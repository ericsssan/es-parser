//! Single-pass scalar tokenizer.
//!
//! Produces the same `TokenList` token stream as `lexer.zig` (the two-phase
//! bitmap lexer) so it can serve as a drop-in tokenizer with the parser
//! unchanged. Scans the source once with a per-first-byte dispatch and plain
//! scalar inner loops (no bitmaps). Handles the full grammar the bitmap lexer
//! does: ASCII and Unicode identifiers, `\u`-escaped identifiers and escaped
//! keywords, numeric/bigint literals, strings, regex-vs-division, template
//! literals (with nested `${}`), line/block/HTML (Annex B) comments, JSX
//! lexing (attribute/text strings, tag-depth tracking, regex and comment
//! suppression in JSX context), and the `has_newline_before` /
//! `has_unicode_escape` per-token flags.
//!
//! The `language` argument selects the TS keyword set and JSX lexing; a
//! `TokenizeOptions` (via `tokenizeScalarWithOptions`) gates Annex B HTML
//! comments through `is_module` / `annex_b`, matching `tokenizeWithAllOptions`.
//!
//! Token streams are byte-for-byte identical to the bitmap lexer across the
//! conformance corpus, except on inputs containing invalid UTF-8 where the
//! bitmap lexer's identifier span is itself position-dependent.

const std = @import("std");
const token = @import("token.zig");
const Tag = token.Tag;
const Language = token.Language;
const lexer = @import("lexer.zig");
const Lex = @import("lexer_helpers.zig");
const uid = @import("unicode_id.zig");
const Ast = @import("ast.zig");

pub const TokenList = Ast.Ast.TokenList;

/// Scan a string literal starting at `open`. In JSX context (`is_jsx`) the
/// string terminates at `<` and may span newlines; JSX attribute strings
/// (`jsx_no_escape`) treat `\` as a literal byte. Mirrors `stringEndBMOptFull`.
fn scanStringJsx(src: []const u8, open: u32, n: u32, is_jsx: bool, jsx_no_escape: bool) u32 {
    const quote = src[open];
    var i = open + 1;
    while (i < n) {
        const c = src[i];
        if (c == quote) return i + 1;
        if (is_jsx and c == '<') return i;
        if (is_jsx and (c == '\n' or c == '\r')) {
            i += 1;
            continue;
        }
        if (c == '\\') {
            if (jsx_no_escape) {
                i += 1;
                continue;
            }
            if (i + 2 < n and src[i + 1] == '\r' and src[i + 2] == '\n') {
                i += 3;
            } else if (i + 3 < n and src[i + 1] == 0xE2 and src[i + 2] == 0x80 and (src[i + 3] == 0xA8 or src[i + 3] == 0xA9)) {
                i += 4;
            } else {
                i += 2;
            }
            continue;
        }
        if (c == '\n' or c == '\r') return i;
        i += 1;
    }
    // An escape near EOF can advance `i` past `n`; the bitmap scanner reports
    // the same overshoot, so match it rather than clamping to `n`.
    return @max(i, n);
}

inline fn isPropertyAccess(t: Tag) bool {
    return t == .dot or t == .question_dot;
}

/// Position of the next line terminator (\n, \r, LS U+2028, PS U+2029) at or
/// after `start`, or `n` if none. The terminator itself is not consumed.
inline fn lineTerminatorScan(src: []const u8, start: u32, n: u32) u32 {
    const V = @Vector(16, u8);
    var i = start;
    while (i + 16 <= n) {
        const chunk: V = src[i..][0..16].*;
        const hits: u16 = @bitCast((chunk == @as(V, @splat(@as(u8, '\n')))) |
            (chunk == @as(V, @splat(@as(u8, '\r')))) |
            (chunk == @as(V, @splat(@as(u8, 0xE2)))));
        if (hits != 0) {
            const p = i + @ctz(hits);
            const c = src[p];
            if (c == '\n' or c == '\r') return p;
            // 0xE2: a LS/PS lead terminates; any other 0xE2 is comment text.
            if (p + 2 < n and src[p + 1] == 0x80 and (src[p + 2] == 0xA8 or src[p + 2] == 0xA9)) return p;
            i = p + 1;
            continue;
        }
        i += 16;
    }
    while (i < n) : (i += 1) {
        const c = src[i];
        if (c == '\n' or c == '\r') return i;
        if (c == 0xE2 and i + 2 < n and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) return i;
    }
    return i;
}

