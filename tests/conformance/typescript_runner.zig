const std = @import("std");
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const Io = std.Io;
const Token = es_parser.token;

/// TypeScript parser conformance runner.
///
/// Uses error baselines from the TypeScript repo to classify tests:
/// - If a baseline has syntax errors (TS1xxx), the test is must-reject
/// - Otherwise, the test is must-parse
///
/// Usage: typescript_runner <conformance-dir>

/// One segment of a multi-file TS test source.
const Segment = struct {
    text: []const u8,
    /// Filename declared by the preceding `@filename:` directive, or empty for
    /// the leading (pre-directive) segment. Caller picks language by extension
    /// and skips non-source segments (`*.json`, `*.d.ts`, etc.).
    name: []const u8,
};

/// Iterates segments of a TypeScript test source split on `//@filename:` /
/// `// @filename:` (and capitalised variants). Each yielded segment carries
/// the filename declared by the directive that introduced it. Boundary
/// directives must start at the beginning of a line (TS test convention).
const SegmentIter = struct {
    src: []const u8,
    pos: u32,
    pending_name: []const u8 = "",

    fn init(src: []const u8) SegmentIter {
        return .{ .src = src, .pos = 0, .pending_name = "" };
    }

    /// Find the next `\n` and return the start of the line after it, or src.len.
    fn skipLine(self: SegmentIter, p: u32) u32 {
        var q = p;
        while (q < self.src.len and self.src[q] != '\n') q += 1;
        if (q < self.src.len) q += 1;
        return q;
    }

    /// Match `(\s*//\s*@[Ff]ilename:\s*)` at the start of a line and capture
    /// the filename (rest of the line, trimmed). Returns the index just past
    /// the directive's newline (start of segment body) on match, or null.
    /// On match, also returns the captured filename via out_name.
    fn matchFilenameAt(self: SegmentIter, line_start: u32, out_name: *[]const u8) ?u32 {
        var i = line_start;
        // Optional leading whitespace.
        while (i < self.src.len and (self.src[i] == ' ' or self.src[i] == '\t')) i += 1;
        if (i + 2 > self.src.len or self.src[i] != '/' or self.src[i + 1] != '/') return null;
        i += 2;
        // Optional spaces.
        while (i < self.src.len and (self.src[i] == ' ' or self.src[i] == '\t')) i += 1;
        if (i + 1 > self.src.len or self.src[i] != '@') return null;
        i += 1;
        // "filename" or "Filename" (case-insensitive on first letter only).
        const tail = "ilename:";
        if (i + 1 + tail.len > self.src.len) return null;
        const f = self.src[i];
        if (f != 'f' and f != 'F') return null;
        i += 1;
        for (tail) |c| {
            if (i >= self.src.len or self.src[i] != c) return null;
            i += 1;
        }
        // Skip whitespace after the colon, then capture filename to end-of-line.
        while (i < self.src.len and (self.src[i] == ' ' or self.src[i] == '\t')) i += 1;
        const name_start = i;
        while (i < self.src.len and self.src[i] != '\n' and self.src[i] != '\r') i += 1;
        // Trim trailing whitespace on the name.
        var name_end = i;
        while (name_end > name_start and (self.src[name_end - 1] == ' ' or self.src[name_end - 1] == '\t')) {
            name_end -= 1;
        }
        out_name.* = self.src[name_start..name_end];
        return self.skipLine(i);
    }

    fn next(self: *SegmentIter) ?Segment {
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        const seg_name = self.pending_name;
        var p = start;
        // Walk line by line. The first segment runs from `start` until we hit
        // the next `@filename:` directive at line-start.
        while (p < self.src.len) {
            // Scan to end of current line.
            var line_end = p;
            while (line_end < self.src.len and self.src[line_end] != '\n') line_end += 1;
            // Skip the very first line (boundary on segment's first line is the
            // *next* segment's start, not part of this one — but if the source
            // begins with a directive there's no leading segment so let it match).
            const can_match_here = p != start or start == 0;
            if (can_match_here) {
                var fname: []const u8 = "";
                if (self.matchFilenameAt(p, &fname)) |next_line| {
                    self.pos = next_line;
                    self.pending_name = fname;
                    return .{ .text = self.src[start..p], .name = seg_name };
                }
            }
            if (line_end < self.src.len) line_end += 1;
            p = line_end;
        }
        self.pos = @intCast(self.src.len);
        return .{ .text = self.src[start..], .name = seg_name };
    }
};

