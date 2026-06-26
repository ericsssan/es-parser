//! Single-pass scalar tokenizer.
//!
//! Produces the same `TokenList` token stream as `lexer.zig` and serves as a
//! drop-in tokenizer with the parser unchanged. Scans the source once with a per-first-byte dispatch and plain
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
/// (`jsx_no_escape`) treat `\` as a literal byte.
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

/// Decode a UTF-8 sequence of known length `len` (1–4) at `i` without
/// re-validating. Callers establish the length with `utf8ByteSequenceLength`
/// and `i + len <= n` first, so the validating `std.unicode.utf8Decode` re-does
/// that work; on the conformance corpus this yields identical codepoints (and
/// for malformed bytes, ones that fail ID/whitespace classification just as the
/// `catch 0` path did — verified by the differential harness).
inline fn decodeKnownLen(src: []const u8, i: u32, len: u32) u32 {
    return switch (len) {
        2 => (@as(u32, src[i] & 0x1F) << 6) | @as(u32, src[i + 1] & 0x3F),
        3 => (@as(u32, src[i] & 0x0F) << 12) | (@as(u32, src[i + 1] & 0x3F) << 6) | @as(u32, src[i + 2] & 0x3F),
        4 => (@as(u32, src[i] & 0x07) << 18) | (@as(u32, src[i + 1] & 0x3F) << 12) | (@as(u32, src[i + 2] & 0x3F) << 6) | @as(u32, src[i + 3] & 0x3F),
        else => src[i],
    };
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

/// Hex-digit value (0–15) for each byte, or 0xFF for non-hex. Lets the escape
/// parser decode without per-digit branches: OR the four looked-up nibbles and
/// a single `& 0xF0 != 0` test flags any non-hex digit.
const hex_lut: [256]u8 = blk: {
    var t: [256]u8 = @splat(0xFF);
    for ('0'..'9' + 1) |c| t[c] = c - '0';
    for ('a'..'f' + 1) |c| t[c] = @as(u8, c - 'a') + 10;
    for ('A'..'F' + 1) |c| t[c] = @as(u8, c - 'A') + 10;
    break :blk t;
};

/// Parse a `\uXXXX` or `\u{...}` escape starting at `p` (which points at `\`).
/// Returns the codepoint, the end offset, and whether it was well-formed. The
/// `cp` value is only meaningful when `ok` (callers bail on `!ok` before using
/// it), so invalid digits need not contribute zero — they just set `ok=false`.
fn parseUnicodeEscape(src: []const u8, p: u32, n: u32) struct { cp: u32, end: u32, ok: bool } {
    var e: u32 = p + 2; // skip "\u"
    if (e < n and src[e] == '{') {
        e += 1;
        var cp: u32 = 0;
        var bad: u8 = 0;
        while (e < n and src[e] != '}') : (e += 1) {
            const h = hex_lut[src[e]];
            bad |= h;
            cp = (cp << 4) | (h & 0x0F);
        }
        const closed = e < n and src[e] == '}';
        if (closed) e += 1;
        return .{ .cp = cp, .end = e, .ok = closed and (bad & 0xF0) == 0 };
    } else if (e + 4 <= n) {
        const h0 = hex_lut[src[e]];
        const h1 = hex_lut[src[e + 1]];
        const h2 = hex_lut[src[e + 2]];
        const h3 = hex_lut[src[e + 3]];
        const cp = (@as(u32, h0 & 0x0F) << 12) | (@as(u32, h1 & 0x0F) << 8) | (@as(u32, h2 & 0x0F) << 4) | (h3 & 0x0F);
        return .{ .cp = cp, .end = e + 4, .ok = ((h0 | h1 | h2 | h3) & 0xF0) == 0 };
    } else {
        return .{ .cp = 0, .end = p + 2, .ok = false };
    }
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

/// Accumulates the decoded codepoints of an escaped identifier to test whether
/// it spells a reserved word — fed incrementally by the ident scanners during
/// their single validation pass, so the keyword check needs no second decode.
///
/// Reserved words are 2–10 lowercase ASCII letters, so `ok` goes false the moment
/// a decoded codepoint can't belong to one (outside `a`–`z`) or the length passes
/// 10; once false the scanners stop feeding it. This mirrors the old
/// `decodedIsKeyword`'s early-bail (digits, `_`, `$`, uppercase, high bytes, or
/// over-long names exit immediately without touching the keyword map).
const KwAcc = struct {
    buf: [10]u8 = undefined,
    len: u8 = 0,
    ok: bool = true,

    inline fn push(self: *KwAcc, dc: u32) void {
        if (!self.ok) return;
        if (dc < 'a' or dc > 'z' or self.len == self.buf.len) {
            self.ok = false;
            return;
        }
        self.buf[self.len] = @intCast(dc);
        self.len += 1;
    }

    inline fn isKeyword(self: *const KwAcc) bool {
        return self.ok and token.keywords.get(self.buf[0..self.len]) != null;
    }
};

/// Whether the identifier text `src[start..end]` (resolving `\u` escapes) spells
/// a reserved word. The scanners normally feed a `KwAcc` during their validation
/// pass instead; this standalone decode is the fallback for the rare case where a
/// trailing high byte was trimmed after the accumulator had already consumed it.
fn decodedIsKeyword(src: []const u8, start: u32, end: u32) bool {
    var acc: KwAcc = .{};
    var raw_i: u32 = start;
    while (raw_i < end) {
        if (src[raw_i] == '\\' and raw_i + 1 < end and src[raw_i + 1] == 'u') {
            const esc = parseUnicodeEscape(src, raw_i, end);
            acc.push(esc.cp);
            raw_i = esc.end;
        } else {
            acc.push(src[raw_i]);
            raw_i += 1;
        }
        if (!acc.ok) return false;
    }
    return acc.isKeyword();
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
/// When `acc` is non-null, the decoded codepoints are fed to it (in source order)
/// for the keyword check, so callers needing it avoid a second decode pass.
fn extendEscapes(src: []const u8, end0: u32, n: u32, acc: ?*KwAcc) u32 {
    var end = end0;
    while (end < n and src[end] == '\\' and end + 1 < n and src[end + 1] == 'u') {
        const esc = parseUnicodeEscape(src, end, n);
        if (!esc.ok or !cpIsIdContinue(esc.cp)) break;
        if (acc) |a| a.push(esc.cp);
        end = esc.end;
        while (end < n) {
            const cc = src[end];
            if ((cc >= 'a' and cc <= 'z') or (cc >= 'A' and cc <= 'Z') or (cc >= '0' and cc <= '9') or cc == '_' or cc == '$') {
                if (acc) |a| a.push(cc);
                end += 1;
                continue;
            }
            if (cc >= 0x80) {
                const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(cc) catch 1);
                if (end + cl <= n) {
                    const cont_cp = decodeKnownLen(src, end, cl);
                    if (uid.isIdContinueJS(@intCast(cont_cp))) {
                        // A high codepoint can't belong to a reserved word; the
                        // old per-byte decode bailed here, so mark the accumulator.
                        if (acc) |a| a.push(cc);
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
    // Feed the keyword accumulator the ASCII byte-run (no escapes appear here —
    // identByteRun stops at `\`); extendEscapes feeds the escape continuations.
    // Only consulted on the escaped path, and only when no high byte is trimmed
    // below (the trim can cut a char the accumulator already saw).
    var acc: KwAcc = .{};
    {
        var bi = start;
        while (bi < bm_end) : (bi += 1) acc.push(src[bi]);
    }
    const pre_trim_end = extendEscapes(src, bm_end, n, &acc);
    var end = pre_trim_end;
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
        const cc = decodeKnownLen(src, scan_i, cl);
        if (lexer.isUnicodeWhitespace(@intCast(cc)) or !uid.isIdContinueJS(@intCast(cc))) {
            valid_end = scan_i;
            break;
        }
        scan_i += cl;
    }
    end = valid_end;
    var tag: Tag = undefined;
    if (has_escape) {
        // Common case (no high byte trimmed): the fused accumulator covers
        // exactly src[start..end]. If a trim shortened the span, the accumulator
        // may have already consumed the trimmed char, so re-decode the final span.
        const is_kw = if (valid_end == pre_trim_end) acc.isKeyword() else decodedIsKeyword(src, start, end);
        tag = if (is_kw) .escaped_keyword else .identifier;
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
        if (back + bl > n) { trim_end = back; continue; } // truncated sequence at EOF
        const bcp = decodeKnownLen(src, back, bl);
        if (uid.isIdContinueJS(@intCast(bcp))) break;
        trim_end = back;
    }
    // High-byte-start idents are always `.identifier` (never a reserved word),
    // so no keyword accumulator is needed.
    return extendEscapes(src, trim_end, n, null);
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
    // Accumulate decoded codepoints for the keyword check in this same pass.
    // This loop computes the final `end` directly (no post-trim), so the
    // accumulator always covers exactly `src[start..end]`.
    var acc: KwAcc = .{};
    acc.push(first.cp);
    var end = first.end;
    while (end < n) {
        const c = src[end];
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$') {
            acc.push(c);
            end += 1;
            continue;
        }
        if (c >= 0x80) {
            const cl: u32 = @intCast(std.unicode.utf8ByteSequenceLength(c) catch 1);
            if (end + cl <= n) {
                const cont_cp = decodeKnownLen(src, end, cl);
                if (uid.isIdContinueJS(cont_cp)) {
                    acc.push(c); // high codepoint → can't be a reserved word
                    end += cl;
                    continue;
                }
            }
            break;
        }
        if (c == '\\' and end + 1 < n and src[end + 1] == 'u') {
            const esc = parseUnicodeEscape(src, end, n);
            if (!esc.ok or !cpIsIdContinue(esc.cp)) break;
            acc.push(esc.cp);
            end = esc.end;
            continue;
        }
        break;
    }
    const tag: Tag = if (acc.isKeyword()) .escaped_keyword else .identifier;
    return .{ .end = end, .tag = tag, .has_escape = true };
}

/// ASCII identifier-start byte (high bytes are dispatched separately).
inline fn isIdentStartByte(c: u8) bool {
    const l = c | 0x20;
    return (l >= 'a' and l <= 'z') or c == '_' or c == '$';
}

const Op = struct { tag: Tag, end: u32 };

inline fn scanOp(src: []const u8, i: u32, n: u32) Op {
    const c = src[i];
    // Single-char delimiters are the common case — return before touching any
    // lookahead. Multi-char-capable operators read c1/c2/c3 lazily, only down
    // the branch that needs them, so the hot single-char path costs one switch
    // and no bounds-checked lookahead loads.
    switch (c) {
        '(' => return .{ .tag = .l_paren, .end = i + 1 },
        ')' => return .{ .tag = .r_paren, .end = i + 1 },
        '[' => return .{ .tag = .l_bracket, .end = i + 1 },
        ']' => return .{ .tag = .r_bracket, .end = i + 1 },
        '{' => return .{ .tag = .l_brace, .end = i + 1 },
        '}' => return .{ .tag = .r_brace, .end = i + 1 },
        ';' => return .{ .tag = .semicolon, .end = i + 1 },
        ',' => return .{ .tag = .comma, .end = i + 1 },
        ':' => return .{ .tag = .colon, .end = i + 1 },
        '~' => return .{ .tag = .tilde, .end = i + 1 },
        '@' => return .{ .tag = .at_sign, .end = i + 1 },
        '#' => return .{ .tag = .hash, .end = i + 1 },
        else => {},
    }
    const c1: u8 = if (i + 1 < n) src[i + 1] else 0;
    return switch (c) {
        '.' => if (c1 == '.' and (if (i + 2 < n) src[i + 2] else 0) == '.') .{ .tag = .ellipsis, .end = i + 3 } else .{ .tag = .dot, .end = i + 1 },
        '?' => if (c1 == '?') (if ((if (i + 2 < n) src[i + 2] else 0) == '=') Op{ .tag = .question_question_equal, .end = i + 3 } else Op{ .tag = .question_question, .end = i + 2 }) else if (c1 == '.' and !((if (i + 2 < n) src[i + 2] else 0) >= '0' and (if (i + 2 < n) src[i + 2] else 0) <= '9')) Op{ .tag = .question_dot, .end = i + 2 } else Op{ .tag = .question, .end = i + 1 },
        '=' => if (c1 == '=' and (if (i + 2 < n) src[i + 2] else 0) == '=') .{ .tag = .equal_equal_equal, .end = i + 3 } else if (c1 == '=') .{ .tag = .equal_equal, .end = i + 2 } else if (c1 == '>') .{ .tag = .arrow, .end = i + 2 } else .{ .tag = .equal, .end = i + 1 },
        '!' => if (c1 == '=' and (if (i + 2 < n) src[i + 2] else 0) == '=') .{ .tag = .bang_equal_equal, .end = i + 3 } else if (c1 == '=') .{ .tag = .bang_equal, .end = i + 2 } else .{ .tag = .bang, .end = i + 1 },
        '+' => if (c1 == '+') .{ .tag = .plus_plus, .end = i + 2 } else if (c1 == '=') .{ .tag = .plus_equal, .end = i + 2 } else .{ .tag = .plus, .end = i + 1 },
        '-' => if (c1 == '-') .{ .tag = .minus_minus, .end = i + 2 } else if (c1 == '=') .{ .tag = .minus_equal, .end = i + 2 } else .{ .tag = .minus, .end = i + 1 },
        '*' => if (c1 == '*' and (if (i + 2 < n) src[i + 2] else 0) == '=') .{ .tag = .asterisk_asterisk_equal, .end = i + 3 } else if (c1 == '*') .{ .tag = .asterisk_asterisk, .end = i + 2 } else if (c1 == '=') .{ .tag = .asterisk_equal, .end = i + 2 } else .{ .tag = .asterisk, .end = i + 1 },
        '%' => if (c1 == '=') .{ .tag = .percent_equal, .end = i + 2 } else .{ .tag = .percent, .end = i + 1 },
        '/' => if (c1 == '=') .{ .tag = .slash_equal, .end = i + 2 } else .{ .tag = .slash, .end = i + 1 },
        '^' => if (c1 == '=') .{ .tag = .caret_equal, .end = i + 2 } else .{ .tag = .caret, .end = i + 1 },
        '&' => if (c1 == '&' and (if (i + 2 < n) src[i + 2] else 0) == '=') .{ .tag = .ampersand_ampersand_equal, .end = i + 3 } else if (c1 == '&') .{ .tag = .ampersand_ampersand, .end = i + 2 } else if (c1 == '=') .{ .tag = .ampersand_equal, .end = i + 2 } else .{ .tag = .ampersand, .end = i + 1 },
        '|' => if (c1 == '|' and (if (i + 2 < n) src[i + 2] else 0) == '=') .{ .tag = .pipe_pipe_equal, .end = i + 3 } else if (c1 == '|') .{ .tag = .pipe_pipe, .end = i + 2 } else if (c1 == '=') .{ .tag = .pipe_equal, .end = i + 2 } else .{ .tag = .pipe, .end = i + 1 },
        '<' => if (c1 == '<' and (if (i + 2 < n) src[i + 2] else 0) == '=') .{ .tag = .less_less_equal, .end = i + 3 } else if (c1 == '<') .{ .tag = .less_less, .end = i + 2 } else if (c1 == '=') .{ .tag = .less_equal, .end = i + 2 } else .{ .tag = .less_than, .end = i + 1 },
        '>' => blk: {
            const c2: u8 = if (i + 2 < n) src[i + 2] else 0;
            break :blk if (c1 == '>' and c2 == '>' and (if (i + 3 < n) src[i + 3] else 0) == '=') .{ .tag = .greater_greater_greater_equal, .end = i + 4 } else if (c1 == '>' and c2 == '>') .{ .tag = .greater_greater_greater, .end = i + 3 } else if (c1 == '>' and c2 == '=') .{ .tag = .greater_greater_equal, .end = i + 3 } else if (c1 == '>') .{ .tag = .greater_greater, .end = i + 2 } else if (c1 == '=') .{ .tag = .greater_equal, .end = i + 2 } else .{ .tag = .greater_than, .end = i + 1 };
        },
        else => .{ .tag = .invalid, .end = i + 1 },
    };
}

/// One lexed token. Mirrors the `TokenList` element fields.
pub const Token = struct {
    tag: Tag,
    start: u32,
    len: u32,
    has_newline_before: bool,
    has_unicode_escape: bool = false,
};

/// Top bit of a JSX frame marks an expression container (vs an element body);
/// the low bits count its nested object/block braces (#61).
const JSX_EXPR_BIT: u32 = 0x8000_0000;

/// Per-call JSX element-body tracking state (#61). Comptime-conditional: returns a
/// zero-size struct when text tokenization is off, so the non-JSX / TSX instantiation
/// of the lexer carries no frame array and no tracking fields at all.
fn JsxState(comptime enabled: bool) type {
    if (!enabled) return struct {};
    return struct {
        in_text: bool = false,
        closing: bool = false, // the `<` just seen begins a closing tag `</…`
        sp: u32 = 0,
        frame_inline: [64]u32 = undefined,
        frame_ptr: [*]u32 = undefined,
        frame_cap: u32 = 64,
        frame_heap: ?[]u32 = null,
        text_nl: bool = false, // last jsx_text token contained a line terminator
    };
}

/// Tokenize `src` into a `TokenList` using the default options, matching
/// `Lexer.tokenizeWithLanguage`. `language` selects the TS keyword set and JSX.
pub fn tokenizeScalar(alloc: std.mem.Allocator, src: []const u8, language: Language) !TokenList {
    return tokenizeScalarWithOptions(alloc, src, language, .{});
}

/// Full front-end result: tokens + comment trivia + line starts, matching the
/// (now-retired) bitmap lexer's `TokenizeResult`. The parse-only path uses
/// `tokenizeScalar` (tokens only, no trivia cost); callers that need comments /
/// line starts (diagnostics, lint directives) use this.
pub fn tokenizeScalarFull(alloc: std.mem.Allocator, src: []const u8, language: Language, opts: Lex.TokenizeOptions) !Lex.TokenizeResult {
    var sink = Lex.CommentSink{};
    errdefer sink.deinit(alloc);
    // Single pass: comment trivia is recorded as the tokenizer scans. Line starts
    // are no longer produced here — the diagnostic/location layer builds them
    // lazily from source (see `span.LineIndex`) so clean files never pay for them.
    var o = opts;
    o.comment_sink = &sink;
    var tokens = try tokenizeScalarWithOptions(alloc, src, language, o);
    errdefer tokens.deinit(alloc);
    const count: u32 = @intCast(sink.starts.items.len);
    const comment_starts = try sink.starts.toOwnedSlice(alloc);
    errdefer alloc.free(comment_starts);
    const comment_ends = try sink.ends.toOwnedSlice(alloc);
    errdefer alloc.free(comment_ends);
    const comment_kinds = try sink.kinds.toOwnedSlice(alloc);
    return .{
        .tokens = tokens,
        .comment_starts = comment_starts,
        .comment_ends = comment_ends,
        .comment_kinds = comment_kinds,
        .comment_count = count,
    };
}


/// Tokenize `src` into a `TokenList`, matching `Lexer.tokenizeWithAllOptions`.
///
/// Single eager pass: keeps the hot lexer state (`i`, `prev_kind`, `saw_nl`,
/// `at_line_start`) in locals so it stays in registers across the token-append
/// loop.
pub fn tokenizeScalarWithOptions(
    alloc: std.mem.Allocator,
    src: []const u8,
    language: Language,
    opts: Lex.TokenizeOptions,
) !TokenList {
    // JSX text tokenization (#61) needs to know when a `<tag>` opens an element
    // body. In TSX a `<T>` is ambiguous (JSX element vs generic type arguments vs
    // generic arrow), and only the parser's speculative parse can disambiguate, so
    // element-body tracking is restricted to plain JSX (no TS); TSX keeps the prior
    // token stream. `jsx_text_mode` is threaded as a COMPTIME parameter so the entire
    // text-tracking path compiles away for non-JSX input — the hot lexer used by the
    // overwhelming majority of files is byte-for-byte identical to before.
    if (language.isJsx() and !language.isTs()) {
        return tokenizeScalarImpl(true, alloc, src, language, opts);
    }
    return tokenizeScalarImpl(false, alloc, src, language, opts);
}

fn tokenizeScalarImpl(
    comptime jsx_text_mode: bool,
    alloc: std.mem.Allocator,
    src: []const u8,
    language: Language,
    opts: Lex.TokenizeOptions,
) !TokenList {
    var toks: TokenList = .empty;
    try toks.ensureTotalCapacity(alloc, @max(src.len / 2 + 16, 64));
    const n: u32 = @intCast(src.len);
    const is_ts = language.isTs();
    const is_jsx = language.isJsx();
    var i: u32 = 0;
    var saw_nl = false;
    var at_line_start = true;
    var prev_kind: Tag = .eof;
    var tmpl_depth: u32 = 0;
    // Per-template-level brace-nesting counters. Inline [16] fast path with a
    // lazy heap spill for deeply nested templates (>=16): without it, tmpl_depth
    // stopped incrementing at the cap and the brace tracking desynced, mis-lexing
    // valid ECMAScript with 17+ nested template literals (#19). The spill only
    // ever triggers on that pathological depth; the common case is the inline
    // array, and neither is touched on the hot ident/whitespace path.
    var brace_inline: [16]u32 = @splat(0);
    var brace_ptr: [*]u32 = &brace_inline;
    var brace_cap: u32 = brace_inline.len;
    var brace_heap: ?[]u32 = null;
    defer if (brace_heap) |h| alloc.free(h);
    // JSX opening-tag header depth and `{...}` nesting within it; used to
    // classify a string as a JSX attribute value vs. an ordinary string.
    var jsx_tag_depth: u32 = 0;
    var jsx_brace_nest: u32 = 0;
    // JSX element-body tracking, to emit one `jsx_text` token per text child (#61).
    // The lexer is context-free, so it tracks JSX structure here: a stack of frames,
    // each an element BODY (text context) or an expression container EXPR (JS
    // context). `<tag>` pushes BODY, `</tag>` pops it; `{` inside a body pushes EXPR
    // and its matching `}` pops it (the frame's low bits count nested object/block
    // braces so the right `}` closes the container). `in_text` caches "top frame is a
    // BODY and we are outside any tag header" — the single bit the hot loop tests.
    //
    // The whole struct is comptime-empty when jsx_text_mode is false, so the non-JSX
    // (and TSX) instantiation of this worker carries none of it — no frame array on
    // the stack, no structural-switch code — and is byte-for-byte identical to before.
    var jx: JsxState(jsx_text_mode) = .{};
    if (jsx_text_mode) jx.frame_ptr = &jx.frame_inline;
    defer if (jsx_text_mode) {
        if (jx.frame_heap) |h| alloc.free(h);
    };
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

    // Hoist the SoA column base pointers + len/capacity into locals. MultiArrayList's
    // appendAssumeCapacity reconstructs the column pointers (one multiply-add per field)
    // on every call because the per-token capacity check may mutate the list, so LLVM
    // cannot prove them loop-invariant. Caching them here — refreshed only on the rare
    // growth — removes that per-token pointer math (mirrors the parser's tags_ptr cache).
    var t_cap: u32 = @intCast(toks.capacity);
    var t_len: u32 = @intCast(toks.len);
    var sl = toks.slice();
    var p_tag = sl.items(.tag).ptr;
    var p_start = sl.items(.start).ptr;
    var p_len = sl.items(.len).ptr;
    var p_nl = sl.items(.has_newline_before).ptr;
    var p_esc = sl.items(.has_unicode_escape).ptr;

    while (i < n) {
        const c = src[i];
        const start = i;
        const prev = prev_kind;
        var tag: Tag = undefined;
        var has_esc = false;
        // Identifiers are the most common token in real code, so peel them out as
        // a direct, well-predicted branch ahead of the dispatch switch. Keeping
        // the indirect jump-table off the hot ident path avoids the branch-target
        // mispredictions a single all-classes jump table suffers on mixed input
        // (a full jump table regressed real-world TS while winning on single-class
        // microbenchmarks). Everything else dispatches through the jump table —
        // one indirect branch instead of the former 11-deep if/else chain.
        // No-token cases (whitespace, comments, BOM/LS/PS) `continue`;
        // token-producing cases set `tag`/`i` and fall to the shared emit tail.
        if (jsx_text_mode and jx.in_text and c != '<' and c != '{' and c != '>' and c != '}') {
            // JSX text child (#61): in element-body context, everything up to the
            // next `<` (tag) or `{` (expression container) is one literal jsx_text
            // token, surrounding whitespace included. JSXText excludes `> }` too, so
            // a bare `>`/`}` ends the run and is lexed as its own token — which the
            // parser rejects, matching the reference. `jx.in_text` is only ever set
            // when jsx_text_mode is on, so this branch is dead code off the JSX path.
            @branchHint(.unlikely);
            var j = i + 1;
            var nl = c == '\n' or c == '\r';
            while (j < n and src[j] != '<' and src[j] != '{' and src[j] != '>' and src[j] != '}') : (j += 1) {
                if (src[j] == '\n' or src[j] == '\r') nl = true;
            }
            jx.text_nl = nl;
            tag = .jsx_text;
            i = j;
        } else if (c == ' ' or c == '\t' or c == 0x0B or c == 0x0C) {
            i += 1;
            continue;
        } else if (c == '\n' or c == '\r') {
            saw_nl = true;
            at_line_start = true;
            // `\r\n` advances two bytes as one newline; a lone `\n`/`\r` advances one.
            if (c == '\r' and i + 1 < n and src[i + 1] == '\n') {
                i += 2;
            } else {
                i += 1;
            }
            continue;
        } else if (c < 0x80 and isIdentStartByte(c)) {
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
        } else switch (c) {
            // Single-char operators with no multi-char variant: emit directly
            // from the jump table (one branch) rather than routing through the
            // else-prong + inlined scanOp re-switch.
            '(' => { tag = .l_paren; i += 1; },
            ')' => { tag = .r_paren; i += 1; },
            '[' => { tag = .l_bracket; i += 1; },
            ']' => { tag = .r_bracket; i += 1; },
            ';' => { tag = .semicolon; i += 1; },
            ',' => { tag = .comma; i += 1; },
            ':' => { tag = .colon; i += 1; },
            '~' => { tag = .tilde; i += 1; },
            '@' => { tag = .at_sign; i += 1; },
            '#' => { tag = .hash; i += 1; },

            '0'...'9' => {
                i = Lex.numberEnd(src, start);
                const is_bn = i > start and src[i - 1] == 'n';
                tag = if (!lexer.validateNumericLiteral(src, start, i) or (i < n and lexer.isIdentStartAtPos(src, i)))
                    .invalid
                else if (is_bn) .bigint_literal else .number_literal;
            },

            '"', '\'' => {
                tag = .string_literal;
                // JSX attribute value (prev `=` inside a tag header) / JSX text
                // (prev `>` or identifier): terminate at `<`. Otherwise plain JS.
                const jsx_attr = is_jsx and prev == .equal and jsx_tag_depth > 0;
                const jsx_text = is_jsx and (prev == .greater_than or prev == .identifier);
                i = scanStringJsx(src, start, n, jsx_attr or jsx_text, jsx_attr);
            },

            '`' => {
                const res = Lex.templateChunkEnd(src, start);
                i = res.end;
                if (!res.terminated) {
                    tag = .invalid;
                } else if (res.has_expr) {
                    tag = .template_head;
                    if (tmpl_depth == brace_cap) {
                        // Cold: deeply nested template — grow the brace buffer.
                        @branchHint(.cold);
                        const new_cap = brace_cap * 2;
                        const grown = try alloc.alloc(u32, new_cap);
                        @memcpy(grown[0..brace_cap], brace_ptr[0..brace_cap]);
                        if (brace_heap) |h| alloc.free(h);
                        brace_heap = grown;
                        brace_ptr = grown.ptr;
                        brace_cap = new_cap;
                    }
                    brace_ptr[tmpl_depth] = 0;
                    tmpl_depth += 1;
                } else tag = .template_no_sub;
            },

            '{' => {
                if (tmpl_depth > 0) brace_ptr[tmpl_depth - 1] += 1;
                tag = .l_brace;
                i += 1;
            },

            '}' => {
                if (tmpl_depth > 0 and brace_ptr[tmpl_depth - 1] == 0) {
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
                    if (tmpl_depth > 0) brace_ptr[tmpl_depth - 1] -= 1;
                    tag = .r_brace;
                    i += 1;
                }
            },

            '/' => {
                // Line comment.
                if (i + 1 < n and src[i + 1] == '/') {
                    const ce = lineTerminatorScan(src, i + 2, n);
                    // JSX: a `//` inside JSX text content (line also contains `</`)
                    // is literal text, not a comment. Skip both slashes.
                    if (is_jsx and !(i > 0 and src[i - 1] == '/')) {
                        var k = i + 2;
                        while (k + 1 < ce) : (k += 1) {
                            if (src[k] == '<' and src[k + 1] == '/') {
                                i += 2;
                                break;
                            }
                        } else {
                            if (opts.comment_sink) |s| s.record(alloc, start, ce, 0);
                            i = ce;
                            saw_nl = true;
                        }
                        continue;
                    }
                    if (opts.comment_sink) |s| s.record(alloc, start, ce, 0);
                    i = ce;
                    saw_nl = true;
                    continue;
                }
                // Block comment.
                if (i + 1 < n and src[i + 1] == '*') {
                    const res = Lex.blockCommentEnd(src, i);
                    if (res.has_nl) { saw_nl = true; at_line_start = true; }
                    if (res.end >= n and !(n >= 2 and src[n - 2] == '*' and src[n - 1] == '/')) {
                        // JSX: an unterminated `/*` in JSX text is a literal `/`.
                        if (is_jsx) {
                            // Cold path: emit via the list (syncs t_len), then refresh
                            // the cached column pointers since append may have grown.
                            toks.len = t_len;
                            try toks.append(alloc, .{ .tag = .slash, .start = i, .len = 1, .has_newline_before = saw_nl });
                            t_len = @intCast(toks.len);
                            t_cap = @intCast(toks.capacity);
                            sl = toks.slice();
                            p_tag = sl.items(.tag).ptr;
                            p_start = sl.items(.start).ptr;
                            p_len = sl.items(.len).ptr;
                            p_nl = sl.items(.has_newline_before).ptr;
                            p_esc = sl.items(.has_unicode_escape).ptr;
                            prev_kind = .slash;
                            saw_nl = false;
                            at_line_start = false;
                            i += 1;
                            continue;
                        }
                        // `blockCommentEnd`'s scalar tail can miss a trailing newline;
                        // rescan so an unterminated comment's newline propagates.
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
                        // Unterminated block comment -> single invalid token, then stop.
                        // Cold path: emit via the list (syncs t_len), then refresh the
                        // cached column pointers since append may have grown.
                        toks.len = t_len;
                        try toks.append(alloc, .{ .tag = .invalid, .start = i, .len = res.end - i, .has_newline_before = saw_nl });
                        t_len = @intCast(toks.len);
                        t_cap = @intCast(toks.capacity);
                        sl = toks.slice();
                        p_tag = sl.items(.tag).ptr;
                        p_start = sl.items(.start).ptr;
                        p_len = sl.items(.len).ptr;
                        p_nl = sl.items(.has_newline_before).ptr;
                        p_esc = sl.items(.has_unicode_escape).ptr;
                        i = res.end;
                        continue;
                    }
                    if (opts.comment_sink) |s| s.record(alloc, start, res.end, 1);
                    i = res.end;
                    continue;
                }
                // Not a comment: regex literal (if allowed) or slash operator.
                if (Lex.regexAllowed(prev) and !(is_jsx and (prev == .less_than or prev == .greater_than))) {
                    tag = .regex_literal;
                    i = Lex.regexEnd(src, start);
                } else {
                    const r = scanOp(src, i, n);
                    tag = r.tag;
                    i = r.end;
                }
            },

            '<' => {
                // Annex B HTML open comment `<!--` (non-module scripts).
                if (annex_b and !is_module and i + 3 < n and src[i + 1] == '!' and src[i + 2] == '-' and src[i + 3] == '-') {
                    const ce = lineTerminatorScan(src, i + 4, n);
                    if (opts.comment_sink) |s| s.record(alloc, start, ce, 0);
                    i = ce;
                    saw_nl = true;
                    continue;
                }
                const r = scanOp(src, i, n);
                tag = r.tag;
                i = r.end;
            },

            '-' => {
                // Annex B HTML close comment `-->` (only at logical line start).
                if (annex_b and !is_module and at_line_start and i + 2 < n and src[i + 1] == '-' and src[i + 2] == '>') {
                    const ce = lineTerminatorScan(src, i + 3, n);
                    if (opts.comment_sink) |s| s.record(alloc, start, ce, 0);
                    i = ce;
                    saw_nl = true;
                    continue;
                }
                // A line-start `-->` outside Annex B is a single invalid token.
                if (at_line_start and (is_module or !annex_b) and i + 2 < n and src[i + 1] == '-' and src[i + 2] == '>') {
                    tag = .invalid;
                    i += 3;
                } else {
                    const r = scanOp(src, i, n);
                    tag = r.tag;
                    i = r.end;
                }
            },

            '.' => {
                if (i + 1 < n and src[i + 1] >= '0' and src[i + 1] <= '9') {
                    i = Lex.numberEnd(src, start);
                    tag = if (!lexer.validateNumericLiteral(src, start, i) or (i < n and lexer.isIdentStartAtPos(src, i)))
                        .invalid
                    else
                        .number_literal;
                } else {
                    const r = scanOp(src, i, n);
                    tag = r.tag;
                    i = r.end;
                }
            },

            '\\' => {
                const r = scanEscapedIdentStart(src, start, n);
                tag = r.tag;
                has_esc = r.has_escape;
                i = r.end;
            },

            else => {
                if (c >= 0x80) {
                    // LS/PS line terminators.
                    if (c == 0xE2 and i + 2 < n and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) {
                        saw_nl = true;
                        at_line_start = true;
                        i += 3;
                        continue;
                    }
                    // BOM.
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
                    const cp = decodeKnownLen(src, i, cl);
                    if (lexer.isUnicodeWhitespace(@intCast(cp))) {
                        i += cl;
                        continue;
                    }
                    // High-byte identifier start, or invalid codepoint.
                    if (!uid.isIdStart(@intCast(cp))) {
                        tag = .invalid;
                        i = start + cl;
                    } else {
                        tag = .identifier;
                        i = scanHighIdentRun(src, start, n);
                    }
                } else {
                    // Any other ASCII byte (operators, punctuation, control) — the
                    // operator scanner returns the right multi/single-char tag, or
                    // `.invalid` for stray control bytes.
                    const r = scanOp(src, i, n);
                    tag = r.tag;
                    i = r.end;
                }
            },
        }
        if (t_len >= t_cap) {
            toks.len = t_len;
            try toks.ensureTotalCapacity(alloc, t_cap * 2 + 16);
            t_cap = @intCast(toks.capacity);
            sl = toks.slice();
            p_tag = sl.items(.tag).ptr;
            p_start = sl.items(.start).ptr;
            p_len = sl.items(.len).ptr;
            p_nl = sl.items(.has_newline_before).ptr;
            p_esc = sl.items(.has_unicode_escape).ptr;
        }
        p_tag[t_len] = tag;
        p_start[t_len] = start;
        p_len[t_len] = i - start;
        p_nl[t_len] = saw_nl;
        p_esc[t_len] = has_esc;
        t_len += 1;

        // Maintain JSX structure state. `<` opens an opening tag (in a body, or
        // where a JSX expression may start) or a closing tag (`</`); `{`/`}` nest
        // inside a tag header (attribute expression) or, in a body, open/close an
        // expression container; `>` closes a header — entering the element body
        // (opening tag) or leaving it (closing tag). See the var block above.
        if (is_jsx) {
            if (jsx_text_mode) {
                // Full JSX structure tracking (element bodies + expression containers)
                // so body text becomes jsx_text tokens (#61). Compiled only into the
                // plain-JSX instantiation.
                switch (tag) {
                    .less_than => {
                        // In a body a `<` is always a tag (text can't contain a bare
                        // `<`); elsewhere fall back to the expression-position heuristic.
                        if (jx.in_text or Lex.regexAllowed(prev)) {
                            const nb: u8 = if (i < n) src[i] else 0;
                            if (nb == '/') {
                                // Closing tag `</…>` — only meaningful inside a body.
                                if (jx.sp > 0 and (jx.frame_ptr[jx.sp - 1] & JSX_EXPR_BIT) == 0) {
                                    jx.closing = true;
                                    jsx_tag_depth += 1; // header until the matching `>`
                                }
                            } else {
                                const opens = nb == '>' or nb == '_' or nb == '$' or
                                    (nb >= 'a' and nb <= 'z') or (nb >= 'A' and nb <= 'Z') or nb >= 0x80;
                                if (opens) jsx_tag_depth += 1;
                            }
                        }
                    },
                    .l_brace => {
                        if (jsx_tag_depth > 0) {
                            jsx_brace_nest += 1; // brace inside a tag header
                        } else if (jx.sp > 0) {
                            const top = jx.frame_ptr[jx.sp - 1];
                            if (top & JSX_EXPR_BIT == 0) {
                                // `{` in a body opens an expression container.
                                if (jx.sp == jx.frame_cap) {
                                    const new_cap = jx.frame_cap * 2;
                                    const grown = try alloc.alloc(u32, new_cap);
                                    @memcpy(grown[0..jx.frame_cap], jx.frame_ptr[0..jx.frame_cap]);
                                    if (jx.frame_heap) |h| alloc.free(h);
                                    jx.frame_heap = grown;
                                    jx.frame_ptr = grown.ptr;
                                    jx.frame_cap = new_cap;
                                }
                                jx.frame_ptr[jx.sp] = JSX_EXPR_BIT;
                                jx.sp += 1;
                            } else {
                                jx.frame_ptr[jx.sp - 1] = top + 1; // nested object/block brace
                            }
                        }
                    },
                    .r_brace => {
                        if (jsx_brace_nest > 0) {
                            jsx_brace_nest -= 1;
                        } else if (jx.sp > 0) {
                            const top = jx.frame_ptr[jx.sp - 1];
                            if (top & JSX_EXPR_BIT != 0) {
                                if (top & ~JSX_EXPR_BIT > 0) {
                                    jx.frame_ptr[jx.sp - 1] = top - 1; // close a nested brace
                                } else {
                                    jx.sp -= 1; // close the expression container
                                }
                            }
                        }
                    },
                    .greater_than => {
                        if (jx.closing) {
                            // `>` of a closing tag `</…>` — leave the element body.
                            jx.closing = false;
                            jsx_tag_depth -= 1;
                            if (jx.sp > 0 and (jx.frame_ptr[jx.sp - 1] & JSX_EXPR_BIT) == 0) jx.sp -= 1;
                        } else if (jsx_tag_depth > 0 and jsx_brace_nest == 0) {
                            jsx_tag_depth -= 1;
                            // Opening-tag header closed: enter the body unless self-closing `/>`.
                            if (prev != .slash) {
                                if (jx.sp == jx.frame_cap) {
                                    const new_cap = jx.frame_cap * 2;
                                    const grown = try alloc.alloc(u32, new_cap);
                                    @memcpy(grown[0..jx.frame_cap], jx.frame_ptr[0..jx.frame_cap]);
                                    if (jx.frame_heap) |h| alloc.free(h);
                                    jx.frame_heap = grown;
                                    jx.frame_ptr = grown.ptr;
                                    jx.frame_cap = new_cap;
                                }
                                jx.frame_ptr[jx.sp] = 0; // BODY frame
                                jx.sp += 1;
                            }
                        }
                    },
                    else => {},
                }
                // Recompute the hot-loop text-context bit: top frame is a body and we
                // are outside any tag header / attribute brace.
                jx.in_text = jx.sp > 0 and (jx.frame_ptr[jx.sp - 1] & JSX_EXPR_BIT) == 0 and
                    jsx_tag_depth == 0 and jsx_brace_nest == 0;
            } else {
                // TSX / non-text JSX: only the opening-tag-header depth and attribute
                // brace nesting needed to classify attribute strings (identical to the
                // pre-#61 lexer). No element-body / text tracking.
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
        }

        prev_kind = if (isPropertyAccess(prev) and tag.isKeyword()) .identifier else tag;
        // A jsx_text token may span line terminators; carry that to the next token's
        // has_newline_before. Comptime-gated so non-JSX keeps the plain `saw_nl = false`.
        if (jsx_text_mode) {
            saw_nl = jx.text_nl;
            jx.text_nl = false;
        } else {
            saw_nl = false;
        }
        at_line_start = false;
    }

    toks.len = t_len;
    try toks.append(alloc, .{ .tag = .eof, .start = n, .len = 0, .has_newline_before = saw_nl });
    return toks;
}
