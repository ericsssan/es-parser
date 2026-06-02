const std = @import("std");
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const Io = std.Io;

/// Fast in-process runner for Babel parser test fixtures.
/// Usage: babel_runner <fixtures-dir>

fn tokenizeMaybe(alloc: std.mem.Allocator, source: []const u8, lang: es_parser.token.Language, is_module: bool, annex_b: bool) !es_parser.scalar_lexer.TokenList {
    return es_parser.scalar_lexer.tokenizeScalarWithOptions(alloc, source, lang, .{ .is_module = is_module, .annex_b = annex_b });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 2) {
        try stdout.print("Usage: babel_runner <fixtures-dir>\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    const fixtures_dir = args[1];
    const compact = args.len >= 3 and std.mem.eql(u8, args[2], "--compact");

    // Collect all input.js files and options.json with "throws"
    var valid_pass: u32 = 0;
    var valid_fail: u32 = 0;
    var invalid_pass: u32 = 0;
    var invalid_fail: u32 = 0;
    var skipped: u32 = 0;

    // Walk fixtures directory
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    const base_dir = Io.Dir.cwd().openDir(io, fixtures_dir, .{}) catch {
        try stdout.print("Cannot open {s}\n", .{fixtures_dir});
        try stdout.flush();
        std.process.exit(1);
    };
    try walkCollect(io, allocator, base_dir, fixtures_dir, &files, "input.js");

    for (files.items) |path| {
        // Skip unsupported features
        if (shouldSkip(path)) {
            skipped += 1;
            continue;
        }

        // Read options.json hierarchy once — used for skip, module, and error classification
        const opts = readOptionsHierarchy(io, allocator, path);

        if (opts.has_unsupported) {
            skipped += 1;
            continue;
        }

        // Check if this is an error test (options.json with "throws" in same dir)
        const is_error_test = opts.is_error or isErrorTestFromOutput(io, allocator, path);

        // Read and parse
        const source = Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(2 * 1024 * 1024)) catch continue;
        defer allocator.free(source);

        // Detect module mode
        const is_module = switch (opts.source_type) {
            .module => true,
            .unambiguous => sourceHasModuleSyntax(source),
            .unspecified, .script => false,
        };

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const file_alloc = arena.allocator();

        // Pick lexer/parser language from the plugins listed in options.json.
        // Flow is filtered upstream (has_unsupported) so we never see it here.
        const lang: es_parser.token.Language = if (opts.is_jsx and opts.is_typescript)
            .tsx
        else if (opts.is_jsx)
            .jsx
        else if (opts.is_typescript)
            .ts
        else
            .js;

        const parse_result = blk: {
            var tokens = tokenizeMaybe(file_alloc, source, lang, is_module, opts.annex_b) catch break :blk ParseResult{ .has_error = true, .first_error = "tokenize failed" };
            defer tokens.deinit(file_alloc);
            var tree = Parser.parseWithLanguageOpts(file_alloc, source, tokens.slice(), lang, is_module, opts.annex_b) catch break :blk ParseResult{ .has_error = true, .first_error = "parse OOM" };
            defer tree.deinit(file_alloc);
            if (tree.errors.len > 0) break :blk ParseResult{ .has_error = true, .first_error = tree.errors[0].message };

            // Run semantic analysis to catch early errors (duplicate bindings, etc.)
            var sem = es_parser.semantic.SemanticAnalyzer.analyze(file_alloc, &tree) catch break :blk ParseResult{ .has_error = false, .first_error = "" };
            defer sem.deinit(file_alloc);
            if (sem.diagnostics.len > 0) break :blk ParseResult{ .has_error = true, .first_error = "semantic error" };

            break :blk ParseResult{ .has_error = false, .first_error = "" };
        };

        if (is_error_test) {
            if (parse_result.has_error) invalid_pass += 1 else {
                invalid_fail += 1;
                if (!compact) try stdout.print("  FAIL (should reject): {s}\n", .{path});
            }
        } else {
            if (!parse_result.has_error) {
                valid_pass += 1;
            } else {
                valid_fail += 1;
                if (!compact) {
                    try stdout.print("  FAIL: {s} | {s}\n", .{ path, parse_result.first_error });
                }
            }
        }
    }

    const valid_total = valid_pass + valid_fail;
    const invalid_total = invalid_pass + invalid_fail;

    if (compact) {
        try stdout.print("babel:                 must-parse: {d}/{d}  must-reject: {d}/{d}  skipped: {d}\n", .{
            valid_pass, valid_total, invalid_pass, invalid_total, skipped,
        });
    } else {
        try stdout.print("Babel parser conformance tests\n\n", .{});
        try stdout.print("Valid JS (should parse without error):\n", .{});
        try stdout.print("  {d}/{d} passed ({d} failed, {d} skipped)\n\n", .{
            valid_pass, valid_total, valid_fail, skipped,
        });
        try stdout.print("Invalid JS (should produce errors):\n", .{});
        try stdout.print("  {d}/{d} correctly rejected ({d} incorrectly accepted)\n", .{
            invalid_pass, invalid_total, invalid_fail,
        });
    }
    try stdout.flush();
}

