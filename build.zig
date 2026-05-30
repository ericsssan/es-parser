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
    const conf_mod = b.createModule(.{
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
    ptr_mod.addImport("es_parser", conf_mod);
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
    // Executables that run against fixture directories.
    // Usage:
    //   zig build conformance-parser-tests -- tests/conformance/test262-parser-tests
    //   zig build conformance-test262      -- tests/conformance/test262
    //   zig build conformance-babel        -- tests/conformance/babel/packages/babel-parser/test/fixtures

    const conf_releaseFast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const parser_tests_runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/parser_tests_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    parser_tests_runner_mod.addImport("es_parser", conf_releaseFast);
    const parser_tests_runner = b.addExecutable(.{
        .name = "parser_tests_runner",
        .root_module = parser_tests_runner_mod,
    });
    const parser_tests_runner_cmd = b.addRunArtifact(parser_tests_runner);
    parser_tests_runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| parser_tests_runner_cmd.addArgs(args);
    b.step("conformance-parser-tests", "Run tc39/test262-parser-tests conformance suite").dependOn(&parser_tests_runner_cmd.step);

    const test262_runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/test262_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    test262_runner_mod.addImport("es_parser", conf_releaseFast);
    const test262_runner = b.addExecutable(.{
        .name = "test262_runner",
        .root_module = test262_runner_mod,
    });
    const test262_runner_cmd = b.addRunArtifact(test262_runner);
    test262_runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| test262_runner_cmd.addArgs(args);
    b.step("conformance-test262", "Run tc39/test262 conformance suite").dependOn(&test262_runner_cmd.step);

    const babel_runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/babel_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    babel_runner_mod.addImport("es_parser", conf_releaseFast);
    const babel_runner = b.addExecutable(.{
        .name = "babel_runner",
        .root_module = babel_runner_mod,
    });
    const babel_runner_cmd = b.addRunArtifact(babel_runner);
    babel_runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| babel_runner_cmd.addArgs(args);
    b.step("conformance-babel", "Run Babel parser conformance suite").dependOn(&babel_runner_cmd.step);

    const typescript_runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/typescript_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    typescript_runner_mod.addImport("es_parser", conf_releaseFast);
    const typescript_runner = b.addExecutable(.{
        .name = "typescript_runner",
        .root_module = typescript_runner_mod,
    });
    const typescript_runner_cmd = b.addRunArtifact(typescript_runner);
    typescript_runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| typescript_runner_cmd.addArgs(args);
    b.step("conformance-typescript", "Run TypeScript parser conformance suite").dependOn(&typescript_runner_cmd.step);

    const semantic_runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/semantic_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    semantic_runner_mod.addImport("es_parser", conf_releaseFast);
    const semantic_runner = b.addExecutable(.{
        .name = "semantic_runner",
        .root_module = semantic_runner_mod,
    });
    const semantic_runner_cmd = b.addRunArtifact(semantic_runner);
    semantic_runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |bargs| semantic_runner_cmd.addArgs(bargs);
    b.step("conformance-semantic", "Run semantic analysis conformance suite").dependOn(&semantic_runner_cmd.step);
}
