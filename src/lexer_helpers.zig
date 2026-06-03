/// Level-2 + SIMD body-skip JavaScript/TypeScript lexer.
///
/// Level-2 outer fast path:
///   Each position first checks if the next 16 bytes are all "simple"
///   (direct single-char tokens + whitespace/newlines via SIMD). Leading
///   simple bytes are batch-processed without touching the complex dispatch.
///
/// SIMD body-skip per arm:
///   identEnd / stringEnd / lineCommentEnd / blockCommentEnd / templateChunkEnd
///   scan token bodies at 16 bytes/cycle.
///
/// Key difference from Lexer2:
///   No full-file classify16 pass.
///   No structural bitmask. No @ctz bitscan inner loop.
///   Each source byte is touched exactly once.

const std = @import("std");
const Token = @import("token.zig");
const Tag = Token.Tag;
const Language = Token.Language;
const Ast = @import("ast.zig");
pub const TokenList = Ast.Ast.TokenList;

const V16 = @Vector(16, u8);
const B16 = @Vector(16, bool);

// ─────────────────────────────────────────────────────────────────────────────
// Public interface (identical to Lexer2)
// ─────────────────────────────────────────────────────────────────────────────

pub const TokenizeResult = struct {
    tokens: TokenList,
    comment_starts: []const u32,
    comment_ends: []const u32,
    comment_kinds: []const u8,
    comment_count: u32,
    line_starts: []u32,
    /// Precomputed wyhash(0, name) for each token at index i where tag == .identifier.
    /// Zero for all other token kinds. Length == tokens.capacity (may exceed tokens.len).

    pub fn deinit(self: *TokenizeResult, allocator: std.mem.Allocator) void {
        self.tokens.deinit(allocator);
        if (self.comment_starts.len > 0) allocator.free(self.comment_starts);
        if (self.comment_ends.len > 0) allocator.free(self.comment_ends);
        if (self.comment_kinds.len > 0) allocator.free(self.comment_kinds);
        if (self.line_starts.len > 0) allocator.free(self.line_starts);
    }
};

/// Optional comment-trivia output. When passed to the scalar lexer it records
/// each comment's `(start, end, kind)` — kind 0 = line / HTML (Annex B),
/// kind 1 = block — matching the bitmap lexer's `comment_*` arrays. Left null
/// on the parse-only fast path so no trivia work is done.
pub const CommentSink = struct {
    starts: std.ArrayListUnmanaged(u32) = .empty,
    ends: std.ArrayListUnmanaged(u32) = .empty,
    kinds: std.ArrayListUnmanaged(u8) = .empty,

    pub fn record(self: *CommentSink, alloc: std.mem.Allocator, start: u32, end: u32, kind: u8) void {
        self.starts.append(alloc, start) catch {};
        self.ends.append(alloc, end) catch {};
        self.kinds.append(alloc, kind) catch {};
    }
    pub fn deinit(self: *CommentSink, alloc: std.mem.Allocator) void {
        self.starts.deinit(alloc);
        self.ends.deinit(alloc);
        self.kinds.deinit(alloc);
    }
};

pub const TokenizeOptions = struct {
    is_module: bool = false,
    annex_b: bool = true,
    /// When non-null, the scalar lexer records comment spans here (trivia).
    comment_sink: ?*CommentSink = null,
    /// Streaming publish: when non-null, the lexer atomically stores `tok_n`
    /// to this slot every PUBLISH_BATCH tokens, allowing a concurrent parser
    /// to consume tokens as they are produced. Null in sequential mode —
    /// hot-loop branch is predicted not-taken with zero overhead.
    publish_to: ?*std.atomic.Value(usize) = null,
    /// Bitmask for publish granularity (batch_size - 1). Must be power-of-2 - 1.
    /// Defaults to PUBLISH_BATCH - 1. Override to tune streaming latency vs overhead.
    publish_batch_mask: usize = PUBLISH_BATCH - 1,
};

/// Streaming publish granularity. Tuned to amortise atomic store cost
/// (~10ns each) over many tokens — at 1024 the lex side adds <20µs total
/// publish overhead on a 9MB file, while the parse side rarely waits.
pub const PUBLISH_BATCH: usize = 1024;

pub fn tokenizeWithLanguage(alloc: std.mem.Allocator, source: []const u8, lang: Language) !TokenizeResult {
    return tokenizeWithAllOptions(alloc, source, lang, .{});
}

pub fn tokenize(alloc: std.mem.Allocator, source: []const u8) !TokenizeResult {
    return tokenizeWithLanguage(alloc, source, .js);
}

pub fn tokenizeWithOptions(alloc: std.mem.Allocator, source: []const u8, lang: Language, is_module: bool) !TokenizeResult {
    return tokenizeWithAllOptions(alloc, source, lang, .{ .is_module = is_module });
}

// ─────────────────────────────────────────────────────────────────────────────
// Level-2 fast path: SIMD simple-byte classifier
// ─────────────────────────────────────────────────────────────────────────────

/// Comptime lookup: is this byte a "simple" byte (direct token or whitespace/NL)?
const IS_SIMPLE: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for ([_]u8{ '(', ')', '[', ']', '{', ';', ',', '~', '@', ':', ' ', '\t', '\n', '\r' }) |b| t[b] = true;
    break :blk t;
};

