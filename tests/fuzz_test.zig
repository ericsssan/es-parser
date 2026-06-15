const std = @import("std");
const es = @import("es_parser");

// ── Helpers ───────────────────────────────────────────────────────────────

/// Return the source bytes to fuzz with.
///
/// In corpus mode (normal `zig build test`) `smith.in` holds the raw corpus
/// entry bytes — return them verbatim so the seeds are treated as real source.
/// In live fuzzer mode (`smith.in == null`) fall through to `sliceWithHash`.
fn fuzzBytes(smith: *std.testing.Smith, buf: []u8) []const u8 {
    if (smith.in) |raw| return raw;
    const len = smith.sliceWithHash(buf, 0x65737061); // "espa"
    return buf[0..len];
}

/// Same as fuzzBytes but with a short buf to stress EOF boundary conditions.
fn fuzzBytesShort(smith: *std.testing.Smith, buf: []u8) []const u8 {
    if (smith.in) |raw| return raw;
    const len = smith.sliceWithHash(buf, 0x6c657869); // "lexi"
    return buf[0..len];
}

// ── Corpus seeds ─────────────────────────────────────────────────────────

const js_corpus: []const []const u8 = &.{
    @embedFile("fixtures/simple_function.js"),
    @embedFile("fixtures/expressions.js"),
    @embedFile("fixtures/variables.js"),
    @embedFile("fixtures/control_flow.js"),
    // Module mode / classes
    "export default function f() {}",
    "import { x } from './y.js'; x;",
    "class C extends B { #x = 1; get x() { return this.#x; } }",
    // Destructuring
    "const { a, b: [c, d] } = obj;",
    "const [x, ...rest] = arr;",
    // Async / generators
    "async function* gen() { yield await fetch('/'); }",
    "const p = async (x) => { const v = await x; return v; };",
    // Template literals
    "const s = `hello ${name}, you are ${age} years old`;",
    "tag`raw ${x}`;",
    // Optional chaining / nullish
    "const v = a?.b?.c ?? d;",
    "f?.(x);",
    // Logical assignment
    "a &&= b; a ||= c; a ??= d;",
    // Switch / try
    "switch (x) { case 1: break; default: throw new Error(); }",
    "try { f(); } catch (e) { g(e); } finally { h(); }",
    // For loops
    "for (const x of arr) { console.log(x); }",
    "for (let i = 0; i < 10; i++) {}",
    "for (const k in obj) {}",
    // Labels / break / continue
    "outer: for (;;) { inner: for (;;) { break outer; } }",
    "L: switch(x) { case 1: for(;;) { continue L; } }",
    // Arrow / params
    "const f = (x = 1, y = x + 1) => x + y;",
    "const g = ([a, b], {c, d: e}) => a + b + c + e;",
    "(a, b) => a + b;",
    // Regex with flags
    "const re = /^[a-z]+$/gi;",
    "const re2 = /(?:x|y){2,}/u;",
    // Control flow edge cases
    "switch(x){ case 1: break; default: break; case 2: break; }",
    "try { return; } finally { x = 1; }",
    // Deeply nested constructs (stress recursion counter)
    "const f = () => () => () => () => 1;",
    "{ { { { const x = 1; } } } }",
    "const [[[x]]] = arr;",
    "const {a: {b: {c}}} = obj;",
    // Strict mode directive
    "\"use strict\"; function f(x) { return x; }",
    "function f() { \"use strict\"; arguments; }",
    // global_return mode
    "return 42;",
    // Empty / trivial
    "",
    ";",
    "//comment\n",
    "/* block */",
};

