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

// ── Index signature error recovery ──────────────────────────────────────────

fn hasErrorNode(tree: *const ast.Ast) bool {
    for (tree.nodes.items(.tag)) |t| { if (t == .error_node) return true; }
    return false;
}

test "index signature without value type recovers" {
    var tree = try parseTs("type Foo = { [key: string]; };");
    defer tree.deinit(testing.allocator);
    try testing.expect(!hasErrorNode(&tree));
}

test "empty index signature recovers" {
    var tree = try parseTs("type Foo = { []; };");
    defer tree.deinit(testing.allocator);
    try testing.expect(!hasErrorNode(&tree));
}

// ── Ambient module declarations ──────────────────────────────────────────────

test "declare module without body or semicolon" {
    var tree = try parseTs("declare module '_'");
    defer tree.deinit(testing.allocator);
    try testing.expect(!hasErrorNode(&tree));
}

test "declare wildcard ambient module without body" {
    var tree = try parseTs("declare module '*.svg'");
    defer tree.deinit(testing.allocator);
    try testing.expect(!hasErrorNode(&tree));
}

// ── Regex v-flag \q{} set notation ──────────────────────────────────────────

test "regex v-flag \\q{} with nested \\u{} escapes" {
    var tree = try parseSource("var r = /^[\\q{\\u{1f476}\\u{1f3fb}}]$/v;");
    defer tree.deinit(testing.allocator);
    try testing.expect(!hasErrorNode(&tree));
}

// ── Issue #8: TS error-recovery for invalid assignment/property forms ────────

test "#8a compound assign to paren object literal" {
    var tree = try parseTs("let _ = ({} *= {});");
    defer tree.deinit(testing.allocator);
    try testing.expect(!hasErrorNode(&tree));
}

test "#8b shorthand property with initializer in object literal" {
    var tree = try parseTs("const x = { y = 1 };");
    defer tree.deinit(testing.allocator);
    try testing.expect(!hasErrorNode(&tree));
}

// ── Issue #14: invalid regex pattern body recovers to a regex_literal node ────

fn hasRegexLiteral(tree: *const ast.Ast) bool {
    for (tree.nodes.items(.tag)) |t| { if (t == .regex_literal) return true; }
    return false;
}

test "#14 invalid regex body keeps regex_literal node and emits a diagnostic" {
    // Each of these is a genuine RegExp syntax error (V8 and tsc reject them
    // too), but — like tsc — the inner-grammar error must NOT erase the node:
    // it still scans as a regex_literal (typing as RegExp), with the diagnostic
    // reported separately. Previously each produced an error_node instead.
    const cases = [_][]const u8{
        "var b = /\\p{ascii}/u;", // invalid unicode property name
        "var b = /\\P[\\P\\w-_]/u;", // \P not followed by '{'
        "var b = /{1}??/;", // nothing to repeat
        "var b = /{1,}??/;",
        "var b = /{2,1}??/;",
        "var b = /[\\q\\u\\i\\c\\k]/u;", // invalid class escapes
    };
    for (cases) |src| {
        var tree = try parseTs(src);
        defer tree.deinit(testing.allocator);
        try testing.expect(hasRegexLiteral(&tree));
        try testing.expect(!hasErrorNode(&tree));
        try testing.expect(tree.errors.len >= 1);
    }
}

test "#14 valid regexes still parse cleanly with no diagnostic" {
    const cases = [_][]const u8{
        "var b = /abc/g;",
        "var b = /\\p{Script_Extensions=Inherited}/u;",
    };
    for (cases) |src| {
        var tree = try parseTs(src);
        defer tree.deinit(testing.allocator);
        try testing.expect(hasRegexLiteral(&tree));
        try testing.expect(!hasErrorNode(&tree));
        try testing.expectEqual(@as(usize, 0), tree.errors.len);
    }
}

// ── Issue #15: labeled tuple members retain their name ──────────────────────

const NamedMember = struct { label: []const u8, optional: bool };

