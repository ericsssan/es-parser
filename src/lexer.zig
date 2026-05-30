/// Two-phase bitmap lexer.
///
/// Phase 1: single SIMD pass over source, producing per-byte bitmaps for
///   ident / whitespace / newline / punct / op_byte / quote / slash /
///   backtick / hash / backslash / high (0x80+). 4× ILP unroll on
///   64-byte windows. Validated at ~4.6ms / 1880 MB/s on typescript.js.
///
/// Phase 2: walk a "visit" bitmap = newline | structural | ident_starts.
/// Whitespace and ident-body bytes are NEVER visited — the bitmap walk
/// skips them automatically. For each visited position, dispatch reuses
/// helpers from lexer_helpers.zig so semantics stay identical.

const std = @import("std");
const Token = @import("token.zig");
const Tag = Token.Tag;
const Language = Token.Language;
const Ast = @import("ast.zig");
const Lex = @import("lexer_helpers.zig");
pub const TokenList = Ast.Ast.TokenList;

const V16 = @Vector(16, u8);
const B16 = @Vector(16, bool);

// ─────────────────────────────────────────────────────────────────────────────
// Public interface — must match lexer.zig exactly so root.zig dispatch is a
// drop-in replacement.
// ─────────────────────────────────────────────────────────────────────────────

pub const TokenizeResult = Lex.TokenizeResult;
pub const TokenizeOptions = Lex.TokenizeOptions;
pub const PUBLISH_BATCH: usize = Lex.PUBLISH_BATCH;