const ts_corpus: []const []const u8 = &.{
    // Basic annotations
    "function f(x: number): string { return String(x); }",
    "const x: number = 1;",
    "let y: string | null = null;",
    // Generics
    "function id<T>(x: T): T { return x; }",
    "const map = <K, V>(k: K, v: V): Map<K, V> => new Map([[k, v]]);",
    // Interfaces / type aliases
    "interface I { x: number; y?: string; }",
    "type T = { a: string } & { b: number };",
    "type Maybe<T> = T | null | undefined;",
    // Enums
    "enum Dir { Up, Down, Left, Right }",
    "const enum Flags { A = 1, B = 2, C = A | B }",
    // Class with TS features
    "class C<T> implements I { constructor(private readonly x: T) {} }",
    "abstract class Base { abstract method(): void; }",
    // Type assertions / satisfies
    "const x = foo as string;",
    "const y = <number>bar;",
    "const z = val satisfies I;",
    // Decorators (legacy experimental_decorators)
    "@decorator class D {}",
    "@decorator method() {}",
    // Non-null assertion
    "document.getElementById('x')!.click();",
    // Conditional / mapped / template literal types
    "type IsString<T> = T extends string ? true : false;",
    "type Readonly<T> = { readonly [K in keyof T]: T[K] };",
    "type Greeting = `Hello ${string}`;",
    // Tuple types
    "type Pair = [string, number];",
    "type Named = [name: string, age: number];",
    // Ambient declarations / namespaces (dts-style)
    "declare namespace N { export const x: number; }",
    "declare function f(x: number): number;",
    "declare function f(x: string): string;",
    "declare module 'x' { export function g(): void; }",
    "declare global { interface Window { custom: any; } }",
    "declare const sym: unique symbol;",
    // Namespace merging
    "namespace A { export namespace B { export const x: number; } }",
    // Using declarations (TS 5.2+)
    "{ using r = getResource(); r.dispose(); }",
};

const jsx_corpus: []const []const u8 = &.{
    // Basic elements
    "<div />",
    "<Foo />",
    "<div>hello</div>",
    "<Foo bar={1} />",
    "<Foo bar=\"str\" />",
    // Fragments
    "<></>",
    "<>{x}</>",
    "<><Foo /><Bar /></>",
    // Nesting
    "<Foo><Bar><Baz /></Bar></Foo>",
    // Spread attributes
    "<Foo {...props} />",
    "<Foo x={1} {...rest} y={2} />",
    // Expression children
    "<Foo>{x + y}</Foo>",
    "<Foo>{x ? <Bar /> : <Baz />}</Foo>",
    // Namespace names
    "<svg:rect width=\"100\" />",
    // Hyphenated names
    "<custom-element />",
    // Multi-line / whitespace
    "<Foo\n  bar={1}\n  baz={2}\n/>",
    // Empty expression container
    "<Foo>{}</Foo>",
    // String literal children
    "<div>  hello  world  </div>",
    // Self-closing with complex attrs
    "<input type=\"text\" onChange={(e) => f(e)} />",
    // TSX type args
    "<Foo<T> />",
    "<Component<string, number> data={x} />",
    // Trivial
    "",
};

const sem_corpus: []const []const u8 = &.{
    @embedFile("fixtures/semantic/scoping.js"),
    @embedFile("fixtures/semantic/closures.js"),
    @embedFile("fixtures/semantic/hoisting.js"),
    // Reference resolution edge cases
    "var x; function f() { return x; } x = 1;",
    "function outer() { let x = 1; return function inner() { return x; }; }",
    "const a = 1; { const a = 2; console.log(a); } console.log(a);",
    // Hoisting
    "f(); function f() {} f();",
    "var x = x;",
    // Catch scope
    "try {} catch (e) { let f = e; }",
    "try {} catch ([a, b]) { a; }",
    // Class fields
    "class C { x = 1; #y = 2; static z = 3; m() { return this.x + this.#y; } }",
    // Generators / async scoping
    "function* gen() { let x = yield 1; return x; }",
    "async function f() { const x = await g(); return x; }",
    // AnnexB sloppy function in block
    "{ function f() {} } f();",
    "if (x) function f() {} else function f() {}",
    // Static blocks
    "class C { static { this.x = 1; } }",
    // Dynamic import
    "const m = await import('./mod.js'); m.default();",
};

// ── Fuzz tests ────────────────────────────────────────────────────────────

// ── JS / TS parse ─────────────────────────────────────────────────────────

test "fuzz: parse js" {
    try std.testing.fuzz({}, fuzzParseJs, .{ .corpus = js_corpus });
}