inline fn hexVal(h: u8, ok: *bool) u32 {
    return switch (h) {
        '0'...'9' => h - '0',
        'a'...'f' => h - 'a' + 10,
        'A'...'F' => h - 'A' + 10,
        else => blk: {
            ok.* = false;
            break :blk 0;
        },
    };
}

/// Parse a `\uXXXX` or `\u{...}` escape starting at `p` (which points at `\`).
/// Returns the codepoint, the end offset, and whether it was well-formed.
fn parseUnicodeEscape(src: []const u8, p: u32, n: u32) struct { cp: u32, end: u32, ok: bool } {
    var ok = true;
    var cp: u32 = 0;
    var e: u32 = p + 2; // skip "\u"
    if (e < n and src[e] == '{') {
        e += 1;
        while (e < n and src[e] != '}') : (e += 1) cp = (cp << 4) | hexVal(src[e], &ok);
        if (e >= n or src[e] != '}') ok = false else e += 1;
    } else if (e + 4 <= n) {
        var hh: u32 = 0;
        for (0..4) |_| {
            hh = (hh << 4) | hexVal(src[e], &ok);
            e += 1;
        }
        cp = hh;
    } else {
        ok = false;
        e = p + 2;
    }
    return .{ .cp = cp, .end = e, .ok = ok };
}

inline fn cpIsIdStart(cp: u32) bool {
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or cp == '_' or cp == '$';
    return uid.isIdStart(cp);
}

inline fn cpIsIdContinue(cp: u32) bool {
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9') or cp == '_' or cp == '$';
    return uid.isIdContinueJS(cp);
}

const IdentResult = struct { end: u32, tag: Tag, has_escape: bool };

/// Decode an identifier's raw text (resolving `\u` escapes) and report whether
/// it spells a reserved word — mirrors the main lexer's keyword check.
///
/// Reserved words are 2–10 lowercase ASCII letters, so bail the moment a decoded
/// character can't belong to one (anything outside `a`–`z`) or the length passes
/// 10. The hot escaped-identifier case (digits, `_`, `$`, uppercase, or long
/// names) exits after a few characters without finishing the decode or touching
/// the keyword map — the keyword check is the dominant cost on escape-heavy code.
fn decodedIsKeyword(src: []const u8, start: u32, end: u32) bool {
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    var raw_i: u32 = start;
    while (raw_i < end) {
        var dc: u32 = undefined;
        if (src[raw_i] == '\\' and raw_i + 1 < end and src[raw_i + 1] == 'u') {
            const esc = parseUnicodeEscape(src, raw_i, end);
            dc = esc.cp;
            raw_i = esc.end;
        } else {
            dc = src[raw_i];
            raw_i += 1;
        }
        if (dc < 'a' or dc > 'z') return false; // not a reserved-word character
        if (len == buf.len) return false; // longer than any reserved word
        buf[len] = @intCast(dc);
        len += 1;
    }
    return token.keywords.get(buf[0..len]) != null;
}

