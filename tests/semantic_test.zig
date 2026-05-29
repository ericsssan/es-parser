const std = @import("std");
const testing = std.testing;
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const semantic = es_parser.semantic;
const ast_mod = es_parser.ast;
const scope_mod = es_parser.scope;
const symbol_mod = es_parser.symbol;

fn analyzeSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;

    var _lr = try Lexer.tokenize(allocator, source); defer _lr.deinit(allocator); var tokens = _lr.tokens;

    var tree = try Parser.parse(allocator, source, tokens.slice());
    defer tree.deinit(allocator);

    return semantic.SemanticAnalyzer.analyze(allocator, &tree);
}

// ── Scope Creation ──────────────────────────────────────

test "empty program creates global scope" {
    var result = try analyzeSource("");
    defer result.deinit(testing.allocator);

    // Should have at least the global scope
    try testing.expect(result.scopes.len() > 0);
}

test "function creates function scope" {
    var result = try analyzeSource("function foo() {}");
    defer result.deinit(testing.allocator);

    // Global + function scope = at least 2
    try testing.expect(result.scopes.len() >= 2);
}

test "block creates block scope" {
    var result = try analyzeSource("{ let x = 1; }");
    defer result.deinit(testing.allocator);

    // Global + block scope
    try testing.expect(result.scopes.len() >= 2);
}

// ── Symbol Declaration ──────────────────────────────────

test "var declaration creates symbol" {
    var result = try analyzeSource("var x = 1;");
    defer result.deinit(testing.allocator);

    try testing.expect(result.symbols.count() > 0);
}

test "let declaration creates symbol" {
    var result = try analyzeSource("let x = 1;");
    defer result.deinit(testing.allocator);

    try testing.expect(result.symbols.count() > 0);
}

test "const declaration creates symbol" {
    var result = try analyzeSource("const x = 1;");
    defer result.deinit(testing.allocator);

    try testing.expect(result.symbols.count() > 0);
}

test "function declaration creates symbol" {
    var result = try analyzeSource("function foo() {}");
    defer result.deinit(testing.allocator);

    try testing.expect(result.symbols.count() > 0);
}

test "multiple declarations" {
    var result = try analyzeSource("let a = 1; let b = 2; let c = 3;");
    defer result.deinit(testing.allocator);

    try testing.expect(result.symbols.count() >= 3);
}

// ── References ──────────────────────────────────────────

test "identifier creates reference" {
    var result = try analyzeSource("let x = 1; x;");
    defer result.deinit(testing.allocator);

    try testing.expect(result.references.count() > 0);
}

test "assignment creates write reference" {
    var result = try analyzeSource("let x; x = 1;");
    defer result.deinit(testing.allocator);

    try testing.expect(result.references.count() > 0);
}

// ── Scoping Rules ───────────────────────────────────────

test "var hoists to function scope" {
    var result = try analyzeSource(
        \\function foo() {
        \\    { var x = 1; }
        \\    return x;
        \\}
    );
    defer result.deinit(testing.allocator);

    // Should not have redeclaration errors for x
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "let is block scoped" {
    var result = try analyzeSource(
        \\{
        \\    let x = 1;
        \\}
    );
    defer result.deinit(testing.allocator);

    // x is scoped to the block
    try testing.expect(result.symbols.count() >= 1);
}

test "for loop let scoping" {
    var result = try analyzeSource(
        \\for (let i = 0; i < 10; i++) {
        \\    i;
        \\}
    );
    defer result.deinit(testing.allocator);

    // i should be declared
    try testing.expect(result.symbols.count() >= 1);
}

// ── Nested Scopes ───────────────────────────────────────

test "nested functions" {
    var result = try analyzeSource(
        \\function outer() {
        \\    let a = 1;
        \\    function inner() {
        \\        return a;
        \\    }
        \\}
    );
    defer result.deinit(testing.allocator);

    // outer, a, inner should be declared
    try testing.expect(result.symbols.count() >= 3);
}

test "class creates scope" {
    var result = try analyzeSource(
        \\class Foo {
        \\    constructor() {}
        \\    method() {}
        \\}
    );
    defer result.deinit(testing.allocator);

    // Foo class should be declared
    try testing.expect(result.symbols.count() >= 1);
}

// ── Parse fixture files ─────────────────────────────────

test "analyze scoping fixture" {
    const source = @embedFile("fixtures/semantic/scoping.js");
    var result = try analyzeSource(source);
    defer result.deinit(testing.allocator);

    // Should produce scopes and symbols without crashing
    try testing.expect(result.scopes.len() > 0);
    try testing.expect(result.symbols.count() > 0);
}

test "analyze hoisting fixture" {
    const source = @embedFile("fixtures/semantic/hoisting.js");
    var result = try analyzeSource(source);
    defer result.deinit(testing.allocator);

    try testing.expect(result.scopes.len() > 0);
    try testing.expect(result.symbols.count() > 0);
}

test "analyze closures fixture" {
    const source = @embedFile("fixtures/semantic/closures.js");
    var result = try analyzeSource(source);
    defer result.deinit(testing.allocator);

    try testing.expect(result.scopes.len() > 0);
    try testing.expect(result.symbols.count() > 0);
}