fn fuzzParseJs(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

test "fuzz: parse js module" {
    try std.testing.fuzz({}, fuzzParseJsModule, .{ .corpus = js_corpus });
}

fn fuzzParseJsModule(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .is_module = true, .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

test "fuzz: parse ts" {
    try std.testing.fuzz({}, fuzzParseTs, .{ .corpus = ts_corpus });
}

fn fuzzParseTs(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .ts) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .language = .ts, .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

// ── JSX / TSX ─────────────────────────────────────────────────────────────

test "fuzz: parse jsx" {
    try std.testing.fuzz({}, fuzzParseJsx, .{ .corpus = jsx_corpus });
}

fn fuzzParseJsx(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .jsx) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .language = .jsx, .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

test "fuzz: parse tsx" {
    try std.testing.fuzz({}, fuzzParseTsx, .{ .corpus = jsx_corpus });
}

fn fuzzParseTsx(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .tsx) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .language = .tsx, .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

// ── ParseOptions combinations ─────────────────────────────────────────────
// Each variant exercises an option branch not hit by the basic JS/TS tests.

test "fuzz: parse global_return" {
    try std.testing.fuzz({}, fuzzParseGlobalReturn, .{ .corpus = js_corpus });
}

fn fuzzParseGlobalReturn(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .global_return = true, .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

test "fuzz: parse annex_b disabled" {
    try std.testing.fuzz({}, fuzzParseNoAnnexB, .{ .corpus = js_corpus });
}

fn fuzzParseNoAnnexB(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .annex_b = false, .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

test "fuzz: parse ts experimental decorators" {
    try std.testing.fuzz({}, fuzzParseTsDecorators, .{ .corpus = ts_corpus });
}

fn fuzzParseTsDecorators(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .ts) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{
        .language = .ts,
        .is_module = true,
        .experimental_decorators = true,
        .emit_events = true,
    }) catch return;
    _ = &toks;
    _ = &tree;
}

test "fuzz: parse dts" {
    try std.testing.fuzz({}, fuzzParseDts, .{ .corpus = ts_corpus });
}

fn fuzzParseDts(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .dts) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .language = .dts, .is_module = true, .emit_events = true }) catch return;
    _ = &toks;
    _ = &tree;
}

// ── Lexer isolation ───────────────────────────────────────────────────────
// Short buffers (512 bytes) stress EOF boundary conditions in all 5 language
// modes. This is the class of bug caught by the recent scanHighIdentRun fix.

const lex_corpus: []const []const u8 = &.{
    // Valid tokens that should tokenize cleanly
    "let x", "\"string\"", "/regex/gi", "// comment", "/* block */",
    "`template`", "`${x}`", "\\u0041",
    // Boundary: multi-byte UTF-8 sequences
    "let \xC3\xA9", // é (2-byte)
    "let \xE2\x80\x8B", // ZWSP (3-byte, U+200B)
    // Truncated sequences at EOF — these should NOT crash
    "\xE2", "\xE2\x80", "\xC3", "\xF0\x9F",
    // Identifiers with escapes
    "\\u0069f", "\\u{41}", "a\\u0041b",
    // Numbers
    "0x1F", "0b1010", "0o17", "1_000_000",
    // JSX text / angle brackets
    "<div>", "</div>", "<>", "</>",
    "",
};

test "fuzz: lexer all languages" {
    try std.testing.fuzz({}, fuzzLexer, .{ .corpus = lex_corpus });
}

fn fuzzLexer(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined; // small → frequent EOF stress
    const src = fuzzBytesShort(smith, &buf);
    // Pick language based on first byte of input for coverage diversity.
    const langs = [_]es.token.Language{ .js, .ts, .jsx, .tsx, .dts };
    const lang = langs[if (src.len > 0) src[0] % langs.len else 0];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var toks = es.Lexer.tokenizeWithLanguage(arena.allocator(), src, lang) catch return;
    _ = &toks;
}

// ── Semantic analysis ─────────────────────────────────────────────────────

test "fuzz: semantic" {
    try std.testing.fuzz({}, fuzzSemantic, .{ .corpus = sem_corpus });
}

fn fuzzSemantic(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .emit_events = true }) catch return;
    _ = &toks;
    if (tree.errors.len > 0) return;
    var sem = es.semantic.SemanticAnalyzer.analyzeWithOptions(alloc, &tree, .{
        .diagnose_redeclare = true,
    }) catch return;
    _ = &sem;
}

test "fuzz: semantic ts" {
    try std.testing.fuzz({}, fuzzSemanticTs, .{ .corpus = ts_corpus });
}