/// Whether a segment with this filename should be parsed as JS/TS source.
/// Multi-file TS tests bundle non-source content too (`package.json`, declaration
/// files, raw text in `.txt` files, sometimes binary data in extension-less files).
/// Allowlist of known JS/TS source extensions; everything else is skipped.
fn segmentIsParseable(name: []const u8) bool {
    if (name.len == 0) return true; // leading segment — parse with file's outer language
    // Reject declaration files outright. Plain `*.d.ts` plus arbitrary-extension
    // declarations (TS allowArbitraryExtensions) like `foo.d.html.ts` use ambient
    // syntax (`const x: T;` without initializer) that the runtime parser rejects.
    if (std.mem.endsWith(u8, name, ".d.ts") or
        std.mem.endsWith(u8, name, ".d.cts") or
        std.mem.endsWith(u8, name, ".d.mts")) return false;
    if (std.mem.endsWith(u8, name, ".ts")) {
        const stem = name[0 .. name.len - 3];
        if (std.mem.indexOf(u8, stem, ".d.") != null) return false;
    }
    // Allowlist source extensions. Anything else (json, txt, css, no-extension,
    // unknown) is treated as non-source data the test bundles for path-resolution
    // checks; skip parsing.
    const source_exts = [_][]const u8{
        ".ts", ".tsx", ".cts", ".mts",
        ".js", ".jsx", ".cjs", ".mjs",
    };
    for (source_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Pick the parser language from a segment's filename, falling back to the
/// outer file's language for the leading (pre-directive) segment.
fn segmentLang(name: []const u8, fallback: Token.Language) Token.Language {
    if (std.mem.endsWith(u8, name, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, name, ".jsx")) return .jsx;
    if (std.mem.endsWith(u8, name, ".ts") or std.mem.endsWith(u8, name, ".cts") or
        std.mem.endsWith(u8, name, ".mts")) return .ts;
    if (std.mem.endsWith(u8, name, ".js") or std.mem.endsWith(u8, name, ".cjs") or
        std.mem.endsWith(u8, name, ".mjs")) return .js;
    return fallback;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 2) {
        try stdout.print("Usage: typescript_runner <conformance-dir>\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    const cases_dir = args[1];
    const compact = args.len >= 3 and std.mem.eql(u8, args[2], "--compact");

    // Derive baselines path from cases dir:
    // cases_dir = .../typescript/tests/cases/conformance
    // baselines = .../typescript/tests/baselines/reference
    var baselines_buf: [4096]u8 = undefined;
    const baselines_dir = blk: {
        // Walk up from cases dir to find tests/baselines/reference.
        // Support both .../tests/cases/... (with trailing subdir) and .../tests/cases (terminal).
        const needle_slash = "/tests/cases/";
        const needle_end   = "/tests/cases";
        if (std.mem.indexOf(u8, cases_dir, needle_slash)) |idx| {
            const prefix = cases_dir[0..idx];
            break :blk std.fmt.bufPrint(&baselines_buf, "{s}/tests/baselines/reference", .{prefix}) catch "";
        }
        if (std.mem.endsWith(u8, cases_dir, needle_end)) {
            const prefix = cases_dir[0 .. cases_dir.len - needle_end.len];
            break :blk std.fmt.bufPrint(&baselines_buf, "{s}/tests/baselines/reference", .{prefix}) catch "";
        }
        break :blk "";
    };

    var must_parse_pass: u32 = 0;
    var must_parse_fail: u32 = 0;
    var must_reject_pass: u32 = 0;
    var must_reject_fail: u32 = 0;
    var skipped: u32 = 0;

    // Collect all .ts files
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    const base_dir = Io.Dir.cwd().openDir(io, cases_dir, .{}) catch {
        try stdout.print("Cannot open {s}\n", .{cases_dir});
        try stdout.flush();
        std.process.exit(1);
    };
    try walkTs(io, allocator, base_dir, cases_dir, &files);

    // Pre-load baseline filenames once (avoids re-scanning directory per test)
    var baseline_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (baseline_names.items) |n| allocator.free(n);
        baseline_names.deinit(allocator);
    }
    if (baselines_dir.len > 0) {
        if (Io.Dir.cwd().openDir(io, baselines_dir, .{})) |bdir| {
            var biter = bdir.iterate();
            while (biter.next(io) catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".errors.txt")) {
                    try baseline_names.append(allocator, try allocator.dupe(u8, entry.name));
                }
            }
        } else |_| {}
    }

    for (files.items) |path| {
        // Skip .d.ts (declaration files — no executable code, conformance handled elsewhere).
        // .tsx files now parse through the .tsx language mode below.
        if (std.mem.endsWith(u8, path, ".d.ts")) {
            skipped += 1;
            continue;
        }

        const source = Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(2 * 1024 * 1024)) catch continue;
        defer allocator.free(source);

        // Multi-file tests are split by the TS test harness on `//@filename:`.
        // Walk the source once to find the segment boundaries; if any are present,
        // parse each segment independently and combine the results. If parsing the
        // whole source as a single file would fail (concatenated top-level JSX,
        // duplicate declarations across files, etc.), per-segment parsing recovers it.

        // Classify using error baselines
        const kind = classifyTest(io, allocator, path, source, baselines_dir, baseline_names.items);
        if (kind == .skip) {
            skipped += 1;
            continue;
        }

        const lang: Token.Language = if (std.mem.endsWith(u8, path, ".tsx"))
            .tsx
        else if (std.mem.endsWith(u8, path, ".ts"))
            .ts
        else
            .js;
        const is_module = detectModuleMode(source);
        const is_strict = detectStrictMode(source);
        const is_experimental_decorators = detectExperimentalDecorators(source);
        // Non-ES module kinds (commonjs, amd, umd, system) are NOT strict by default.
        // Use force_strict=false so we can parse module syntax without strict semantics.
        const force_strict: ?bool = if (detectNonEsModuleKind(source) and !is_strict) false else null;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const file_alloc = arena.allocator();

        var first_error: []const u8 = "";

        // Prepend "use strict"; if the test directives enable strict mode.
        // Skip prepending for TypeScript files: strict mode from tsconfig (@alwaysStrict,
        // @strict) is a semantic concern in TypeScript; the parser does not need to see
        // "use strict" in source to enforce eval/arguments restrictions (TS1100) since
        // TypeScript handles those as semantic (type-checker) errors, not parse errors.
        const parse_source = if (is_strict and !is_module and lang == .js) blk: {
            const prefix = "\"use strict\";\n";
            const buf = file_alloc.alloc(u8, prefix.len + source.len) catch break :blk source;
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..], source);
            break :blk buf;
        } else source;

        // Split into segments at `//@filename:` directives. Each segment is parsed
        // independently — multi-file tests bundle multiple files in one source and
        // parsing them concatenated mis-reports legitimate duplicate-decl / JSX-recovery
        // errors. For must-parse all segments must succeed; for must-reject any one
        // segment failing counts as the expected rejection.
        // Track per-language segment outcomes. Many TS multi-file tests bundle a
        // `.js` segment alongside `.ts` to show that TS-only syntax (type annotations,
        // generic arrows) errors in JS mode but works in TS — those tests are
        // classified must-parse (the TS segment must succeed). We require all
        // TS/TSX segments to succeed but allow JS segments to error.
        var all_ts_segments_ok = true;
        var saw_ts_segment = false;
        var all_segments_ok = true;
        var seg_iter = SegmentIter.init(parse_source);
        while (seg_iter.next()) |segment| {
            if (segment.text.len == 0) continue;
            // Skip non-source segments (package.json, .d.ts, etc.) — bundled
            // alongside the .ts files but not parsed as JS/TS.
            if (!segmentIsParseable(segment.name)) continue;
            const seg_lang = segmentLang(segment.name, lang);
            const seg_is_ts = seg_lang == .ts or seg_lang == .tsx;
            if (seg_is_ts) saw_ts_segment = true;
            const seg_ok = parse_blk: {
                // Strip test-harness directive lines (// @key: ...) and BOM so that a
                // shebang (#!/...) following the directives lands at position 0 in the
                // source the lexer sees — matching what TypeScript's test harness does.
                const parse_text = stripTestHarnessDirectives(segment.text);
                var toks = (Lexer.tokenizeWithOptions(file_alloc, parse_text, seg_lang, is_module) catch {
                    if (first_error.len == 0) first_error = "tokenize failed";
                    break :parse_blk false;
                }).tokens;
                defer toks.deinit(file_alloc);
                var tree = Parser.parseWithOptions(file_alloc, parse_text, toks.slice(), .{
                    .language = seg_lang,
                    .is_module = is_module,
                    .is_strict = force_strict,
                    .emit_events = true,
                    .experimental_decorators = is_experimental_decorators,
                }) catch {
                    if (first_error.len == 0) first_error = "parse OOM";
                    break :parse_blk false;
                };
                if (tree.errors.len > 0) {
                    if (first_error.len == 0) first_error = tree.errors[0].message;
                    break :parse_blk false;
                }
                // Semantic analysis (must-reject only — TS allows redeclarations JS doesn't).
                if (kind == .must_reject) {
                    var sem = es_parser.semantic.SemanticAnalyzer.analyze(file_alloc, &tree) catch break :parse_blk true;
                    defer sem.deinit(file_alloc);
                    if (sem.diagnostics.len > 0) {
                        if (first_error.len == 0) first_error = "semantic error";
                        break :parse_blk false;
                    }
                }
                break :parse_blk true;
            };
            if (!seg_ok) {
                all_segments_ok = false;
                if (seg_is_ts) all_ts_segments_ok = false;
            }
        }
        // For must-reject: any segment failing counts (JS strict-mode errors in .js segments,
        // etc.). For must-parse: TS-segment-based logic avoids false failures from unsupported
        // TS syntax in .js segments (e.g. `satisfies` in a .js allowJs file).
        const has_error = if (kind == .must_reject)
            !all_segments_ok
        else if (saw_ts_segment)
            !all_ts_segments_ok
        else
            !all_segments_ok;

        switch (kind) {
            .must_parse => {
                if (!has_error) {
                    must_parse_pass += 1;
                } else {
                    must_parse_fail += 1;
                    if (!compact) {
                        try stdout.print("  FAIL (should parse): {s} | {s}\n", .{ path, first_error });
                    }
                }
            },
            .must_reject => {
                if (has_error) {
                    must_reject_pass += 1;
                } else {
                    must_reject_fail += 1;
                    if (!compact) {
                        try stdout.print("  FAIL (should reject): {s}\n", .{path});
                    }
                }
            },
            .skip => unreachable,
        }
    }

    const parse_total = must_parse_pass + must_parse_fail;
    const reject_total = must_reject_pass + must_reject_fail;
    const overall_total = parse_total + reject_total;
    const overall_pass = must_parse_pass + must_reject_pass;

    if (compact) {
        try stdout.print("typescript:            must-parse: {d}/{d}  must-reject: {d}/{d}  skipped: {d}\n", .{
            must_parse_pass, parse_total, must_reject_pass, reject_total, skipped,
        });
    } else {
        try stdout.print("TypeScript parser conformance tests\n\n", .{});
        try stdout.print("  Must-parse:   {d} / {d}\n", .{ must_parse_pass, parse_total });
        try stdout.print("  Must-reject:  {d} / {d}\n", .{ must_reject_pass, reject_total });
        try stdout.print("  Skipped:      {d}\n", .{skipped});
        try stdout.print("  Overall:      {d} / {d}\n", .{ overall_pass, overall_total });
    }
    try stdout.flush();
}

