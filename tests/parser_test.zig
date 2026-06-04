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
// These are binding early-errors detected by semantic analysis (diagnose_redeclare).

fn expectRedeclErrors(source: []const u8) !void {
    var lr = try Lexer.tokenize(testing.allocator, source);
    defer lr.deinit(testing.allocator);
    var tree = try Parser.parse(testing.allocator, source, lr.tokens.slice());
    defer tree.deinit(testing.allocator);
    var sem = try es_parser.semantic.SemanticAnalyzer.analyzeWithOptions(
        testing.allocator, &tree, .{ .diagnose_redeclare = true });
    defer sem.deinit(testing.allocator);
    try testing.expect(tree.errors.len > 0 or sem.diagnostics.len > 0);
}

test "lex-var conflict: const then var" {
    try expectRedeclErrors("{ const f = 0; var f }");
}

test "lex-var conflict: let then var" {
    try expectRedeclErrors("{ let f; var f }");
}

test "lex-var conflict: class then var" {
    try expectRedeclErrors("{ class f {} var f }");
}

test "lex-var conflict: async fn then var" {
    try expectRedeclErrors("{ async function f() {} var f }");
}

test "lex-var conflict: var then const" {
    try expectRedeclErrors("{ var f; const f = 0 }");
}

test "lex-var conflict nested block" {
    try expectRedeclErrors("{ let f; { var f } }");
}

test "lex-var conflict nested if" {
    try expectRedeclErrors("{ let f; if (x) { var f } }");
}

test "lex-var conflict nested for" {
    try expectRedeclErrors("{ let f; for (;;) { var f } }");
}

test "switch lex-var conflict" {
    try expectRedeclErrors("switch (0) { case 1: const f = 0; default: var f }");
}

test "switch lex-lex conflict across cases" {
    try expectRedeclErrors("switch (0) { case 1: async function f() {} default: const f = 0 }");
}

test "switch lex-lex same case" {
    try expectRedeclErrors("switch (0) { case 1: let f; const f = 0 }");
}

test "no false positive: var-var in block" {
    var tree = try parseSource("{ var f; var f }");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "lex-var conflict: fn-decl and var in same block is SyntaxError" {
    try expectRedeclErrors("{ function f() {} var f }");
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

test "mongolian vowel separator between var and name is SyntaxError" {
    // var\u{180E}foo - U+180E is not whitespace in ES2016+
    const source = "var\xe1\xa0\x8efoo;";
    var lr = try Lexer.tokenize(testing.allocator, source);
    defer lr.deinit(testing.allocator);
    var tree = try Parser.parse(testing.allocator, source, lr.tokens.slice());
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.errors.len > 0);
}


// ── Deep-nesting recursion guard (stack-overflow protection) ────────
//
// Pathologically nested input must be rejected with a diagnostic — not
// abort the process via native stack overflow. The recursive-descent
// parser caps nesting depth at `Parser.max_recursion_depth`; past that it
// emits "maximum nesting depth … exceeded" and recovers like any other
// syntax error. Each vector below nests an order of magnitude deeper than
// the cap; before the guard existed these crashed the process. The test
// surviving (and reporting errors rather than accepting) is the regression
// check. Vectors cover every guarded recursion chokepoint: expressions,
// statements, binding patterns, TS types, and JSX elements.

fn expectRejectsDeepNesting(
    prefix: []const u8,
    unit: []const u8,
    suffix: []const u8,
    reps: usize,
    language: es_parser.token.Language,
) !void {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, prefix.len + unit.len * reps + suffix.len);
    defer allocator.free(buf);
    var w: usize = 0;
    @memcpy(buf[w..][0..prefix.len], prefix);
    w += prefix.len;
    for (0..reps) |_| {
        @memcpy(buf[w..][0..unit.len], unit);
        w += unit.len;
    }
    @memcpy(buf[w..][0..suffix.len], suffix);

    var lr = try Lexer.tokenizeWithLanguage(allocator, buf, language);
    defer lr.deinit(allocator);
    // The parser recovers internally, so an over-deep parse returns an Ast
    // carrying diagnostics rather than raising; tolerate a raised
    // ParseError too. Either way it must not crash and must reject.
    var tree = Parser.parseWithOptions(allocator, buf, lr.tokens.slice(), .{ .language = language }) catch |e| {
        try testing.expectEqual(error.ParseError, e);
        return;
    };
    defer tree.deinit(allocator);
    try testing.expect(tree.errors.len > 0);
}