fn fuzzSemanticTs(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .ts) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .language = .ts, .is_module = true, .emit_events = true }) catch return;
    _ = &toks;
    if (tree.errors.len > 0) return;
    var sem = es.semantic.SemanticAnalyzer.analyzeWithOptions(alloc, &tree, .{
        .is_module = true,
        .diagnose_redeclare = true,
    }) catch return;
    _ = &sem;
}

// Semantic with option combinations not covered by the default tests.

test "fuzz: semantic no-cfg" {
    try std.testing.fuzz({}, fuzzSemanticNoCfg, .{ .corpus = sem_corpus });
}

fn fuzzSemanticNoCfg(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .emit_events = true }) catch return;
    _ = &toks;
    if (tree.errors.len > 0) return;
    var sem = es.semantic.SemanticAnalyzer.analyzeWithOptions(alloc, &tree, .{
        .need_cfg = false,
    }) catch return;
    _ = &sem;
}

test "fuzz: semantic with parents" {
    try std.testing.fuzz({}, fuzzSemanticParents, .{ .corpus = sem_corpus });
}

fn fuzzSemanticParents(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .emit_events = true }) catch return;
    _ = &toks;
    if (tree.errors.len > 0) return;
    var sem = es.semantic.SemanticAnalyzer.analyzeWithOptions(alloc, &tree, .{
        .build_parents = true,
    }) catch return;
    _ = &sem;
}

test "fuzz: semantic annex_b disabled" {
    try std.testing.fuzz({}, fuzzSemanticNoAnnexB, .{ .corpus = sem_corpus });
}

fn fuzzSemanticNoAnnexB(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var toks = es.Lexer.tokenizeWithLanguage(alloc, src, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .annex_b = false, .emit_events = true }) catch return;
    _ = &toks;
    if (tree.errors.len > 0) return;
    var sem = es.semantic.SemanticAnalyzer.analyzeWithOptions(alloc, &tree, .{
        .annex_b = false,
        .diagnose_redeclare = true,
    }) catch return;
    _ = &sem;
}

// Structure-aware depth target for the scope-stack-depth class (#18). The
// byte-mutation semantic fuzzers above can't reach this bug: nesting depth is
// not a coverage dimension (level 257 hits the same edges as level 5), so the
// coverage engine gets no gradient toward 256+ balanced scopes, and no seed is
// deeply nested. They also have no correctness oracle — they discard the result
// and only check for crashes. Here the input length drives the nesting depth and
// we assert the invariant directly: legal lexical shadowing must never be
// reported as a duplicate binding, at any depth. Plain blocks only — they are the
// one construct that reaches >256 scopes within the parser's 400-deep recursion
// budget (if/for/functions each cost ~2 recursion levels). need_cfg = false keeps
// this on the scope-resolution path and clear of the try/finally CFG bug (#17).
test "fuzz: deeply nested scope shadowing (#18)" {
    try std.testing.fuzz({}, fuzzScopeDepth, .{ .corpus = sem_corpus });
}

fn fuzzScopeDepth(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    const seed = fuzzBytes(smith, &buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // One nested block per input byte, capped above the resolver's 256 growth
    // point and below the parser's max_recursion_depth (400).
    const depth = @min(seed.len, 350);
    var src: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    var i: usize = 0;
    while (i < depth) : (i += 1) src.appendSlice(alloc, "{ let x = 1; x;") catch return;
    i = 0;
    while (i < depth) : (i += 1) src.append(alloc, '}') catch return;

    var toks = es.Lexer.tokenizeWithLanguage(alloc, src.items, .js) catch return;
    var tree = es.Parser.parseWithOptions(alloc, src.items, toks.tokens.slice(), .{ .emit_events = true }) catch return;
    _ = &toks;
    if (tree.errors.len > 0) return; // hit the nesting limit etc. — not our concern
    const sem = es.semantic.SemanticAnalyzer.analyzeWithOptions(alloc, &tree, .{
        .diagnose_redeclare = true,
        .need_cfg = false,
    }) catch return;
    // Every `let x` lives in its own block scope: zero duplicate-binding errors.
    for (sem.diagnostics) |d| {
        if (d.severity == .@"error") return error.SpuriousRedeclareDiagnostic;
    }
}