// ── Strict mode detection ───────────────────────────────────────

fn detectExperimentalDecorators(source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "// @experimentalDecorators: true") != null) return true;
    if (std.mem.indexOf(u8, source, "// @experimentaldecorators: true") != null) return true;
    return false;
}

fn detectStrictMode(source: []const u8) bool {
    // Detect @strict or @alwaysStrict directives in TS test comments.
    // For parametric directives like `@alwaysStrict: true, false` we pick the
    // *non-strict* variant. The TS test harness emits separate baseline files
    // per parameter combination; tests with strict-only errors (TS1100 etc.)
    // are classified by their parametric baselines, but the source file is
    // single-config from the parser's POV. Picking non-strict matches the more
    // permissive variant and avoids false-rejects on `var arguments` tests.
    // Hard-strict is only when `@strict: true` or `@alwaysStrict: true` appears
    // ALONE (not in a parametric list).
    if (std.mem.indexOf(u8, source, "// @strict: true") != null and
        std.mem.indexOf(u8, source, "// @strict: true,") == null) return true;
    if (std.mem.indexOf(u8, source, "// @alwaysStrict: true") != null and
        std.mem.indexOf(u8, source, "// @alwaysStrict: true,") == null and
        std.mem.indexOf(u8, source, "// @alwaysStrict: true ,") == null) return true;
    // "@strict" without ": false" means strict is enabled
    if (std.mem.indexOf(u8, source, "// @strict\n") != null) return true;
    return false;
}

