const std = @import("std");
const testing = std.testing;
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const semantic = es_parser.semantic;
const scope_mod = es_parser.scope;
const symbol_mod = es_parser.symbol;
const ScopeKind = scope_mod.ScopeKind;
const ScopeId = scope_mod.ScopeId;
const SymbolId = symbol_mod.SymbolId;
const BindingKind = symbol_mod.BindingKind;

fn analyzeSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenize(allocator, source);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parse(allocator, source, tokens.slice());
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyze(allocator, &tree);
}

fn analyzeModuleSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithOptions(allocator, source, .js, true);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, true);
}

test "analyze without scope-event emission errors instead of returning empty" {
    const allocator = testing.allocator;
    const source = "let x = 1; x;";
    var _lr = try Lexer.tokenize(allocator, source);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    // emit_events defaults to false here, so no scope events are produced.
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{});
    defer tree.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), tree.scope_events.len);
    try testing.expectError(
        semantic.SemanticAnalyzer.Error.MissingScopeEvents,
        semantic.SemanticAnalyzer.analyze(allocator, &tree),
    );
}

// ── Structural test helpers ─────────────────────────────────
//
// Unlike count-based smoke checks (`symbols.count() > 0`), these assert the
// actual shape of the semantic graph: which symbol exists, its binding kind,
// the scope kind it lives in, and how many references resolve to it.

/// Find the first symbol with the given name. Returns its SymbolId or null.
fn findSymbol(result: *const semantic.SemanticResult, name: []const u8) ?SymbolId {
    var i: u32 = 0;
    while (i < result.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, result.symbols.getName(id), name)) return id;
    }
    return null;
}

/// Count scopes of a given kind in the tree.
fn countScopesOfKind(result: *const semantic.SemanticResult, want: ScopeKind) u32 {
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < result.scopes.len()) : (i += 1) {
        if (result.scopes.kind(ScopeId.fromInt(i)) == want) n += 1;
    }
    return n;
}

/// Assert a symbol named `name` exists, with the given binding kind, declared in
/// a scope of `scope_kind`.
fn expectSymbol(
    result: *const semantic.SemanticResult,
    name: []const u8,
    binding: BindingKind,
    scope_kind: ScopeKind,
) !void {
    const id = findSymbol(result, name) orelse {
        std.debug.print("expected symbol '{s}' not found\n", .{name});
        return error.SymbolNotFound;
    };
    try testing.expectEqual(binding, result.symbols.getBindingKind(id));
    const sid = result.symbols.getScope(id);
    try testing.expectEqual(scope_kind, result.scopes.kind(sid));
}

// ── Scope structure ─────────────────────────────────────────

test "empty program: single global scope, no symbols" {
    var r = try analyzeSource("");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.scopes.len());
    try testing.expectEqual(ScopeKind.global, r.scopes.kind(ScopeId.fromInt(0)));
    try testing.expectEqual(@as(u32, 0), r.symbols.count());
}

test "function declaration creates a function scope under global" {
    var r = try analyzeSource("function foo() {}");
    defer r.deinit(testing.allocator);
    // Exactly one function scope, parented to the global scope.
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .function));
    var fn_scope: ?ScopeId = null;
    var i: u32 = 0;
    while (i < r.scopes.len()) : (i += 1) {
        const id = ScopeId.fromInt(i);
        if (r.scopes.kind(id) == .function) fn_scope = id;
    }
    const fs = fn_scope.?;
    try testing.expectEqual(ScopeKind.global, r.scopes.kind(r.scopes.parent(fs)));
    // `foo` is a function_decl bound in the global scope, not the function scope.
    try expectSymbol(&r, "foo", .function_decl, .global);
}

test "block scope holds let, not the enclosing scope" {
    var r = try analyzeSource("{ let x = 1; }");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .block));
    try expectSymbol(&r, "x", .let, .block);
}