/// Leading "simple" run including newlines (used when caller handles newlines in inner loop).
inline fn simpleRun16(chunk: V16) u32 {
    const is_lr: B16 = (chunk == @as(V16, @splat(@as(u8, '(')))) |
                       (chunk == @as(V16, @splat(@as(u8, ')'))));
    const is_bk: B16 = (chunk == @as(V16, @splat(@as(u8, '[')))) |
                       (chunk == @as(V16, @splat(@as(u8, ']'))));
    const is_br: B16 = (chunk == @as(V16, @splat(@as(u8, '{'))));
    const is_sc: B16 = (chunk == @as(V16, @splat(@as(u8, ';')))) |
                       (chunk == @as(V16, @splat(@as(u8, ','))));
    const is_ms: B16 = (chunk == @as(V16, @splat(@as(u8, '~')))) |
                       (chunk == @as(V16, @splat(@as(u8, '@'))));
    const is_co: B16 = (chunk == @as(V16, @splat(@as(u8, ':'))));
    const is_ws: B16 = (chunk == @as(V16, @splat(@as(u8, ' ')))) |
                       (chunk == @as(V16, @splat(@as(u8, '\t'))));
    const is_nl: B16 = (chunk == @as(V16, @splat(@as(u8, '\n')))) |
                       (chunk == @as(V16, @splat(@as(u8, '\r'))));
    const simple: u16 = @bitCast(is_lr | is_bk | is_br | is_sc | is_ms | is_co | is_ws | is_nl);
    return @min(16, @as(u32, @ctz(~simple)));
}

/// Like simpleRun16 but stops at newlines — used by Phase 2 since newlines
/// need ls.append and are handled by the complex dispatch (Phase 3).
inline fn simpleRun16Punct(chunk: V16) u32 {
    const is_lr: B16 = (chunk == @as(V16, @splat(@as(u8, '(')))) |
                       (chunk == @as(V16, @splat(@as(u8, ')'))));
    const is_bk: B16 = (chunk == @as(V16, @splat(@as(u8, '[')))) |
                       (chunk == @as(V16, @splat(@as(u8, ']'))));
    const is_br: B16 = (chunk == @as(V16, @splat(@as(u8, '{'))));
    const is_sc: B16 = (chunk == @as(V16, @splat(@as(u8, ';')))) |
                       (chunk == @as(V16, @splat(@as(u8, ','))));
    const is_ms: B16 = (chunk == @as(V16, @splat(@as(u8, '~')))) |
                       (chunk == @as(V16, @splat(@as(u8, '@'))));
    const is_co: B16 = (chunk == @as(V16, @splat(@as(u8, ':'))));
    const is_ws: B16 = (chunk == @as(V16, @splat(@as(u8, ' ')))) |
                       (chunk == @as(V16, @splat(@as(u8, '\t'))));
    const simple: u16 = @bitCast(is_lr | is_bk | is_br | is_sc | is_ms | is_co | is_ws);
    return @min(16, @as(u32, @ctz(~simple)));
}

// ─────────────────────────────────────────────────────────────────────────────
// SIMD body-skip helpers (identical to Lexer2 — no changes)
// ─────────────────────────────────────────────────────────────────────────────

