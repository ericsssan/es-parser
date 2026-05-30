const std = @import("std");
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const SemanticAnalyzer = es_parser.semantic.SemanticAnalyzer;
const ScopeKind = es_parser.scope.ScopeKind;
const ScopeId = es_parser.scope.ScopeId;
const SymbolId = es_parser.symbol.SymbolId;
const BindingKind = es_parser.symbol.BindingKind;
const Io = std.Io;

/// Semantic analysis fixture runner.
///
/// Walks a directory of `.js` / `.ts` fixture files, runs the full
/// parse + semantic pipeline on each, and reports a structural summary:
///   scopes / symbols / references / diagnostics per file
/// plus aggregate counts.  Useful for regression detection on the
/// scope/symbol/reference graph rather than just the diagnostic list.
///
/// Usage: semantic_runner <fixtures-dir>

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [16384]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 2) {
        try stdout.print("Usage: semantic_runner <fixtures-dir>\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    const fixtures_dir_path = args[1];
    const compact = args.len >= 3 and std.mem.eql(u8, args[2], "--compact");

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    const base_dir = Io.Dir.cwd().openDir(io, fixtures_dir_path, .{}) catch {
        try stdout.print("Cannot open directory: {s}\n", .{fixtures_dir_path});
        try stdout.flush();
        std.process.exit(1);
    };

    try collectSourceFiles(io, allocator, base_dir, fixtures_dir_path, &files);
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool { return std.mem.lessThan(u8, a, b); }
    }.lt);

    var total: u32 = 0;
    var pass: u32 = 0;    // parsed + analyzed with no error diagnostic
    var failed: u32 = 0;  // produced error-severity diagnostics or crashed

    // Aggregate structural counts across all fixtures.
    var total_scopes: u64 = 0;
    var total_symbols: u64 = 0;
    var total_refs: u64 = 0;
    var total_diag_errors: u64 = 0;
    var total_diag_warnings: u64 = 0;

    for (files.items) |path| {
        total += 1;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const file_alloc = arena.allocator();

        const source = Io.Dir.cwd().readFileAlloc(
            io, path, file_alloc, Io.Limit.limited(2 * 1024 * 1024),
        ) catch {
            failed += 1;
            if (!compact) try stdout.print("  FAIL (read error): {s}\n", .{path});
            continue;
        };

        const lang: es_parser.token.Language = if (std.mem.endsWith(u8, path, ".ts"))
            .ts
        else if (std.mem.endsWith(u8, path, ".tsx"))
            .tsx
        else
            .js;

        // Tokenize
        var lr = Lexer.tokenizeWithOptions(file_alloc, source, lang, false) catch {
            failed += 1;
            if (!compact) try stdout.print("  FAIL (lex error): {s}\n", .{path});
            continue;
        };
        defer lr.deinit(file_alloc);

        // Parse — emit scope events for the semantic pass.
        var tree = Parser.parseWithOptions(file_alloc, source, lr.tokens.slice(), .{
            .language = lang,
            .emit_events = true,
        }) catch {
            failed += 1;
            if (!compact) try stdout.print("  FAIL (parse OOM): {s}\n", .{path});
            continue;
        };
        defer tree.deinit(file_alloc);

        // Count parse-level error diagnostics.
        var parse_errors: u32 = 0;
        for (tree.errors) |d| {
            if (d.severity == .@"error") parse_errors += 1;
        }

        // Semantic analysis.
        var sem = SemanticAnalyzer.analyze(file_alloc, &tree) catch {
            failed += 1;
            if (!compact) try stdout.print("  FAIL (sem OOM): {s}\n", .{path});
            continue;
        };
        defer sem.deinit(file_alloc);

        // Count diagnostic severities.
        var sem_errors: u32 = 0;
        var sem_warnings: u32 = 0;
        for (sem.diagnostics) |d| {
            if (d.severity == .@"error") sem_errors += 1
            else if (d.severity == .warning) sem_warnings += 1;
        }

        const n_scopes = sem.scopes.len();
        const n_syms = sem.symbols.count();
        const n_refs = sem.references.count();
        const n_errs = parse_errors + sem_errors;

        total_scopes += n_scopes;
        total_symbols += n_syms;
        total_refs += n_refs;
        total_diag_errors += n_errs;
        total_diag_warnings += sem_warnings;

        if (n_errs == 0) {
            pass += 1;
            if (!compact) {
                try stdout.print(
                    "  OK  {s}  scopes={d} syms={d} refs={d}\n",
                    .{ path, n_scopes, n_syms, n_refs },
                );
            }
        } else {
            failed += 1;
            if (!compact) {
                try stdout.print(
                    "  ERR {s}  scopes={d} syms={d} refs={d} errors={d}\n",
                    .{ path, n_scopes, n_syms, n_refs, n_errs },
                );
                // Print first parse error for quick diagnosis.
                for (tree.errors) |d| {
                    if (d.severity == .@"error") {
                        try stdout.print("      parse: {s}\n", .{d.message});
                        break;
                    }
                }
                for (sem.diagnostics) |d| {
                    if (d.severity == .@"error") {
                        try stdout.print("      sem:   {s}\n", .{d.message});
                        break;
                    }
                }
            }
        }
        try stdout.flush();
    }

    try stdout.print(
        \\
        \\Semantic analysis results
        \\
        \\  Files:    {d} total, {d} clean, {d} with errors
        \\  Scopes:   {d}
        \\  Symbols:  {d}
        \\  Refs:     {d}
        \\  Diagnostics:  {d} errors, {d} warnings
        \\
        , .{ total, pass, failed,
             total_scopes, total_symbols, total_refs,
             total_diag_errors, total_diag_warnings });
    try stdout.flush();
}

/// Collect all `.js` / `.ts` / `.tsx` files under `base_dir` recursively.
fn collectSourceFiles(
    io: Io,
    allocator: std.mem.Allocator,
    base_dir: Io.Dir,
    base_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const Stack = struct { dir: Io.Dir, path: []const u8 };
    var stack: std.ArrayList(Stack) = .empty;
    defer {
        for (stack.items) |s| allocator.free(s.path);
        stack.deinit(allocator);
    }
    try stack.append(allocator, .{ .dir = base_dir, .path = try allocator.dupe(u8, base_path) });

    while (stack.items.len > 0) {
        const item = stack.pop().?;
        defer allocator.free(item.path);

        var iter = item.dir.iterate();
        while (iter.next(io) catch null) |entry| {
            var path_buf: [4096]u8 = undefined;
            const entry_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ item.path, entry.name }) catch continue;
            switch (entry.kind) {
                .directory => {
                    const sub = item.dir.openDir(io, entry.name, .{}) catch continue;
                    try stack.append(allocator, .{ .dir = sub, .path = try allocator.dupe(u8, entry_path) });
                },
                .file => {
                    if (std.mem.endsWith(u8, entry.name, ".js") or
                        std.mem.endsWith(u8, entry.name, ".ts") or
                        std.mem.endsWith(u8, entry.name, ".tsx"))
                    {
                        try out.append(allocator, try allocator.dupe(u8, entry_path));
                    }
                },
                else => {},
            }
        }
    }
}