/// SIMD scan of an ASCII identifier body: returns the offset of the first byte
/// that is not `[A-Za-z0-9_$]` (which includes any 0x80+ byte and `\`). Scans
/// 16 bytes per step; the hot path for the ~42%-of-tokens identifier case.
inline fn asciiIdentEnd(src: []const u8, start: u32, n: u32) u32 {
    const V = @Vector(16, u8);
    var i = start;
    while (i + 16 <= n) {
        const chunk: V = src[i..][0..16].*;
        const lower = chunk | @as(V, @splat(@as(u8, 0x20)));
        const is_alpha = (lower >= @as(V, @splat(@as(u8, 'a')))) & (lower <= @as(V, @splat(@as(u8, 'z'))));
        const is_digit = (chunk >= @as(V, @splat(@as(u8, '0')))) & (chunk <= @as(V, @splat(@as(u8, '9'))));
        const is_us = (chunk == @as(V, @splat(@as(u8, '_')))) | (chunk == @as(V, @splat(@as(u8, '$'))));
        const mask: u16 = @bitCast(is_alpha | is_digit | is_us);
        if (mask != 0xFFFF) return i + @ctz(~mask);
        i += 16;
    }
    while (i < n) : (i += 1) {
        const c = src[i];
        const l = c | 0x20;
        if (!((l >= 'a' and l <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '$')) break;
    }
    return i;
}

/// Identifier byte-run identical to the main lexer's `ident` bitmap: consume
/// ASCII ident chars and every 0x80+ byte, stopping only at an LS/PS (U+2028/
/// U+2029) lead sequence. Codepoint validity is enforced afterwards.
inline fn identByteRun(src: []const u8, start: u32, n: u32) u32 {
    var i = start;
    while (i < n) {
        const c = src[i];
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$') {
            i += 1;
            continue;
        }
        if (c >= 0x80) {
            if (c == 0xE2 and i + 2 < n and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) break;
            i += 1;
            continue;
        }
        break;
    }
    return i;
}

/// Extend an identifier across `\u` escape continuations starting at `end0`.
fn extendEscapes(src: []const u8, end0: u32, n: u32) u32 {
    var end = end0;
    while (end < n and src[end] == '\\' and end + 1 < n and src[end + 1] == 'u') {
        const esc = parseUnicodeEscape(src, end, n);
        if (!esc.ok or !cpIsIdContinue(esc.cp)) break;
        end = esc.end;
        while (end < n) {
            const cc = src[end];
            if ((cc >= 'a' and cc <= 'z') or (cc >= 'A' and cc <= 'Z') or (cc >= '0' and cc <= '9') or cc == '_' or cc == '$') {
                end += 1;
                continue;
            }
            if (cc >= 0x80) {
                const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(cc) catch 1);
                if (end + cl <= n) {
                    const cont_cp = std.unicode.utf8Decode(src[end .. end + cl]) catch 0;
                    if (uid.isIdContinueJS(@intCast(cont_cp))) {
                        end += cl;
                        continue;
                    }
                }
            }
            break;
        }
    }
    return end;
}

/// ASCII-start identifier: byte-run, `\u` extension, then forward validation
/// (stripping at the first non-ID_Continue high codepoint) and keyword lookup.
fn scanIdentRun(src: []const u8, start: u32, n: u32, prev: Tag, is_ts: bool) IdentResult {
    const bm_end = identByteRun(src, start, n);
    var end = extendEscapes(src, bm_end, n);
    const has_escape = end != bm_end;
    // Validate high-byte continuation runs: the run accepts all 0x80+ bytes,
    // but not all are valid ID_Continue (whitespace, BOM, Po, ...).
    var valid_end = end;
    var scan_i: u32 = start + 1;
    while (scan_i < valid_end) {
        const sc = src[scan_i];
        if (sc < 0x80) {
            scan_i += 1;
            continue;
        }
        if (sc == 0xEF and scan_i + 2 < n and src[scan_i + 1] == 0xBB and src[scan_i + 2] == 0xBF) {
            valid_end = scan_i;
            break;
        }
        const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(sc) catch 1);
        if (scan_i + cl > n) {
            valid_end = scan_i;
            break;
        }
        const cc = std.unicode.utf8Decode(src[scan_i .. scan_i + cl]) catch 0;
        if (lexer.isUnicodeWhitespace(@intCast(cc)) or !uid.isIdContinueJS(@intCast(cc))) {
            valid_end = scan_i;
            break;
        }
        scan_i += cl;
    }
    end = valid_end;
    var tag: Tag = undefined;
    if (has_escape) {
        tag = if (decodedIsKeyword(src, start, end)) .escaped_keyword else .identifier;
    } else {
        tag = if (isPropertyAccess(prev)) .identifier else lexer.keywordLookup(src[start..end], is_ts);
    }
    return .{ .end = end, .tag = tag, .has_escape = has_escape };
}