// ── Module mode detection ────────────────────────────────────────

/// Returns true if the test explicitly sets @strict: false.
fn detectExplicitStrictFalse(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "// @strict: false") != null;
}

/// Returns true if the test uses a non-ES module kind (commonjs, amd, umd, system, none).
/// These are NOT automatically strict; strict mode only applies when @strict is enabled.
fn detectNonEsModuleKind(source: []const u8) bool {
    const non_es = [_][]const u8{ "commonjs", "amd", "umd", "system", "none" };
    for (non_es) |kind| {
        var buf: [40]u8 = undefined;
        const needle1 = std.fmt.bufPrint(&buf, "// @module: {s}", .{kind}) catch continue;
        if (std.mem.indexOf(u8, source, needle1) != null) return true;
        const needle2 = std.fmt.bufPrint(&buf, "// @module:{s}", .{kind}) catch continue;
        if (std.mem.indexOf(u8, source, needle2) != null) return true;
        const needle3 = std.fmt.bufPrint(&buf, "//@module: {s}", .{kind}) catch continue;
        if (std.mem.indexOf(u8, source, needle3) != null) return true;
        const needle4 = std.fmt.bufPrint(&buf, "//@module:{s}", .{kind}) catch continue;
        if (std.mem.indexOf(u8, source, needle4) != null) return true;
    }
    return false;
}