test "module source produces a module scope" {
    var r = try analyzeModuleSource("export const y = 1;");
    defer r.deinit(testing.allocator);
    // A module source has a module scope nested under the global wrapper scope.
    // (Top-level module bindings attach to the global wrapper, eslint-scope style,
    // so we assert the const binding exists rather than pinning its exact scope.)
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .module));
    const y = findSymbol(&r, "y") orelse return error.SymbolNotFound;
    try testing.expectEqual(BindingKind.@"const", r.symbols.getBindingKind(y));
}

// ── Binding kinds ───────────────────────────────────────────

test "var/let/const get distinct binding kinds" {
    var r = try analyzeSource("var a = 1; let b = 2; const c = 3;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "a", .@"var", .global);
    try expectSymbol(&r, "b", .let, .global);
    try expectSymbol(&r, "c", .@"const", .global);
}

test "class declaration binding kind" {
    var r = try analyzeSource("class C {}");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "C", .class_decl, .global);
}

test "function parameters are parameter bindings in the function scope" {
    var r = try analyzeSource("function f(p, q) { return p; }");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "p", .parameter, .function);
    try expectSymbol(&r, "q", .parameter, .function);
}

test "catch parameter is bound in the catch scope" {
    var r = try analyzeSource("try { } catch (e) { e; }");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .catch_clause));
    try expectSymbol(&r, "e", .catch_param, .catch_clause);
}

// ── References ──────────────────────────────────────────────

test "reference resolves to its declaration" {
    var r = try analyzeSource("let x = 1; x; x;");
    defer r.deinit(testing.allocator);
    const x = findSymbol(&r, "x") orelse return error.SymbolNotFound;
    // Two read references to x (the declaration initializer is not a reference).
    const range = r.symbols.getRefRange(x);
    try testing.expect(range.len() >= 2);
    // Every reference in the range resolves to x.
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        try testing.expectEqual(x, r.references.getSymbol(ref_id));
    }
}

test "write reference is recorded for assignment" {
    var r = try analyzeSource("let x; x = 1;");
    defer r.deinit(testing.allocator);
    const x = findSymbol(&r, "x") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(x);
    var saw_write = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id).isWrite()) saw_write = true;
    }
    try testing.expect(saw_write);
}

// ── Scoping rules ───────────────────────────────────────────