/// High-byte-start identifier (leading codepoint already validated as
/// ID_Start): byte-run, back-trim of trailing non-ID_Continue codepoints,
/// then `\u` extension. Always tagged `.identifier`, never escape-flagged —
/// matching the main lexer's dedicated high-byte arm.
fn scanHighIdentRun(src: []const u8, start: u32, n: u32) u32 {
    const run_end = identByteRun(src, start, n);
    const start_len: u32 = @intCast(std.unicode.utf8ByteSequenceLength(src[start]) catch 1);
    var trim_end = run_end;
    while (trim_end > start + start_len) {
        var back = trim_end - 1;
        while (back > start and (src[back] & 0xC0) == 0x80) back -= 1;
        const bb = src[back];
        if (bb < 0x80) break;
        const bl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(bb) catch 1);
        const bcp = std.unicode.utf8Decode(src[back .. back + bl]) catch 0;
        if (uid.isIdContinueJS(@intCast(bcp))) break;
        trim_end = back;
    }
    return extendEscapes(src, trim_end, n);
}

/// Scan an identifier whose first codepoint is a `\u` escape (`\uXXXX...`).
fn scanEscapedIdentStart(src: []const u8, start: u32, n: u32) IdentResult {
    // A `\` not followed by `u` is a one-byte invalid token.
    if (start + 1 >= n or src[start + 1] != 'u') {
        return .{ .end = start + 1, .tag = .invalid, .has_escape = true };
    }
    const first = parseUnicodeEscape(src, start, n);
    if (!first.ok or !cpIsIdStart(first.cp)) {
        return .{ .end = first.end, .tag = .invalid, .has_escape = true };
    }
    var end = first.end;
    while (end < n) {
        const c = src[end];
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$') {
            end += 1;
            continue;
        }
        if (c >= 0x80) {
            const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(c) catch 1);
            if (end + cl <= n) {
                const cont_cp = std.unicode.utf8Decode(src[end .. end + cl]) catch 0;
                if (uid.isIdContinueJS(cont_cp)) {
                    end += cl;
                    continue;
                }
            }
            break;
        }
        if (c == '\\' and end + 1 < n and src[end + 1] == 'u') {
            const esc = parseUnicodeEscape(src, end, n);
            if (!esc.ok or !cpIsIdContinue(esc.cp)) break;
            end = esc.end;
            continue;
        }
        break;
    }
    const tag: Tag = if (decodedIsKeyword(src, start, end)) .escaped_keyword else .identifier;
    return .{ .end = end, .tag = tag, .has_escape = true };
}

/// ASCII identifier-start byte (high bytes are dispatched separately).
inline fn isIdentStartByte(c: u8) bool {
    const l = c | 0x20;
    return (l >= 'a' and l <= 'z') or c == '_' or c == '$';
}

const Op = struct { tag: Tag, end: u32 };