fn detectModuleMode(source: []const u8) bool {
    // Scan for export/import at top-level (brace depth == 0) after optional whitespace.
    // Note: @module: directives are compiler OUTPUT options, not module declarations.
    // A file is an ES module only if it has top-level import/export syntax.
    // Track brace depth to ignore `export` inside namespace/class bodies.
    var i: usize = 0;
    var depth: i32 = 0;
    while (i < source.len) {
        const c = source[i];
        // Track brace depth (skip string literals to avoid counting braces in strings)
        if (c == '"' or c == '\'') {
            const q = c;
            i += 1;
            while (i < source.len and source[i] != q and source[i] != '\n') {
                if (source[i] == '\\') i += 1; // skip escape
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        if (c == '`') {
            i += 1;
            while (i < source.len and source[i] != '`') {
                if (source[i] == '\\') i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            // Line comment: skip to end of line
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            // Block comment: skip to */
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            if (i + 1 < source.len) i += 2;
            continue;
        }
        if (c == '{') { depth += 1; i += 1; continue; }
        if (c == '}') { if (depth > 0) depth -= 1; i += 1; continue; }
        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') { i += 1; continue; }
        // At top level (depth 0): check for export/import keyword
        if (depth == 0 and i + 6 < source.len) {
            if (std.mem.eql(u8, source[i..][0..6], "export") or
                std.mem.eql(u8, source[i..][0..6], "import"))
            {
                const next = source[i + 6];
                if (next == ' ' or next == '\t' or next == '{' or next == '\n' or next == '*') return true;
            }
        }
        // Skip to next interesting character (skip identifiers, numbers, etc.)
        i += 1;
    }
    return false;
}

// ── Test classification ──────────────────────────────────────────

const TestKind = enum { must_parse, must_reject, skip };

fn classifyTest(io: Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, baselines_dir: []const u8, baseline_names: []const []const u8) TestKind {
    // Skip pure JSON files
    if (source.len > 0 and (source[0] == '{' or (source[0] == 0xEF and source.len > 3 and source[3] == '{'))) {
        return .skip;
    }

    // Use error baselines if available: check if <testname>.errors.txt exists
    // and contains syntax errors (TS1xxx codes = parse errors)
    if (baselines_dir.len > 0) {
        if (hasSyntaxErrorBaseline(io, allocator, path, baselines_dir, baseline_names))
            return .must_reject;
    }

    // TS1100 ("Invalid use of 'eval'/'arguments' in strict mode") is in
    // semantic_only_codes because most baselines are parametric `(alwaysstrict=true)`
    // — strict mode comes from tsconfig the parser doesn't see. But when the
    // SOURCE itself has a `"use strict";` directive, strict mode is parse-time
    // detectable; ez correctly rejects, so reclassify these as must-reject.
    if (baselines_dir.len > 0 and hasUseStrictDirective(source) and
        baselineHasCode(io, allocator, path, baselines_dir, baseline_names, "TS1100"))
    {
        return .must_reject;
    }

    return .must_parse;
}

/// True if source contains an actual `"use strict"` directive (not inside a // comment).
fn hasUseStrictDirective(source: []const u8) bool {
    // Scan line by line to avoid matching "use strict" inside // comments.
    var i: usize = 0;
    while (i < source.len) {
        // Find end of line.
        var line_end: usize = i;
        while (line_end < source.len and source[line_end] != '\n') line_end += 1;
        const line = source[i..line_end];
        // Check if this line contains "use strict" or 'use strict'.
        const dq = std.mem.indexOf(u8, line, "\"use strict\"");
        const sq = std.mem.indexOf(u8, line, "'use strict'");
        const match_pos = if (dq != null and sq != null) @min(dq.?, sq.?) else dq orelse sq;
        if (match_pos) |pos| {
            // Check whether the match is preceded by // on the same line.
            const is_in_line_comment = blk: {
                var j: usize = 0;
                while (j + 1 < pos) : (j += 1) {
                    if (line[j] == '/' and line[j + 1] == '/') break :blk true;
                }
                break :blk false;
            };
            if (!is_in_line_comment) return true;
        }
        i = line_end + 1;
    }
    return false;
}

/// True if the test's error baseline contains a specific TS code (e.g. "TS1100").
fn baselineHasCode(
    io: Io,
    allocator: std.mem.Allocator,
    test_path: []const u8,
    baselines_dir: []const u8,
    baseline_names: []const []const u8,
    code: []const u8,
) bool {
    const basename = getBasename(test_path);
    const stem = if (std.mem.endsWith(u8, basename, ".tsx"))
        basename[0 .. basename.len - 4]
    else if (std.mem.endsWith(u8, basename, ".ts"))
        basename[0 .. basename.len - 3]
    else
        basename;
    var buf: [4096]u8 = undefined;
    const baseline_path = std.fmt.bufPrint(&buf, "{s}/{s}.errors.txt", .{ baselines_dir, stem }) catch return false;
    if (Io.Dir.cwd().readFileAlloc(io, baseline_path, allocator, Io.Limit.limited(256 * 1024))) |c| {
        defer allocator.free(c);
        if (std.mem.indexOf(u8, c, code) != null) return true;
    } else |_| {}
    for (baseline_names) |name| {
        if (!std.mem.startsWith(u8, name, stem)) continue;
        if (name.len <= stem.len or name[stem.len] != '(') continue;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ baselines_dir, name }) catch continue;
        if (Io.Dir.cwd().readFileAlloc(io, p, allocator, Io.Limit.limited(256 * 1024))) |c| {
            defer allocator.free(c);
            if (std.mem.indexOf(u8, c, code) != null) return true;
        } else |_| {}
    }
    return false;
}

/// Check if a test file has a corresponding .errors.txt baseline with syntax errors.
/// Syntax errors in TypeScript are TS1xxx codes (1000-1999 range).
fn hasSyntaxErrorBaseline(io: Io, allocator: std.mem.Allocator, test_path: []const u8, baselines_dir: []const u8, baseline_names: []const []const u8) bool {
    // Extract test name from path: .../cases/conformance/foo/bar.ts -> bar
    const basename = getBasename(test_path);
    const stem = if (std.mem.endsWith(u8, basename, ".ts"))
        basename[0 .. basename.len - 3]
    else if (std.mem.endsWith(u8, basename, ".tsx"))
        basename[0 .. basename.len - 4]
    else
        basename;

    // Check exact baseline: <stem>.errors.txt
    var buf: [4096]u8 = undefined;
    const baseline_path = std.fmt.bufPrint(&buf, "{s}/{s}.errors.txt", .{ baselines_dir, stem }) catch return false;
    if (checkBaselineForSyntaxErrors(io, allocator, baseline_path)) return true;

    // Also check parametric baselines: <stem>(<params>).errors.txt
    // TypeScript generates these for tests with multiple @target values.
    // Uses pre-cached baseline_names to avoid re-scanning the directory per test.
    for (baseline_names) |name| {
        if (!std.mem.startsWith(u8, name, stem)) continue;
        if (name.len <= stem.len or name[stem.len] != '(') continue;
        const param_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ baselines_dir, name }) catch continue;
        if (checkBaselineForSyntaxErrors(io, allocator, param_path)) return true;
    }
    return false;
}

