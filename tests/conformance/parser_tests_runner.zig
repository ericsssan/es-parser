const std = @import("std");
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const Io = std.Io;

fn tokenizeMaybe(alloc: std.mem.Allocator, source: []const u8, lang: es_parser.token.Language, is_module: bool) !es_parser.scalar_lexer.TokenList {
    return es_parser.scalar_lexer.tokenizeScalarWithOptions(alloc, source, lang, .{ .is_module = is_module });
}

/// Fast runner for tc39/test262-parser-tests (directory-based classification).
/// Replaces the bash script that spawned a process per file.
///
/// Usage: parser_tests_runner <test262-parser-tests-dir>

// Known-stale tests in the abandoned test262-parser-tests repo (issues #3, #25, #31)
const known_stale = [_][]const u8{
    "0d5e450f1da8a92a.js", // '\9' — valid Annex B
    "748656edbfb2d0bb.js", // '\8' — valid Annex B
    "79f882da06f88c9f.js", // "\8" — valid Annex B
    "92b6af54adef3624.js", // "\9" — valid Annex B
    "98204d734f8c72b3.js", // (class {a}) — valid ES2022
    "ef81b93cf9bdb4ec.js", // (class {a=0}) — valid ES2022
    "a8beb1480f385441.js", // func() = 4 — valid Annex B (call-as-target)
    "e3fbcf63d7e43ead.js", // for(var x=1 in [1,2,3]) — valid Annex B B.3.5
};

fn isKnownStale(path: []const u8) bool {
    for (known_stale) |stale| {
        if (std.mem.endsWith(u8, path, stale)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 2) {
        try stdout.print("Usage: parser_tests_runner <test262-parser-tests-dir>\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    const base_dir = args[1];
    var compact_mode = false;
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--compact")) compact_mode = true;

    if (!compact_mode) {
        try stdout.print("test262-parser-tests (in-process)\n", .{});
        try stdout.print("=================================\n\n", .{});
        try stdout.flush();
    }

    const Mode = enum { must_pass, must_error, must_not_crash };
    const categories = [_]struct { dir: []const u8, name: []const u8, mode: Mode }{
        .{ .dir = "pass", .name = "pass/", .mode = .must_pass },
        .{ .dir = "pass-explicit", .name = "pass-explicit/", .mode = .must_pass },
        .{ .dir = "fail", .name = "fail/", .mode = .must_error },
        .{ .dir = "early", .name = "early/", .mode = .must_not_crash },
    };

    var overall_pass: u32 = 0;
    var overall_total: u32 = 0;
    var overall_skip: u32 = 0;
    var must_pass_pass: u32 = 0;
    var must_pass_total: u32 = 0;
    var must_error_pass: u32 = 0;
    var must_error_total: u32 = 0;

    for (categories) |cat| {
        var pass: u32 = 0;
        var fail: u32 = 0;
        var skip: u32 = 0;
        var total: u32 = 0;

        // Build path: base_dir/cat.dir
        var path_buf: [4096]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, cat.dir }) catch continue;

        // Open directory and iterate
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch continue;

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            const name = entry.name;
            if (!std.mem.endsWith(u8, name, ".js")) continue;

            if (cat.mode == .must_error and isKnownStale(name)) {
                skip += 1;
                continue;
            }

            total += 1;

            // Read file using the directory handle for relative reads
            const source = dir.readFileAlloc(io, name, allocator, Io.Limit.limited(2 * 1024 * 1024)) catch {
                fail += 1;
                continue;
            };
            defer allocator.free(source);

            // Detect module mode from .module.js extension
            const is_module = std.mem.endsWith(u8, name, ".module.js");

            // Parse
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const file_alloc = arena.allocator();

            const Result = enum { ok, has_errors, crashed };
            const result: Result = blk: {
                var tokens = tokenizeMaybe(file_alloc, source, .js, is_module) catch break :blk .crashed;
                defer tokens.deinit(file_alloc);
                var tree = Parser.parseWithLanguage(file_alloc, source, tokens.slice(), .js, is_module) catch break :blk .crashed;
                defer tree.deinit(file_alloc);
                if (tree.errors.len > 0) break :blk .has_errors;
                var sem = es_parser.semantic.SemanticAnalyzer.analyzeWithOptions(file_alloc, &tree, .{ .is_module = is_module, .diagnose_redeclare = true }) catch break :blk .ok;
                defer sem.deinit(file_alloc);
                break :blk if (sem.diagnostics.len > 0) .has_errors else .ok;
            };

            switch (cat.mode) {
                .must_pass => {
                    if (result == .ok) pass += 1 else {
                        fail += 1;
                        if (!compact_mode) try stdout.print("  FAIL (should pass): {s}/{s}\n", .{ dir_path, name });
                    }
                },
                .must_error => {
                    if (result != .ok) pass += 1 else {
                        fail += 1;
                        if (!compact_mode) try stdout.print("  FAIL (should reject): {s}/{s}\n", .{ dir_path, name });
                    }
                },
                .must_not_crash => {
                    // early/ tests may have errors, just must not crash (OOM)
                    if (result != .crashed) pass += 1 else fail += 1;
                },
            }
        }

        if (!compact_mode) {
            const label = switch (cat.mode) {
                .must_error => "rejected",
                .must_pass => "passed",
                .must_not_crash => "parsed",
            };
            if (skip > 0) {
                try stdout.print("  {s:<16}{d}/{d} {s} ({d} known-stale skipped)\n", .{ cat.name, pass, total, label, skip });
            } else {
                try stdout.print("  {s:<16}{d}/{d} {s}\n", .{ cat.name, pass, total, label });
            }
            try stdout.flush();
        }

        overall_pass += pass;
        overall_total += total;
        overall_skip += skip;
        switch (cat.mode) {
            .must_pass => {
                must_pass_pass += pass;
                must_pass_total += total;
            },
            .must_error, .must_not_crash => {
                must_error_pass += pass;
                must_error_total += total;
            },
        }
    }

    if (compact_mode) {
        try stdout.print("test262-parser-tests:  must-parse: {d}/{d}  must-reject: {d}/{d}  skipped: {d}\n", .{ must_pass_pass, must_pass_total, must_error_pass, must_error_total, overall_skip });
    } else {
        try stdout.print("\n  Overall: {d}/{d}\n", .{ overall_pass, overall_total });
    }
    try stdout.flush();
}