fn scanOp(src: []const u8, i: u32, n: u32) Op {
    const c = src[i];
    const c1: u8 = if (i + 1 < n) src[i + 1] else 0;
    const c2: u8 = if (i + 2 < n) src[i + 2] else 0;
    const c3: u8 = if (i + 3 < n) src[i + 3] else 0;
    return switch (c) {
        '(' => .{ .tag = .l_paren, .end = i + 1 },
        ')' => .{ .tag = .r_paren, .end = i + 1 },
        '[' => .{ .tag = .l_bracket, .end = i + 1 },
        ']' => .{ .tag = .r_bracket, .end = i + 1 },
        '{' => .{ .tag = .l_brace, .end = i + 1 },
        '}' => .{ .tag = .r_brace, .end = i + 1 },
        ';' => .{ .tag = .semicolon, .end = i + 1 },
        ',' => .{ .tag = .comma, .end = i + 1 },
        ':' => .{ .tag = .colon, .end = i + 1 },
        '~' => .{ .tag = .tilde, .end = i + 1 },
        '@' => .{ .tag = .at_sign, .end = i + 1 },
        '#' => .{ .tag = .hash, .end = i + 1 },
        '.' => if (c1 == '.' and c2 == '.') .{ .tag = .ellipsis, .end = i + 3 } else .{ .tag = .dot, .end = i + 1 },
        '?' => if (c1 == '?') (if (c2 == '=') Op{ .tag = .question_question_equal, .end = i + 3 } else Op{ .tag = .question_question, .end = i + 2 }) else if (c1 == '.' and !(c2 >= '0' and c2 <= '9')) Op{ .tag = .question_dot, .end = i + 2 } else Op{ .tag = .question, .end = i + 1 },
        '=' => if (c1 == '=' and c2 == '=') .{ .tag = .equal_equal_equal, .end = i + 3 } else if (c1 == '=') .{ .tag = .equal_equal, .end = i + 2 } else if (c1 == '>') .{ .tag = .arrow, .end = i + 2 } else .{ .tag = .equal, .end = i + 1 },
        '!' => if (c1 == '=' and c2 == '=') .{ .tag = .bang_equal_equal, .end = i + 3 } else if (c1 == '=') .{ .tag = .bang_equal, .end = i + 2 } else .{ .tag = .bang, .end = i + 1 },
        '+' => if (c1 == '+') .{ .tag = .plus_plus, .end = i + 2 } else if (c1 == '=') .{ .tag = .plus_equal, .end = i + 2 } else .{ .tag = .plus, .end = i + 1 },
        '-' => if (c1 == '-') .{ .tag = .minus_minus, .end = i + 2 } else if (c1 == '=') .{ .tag = .minus_equal, .end = i + 2 } else .{ .tag = .minus, .end = i + 1 },
        '*' => if (c1 == '*' and c2 == '=') .{ .tag = .asterisk_asterisk_equal, .end = i + 3 } else if (c1 == '*') .{ .tag = .asterisk_asterisk, .end = i + 2 } else if (c1 == '=') .{ .tag = .asterisk_equal, .end = i + 2 } else .{ .tag = .asterisk, .end = i + 1 },
        '%' => if (c1 == '=') .{ .tag = .percent_equal, .end = i + 2 } else .{ .tag = .percent, .end = i + 1 },
        '/' => if (c1 == '=') .{ .tag = .slash_equal, .end = i + 2 } else .{ .tag = .slash, .end = i + 1 },
        '^' => if (c1 == '=') .{ .tag = .caret_equal, .end = i + 2 } else .{ .tag = .caret, .end = i + 1 },
        '&' => if (c1 == '&' and c2 == '=') .{ .tag = .ampersand_ampersand_equal, .end = i + 3 } else if (c1 == '&') .{ .tag = .ampersand_ampersand, .end = i + 2 } else if (c1 == '=') .{ .tag = .ampersand_equal, .end = i + 2 } else .{ .tag = .ampersand, .end = i + 1 },
        '|' => if (c1 == '|' and c2 == '=') .{ .tag = .pipe_pipe_equal, .end = i + 3 } else if (c1 == '|') .{ .tag = .pipe_pipe, .end = i + 2 } else if (c1 == '=') .{ .tag = .pipe_equal, .end = i + 2 } else .{ .tag = .pipe, .end = i + 1 },
        '<' => if (c1 == '<' and c2 == '=') .{ .tag = .less_less_equal, .end = i + 3 } else if (c1 == '<') .{ .tag = .less_less, .end = i + 2 } else if (c1 == '=') .{ .tag = .less_equal, .end = i + 2 } else .{ .tag = .less_than, .end = i + 1 },
        '>' => if (c1 == '>' and c2 == '>' and c3 == '=') .{ .tag = .greater_greater_greater_equal, .end = i + 4 } else if (c1 == '>' and c2 == '>') .{ .tag = .greater_greater_greater, .end = i + 3 } else if (c1 == '>' and c2 == '=') .{ .tag = .greater_greater_equal, .end = i + 3 } else if (c1 == '>') .{ .tag = .greater_greater, .end = i + 2 } else if (c1 == '=') .{ .tag = .greater_equal, .end = i + 2 } else .{ .tag = .greater_than, .end = i + 1 },
        else => .{ .tag = .invalid, .end = i + 1 },
    };
}