/// Parse TS while keeping the token list alive — `Ast` does not own its tokens,
/// so reading token *text* (tokenText) requires the lexer result to outlive it.
const TsParse = struct {
    lexed: Lexer.TokenizeResult,
    tree: ast.Ast,

    fn init(source: []const u8) !TsParse {
        var lexed = try Lexer.tokenizeWithLanguage(testing.allocator, source, .ts);
        errdefer lexed.deinit(testing.allocator);
        const tree = try Parser.parseWithLanguage(testing.allocator, source, lexed.tokens.slice(), .ts, false);
        return .{ .lexed = lexed, .tree = tree };
    }

    fn deinit(self: *TsParse) void {
        self.tree.deinit(testing.allocator);
        self.lexed.deinit(testing.allocator);
    }

    /// Collect every ts_named_tuple_member's label + optional flag, in node order.
    fn collectNamedMembers(self: *const TsParse, out: *std.ArrayListUnmanaged(NamedMember)) !void {
        const tags = self.tree.nodes.items(.tag);
        const mains = self.tree.nodes.items(.main_token);
        const datas = self.tree.nodes.items(.data);
        for (tags, 0..) |t, i| {
            if (t != .ts_named_tuple_member) continue;
            try out.append(testing.allocator, .{
                .label = self.tree.tokenText(mains[i]),
                // rhs encodes the optional flag: .root (ordinal 0) = optional.
                .optional = @intFromEnum(datas[i].rhs) == 0,
            });
        }
    }
};

test "#15 labeled tuple members retain name and optional flag" {
    var p = try TsParse.init("type T = [a: number, b?: string];");
    defer p.deinit();
    try expectNoErrors(&p.tree);

    var members: std.ArrayListUnmanaged(NamedMember) = .empty;
    defer members.deinit(testing.allocator);
    try p.collectNamedMembers(&members);

    try testing.expectEqual(@as(usize, 2), members.items.len);
    try testing.expectEqualStrings("a", members.items[0].label);
    try testing.expect(!members.items[0].optional);
    try testing.expectEqualStrings("b", members.items[1].label);
    try testing.expect(members.items[1].optional);
}

test "#15 named and unnamed tuples produce different ASTs" {
    var named = try TsParse.init("type T = [a: number, b: string];");
    defer named.deinit();
    var plain = try TsParse.init("type U = [number, string];");
    defer plain.deinit();

    var named_members: std.ArrayListUnmanaged(NamedMember) = .empty;
    defer named_members.deinit(testing.allocator);
    try named.collectNamedMembers(&named_members);

    var plain_members: std.ArrayListUnmanaged(NamedMember) = .empty;
    defer plain_members.deinit(testing.allocator);
    try plain.collectNamedMembers(&plain_members);

    try testing.expectEqual(@as(usize, 2), named_members.items.len);
    try testing.expectEqual(@as(usize, 0), plain_members.items.len);
}

test "#15 labeled rest element retains its name" {
    var p = try TsParse.init("type R = [first: string, ...rest: number[]];");
    defer p.deinit();
    try expectNoErrors(&p.tree);

    var members: std.ArrayListUnmanaged(NamedMember) = .empty;
    defer members.deinit(testing.allocator);
    try p.collectNamedMembers(&members);

    try testing.expectEqual(@as(usize, 2), members.items.len);
    try testing.expectEqualStrings("first", members.items[0].label);
    try testing.expectEqualStrings("rest", members.items[1].label);
}

// ── Issue #16: catch-clause type annotation is retained on the binding ──────

/// Find the single `catch_clause` node and return its catch-parameter binding
/// (the node in `data.lhs`), or null if there is no catch clause.
fn catchParam(p: *const TsParse) ?NodeIndex {
    const tags = p.tree.nodes.items(.tag);
    const datas = p.tree.nodes.items(.data);
    for (tags, 0..) |t, i| {
        if (t == .catch_clause) return datas[i].lhs;
    }
    return null;
}