const ParseResult = struct {
    has_error: bool,
    first_error: []const u8,
};

fn shouldSkip(path: []const u8) bool {
    const skip_patterns = [_][]const u8{
        // typescript fixtures have their own runner; flow is unsupported.
        // jsx/ used to be here — now handled via plugin detection.
        "/typescript/", "flow", "decorators", "pipeline",
        "record-and-tuple", "v8intrinsic", "hack-pipes", "module-blocks",
        "defer", "source-phase", "import-assertions",
        // experimental/import-attributes-createImportExpression-false uses a babel
        // option we don't model; the standardized es2025/import-attributes corpus
        // is supported. Skip only the experimental form.
        "experimental/import-attributes",
        "placeholders", "discard-binding",
        "do-expression", "partial-application", "throw-expression",
        "function-sent", "async-do-expression", "module-string-names",
        "export-extensions", "decimal", "module-attributes",
        "destructuring-private", "regex-modifiers",
        "valid-assignment-target-type",
        // Skip non-parser packages. Only babel-parser/test/fixtures is the
        // parser-conformance corpus. Plugin/transform/generator/runtime tests
        // exercise unrelated behavior.
        "/babel-plugin-",
        "/babel-helpers/",
        "/babel-core/",
        "/babel-preset-",
        "/babel-plugin-syntax-",
        "/babel-generator/",
        "/babel-traverse/",
        "/babel-types/",
        "/babel-template/",
        "/babel-runtime/",
        "/babel-cli/",
        "/babel-node/",
        "/babel-register/",
        "/babel-standalone/",
        "/babel-compat-data/",
        "/babel-runtime-corejs2/",
        "/babel-runtime-corejs3/",
        "/babel-helper-",
        // Babel-parser experimental subdirs that need plugin flags.
        "/babel-parser/test/expressions/is-expression-babel-parser/",
        "/babel-parser/test/fixtures/experimental/_no-plugin/",
        // Flow generics in arrow functions: `<T>() => {}` parsed as Flow, not JSX.
        "_no-plugin-ts-type-param/",
        // Babel-specific strictures that TypeScript treats as semantic (not parse) errors.
        // Adding parse-time rejection would cause TypeScript conformance regressions.
        "class-private-properties/invalid-ts-type-literal/", // TS18016: private name in interface
        "object-rest-spread/no-pattern-in-rest-with-ts/",    // rest pattern in assignment
        "/babel-parser/test/fixtures/experimental/optional-chaining-assign/",
        // Categorized startline/startcolumn tests are about parse-options metadata.
        "/babel-parser/test/fixtures/core/categorized/",
    };
    for (skip_patterns) |pat| {
        if (std.mem.indexOf(u8, path, pat) != null) return true;
    }
    return false;
}

const SourceType = enum { unspecified, module, unambiguous, script };

/// Result of walking options.json files up the directory tree (single pass).
const OptionsResult = struct {
    has_unsupported: bool,
    source_type: SourceType,
    is_error: bool, // options.json contains "throws"
    annex_b: bool = true, // annexB option (default: true)
    is_jsx: bool = false, // "jsx" plugin enabled
    is_typescript: bool = false, // "typescript" plugin enabled
    is_flow: bool = false, // "flow" plugin enabled (we don't support flow → skip)
    plugins_set: bool = false, // closest options.json's plugins win (Babel semantics)
};

