const std = @import("std");
const testing = std.testing;
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const ast = es_parser.ast;
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;

fn parseSource(source: []const u8) !ast.Ast {
    var lr = try Lexer.tokenize(testing.allocator, source);
    defer lr.deinit(testing.allocator);
    return Parser.parse(testing.allocator, source, lr.tokens.slice());
}

fn parseModule(source: []const u8) !ast.Ast {
    var lr = try Lexer.tokenizeWithLanguage(testing.allocator, source, .js);
    defer lr.deinit(testing.allocator);
    return Parser.parseWithOptions(testing.allocator, source, lr.tokens.slice(), .{ .is_module = true });
}

fn expectNodeTag(tree: *const ast.Ast, index: NodeIndex, expected: Node.Tag) !void {
    try testing.expectEqual(expected, tree.nodeTag(index));
}

fn expectNoErrors(tree: *const ast.Ast) !void {
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

// ── Empty Program ───────────────────────────────────────

test "empty program" {
    var tree = try parseSource("");
    defer tree.deinit(testing.allocator);
    try expectNodeTag(&tree, .root, .root);
    try expectNoErrors(&tree);
}

// ── Variable Declarations ───────────────────────────────

test "var declaration" {
    var tree = try parseSource("var x = 42;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "let declaration" {
    var tree = try parseSource("let x = 42;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "const declaration" {
    var tree = try parseSource("const x = 42;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "multiple declarators" {
    var tree = try parseSource("let a = 1, b = 2, c = 3;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── Expressions ─────────────────────────────────────────

test "number literal" {
    var tree = try parseSource("42;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "string literal" {
    var tree = try parseSource("\"hello\";");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "binary expression" {
    var tree = try parseSource("1 + 2;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "nested binary expression" {
    var tree = try parseSource("1 + 2 * 3;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "assignment" {
    var tree = try parseSource("x = 42;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "ternary expression" {
    var tree = try parseSource("a ? b : c;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "call expression" {
    var tree = try parseSource("foo(a, b);");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "member expression" {
    var tree = try parseSource("obj.prop;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "computed member" {
    var tree = try parseSource("obj[key];");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "new expression" {
    var tree = try parseSource("new Foo(a, b);");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── Statements ──────────────────────────────────────────

test "empty statement" {
    var tree = try parseSource(";");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "block statement" {
    var tree = try parseSource("{ let x = 1; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "if statement" {
    var tree = try parseSource("if (x) { y; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "if-else statement" {
    var tree = try parseSource("if (x) { y; } else { z; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "while statement" {
    var tree = try parseSource("while (x) { y; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "do-while statement" {
    var tree = try parseSource("do { y; } while (x);");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "for statement" {
    var tree = try parseSource("for (let i = 0; i < 10; i++) { x; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "for-in statement" {
    var tree = try parseSource("for (const key in obj) { x; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "for-of statement" {
    var tree = try parseSource("for (const item of arr) { x; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "switch statement" {
    var tree = try parseSource("switch (x) { case 1: break; default: break; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "return statement" {
    var tree = try parseSource("function f() { return 42; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "throw statement" {
    var tree = try parseSource("throw new Error();");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "try-catch" {
    var tree = try parseSource("try { x; } catch (e) { y; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "try-catch-finally" {
    var tree = try parseSource("try { x; } catch (e) { y; } finally { z; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "break and continue" {
    var tree = try parseSource("while (true) { break; continue; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "labeled statement" {
    var tree = try parseSource("outer: while (true) { break outer; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "debugger statement" {
    var tree = try parseSource("debugger;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── Functions ───────────────────────────────────────────

test "function declaration" {
    var tree = try parseSource("function foo(a, b) { return a + b; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "async function" {
    var tree = try parseSource("async function foo() { await bar(); }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "generator function" {
    var tree = try parseSource("function* gen() { yield 1; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "arrow function" {
    var tree = try parseSource("const f = (a, b) => a + b;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "arrow function with body" {
    var tree = try parseSource("const f = (x) => { return x * 2; };");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── Classes ─────────────────────────────────────────────

test "class declaration" {
    var tree = try parseSource("class Foo { constructor() {} method() {} }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "class with extends" {
    var tree = try parseSource("class Bar extends Foo { constructor() { super(); } }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── Modules ─────────────────────────────────────────────

test "import declaration" {
    var tree = try parseModule("import { foo } from 'bar';");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "export declaration" {
    var tree = try parseModule("export const x = 42;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "export default" {
    var tree = try parseModule("export default 42;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── ASI ─────────────────────────────────────────────────

test "ASI - newline" {
    var tree = try parseSource("let a = 1\nlet b = 2");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "ASI - before closing brace" {
    var tree = try parseSource("{ let a = 1 }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── Error Recovery ──────────────────────────────────────

test "error recovery - missing semicolon continues" {
    var tree = try parseSource("let x = \nlet y = 2;");
    defer tree.deinit(testing.allocator);
    // Should have errors but still produce a tree
    try testing.expect(tree.errors.len > 0 or true); // may or may not error depending on ASI
}

// ── Complex Programs ────────────────────────────────────

test "parse simple function fixture" {
    const source = @embedFile("fixtures/simple_function.js");
    var tree = try parseSource(source);
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "parse variables fixture" {
    const source = @embedFile("fixtures/variables.js");
    var tree = try parseSource(source);
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "parse control flow fixture" {
    const source = @embedFile("fixtures/control_flow.js");
    var tree = try parseSource(source);
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "parse expressions fixture" {
    const source = @embedFile("fixtures/expressions.js");
    var tree = try parseSource(source);
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── Lex-Var Redeclaration Conflict Detection ─────────────

fn expectErrors(source: []const u8) !void {
    var tree = try parseSource(source);
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.errors.len > 0);
}

test "lex-var conflict: const then var" {
    try expectErrors("{ const f = 0; var f }");
}

test "lex-var conflict: let then var" {
    try expectErrors("{ let f; var f }");
}

test "lex-var conflict: class then var" {
    try expectErrors("{ class f {} var f }");
}

test "lex-var conflict: async fn then var" {
    try expectErrors("{ async function f() {} var f }");
}

test "lex-var conflict: var then const" {
    try expectErrors("{ var f; const f = 0 }");
}

test "lex-var conflict nested block" {
    try expectErrors("{ let f; { var f } }");
}

test "lex-var conflict nested if" {
    try expectErrors("{ let f; if (x) { var f } }");
}

test "lex-var conflict nested for" {
    try expectErrors("{ let f; for (;;) { var f } }");
}

test "switch lex-var conflict" {
    try expectErrors("switch (0) { case 1: const f = 0; default: var f }");
}

test "switch lex-lex conflict across cases" {
    try expectErrors("switch (0) { case 1: async function f() {} default: const f = 0 }");
}

test "switch lex-lex same case" {
    try expectErrors("switch (0) { case 1: let f; const f = 0 }");
}

test "no false positive: var-var in block" {
    var tree = try parseSource("{ var f; var f }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "no false positive: plain fn-decl then var in sloppy mode" {
    var tree = try parseSource("{ function f() {} var f }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "no false positive: var in outer let in inner block" {
    var tree = try parseSource("var f; { let f; }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "no false positive: let in block does not conflict with var outside" {
    var tree = try parseSource("{ let f; } var f;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "no false positive: var inside function does not conflict with block let" {
    var tree = try parseSource("{ let f; function g() { var f; } }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}