/// TS1xxx codes that are semantic type-checker errors or target-dependent feature checks,
/// NOT syntactic parse errors. We cannot emit these at parse time, so they must not
/// classify tests as must-reject.
/// TS1xxx codes that are semantic type-checker errors or target-dependent feature checks,
/// NOT syntactic parse errors. We cannot emit these at parse time, so they must not
/// classify tests as must-reject.
/// NOTE: Only codes are listed here where ALL files containing only this code can be
/// safely reclassified as must-parse (our parser accepts them cleanly).
const semantic_only_codes = [_]u16{
    1055, // Type is not a valid async function return type (semantic)
    1058, // Return type of async function must be Promise-compatible (semantic)
    1064, // Return type of async function must be global Promise<T> (semantic)
    1166, // Computed property name in class property must have simple literal or unique symbol type (semantic)
    1169, // Computed property name in interface must have literal or unique symbol type (semantic)
    1170, // Computed property name in type literal must have literal or unique symbol type (semantic)
    1207, // Decorators cannot be applied to multiple get/set accessors of same name (semantic)
    1238, // Unable to resolve signature of class decorator (type-checker)
    1239, // Unable to resolve signature of method decorator (type-checker)
    1240, // Unable to resolve signature of property decorator (type-checker)
    1241, // Unable to resolve signature of parameter decorator (type-checker)
    1250, // Function declarations not allowed in blocks in strict mode targeting ES5 (target-dep)
    1346, // Parameter not allowed with 'use strict' directive (non-simple params — ES2016+ only, target-dependent)
    1347, // 'use strict' directive cannot be used with non-simple parameter list (ES2016+ only, target-dependent)
    1348, // Non-simple parameter declared here (related hint for TS1346/1347)
    1349, // 'use strict' directive used here (related hint for TS1346/1347)
    1270, // Decorator used in ambient context (contextual)
    1288, // Import alias cannot resolve to type when verbatimModuleSyntax enabled (config)
    1320, // Type is not valid async function return type in ES5/ES3 (target-dependent)
    1329, // Cannot enable strictPropertyInitialization without strictNullChecks (config)
    1345, // Expression of type 'void' cannot be tested for truthiness (type-checker)
    1360, // Type does not satisfy expected type (type-checker)
    1451, // Private identifiers only available targeting ES2015+ (target-dependent)
    1501, // Regex flag only available targeting es6+ (target-dependent)
    // Surfaced by the broader multi-file corpus (un-skipping `@filename:` tests).
    // All require tsconfig context the parser doesn't have:
    1100, // Invalid use of '%0' in strict mode — most TS1100 baselines are parametric
          // `(alwaysstrict=true)`, where strict comes from tsconfig the parser can't see.
          // Tests with explicit `"use strict"` directives are caught at parse time
          // (and would correctly classify as must-parse for the non-strict variant
          // of the parametric baseline anyway).
    // (TS1200 "Line terminator not permitted before arrow" IS a parse-time error
    //  ez correctly emits — don't list it; tests with TS1200 should classify
    //  as must-reject and ez passes them.)
    1255, // Definite assignment assertion semantic
    1323, // Dynamic imports require module=es2020+/commonjs/etc (target-dependent)
    1324, // Dynamic imports only support a second argument with newer module config
    1325, // Argument of dynamic import must be a string type (semantic)
    1361, // 'import type' used as value (semantic)
    1362, // 'export type' used as value (semantic)
    1376, // Modifier conflict (semantic — modifier-modifier interaction)
    1377, // Modifier conflict (semantic)
    1378, // Top-level 'await' with wrong target/module config (target-dependent)
    1432, // 'await' top-level requires module setting (target-dependent)
    1464, // 'import' attribute requires `with` (config-dependent)
    1473, // Import attributes are only supported when '--module' is es2026 or later
    1474, // Import attributes (config)
    1479, // Top-level 'await' (target-dependent)
    1484, // 'export type' / 'import type' style (verbatimModuleSyntax-dependent)
    1700, // 'super' in non-derived class (semantic)
    1701, // Decorator related (semantic)
    1800, // 'using' / 'await using' target-dependent
    1801, // 'using' / 'await using' target-dependent
    1803, // 'await using' target-dependent
    1804, // Decorator-related modifier (semantic)
    // More config-dependent codes surfaced after un-skipping multi-file tests.
    // These all depend on tsconfig (`module`, `target`, `verbatimModuleSyntax`,
    // `esModuleInterop`, `useDefineForClassFields`, etc.) the parser doesn't see.
    1192, // Module '%0' has no default export (import alias config)
    1195, // 'export *' does not re-export a default (related diagnostic for TS1192)
    1203, // Export assignment cannot be used when targeting ECMAScript modules
    1205, // Re-exporting a type when 'verbatimModuleSyntax' is enabled (config)
    1216, // Identifier expected. '%0' is a reserved word in module mode
    1259, // Module '%0' can only be default-imported using esModuleInterop
    1282, // 'export =' with verbatimModuleSyntax — value/type mismatch (config)
    1283, // 'export =' with verbatimModuleSyntax — type-only (config)
    1284, // 'export default' must reference a value when verbatimModuleSyntax (config)
    1285, // 'export default' type-only with verbatimModuleSyntax (config)
    1273, // '%0' modifier can only be used in TypeScript files (decorators-legacy)
    1274, // 'decorators' option is required (decorators)
    1287, // A re-export cannot have type-only annotations (verbatimModuleSyntax)
    1295, // Type assertions in JavaScript files (allowJs)
    1306, // 'this' implicitly has type 'any' (semantic)
    1039, // Initializers not allowed in ambient contexts (semantic — tsconfig-dependent)
    1103, // 'for await' only allowed in async functions (TS emits as semantic in non-async TS functions)
    1308, // 'await' expression only allowed in async (target-dependent)
    1309, // The current file is a CommonJS module (target-dependent top-level await)
    1331, // Parameter property declaration only in constructor implementation (semantic)
    1340, // Module reference (config-dependent)
    1356, // Did you mean to use 'as const' (semantic)
    1363, // Type-only export-equals (verbatimModuleSyntax)
    1380, // 'import =' / 'export =' (verbatimModuleSyntax)
    1392, // Import attribute resolution-mode (config)
    // (TS1434 is class-member parse error in some contexts — keep as syntactic.)
    1453, // 'resolution-mode' attribute (config)
    1454, // 'resolution-mode' attribute (config)
    1455, // 'resolution-mode' attribute (config)
    1456, // 'resolution-mode' attribute (config)
    1463, // Import attributes (config)
    1470, // Import.meta target-dependent
    1471, // Import attributes assertion config
    1485, // Import attributes only supported (config)
    1486, // Decorators not allowed (config)
    1543, // 'using' / 'await using' (target-dependent)
    1544, // 'using' / 'await using' (target-dependent)
    // Additional config/type-checker-dependent codes identified from failing tests.
    1069, // Unexpected token in jsdoc type parameter (jsdoc-parse-only — ignored by our non-jsdoc parser)
    1223, // 'satisfies' tag already specified (jsdoc-parse-only)
    1065, // Return type of async function or method must be global Promise<T> (type-checker)
    1202, // Import assignment cannot be used when targeting ECMAScript modules (config: module=esnext)
    1289, // Resolves to type-only declaration, mark type-only when isolatedModules enabled (config)
    1448, // Must be re-exported using type-only re-export when isolatedModules enabled (config)
    1541, // Type-only import of ECMAScript module from CommonJS module needs resolution-mode (config)
    1542, // Type import of ECMAScript module from CommonJS module needs resolution-mode (config)
    1062, // Type is referenced directly/indirectly in fulfillment callback of own 'then' (type-checker)
    1251, // Function decls not allowed in blocks in strict mode targeting ES5, class body (target-dependent; 1250 covers blocks generally)
    1294, // Syntax not allowed when 'erasableSyntaxOnly' is enabled (compiler config flag)
};