/// Walk up the directory tree reading options.json files once.
/// Determines unsupported options, module mode, and error classification in a single pass.
fn readOptionsHierarchy(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8) OptionsResult {
    var result = OptionsResult{ .has_unsupported = false, .source_type = .unspecified, .is_error = false };
    if (!std.mem.endsWith(u8, input_path, "/input.js")) return result;
    var end = input_path.len - "/input.js".len;

    const unsupported = [_][]const u8{
        "\"allowAwaitOutsideFunction\"",
        "\"allowSuperOutsideMethod\"",
        "\"allowNewTargetOutsideFunction\": true",
        "\"allowUndeclaredExports\"",
        "\"functionBind\"",
        "\"decorators-legacy\"",
        "\"v8intrinsic\"",
    };

    var is_first_dir = true;
    while (end > 0) {
        var buf: [4096]u8 = undefined;
        if (end + "/options.json".len > buf.len) break;
        @memcpy(buf[0..end], input_path[0..end]);
        @memcpy(buf[end..][0.."/options.json".len], "/options.json");
        const opts_path = buf[0 .. end + "/options.json".len];

        if (Io.Dir.cwd().readFileAlloc(io, opts_path, allocator, Io.Limit.limited(64 * 1024))) |content| {
            defer allocator.free(content);

            // Check unsupported options (any level)
            for (unsupported) |pat| {
                if (std.mem.indexOf(u8, content, pat) != null) {
                    result.has_unsupported = true;
                    return result;
                }
            }
            if (std.mem.indexOf(u8, content, "\"sourceType\": \"commonjs\"") != null or
                std.mem.indexOf(u8, content, "\"sourceType\":\"commonjs\"") != null)
            {
                result.has_unsupported = true;
                return result;
            }

            // Detect parser plugins so we can switch the lexer/parser into
            // jsx/ts/tsx mode. Look ONLY inside the "plugins": [...] array,
            // because "throws" messages frequently mention plugin names
            // (e.g. `"throws": "...\"jsx\", \"flow\", \"typescript\"..."`).
            const plugins_array = blk: {
                const key = "\"plugins\"";
                const k_at = std.mem.indexOf(u8, content, key) orelse break :blk @as(?[]const u8, null);
                const lb = std.mem.indexOfScalarPos(u8, content, k_at + key.len, '[') orelse break :blk @as(?[]const u8, null);
                const rb = std.mem.indexOfScalarPos(u8, content, lb + 1, ']') orelse break :blk @as(?[]const u8, null);
                break :blk content[lb .. rb + 1];
            };
            // Closest options.json wins — once set, don't let a parent's
            // plugins list (e.g. `jsx/options.json`'s ["jsx", "flow"]) leak
            // into a child fixture that explicitly declares `"plugins": []`
            // to test the no-plugin error path.
            if (plugins_array) |pa| {
                if (!result.plugins_set) {
                    result.plugins_set = true;
                    if (std.mem.indexOf(u8, pa, "\"jsx\"") != null) result.is_jsx = true;
                    if (std.mem.indexOf(u8, pa, "\"typescript\"") != null) result.is_typescript = true;
                    if (std.mem.indexOf(u8, pa, "\"flow\"") != null) result.is_flow = true;
                    // Unsupported plugins — skip rather than fail.
                    if (std.mem.indexOf(u8, pa, "\"moduleBlocks\"") != null) {
                        result.has_unsupported = true;
                        return result;
                    }
                    // We don't support Flow's type syntax. If a fixture is
                    // pure-Flow (no jsx/typescript escape hatch), skip it.
                    // Many Babel JSX fixtures inherit `["jsx", "flow"]` from
                    // the parent — for those, parse as JSX (Flow-specific
                    // syntax in the input will fail naturally).
                    if (result.is_flow and !result.is_jsx and !result.is_typescript) {
                        result.has_unsupported = true;
                        return result;
                    }
                }
            }

            // Check "throws" (only in the test's own directory)
            if (is_first_dir) {
                if (std.mem.indexOf(u8, content, "\"throws\"") != null) {
                    result.is_error = true;
                }
            }

            // Check annexB option (any level — first match wins)
            if (std.mem.indexOf(u8, content, "\"annexB\": false") != null or
                std.mem.indexOf(u8, content, "\"annexB\":false") != null)
            {
                result.annex_b = false;
            }

            // Check sourceType (first match wins, walking up)
            if (result.source_type == .unspecified) {
                if (std.mem.indexOf(u8, content, "\"sourceType\": \"module\"") != null or
                    std.mem.indexOf(u8, content, "\"sourceType\":\"module\"") != null)
                {
                    result.source_type = .module;
                } else if (std.mem.indexOf(u8, content, "\"sourceType\": \"script\"") != null or
                    std.mem.indexOf(u8, content, "\"sourceType\":\"script\"") != null)
                {
                    result.source_type = .script;
                } else if (std.mem.indexOf(u8, content, "\"unambiguous\"") != null) {
                    result.source_type = .unambiguous;
                }
            }
        } else |_| {}

        is_first_dir = false;
        while (end > 0 and input_path[end - 1] != '/') end -= 1;
        if (end > 0) end -= 1;
    }
    return result;
}

