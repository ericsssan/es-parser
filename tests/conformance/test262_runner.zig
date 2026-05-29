const std = @import("std");
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;

fn tokenizeMaybe(alloc: std.mem.Allocator, source: []const u8, lang: es_parser.token.Language, is_module: bool) !Lexer.TokenizeResult {
    return Lexer.tokenizeWithOptions(alloc, source, lang, is_module);
}
const Parser = es_parser.Parser;
const Io = std.Io;

/// tc39/test262 conformance runner.
///
/// Reads a file list from a text file (one path per line), parses each,
/// checks frontmatter for negative.phase:parse, and reports results.
///
/// Usage: test262_runner <filelist.txt>

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 2) {
        try stdout.print("Usage: test262_runner <dir-or-filelist>\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    const input_path = args[1];
    var compact = false;
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--compact")) compact = true;

    // Build file list: either read from a file list or walk a directory
    var file_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_list.items) |p| allocator.free(p);
        file_list.deinit(allocator);
    }

    // Check if input is a directory by trying to open it
    if (Io.Dir.cwd().openDir(io, input_path, .{}) catch null) |base_dir| {
        // Walk directory recursively collecting .js files
        try walkDir(io, allocator, base_dir, input_path, &file_list);
    } else {
        // Read as file list (one path per line)
        const list_data = Io.Dir.cwd().readFileAlloc(io, input_path, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch {
            try stdout.print("Cannot read {s}\n", .{input_path});
            try stdout.flush();
            std.process.exit(1);
        };
        defer allocator.free(list_data);
        var lines = std.mem.splitScalar(u8, list_data, '\n');
        while (lines.next()) |line| {
            const path = std.mem.trim(u8, line, " \t\r");
            if (path.len == 0 or !std.mem.endsWith(u8, path, ".js")) continue;
            const duped = try allocator.dupe(u8, path);
            try file_list.append(allocator, duped);
        }
    }

    if (!compact) {
        try stdout.print("tc39/test262 Parser Conformance\n", .{});
        try stdout.print("===============================\n\n", .{});
        try stdout.flush();
    }

    var reject_pass: u32 = 0;
    var reject_fail: u32 = 0;
    var parse_pass: u32 = 0;
    var parse_fail: u32 = 0;
    var skipped: u32 = 0;
    var total: u32 = 0;

    var fail_buf: [10000][]const u8 = undefined;
    var fail_count: usize = 0;
    var false_reject_buf: [10000][]const u8 = undefined;
    var false_reject_count: usize = 0;
    for (file_list.items) |path| {

        total += 1;

        const source = Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(2 * 1024 * 1024)) catch {
            skipped += 1;
            continue;
        };
        defer allocator.free(source);

        // Parse frontmatter to classify
        const kind = classifyTest(source);
        if (kind == .skip) {
            skipped += 1;
            continue;
        }

        // Skip _FIXTURE files (helper modules, not standalone tests)
        if (std.mem.indexOf(u8, path, "_FIXTURE") != null) {
            skipped += 1;
            continue;
        }

        // Detect module: flags: [module] or .mjs extension.
        // Note: directory-based heuristics (/module-code/, /export/, /import/) are
        // NOT used because some tests in those dirs are specifically for script mode.
        const is_module = isModuleTest(source) or
            std.mem.endsWith(u8, path, ".mjs");

        // Detect onlyStrict flag — prepend "use strict"; to source
        const only_strict = isOnlyStrict(source);

        // Parse using per-file arena to prevent allocator fragmentation
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const file_alloc = arena.allocator();

        const parse_source = if (only_strict) blk: {
            const prefix = "\"use strict\";\n";
            const buf = file_alloc.alloc(u8, prefix.len + source.len) catch {
                skipped += 1;
                continue;
            };
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..], source);
            break :blk buf;
        } else source;

        const result = tryParseDetailed(file_alloc, parse_source, is_module);

        switch (kind) {
            .must_reject => {
                if (result.has_error) {
                    reject_pass += 1;
                } else {
                    reject_fail += 1;
                    if (fail_count < fail_buf.len) {
                        fail_buf[fail_count] = path;
                        fail_count += 1;
                    }
                }
            },
            .must_parse => {
                if (!result.has_error) {
                    parse_pass += 1;
                } else {
                    parse_fail += 1;
                    if (false_reject_count < false_reject_buf.len) {
                        false_reject_buf[false_reject_count] = path;
                        false_reject_count += 1;
                    }
                }
            },
            .skip => {},
        }

        if (!compact and total % 5000 == 0) {
            try stdout.print("  ... {d}\n", .{total});
            try stdout.flush();
        }
    }

    const reject_total = reject_pass + reject_fail;
    const parse_total = parse_pass + parse_fail;
    const overall_total = reject_total + parse_total;
    const overall_pass = reject_pass + parse_pass;

    if (compact) {
        try stdout.print("tc39/test262:          must-parse: {d}/{d}  must-reject: {d}/{d}\n", .{ parse_pass, parse_total, reject_pass, reject_total });
    } else {
        try stdout.print("\nResults\n", .{});
        try stdout.print("-------\n", .{});
        try stdout.print("  Must-reject:  {d} / {d}\n", .{ reject_pass, reject_total });
        try stdout.print("  Must-parse:   {d} / {d}\n", .{ parse_pass, parse_total });
        try stdout.print("  Skipped:      {d}\n", .{skipped});
        try stdout.print("  Overall:      {d} / {d}\n\n", .{ overall_pass, overall_total });
    }
    try stdout.flush();

    if (fail_count > 0) {
        try stdout.print("Missed rejects ({d} total, showing {d}):\n", .{ reject_fail, fail_count });
        for (fail_buf[0..fail_count]) |p| {
            try stdout.print("  {s}\n", .{p});
        }
        try stdout.flush();
    }

    if (false_reject_count > 0) {
        try stdout.print("False rejects (showing {d}):\n", .{false_reject_count});
        for (false_reject_buf[0..false_reject_count]) |p| {
            try stdout.print("  {s}\n", .{p});
        }
        try stdout.flush();
    }
}

