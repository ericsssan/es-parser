//! Lexer support types + shared SIMD token-body scanners.
//!
//! Holds `TokenizeResult` / `TokenizeOptions` / `CommentSink`, and the SIMD
//! body-skip scanners (`blockCommentEnd`, `templateChunkEnd`, `regexEnd`,
//! `numberEnd`, `regexAllowed`) that `scalar_lexer` calls. The standalone
//! tokenizer this file once held has been retired (scalar is the sole producer).

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
    /// When non-null, the scalar lexer records line-start byte offsets here as it
    /// scans (single pass — inter-token newlines from the whitespace handlers,
    /// multi-line token interiors from their emit sites). Caller seeds index 0.
    line_starts: ?*std.ArrayListUnmanaged(u32) = null,
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
