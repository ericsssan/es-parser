//! Lexer entry points + shared scalar helpers.
//!
//! The two-phase bitmap tokenizer this file once held has been retired — the
//! single-pass `scalar_lexer` is the sole token producer. `tokenize*` here are
//! thin shims that delegate to `scalar_lexer.tokenizeScalarFull`. What remains
//! is the keyword-lookup machinery (`keywordLookup` + its perfect-hash tables)
//! and the numeric/identifier classification helpers (`validateNumericLiteral`,
//! `isIdentStartAtPos`, `isUnicodeWhitespace`) that `scalar_lexer` imports.

const std = @import("std");
const builtin = @import("builtin");
const Token = @import("token.zig");
const Tag = Token.Tag;
const Language = Token.Language;
const Ast = @import("ast.zig");
const Lex = @import("lexer_helpers.zig");
pub const TokenList = Ast.Ast.TokenList;

pub const TokenizeResult = Lex.TokenizeResult;
pub const TokenizeOptions = Lex.TokenizeOptions;
pub const CommentSink = Lex.CommentSink;
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
    // The scalar lexer is the single token producer; it now also emits the
    // comment + line-start trivia this result carries. (The two-phase bitmap
    // path below is retired.)
    return @import("scalar_lexer.zig").tokenizeScalarFull(alloc, source, language, opts);
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1: build per-byte bitmaps via 4× ILP SIMD on 64-byte windows.
// ─────────────────────────────────────────────────────────────────────────────

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

pub fn validateNumericLiteral(src: []const u8, start: u32, end: u32) bool {
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
pub fn isIdentStartAtPos(src: []const u8, pos: u32) bool {
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
pub inline fn isUnicodeWhitespace(cp: u32) bool {
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
