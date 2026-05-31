# es-parser

A fast JavaScript / TypeScript / JSX parser written in Zig.

Recursive-descent parser with a `MultiArrayList`-backed AST, a SIMD/bitmap
lexer, an event-driven semantic layer (scope tree, symbol table, reference
resolution), and a four-tier diagnostic system (error / warning / info / hint).
Extracted from the Ez linter.

## Conformance

| Suite | Result |
|-------|--------|
| [tc39/test262-parser-tests](https://github.com/tc39/test262-parser-tests) | must-parse 3,966 / 3,966 · must-reject 1,389 / 1,389 |
| TypeScript compiler tests (`tests/cases`) | 19,128 / 19,136 |
| Babel parser fixtures — valid | 2,041 / 2,041 |
| Babel parser fixtures — invalid (correctly rejected) | 1,548 / 1,548 |

The remaining TypeScript failures require cross-file type analysis or
transpile-level error recovery, which a single-file parser does not perform.

## Features

- **Languages**: JS, TS, JSX, TSX, `.d.ts` (also `.mjs`, `.cjs`, `.mts`, `.cts`)
- **ES2025**: async/await, generators, optional chaining, nullish coalescing, import attributes, `using` declarations, decorators
- **SIMD lexer**: bitmap-accelerated tokenization
- **Scope analysis**: lexical scopes, symbol table, reference resolution
- **CFG**: control-flow graph for reachability analysis
- **Diagnostics**: four severity tiers (error / warning / info / hint)
- **Error recovery**: produces a usable AST even from broken input

## Requirements

Zig `0.17.0-dev.607+456b2ec07` or later.

## Usage

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .es_parser = .{
        .url = "https://github.com/ericsssan/es-parser/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "es_parser-0.1.0-C15LK7riGQA442nDjkR8yefVUXwbXCVNRJRhYFUGefdp",
    },
},
```

Then in `build.zig` — the dependency is named `es_parser` and exposes a module
called `es-parser`:

```zig
const es_parser = b.dependency("es_parser", .{ .target = target, .optimize = optimize });
my_module.addImport("es_parser", es_parser.module("es-parser"));
```

### Parsing

Parsing is a two-step pipeline: tokenize, then parse the token slice.

```zig
const es = @import("es_parser");

// Lex
var lr = try es.Lexer.tokenize(allocator, source);
defer lr.deinit(allocator);

// Parse — emit_events = true is set automatically by Parser.parse(),
// enabling the fast-path semantic analyzer.
var tree = try es.Parser.parse(allocator, source, lr.tokens.slice());
defer tree.deinit(allocator);

// tree.nodes  — MultiArrayList of AST nodes
// tree.errors — []const Diagnostic; each carries a .severity field
//               (.@"error" / .warning / .info / .hint)
for (tree.errors) |d| {
    if (d.severity == .@"error") std.debug.print("error: {s}\n", .{d.message});
}
```

For TypeScript / JSX or module mode:

```zig
var lr = try es.Lexer.tokenizeWithLanguage(allocator, source, .ts);
defer lr.deinit(allocator);

var tree = try es.Parser.parseWithOptions(allocator, source, lr.tokens.slice(), .{
    .language = .ts,          // .js, .jsx, .ts, .tsx, or .dts
    .is_module = true,        // enable import/export + strict-mode semantics
    .emit_events = true,      // required for semantic analysis
});
defer tree.deinit(allocator);
```

### Semantic analysis

```zig
// analyze() always uses module mode (strict, import/export allowed).
// For script mode use analyzeModule(allocator, &tree, false).
var sem = try es.semantic.SemanticAnalyzer.analyze(allocator, &tree);
defer sem.deinit(allocator);

// sem.scopes      — scope tree (ScopeTree)
// sem.symbols     — symbol table (SymbolTable)
// sem.references  — reference list (ReferenceTable)
// sem.diagnostics — early errors (duplicate bindings, etc.)
```

## Building and testing

```sh
zig build test    # unit + lexer + parser + semantic tests + tc39/test262-parser-tests
```

### Conformance suites

`conformance-parser-tests` runs against the bundled submodule automatically.
The other three suites are large external repos registered as submodules but
not checked out by default — initialize them first, then pass the path:

```sh
# Bundled — no argument needed
zig build conformance-parser-tests

# Full tc39/test262
git submodule update --init tests/conformance/test262
zig build conformance-test262 -- tests/conformance/test262

# Babel parser fixtures
git submodule update --init tests/conformance/babel
zig build conformance-babel -- tests/conformance/babel/packages/babel-parser/test/fixtures

# TypeScript compiler tests
git submodule update --init tests/conformance/typescript
zig build conformance-typescript -- tests/conformance/typescript/tests/cases

# Semantic analysis fixtures (bundled)
zig build conformance-semantic -- tests/fixtures/semantic
```

## Support

If you find es-parser useful, please consider:

- **Starring the repo** — it helps others discover the project and motivates continued development
- **Sponsoring** — if this parser saves you time or powers your tooling, a donation helps me maintain and improve it full time: [GitHub Sponsors](https://github.com/sponsors/ericsssan)

Your support means a lot and directly enables better conformance, performance, and new features. Thank you!

## License

MIT
