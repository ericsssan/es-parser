const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Parser library module ─────────────────────────────
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Expose as a named module so external projects can depend on it.
    _ = b.addModule("es-parser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ── Unit tests (embedded in src/) ────────────────────
    const unit_tests = b.addTest(.{ .root_module = lib_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // ── Parser tests ─────────────────────────────────────
    const parser_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/parser_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    parser_test_mod.addImport("es_parser", lib_mod);
    const parser_tests = b.addTest(.{ .root_module = parser_test_mod });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    // ── Lexer tests ───────────────────────────────────────
    const lexer_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/lexer_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lexer_test_mod.addImport("es_parser", lib_mod);
    const lexer_tests = b.addTest(.{ .root_module = lexer_test_mod });
    const run_lexer_tests = b.addRunArtifact(lexer_tests);

    // ── Semantic tests ────────────────────────────────────
    const semantic_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/semantic_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    semantic_test_mod.addImport("es_parser", lib_mod);
    const semantic_tests = b.addTest(.{ .root_module = semantic_test_mod });
    const run_semantic_tests = b.addRunArtifact(semantic_tests);

    // ── Conformance: test262-parser-tests (always run, submodule included) ──
    // Shared ReleaseFast build of the parser, reused by the bundled test-step
    // runner below and every standalone conformance runner.
    const conf_releaseFast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const ptr_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/parser_tests_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    ptr_mod.addImport("es_parser", conf_releaseFast);
    const ptr_exe = b.addExecutable(.{ .name = "parser_tests_runner", .root_module = ptr_mod });
    const ptr_cmd = b.addRunArtifact(ptr_exe);
    ptr_cmd.addArg("tests/conformance/test262-parser-tests");
    ptr_cmd.addArg("--compact");

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_lexer_tests.step);
    test_step.dependOn(&run_semantic_tests.step);
    test_step.dependOn(&ptr_cmd.step);

    // ── Conformance runners ───────────────────────────────
    // Executables that run against fixture directories. Each step has a default
    // fixture path (the correct conformance input set) so `zig build conformance-X`
    // works with no arguments; pass `-- <dir>` to override. NOTE: the TypeScript
    // input set is `tests/cases` — the runner derives error baselines from a sibling
    // `tests/baselines/reference`, so it must NOT be pointed at the whole tree.

    addConformanceRunner(b, target, conf_releaseFast, "parser_tests_runner", "tests/conformance/parser_tests_runner.zig", "conformance-parser-tests", "Run tc39/test262-parser-tests conformance suite", "tests/conformance/test262-parser-tests");
    addConformanceRunner(b, target, conf_releaseFast, "test262_runner", "tests/conformance/test262_runner.zig", "conformance-test262", "Run tc39/test262 conformance suite", "tests/conformance/test262");
    addConformanceRunner(b, target, conf_releaseFast, "babel_runner", "tests/conformance/babel_runner.zig", "conformance-babel", "Run Babel parser conformance suite", "tests/conformance/babel/packages/babel-parser/test/fixtures");
    addConformanceRunner(b, target, conf_releaseFast, "typescript_runner", "tests/conformance/typescript_runner.zig", "conformance-typescript", "Run TypeScript parser conformance suite", "tests/conformance/typescript/tests/cases");
    addConformanceRunner(b, target, conf_releaseFast, "semantic_runner", "tests/conformance/semantic_runner.zig", "conformance-semantic", "Run semantic analysis conformance suite", "tests/conformance/typescript/tests/cases");
}

/// Wire up one standalone conformance runner: a ReleaseFast executable built
/// from `src`, importing the shared parser module `dep`, exposed as build step
/// `step_name`. Runs against `default_fixture` unless `-- <args>` overrides it.
fn addConformanceRunner(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    dep: *std.Build.Module,
    name: []const u8,
    src: []const u8,
    step_name: []const u8,
    desc: []const u8,
    default_fixture: []const u8,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(src),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    mod.addImport("es_parser", dep);
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    const cmd = b.addRunArtifact(exe);
    cmd.step.dependOn(b.getInstallStep());
    // `-- <args>` overrides the default fixture path; with no args, run the
    // documented conformance input set so `zig build conformance-X` just works.
    // `b.args` only exists on some Zig versions — guard with @hasField so this
    // compiles across the supported range (the field was removed after dev.305).
    if (@hasField(@TypeOf(b.*), "args")) {
        if (b.args) |args| cmd.addArgs(args) else cmd.addArg(default_fixture);
    } else {
        cmd.addArg(default_fixture);
    }
    b.step(step_name, desc).dependOn(&cmd.step);
}