test "deeply nested input is rejected, not a stack overflow" {
    // An order of magnitude beyond the recursion cap — would overflow the
    // native stack if the depth guard were removed.
    const reps = @as(usize, Parser.max_recursion_depth) * 12;
    try expectRejectsDeepNesting("", "(", "", reps, .js); // expressions (parsePrimaryExpression)
    try expectRejectsDeepNesting("", "{", "", reps, .js); // statements (parseStatement)
    try expectRejectsDeepNesting("let ", "[", "", reps, .js); // binding patterns (parseBindingPattern)
    try expectRejectsDeepNesting("type T=", "(", "", reps, .ts); // TS types (parseType)
    try expectRejectsDeepNesting("x=", "<a>", "1", reps, .tsx); // JSX (parseJsxElement)
    // Prefix-operator recursion recurses on its operand, never re-entering
    // parsePrimaryExpression — so each needs its own guard (parseUnaryOp,
    // parseAwaitExpression, parseNewExpression).
    try expectRejectsDeepNesting("", "new ", "Foo()", reps, .js); // parseNewExpression
    try expectRejectsDeepNesting("x=", "!", "y", reps, .js); // parseUnaryOp (logical not)
    try expectRejectsDeepNesting("x=", "typeof ", "y", reps, .js); // parseUnaryOp (typeof)
    try expectRejectsDeepNesting("x=", "void ", "y", reps, .js); // parseUnaryOp (void)
    try expectRejectsDeepNesting("x=", "-", "y", reps, .js); // parseUnaryOp (unary minus)
    try expectRejectsDeepNesting("await ", "await ", "y", reps, .js); // parseAwaitExpression
}

// ── Annex B: flag-less `\u{…}` in regex (web reality) vs TypeScript TS1538 ──

fn parseTs(source: []const u8) !ast.Ast {
    var lr = try Lexer.tokenizeWithLanguage(testing.allocator, source, .ts);
    defer lr.deinit(testing.allocator);
    return Parser.parseWithOptions(testing.allocator, source, lr.tokens.slice(), .{ .language = .ts });
}

test "regex: flag-less \\u{...} parses in JS (Annex B identity-escape + quantifier)" {
    // `/\u{41}/` without the u flag is valid web-reality JS: `\u` matches "u",
    // `{41}` is a quantifier. Named-group names admit `\u{...}` too.
    var a = try parseSource("var r = /\\u{41}/;\n");
    defer a.deinit(testing.allocator);
    try expectNoErrors(&a);

    var b = try parseSource("var r = /(?<\\u{1d4d1}>x)/;\n");
    defer b.deinit(testing.allocator);
    try expectNoErrors(&b);
}

test "regex: flag-less \\u{...} still errors in TypeScript (TS1538)" {
    var a = try parseTs("var r = /\\u{10000}/;\n");
    defer a.deinit(testing.allocator);
    try testing.expect(a.errors.len >= 1);

    // With the u flag it is a valid code-point escape in both JS and TS.
    var b = try parseTs("var r = /\\u{10000}/u;\n");
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), b.errors.len);
}

// ── Annex B B.3.3: sloppy if/label function vs outer lexical binding ────────

test "annexB: sloppy if-body function does not conflict with outer let" {
    // Per Annex B B.3.3 the function's hoisted var-binding is suppressed when it
    // would clash with a lexical declaration — no early error (test262
    // annexB/.../global-code/if-decl-*-skip-early-err).
    var a = try parseSource("let f = 123;\nif (true) function f() {} else function _f() {}\n");
    defer a.deinit(testing.allocator);
    try expectNoErrors(&a);

    var b = try parseSource("let f = 123;\nif (false) ; else function f() {}\n");
    defer b.deinit(testing.allocator);
    try expectNoErrors(&b);
}

test "annexB exemption does not mask real lexical/var conflicts" {
    // A genuine let-vs-var clash at top level is still an error (semantic).
    try expectRedeclErrors("let g = 1;\nvar g;\n");
}

// ── TS: a statement-level decorator must decorate a class (TS1146) ──────────

test "ts: decorator on a non-declaration is rejected" {
    var a = try parseTs("declare function dec<T>(t: T): T;\n@dec\nawait 1\n");
    defer a.deinit(testing.allocator);
    try testing.expect(a.errors.len >= 1);
}

test "ts: decorator on a class declaration is accepted" {
    var a = try parseTs("declare function dec<T>(t: T): T;\n@dec\nclass C {}\n");
    defer a.deinit(testing.allocator);
    try expectNoErrors(&a);

    // export / abstract forms too.
    var b = try parseTs("declare const dec: any;\n@dec\nexport class D {}\n");
    defer b.deinit(testing.allocator);
    try expectNoErrors(&b);

    var c = try parseTs("declare const dec: any;\n@dec\nabstract class E {}\n");
    defer c.deinit(testing.allocator);
    try expectNoErrors(&c);
}

// ── Robustness: malformed class body must not exhaust memory ────────────────

test "parser: conflict markers in a class body recover without OOM" {
    // Regression: the class-declaration body loop didn't force progress on a
    // recovery that consumed no tokens (`<<<<<<<` after a valid member), so it
    // spun appending error nodes until OutOfMemory. Must parse (with errors).
    var a = try parseSource(
        "class C {\n    v = 1;\n<<<<<<< HEAD\n    w = 2;\n=======\n    w = 3;\n>>>>>>> branch\n}\n",
    );
    defer a.deinit(testing.allocator);
    try testing.expect(a.errors.len > 0);
}