const ErrorDetail = struct {
    kind: enum { parse, semantic },
    count: u32,
};

fn tryParseDetailed(allocator: std.mem.Allocator, source: []const u8, is_module: bool) struct { has_error: bool, detail: ErrorDetail } {
    var tokens = (tokenizeMaybe(allocator, source, .js, is_module) catch return .{ .has_error = true, .detail = .{ .kind = .parse, .count = 0 } }).tokens;
    defer tokens.deinit(allocator);

    var tree = Parser.parseWithLanguage(allocator, source, tokens.slice(), .js, is_module) catch return .{ .has_error = true, .detail = .{ .kind = .parse, .count = 0 } };
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        if (std.mem.indexOf(u8, source, "BigInt literals as property keys") != null) {
            for (tree.errors[0..@min(tree.errors.len, 5)]) |e| {
                std.debug.print("  err span={d} \"{s}\"\n", .{e.span.start, e.message});
            }
        }
        return .{ .has_error = true, .detail = .{ .kind = .parse, .count = @intCast(tree.errors.len) } };
    }

    // Run semantic analysis to catch early errors (duplicate bindings, etc.)
    var sem = es_parser.semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, is_module) catch return .{ .has_error = false, .detail = .{ .kind = .semantic, .count = 0 } };
    defer sem.deinit(allocator);

    if (sem.diagnostics.len > 0) return .{ .has_error = true, .detail = .{ .kind = .semantic, .count = @intCast(sem.diagnostics.len) } };

    return .{ .has_error = false, .detail = .{ .kind = .semantic, .count = 0 } };
}

const TestKind = enum { must_reject, must_parse, skip };

fn classifyTest(source: []const u8) TestKind {
    const fm_start = std.mem.indexOf(u8, source, "/*---") orelse return .must_parse;
    const fm_end = std.mem.indexOfPos(u8, source, fm_start, "---*/") orelse return .must_parse;
    const fm = source[fm_start..fm_end];

    if (std.mem.indexOf(u8, fm, "phase: parse") != null or
        std.mem.indexOf(u8, fm, "phase: early") != null) return .must_reject;
    if (std.mem.indexOf(u8, fm, "phase: resolution") != null) return .skip;
    return .must_parse;
}

fn isOnlyStrict(source: []const u8) bool {
    const fm_start = std.mem.indexOf(u8, source, "/*---") orelse return false;
    const fm_end = std.mem.indexOfPos(u8, source, fm_start, "---*/") orelse return false;
    const fm = source[fm_start..fm_end];
    if (std.mem.indexOf(u8, fm, "flags:") == null) return false;
    return std.mem.indexOf(u8, fm, "onlyStrict") != null;
}

fn isModuleTest(source: []const u8) bool {
    const fm_start = std.mem.indexOf(u8, source, "/*---") orelse return false;
    const fm_end = std.mem.indexOfPos(u8, source, fm_start, "---*/") orelse return false;
    const fm = source[fm_start..fm_end];
    // Find "flags:" — accepts both inline form `flags: [module]` and
    // YAML list form `flags:\n  - module`.
    const flags_start = std.mem.indexOf(u8, fm, "flags:") orelse return false;
    // Inline form: same line.
    const inline_end = std.mem.indexOfPos(u8, fm, flags_start, "\n") orelse fm.len;
    if (std.mem.indexOf(u8, fm[flags_start..inline_end], "module") != null) return true;
    // YAML list form: scan continuation lines (start with whitespace).
    var pos = inline_end + 1;
    while (pos < fm.len) {
        const line_end = std.mem.indexOfPos(u8, fm, pos, "\n") orelse fm.len;
        const line = fm[pos..line_end];
        // Continuation lines are indented (start with space/tab).
        if (line.len == 0 or (line[0] != ' ' and line[0] != '\t')) break;
        if (std.mem.indexOf(u8, line, "module") != null) return true;
        pos = line_end + 1;
    }
    return false;
}

/// Recursively walk a directory collecting .js file paths.
const StackEntry = struct { dir: std.Io.Dir, path: []const u8 };

fn walkDir(io: std.Io, allocator: std.mem.Allocator, base_dir: std.Io.Dir, base_path: []const u8, list: *std.ArrayList([]const u8)) !void {
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
            } else if (std.mem.endsWith(u8, entry.name, ".js")) {
                try list.append(allocator, try allocator.dupe(u8, full_path));
            }
        }
    }
}