pub inline fn identEnd(src: []const u8, start: u32) u32 {
    const n: u32 = @intCast(src.len);
    var i = start + 1;
    while (i + 16 <= n) {
        const chunk: V16 = src[i..][0..16].*;
        const is_lower = (chunk >= @as(V16, @splat(@as(u8, 'a')))) & (chunk <= @as(V16, @splat(@as(u8, 'z'))));
        const is_upper = (chunk >= @as(V16, @splat(@as(u8, 'A')))) & (chunk <= @as(V16, @splat(@as(u8, 'Z'))));
        const is_digit = (chunk >= @as(V16, @splat(@as(u8, '0')))) & (chunk <= @as(V16, @splat(@as(u8, '9'))));
        const is_ud: B16 = (chunk == @as(V16, @splat(@as(u8, '_')))) | (chunk == @as(V16, @splat(@as(u8, '$'))));
        const is_high: B16 = chunk >= @as(V16, @splat(@as(u8, 0x80)));
        const is_e2: B16 = chunk == @as(V16, @splat(@as(u8, 0xE2)));
        const ib: u16 = @bitCast(is_lower | is_upper | is_digit | is_ud | is_high);
        const e2_mask: u16 = @bitCast(is_e2);
        if (ib != 0xFFFF) {
            const first_bad = @as(u32, @ctz(~ib));
            if (e2_mask == 0) return i + first_bad;
            return i + @min(first_bad, @as(u32, @ctz(e2_mask)));
        }
        // All 16 bytes look like ident chars, but 0xE2 may start LS (U+2028) or PS (U+2029).
        if (e2_mask != 0) return i + @as(u32, @ctz(e2_mask));
        i += 16;
    }
    while (i < n) : (i += 1) {
        switch (src[i]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => {},
            0x80...0xFF => {
                // U+2028 LS (E2 80 A8) and U+2029 PS (E2 80 A9) are line terminators, not ident chars.
                if (src[i] == 0xE2 and i + 2 < n and src[i + 1] == 0x80 and
                    (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) break;
            },
            else => break,
        }
    }
    return i;
}

pub inline fn stringEnd(src: []const u8, open: u32) u32 {
    const n: u32 = @intCast(src.len);
    const quote = src[open];
    const vq  = @as(V16, @splat(quote));
    const vbs = @as(V16, @splat(@as(u8, '\\')));
    const vnl = @as(V16, @splat(@as(u8, '\n')));
    const vcr = @as(V16, @splat(@as(u8, '\r')));
    var i = open + 1;
    while (i + 16 <= n) {
        const chunk: V16 = src[i..][0..16].*;
        const hits: u16 = @bitCast((chunk == vq) | (chunk == vbs) | (chunk == vnl) | (chunk == vcr));
        if (hits != 0) {
            const b: u32 = @ctz(hits);
            const p = i + b;
            const c = src[p];
            if (c == quote) return p + 1;
            if (c == '\\') {
                // Line continuation: \<CRLF> consumes both bytes; \<CR>, \<LF>,
                // \<LS>, \<PS> consume the line terminator. Other escapes
                // consume one byte after the backslash.
                if (p + 2 < n and src[p + 1] == '\r' and src[p + 2] == '\n') {
                    i = p + 3;
                } else if (p + 3 < n and src[p + 1] == 0xE2 and src[p + 2] == 0x80 and
                           (src[p + 3] == 0xA8 or src[p + 3] == 0xA9))
                {
                    i = p + 4;
                } else {
                    i = p + 2;
                }
                continue;
            }
            return p;
        }
        i += 16;
    }
    while (i < n) : (i += 1) {
        const c = src[i];
        if (c == quote) return i + 1;
        if (c == '\\') {
            if (i + 2 < n and src[i + 1] == '\r' and src[i + 2] == '\n') {
                i += 2;
            } else if (i + 3 < n and src[i + 1] == 0xE2 and src[i + 2] == 0x80 and
                       (src[i + 3] == 0xA8 or src[i + 3] == 0xA9))
            {
                i += 3;
            } else {
                i += 1;
            }
            continue;
        }
        if (c == '\n' or c == '\r') return i;
    }
    return i;
}

pub fn lineCommentEnd(src: []const u8, start: u32) u32 {
    const n: u32 = @intCast(src.len);
    const vnl = @as(V16, @splat(@as(u8, '\n')));
    const vcr = @as(V16, @splat(@as(u8, '\r')));
    var i = start;
    while (i + 16 <= n) {
        const chunk: V16 = src[i..][0..16].*;
        const m: u16 = @bitCast((chunk == vnl) | (chunk == vcr));
        if (m != 0) return i + @as(u32, @ctz(m));
        i += 16;
    }
    while (i < n and src[i] != '\n' and src[i] != '\r') i += 1;
    return i;
}

pub fn blockCommentEnd(src: []const u8, open: u32) struct { end: u32, has_nl: bool } {
    const n: u32 = @intCast(src.len);
    const vstar = @as(V16, @splat(@as(u8, '*')));
    const vnl   = @as(V16, @splat(@as(u8, '\n')));
    const vcr   = @as(V16, @splat(@as(u8, '\r')));
    const ve2   = @as(V16, @splat(@as(u8, 0xE2)));
    var i = open + 2;
    var has_nl = false;
    while (i + 16 <= n) {
        const chunk: V16 = src[i..][0..16].*;
        const nl_mask: u16 = @bitCast((chunk == vnl) | (chunk == vcr));
        // LS (E2 80 A8) and PS (E2 80 A9) checked via 0xE2 lead-byte hits.
        const e2_mask: u16 = @bitCast(chunk == ve2);
        var sm: u16 = @bitCast(chunk == vstar);
        if (sm == 0) {
            if (nl_mask != 0) has_nl = true;
            if (!has_nl and e2_mask != 0) has_nl = checkLsPs(src, i, e2_mask, n);
            i += 16;
            continue;
        }
        while (sm != 0) {
            const b: u32 = @ctz(sm); sm &= sm -% 1;
            const p = i + b;
            if (p + 1 < n and src[p + 1] == '/') {
                if (nl_mask != 0 and b > 0) {
                    const before: u16 = (@as(u16, 1) << @intCast(b)) - 1;
                    if ((nl_mask & before) != 0) has_nl = true;
                }
                if (!has_nl and e2_mask != 0 and b > 0) {
                    const before: u16 = (@as(u16, 1) << @intCast(b)) - 1;
                    const e2_before = e2_mask & before;
                    if (e2_before != 0) has_nl = checkLsPs(src, i, e2_before, n);
                }
                return .{ .end = p + 2, .has_nl = has_nl };
            }
        }
        if (nl_mask != 0) has_nl = true;
        if (!has_nl and e2_mask != 0) has_nl = checkLsPs(src, i, e2_mask, n);
        i += 16;
    }
    while (i + 1 < n) : (i += 1) {
        if (src[i] == '\n' or src[i] == '\r') has_nl = true;
        if (src[i] == 0xE2 and i + 2 < n and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) has_nl = true;
        if (src[i] == '*' and src[i + 1] == '/') return .{ .end = i + 2, .has_nl = has_nl };
    }
    return .{ .end = n, .has_nl = has_nl };
}

inline fn checkLsPs(src: []const u8, base: u32, mask: u16, n: u32) bool {
    var m = mask;
    while (m != 0) {
        const b: u32 = @ctz(m); m &= m -% 1;
        const p = base + b;
        if (p + 2 < n and src[p + 1] == 0x80 and (src[p + 2] == 0xA8 or src[p + 2] == 0xA9)) return true;
    }
    return false;
}

pub fn templateChunkEnd(src: []const u8, open: u32) struct { end: u32, has_expr: bool, terminated: bool } {
    const n: u32 = @intCast(src.len);
    const vtick = @as(V16, @splat(@as(u8, '`')));
    const vbs   = @as(V16, @splat(@as(u8, '\\')));
    const vdol  = @as(V16, @splat(@as(u8, '$')));
    var i = open + 1;
    while (i < n) {
        if (i + 16 <= n) {
            const chunk: V16 = src[i..][0..16].*;
            const hits: u16 = @bitCast((chunk == vtick) | (chunk == vbs) | (chunk == vdol));
            if (hits == 0) { i += 16; continue; }
            const b: u32 = @ctz(hits);
            const p = i + b;
            const c = src[p];
            if (c == '`') return .{ .end = p + 1, .has_expr = false, .terminated = true };
            if (c == '\\') { i = p + 2; continue; }
            if (p + 1 < n and src[p + 1] == '{') return .{ .end = p + 2, .has_expr = true, .terminated = true };
            i = p + 1;
        } else {
            const c = src[i];
            if (c == '`') return .{ .end = i + 1, .has_expr = false, .terminated = true };
            if (c == '\\') { i += 2; continue; }
            if (c == '$' and i + 1 < n and src[i + 1] == '{') return .{ .end = i + 2, .has_expr = true, .terminated = true };
            i += 1;
        }
    }
    return .{ .end = n, .has_expr = false, .terminated = false };
}

pub inline fn regexEnd(src: []const u8, open: u32) u32 {
    const n: u32 = @intCast(src.len);
    var i = open + 1;
    var in_class = false;
    while (i < n) : (i += 1) {
        const c = src[i];
        if (c == '\\' and i + 1 < n) { i += 1; continue; }
        if (c == '[') { in_class = true; continue; }
        if (c == ']') { in_class = false; continue; }
        if (c == '/' and !in_class) {
            i += 1;
            while (i < n) : (i += 1) {
                switch (src[i]) { 'a'...'z', 'A'...'Z', '0'...'9' => {}, else => break }
            }
            return i;
        }
        if (c == '\n' or c == '\r') return i;
    }
    return i;
}

pub inline fn numberEnd(src: []const u8, open: u32) u32 {
    const n: u32 = @intCast(src.len);
    var i = open;
    // Track whether this is a legacy octal literal (starts with `0` followed by
    // more digits).  Legacy octals must not consume a trailing `.` because `.`
    // signals property / method access on the number: `01.a` → member access.
    var is_legacy_octal = false;
    if (src[i] == '0' and i + 1 < n) {
        switch (src[i + 1]) {
            'x', 'X' => {
                i += 2;
                while (i < n) { switch (src[i]) { '0'...'9', 'a'...'f', 'A'...'F', '_' => i += 1, else => break } }
                if (i < n and src[i] == 'n') i += 1;
                return i;
            },
            'o', 'O' => {
                i += 2;
                while (i < n) { switch (src[i]) { '0'...'7', '_' => i += 1, else => break } }
                if (i < n and src[i] == 'n') i += 1;
                return i;
            },
            'b', 'B' => {
                i += 2;
                while (i < n) { switch (src[i]) { '0', '1', '_' => i += 1, else => break } }
                if (i < n and src[i] == 'n') i += 1;
                return i;
            },
            '0'...'7' => { is_legacy_octal = true; }, // valid octal digits; 8/9 are decimal
            else => {},
        }
    }
    // Walk decimal digits.  Track whether we hit `8` or `9` — when a
    // legacy-octal-shaped prefix `0[0-7]*` is followed by 8/9, the whole
    // literal is a NonOctalDecimalIntegerLiteral (Annex B.1.1) which MAY
    // have a fractional part / exponent like any decimal.  Without this,
    // `019.1` was lexed as `019` + `.1` (two tokens, syntax garbage)
    // instead of a single number.
    var has_non_octal_digit = false;
    while (i < n) {
        switch (src[i]) {
            '0'...'7', '_' => i += 1,
            '8', '9' => { has_non_octal_digit = true; i += 1; },
            else => break,
        }
    }
    if (is_legacy_octal and has_non_octal_digit) is_legacy_octal = false;
    if (!is_legacy_octal and i < n and src[i] == '.') {
        i += 1;
        while (i < n) { switch (src[i]) { '0'...'9', '_' => i += 1, else => break } }
    }
    if (i < n and (src[i] == 'e' or src[i] == 'E')) {
        i += 1;
        if (i < n and (src[i] == '+' or src[i] == '-')) i += 1;
        while (i < n) { switch (src[i]) { '0'...'9', '_' => i += 1, else => break } }
    }
    if (i < n and src[i] == 'n') i += 1;
    return i;
}

// ─────────────────────────────────────────────────────────────────────────────
// Regex disambiguation (identical to Lexer2)
// ─────────────────────────────────────────────────────────────────────────────

pub inline fn regexAllowed(prev: Tag) bool {
    return switch (prev) {
        .eof,
        .l_paren, .l_brace, .l_bracket,
        .semicolon, .comma, .colon, .arrow,
        .question, .question_dot,
        .plus, .minus, .asterisk, .slash, .percent, .asterisk_asterisk,
        .ampersand, .pipe, .caret, .tilde, .bang,
        .less_than, .greater_than,
        .less_less, .greater_greater, .greater_greater_greater,
        .equal,
        .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal,
        .asterisk_asterisk_equal,
        .ampersand_equal, .pipe_equal, .caret_equal,
        .less_less_equal, .greater_greater_equal, .greater_greater_greater_equal,
        .ampersand_ampersand_equal, .pipe_pipe_equal, .question_question_equal,
        .equal_equal, .bang_equal, .equal_equal_equal, .bang_equal_equal,
        .less_equal, .greater_equal,
        .ampersand_ampersand, .pipe_pipe, .question_question,
        .kw_return, .kw_typeof, .kw_void, .kw_delete, .kw_throw,
        .kw_new, .kw_in, .kw_instanceof, .kw_await, .kw_case,
        // Inside a template-literal interpolation: `${/regex/}` — after
        // `${` (template_head) and `}${` boundaries (template_middle),
        // the next token starts an expression, so a regex is allowed.
        .template_head, .template_middle,
        => true,
        else => false,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Main tokenize
// ─────────────────────────────────────────────────────────────────────────────

pub fn tokenizeWithAllOptions(
    alloc: std.mem.Allocator,
    source: []const u8,
    language: Language,
    opts: TokenizeOptions,
) !TokenizeResult {
    return tokenizeWithBuf(alloc, source, language, opts, null);
}

/// Variant that lets the caller supply a pre-allocated TokenList. Used by
/// the streaming pipeline driver: parser thread already holds a slice over
/// the buffer, and the lexer thread writes into the same backing memory.
pub fn tokenizeWithBuf(
    alloc: std.mem.Allocator,
    source: []const u8,
    language: Language,
    opts: TokenizeOptions,
    tokens_buf: ?*TokenList,
) !TokenizeResult {
    _ = opts.annex_b;
    const src = source;
    const n: u32 = @intCast(src.len);

    // Bound for token capacity. Empirical token density in conformance
    // fixtures peaks around n/2 (eg `;;` heavy code), well above the
    // Initial cap n/4+128 covers ~99.9% of real-world files. Pathological
    // dense files (e.g. parse5's named_entity_trie.js at 0.78 tok/byte)
    // exceed; we double-and-grow on overflow at outer loop boundary.
    var cap: u32 = @max(n / 4 + 128, 128);
    var tokens: TokenList = if (tokens_buf) |b| b.* else TokenList{};
    if (tokens_buf == null) try tokens.ensureTotalCapacity(alloc, cap);
    var ts_init = tokens.slice();
    var tag_ptr   = ts_init.items(.tag).ptr;
    var start_ptr = ts_init.items(.start).ptr;
    var len_ptr   = ts_init.items(.len).ptr;
    var nl_ptr    = ts_init.items(.has_newline_before).ptr;
    var esc_ptr   = ts_init.items(.has_unicode_escape).ptr;
    @memset(esc_ptr[0..tokens.capacity], false);
    var tok_n: usize = 0;
    const cm_cap: u32 = @max(n / 200 + 16, 16);
    var cm_s = try std.ArrayListUnmanaged(u32).initCapacity(alloc, cm_cap);
    var cm_e = try std.ArrayListUnmanaged(u32).initCapacity(alloc, cm_cap);
    var cm_k = try std.ArrayListUnmanaged(u8 ).initCapacity(alloc, cm_cap);

    var ls = try std.ArrayListUnmanaged(u32).initCapacity(alloc, @max(n / 30 + 16, 16));
    try ls.append(alloc, 0);

    var prev_kind: Tag  = .eof;
    var saw_nl:   bool  = false;
    // Tracks whether we are at the logical start of a line (for Annex B --> comment).
    // True at the start of the file; set true after any newline; cleared when a real
    // (non-comment, non-whitespace) token is emitted.
    var at_line_start: bool = true;
    var tmpl_depth: u32 = 0;
    var brace_d: [16]u32 = @splat(0);

    var pos: u32 = 0;

    const vsp: V16 = @splat(' ');
    const vtb: V16 = @splat('\t');

    outer: while (pos < n) {
        // Capacity guard: Phase 2 fast path emits up to 16 tokens per chunk,
        // Phase 3 emits 1. 64-token margin covers worst case + slack.
        if (tok_n + 64 > cap) {
            tokens.len = tok_n;
            cap *= 2;
            tokens.ensureTotalCapacity(alloc, cap) catch return error.OutOfMemory;
            ts_init = tokens.slice();
            tag_ptr   = ts_init.items(.tag).ptr;
            start_ptr = ts_init.items(.start).ptr;
            len_ptr   = ts_init.items(.len).ptr;
            nl_ptr    = ts_init.items(.has_newline_before).ptr;
            esc_ptr   = ts_init.items(.has_unicode_escape).ptr;
            @memset(esc_ptr[tok_n..tokens.capacity], false);
        }
        const byte = src[pos];

        // ══════════════════════════════════════════════════════════════════════
        // Phase 1: Whitespace SIMD skip (space + tab only, 2 compares / 16 B)
        // Kept separate from the punctuation fast path because whitespace
        // carries no token data — no IS_SIMPLE dispatch overhead needed here.
        // ══════════════════════════════════════════════════════════════════════
        if (byte == ' ' or byte == '\t') {
            pos += 1;
            while (pos + 16 <= n) {
                const chunk: V16 = src[pos..][0..16].*;
                const ws: u16 = @bitCast((chunk == vsp) | (chunk == vtb));
                if (ws != 0xFFFF) { pos += @ctz(~ws); break; }
                pos += 16;
            }
            while (pos < n and (src[pos] == ' ' or src[pos] == '\t')) pos += 1;
            continue :outer;
        }

        // ══════════════════════════════════════════════════════════════════════
        // Phase 2: Level-2 punctuation fast path
        // Only for IS_SIMPLE chars that are NOT newlines — newlines need
        // ls.append so they must go through the complex dispatch below.
        // ══════════════════════════════════════════════════════════════════════
        if (IS_SIMPLE[byte] and byte != '\n' and byte != '\r' and pos + 16 <= n) {
            const chunk: V16 = src[pos..][0..16].*;
            const run = simpleRun16Punct(chunk);
            if (run > 0) {
                var i: u32 = 0;
                while (i < run) : (i += 1) {
                    switch (src[pos + i]) {
                        '(' => { tag_ptr[tok_n] = .l_paren;   start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .l_paren; },
                        ')' => { tag_ptr[tok_n] = .r_paren;   start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .r_paren; },
                        '[' => { tag_ptr[tok_n] = .l_bracket; start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .l_bracket; },
                        ']' => { tag_ptr[tok_n] = .r_bracket; start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .r_bracket; },
                        '{' => {
                            if (tmpl_depth > 0) brace_d[tmpl_depth - 1] += 1;
                            tag_ptr[tok_n] = .l_brace; start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .l_brace;
                        },
                        ';' => { tag_ptr[tok_n] = .semicolon; start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .semicolon; },
                        ',' => { tag_ptr[tok_n] = .comma;     start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .comma; },
                        '~' => { tag_ptr[tok_n] = .tilde;     start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .tilde; },
                        '@' => { tag_ptr[tok_n] = .at_sign;   start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .at_sign; },
                        ':' => { tag_ptr[tok_n] = .colon;     start_ptr[tok_n] = pos+i; len_ptr[tok_n] = 1; nl_ptr[tok_n] = saw_nl; tok_n += 1; saw_nl = false; prev_kind = .colon; },
                        ' ', '\t' => {},
                        else => unreachable,
                    }
                }
                pos += run;
                // Streaming publish: amortised over PUBLISH_BATCH tokens to
                // keep the atomic store rate low. In sequential mode the
                // option is null and the branch is predicted not-taken.
                if (opts.publish_to) |p| {
                    if ((tok_n & opts.publish_batch_mask) == 0) p.store(tok_n, .release);
                }
                continue :outer; // byte is stale after pos changes — restart loop
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // Phase 3: Complex arm dispatch at src[pos]
        // ══════════════════════════════════════════════════════════════════════
        var tag: Tag = undefined;
        var end: u32 = undefined;
        var is_escaped: bool = false;

        switch (byte) {
            // ── Whitespace not caught by fast path (tail of file, etc.) ──────
            ' ', '\t' => { pos += 1; continue :outer; },
            '\n' => { saw_nl = true; at_line_start = true; try ls.append(alloc, pos + 1); pos += 1; continue :outer; },
            '\r' => {
                saw_nl = true; at_line_start = true;
                if (pos + 1 < n and src[pos + 1] == '\n') {
                    try ls.append(alloc, pos + 2); pos += 2;
                } else {
                    try ls.append(alloc, pos + 1); pos += 1;
                }
                continue :outer;
            },
            0x0B, 0x0C => { pos += 1; continue :outer; },

            // ── '}' — might end a template expression ────────────────────────
            '}' => {
                if (tmpl_depth > 0 and brace_d[tmpl_depth - 1] == 0) {
                    const res = templateChunkEnd(src, pos);
                    if (!res.terminated) {
                        tag = .invalid; end = res.end;
                    } else if (res.has_expr) {
                        tag = .template_middle; end = res.end;
                    } else {
                        tag = .template_tail; end = res.end;
                        tmpl_depth -= 1;
                    }
                } else {
                    if (tmpl_depth > 0) brace_d[tmpl_depth - 1] -= 1;
                    tag = .r_brace; end = pos + 1;
                }
            },

            // ── Simple single-char tokens (IS_SIMPLE, non-newline) ──────────
            // Phase 2 handles these in batch when pos+16<=n. When near EOF
            // (pos+16>n), Phase 2 is skipped and we need scalar fallbacks here.
            '(' => { tag = .l_paren;   end = pos + 1; },
            ')' => { tag = .r_paren;   end = pos + 1; },
            '[' => { tag = .l_bracket; end = pos + 1; },
            ']' => { tag = .r_bracket; end = pos + 1; },
            '{' => {
                if (tmpl_depth > 0) brace_d[tmpl_depth - 1] += 1;
                tag = .l_brace; end = pos + 1;
            },
            ';' => { tag = .semicolon; end = pos + 1; },
            ',' => { tag = .comma;     end = pos + 1; },
            '~' => { tag = .tilde;     end = pos + 1; },
            '@' => { tag = .at_sign;   end = pos + 1; },
            ':' => { tag = .colon;     end = pos + 1; },

            // ── '.' ─────────────────────────────────────────────────────────
            '.' => {
                if (pos + 2 < n and src[pos + 1] == '.' and src[pos + 2] == '.') {
                    tag = .ellipsis; end = pos + 3;
                } else if (pos + 1 < n and src[pos + 1] >= '0' and src[pos + 1] <= '9') {
                    end = numberEnd(src, pos); tag = .number_literal;
                } else {
                    tag = .dot; end = pos + 1;
                }
            },

            // ── '?' ─────────────────────────────────────────────────────────
            '?' => {
                if (pos + 1 < n and src[pos + 1] == '?') {
                    if (pos + 2 < n and src[pos + 2] == '=') { tag = .question_question_equal; end = pos + 3; }
                    else                                       { tag = .question_question;       end = pos + 2; }
                } else if (pos + 1 < n and src[pos + 1] == '.') {
                    tag = .question_dot; end = pos + 2;
                } else {
                    tag = .question; end = pos + 1;
                }
            },

            // ── '+' ─────────────────────────────────────────────────────────
            '+' => {
                if (pos + 1 < n and src[pos + 1] == '+') { tag = .plus_plus;  end = pos + 2; }
                else if (pos + 1 < n and src[pos + 1] == '=') { tag = .plus_equal; end = pos + 2; }
                else { tag = .plus; end = pos + 1; }
            },

            // ── '-' ─────────────────────────────────────────────────────────
            '-' => {
                // Annex B: `-->` at the start of a line is a single-line comment
                // (HTML close comment).  `at_line_start` is true when no real token
                // has been emitted since the last newline (or since file start).
                if (at_line_start and pos + 2 <= n and src[pos + 1] == '-' and src[pos + 2] == '>') {
                    const ce = lineCommentEnd(src, pos + 3);
                    try cm_s.append(alloc, pos);
                    try cm_e.append(alloc, ce);
                    try cm_k.append(alloc, 0);
                    saw_nl = true; pos = ce; continue :outer;
                }
                if (pos + 1 < n and src[pos + 1] == '-') { tag = .minus_minus;  end = pos + 2; }
                else if (pos + 1 < n and src[pos + 1] == '=') { tag = .minus_equal; end = pos + 2; }
                else { tag = .minus; end = pos + 1; }
            },

            // ── '*' ─────────────────────────────────────────────────────────
            '*' => {
                if (pos + 1 < n and src[pos + 1] == '*') {
                    if (pos + 2 < n and src[pos + 2] == '=') { tag = .asterisk_asterisk_equal; end = pos + 3; }
                    else { tag = .asterisk_asterisk; end = pos + 2; }
                } else if (pos + 1 < n and src[pos + 1] == '=') { tag = .asterisk_equal; end = pos + 2; }
                else { tag = .asterisk; end = pos + 1; }
            },

            // ── '%' ─────────────────────────────────────────────────────────
            '%' => {
                if (pos + 1 < n and src[pos + 1] == '=') { tag = .percent_equal; end = pos + 2; }
                else { tag = .percent; end = pos + 1; }
            },

            // ── '&' ─────────────────────────────────────────────────────────
            '&' => {
                if (pos + 1 < n and src[pos + 1] == '&') {
                    if (pos + 2 < n and src[pos + 2] == '=') { tag = .ampersand_ampersand_equal; end = pos + 3; }
                    else { tag = .ampersand_ampersand; end = pos + 2; }
                } else if (pos + 1 < n and src[pos + 1] == '=') { tag = .ampersand_equal; end = pos + 2; }
                else { tag = .ampersand; end = pos + 1; }
            },

            // ── '|' ─────────────────────────────────────────────────────────
            '|' => {
                if (pos + 1 < n and src[pos + 1] == '|') {
                    if (pos + 2 < n and src[pos + 2] == '=') { tag = .pipe_pipe_equal; end = pos + 3; }
                    else { tag = .pipe_pipe; end = pos + 2; }
                } else if (pos + 1 < n and src[pos + 1] == '=') { tag = .pipe_equal; end = pos + 2; }
                else { tag = .pipe; end = pos + 1; }
            },

            // ── '^' ─────────────────────────────────────────────────────────
            '^' => {
                if (pos + 1 < n and src[pos + 1] == '=') { tag = .caret_equal; end = pos + 2; }
                else { tag = .caret; end = pos + 1; }
            },

            // ── '!' ─────────────────────────────────────────────────────────
            '!' => {
                if (pos + 1 < n and src[pos + 1] == '=') {
                    if (pos + 2 < n and src[pos + 2] == '=') { tag = .bang_equal_equal; end = pos + 3; }
                    else { tag = .bang_equal; end = pos + 2; }
                } else { tag = .bang; end = pos + 1; }
            },

            // ── '<' ─────────────────────────────────────────────────────────
            '<' => {
                // Annex B: `<!--` is a single-line comment (HTML open comment).
                if (pos + 3 <= n and src[pos + 1] == '!' and src[pos + 2] == '-' and src[pos + 3] == '-') {
                    const ce = lineCommentEnd(src, pos + 4);
                    try cm_s.append(alloc, pos);
                    try cm_e.append(alloc, ce);
                    try cm_k.append(alloc, 0);
                    saw_nl = true; pos = ce; continue :outer;
                }
                if (pos + 1 < n and src[pos + 1] == '=') { tag = .less_equal; end = pos + 2; }
                else if (pos + 1 < n and src[pos + 1] == '<') {
                    if (pos + 2 < n and src[pos + 2] == '=') { tag = .less_less_equal; end = pos + 3; }
                    else { tag = .less_less; end = pos + 2; }
                } else { tag = .less_than; end = pos + 1; }
            },

            // ── '>' ─────────────────────────────────────────────────────────
            '>' => {
                if (pos + 1 < n and src[pos + 1] == '=') {
                    tag = .greater_equal; end = pos + 2;
                } else if (pos + 1 < n and src[pos + 1] == '>') {
                    if (pos + 2 < n and src[pos + 2] == '>') {
                        if (pos + 3 < n and src[pos + 3] == '=') { tag = .greater_greater_greater_equal; end = pos + 4; }
                        else { tag = .greater_greater_greater; end = pos + 3; }
                    } else if (pos + 2 < n and src[pos + 2] == '=') { tag = .greater_greater_equal; end = pos + 3; }
                    else { tag = .greater_greater; end = pos + 2; }
                } else { tag = .greater_than; end = pos + 1; }
            },

            // ── '=' ─────────────────────────────────────────────────────────
            '=' => {
                if (pos + 1 < n and src[pos + 1] == '=') {
                    if (pos + 2 < n and src[pos + 2] == '=') { tag = .equal_equal_equal; end = pos + 3; }
                    else { tag = .equal_equal; end = pos + 2; }
                } else if (pos + 1 < n and src[pos + 1] == '>') { tag = .arrow; end = pos + 2; }
                else { tag = .equal; end = pos + 1; }
            },

            // ── '#' ─────────────────────────────────────────────────────────
            '#' => {
                if (pos == 0 and pos + 1 < n and src[pos + 1] == '!') {
                    end = lineCommentEnd(src, pos + 2); tag = .hashbang;
                } else {
                    tag = .hash; end = pos + 1;
                }
            },

            // ── '/' — comment, regex, or divide ─────────────────────────────
            '/' => {
                if (pos + 1 < n and src[pos + 1] == '/') {
                    const ce = lineCommentEnd(src, pos + 2);
                    try cm_s.append(alloc, pos);
                    try cm_e.append(alloc, ce);
                    try cm_k.append(alloc, 0);
                    saw_nl = true; pos = ce; continue :outer;
                }
                if (pos + 1 < n and src[pos + 1] == '*') {
                    const res = blockCommentEnd(src, pos);
                    try cm_s.append(alloc, pos);
                    try cm_e.append(alloc, res.end);
                    try cm_k.append(alloc, 1);
                    if (res.has_nl) { saw_nl = true; at_line_start = true; }
                    pos = res.end; continue :outer;
                }
                if (pos + 1 < n and src[pos + 1] == '=') { tag = .slash_equal; end = pos + 2; }
                // In JSX/TSX mode, `</tag>` must not have `/` tokenized as regex.
                // `.less_than` before `/` means we are inside a closing tag.
                else if (regexAllowed(prev_kind) and !(language.isJsx() and (prev_kind == .less_than or prev_kind == .greater_than))) { end = regexEnd(src, pos); tag = .regex_literal; }
                else { tag = .slash; end = pos + 1; }
            },

            // ── Strings ─────────────────────────────────────────────────────
            '"', '\'' => { end = stringEnd(src, pos); tag = .string_literal; },

            // ── Template literals ────────────────────────────────────────────
            '`' => {
                const res = templateChunkEnd(src, pos);
                if (!res.terminated) {
                    tag = .invalid; end = res.end;
                } else if (res.has_expr) {
                    tag = .template_head;
                    if (tmpl_depth < brace_d.len) {
                        brace_d[tmpl_depth] = 0;
                        tmpl_depth += 1;
                    }
                    end = res.end;
                } else {
                    tag = .template_no_sub; end = res.end;
                }
            },

            // ── Numbers ─────────────────────────────────────────────────────
            '0'...'9' => {
                end = numberEnd(src, pos);
                tag = if (end > pos and src[end - 1] == 'n') .bigint_literal else .number_literal;
            },

            // ── Identifiers and keywords ─────────────────────────────────────
            'a'...'z', 'A'...'Z', '_', '$' => {
                end = identEnd(src, pos);
                const text = src[pos..end];
                if (text.len <= 10) {
                    if (Token.keywords.get(text)) |kw| {
                        tag = kw;
                    } else if (language.isTs()) {
                        tag = Token.ts_keywords.get(text) orelse .identifier;
                    } else {
                        tag = .identifier;
                    }
                } else {
                    tag = .identifier;
                }
            },

            // ── Unicode high bytes ───────────────────────────────────────────
            0x80...0xFF => {
                if (byte == 0xE2 and pos + 2 < n and src[pos + 1] == 0x80 and
                    (src[pos + 2] == 0xA8 or src[pos + 2] == 0xA9))
                {
                    saw_nl = true; at_line_start = true; pos += 3; continue :outer;
                }
                if (byte == 0xEF and pos + 2 < n and src[pos + 1] == 0xBB and src[pos + 2] == 0xBF) {
                    pos += 3; continue :outer;
                }
                end = identEnd(src, pos); tag = .identifier;
            },

            // ── Backslash — \uXXXX escaped identifier ───────────────────────
            '\\' => {
                end = identEnd(src, pos);
                if (end == pos) end = pos + 1;
                const text = src[pos..end];
                tag = if (Token.keywords.get(text) != null) .escaped_keyword else .identifier;
                is_escaped = true;
            },

            // ── Anything else ────────────────────────────────────────────────
            else => {
                // VT (0x0B) and FF (0x0C) are ECMAScript WhiteSpace — skip silently.
                if (byte == 0x0B or byte == 0x0C) { pos += 1; continue :outer; }
                // All other unrecognized bytes are illegal tokens.
                tag = .invalid; end = pos + 1;
            },
        }

        // ── Emit token ──
        tag_ptr[tok_n]   = tag;
        start_ptr[tok_n] = pos;
        len_ptr[tok_n]   = end - pos;
        nl_ptr[tok_n]    = saw_nl;
        if (is_escaped) esc_ptr[tok_n] = true;
        tok_n += 1;
        saw_nl       = false;
        at_line_start = false;
        // When a keyword is used as a property name (preceded by `.`), treat it as
        // an identifier for regex disambiguation: `a.in / b` is division, not regex.
        prev_kind = if (prev_kind == .dot and tag.isKeyword()) .identifier else tag;
        pos       = end;
        if (opts.publish_to) |p| {
            if ((tok_n & opts.publish_batch_mask) == 0) p.store(tok_n, .release);
        }
    }

    // ── EOF token ──
    tag_ptr[tok_n]   = .eof;
    start_ptr[tok_n] = n;
    len_ptr[tok_n]   = 0;
    nl_ptr[tok_n]    = saw_nl;
    tok_n += 1;
    tokens.len = tok_n;

    const comment_count: u32 = @intCast(cm_s.items.len);
    return .{
        .tokens         = tokens,
        .comment_starts = try cm_s.toOwnedSlice(alloc),
        .comment_ends   = try cm_e.toOwnedSlice(alloc),
        .comment_kinds  = try cm_k.toOwnedSlice(alloc),
        .comment_count  = comment_count,
        .line_starts    = try ls.toOwnedSlice(alloc),
    };
}