test "var hoists to the function scope, not the inner block" {
    var r = try analyzeSource(
        \\function foo() {
        \\    { var x = 1; }
        \\    return x;
        \\}
    );
    defer r.deinit(testing.allocator);
    // `x` is a var; despite being written inside a block, it hoists to the
    // enclosing function scope.
    try expectSymbol(&r, "x", .@"var", .function);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "nested functions: inner symbol lives in inner scope" {
    var r = try analyzeSource(
        \\function outer() {
        \\    let a = 1;
        \\    function inner() { return a; }
        \\}
    );
    defer r.deinit(testing.allocator);
    // Two function scopes (outer, inner).
    try testing.expectEqual(@as(u32, 2), countScopesOfKind(&r, .function));
    // `a` is a let declared in the function body block — `let` binds to the
    // immediately enclosing block (the function body `{ ... }`), not the
    // function scope itself (only `var` and params hoist to the function scope).
    try expectSymbol(&r, "a", .let, .block);
    // `inner` is a function_decl declared inside outer's body block.
    try expectSymbol(&r, "inner", .function_decl, .block);
    // `outer` is a function_decl at the top level.
    try expectSymbol(&r, "outer", .function_decl, .global);
}

test "for-loop let is scoped to the loop block" {
    var r = try analyzeSource("for (let i = 0; i < 10; i++) { i; }");
    defer r.deinit(testing.allocator);
    const i_sym = findSymbol(&r, "i") orelse return error.SymbolNotFound;
    try testing.expectEqual(BindingKind.let, r.symbols.getBindingKind(i_sym));
    // The for-loop's `let` lives in a block scope, not the global scope.
    try testing.expect(r.scopes.kind(r.symbols.getScope(i_sym)) != .global);
}

// ── Fixtures: build without crashing and produce a non-trivial graph ──

test "analyze scoping fixture produces scopes and symbols" {
    const source = @embedFile("fixtures/semantic/scoping.js");
    var r = try analyzeSource(source);
    defer r.deinit(testing.allocator);
    try testing.expect(r.scopes.len() > 1);
    try testing.expect(r.symbols.count() > 0);
}

test "analyze hoisting fixture produces scopes and symbols" {
    const source = @embedFile("fixtures/semantic/hoisting.js");
    var r = try analyzeSource(source);
    defer r.deinit(testing.allocator);
    try testing.expect(r.scopes.len() > 1);
    try testing.expect(r.symbols.count() > 0);
}

test "analyze closures fixture produces scopes and symbols" {
    const source = @embedFile("fixtures/semantic/closures.js");
    var r = try analyzeSource(source);
    defer r.deinit(testing.allocator);
    try testing.expect(r.scopes.len() > 1);
    try testing.expect(r.symbols.count() > 0);
}

// ── Duplicate-binding early errors (opt-in diagnose_redeclare) ──────────────

/// Parse `source` (module or script) and return the number of redeclaration
/// diagnostics produced with `diagnose_redeclare` enabled.
fn redeclareDiagCount(source: []const u8, is_module: bool) !usize {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithOptions(allocator, source, .js, is_module);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .is_module = is_module, .emit_events = true });
    defer tree.deinit(allocator);
    // Skip cases the parser already rejects (e.g. `let x; let x;`): the early
    // error we test for is the semantic one, isolated from parser diagnostics.
    var r = try semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &tree, .{ .is_module = is_module, .diagnose_redeclare = true });
    defer r.deinit(allocator);
    return r.diagnostics.len;
}

/// Same as `redeclareDiagCount` but parses as TypeScript (module mode).
fn redeclareDiagCountTs(source: []const u8) !usize {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithLanguage(allocator, source, .ts);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .language = .ts, .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    var r = try semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &tree, .{ .is_module = true, .diagnose_redeclare = true });
    defer r.deinit(allocator);
    return r.diagnostics.len;
}

test "redeclare: TS function overloads are not flagged, real TS dups still are" {
    // Overload signatures + implementation share a name — valid TS, must NOT flag.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCountTs(
        "function f(x: number): void;\nfunction f(x: string): void;\nfunction f(x: any): void {}\nexport { f };\n",
    ));
    // But genuine duplicate lexical bindings are still errors in TS.
    try testing.expect(try redeclareDiagCountTs("class C {}\nclass C {}\nexport { C };\n") >= 1);
    try testing.expect(try redeclareDiagCountTs("let g = 1;\nfunction g() {}\nexport { g };\n") >= 1);
}

test "redeclare: lexical duplicate bindings are flagged" {
    // class + class, class + var, class + let — all duplicate lexical bindings.
    try testing.expect(try redeclareDiagCount("class A {}\nclass A {}\n", false) >= 1);
    try testing.expect(try redeclareDiagCount("class C {}\nvar C;\n", false) >= 1);
    try testing.expect(try redeclareDiagCount("class C {}\nlet C = 1;\n", false) >= 1);
}

test "redeclare: top-level function duplicate is module-only" {
    // Two top-level functions: legal in a Script (var-like), an error in a Module.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("function x() {}\nfunction x() {}\n", false));
    try testing.expect(try redeclareDiagCount("function x() {}\nfunction x() {}\n", true) >= 1);
}

test "redeclare: legal redeclarations are not flagged" {
    // var + var, var + function, function + function (script) are all allowed.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("var a;\nvar a;\n", false));
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("var b;\nfunction b() {}\n", false));
    // Annex B: a sloppy function nested in `if` does not conflict with an outer let.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("let f = 1;\nif (false) function _f() {} else function f() {}\n", false));
}