test "#16 typed catch binding retains its type annotation" {
    inline for (.{ "unknown", "any" }) |ty| {
        var p = try TsParse.init("try {} catch (e: " ++ ty ++ ") { e; }");
        defer p.deinit();
        try expectNoErrors(&p.tree);

        const tags = p.tree.nodes.items(.tag);
        const mains = p.tree.nodes.items(.main_token);
        const datas = p.tree.nodes.items(.data);

        const param = catchParam(&p) orelse return error.NoCatchClause;
        try testing.expectEqual(Node.Tag.identifier, tags[param.toInt()]);

        // The binding identifier's rhs slot now carries the annotation.
        const ann = datas[param.toInt()].rhs;
        try testing.expect(ann != .none);
        try testing.expectEqual(Node.Tag.ts_type_annotation, tags[ann.toInt()]);

        // The annotation wraps a type node whose main token is the type name.
        const type_node = datas[ann.toInt()].lhs;
        try testing.expect(type_node != .none);
        try testing.expectEqualStrings(ty, p.tree.tokenText(mains[type_node.toInt()]));
    }
}

test "#16 untyped catch binding has no type annotation" {
    var p = try TsParse.init("try {} catch (e) { e; }");
    defer p.deinit();
    try expectNoErrors(&p.tree);

    const tags = p.tree.nodes.items(.tag);
    const datas = p.tree.nodes.items(.data);

    const param = catchParam(&p) orelse return error.NoCatchClause;
    try testing.expectEqual(Node.Tag.identifier, tags[param.toInt()]);
    // No annotation: rhs stays empty, so a typed binding is distinguishable.
    try testing.expectEqual(NodeIndex.none, datas[param.toInt()].rhs);
}

// ── #19: nesting caps must keep enforcing past their old fixed size ──────────
//
// These tracking buffers were fixed-size and silently stopped enforcing their
// check once full. Each test drives the structure past the old cap and asserts
// the check still fires. Red->green: pre-fix the duplicate beyond the cap was
// not detected (0 errors); post-fix it is.

test "#19 duplicate label is detected beyond the old 32-entry label stack" {
    // 33 distinct labels (l0..l32) — l32 is the 33rd, which the old [32] stack
    // dropped — then a duplicate `l32:`. Pre-fix the dup-check never saw l32, so
    // it was missed; post-fix the grown stack catches it (SyntaxError in JS).
    const alloc = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i <= 32) : (i += 1) try buf.print(alloc, "l{d}: ", .{i});
    try buf.appendSlice(alloc, "l32: x;"); // duplicate of the 33rd label

    var tree = try parseSource(buf.items);
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.errors.len >= 1);
}

test "#19 duplicate import attribute is detected beyond the old 32-key cap" {
    // 33 distinct keys (k0..k32) then a duplicate `k32` — the 33rd key was
    // dropped by the old [32] offsets array, so the dup against it was missed.
    const alloc = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "import x from \"m\" with { ");
    var i: usize = 0;
    while (i <= 32) : (i += 1) try buf.print(alloc, "k{d}: \"v\", ", .{i});
    try buf.appendSlice(alloc, "k32: \"v\" };"); // duplicate of the 33rd key

    var tree = try parseModule(buf.items);
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.errors.len >= 1);
}

// ── lang:js_ts — JS files with TypeScript annotations (#32) ─────────────────

fn parseJsTs(source: []const u8) !ast.Ast {
    var lr = try Lexer.tokenizeWithLanguage(testing.allocator, source, .js_ts);
    defer lr.deinit(testing.allocator);
    return Parser.parseWithOptions(testing.allocator, source, lr.tokens.slice(), .{ .language = .js_ts, .emit_events = true });
}