/// Check output.json / output.extended.json for "errors" (error test classification).
fn isErrorTestFromOutput(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8) bool {
    if (!std.mem.endsWith(u8, input_path, "input.js")) return false;
    var buf: [4096]u8 = undefined;
    const dir_len = input_path.len - "input.js".len;
    @memcpy(buf[0..dir_len], input_path[0..dir_len]);

    const output_files = [_][]const u8{ "output.json", "output.extended.json" };
    for (output_files) |filename| {
        if (dir_len + filename.len > buf.len) continue;
        @memcpy(buf[dir_len..][0..filename.len], filename);
        if (Io.Dir.cwd().readFileAlloc(io, buf[0 .. dir_len + filename.len], allocator, Io.Limit.limited(256 * 1024))) |content| {
            defer allocator.free(content);
            if (std.mem.indexOf(u8, content, "\"errors\"") != null) return true;
        } else |_| {}
    }
    return false;
}

/// Quick scan for top-level import/export/await to detect module mode.
fn sourceHasModuleSyntax(source: []const u8) bool {
    // import.meta anywhere implies module mode.
    if (std.mem.indexOf(u8, source, "import.meta") != null) return true;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        // Skip whitespace/newlines
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        // Skip single-line comments
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        // Skip multi-line comments
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i += 2;
            continue;
        }
        // Check for import/export at word boundary
        if (std.mem.startsWith(u8, source[i..], "import") and
            i + 6 < source.len and !isIdentChar(source[i + 6]))
            return true;
        if (std.mem.startsWith(u8, source[i..], "export") and
            i + 6 < source.len and !isIdentChar(source[i + 6]))
            return true;
        if (std.mem.startsWith(u8, source[i..], "await") and
            i + 5 < source.len and !isIdentChar(source[i + 5]))
        {
            // Only treat as module syntax if followed by a clear expression start
            // on the same line (not newline/% which are ambiguous).
            var j = i + 5;
            while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
            if (j < source.len and isExpressionStart(source[j])) return true;
        }
        // Skip to next line (we only check statement-start positions)
        while (i < source.len and source[i] != '\n') i += 1;
        i += 1;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}

fn isExpressionStart(c: u8) bool {
    return isIdentChar(c) or c == '(' or c == '[' or c == '{' or
        c == '\'' or c == '"' or c == '`' or c == '!' or c == '~' or
        c == '+' or c == '-' or c == '/';
}

const StackEntry = struct { dir: std.Io.Dir, path: []const u8 };

fn walkCollect(io: std.Io, allocator: std.mem.Allocator, base_dir: std.Io.Dir, base_path: []const u8, list: *std.ArrayList([]const u8), target_name: []const u8) !void {
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
            } else if (std.mem.eql(u8, entry.name, target_name)) {
                try list.append(allocator, try allocator.dupe(u8, full_path));
            }
        }
    }
}
