const std = @import("std");
const es = @import("es_parser");

// ── Helpers ───────────────────────────────────────────────────────────────

/// Return the source bytes to fuzz with.
///
/// In corpus mode (normal `zig build test`, or seeded fuzzer runs) `smith.in`
/// holds the raw corpus entry bytes — return them verbatim so the seeds are
/// treated as real JS/TS source.
///
/// In live fuzzer mode (`smith.in == null`) fall through to `sliceWithHash`
/// so the fuzzer's coverage-directed mutations drive the byte sequence.
fn fuzzBytes(smith: *std.testing.Smith, buf: []u8) []const u8 {
    if (smith.in) |raw| return raw;
    const len = smith.sliceWithHash(buf, 0x65737061); // "espa"
    return buf[0..len];
}

// ── Corpus seeds ─────────────────────────────────────────────────────────
// Embedded at compile time; these are the initial seed inputs used when
// running `zig build test` normally (each corpus entry runs testOne once),
// and they guide coverage-directed mutation during `zig build test --fuzz`.

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
    // Labels / break
    "outer: for (;;) { inner: for (;;) { break outer; } }",
    // Tricky parens / arrow
    "const f = (x = 1, y = x + 1) => x + y;",
    "(a, b) => a + b;",
    // Regex
    "const re = /^[a-z]+$/gi;",
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
    // Decorators
    "@decorator class D {}",
    // Non-null assertion
    "document.getElementById('x')!.click();",
    // Conditional types
    "type IsString<T> = T extends string ? true : false;",
    // Mapped types
    "type Readonly<T> = { readonly [K in keyof T]: T[K] };",
    // Tuple types
    "type Pair = [string, number];",
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
};

// ── Fuzz tests ────────────────────────────────────────────────────────────

test "fuzz: parse js" {
    try std.testing.fuzz({}, fuzzParseJs, .{ .corpus = js_corpus });
}

fn fuzzParseJs(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var toks = try es.Lexer.tokenizeWithLanguage(alloc, src, .js);
    var tree = try es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .emit_events = true });
    _ = &toks; // keep toks alive for tree's token references
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

    var toks = try es.Lexer.tokenizeWithLanguage(alloc, src, .js);
    var tree = try es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .is_module = true, .emit_events = true });
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

    var toks = try es.Lexer.tokenizeWithLanguage(alloc, src, .ts);
    var tree = try es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .language = .ts, .emit_events = true });
    _ = &toks;
    _ = &tree;
}

test "fuzz: semantic" {
    try std.testing.fuzz({}, fuzzSemantic, .{ .corpus = sem_corpus });
}

fn fuzzSemantic(_: void, smith: *std.testing.Smith) !void {
    var buf: [8192]u8 = undefined;
    const src = fuzzBytes(smith, &buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var toks = try es.Lexer.tokenizeWithLanguage(alloc, src, .js);
    var tree = try es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .emit_events = true });
    _ = &toks; // keep toks alive while tree is in use

    // Only analyze syntactically valid files; parse errors can produce
    // scope-event streams the analyzer is not expected to handle.
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

    var toks = try es.Lexer.tokenizeWithLanguage(alloc, src, .ts);
    var tree = try es.Parser.parseWithOptions(alloc, src, toks.tokens.slice(), .{ .language = .ts, .is_module = true, .emit_events = true });
    _ = &toks;

    if (tree.errors.len > 0) return;

    var sem = es.semantic.SemanticAnalyzer.analyzeWithOptions(alloc, &tree, .{
        .is_module = true,
        .diagnose_redeclare = true,
    }) catch return;
    _ = &sem;
}