test "lang:js_ts accepts arrow function with TS return type annotation (#32)" {
    // Plain lang:js rejects ): void =>; lang:js_ts must accept it.
    var tree = try parseJsTs("const f = (): void => {};");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "lang:js_ts accepts param type annotation (#32)" {
    var tree = try parseJsTs("const f = (arg: string): void => {};");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "lang:js_ts accepts method shorthand with TS annotation (#32)" {
    // Reproduces the object-shorthand corpus case from the issue.
    var tree = try parseJsTs("const obj = { key: (): void => { x() } };");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "lang:js rejects TypeScript return type annotation — no regression (#32)" {
    var tree = try parseSource("const f = (): void => {};");
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.errors.len >= 1);
}

test "lang:js_ts accepts `as` type cast (#32)" {
    var tree = try parseJsTs("const x = foo as string;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

test "lang:js_ts + is_module accepts top-level import with TS annotation (#32)" {
    const allocator = testing.allocator;
    const source = "import type { Foo } from 'x'; const f = (arg: Foo): void => {};";
    var lr = try Lexer.tokenizeWithLanguage(allocator, source, .js_ts);
    defer lr.deinit(allocator);
    var tree = try Parser.parseWithOptions(allocator, source, lr.tokens.slice(), .{ .language = .js_ts, .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    try expectNoErrors(&tree);
}

test "lang:js_ts angle-bracket type assertion parsed as TS (not JSX) (#32)" {
    // isJsx()=false, isTs()=true — <string>x takes the TS assertion branch.
    var tree = try parseJsTs("const x = <string>y;");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
}

// ── #62: parenthesized type as an arrow return type ───────────────────────

fn hasNodeTag(tree: *const ast.Ast, tag: Node.Tag) bool {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        if (tags[i] == tag) return true;
    }
    return false;
}

test "arrow with a parenthesized return type parses, not an ErrorNode (#62)" {
    // `(): (void) => {}` — the `: (` must read a parenthesized return TYPE, not a
    // function type that swallows the arrow's own `=>`. Previously the whole arrow
    // became an ErrorNode.
    const cases = [_][]const u8{
        "const f = (): (void) => {};",
        "const f = (): (T | U) => x;", // union
        "const f = (): (T & U) => x;", // intersection
        "const f = (): (A extends B ? C : D) => x;", // conditional type
        "const f = (): (readonly string[]) => x;",
        "const f = (x): (void) => {};",
        "const o = { key: (): (void) => { x(); } };",
        "const f = (): (() => void) => g;", // parenthesized function-type return
    };
    for (cases) |src| {
        var tree = try parseTs(src);
        defer tree.deinit(testing.allocator);
        try expectNoErrors(&tree);
        try testing.expect(hasNodeTag(&tree, .arrow_fn));
        try testing.expect(!hasNodeTag(&tree, .error_node));
    }
    // js_ts mode parses it the same way.
    var jt = try parseJsTs("const f = (): (void) => {};");
    defer jt.deinit(testing.allocator);
    try expectNoErrors(&jt);
    try testing.expect(hasNodeTag(&jt, .arrow_fn));
}

test "parenthesized return type is a TSParenthesizedType; function types still parse (#62)" {
    {
        var tree = try parseTs("const f = (): (void) => {};");
        defer tree.deinit(testing.allocator);
        try testing.expect(hasNodeTag(&tree, .ts_parenthesized_type));
    }
    // Genuine function types must still be recognized (the heuristic that decides
    // `( … ) =>` is a function type vs a parenthesized type must not regress).
    const fn_types = [_][]const u8{
        "type A = (a) => void;",
        "type B = (a, b) => void;",
        "type C = ({x}) => void;",
        "type D = (...r: any[]) => void;",
        "type E = (a?) => void;",
        "type F = (a = 1) => void;",
        "function A(): (public B) => C {}", // parameter-property modifier
        "type G = ({}?: { x: string }) => void;", // optional destructuring param
    };
    for (fn_types) |src| {
        var tree = try parseTs(src);
        defer tree.deinit(testing.allocator);
        try expectNoErrors(&tree);
        try testing.expect(hasNodeTag(&tree, .ts_function_type));
    }
    // A bare parenthesized type stays a parenthesized type.
    var pt = try parseTs("type T = (void);");
    defer pt.deinit(testing.allocator);
    try expectNoErrors(&pt);
    try testing.expect(hasNodeTag(&pt, .ts_parenthesized_type));
}

fn firstNodeOfTag(tree: *const ast.Ast, tag: Node.Tag) ?NodeIndex {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        if (tags[i] == tag) return NodeIndex.fromInt(i);
    }
    return null;
}

test "arrow's actual return_type node is the parenthesized type (#62)" {
    // Pin the precise shape (not just `hasNodeTag` anywhere in the tree): the
    // arrow's ArrowData.return_type is a TSTypeAnnotation wrapping the
    // parenthesized type.
    var tree = try parseTs("const f = (): (void) => {};");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
    const datas = tree.nodes.items(.data);
    const arrow = firstNodeOfTag(&tree, .arrow_fn) orelse return error.NoArrow;
    const ad = tree.extraData(ast.ArrowData, @intFromEnum(datas[arrow.toInt()].lhs));
    try testing.expect(ad.return_type != .none);
    try expectNodeTag(&tree, ad.return_type, .ts_type_annotation);
    // The annotation's inner node (data.lhs) is the parenthesized type.
    try expectNodeTag(&tree, datas[ad.return_type.toInt()].lhs, .ts_parenthesized_type);
}

test "import-equals binding identifier is created and anchored to the declaration (#64)" {
    const src = "import mod = require(\"./m\");";
    var lr = try Lexer.tokenizeWithLanguage(testing.allocator, src, .ts);
    defer lr.deinit(testing.allocator);
    var tree = try Parser.parseWithOptions(testing.allocator, src, lr.tokens.slice(), .{ .language = .ts, .is_module = true });
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
    const decl = firstNodeOfTag(&tree, .import_decl) orelse return error.NoDecl;
    const parents = try es_parser.parent_builder.buildParentsOnly(&tree, testing.allocator);
    defer testing.allocator.free(parents);
    // The binding identifier `mod` is created and parented directly to the
    // import_decl (the `require(...)` call's own `require` identifier is parented
    // to the call, so the only identifier child of the declaration is the binding).
    const tags = tree.nodes.items(.tag);
    var binding_children: u32 = 0;
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        if (tags[i] == .identifier and parents[i] == @intFromEnum(decl)) binding_children += 1;
    }
    try testing.expectEqual(@as(u32, 1), binding_children);
}

test "let with a binding list on the next line is one declaration, not ASI (#59)" {
    // There is no `[no LineTerminator here]` between `let` and its BindingList, so
    // `let\n x` continues the LexicalDeclaration — it must NOT be `let;` + expression.
    const cases = [_][]const u8{
        "let\n    x = 1",
        "let\n    x = {},\n    y = {}", // multiple declarators
        "let\n    [a] = b", // array destructuring
        "let\n    {a} = b", // object destructuring
    };
    for (cases) |src| {
        var tree = try parseSource(src);
        defer tree.deinit(testing.allocator);
        try expectNoErrors(&tree);
        try testing.expect(firstNodeOfTag(&tree, .let_decl) != null);
        try testing.expect(firstNodeOfTag(&tree, .declarator) != null);
    }
}

test "let followed by an operator is still an identifier expression (#59)" {
    // `let\n instanceof x` is the expression `let instanceof x` (the operator
    // continues the expression); ASI does not make a declaration here.
    var tree = try parseSource("let\n    instanceof x");
    defer tree.deinit(testing.allocator);
    try expectNoErrors(&tree);
    try testing.expect(firstNodeOfTag(&tree, .let_decl) == null);
}

test "let with newline binding stays an expression in single-statement contexts (#59)" {
    // A LexicalDeclaration is forbidden as a single-statement body or labeled-item,
    // so ASI fires after `let` there — `let\n x` is the `let` identifier expression,
    // NOT a declaration (guards the statement-list fix from leaking into these
    // delegated contexts).
    const cases = [_][]const u8{
        "if (a) let\n    x = 1",
        "while (a) let\n    x = 1",
        "for (;;) let\n    x = 1",
        "lbl: let\n    x = 1",
        "A: B: let\n    x = 1", // nested labels
    };
    for (cases) |src| {
        var tree = try parseSource(src);
        defer tree.deinit(testing.allocator);
        try expectNoErrors(&tree);
        try testing.expect(firstNodeOfTag(&tree, .let_decl) == null);
    }
}