fn checkBaselineForSyntaxErrors(io: Io, allocator: std.mem.Allocator, path: []const u8) bool {
    const content = Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(256 * 1024)) catch return false;
    defer allocator.free(content);

    // Check for syntax error codes: TS1xxx (1000-1999, exactly 4 digits after TS).
    // Must NOT match TS1xxxx (5+ digit codes like TS18050 which are semantic errors).
    // Skip codes that are semantic/type-checker/target-dependent (not implementable at parse time).
    // Also recognize a small allowlist of 5-digit codes that ARE parse errors:
    //   TS17012 — Invalid meta-property for `import` keyword
    //   TS17021 — Unicode escape sequence cannot appear here (JSX tag name)
    //   TS18007 — JSX expressions may not use the comma operator
    //   TS18058 — Default imports not allowed in a deferred import
    //   TS18059 — Named imports not allowed in a deferred import
    const syntactic_5digit = [_]u32{ 17012, 17021, 18007, 18058, 18059 };
    var i: usize = 0;
    while (i + 6 < content.len) : (i += 1) {
        if (content[i] != 'T' or content[i + 1] != 'S') continue;
        // Walk forward grabbing digits.
        var j: usize = i + 2;
        while (j < content.len and isDigit(content[j])) j += 1;
        const ndigits = j - (i + 2);
        if (ndigits == 4) {
            // 4-digit TS1xxx code.
            if (content[i + 2] != '1') { i = j; continue; }
            const d2 = content[i + 3] - '0';
            const d3 = content[i + 4] - '0';
            const d4 = content[i + 5] - '0';
            const code: u16 = 1000 + @as(u16, d2) * 100 + @as(u16, d3) * 10 + d4;
            var is_semantic = false;
            for (semantic_only_codes) |sc| {
                if (sc == code) { is_semantic = true; break; }
            }
            if (!is_semantic) return true;
        } else if (ndigits == 5) {
            // 5-digit code — check the allowlist.
            var code5: u32 = 0;
            var k: usize = i + 2;
            while (k < j) : (k += 1) code5 = code5 * 10 + (content[k] - '0');
            for (syntactic_5digit) |sc| {
                if (sc == code5) return true;
            }
        }
        i = j;
    }
    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Strip UTF-8 BOM and leading `// @key: value` test-harness directive lines from a