/// Tokenize `src` into a `TokenList` using the default options, matching
/// `Lexer.tokenizeWithLanguage`. `language` selects the TS keyword set and JSX.
pub fn tokenizeScalar(alloc: std.mem.Allocator, src: []const u8, language: Language) !TokenList {
    return tokenizeScalarWithOptions(alloc, src, language, .{});
}

/// Tokenize `src` into a `TokenList`, matching `Lexer.tokenizeWithAllOptions`.
/// `opts.is_module` / `opts.annex_b` gate Annex B HTML comments; the streaming
/// publish fields are accepted but ignored (this tokenizer is not incremental).
pub fn tokenizeScalarWithOptions(
    alloc: std.mem.Allocator,
    src: []const u8,
    language: Language,
    opts: Lex.TokenizeOptions,
) !TokenList {
    var toks: TokenList = .empty;
    try toks.ensureTotalCapacity(alloc, @max(src.len / 4 + 16, 64));
    const n: u32 = @intCast(src.len);
    const is_ts = language.isTs();
    const is_jsx = language.isJsx();
    var i: u32 = 0;
    var saw_nl = false;
    var at_line_start = true;
    var prev_kind: Tag = .eof;
    var tmpl_depth: u32 = 0;
    var brace_d: [16]u32 = @splat(0);
    // JSX opening-tag header depth and `{...}` nesting within it; used to
    // classify a string as a JSX attribute value vs. an ordinary string.
    var jsx_tag_depth: u32 = 0;
    var jsx_brace_nest: u32 = 0;
    // Annex B HTML comments (`<!--` / `-->`) are enabled only in non-module
    // scripts with annex_b set.
    const annex_b = opts.annex_b;
    const is_module = opts.is_module;

    // Hashbang `#!...` only valid at byte 0.
    if (n >= 2 and src[0] == '#' and src[1] == '!') {
        i = lineTerminatorScan(src, 2, n);
        try toks.append(alloc, .{ .tag = .hashbang, .start = 0, .len = i, .has_newline_before = false });
        at_line_start = false;
    }

    while (i < n) {
        const c = src[i];
        switch (c) {
            ' ', '\t', 0x0B, 0x0C => { i += 1; continue; },
            '\n' => { saw_nl = true; at_line_start = true; i += 1; continue; },
            '\r' => { saw_nl = true; at_line_start = true; i += 1; continue; },
            '<' => {
                // Annex B HTML open comment `<!--` (non-module scripts).
                if (annex_b and !is_module and i + 3 < n and src[i + 1] == '!' and src[i + 2] == '-' and src[i + 3] == '-') {
                    i = lineTerminatorScan(src, i + 4, n);
                    saw_nl = true;
                    continue;
                }
            },
            '-' => {
                // Annex B HTML close comment `-->` (only at logical line start).
                if (annex_b and !is_module and at_line_start and i + 2 < n and src[i + 1] == '-' and src[i + 2] == '>') {
                    i = lineTerminatorScan(src, i + 3, n);
                    saw_nl = true;
                    continue;
                }
            },
            '/' => {
                if (i + 1 < n and src[i + 1] == '/') {
                    const ce = lineTerminatorScan(src, i + 2, n);
                    // JSX: a `//` inside JSX text content (where the line also
                    // contains `</`) is literal text, not a comment. Skip both
                    // slashes so the rest of the line stays visible.
                    if (is_jsx and !(i > 0 and src[i - 1] == '/')) {
                        var k = i + 2;
                        while (k + 1 < ce) : (k += 1) {
                            if (src[k] == '<' and src[k + 1] == '/') {
                                i += 2;
                                break;
                            }
                        } else {
                            i = ce;
                            saw_nl = true;
                        }
                        continue;
                    }
                    i = ce;
                    saw_nl = true;
                    continue;
                }
                if (i + 1 < n and src[i + 1] == '*') {
                    const res = Lex.blockCommentEnd(src, i);
                    if (res.has_nl) { saw_nl = true; at_line_start = true; }
                    if (res.end >= n and !(n >= 2 and src[n - 2] == '*' and src[n - 1] == '/')) {
                        // JSX: an unterminated `/*` in JSX text is a literal `/`,
                        // not an error. Emit it as a slash and resume after it.
                        if (is_jsx) {
                            if (toks.len >= toks.capacity) try toks.ensureTotalCapacity(alloc, toks.capacity * 2 + 16);
                            toks.appendAssumeCapacity(.{ .tag = .slash, .start = i, .len = 1, .has_newline_before = saw_nl });
                            prev_kind = .slash;
                            saw_nl = false;
                            at_line_start = false;
                            i += 1;
                            continue;
                        }
                        // `Lex.blockCommentEnd`'s scalar tail can miss a trailing
                        // newline byte; rescan the body so an unterminated comment's
                        // newline still propagates to the following token.
                        if (!res.has_nl) {
                            var q = i + 2;
                            while (q < n) : (q += 1) {
                                const cc = src[q];
                                if (cc == '\n' or cc == '\r' or
                                    (cc == 0xE2 and q + 2 < n and src[q + 1] == 0x80 and (src[q + 2] == 0xA8 or src[q + 2] == 0xA9)))
                                {
                                    saw_nl = true;
                                    break;
                                }
                            }
                        }
                        // Unterminated block comment → single invalid token, then stop.
                        if (toks.len >= toks.capacity) try toks.ensureTotalCapacity(alloc, toks.capacity * 2 + 16);
                        toks.appendAssumeCapacity(.{ .tag = .invalid, .start = i, .len = res.end - i, .has_newline_before = saw_nl });
                        i = res.end;
                        // Note: saw_nl is intentionally left set — the main lexer
                        // breaks here without clearing it, so a trailing EOF inherits
                        // any newline seen inside the unterminated comment.
                        continue;
                    }
                    i = res.end;
                    continue;
                }
            },
            else => {},
        }
        // High-byte line terminators / whitespace / BOM.
        if (c >= 0x80) {
            if (c == 0xE2 and i + 2 < n and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) {
                saw_nl = true;
                at_line_start = true;
                i += 3;
                continue;
            }
            if (c == 0xEF and i + 2 < n and src[i + 1] == 0xBB and src[i + 2] == 0xBF) {
                i += 3;
                continue;
            }
            const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(c) catch 1);
            if (i + cl > n) {
                // Truncated UTF-8 sequence at EOF: skip one byte.
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(src[i .. i + cl]) catch 0;
            if (lexer.isUnicodeWhitespace(@intCast(cp))) {
                i += cl;
                continue;
            }
        }
        const prev = prev_kind;
        const start = i;
        var tag: Tag = undefined;
        var has_esc = false;
        if (c < 0x80 and isIdentStartByte(c)) {
            // Hot path: SIMD-scan the ASCII identifier body. If it stops on a
            // plain delimiter (not `\` or a 0x80+ byte), it is a pure-ASCII
            // identifier — no escape decoding or Unicode validation needed.
            const e = asciiIdentEnd(src, start, n);
            const stop: u8 = if (e < n) src[e] else 0;
            if (stop == '\\' or stop >= 0x80) {
                @branchHint(.cold);
                const r = scanIdentRun(src, start, n, prev, is_ts);
                tag = r.tag;
                has_esc = r.has_escape;
                i = r.end;
            } else {
                i = e;
                tag = if (isPropertyAccess(prev)) .identifier else lexer.keywordLookup(src[start..e], is_ts);
            }
        } else if (c >= 0x80) {
            // High-byte start (whitespace/BOM/LS/PS/truncation already filtered).
            const sl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(c) catch 1);
            const start_cp = std.unicode.utf8Decode(src[start .. start + sl]) catch 0;
            if (!uid.isIdStart(@intCast(start_cp))) {
                tag = .invalid;
                i = start + sl;
            } else {
                tag = .identifier;
                i = scanHighIdentRun(src, start, n);
            }
        } else if (c == '\\') {
            const r = scanEscapedIdentStart(src, start, n);
            tag = r.tag;
            has_esc = r.has_escape;
            i = r.end;
        } else if (c >= '0' and c <= '9') {
            i = Lex.numberEnd(src, start);
            const is_bn = i > start and src[i - 1] == 'n';
            tag = if (!lexer.validateNumericLiteral(src, start, i) or (i < n and lexer.isIdentStartAtPos(src, i)))
                .invalid
            else if (is_bn) .bigint_literal else .number_literal;
        } else if (c == '.' and i + 1 < n and src[i + 1] >= '0' and src[i + 1] <= '9') {
            i = Lex.numberEnd(src, start);
            tag = if (!lexer.validateNumericLiteral(src, start, i) or (i < n and lexer.isIdentStartAtPos(src, i)))
                .invalid
            else
                .number_literal;
        } else if (c == '"' or c == '\'') {
            tag = .string_literal;
            // JSX attribute value (`<div id="x">`, prev `=` inside a tag header):
            // no escapes, terminate at `<`. JSX text content (prev `>` or an
            // identifier): terminate at `<` but still a string. Otherwise plain JS.
            const jsx_attr = is_jsx and prev == .equal and jsx_tag_depth > 0;
            const jsx_text = is_jsx and (prev == .greater_than or prev == .identifier);
            i = scanStringJsx(src, start, n, jsx_attr or jsx_text, jsx_attr);
        } else if (c == '/' and Lex.regexAllowed(prev) and !(is_jsx and (prev == .less_than or prev == .greater_than))) {
            tag = .regex_literal;
            i = Lex.regexEnd(src, start);
        } else if (c == '`') {
            const res = Lex.templateChunkEnd(src, start);
            i = res.end;
            if (!res.terminated) {
                tag = .invalid;
            } else if (res.has_expr) {
                tag = .template_head;
                if (tmpl_depth < brace_d.len) {
                    brace_d[tmpl_depth] = 0;
                    tmpl_depth += 1;
                }
            } else tag = .template_no_sub;
        } else if (c == '{') {
            if (tmpl_depth > 0) brace_d[tmpl_depth - 1] += 1;
            tag = .l_brace;
            i += 1;
        } else if (c == '}') {
            if (tmpl_depth > 0 and brace_d[tmpl_depth - 1] == 0) {
                const res = Lex.templateChunkEnd(src, start);
                i = res.end;
                if (!res.terminated) {
                    tag = .invalid;
                } else if (res.has_expr) {
                    tag = .template_middle;
                } else {
                    tag = .template_tail;
                    tmpl_depth -= 1;
                }
            } else {
                if (tmpl_depth > 0) brace_d[tmpl_depth - 1] -= 1;
                tag = .r_brace;
                i += 1;
            }
        } else if (c == '-' and at_line_start and (is_module or !annex_b) and
            i + 2 < n and src[i + 1] == '-' and src[i + 2] == '>')
        {
            // A line-start `-->` outside Annex B (module, or annex_b disabled)
            // is not an HTML close comment — it is a single invalid token.
            tag = .invalid;
            i += 3;
        } else {
            const r = scanOp(src, i, n);
            tag = r.tag;
            i = r.end;
        }
        if (toks.len >= toks.capacity) try toks.ensureTotalCapacity(alloc, toks.capacity * 2 + 16);
        toks.appendAssumeCapacity(.{ .tag = tag, .start = start, .len = i - start, .has_newline_before = saw_nl, .has_unicode_escape = has_esc });

        // Maintain JSX opening-tag depth. `<` opens a JSX element when in
        // expression/child position (regexAllowed) and followed by a tag-name
        // start or `>` (fragment); `{`/`}` nest inside the tag header; `>`
        // closes the header.
        if (is_jsx) {
            switch (tag) {
                .less_than => {
                    if (Lex.regexAllowed(prev)) {
                        const nb: u8 = if (i < n) src[i] else 0;
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

        prev_kind = if (isPropertyAccess(prev) and tag.isKeyword()) .identifier else tag;
        saw_nl = false;
        at_line_start = false;
    }
    try toks.append(alloc, .{ .tag = .eof, .start = n, .len = 0, .has_newline_before = saw_nl });
    return toks;
}