pub fn tokenize(alloc: std.mem.Allocator, source: []const u8) !TokenizeResult {
    return tokenizeWithAllOptions(alloc, source, .js, .{});
}
pub fn tokenizeWithLanguage(alloc: std.mem.Allocator, source: []const u8, lang: Language) !TokenizeResult {
    return tokenizeWithAllOptions(alloc, source, lang, .{});
}
pub fn tokenizeWithOptions(alloc: std.mem.Allocator, source: []const u8, lang: Language, is_module: bool) !TokenizeResult {
    return tokenizeWithAllOptions(alloc, source, lang, .{ .is_module = is_module });
}
pub fn tokenizeWithAllOptions(
    alloc: std.mem.Allocator,
    source: []const u8,
    language: Language,
    opts: TokenizeOptions,
) !TokenizeResult {
    return tokenizeWithBuf(alloc, source, language, opts, null);
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1: build per-byte bitmaps via 4× ILP SIMD on 64-byte windows.
// ─────────────────────────────────────────────────────────────────────────────

pub const Bitmaps = struct {
    /// 1 bit per source byte; 64 bytes packed per u64 word.
    /// Last word may have unused trailing bits (zero-filled).
    ident: []u64, // a-z A-Z 0-9 _ $ 0x80+
    newline: []u64, // \n \r
    /// "Structural" — every byte that triggers the complex dispatch in
    /// Phase 2: punct (( ) [ ] { } ; , . ? : ~ @), op (+ - * / % < > = !
    /// & | ^), quote (' "), backtick (`), hash (#), backslash (\), and
    /// high bytes (0x80+, for unicode line separators / ident continuation).
    /// Whitespace and pure ident-body bytes are NOT included.
    structural: []u64,
    /// Whole-source flag: true if any byte ≥ 0x80 was seen. Lets the
    /// walker fast-skip the per-emit pending_drain check for ASCII-only
    /// sources (the common case for JS/TS source).
    has_high: bool = false,

    pub fn init(alloc: std.mem.Allocator, n_bytes: usize) !Bitmaps {
        const n_words = (n_bytes + 63) / 64 + 1; // +1 sentinel for cross-word carry
        return .{
            .ident      = try alloc.alloc(u64, n_words),
            .newline    = try alloc.alloc(u64, n_words),
            .structural = try alloc.alloc(u64, n_words),
        };
    }
    pub fn deinit(self: *Bitmaps, alloc: std.mem.Allocator) void {
        alloc.free(self.ident);
        alloc.free(self.newline);
        alloc.free(self.structural);
    }
};

const ChunkMasks = struct {
    ident: u16 = 0,
    newline: u16 = 0,
    structural: u16 = 0,
};

inline fn classifyChunk(chunk: V16, m: *ChunkMasks) void {
    // Ident: a-z, A-Z, 0-9, _, $, 0x80+
    //
    // Compress upper-or-lower-letter check into a single range test: ORing
    // with 0x20 maps 'A'..'Z' (0x41..0x5A) → 0x61..0x7A = 'a'..'z'. Then
    // a single 'a'..'z' range catches both cases. Saves 2 SIMD compares
    // (and 1 OR) per chunk.
    const lower_chunk = chunk | @as(V16, @splat(@as(u8, 0x20)));
    const is_letter = (lower_chunk >= @as(V16, @splat(@as(u8, 'a')))) &
                      (lower_chunk <= @as(V16, @splat(@as(u8, 'z'))));
    const is_digit = (chunk >= @as(V16, @splat(@as(u8, '0')))) & (chunk <= @as(V16, @splat(@as(u8, '9'))));
    const is_us_dl: B16 = (chunk == @as(V16, @splat(@as(u8, '_')))) | (chunk == @as(V16, @splat(@as(u8, '$'))));
    const is_high: B16 = chunk >= @as(V16, @splat(@as(u8, 0x80)));
    m.ident = @bitCast(is_letter | is_digit | is_us_dl | is_high);

    // Newline: \n \r (LS/PS handled via 0x80+ bytes elsewhere)
    m.newline = @bitCast(
        (chunk == @as(V16, @splat(@as(u8, '\n')))) |
        (chunk == @as(V16, @splat(@as(u8, '\r')))),
    );

    // Structural: anything that's not ident, not whitespace, not pure newline.
    // Equivalent to: NOT (ident | space | tab | newline). Conservative —
    // includes punct, op, quote, backtick, hash, backslash.
    const is_sp: B16 = (chunk == @as(V16, @splat(@as(u8, ' ')))) |
                      (chunk == @as(V16, @splat(@as(u8, '\t'))));
    const is_id: u16 = m.ident;
    const is_nl: u16 = m.newline;
    const is_ws: u16 = @bitCast(is_sp);
    m.structural = ~(is_id | is_nl | is_ws);
}

pub fn buildBitmaps(src: []const u8, bm: *Bitmaps) void {
    const n = src.len;
    var pos: usize = 0;
    var word_idx: usize = 0;
    var any_high: u16 = 0;

    while (pos + 64 <= n) : ({ pos += 64; word_idx += 1; }) {
        const c0: V16 = src[pos      ..][0..16].*;
        const c1: V16 = src[pos + 16 ..][0..16].*;
        const c2: V16 = src[pos + 32 ..][0..16].*;
        const c3: V16 = src[pos + 48 ..][0..16].*;
        var m0: ChunkMasks = .{};
        var m1: ChunkMasks = .{};
        var m2: ChunkMasks = .{};
        var m3: ChunkMasks = .{};
        classifyChunk(c0, &m0);
        classifyChunk(c1, &m1);
        classifyChunk(c2, &m2);
        classifyChunk(c3, &m3);
        bm.ident[word_idx]      = @as(u64, m0.ident)      | (@as(u64, m1.ident)      << 16) | (@as(u64, m2.ident)      << 32) | (@as(u64, m3.ident)      << 48);
        bm.newline[word_idx]    = @as(u64, m0.newline)    | (@as(u64, m1.newline)    << 16) | (@as(u64, m2.newline)    << 32) | (@as(u64, m3.newline)    << 48);
        bm.structural[word_idx] = @as(u64, m0.structural) | (@as(u64, m1.structural) << 16) | (@as(u64, m2.structural) << 32) | (@as(u64, m3.structural) << 48);
        // Accumulate has-any-high flag from each chunk in 4× ILP. The
        // compares are independent and run in parallel with the bitmap
        // emit; net Phase 1 cost is one OR per word at the end.
        any_high |= @as(u16, @bitCast(c0 >= @as(V16, @splat(@as(u8, 0x80))))) |
                    @as(u16, @bitCast(c1 >= @as(V16, @splat(@as(u8, 0x80))))) |
                    @as(u16, @bitCast(c2 >= @as(V16, @splat(@as(u8, 0x80))))) |
                    @as(u16, @bitCast(c3 >= @as(V16, @splat(@as(u8, 0x80)))));
    }

    // Tail — process remaining bytes with 16-byte chunks then scalar.
    var tail_ident: u64 = 0;
    var tail_nl: u64 = 0;
    var tail_st: u64 = 0;
    var bit: u6 = 0;
    while (pos < n) : (pos += 1) {
        const b = src[pos];
        if (b >= 0x80) any_high |= 1;
        const is_id =
            (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or b == '_' or b == '$' or b >= 0x80;
        const is_nl = b == '\n' or b == '\r';
        const is_ws = b == ' ' or b == '\t';
        if (is_id) tail_ident |= @as(u64, 1) << bit;
        if (is_nl) tail_nl |= @as(u64, 1) << bit;
        if (!is_id and !is_nl and !is_ws) tail_st |= @as(u64, 1) << bit;
        bit +%= 1;
        if (bit == 0) {
            bm.ident[word_idx]      = tail_ident; tail_ident = 0;
            bm.newline[word_idx]    = tail_nl; tail_nl = 0;
            bm.structural[word_idx] = tail_st; tail_st = 0;
            word_idx += 1;
        }
    }
    if (bit != 0) {
        bm.ident[word_idx]      = tail_ident;
        bm.newline[word_idx]    = tail_nl;
        bm.structural[word_idx] = tail_st;
        word_idx += 1;
    }
    // Zero-fill remaining sentinel words.
    while (word_idx < bm.ident.len) : (word_idx += 1) {
        bm.ident[word_idx]      = 0;
        bm.newline[word_idx]    = 0;
        bm.structural[word_idx] = 0;
    }
    bm.has_high = any_high != 0;

    // LS (U+2028 = E2 80 A8) and PS (U+2029 = E2 80 A9) are LineTerminators,
    // not identifier characters. The SIMD classifier marks all >= 0x80 bytes
    // as ident, so post-correct: clear their ident bits and set the E2 lead
    // byte in the newline bitmap so the dispatch handles them as line breaks.
    if (bm.has_high) {
        var i: usize = 0;
        while (i + 2 < n) {
            if (src[i] == 0xE2 and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) {
                const w0: usize = i / 64;       const b0: u6 = @intCast(i % 64);
                const w1: usize = (i + 1) / 64; const b1: u6 = @intCast((i + 1) % 64);
                const w2: usize = (i + 2) / 64; const b2: u6 = @intCast((i + 2) % 64);
                bm.ident[w0]   &= ~(@as(u64, 1) << b0);
                bm.ident[w1]   &= ~(@as(u64, 1) << b1);
                bm.ident[w2]   &= ~(@as(u64, 1) << b2);
                bm.newline[w0] |=   @as(u64, 1) << b0;
                i += 3;
            } else {
                i += 1;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2: walk visit bitmap. Visit positions are: newline | structural |
// ident_start. Ident_start = bit i in ident set AND bit i-1 NOT set (with
// cross-word carry).  Whitespace and ident-body bytes are skipped.
// ─────────────────────────────────────────────────────────────────────────────

/// Comptime single-char-byte → Tag table. Covers structural bytes whose
/// token is fully determined by the byte alone (no peek, no state). Lets
/// the dispatcher skip the giant switch on the most common path.
/// `.eof` sentinel = "needs full dispatch" (chosen because eof never
/// appears in source, distinct from .invalid which is a real lex result).
const SINGLE_TAG: [256]Tag = blk: {
    var t: [256]Tag = @splat(.eof);
    t['('] = .l_paren;
    t[')'] = .r_paren;
    t['['] = .l_bracket;
    t[']'] = .r_bracket;
    t[';'] = .semicolon;
    t[','] = .comma;
    t['~'] = .tilde;
    t['@'] = .at_sign;
    t[':'] = .colon;
    break :blk t;
};

/// Hand-rolled keyword lookup. Measured: std.StaticStringMap.get takes
/// ~7-8ns per call (~5ms total on typescript.js, 660K idents). Bucketed
/// inline linear scan compiles to a sequence of u64 compare-branch
/// pairs with first-match exit, ~1-2ns hot-path.
const KW = struct { bytes: u64, tag: Tag };

fn pK(comptime s: []const u8) u64 {
    @setEvalBranchQuota(100000);
    var v: u64 = 0;
    for (s, 0..) |c, i| {
        v |= @as(u64, c) << @as(u6, @intCast(i * 8));
    }
    return v;
}

test "pK packing" {
    const c_pK = comptime pK("const");
    const c_load = loadU64("const", 5);
    try std.testing.expectEqual(c_pK, c_load);
}

test "keywordLookup" {
    try std.testing.expectEqual(Tag.kw_const, keywordLookup("const", false));
    try std.testing.expectEqual(Tag.kw_default, keywordLookup("default", false));
    try std.testing.expectEqual(Tag.kw_let, keywordLookup("let", false));
    try std.testing.expectEqual(Tag.kw_var, keywordLookup("var", false));
    try std.testing.expectEqual(Tag.kw_function, keywordLookup("function", false));
    try std.testing.expectEqual(Tag.identifier, keywordLookup("foo", false));
    try std.testing.expectEqual(Tag.kw_type, keywordLookup("type", true));
    try std.testing.expectEqual(Tag.identifier, keywordLookup("type", false));
}

inline fn loadU64(buf: []const u8, comptime L: usize) u64 {
    var v: u64 = 0;
    inline for (0..L) |i| v |= @as(u64, buf[i]) << @as(u6, @intCast(i * 8));
    return v;
}

/// Append a line-start entry for every newline in src[start..end).
/// Used after consuming a token whose body may contain newlines (block
/// comments, template literals, strings with line continuations) — the
/// outer bitmap walk's `skip_until` jumps over the body, so newlines
/// inside have to be registered here or `loc.start.line` will be too
/// low downstream. Mirrors the unicode-line-separator handling in the
/// main lex loop.
fn scanRangeForNewlines(
    ls: *std.ArrayListUnmanaged(u32),
    alloc: std.mem.Allocator,
    src: []const u8,
    start: u32,
    end: u32,
) !void {
    var q: u32 = start;
    // Callers (string/template/comment scanners) sometimes pass an `end` that
    // overshoots `src.len` for unterminated tokens at EOF. Bound the loop by
    // the actual source length so we never index out of range.
    const cap: u32 = @min(end, @as(u32, @intCast(src.len)));
    while (q < cap) : (q += 1) {
        const c = src[q];
        if (c == '\n') {
            try ls.append(alloc, q + 1);
        } else if (c == '\r') {
            const next_q = if (q + 1 < cap and src[q + 1] == '\n') q + 2 else q + 1;
            try ls.append(alloc, next_q);
            q = next_q - 1; // -1 since loop increments
        } else if (c == 0xE2 and q + 2 < cap and src[q + 1] == 0x80 and (src[q + 2] == 0xA8 or src[q + 2] == 0xA9)) {
            try ls.append(alloc, q + 3);
            q += 2;
        }
    }
}

/// Cold helper: load up to 8 bytes from src[p..], zero-padding the rest.
/// Used only for the last 1–2 bitmap words (word_safe = false).
fn safeRaw8(src: []const u8, p: u32, n: u32) u64 {
    var buf: [8]u8 = @splat(0);
    const avail = @min(8, n - p);
    @memcpy(buf[0..avail], src[p .. p + avail]);
    return @bitCast(buf);
}

const KW2_JS = [_]KW{
    .{ .bytes = pK("in"), .tag = .kw_in },
    .{ .bytes = pK("if"), .tag = .kw_if },
    .{ .bytes = pK("do"), .tag = .kw_do },
    .{ .bytes = pK("of"), .tag = .kw_of },
    .{ .bytes = pK("as"), .tag = .kw_as },
};
const KW2_TS = [_]KW{ .{ .bytes = pK("is"), .tag = .kw_is } };

const KW3_JS = [_]KW{
    .{ .bytes = pK("var"), .tag = .kw_var },
    .{ .bytes = pK("let"), .tag = .kw_let },
    .{ .bytes = pK("for"), .tag = .kw_for },
    .{ .bytes = pK("new"), .tag = .kw_new },
    .{ .bytes = pK("try"), .tag = .kw_try },
    .{ .bytes = pK("get"), .tag = .kw_get },
    .{ .bytes = pK("set"), .tag = .kw_set },
};

const KW4_JS = [_]KW{
    .{ .bytes = pK("else"), .tag = .kw_else },
    .{ .bytes = pK("from"), .tag = .kw_from },
    .{ .bytes = pK("case"), .tag = .kw_case },
    .{ .bytes = pK("this"), .tag = .kw_this },
    .{ .bytes = pK("void"), .tag = .kw_void },
    .{ .bytes = pK("with"), .tag = .kw_with },
    .{ .bytes = pK("enum"), .tag = .kw_enum },
    .{ .bytes = pK("null"), .tag = .kw_null },
    .{ .bytes = pK("true"), .tag = .kw_true },
};
const KW4_TS = [_]KW{ .{ .bytes = pK("type"), .tag = .kw_type } };

const KW5_JS = [_]KW{
    .{ .bytes = pK("break"), .tag = .kw_break },
    .{ .bytes = pK("catch"), .tag = .kw_catch },
    .{ .bytes = pK("class"), .tag = .kw_class },
    .{ .bytes = pK("const"), .tag = .kw_const },
    .{ .bytes = pK("super"), .tag = .kw_super },
    .{ .bytes = pK("throw"), .tag = .kw_throw },
    .{ .bytes = pK("while"), .tag = .kw_while },
    .{ .bytes = pK("yield"), .tag = .kw_yield },
    .{ .bytes = pK("async"), .tag = .kw_async },
    .{ .bytes = pK("await"), .tag = .kw_await },
    .{ .bytes = pK("false"), .tag = .kw_false },
};
const KW5_TS = [_]KW{
    .{ .bytes = pK("infer"), .tag = .kw_infer },
    .{ .bytes = pK("keyof"), .tag = .kw_keyof },
};

const KW6_JS = [_]KW{
    .{ .bytes = pK("delete"), .tag = .kw_delete },
    .{ .bytes = pK("export"), .tag = .kw_export },
    .{ .bytes = pK("import"), .tag = .kw_import },
    .{ .bytes = pK("return"), .tag = .kw_return },
    .{ .bytes = pK("switch"), .tag = .kw_switch },
    .{ .bytes = pK("typeof"), .tag = .kw_typeof },
    .{ .bytes = pK("static"), .tag = .kw_static },
};
const KW6_TS = [_]KW{
    .{ .bytes = pK("module"), .tag = .kw_module },
    .{ .bytes = pK("unique"), .tag = .kw_unique },
};

const KW7_JS = [_]KW{
    .{ .bytes = pK("default"), .tag = .kw_default },
    .{ .bytes = pK("extends"), .tag = .kw_extends },
    .{ .bytes = pK("finally"), .tag = .kw_finally },
};
const KW7_TS = [_]KW{
    .{ .bytes = pK("declare"), .tag = .kw_declare },
    .{ .bytes = pK("asserts"), .tag = .kw_asserts },
};

const KW8_JS = [_]KW{
    .{ .bytes = pK("continue"), .tag = .kw_continue },
    .{ .bytes = pK("debugger"), .tag = .kw_debugger },
    .{ .bytes = pK("function"), .tag = .kw_function },
};
const KW8_TS = [_]KW{
    .{ .bytes = pK("readonly"), .tag = .kw_readonly },
    .{ .bytes = pK("abstract"), .tag = .kw_abstract },
    .{ .bytes = pK("override"), .tag = .kw_override },
};

inline fn matchKW(comptime tbl: []const KW, v: u64) ?Tag {
    inline for (tbl) |kw| {
        if (v == kw.bytes) return kw.tag;
    }
    return null;
}

// Precomputed: for each keyword length 2..10, which lowercase first-chars
// map to at least one keyword? Bit i = ('a'+i). Keywords always start with
// lowercase; any other first char → immediate identifier return.
const KW_FC_MASK: [11]u32 = m: {
    var m: [11]u32 = @splat(0);
    const lists = .{
        .{ 2, KW2_JS }, .{ 2, KW2_TS },
        .{ 3, KW3_JS },
        .{ 4, KW4_JS }, .{ 4, KW4_TS },
        .{ 5, KW5_JS }, .{ 5, KW5_TS },
        .{ 6, KW6_JS }, .{ 6, KW6_TS },
        .{ 7, KW7_JS }, .{ 7, KW7_TS },
        .{ 8, KW8_JS }, .{ 8, KW8_TS },
    };
    for (lists) |entry| {
        const l = entry.@"0";
        for (entry.@"1") |kw| {
            const fc: u8 = @truncate(kw.bytes);
            m[l] |= @as(u32, 1) << @as(u5, fc - 'a');
        }
    }
    // len=9: satisfies(s), namespace(n), interface(i)
    m[9] |= (@as(u32, 1) << @as(u5, 's' - 'a')) | (@as(u32, 1) << @as(u5, 'n' - 'a')) | (@as(u32, 1) << @as(u5, 'i' - 'a'));
    // len=10: instanceof(i), implements(i)
    m[10] |= @as(u32, 1) << @as(u5, 'i' - 'a');
    break :m m;
};

/// True when the previous token is a property-access operator.
/// After `.` or `?.`, the next identifier is always a property name —
/// keyword lookup is semantically unnecessary and can be skipped.
inline fn isPropertyAccess(tag: Tag) bool {
    return tag == .dot or tag == .question_dot;
}

pub inline fn keywordLookup(text: []const u8, ts: bool) Tag {
    const len = text.len;
    if (len < 2 or len > 10) return .identifier;
    const fc = text[0];
    if (fc < 'a' or fc > 'z') return .identifier;
    if ((KW_FC_MASK[len] >> @as(u5, @intCast(fc - 'a'))) & 1 == 0) return .identifier;
    // First-char dispatch: after FC_MASK the first char is known to appear in at
    // least one keyword of this length. Use a switch (compiled to a jump table)
    // instead of the old linear matchKW scan — at most 2 comparisons per lookup.
    return switch (len) {
        2 => {
            const v = loadU64(text, 2);
            return switch (fc) {
                'a' => if (v == comptime pK("as")) Tag.kw_as else Tag.identifier,
                'd' => if (v == comptime pK("do")) Tag.kw_do else Tag.identifier,
                'i' => if (v == comptime pK("in")) Tag.kw_in
                        else if (v == comptime pK("if")) Tag.kw_if
                        else if (ts and v == comptime pK("is")) Tag.kw_is
                        else Tag.identifier,
                'o' => if (v == comptime pK("of")) Tag.kw_of else Tag.identifier,
                else => Tag.identifier,
            };
        },
        3 => {
            const v = loadU64(text, 3);
            return switch (fc) {
                'v' => if (v == comptime pK("var")) Tag.kw_var else Tag.identifier,
                'l' => if (v == comptime pK("let")) Tag.kw_let else Tag.identifier,
                'f' => if (v == comptime pK("for")) Tag.kw_for else Tag.identifier,
                'n' => if (v == comptime pK("new")) Tag.kw_new else Tag.identifier,
                't' => if (v == comptime pK("try")) Tag.kw_try else Tag.identifier,
                'g' => if (v == comptime pK("get")) Tag.kw_get else Tag.identifier,
                's' => if (v == comptime pK("set")) Tag.kw_set else Tag.identifier,
                else => Tag.identifier,
            };
        },
        4 => {
            const v = loadU64(text, 4);
            return switch (fc) {
                'c' => if (v == comptime pK("case")) Tag.kw_case else Tag.identifier,
                'e' => switch (text[1]) {
                    'l' => if (v == comptime pK("else")) Tag.kw_else else Tag.identifier,
                    'n' => if (v == comptime pK("enum")) Tag.kw_enum else Tag.identifier,
                    else => Tag.identifier,
                },
                'f' => if (v == comptime pK("from")) Tag.kw_from else Tag.identifier,
                'n' => if (v == comptime pK("null")) Tag.kw_null else Tag.identifier,
                't' => switch (text[1]) {
                    'h' => if (v == comptime pK("this")) Tag.kw_this else Tag.identifier,
                    'r' => if (v == comptime pK("true")) Tag.kw_true else Tag.identifier,
                    'y' => if (ts and v == comptime pK("type")) Tag.kw_type else Tag.identifier,
                    else => Tag.identifier,
                },
                'v' => if (v == comptime pK("void")) Tag.kw_void else Tag.identifier,
                'w' => if (v == comptime pK("with")) Tag.kw_with else Tag.identifier,
                else => Tag.identifier,
            };
        },
        5 => {
            const v = loadU64(text, 5);
            return switch (fc) {
                'a' => switch (text[1]) {
                    's' => if (v == comptime pK("async")) Tag.kw_async else Tag.identifier,
                    'w' => if (v == comptime pK("await")) Tag.kw_await else Tag.identifier,
                    else => Tag.identifier,
                },
                'b' => if (v == comptime pK("break")) Tag.kw_break else Tag.identifier,
                'c' => switch (text[1]) {
                    'a' => if (v == comptime pK("catch")) Tag.kw_catch else Tag.identifier,
                    'l' => if (v == comptime pK("class")) Tag.kw_class else Tag.identifier,
                    'o' => if (v == comptime pK("const")) Tag.kw_const else Tag.identifier,
                    else => Tag.identifier,
                },
                'f' => if (v == comptime pK("false")) Tag.kw_false else Tag.identifier,
                'i' => if (ts and v == comptime pK("infer")) Tag.kw_infer else Tag.identifier,
                'k' => if (ts and v == comptime pK("keyof")) Tag.kw_keyof else Tag.identifier,
                's' => if (v == comptime pK("super")) Tag.kw_super else Tag.identifier,
                't' => if (v == comptime pK("throw")) Tag.kw_throw else Tag.identifier,
                'w' => if (v == comptime pK("while")) Tag.kw_while else Tag.identifier,
                'y' => if (v == comptime pK("yield")) Tag.kw_yield else Tag.identifier,
                else => Tag.identifier,
            };
        },
        6 => {
            const v = loadU64(text, 6);
            return switch (fc) {
                'd' => if (v == comptime pK("delete")) Tag.kw_delete else Tag.identifier,
                'e' => if (v == comptime pK("export")) Tag.kw_export else Tag.identifier,
                'i' => if (v == comptime pK("import")) Tag.kw_import else Tag.identifier,
                'm' => if (ts and v == comptime pK("module")) Tag.kw_module else Tag.identifier,
                'r' => if (v == comptime pK("return")) Tag.kw_return else Tag.identifier,
                's' => switch (text[1]) {
                    'w' => if (v == comptime pK("switch")) Tag.kw_switch else Tag.identifier,
                    't' => if (v == comptime pK("static")) Tag.kw_static else Tag.identifier,
                    else => Tag.identifier,
                },
                't' => if (v == comptime pK("typeof")) Tag.kw_typeof else Tag.identifier,
                'u' => if (ts and v == comptime pK("unique")) Tag.kw_unique else Tag.identifier,
                else => Tag.identifier,
            };
        },
        7 => {
            const v = loadU64(text, 7);
            return switch (fc) {
                'a' => if (ts and v == comptime pK("asserts")) Tag.kw_asserts else Tag.identifier,
                'd' => switch (text[2]) {  // "default"[2]='f', "declare"[2]='c'
                    'f' => if (v == comptime pK("default")) Tag.kw_default else Tag.identifier,
                    'c' => if (ts and v == comptime pK("declare")) Tag.kw_declare else Tag.identifier,
                    else => Tag.identifier,
                },
                'e' => if (v == comptime pK("extends")) Tag.kw_extends else Tag.identifier,
                'f' => if (v == comptime pK("finally")) Tag.kw_finally else Tag.identifier,
                else => Tag.identifier,
            };
        },
        8 => {
            const v = loadU64(text, 8);
            return switch (fc) {
                'a' => if (ts and v == comptime pK("abstract")) Tag.kw_abstract else Tag.identifier,
                'c' => if (v == comptime pK("continue")) Tag.kw_continue else Tag.identifier,
                'd' => if (v == comptime pK("debugger")) Tag.kw_debugger else Tag.identifier,
                'f' => if (v == comptime pK("function")) Tag.kw_function else Tag.identifier,
                'o' => if (ts and v == comptime pK("override")) Tag.kw_override else Tag.identifier,
                'r' => if (ts and v == comptime pK("readonly")) Tag.kw_readonly else Tag.identifier,
                else => Tag.identifier,
            };
        },
        9 => blk: {
            const v8 = loadU64(text, 8);
            const c9 = text[8];
            const KW9_SATISFIE: u64 = pK("satisfie");
            const KW9_NAMESPAC: u64 = pK("namespac");
            const KW9_INTERFAC: u64 = pK("interfac");
            if (ts) {
                if (v8 == KW9_SATISFIE and c9 == 's') break :blk Tag.kw_satisfies;
                if (v8 == KW9_NAMESPAC and c9 == 'e') break :blk Tag.kw_namespace;
                if (v8 == KW9_INTERFAC and c9 == 'e') break :blk Tag.kw_interface;
            }
            break :blk Tag.identifier;
        },
        10 => blk: {
            const v8 = loadU64(text, 8);
            const c9 = text[8];
            const c10 = text[9];
            const KW10_INSTANCE: u64 = pK("instance");
            const KW10_IMPLEMEN: u64 = pK("implemen");
            if (v8 == KW10_INSTANCE and c9 == 'o' and c10 == 'f') break :blk Tag.kw_instanceof;
            if (ts and v8 == KW10_IMPLEMEN and c9 == 't' and c10 == 's') break :blk Tag.kw_implements;
            break :blk Tag.identifier;
        },
        else => Tag.identifier,
    };
}

/// Keyword dispatch given a pre-loaded 8-byte chunk from ptr[0..8].
/// Derives fc from low byte of raw8, using shifts for ptr[1]/ptr[2] disambiguation
/// so the entire hot path (len 2–8) runs from registers after a single load.
/// ptr is only accessed for len=9 (ptr[8]) and len=10 (ptr[8], ptr[9]).
inline fn keywordLookupFromRaw(raw8: u64, ptr: [*]const u8, len: usize, ts: bool) Tag {
    if (len < 2 or len > 10) return .identifier;
    const fc: u8 = @truncate(raw8);
    if (fc < 'a' or fc > 'z') return .identifier;
    if ((KW_FC_MASK[len] >> @as(u5, @intCast(fc - 'a'))) & 1 == 0) return .identifier;
    const c2: u8 = @truncate(raw8 >> 8);   // ptr[1] — from register, no load
    const c3: u8 = @truncate(raw8 >> 16);  // ptr[2] — from register, no load
    return switch (len) {
        2 => {
            const v = raw8 & 0xFFFF;
            return switch (fc) {
                'a' => if (v == comptime pK("as")) Tag.kw_as else Tag.identifier,
                'd' => if (v == comptime pK("do")) Tag.kw_do else Tag.identifier,
                'i' => if (v == comptime pK("in")) Tag.kw_in
                        else if (v == comptime pK("if")) Tag.kw_if
                        else if (ts and v == comptime pK("is")) Tag.kw_is
                        else Tag.identifier,
                'o' => if (v == comptime pK("of")) Tag.kw_of else Tag.identifier,
                else => Tag.identifier,
            };
        },
        3 => {
            const v = raw8 & 0xFFFFFF;
            return switch (fc) {
                'v' => if (v == comptime pK("var")) Tag.kw_var else Tag.identifier,
                'l' => if (v == comptime pK("let")) Tag.kw_let else Tag.identifier,
                'f' => if (v == comptime pK("for")) Tag.kw_for else Tag.identifier,
                'n' => if (v == comptime pK("new")) Tag.kw_new else Tag.identifier,
                't' => if (v == comptime pK("try")) Tag.kw_try else Tag.identifier,
                'g' => if (v == comptime pK("get")) Tag.kw_get else Tag.identifier,
                's' => if (v == comptime pK("set")) Tag.kw_set else Tag.identifier,
                else => Tag.identifier,
            };
        },
        4 => {
            const v = raw8 & 0xFFFFFFFF;
            return switch (fc) {
                'c' => if (v == comptime pK("case")) Tag.kw_case else Tag.identifier,
                'e' => switch (c2) {
                    'l' => if (v == comptime pK("else")) Tag.kw_else else Tag.identifier,
                    'n' => if (v == comptime pK("enum")) Tag.kw_enum else Tag.identifier,
                    else => Tag.identifier,
                },
                'f' => if (v == comptime pK("from")) Tag.kw_from else Tag.identifier,
                'n' => if (v == comptime pK("null")) Tag.kw_null else Tag.identifier,
                't' => switch (c2) {
                    'h' => if (v == comptime pK("this")) Tag.kw_this else Tag.identifier,
                    'r' => if (v == comptime pK("true")) Tag.kw_true else Tag.identifier,
                    'y' => if (ts and v == comptime pK("type")) Tag.kw_type else Tag.identifier,
                    else => Tag.identifier,
                },
                'v' => if (v == comptime pK("void")) Tag.kw_void else Tag.identifier,
                'w' => if (v == comptime pK("with")) Tag.kw_with else Tag.identifier,
                else => Tag.identifier,
            };
        },
        5 => {
            const v = raw8 & 0x000000FFFFFFFFFF;
            return switch (fc) {
                'a' => switch (c2) {
                    's' => if (v == comptime pK("async")) Tag.kw_async else Tag.identifier,
                    'w' => if (v == comptime pK("await")) Tag.kw_await else Tag.identifier,
                    else => Tag.identifier,
                },
                'b' => if (v == comptime pK("break")) Tag.kw_break else Tag.identifier,
                'c' => switch (c2) {
                    'a' => if (v == comptime pK("catch")) Tag.kw_catch else Tag.identifier,
                    'l' => if (v == comptime pK("class")) Tag.kw_class else Tag.identifier,
                    'o' => if (v == comptime pK("const")) Tag.kw_const else Tag.identifier,
                    else => Tag.identifier,
                },
                'f' => if (v == comptime pK("false")) Tag.kw_false else Tag.identifier,
                'i' => if (ts and v == comptime pK("infer")) Tag.kw_infer else Tag.identifier,
                'k' => if (ts and v == comptime pK("keyof")) Tag.kw_keyof else Tag.identifier,
                's' => if (v == comptime pK("super")) Tag.kw_super else Tag.identifier,
                't' => if (v == comptime pK("throw")) Tag.kw_throw else Tag.identifier,
                'w' => if (v == comptime pK("while")) Tag.kw_while else Tag.identifier,
                'y' => if (v == comptime pK("yield")) Tag.kw_yield else Tag.identifier,
                else => Tag.identifier,
            };
        },
        6 => {
            const v = raw8 & 0x0000FFFFFFFFFFFF;
            return switch (fc) {
                'd' => if (v == comptime pK("delete")) Tag.kw_delete else Tag.identifier,
                'e' => if (v == comptime pK("export")) Tag.kw_export else Tag.identifier,
                'i' => if (v == comptime pK("import")) Tag.kw_import else Tag.identifier,
                'm' => if (ts and v == comptime pK("module")) Tag.kw_module else Tag.identifier,
                'r' => if (v == comptime pK("return")) Tag.kw_return else Tag.identifier,
                's' => switch (c2) {
                    'w' => if (v == comptime pK("switch")) Tag.kw_switch else Tag.identifier,
                    't' => if (v == comptime pK("static")) Tag.kw_static else Tag.identifier,
                    else => Tag.identifier,
                },
                't' => if (v == comptime pK("typeof")) Tag.kw_typeof else Tag.identifier,
                'u' => if (ts and v == comptime pK("unique")) Tag.kw_unique else Tag.identifier,
                else => Tag.identifier,
            };
        },
        7 => {
            const v = raw8 & 0x00FFFFFFFFFFFFFF;
            return switch (fc) {
                'a' => if (ts and v == comptime pK("asserts")) Tag.kw_asserts else Tag.identifier,
                'd' => switch (c3) {  // "default"[2]='f', "declare"[2]='c'
                    'f' => if (v == comptime pK("default")) Tag.kw_default else Tag.identifier,
                    'c' => if (ts and v == comptime pK("declare")) Tag.kw_declare else Tag.identifier,
                    else => Tag.identifier,
                },
                'e' => if (v == comptime pK("extends")) Tag.kw_extends else Tag.identifier,
                'f' => if (v == comptime pK("finally")) Tag.kw_finally else Tag.identifier,
                else => Tag.identifier,
            };
        },
        8 => {
            const v = raw8;
            return switch (fc) {
                'a' => if (ts and v == comptime pK("abstract")) Tag.kw_abstract else Tag.identifier,
                'c' => if (v == comptime pK("continue")) Tag.kw_continue else Tag.identifier,
                'd' => if (v == comptime pK("debugger")) Tag.kw_debugger else Tag.identifier,
                'f' => if (v == comptime pK("function")) Tag.kw_function else Tag.identifier,
                'o' => if (ts and v == comptime pK("override")) Tag.kw_override else Tag.identifier,
                'r' => if (ts and v == comptime pK("readonly")) Tag.kw_readonly else Tag.identifier,
                else => Tag.identifier,
            };
        },
        9 => blk: {
            const v8 = raw8;
            const c9 = ptr[8];
            const KW9_SATISFIE: u64 = pK("satisfie");
            const KW9_NAMESPAC: u64 = pK("namespac");
            const KW9_INTERFAC: u64 = pK("interfac");
            if (ts) {
                if (v8 == KW9_SATISFIE and c9 == 's') break :blk Tag.kw_satisfies;
                if (v8 == KW9_NAMESPAC and c9 == 'e') break :blk Tag.kw_namespace;
                if (v8 == KW9_INTERFAC and c9 == 'e') break :blk Tag.kw_interface;
            }
            break :blk Tag.identifier;
        },
        10 => blk: {
            const v8 = raw8;
            const c9 = ptr[8];
            const c10 = ptr[9];
            const KW10_INSTANCE: u64 = pK("instance");
            const KW10_IMPLEMEN: u64 = pK("implemen");
            if (v8 == KW10_INSTANCE and c9 == 'o' and c10 == 'f') break :blk Tag.kw_instanceof;
            if (ts and v8 == KW10_IMPLEMEN and c9 == 't' and c10 == 's') break :blk Tag.kw_implements;
            break :blk Tag.identifier;
        },
        else => Tag.identifier,
    };
}

/// Hot-path keyword lookup. Caller guarantees ptr+8 is readable.
/// Issues a single 8-byte unaligned load then delegates to keywordLookupFromRaw,
/// which derives fc from raw8 and uses register shifts for ptr[1]/ptr[2].
pub inline fn keywordLookupHot(ptr: [*]const u8, len: usize, ts: bool) Tag {
    const raw8 = @as(*align(1) const u64, @ptrCast(ptr)).*;
    return keywordLookupFromRaw(raw8, ptr, len, ts);
}


/// Position of the next set bit at index ≥ `from`, or `n` if none.
/// Used to scan strings / comments / templates against pre-built bitmaps
/// instead of doing a fresh 16-byte SIMD pass.
inline fn nextSetBit(bm: []const u64, from: u32, n: u32) u32 {
    var wi = from / 64;
    if (wi >= bm.len) return n;
    const b: u32 = from % 64;
    var w = bm[wi];
    if (b > 0) {
        const shift: u6 = @intCast(b);
        w &= ~((@as(u64, 1) << shift) - 1);
    }
    while (true) {
        if (w != 0) {
            const off: u32 = @ctz(w);
            const pos: u32 = wi * 64 + off;
            return @min(pos, n);
        }
        wi += 1;
        if (wi >= bm.len) return n;
        w = bm[wi];
    }
}

/// Bitmap-driven line comment scan. Returns position of the LineTerminator
/// that ends the comment (or n if none). Stops at \n, \r, LS (U+2028), or
/// PS (U+2029) — all four are LineTerminators per the ECMAScript spec.
/// `has_high`: set from bm.has_high; when false, no 0x80+ bytes exist so
/// the LS/PS byte scan is unconditionally skipped.
inline fn lineCommentEndBM(newline_bm: []const u64, start: u32, src: []const u8, has_high: bool) u32 {
    const n: u32 = @intCast(src.len);
    const nl = nextSetBit(newline_bm, start, n);
    if (!has_high) return nl;
    // Scan [start..nl) for LS (E2 80 A8) or PS (E2 80 A9).
    var i = start;
    while (i + 2 < nl) : (i += 1) {
        if (src[i] == 0xE2 and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) return i;
    }
    return nl;
}

/// Bitmap-driven string scan. Walks structural|newline (both contain quote
/// and backslash; newline terminates an unterminated string). Returns
/// `end` such that the string token spans [open .. end).
pub fn stringEndBM(
    src: []const u8,
    structural_bm: []const u64,
    newline_bm: []const u64,
    open: u32,
    n: u32,
) u32 {
    return stringEndBMOpt(src, structural_bm, newline_bm, open, n, false);
}

/// JSX-aware string scanner. Two orthogonal flags:
///   `is_jsx` — JSX context (inside the file's JSX, not inside `{...}` braces).
///     Terminates the string at `<` (so `<>I'm</>` doesn't swallow `'m</>`),
///     and allows newlines inside the string (JSX attribute strings legally
///     span multiple lines, e.g. `<path d="M0 0\n L 10 10">`).
///   `jsx_no_escape` — JSX attribute string (`<div attr="x\"`/>`). In JSX,
///     `\` is a literal character, so the first `"` after `\` closes the
///     string. JS strings (including those inside `{...}`) follow standard
///     escape rules and consume `\<next>` as one unit.
pub fn stringEndBMOpt(
    src: []const u8,
    structural_bm: []const u64,
    newline_bm: []const u64,
    open: u32,
    n: u32,
    is_jsx: bool,
) u32 {
    return stringEndBMOptFull(src, structural_bm, newline_bm, open, n, is_jsx, is_jsx);
}

/// Underlying implementation with separate JSX-context and no-escape flags.
pub fn stringEndBMOptFull(
    src: []const u8,
    structural_bm: []const u64,
    newline_bm: []const u64,
    open: u32,
    n: u32,
    is_jsx: bool,
    jsx_no_escape: bool,
) u32 {
    const quote = src[open];
    var i: u32 = open + 1;
    while (i < n) {
        // Find next interesting byte (quote, backslash, or newline).
        var wi = i / 64;
        if (wi >= structural_bm.len) return n;
        const b: u32 = i % 64;
        var hits = (structural_bm[wi] | newline_bm[wi]);
        if (b > 0) {
            const shift: u6 = @intCast(b);
            hits &= ~((@as(u64, 1) << shift) - 1);
        }
        while (true) {
            if (hits != 0) {
                const off: u32 = @ctz(hits);
                const p = wi * 64 + off;
                if (p >= n) return n;
                const c = src[p];
                if (c == quote) return p + 1;
                if (is_jsx and c == '<') return p;
                // JSX attribute strings (`<path d="M230 80\n\tA ...">`) span
                // newlines. JS strings don't, but a JSX-mode source has no
                // ambiguity here: the parser still classifies string usage,
                // and JS-style fixtures live in non-JSX languages anyway.
                if (is_jsx and (c == '\n' or c == '\r')) {
                    hits &= hits - 1;
                    continue;
                }
                if (c == '\\') {
                    // JSX attribute strings don't support escape sequences — `\` is
                    // a literal character. So `<div attr="x\"`/>` ends at the first
                    // `"`. JS strings (including those inside JSX `{...}`) escape.
                    if (jsx_no_escape) {
                        i = p + 1;
                        break;
                    }
                    // JS line continuation: \<CRLF>, \<LS>, \<PS> consume the
                    // entire line-terminator sequence. Other escapes consume
                    // a single byte after the backslash.
                    if (p + 2 < n and src[p + 1] == '\r' and src[p + 2] == '\n') {
                        i = p + 3;
                    } else if (p + 3 < n and src[p + 1] == 0xE2 and src[p + 2] == 0x80 and
                               (src[p + 3] == 0xA8 or src[p + 3] == 0xA9))
                    {
                        i = p + 4;
                    } else {
                        i = p + 2;
                    }
                    break;
                }
                if (c == '\n' or c == '\r') return p;
                // other structural byte — irrelevant in string body, clear and continue.
                hits &= hits - 1;
                continue;
            }
            wi += 1;
            if (wi >= structural_bm.len) return n;
            hits = structural_bm[wi] | newline_bm[wi];
        }
    }
    return @max(i, n);
}

/// Bitmap-driven block comment scan. Walks structural for `*` candidates,
/// newline for has_nl tracking. Returns end (after `*/`) and whether a
/// newline lies within the comment body.
/// `has_high`: set from bm.has_high; when false, the LS/PS byte scans are skipped.
pub fn blockCommentEndBM(
    src: []const u8,
    structural_bm: []const u64,
    newline_bm: []const u64,
    open: u32,
    n: u32,
    has_high: bool,
) struct { end: u32, has_nl: bool } {
    const i: u32 = open + 2;
    var has_nl = false;
    // First detect if any newline exists in [open+2 .. eventual end). We check
    // incrementally as we walk.
    while (i < n) {
        var wi = i / 64;
        if (wi >= structural_bm.len) return .{ .end = n, .has_nl = has_nl };
        const b: u32 = i % 64;
        var hits = structural_bm[wi];
        var nl_word = newline_bm[wi];
        if (b > 0) {
            const shift: u6 = @intCast(b);
            const mask = ~((@as(u64, 1) << shift) - 1);
            hits &= mask;
            nl_word &= mask;
        }
        while (true) {
            if (hits != 0) {
                const off: u32 = @ctz(hits);
                const p = wi * 64 + off;
                if (p >= n) return .{ .end = n, .has_nl = has_nl };
                if (src[p] == '*' and p + 1 < n and src[p + 1] == '/') {
                    // Check newlines before p in current word.
                    if (nl_word != 0) {
                        const before_mask: u64 = (@as(u64, 1) << @intCast(p % 64)) - 1;
                        if ((nl_word & before_mask) != 0) has_nl = true;
                    }
                    // Check for LS/PS in bytes [word_start..p).
                    if (has_high and !has_nl) {
                        const word_start2: u32 = @intCast(wi * 64);
                        var scan2: u32 = if (word_start2 < i) i else word_start2;
                        while (scan2 + 2 < p) : (scan2 += 1) {
                            if (src[scan2] == 0xE2 and src[scan2 + 1] == 0x80 and (src[scan2 + 2] == 0xA8 or src[scan2 + 2] == 0xA9)) { has_nl = true; break; }
                        }
                    }
                    return .{ .end = p + 2, .has_nl = has_nl };
                }
                hits &= hits - 1;
                continue;
            }
            // No more candidates in this word. Check if newlines exist in remainder.
            if (nl_word != 0) has_nl = true;
            // Also check for LS/PS in this word's bytes.
            if (has_high and !has_nl) {
                const ws: u32 = @intCast(wi * 64);
                var sc: u32 = if (ws < i) i else ws;
                const we: u32 = @min(ws + 64, n);
                while (sc + 2 < we) : (sc += 1) {
                    if (src[sc] == 0xE2 and src[sc + 1] == 0x80 and (src[sc + 2] == 0xA8 or src[sc + 2] == 0xA9)) { has_nl = true; break; }
                }
            }
            wi += 1;
            if (wi >= structural_bm.len) return .{ .end = n, .has_nl = has_nl };
            hits = structural_bm[wi];
            nl_word = newline_bm[wi];
        }
    }
    return .{ .end = n, .has_nl = has_nl };
}

/// Find ident run end starting at bit `start_bit` of word `wi` using the
/// pre-built ident bitmap. Avoids re-scanning bytes — `@ctz(~tail)` over
/// 64-bit words is essentially free (no SIMD). Falls back to scalar scan
/// only if the run reaches end of bitmap.
pub inline fn identEndFromBitmap(
    ident_bm: []const u64,
    wi_in: usize,
    start_bit: u32,
    word_off_in: u32,
    n: u32,
) u32 {
    return identEndFromBitmapW(ident_bm, ident_bm[wi_in], wi_in, start_bit, word_off_in, n);
}

// Hot variant: caller passes the already-loaded ident_bm[wi_in] to avoid
// a redundant memory load when the caller has it in a register.
pub inline fn identEndFromBitmapW(
    ident_bm: []const u64,
    w0: u64,
    wi_in: usize,
    start_bit: u32,
    word_off_in: u32,
    n: u32,
) u32 {
    const max_in_word: u32 = 64 - start_bit;
    const tail = w0 >> @intCast(start_bit);
    const ctz_inv: u32 = @ctz(~tail);
    if (ctz_inv < max_in_word) {
        return word_off_in + start_bit + ctz_inv;
    }
    // Run extends to end of word; scan next words for first 0-bit.
    var len: u32 = max_in_word;
    var wj = wi_in + 1;
    while (wj < ident_bm.len) : (wj += 1) {
        const w = ident_bm[wj];
        const inv2 = ~w;
        if (inv2 == 0) {
            len += 64;
        } else {
            len += @intCast(@ctz(inv2));
            const end_pos = word_off_in + start_bit + len;
            return @min(end_pos, n);
        }
    }
    return n;
}

/// Validate a numeric literal token [start..end) in src.
/// Returns true if valid, false if it's a syntax error.
/// Checks:
///  - 0x/0b/0o/0X/0B/0O must have at least one digit after the prefix
///  - No trailing _ separator (last digit before optional 'n' cannot be '_')
///  - No leading _ after prefix
///  - No double __ separator
///  - Exponent part (e/E) must have at least one digit after optional sign
///  - Number literal immediately followed by IdentifierStart is a syntax error
///    (caller checks this separately via next-byte inspection)
fn validateNumericLiteral(src: []const u8, start: u32, end: u32) bool {
    if (start >= end) return false;
    var i = start;
    // BigInt suffix: strip trailing 'n' for validation.
    const is_bigint = end > start and src[end - 1] == 'n';
    const val_end: u32 = if (is_bigint) end - 1 else end;

    if (src[i] == '0' and i + 1 < val_end) {
        switch (src[i + 1]) {
            'x', 'X', 'b', 'B', 'o', 'O' => {
                const prefix_end = i + 2;
                if (prefix_end >= val_end) return false; // 0x/0b/0o with no digits
                // No leading _ after prefix.
                if (src[prefix_end] == '_') return false;
                // No trailing _ before optional 'n'.
                if (src[val_end - 1] == '_') return false;
                // No double __.
                var j = prefix_end;
                while (j < val_end) : (j += 1) {
                    if (src[j] == '_' and j + 1 < val_end and src[j + 1] == '_') return false;
                }
                return true;
            },
            '0'...'9' => {
                // Legacy-octal-like or non-octal-decimal: `0` followed by more digits.
                // BigInt `n` suffix NOT allowed.
                if (is_bigint) return false;
                // No separator `_` allowed in the integer part.
                var j = start;
                while (j < val_end and src[j] != '.' and src[j] != 'e' and src[j] != 'E') : (j += 1) {
                    if (src[j] == '_') return false;
                }
                // Pure integer (no fractional/exponent): done.
                if (j >= val_end) return true;
                // Has fractional/exponent — validate those parts via decimal rules below.
                i = j;
            },
            '_' => {
                // `0_...` — leading separator after `0` not allowed.
                return false;
            },
            else => {},
        }
    }

    // BigInt cannot have decimal point or exponent.
    if (is_bigint) {
        // Already stripped 'n'. Check val_end chars for '.' or 'e'/'E'.
        var j = start;
        while (j < val_end) : (j += 1) {
            if (src[j] == '.' or src[j] == 'e' or src[j] == 'E') return false;
        }
    }

    // Decimal literal validation.
    // Check for leading _ (separator cannot be first digit).
    if (i < val_end and src[i] == '_') return false;
    // Scan integer part.
    while (i < val_end and src[i] != '.' and src[i] != 'e' and src[i] != 'E') : (i += 1) {}
    // Check no trailing _ in integer part.
    if (i > start and src[i - 1] == '_') return false;
    // Decimal point.
    if (i < val_end and src[i] == '.') {
        i += 1; // skip '.'
        if (i < val_end and src[i] == '_') return false; // leading _ after .
        while (i < val_end and src[i] != 'e' and src[i] != 'E') : (i += 1) {}
        if (i > start + 1 and src[i - 1] == '_') return false; // trailing _ before exponent
    }
    // Exponent.
    if (i < val_end and (src[i] == 'e' or src[i] == 'E')) {
        i += 1;
        if (i < val_end and (src[i] == '+' or src[i] == '-')) i += 1;
        // Must have at least one digit after 'e' or 'e+/-'.
        if (i >= val_end) return false;
        if (src[i] < '0' or src[i] > '9') return false;
        // No leading _.
        if (src[i] == '_') return false;
        while (i < val_end) : (i += 1) {}
        if (val_end > start and src[val_end - 1] == '_') return false;
    }
    // Check for double __ anywhere.
    var j = start;
    while (j + 1 < val_end) : (j += 1) {
        if (src[j] == '_' and src[j + 1] == '_') return false;
    }
    return true;
}

/// Returns true if byte `b` can be the start of an identifier (ASCII) or is a high byte
/// that might start a Unicode identifier continuation. Used to detect "number followed by
/// IdentifierStart" syntax errors.
inline fn isIdentStart(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '_', '$', '\\', 0x80...0xFF => true,
        else => false,
    };
}

/// Returns true if the character at src[pos] is an ECMAScript IdentifierStart
/// (properly decoding multi-byte UTF-8 sequences). Used to detect illegal
/// numeric literal followed by IdentifierStart.
fn isIdentStartAtPos(src: []const u8, pos: u32) bool {
    if (pos >= src.len) return false;
    const b = src[pos];
    // ASCII identifier start characters.
    if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_' or b == '$' or b == '\\') return true;
    // Digit: not an id start.
    if (b >= '0' and b <= '9') return false;
    // High byte: decode and check ID_Start.
    if (b >= 0x80) {
        const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(b) catch return false);
        const n: u32 = @intCast(src.len);
        if (pos + cl > n) return false;
        const cp = std.unicode.utf8Decode(src[pos..pos+cl]) catch return false;
        // LS/PS are line terminators, not identifier starts.
        if (cp == 0x2028 or cp == 0x2029) return false;
        // BOM: not an identifier start.
        if (cp == 0xFEFF) return false;
        // Unicode whitespace (Zs): not identifier starts.
        if (isUnicodeWhitespace(cp)) return false;
        // Check ID_Start.
        if (cp < 0x80) return true; // ASCII already handled
        return @import("unicode_id.zig").isIdStart(cp);
    }
    return false;
}

/// Returns true for Unicode codepoints that ECMAScript treats as WhiteSpace
/// but are not ASCII (so they slip through Phase 1 as ident-class bytes).
/// Covers: NBSP (U+00A0), Zs category chars (U+1680, U+2000-U+200A, U+202F,
/// U+205F, U+3000), and ZWNBSP (U+FEFF — already handled as BOM).
inline fn isUnicodeWhitespace(cp: u32) bool {
    return switch (cp) {
        0x0085 => true, // NEL (NEXT LINE) — TypeScript treats as whitespace/line-terminator
        0x00A0 => true, // NO-BREAK SPACE
        0x1680 => true, // OGHAM SPACE MARK
        0x2000...0x200A => true, // EN QUAD .. HAIR SPACE
        0x202F => true, // NARROW NO-BREAK SPACE
        0x205F => true, // MEDIUM MATHEMATICAL SPACE
        0x3000 => true, // IDEOGRAPHIC SPACE
        0xFEFF => true, // ZERO WIDTH NO-BREAK SPACE (already handled but safe to include)
        else => false,
    };
}

pub fn tokenizeWithBuf(
    alloc: std.mem.Allocator,
    source: []const u8,
    language: Language,
    opts: TokenizeOptions,
    tokens_buf: ?*TokenList,
) !TokenizeResult {
    return tokenizeWithBufAndBitmaps(alloc, source, language, opts, tokens_buf, null);
}

/// Variant that accepts a caller-provided pre-built bitmap. When non-null,
/// skips Phase 1 (bitmap construction) — useful when the bitmap was already
/// built upstream by an out-of-band caller.
pub fn tokenizeWithBufAndBitmaps(
    alloc: std.mem.Allocator,
    source: []const u8,
    language: Language,
    opts: TokenizeOptions,
    tokens_buf: ?*TokenList,
    pre_bm: ?*const Bitmaps,
) !TokenizeResult {
    _ = opts.annex_b;
    const src = source;
    const n: u32 = @intCast(src.len);

    // Initial cap empirically covers ~99.9% of real-world files (typescript.js
    // peaks at 0.15 tok/byte; n/4 = 4× headroom). Pathological all-punct
    // files (e.g. `;;;;…`) can exceed; we double-and-grow on overflow.
    var cap: u32 = @max(n / 4 + 128, 128);
    var tokens: TokenList = if (tokens_buf) |b| b.* else TokenList{};
    if (tokens_buf == null) try tokens.ensureTotalCapacity(alloc, cap);
    var ts_init = tokens.slice();
    var tag_ptr   = ts_init.items(.tag).ptr;
    var start_ptr = ts_init.items(.start).ptr;
    var len_ptr   = ts_init.items(.len).ptr;
    var nl_ptr    = ts_init.items(.has_newline_before).ptr;
    var esc_ptr   = ts_init.items(.has_unicode_escape).ptr;
    // Zero escape array — most tokens have no unicode escapes; only the rare
    // \u-escape identifier paths write `true` below.
    @memset(esc_ptr[0..tokens.capacity], false);
    var tok_n: usize = 0;
    const cm_cap: u32 = @max(n / 200 + 16, 16);
    var cm_s = try std.ArrayListUnmanaged(u32).initCapacity(alloc, cm_cap);
    var cm_e = try std.ArrayListUnmanaged(u32).initCapacity(alloc, cm_cap);
    var cm_k = try std.ArrayListUnmanaged(u8 ).initCapacity(alloc, cm_cap);
    var ls = try std.ArrayListUnmanaged(u32).initCapacity(alloc, @max(n / 30 + 16, 16));
    try ls.append(alloc, 0);

    // ── Phase 1: build bitmaps (or use caller's) ────────────────────────────
    var owned_bm: Bitmaps = undefined;
    var bm_owned = false;
    const bm: *const Bitmaps = blk: {
        if (pre_bm) |existing| break :blk existing;
        owned_bm = try Bitmaps.init(alloc, n);
        bm_owned = true;
        buildBitmaps(src, &owned_bm);
        break :blk &owned_bm;
    };
    defer if (bm_owned) owned_bm.deinit(alloc);

    // ── Phase 2: walk visit bitmap = newline | structural | ident_starts ──
    var prev_kind: Tag  = .eof;
    // JSX opening-tag tracking (JSX languages only). `jsx_tag_depth` counts how many
    // JSX opening-tag headers (`<Foo ...`) we are currently inside; `jsx_brace_nest`
    // counts `{...}` nesting within a tag header so a `>` inside an attribute
    // expression (`<a b={x > y}>`) doesn't prematurely close the header. Lets the
    // string scanner distinguish a JSX attribute `=` (no-escape) from an assignment
    // `=` (standard JS escapes) — `prev_kind == .equal` alone cannot, since both look
    // like `identifier = string`.
    var jsx_tag_depth: u32 = 0;
    var jsx_brace_nest: u32 = 0;
    var saw_nl:   bool  = false;
    // Tracks whether we are at the logical start of a line (for Annex B --> comment).
    // True at start of file; set true after any newline; cleared when a real token is emitted.
    var at_line_start: bool = true;

    var tmpl_depth: u32 = 0;
    var brace_d: [16]u32 = @splat(0);

    var prev_ident_last_bit: u64 = 0;
    // Cursor: any visit bit at pos < skip_until is dropped. Set after every
    // range-consuming operation (idents, comments, strings, templates,
    // regex, BOM, line/para separators).
    var skip_until: u32 = 0;
    // Set to true ONLY when skip_until lands inside an ident-bitmap-run
    // (BOM/LS/PS skips, mid-ident number ends). The drain at top of inner
    // loop runs only when this is set — avoiding 1.3M unnecessary checks.

    // Word-by-word walk.
    var wi: usize = 0;
    while (wi < bm.ident.len) : (wi += 1) {
        if (tok_n + 1024 > cap) {
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
        const w_id = bm.ident[wi];
        const w_nl = bm.newline[wi];
        const w_st = bm.structural[wi];
        // ident_starts: bit set where a new ident run begins.
        const id_starts = w_id & ~((w_id << 1) | prev_ident_last_bit);
        prev_ident_last_bit = (w_id >> 63) & 1;
        const word_off: u32 = @intCast(wi * 64);
        // word_safe: every p in this word satisfies p+3 < n (worst-case operator lookahead).
        // True for all words except the last 1–2; set once per word, used in structural dispatch.
        const word_safe: bool = (word_off + 67 <= n);
        // Fast-forward whole words covered by skip_until.
        if (skip_until >= word_off + 64) continue;
        var visit = w_nl | w_st | id_starts;
        // Drop bits < (skip_until - word_off) within this word.
        if (skip_until > word_off) {
            const shift: u6 = @intCast(skip_until - word_off);
            visit &= ~@as(u64, 0) << shift;
        }

        while (visit != 0) {
            const b: u32 = @ctz(visit);
            visit &= visit - 1;
            const p: u32 = word_off + b;
            if (p >= n) break;
            if (p < skip_until) continue;
            const byte = src[p];
            if ((w_nl >> @intCast(b)) & 1 != 0) {
                @branchHint(.unlikely);
                saw_nl = true;
                at_line_start = true;
                if (byte == '\n') {
                    try ls.append(alloc, p + 1);
                } else if (byte == '\r') {
                    if (p + 1 < n and src[p + 1] == '\n') {
                        try ls.append(alloc, p + 2);
                        // CRLF is a single line terminator — skip the trailing
                        // `\n` so the next iteration doesn't append again.
                        skip_until = p + 2;
                    } else {
                        try ls.append(alloc, p + 1);
                    }
                } else {
                    // LS (U+2028, E2 80 A8) or PS (U+2029, E2 80 A9): lead byte set in
                    // newline bitmap by buildBitmaps; continuation bytes cleared from ident.
                    skip_until = p + 3;
                    try ls.append(alloc, p + 3);
                }
                continue;
            }

            // Ident-start: scan run end. Phase 1's ident bitmap conflates
            // letters, digits, and high bytes — all valid ident-CONTINUATION
            // chars. JS ident-START rules differ: digits start numbers, high
            // bytes can start idents but need separate handling for BOM/LS/PS.
            if ((id_starts >> @intCast(b)) & 1 != 0) {
                var tag: Tag = undefined;
                var end: u32 = undefined;
                var is_escaped_id: bool = false; // set true when identifier has \u escapes
                switch (byte) {
                    '0'...'9' => {
                        end = Lex.numberEnd(src, p);
                        const is_bn = end > p and src[end - 1] == 'n';
                        // Validate numeric literal.
                        if (!validateNumericLiteral(src, p, end)) {
                            tag = .invalid;
                        } else if (end < n and isIdentStartAtPos(src, end)) {
                            // Number immediately followed by IdentifierStart or DecimalDigit → syntax error.
                            tag = .invalid;
                        } else {
                            tag = if (is_bn) .bigint_literal else .number_literal;
                        }
                    },
                    0x80...0xFF => {
                        var skip_to: u32 = 0;
                        if (byte == 0xE2 and p + 2 < n and src[p + 1] == 0x80 and (src[p + 2] == 0xA8 or src[p + 2] == 0xA9)) {
                            saw_nl = true;
                            skip_to = p + 3;
                        } else if (byte == 0xEF and p + 2 < n and src[p + 1] == 0xBB and src[p + 2] == 0xBF) {
                            skip_to = p + 3;
                        }
                        if (skip_to != 0) {
                            skip_until = skip_to;
                            // Inline drain: BOM/LS may end inside ident-bitmap-run (e.g.
                            // BOM followed by `var`). Without this, the next ident is
                            // never visited (its predecessor bit is set in ident bitmap).
                            while (skip_until < n) {
                                const sw = skip_until / 64;
                                if (sw >= bm.ident.len) break;
                                const sb: u32 = skip_until % 64;
                                if (((bm.ident[sw] >> @intCast(sb)) & 1) == 0) break;
                                const tail_byte = src[skip_until];
                                var tt: Tag = undefined;
                                var te: u32 = undefined;
                                if (tail_byte == 0xE2 and skip_until + 2 < n and src[skip_until + 1] == 0x80 and (src[skip_until + 2] == 0xA8 or src[skip_until + 2] == 0xA9)) {
                                    saw_nl = true;
                                    skip_until = skip_until + 3;
                                    continue;
                                }
                                if (tail_byte == 0xEF and skip_until + 2 < n and src[skip_until + 1] == 0xBB and src[skip_until + 2] == 0xBF) {
                                    skip_until = skip_until + 3;
                                    continue;
                                }
                                switch (tail_byte) {
                                    '0'...'9' => {
                                        te = Lex.numberEnd(src, skip_until);
                                        const is_bn3 = te > skip_until and src[te - 1] == 'n';
                                        if (!validateNumericLiteral(src, skip_until, te) or (te < n and isIdentStartAtPos(src, te))) {
                                            tt = .invalid;
                                        } else {
                                            tt = if (is_bn3) .bigint_literal else .number_literal;
                                        }
                                    },
                                    0x80...0xFF => {
                                        te = identEndFromBitmap(bm.ident, sw, sb, sw * 64, n);
                                        tt = .identifier;
                                    },
                                    else => {
                                        te = identEndFromBitmap(bm.ident, sw, sb, sw * 64, n);
                                        tt = if (isPropertyAccess(prev_kind)) .identifier else keywordLookup(src[skip_until..te], language.isTs());
                                    },
                                }
                                tag_ptr[tok_n] = tt;
                                start_ptr[tok_n] = skip_until;
                                len_ptr[tok_n] = te - skip_until;
                                nl_ptr[tok_n] = saw_nl;
                                tok_n += 1;
                                saw_nl = false;

                                prev_kind = if (tt.isKeyword() and isPropertyAccess(prev_kind)) .identifier else tt;
                                skip_until = te;
                            }
                            continue;
                        }
                        // Validate ID_Start for the leading codepoint.
                        const uid2 = @import("unicode_id.zig");
                        const start_len: u32 = @intCast(std.unicode.utf8ByteSequenceLength(byte) catch 1);
                        if (p + start_len > n) {
                            // Truncated sequence at EOF: skip it.
                            skip_until = p + 1;
                            if (p + 1 < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(p + 1 - word_off)); } else { visit = 0; }
                            continue;
                        } else {
                            const start_cp = std.unicode.utf8Decode(src[p..p+start_len]) catch 0;
                            if (!uid2.isIdStart(@intCast(start_cp))) {
                                // Not an ID_Start. Check if it's a Unicode whitespace (Zs etc.)
                                // — these should be silently skipped, not emitted as .invalid.
                                if (isUnicodeWhitespace(@intCast(start_cp))) {
                                    skip_until = p + start_len;
                                    // Drain: the byte immediately after whitespace may have lost
                                    // its id_start bit (because its predecessor byte was ident-class).
                                    // Emit any immediately following ident tokens here.
                                    while (skip_until < n) {
                                        const sw = skip_until / 64;
                                        if (sw >= bm.ident.len) break;
                                        const sb: u32 = skip_until % 64;
                                        if (((bm.ident[sw] >> @intCast(sb)) & 1) == 0) break;
                                        const tail_byte = src[skip_until];
                                        var tt: Tag = undefined;
                                        var te: u32 = undefined;
                                        if (tail_byte == 0xE2 and skip_until + 2 < n and src[skip_until + 1] == 0x80 and (src[skip_until + 2] == 0xA8 or src[skip_until + 2] == 0xA9)) {
                                            saw_nl = true;
                                            at_line_start = true;
                                            skip_until = skip_until + 3;
                                            continue;
                                        }
                                        if (tail_byte == 0xEF and skip_until + 2 < n and src[skip_until + 1] == 0xBB and src[skip_until + 2] == 0xBF) {
                                            skip_until = skip_until + 3;
                                            continue;
                                        }
                                        // Another Unicode high byte: check if whitespace (skip) or ident.
                                        if (tail_byte >= 0x80) {
                                            const t_cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(tail_byte) catch 1);
                                            if (skip_until + t_cl <= n) {
                                                const t_cp = std.unicode.utf8Decode(src[skip_until..skip_until+t_cl]) catch 0;
                                                if (isUnicodeWhitespace(t_cp)) {
                                                    skip_until += t_cl;
                                                    continue;
                                                }
                                                if (!uid2.isIdStart(t_cp)) {
                                                    // Not a valid ident start — stop draining.
                                                    break;
                                                }
                                            }
                                            te = identEndFromBitmap(bm.ident, sw, sb, sw * 64, n);
                                            tt = .identifier;
                                        } else {
                                            switch (tail_byte) {
                                                '0'...'9' => {
                                                    te = Lex.numberEnd(src, skip_until);
                                                    const is_bnd = te > skip_until and src[te - 1] == 'n';
                                                    if (!validateNumericLiteral(src, skip_until, te) or (te < n and isIdentStartAtPos(src, te))) {
                                                        tt = .invalid;
                                                    } else {
                                                        tt = if (is_bnd) .bigint_literal else .number_literal;
                                                    }
                                                },
                                                else => {
                                                    te = identEndFromBitmap(bm.ident, sw, sb, sw * 64, n);
                                                    tt = if (isPropertyAccess(prev_kind)) .identifier else keywordLookup(src[skip_until..te], language.isTs());
                                                },
                                            }
                                        }
                                        tag_ptr[tok_n] = tt;
                                        start_ptr[tok_n] = skip_until;
                                        len_ptr[tok_n] = te - skip_until;
                                        nl_ptr[tok_n] = saw_nl;
                                        tok_n += 1;
                                        saw_nl = false;
                                        at_line_start = false;
                                        prev_kind = if (tt.isKeyword() and isPropertyAccess(prev_kind)) .identifier else tt;
                                        skip_until = te;
                                    }
                                    continue;
                                }
                                end = p + start_len; tag = .invalid;
                            } else {
                                end = identEndFromBitmapW(bm.ident, w_id, wi, b, word_off, n);
                                // Re-validate: strip trailing codepoints that are not ID_Continue.
                                // ASCII chars (a-z, A-Z, 0-9, _, $) are always valid ident-continue;
                                // only check non-ASCII chars via unicode_id tables.
                                var trim_end = end;
                                while (trim_end > p + start_len) {
                                    var back = trim_end - 1;
                                    while (back > p and src[back] & 0xC0 == 0x80) back -= 1;
                                    const back_byte = src[back];
                                    if (back_byte < 0x80) {
                                        // ASCII ident char: always valid ID_Continue in JS.
                                        break;
                                    }
                                    const bl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(back_byte) catch 1);
                                    const bcp = std.unicode.utf8Decode(src[back..back+bl]) catch 0;
                                    if (uid2.isIdContinueJS(@intCast(bcp))) break;
                                    trim_end = back;
                                }
                                end = trim_end;
                                // Extend: check for \u escape continuation after ident run.
                                while (end < n and src[end] == '\\' and end + 1 < n and src[end + 1] == 'u') {
                                    var ec_end: u32 = end + 2;
                                    var ec_cp: u32 = 0;
                                    var ok: bool = true;
                                    if (ec_end < n and src[ec_end] == '{') {
                                        ec_end += 1;
                                        while (ec_end < n and src[ec_end] != '}') : (ec_end += 1) {
                                            const h = src[ec_end];
                                            ec_cp = (ec_cp << 4) | switch (h) {
                                                '0'...'9' => h - '0',
                                                'a'...'f' => h - 'a' + 10,
                                                'A'...'F' => h - 'A' + 10,
                                                else => blk: { ok = false; break :blk 0; },
                                            };
                                        }
                                        if (ec_end >= n or src[ec_end] != '}') { ok = false; } else { ec_end += 1; }
                                    } else if (ec_end + 4 <= n) {
                                        for (0..4) |_| {
                                            const h = src[ec_end];
                                            ec_cp = (ec_cp << 4) | switch (h) {
                                                '0'...'9' => h - '0',
                                                'a'...'f' => h - 'a' + 10,
                                                'A'...'F' => h - 'A' + 10,
                                                else => blk: { ok = false; break :blk 0; },
                                            };
                                            ec_end += 1;
                                        }
                                    } else { ok = false; }
                                    if (!ok) break;
                                    const ec_ok2 = if (ec_cp < 0x80) ((ec_cp >= 'a' and ec_cp <= 'z') or (ec_cp >= 'A' and ec_cp <= 'Z') or (ec_cp >= '0' and ec_cp <= '9') or ec_cp == '_' or ec_cp == '$') else uid2.isIdContinueJS(ec_cp);
                                    if (!ec_ok2) break;
                                    end = ec_end;
                                    // Scan ASCII/high-byte continuation after escape.
                                    while (end < n) {
                                        const cc = src[end];
                                        if ((cc >= 'a' and cc <= 'z') or (cc >= 'A' and cc <= 'Z') or (cc >= '0' and cc <= '9') or cc == '_' or cc == '$') { end += 1; continue; }
                                        if (cc >= 0x80) {
                                            const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(cc) catch 1);
                                            if (end + cl <= n) {
                                                const cont_cp = std.unicode.utf8Decode(src[end..end+cl]) catch 0;
                                                if (uid2.isIdContinueJS(@intCast(cont_cp))) { end += cl; continue; }
                                            }
                                        }
                                        break;
                                    }
                                }
                                tag = .identifier;
                            }
                        }
                    },
                    else => {
                        // Hoist 8-byte load before identEndFromBitmapW — p is known, end is not.
                        // The load and the bitmap CTZ are independent: OOO cores overlap them,
                        // hiding ~4 cycles of load latency before keywordLookupFromRaw needs raw8.
                        const ident_hot = p + 8 <= n;
                        const ident_raw8: u64 = if (ident_hot) @as(*align(1) const u64, @ptrCast(src.ptr + p)).* else 0;
                        end = identEndFromBitmapW(bm.ident, w_id, wi, b, word_off, n);
                        const ident_bm_end = end; // position after pure-bitmap run; used below for has_escape
                        // Extend identifier if followed by \u escape continuation.
                        while (end < n and src[end] == '\\' and end + 1 < n and src[end + 1] == 'u') {
                            const uid3 = @import("unicode_id.zig");
                            var ec_end: u32 = end + 2;
                            var ec_cp: u32 = 0;
                            var ok: bool = true;
                            if (ec_end < n and src[ec_end] == '{') {
                                ec_end += 1;
                                while (ec_end < n and src[ec_end] != '}') : (ec_end += 1) {
                                    const h = src[ec_end];
                                    ec_cp = (ec_cp << 4) | switch (h) {
                                        '0'...'9' => h - '0',
                                        'a'...'f' => h - 'a' + 10,
                                        'A'...'F' => h - 'A' + 10,
                                        else => blk: { ok = false; break :blk 0; },
                                    };
                                }
                                if (ec_end >= n or src[ec_end] != '}') { ok = false; } else { ec_end += 1; }
                            } else if (ec_end + 4 <= n) {
                                for (0..4) |_| {
                                    const h = src[ec_end];
                                    ec_cp = (ec_cp << 4) | switch (h) {
                                        '0'...'9' => h - '0',
                                        'a'...'f' => h - 'a' + 10,
                                        'A'...'F' => h - 'A' + 10,
                                        else => blk: { ok = false; break :blk 0; },
                                    };
                                    ec_end += 1;
                                }
                            } else { ok = false; }
                            if (!ok) break;
                            const ec_ok3 = if (ec_cp < 0x80) ((ec_cp >= 'a' and ec_cp <= 'z') or (ec_cp >= 'A' and ec_cp <= 'Z') or (ec_cp >= '0' and ec_cp <= '9') or ec_cp == '_' or ec_cp == '$') else uid3.isIdContinueJS(ec_cp);
                            if (!ec_ok3) break;
                            end = ec_end;
                            // Scan continuation after escape.
                            while (end < n) {
                                const cc = src[end];
                                if ((cc >= 'a' and cc <= 'z') or (cc >= 'A' and cc <= 'Z') or (cc >= '0' and cc <= '9') or cc == '_' or cc == '$') { end += 1; continue; }
                                if (cc >= 0x80) {
                                    const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(cc) catch 1);
                                    if (end + cl <= n) {
                                        const cont_cp = std.unicode.utf8Decode(src[end..end+cl]) catch 0;
                                        if (uid3.isIdContinueJS(@intCast(cont_cp))) { end += cl; continue; }
                                    }
                                }
                                break;
                            }
                        }
                        // has_escape: true when the identifier contains \u continuation
                        // escapes (the extension loop above ran past ident_bm_end).
                        // Must be computed here, BEFORE the high-byte validation below
                        // can shorten `end` (e.g. when a keyword is immediately followed
                        // by a Unicode whitespace like NBSP — the validation sets
                        // end = valid_end < ident_bm_end, which must NOT set has_escape).
                        const has_escape = (end != ident_bm_end);
                        // Validate any high-byte continuation sequences in the identifier.
                        // The bitmap includes all 0x80+ bytes as ident-class, but not all
                        // are valid ID_Continue (e.g. Po chars, whitespace).
                        // Skip entirely when no high bytes exist in the source — all bytes
                        // are guaranteed < 0x80 so nothing to validate.
                        if (bm.has_high) {
                            // Fast-reject: use the pre-loaded ident_raw8 to check whether
                            // any of the first 8 ident bytes has bit 7 set — all register
                            // ops, no extra loads. For ident_len <= 8 (the vast majority),
                            // mask out bytes beyond the ident to avoid false positives.
                            const ident_len: u32 = end - p;
                            const need_scan: bool = if (ident_hot and ident_len <= 8) b: {
                                const shift: u6 = @intCast((8 - ident_len) << 3);
                                const mask: u64 = @as(u64, std.math.maxInt(u64)) >> shift;
                                break :b (ident_raw8 & mask & 0x8080808080808080) != 0;
                            } else true;
                            if (need_scan) {
                                var valid_end = end;
                                var scan_i: u32 = p + 1;
                                while (scan_i < valid_end) {
                                    const sc = src[scan_i];
                                    if (sc < 0x80) { scan_i += 1; continue; }
                                    // BOM inside ident → invalid.
                                    if (sc == 0xEF and scan_i + 2 < n and src[scan_i + 1] == 0xBB and src[scan_i + 2] == 0xBF) {
                                        valid_end = scan_i;
                                        break;
                                    }
                                    const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(sc) catch 1);
                                    if (scan_i + cl > n) { valid_end = scan_i; break; }
                                    const cc = std.unicode.utf8Decode(src[scan_i..scan_i+cl]) catch 0;
                                    if (isUnicodeWhitespace(cc) or !@import("unicode_id.zig").isIdContinueJS(@intCast(cc))) {
                                        valid_end = scan_i;
                                        break;
                                    }
                                    scan_i += cl;
                                }
                                end = valid_end;
                            }
                        }
                        const text = src[p..end];
                        if (has_escape) {
                            // Decode the raw escaped text and check if it's a reserved word.
                            var dec_buf: [16]u8 = undefined;
                            var dec_len: usize = 0;
                            var raw_j: u32 = p;
                            var dec_ok: bool = true;
                            while (raw_j < end and dec_len < dec_buf.len) {
                                const rc = src[raw_j];
                                if (rc == '\\' and raw_j + 1 < end and src[raw_j + 1] == 'u') {
                                    var dc_end2: u32 = raw_j + 2;
                                    var dc_cp2: u32 = 0;
                                    if (dc_end2 < end and src[dc_end2] == '{') {
                                        dc_end2 += 1;
                                        while (dc_end2 < end and src[dc_end2] != '}') : (dc_end2 += 1) {
                                            const hh = src[dc_end2];
                                            dc_cp2 = (dc_cp2 << 4) | switch (hh) {
                                                '0'...'9' => hh - '0',
                                                'a'...'f' => hh - 'a' + 10,
                                                'A'...'F' => hh - 'A' + 10,
                                                else => blk: { dec_ok = false; break :blk 0; },
                                            };
                                        }
                                        if (dc_end2 < end) dc_end2 += 1; // skip '}'
                                    } else if (dc_end2 + 4 <= end) {
                                        for (0..4) |_| {
                                            const hh = src[dc_end2];
                                            dc_cp2 = (dc_cp2 << 4) | switch (hh) {
                                                '0'...'9' => hh - '0',
                                                'a'...'f' => hh - 'a' + 10,
                                                'A'...'F' => hh - 'A' + 10,
                                                else => blk: { dec_ok = false; break :blk 0; },
                                            };
                                            dc_end2 += 1;
                                        }
                                    } else { dec_ok = false; dc_end2 = raw_j + 2; }
                                    if (dc_cp2 < 0x80) {
                                        dec_buf[dec_len] = @intCast(dc_cp2);
                                        dec_len += 1;
                                    } else {
                                        dec_ok = false; // non-ASCII in decoded → can't be a keyword
                                    }
                                    raw_j = dc_end2;
                                } else if (rc < 0x80) {
                                    dec_buf[dec_len] = rc;
                                    dec_len += 1;
                                    raw_j += 1;
                                } else {
                                    dec_ok = false;
                                    raw_j += 1;
                                }
                            }
                            if (dec_ok and dec_len <= 10 and raw_j >= end) {
                                if (Token.keywords.get(dec_buf[0..dec_len]) != null) {
                                    tag = .escaped_keyword;
                                } else {
                                    tag = .identifier;
                                }
                            } else {
                                tag = .identifier;
                            }
                        } else {
                            tag = if (isPropertyAccess(prev_kind)) .identifier
                                  else if (ident_hot) keywordLookupFromRaw(ident_raw8, src.ptr + p, end - p, language.isTs())
                                  else keywordLookup(text, language.isTs());
                        }
                        is_escaped_id = has_escape;
                    },
                }
                tag_ptr[tok_n]   = tag;
                start_ptr[tok_n] = p;
                len_ptr[tok_n]   = end - p;
                nl_ptr[tok_n]    = saw_nl;
                if (is_escaped_id) esc_ptr[tok_n] = true;
                tok_n += 1;
                saw_nl = false;
                at_line_start = false;

                prev_kind = if (isPropertyAccess(prev_kind) and tag.isKeyword()) .identifier else tag;
                if (opts.publish_to) |pp| {
                    if ((tok_n & opts.publish_batch_mask) == 0) pp.store(tok_n, .release);
                }
                skip_until = end;
                // Drain trailing ident-bitmap-run if number consumed only part.
                while (end < n) {
                    @branchHint(.cold);
                    const ew = end / 64;
                    if (ew >= bm.ident.len) break;
                    const eb: u32 = end % 64;
                    if (((bm.ident[ew] >> @intCast(eb)) & 1) == 0) break;
                    const tail_byte = src[end];
                    var t_tag: Tag = undefined;
                    var t_end: u32 = undefined;
                    // LS/PS/BOM detection BEFORE dispatch — these are
                    // ident-class bytes per Phase 1 but mean "line break"
                    // or "skip" rather than "ident character".
                    if (tail_byte == 0xE2 and end + 2 < n and src[end + 1] == 0x80 and (src[end + 2] == 0xA8 or src[end + 2] == 0xA9)) {
                        saw_nl = true;
                        end = end + 3;
                        skip_until = end;
                        continue;
                    }
                    if (tail_byte == 0xEF and end + 2 < n and src[end + 1] == 0xBB and src[end + 2] == 0xBF) {
                        end = end + 3;
                        skip_until = end;
                        continue;
                    }
                    switch (tail_byte) {
                        '0'...'9' => {
                            t_end = Lex.numberEnd(src, end);
                            const is_bn4 = t_end > end and src[t_end - 1] == 'n';
                            if (!validateNumericLiteral(src, end, t_end) or (t_end < n and isIdentStartAtPos(src, t_end))) {
                                t_tag = .invalid;
                            } else {
                                t_tag = if (is_bn4) .bigint_literal else .number_literal;
                            }
                        },
                        0x80...0xFF => {
                            // Check for Unicode whitespace (Zs) — silently skip.
                            const t_cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(tail_byte) catch 1);
                            if (end + t_cl <= n) {
                                const t_cp = std.unicode.utf8Decode(src[end..end+t_cl]) catch 0;
                                if (isUnicodeWhitespace(t_cp)) {
                                    end += t_cl;
                                    skip_until = end;
                                    continue;
                                }
                                if (!@import("unicode_id.zig").isIdStart(@intCast(t_cp))) {
                                    // Not ID_Start and not whitespace (e.g. U+180E Mongolian
                                    // Vowel Separator) — emit the codepoint as invalid.
                                    t_end = end + t_cl;
                                    t_tag = .invalid;
                                } else {
                                    t_end = identEndFromBitmap(bm.ident, ew, eb, ew * 64, n);
                                    t_tag = .identifier;
                                }
                            } else {
                                t_end = identEndFromBitmap(bm.ident, ew, eb, ew * 64, n);
                                t_tag = .identifier;
                            }
                        },
                        else => {
                            t_end = identEndFromBitmap(bm.ident, ew, eb, ew * 64, n);
                            t_tag = if (isPropertyAccess(prev_kind)) .identifier else keywordLookup(src[end..t_end], language.isTs());
                        },
                    }
                    tag_ptr[tok_n]   = t_tag;
                    start_ptr[tok_n] = end;
                    len_ptr[tok_n]   = t_end - end;
                    nl_ptr[tok_n]    = saw_nl;
                    tok_n += 1;
                    saw_nl = false;
                    at_line_start = false;
                    prev_kind = if (isPropertyAccess(prev_kind) and t_tag.isKeyword()) .identifier else t_tag;
                    if (opts.publish_to) |pp| {
                        if ((tok_n & opts.publish_batch_mask) == 0) pp.store(tok_n, .release);
                    }
                    end = t_end;
                    skip_until = end;
                }
                continue;
            }

            // Structural byte: dispatch identical to lexer.zig.
            var tag: Tag = undefined;
            var end: u32 = undefined;
            var is_escaped: bool = false; // set true only for \u-start identifier paths
            // Fast path: single-char tokens with no special handling.
            // Skips the giant switch's jump-table for the most common case.
            const single_tag = SINGLE_TAG[byte];
            if (single_tag != .eof) {
                tag = single_tag;
                end = p + 1;
            } else {
                // SWAR lookahead: load 8 bytes at p into a register once.
                // next1/next2/next3 replace p+k bounds-checked loads in operator arms.
                // safeRaw8 zero-pads for the last 1–2 bitmap words (word_safe = false);
                // zero bytes don't match any operator continuation char, so all
                // branch outcomes are identical to the original bounds-checked code.
                const raw8: u64 = if (word_safe)
                    @as(*align(1) const u64, @ptrCast(src.ptr + p)).*
                else
                    safeRaw8(src, p, n);
                const next1: u8 = @truncate(raw8 >> 8);
                const next2: u8 = @truncate(raw8 >> 16);
                const next3: u8 = @truncate(raw8 >> 24);
                switch (byte) {
                // ( ) [ ] ; , ~ @ : are handled by SINGLE_TAG fast path.
                '{' => {
                    if (tmpl_depth > 0) brace_d[tmpl_depth - 1] += 1;
                    tag = .l_brace; end = p + 1;
                },
                '}' => {
                    if (tmpl_depth > 0 and brace_d[tmpl_depth - 1] == 0) {
                        const res = Lex.templateChunkEnd(src, p);
                        end = res.end;
                        if (!res.terminated) { tag = .invalid; }
                        else if (res.has_expr) { tag = .template_middle; }
                        else { tag = .template_tail; tmpl_depth -= 1; }
                        // Template chunk between `}` and the next `${` or
                        // backtick can span multiple lines — register
                        // those breaks in `ls`.
                        try scanRangeForNewlines(&ls, alloc, src, p + 1, end);
                    } else {
                        if (tmpl_depth > 0) brace_d[tmpl_depth - 1] -= 1;
                        tag = .r_brace; end = p + 1;
                    }
                },
                '.' => {
                    if (next1 == '.' and next2 == '.') { tag = .ellipsis; end = p + 3; }
                    else if (next1 >= '0' and next1 <= '9') {
                        end = Lex.numberEnd(src, p);
                        tag = if (!validateNumericLiteral(src, p, end) or (end < n and isIdentStartAtPos(src, end))) .invalid else .number_literal;
                    }
                    else { tag = .dot; end = p + 1; }
                },
                '?' => {
                    if (next1 == '?') {
                        if (next2 == '=') { tag = .question_question_equal; end = p + 3; }
                        else { tag = .question_question; end = p + 2; }
                    } else if (next1 == '.' and !(next2 >= '0' and next2 <= '9')) { tag = .question_dot; end = p + 2; }
                    else { tag = .question; end = p + 1; }
                },
                '+' => {
                    if (next1 == '+') { tag = .plus_plus; end = p + 2; }
                    else if (next1 == '=') { tag = .plus_equal; end = p + 2; }
                    else { tag = .plus; end = p + 1; }
                },
                '-' => {
                    if (at_line_start and next1 == '-' and next2 == '>') {
                        if (opts.is_module or !opts.annex_b) {
                            tag = .invalid; end = p + 3;
                        } else {
                            const ce = lineCommentEndBM(bm.newline, p + 3, src, bm.has_high);
                            try cm_s.append(alloc, p);
                            try cm_e.append(alloc, ce);
                            try cm_k.append(alloc, 0);
                            saw_nl = true;
                            at_line_start = true;
                            skip_until = ce;
                            if (ce < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(ce - word_off)); } else { visit = 0; }
                            continue;
                        }
                    } else if (next1 == '-') { tag = .minus_minus; end = p + 2; }
                    else if (next1 == '=') { tag = .minus_equal; end = p + 2; }
                    else { tag = .minus; end = p + 1; }
                },
                '*' => {
                    if (next1 == '*') {
                        if (next2 == '=') { tag = .asterisk_asterisk_equal; end = p + 3; }
                        else { tag = .asterisk_asterisk; end = p + 2; }
                    } else if (next1 == '=') { tag = .asterisk_equal; end = p + 2; }
                    else { tag = .asterisk; end = p + 1; }
                },
                '%' => {
                    if (next1 == '=') { tag = .percent_equal; end = p + 2; }
                    else { tag = .percent; end = p + 1; }
                },
                '&' => {
                    if (next1 == '&') {
                        if (next2 == '=') { tag = .ampersand_ampersand_equal; end = p + 3; }
                        else { tag = .ampersand_ampersand; end = p + 2; }
                    } else if (next1 == '=') { tag = .ampersand_equal; end = p + 2; }
                    else { tag = .ampersand; end = p + 1; }
                },
                '|' => {
                    if (next1 == '|') {
                        if (next2 == '=') { tag = .pipe_pipe_equal; end = p + 3; }
                        else { tag = .pipe_pipe; end = p + 2; }
                    } else if (next1 == '=') { tag = .pipe_equal; end = p + 2; }
                    else { tag = .pipe; end = p + 1; }
                },
                '^' => {
                    if (next1 == '=') { tag = .caret_equal; end = p + 2; }
                    else { tag = .caret; end = p + 1; }
                },
                '!' => {
                    if (next1 == '=') {
                        if (next2 == '=') { tag = .bang_equal_equal; end = p + 3; }
                        else { tag = .bang_equal; end = p + 2; }
                    } else { tag = .bang; end = p + 1; }
                },
                '<' => {
                    if (next1 == '!' and next2 == '-' and next3 == '-') {
                        if (opts.is_module or !opts.annex_b) {
                            tag = .less_than; end = p + 1;
                        } else {
                            const ce = lineCommentEndBM(bm.newline, p + 4, src, bm.has_high);
                            try cm_s.append(alloc, p);
                            try cm_e.append(alloc, ce);
                            try cm_k.append(alloc, 0);
                            saw_nl = true;
                            skip_until = ce;
                            if (ce < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(ce - word_off)); } else { visit = 0; }
                            continue;
                        }
                    } else if (next1 == '=') { tag = .less_equal; end = p + 2; }
                    else if (next1 == '<') {
                        if (next2 == '=') { tag = .less_less_equal; end = p + 3; }
                        else { tag = .less_less; end = p + 2; }
                    } else { tag = .less_than; end = p + 1; }
                },
                '>' => {
                    if (next1 == '=') { tag = .greater_equal; end = p + 2; }
                    else if (next1 == '>') {
                        if (next2 == '>') {
                            if (next3 == '=') { tag = .greater_greater_greater_equal; end = p + 4; }
                            else { tag = .greater_greater_greater; end = p + 3; }
                        } else if (next2 == '=') { tag = .greater_greater_equal; end = p + 3; }
                        else { tag = .greater_greater; end = p + 2; }
                    } else { tag = .greater_than; end = p + 1; }
                },
                '=' => {
                    if (next1 == '=') {
                        if (next2 == '=') { tag = .equal_equal_equal; end = p + 3; }
                        else { tag = .equal_equal; end = p + 2; }
                    } else if (next1 == '>') { tag = .arrow; end = p + 2; }
                    else { tag = .equal; end = p + 1; }
                },
                '#' => {
                    if (p == 0 and next1 == '!') {
                        end = lineCommentEndBM(bm.newline, p + 2, src, bm.has_high); tag = .hashbang;
                    } else { tag = .hash; end = p + 1; }
                },
                '/' => {
                    if (next1 == '/') {
                        const ce = lineCommentEndBM(bm.newline, p + 2, src, bm.has_high);
                        // In JSX mode: if the line comment body contains `</` (closing tag
                        // pattern) AND the `//` is not preceded by another `/` (which would
                        // indicate `////` comments in fourslash test files), this `//` is
                        // inside JSX text content, not JS code. Skip both slash chars without
                        // treating them as a comment so the parser still sees `</tag>`.
                        if (language.isJsx()) {
                            // Don't apply to `////...` sequences (preceded by `/`)
                            const preceded_by_slash = p > 0 and src[p - 1] == '/';
                            var k: u32 = p + 2;
                            var jsx_text_comment = false;
                            if (!preceded_by_slash) {
                                while (k + 1 < ce) : (k += 1) {
                                    if (src[k] == '<' and src[k + 1] == '/') { jsx_text_comment = true; break; }
                                }
                            }
                            if (jsx_text_comment) {
                                // Clear the bit for the second `/` so the visit loop skips it.
                                const p1 = p + 1;
                                if (p1 < word_off + 64) {
                                    visit &= ~(@as(u64, 1) << @as(u6, @intCast(p1 - word_off)));
                                } else {
                                    skip_until = p + 2;
                                }
                                continue; // skip first `/` without emitting; rest of line is visible
                            } else {
                                try cm_s.append(alloc, p);
                                try cm_e.append(alloc, ce);
                                try cm_k.append(alloc, 0);
                                saw_nl = true;
                                skip_until = ce;
                                if (ce < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(ce - word_off)); } else { visit = 0; }
                                continue;
                            }
                        } else {
                            try cm_s.append(alloc, p);
                            try cm_e.append(alloc, ce);
                            try cm_k.append(alloc, 0);
                            saw_nl = true;
                            skip_until = ce;
                            if (ce < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(ce - word_off)); } else { visit = 0; }
                            continue;
                        }
                    }
                    if (next1 == '*') {
                        const res = blockCommentEndBM(src, bm.structural, bm.newline, p, n, bm.has_high);
                        if (res.has_nl) { saw_nl = true; }
                        // Unterminated block comment: in JSX mode, `/*` inside JSX text content
                        // is literal text (not a comment). Emit `/` as a slash token and let
                        // the `*` be handled separately, so `<span>/*</span>` parses correctly.
                        if (res.end >= n and !(n >= 2 and src[n-2] == '*' and src[n-1] == '/')) {
                            if (language.isJsx()) {
                                // Treat as a literal `/` — JSX text content is not JS expression context.
                                tag = .slash; end = p + 1;
                                // (fall through to emit as .slash below)
                            } else {
                                tag_ptr[tok_n] = .invalid; start_ptr[tok_n] = p; len_ptr[tok_n] = res.end - p; nl_ptr[tok_n] = saw_nl;
                                tok_n += 1;
                                skip_until = n;
                                wi = bm.ident.len; // terminate outer word loop
                                break; // break inner visit loop
                            }
                        } else {
                            try cm_s.append(alloc, p);
                            try cm_e.append(alloc, res.end);
                            try cm_k.append(alloc, 1);
                            // Newlines inside block comments must still register in `ls`
                            // — `skip_until` would otherwise hide them from the bitmap walk,
                            // leaving line numbers under-counted (loc.start.line wrong).
                            if (res.has_nl) {
                                var q: u32 = p + 2;
                                while (q < res.end) : (q += 1) {
                                    const c = src[q];
                                    if (c == '\n') { try ls.append(alloc, q + 1); at_line_start = true; }
                                    else if (c == '\r') {
                                        const next_q = if (q + 1 < res.end and src[q + 1] == '\n') q + 2 else q + 1;
                                        try ls.append(alloc, next_q);
                                        at_line_start = true;
                                        q = next_q - 1; // -1 since loop increments
                                    } else if (c == 0xE2 and q + 2 < res.end and src[q + 1] == 0x80 and (src[q + 2] == 0xA8 or src[q + 2] == 0xA9)) {
                                        try ls.append(alloc, q + 3);
                                        at_line_start = true;
                                        q += 2;
                                    }
                                }
                            }
                            skip_until = res.end;
                            if (res.end < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(res.end - word_off)); } else { visit = 0; }
                            continue;
                        }
                    }
                    // JSX: `>` and `<` precede tag content / closing tags, never a
                    // regex. `<div>/text</div>` would otherwise lex `/text</div>`
                    // as a regex literal and swallow the closing tag.
                    if (Lex.regexAllowed(prev_kind) and !(language.isJsx() and (prev_kind == .less_than or prev_kind == .greater_than))) { end = Lex.regexEnd(src, p); tag = .regex_literal; }
                    else if (next1 == '=') { tag = .slash_equal; end = p + 2; }
                    else { tag = .slash; end = p + 1; }
                },
                '"', '\'' => {
                    // JSX semantics: two distinct string contexts within JSX files.
                    // 1. JSX attribute value: `<div id="foo">` — prev token is `=`.
                    //    Needs terminate-at-`<` AND no escape sequences.
                    // 2. JSX text content: `<div>'</div>` — prev token is `>`.
                    //    Needs terminate-at-`<` (so the scan stops before `</`)
                    //    but `'` in text is not a true string delimiter — the
                    //    terminate-at-`<` just prevents it from consuming the tag.
                    //    Also covers contractions like `I'm` in `<>Hi, I'm!</>` where
                    //    prev_kind is `identifier` — `identifier'` is invalid JS so this
                    //    is unambiguously JSX text content.
                    // 3. JS expression inside `{}`: `{"<test>"}` — prev is `{` etc.
                    //    Must NOT terminate at `<`; standard JS string semantics.
                    // A string after `=` is a JSX attribute value (no escapes) ONLY when
                    // we are actually inside a JSX opening-tag header. Otherwise the `=` is
                    // an ordinary assignment (`const s = 'it\'s'` in a .tsx file) and the
                    // string must use standard JS escape semantics.
                    const jsx_attr = language.isJsx() and prev_kind == .equal and jsx_tag_depth > 0;
                    const jsx_text = language.isJsx() and (prev_kind == .greater_than or prev_kind == .identifier);
                    end = stringEndBMOptFull(src, bm.structural, bm.newline, p, n, jsx_attr or jsx_text, jsx_attr);
                    tag = .string_literal;
                    // Strings with line continuations (`\<newline>`) span
                    // multiple source lines. Register those breaks in `ls`
                    // so loc.start.line matches ESLint downstream.
                    try scanRangeForNewlines(&ls, alloc, src, p + 1, end);
                },
                '`' => {
                    const res = Lex.templateChunkEnd(src, p);
                    end = res.end;
                    if (!res.terminated) { tag = .invalid; }
                    else if (res.has_expr) {
                        tag = .template_head;
                        if (tmpl_depth < brace_d.len) {
                            brace_d[tmpl_depth] = 0;
                            tmpl_depth += 1;
                        }
                    } else { tag = .template_no_sub; }
                    // Template literals may span multiple lines; same as
                    // block comments above, register every newline inside
                    // the chunk in `ls`.
                    try scanRangeForNewlines(&ls, alloc, src, p + 1, end);
                },
                '0'...'9' => {
                    end = Lex.numberEnd(src, p);
                    const is_bn2 = end > p and src[end - 1] == 'n';
                    if (!validateNumericLiteral(src, p, end)) {
                        tag = .invalid;
                    } else if (end < n and isIdentStartAtPos(src, end)) {
                        tag = .invalid;
                    } else {
                        tag = if (is_bn2) .bigint_literal else .number_literal;
                    }
                },
                '\\' => {
                    // \uXXXX or \u{N} escaped identifier start.
                    const uid = @import("unicode_id.zig");
                    var valid: bool = true;
                    var first_cp: u32 = 0;
                    var ie: u32 = p; // end of first escape sequence
                    if (next1 == 'u') {
                        var ec_end: u32 = p + 2;
                        var ec_cp: u32 = 0;
                        if (ec_end < n and src[ec_end] == '{') {
                            ec_end += 1;
                            while (ec_end < n and src[ec_end] != '}') : (ec_end += 1) {
                                const h = src[ec_end];
                                ec_cp = (ec_cp << 4) | switch (h) {
                                    '0'...'9' => h - '0',
                                    'a'...'f' => h - 'a' + 10,
                                    'A'...'F' => h - 'A' + 10,
                                    else => blk: { valid = false; break :blk 0; },
                                };
                            }
                            if (ec_end >= n or src[ec_end] != '}') { valid = false; }
                            else { ec_end += 1; }
                        } else if (ec_end + 4 <= n) {
                            var hh: u32 = 0;
                            for (0..4) |_| {
                                const h = src[ec_end];
                                hh = (hh << 4) | switch (h) {
                                    '0'...'9' => h - '0',
                                    'a'...'f' => h - 'a' + 10,
                                    'A'...'F' => h - 'A' + 10,
                                    else => blk: { valid = false; break :blk 0; },
                                };
                                ec_end += 1;
                            }
                            ec_cp = hh;
                        } else { valid = false; ec_end = p + 2; }
                        first_cp = ec_cp;
                        ie = ec_end;
                    } else { valid = false; ie = p + 1; }

                    // Validate ID_Start for the first codepoint.
                    if (valid) {
                        if (first_cp < 0x80) {
                            if (!((first_cp >= 'a' and first_cp <= 'z') or (first_cp >= 'A' and first_cp <= 'Z') or first_cp == '_' or first_cp == '$'))
                                valid = false;
                        } else {
                            if (!uid.isIdStart(first_cp)) valid = false;
                        }
                    }

                    if (!valid) {
                        tag = .invalid;
                        end = ie;
                    } else {
                        // Scan continuation: ASCII ident chars or \u escapes or high bytes.
                        var j: u32 = ie;
                        scan_cont: while (j < n) {
                            const c = src[j];
                            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                                (c >= '0' and c <= '9') or c == '_' or c == '$') { j += 1; continue; }
                            if (c >= 0x80) {
                                const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(c) catch 1);
                                if (j + cl <= n) {
                                    const cont_cp = std.unicode.utf8Decode(src[j..j+cl]) catch 0;
                                    if (uid.isIdContinueJS(cont_cp)) { j += cl; continue; }
                                }
                                break;
                            }
                            if (c == '\\' and j + 1 < n and src[j + 1] == 'u') {
                                var ec_end2: u32 = j + 2;
                                var ec_cp2: u32 = 0;
                                var cont_valid: bool = true;
                                if (ec_end2 < n and src[ec_end2] == '{') {
                                    ec_end2 += 1;
                                    while (ec_end2 < n and src[ec_end2] != '}') : (ec_end2 += 1) {
                                        const h = src[ec_end2];
                                        ec_cp2 = (ec_cp2 << 4) | switch (h) {
                                            '0'...'9' => h - '0',
                                            'a'...'f' => h - 'a' + 10,
                                            'A'...'F' => h - 'A' + 10,
                                            else => blk: { cont_valid = false; break :blk 0; },
                                        };
                                    }
                                    if (ec_end2 >= n or src[ec_end2] != '}') { cont_valid = false; }
                                    else { ec_end2 += 1; }
                                } else if (ec_end2 + 4 <= n) {
                                    for (0..4) |_| {
                                        const h = src[ec_end2];
                                        ec_cp2 = (ec_cp2 << 4) | switch (h) {
                                            '0'...'9' => h - '0',
                                            'a'...'f' => h - 'a' + 10,
                                            'A'...'F' => h - 'A' + 10,
                                            else => blk: { cont_valid = false; break :blk 0; },
                                        };
                                        ec_end2 += 1;
                                    }
                                } else { cont_valid = false; }
                                if (!cont_valid) break :scan_cont;
                                const ec_ok_cont = if (ec_cp2 < 0x80) ((ec_cp2 >= 'a' and ec_cp2 <= 'z') or (ec_cp2 >= 'A' and ec_cp2 <= 'Z') or (ec_cp2 >= '0' and ec_cp2 <= '9') or ec_cp2 == '_' or ec_cp2 == '$') else uid.isIdContinueJS(ec_cp2);
                                if (!ec_ok_cont) break :scan_cont;
                                j = ec_end2;
                                continue;
                            }
                            break;
                        }
                        end = j;
                        // Decode the raw escaped text into its string value to check keywords.
                        // Build decoded chars into a stack buffer (keywords are max 10 ASCII chars).
                        var decoded_buf: [16]u8 = undefined;
                        var decoded_len: usize = 0;
                        var is_kw: bool = false;
                        var raw_i: u32 = p;
                        var decode_ok: bool = true;
                        while (raw_i < end and decoded_len < decoded_buf.len) {
                            const rc = src[raw_i];
                            if (rc == '\\' and raw_i + 1 < end and src[raw_i + 1] == 'u') {
                                var dc_end: u32 = raw_i + 2;
                                var dc_cp: u32 = 0;
                                if (dc_end < end and src[dc_end] == '{') {
                                    dc_end += 1;
                                    while (dc_end < end and src[dc_end] != '}') : (dc_end += 1) {
                                        const hh = src[dc_end];
                                        dc_cp = (dc_cp << 4) | switch (hh) {
                                            '0'...'9' => hh - '0',
                                            'a'...'f' => hh - 'a' + 10,
                                            'A'...'F' => hh - 'A' + 10,
                                            else => blk: { decode_ok = false; break :blk 0; },
                                        };
                                    }
                                    if (dc_end < end) dc_end += 1; // skip '}'
                                } else if (dc_end + 4 <= end) {
                                    for (0..4) |_| {
                                        const hh = src[dc_end];
                                        dc_cp = (dc_cp << 4) | switch (hh) {
                                            '0'...'9' => hh - '0',
                                            'a'...'f' => hh - 'a' + 10,
                                            'A'...'F' => hh - 'A' + 10,
                                            else => blk: { decode_ok = false; break :blk 0; },
                                        };
                                        dc_end += 1;
                                    }
                                } else { decode_ok = false; dc_end = raw_i + 2; }
                                if (dc_cp < 0x80) {
                                    decoded_buf[decoded_len] = @intCast(dc_cp);
                                    decoded_len += 1;
                                } else {
                                    // Non-ASCII codepoint in decoded text — can't be a keyword.
                                    decode_ok = false;
                                }
                                raw_i = dc_end;
                            } else if (rc < 0x80) {
                                decoded_buf[decoded_len] = rc;
                                decoded_len += 1;
                                raw_i += 1;
                            } else {
                                // High byte — not a keyword char.
                                decode_ok = false;
                                raw_i += 1;
                            }
                        }
                        if (decode_ok and decoded_len <= 10 and raw_i >= end) {
                            is_kw = Token.keywords.get(decoded_buf[0..decoded_len]) != null;
                        }
                        tag = if (is_kw) .escaped_keyword else .identifier;
                    }
                    is_escaped = true;
                },
                0x80...0xFF => {
                    if (byte == 0xE2 and next1 == 0x80 and (next2 == 0xA8 or next2 == 0xA9)) {
                        saw_nl = true;
                        at_line_start = true;
                        const skip_to: u32 = p + 3;
                        skip_until = skip_to;
                        if (skip_to < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(skip_to - word_off)); } else { visit = 0; }
                        continue;
                    }
                    if (byte == 0xEF and next1 == 0xBB and next2 == 0xBF) {
                        const skip_to: u32 = p + 3;
                        skip_until = skip_to;
                        if (skip_to < word_off + 64) { visit &= ~@as(u64, 0) << @as(u6, @intCast(skip_to - word_off)); } else { visit = 0; }
                        continue;
                    }
                    end = Lex.identEnd(src, p); tag = .identifier;
                },
                else => {
                    // VT (0x0B) and FF (0x0C) are ECMAScript WhiteSpace — skip silently.
                    if (byte == 0x0B or byte == 0x0C) continue;
                    // All other unrecognized bytes (control chars, etc.) are illegal tokens.
                    tag = .invalid; end = p + 1;
                },
            }
            } // else (SWAR structural dispatch)

            // Emit token.
            tag_ptr[tok_n]   = tag;
            start_ptr[tok_n] = p;
            len_ptr[tok_n]   = end - p;
            nl_ptr[tok_n]    = saw_nl;
            if (is_escaped) { esc_ptr[tok_n] = true; is_escaped = false; }
            tok_n += 1;
            saw_nl = false;
            at_line_start = false;

            // Maintain JSX opening-tag depth (used by the string scanner above). Only
            // `<` `>` `{` `}` tokens matter, and all of them reach this common emit
            // point. `prev_kind` here is still the token BEFORE `tag`, which is exactly
            // what the `<`-opens-a-JSX-element test needs.
            if (language.isJsx()) {
                switch (tag) {
                    .less_than => {
                        // `<` begins a JSX element when it is in expression/child position
                        // (regexAllowed) and is immediately followed by a tag-name start or
                        // `>` (fragment). This is the same disambiguation that separates JSX
                        // from generics (`foo<T>`, where prev_kind is an identifier) and from
                        // the less-than operator (`a < b`).
                        if (Lex.regexAllowed(prev_kind)) {
                            const nb: u8 = if (end < n) src[end] else 0;
                            const opens = nb == '>' or nb == '_' or nb == '$' or
                                (nb >= 'a' and nb <= 'z') or (nb >= 'A' and nb <= 'Z') or nb >= 0x80;
                            if (opens) jsx_tag_depth += 1;
                        }
                    },
                    .l_brace => if (jsx_tag_depth > 0) {
                        jsx_brace_nest += 1;
                    },
                    .r_brace => if (jsx_brace_nest > 0) {
                        jsx_brace_nest -= 1;
                    },
                    .greater_than => if (jsx_tag_depth > 0 and jsx_brace_nest == 0) {
                        jsx_tag_depth -= 1;
                    },
                    else => {},
                }
            }

            prev_kind = if (isPropertyAccess(prev_kind) and tag.isKeyword()) .identifier else tag;
            if (opts.publish_to) |pp| {
                if ((tok_n & opts.publish_batch_mask) == 0) pp.store(tok_n, .release);
            }

            // Skip visit bits in [p+1 .. end). Bulk-clear covered bits in
            // the current visit word to avoid per-bit `p < skip_until` checks.
            if (end > p + 1) {
                skip_until = end;
                if (end < word_off + 64) {
                    const shift: u6 = @intCast(end - word_off);
                    visit &= ~@as(u64, 0) << shift;
                } else {
                    visit = 0;
                }
            }

            // ── Drain trailing ident-bitmap-run ────────────────────────
            // If the consumed token ended mid-ident-bitmap-run (e.g.,
            // numberEnd stopped on `_8` after `0o01`, or `3ea` parsed only
            // `3`), the residual bytes have NO ident_start bit (their
            // predecessor is also ident-class) and would never be visited.
            // Walk forward emitting each contiguous tail token until we
            // exit the ident-bitmap-run.
            while (end < n) {
                @branchHint(.cold);
                const ew = end / 64;
                if (ew >= bm.ident.len) break;
                const eb: u32 = end % 64;
                if (((bm.ident[ew] >> @intCast(eb)) & 1) == 0) break;
                // If the predecessor byte is non-ident, 'end' is an ident-start:
                // the main visit loop will process it via the id_start dispatch
                // (which handles \u continuations). Don't drain it here.
                if (end > 0) {
                    const pred_w = (end - 1) / 64;
                    const pred_b: u6 = @intCast((end - 1) % 64);
                    if (pred_w < bm.ident.len and ((bm.ident[pred_w] >> pred_b) & 1) == 0) break;
                }
                const tail_byte = src[end];
                var t_tag: Tag = undefined;
                var t_end: u32 = undefined;
                if (tail_byte == 0xE2 and end + 2 < n and src[end + 1] == 0x80 and (src[end + 2] == 0xA8 or src[end + 2] == 0xA9)) {
                    saw_nl = true;
                    end = end + 3;
                    skip_until = end;
                    continue;
                }
                if (tail_byte == 0xEF and end + 2 < n and src[end + 1] == 0xBB and src[end + 2] == 0xBF) {
                    end = end + 3;
                    skip_until = end;
                    continue;
                }
                switch (tail_byte) {
                    '0'...'9' => {
                        t_end = Lex.numberEnd(src, end);
                        const is_bn5 = t_end > end and src[t_end - 1] == 'n';
                        if (!validateNumericLiteral(src, end, t_end) or (t_end < n and isIdentStartAtPos(src, t_end))) {
                            t_tag = .invalid;
                        } else {
                            t_tag = if (is_bn5) .bigint_literal else .number_literal;
                        }
                    },
                    0x80...0xFF => {
                        // Check for Unicode whitespace (Zs) — silently skip.
                        const t_cl2: u32 = @intCast(std.unicode.utf8ByteSequenceLength(tail_byte) catch 1);
                        if (end + t_cl2 <= n) {
                            const t_cp2 = std.unicode.utf8Decode(src[end..end+t_cl2]) catch 0;
                            if (isUnicodeWhitespace(t_cp2)) {
                                end += t_cl2;
                                skip_until = end;
                                continue;
                            }
                        }
                        t_end = identEndFromBitmap(bm.ident, ew, eb, ew * 64, n);
                        t_tag = .identifier;
                    },
                    else => {
                        t_end = identEndFromBitmap(bm.ident, ew, eb, ew * 64, n);
                        t_tag = if (isPropertyAccess(prev_kind)) .identifier else keywordLookup(src[end..t_end], language.isTs());
                    },
                }
                tag_ptr[tok_n]   = t_tag;
                start_ptr[tok_n] = end;
                len_ptr[tok_n]   = t_end - end;
                nl_ptr[tok_n]    = saw_nl; // may be set by LS skip above
                tok_n += 1;
                saw_nl = false;
                at_line_start = false;
                prev_kind = if (isPropertyAccess(prev_kind) and t_tag.isKeyword()) .identifier else t_tag;
                if (opts.publish_to) |pp| {
                    if ((tok_n & opts.publish_batch_mask) == 0) pp.store(tok_n, .release);
                }
                end = t_end;
                skip_until = end;
            }
        }
    }

    // ── EOF token ──
    tag_ptr[tok_n]   = .eof;
    start_ptr[tok_n] = n;
    len_ptr[tok_n]   = 0;
    nl_ptr[tok_n]    = saw_nl;
    tok_n += 1;
    tokens.len = tok_n;
    // Caller provided buffer: sync the new len back. The shared `bytes`
    // pointer means writes via tag_ptr/etc. already landed in the
    // caller's storage; only the `len` field needs propagation.
    if (tokens_buf) |b| b.len = tok_n;

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