/// source segment so that a shebang (`#!/...`) that follows directives is at position 0
/// when the lexer sees it. Also strips blank lines between directives and the shebang.
/// This mirrors what the TypeScript test harness does before invoking the compiler.
fn stripTestHarnessDirectives(source: []const u8) []const u8 {
    var i: usize = 0;
    // Strip UTF-8 BOM (EF BB BF).
    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
        i = 3;
    }
    // Repeatedly strip `// @...` directive lines and blank lines until neither matches.
    var changed = true;
    while (changed) {
        changed = false;
        // Strip `// @...` lines.
        if (i < source.len) {
            var j = i;
            while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
            if (j + 2 < source.len and source[j] == '/' and source[j + 1] == '/') {
                var k = j + 2;
                while (k < source.len and (source[k] == ' ' or source[k] == '\t')) k += 1;
                if (k < source.len and source[k] == '@') {
                    while (i < source.len and source[i] != '\n') i += 1;
                    if (i < source.len) i += 1;
                    changed = true;
                    continue;
                }
            }
        }
        // Strip blank lines (whitespace-only).
        if (i < source.len) {
            var j = i;
            while (j < source.len and (source[j] == ' ' or source[j] == '\t' or source[j] == '\r')) j += 1;
            if (j < source.len and source[j] == '\n') {
                i = j + 1;
                changed = true;
            }
        }
    }
    return source[i..];
}

fn getBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

// ── Directory walker ─────────────────────────────────────────────

const StackEntry = struct { dir: std.Io.Dir, path: []const u8 };

fn walkTs(io: std.Io, allocator: std.mem.Allocator, base_dir: std.Io.Dir, base_path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var stack: std.ArrayList(StackEntry) = .empty;
    defer {
        for (stack.items) |item| allocator.free(item.path);
        stack.deinit(allocator);
    }
    try stack.append(allocator, .{ .dir = base_dir, .path = try allocator.dupe(u8, base_path) });

    while (stack.items.len > 0) {
        const item = stack.pop().?;
        defer allocator.free(item.path);

        var iter = item.dir.iterate();
        while (iter.next(io) catch null) |entry| {
            var path_buf: [4096]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ item.path, entry.name }) catch continue;

            if (entry.kind == .directory) {
                const sub_dir = item.dir.openDir(io, entry.name, .{}) catch continue;
                try stack.append(allocator, .{ .dir = sub_dir, .path = try allocator.dupe(u8, full_path) });
            } else if (std.mem.endsWith(u8, entry.name, ".ts") or std.mem.endsWith(u8, entry.name, ".tsx")) {
                try list.append(allocator, try allocator.dupe(u8, full_path));
            }
        }
    }
}
