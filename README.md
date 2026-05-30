# es-parser

A fast JavaScript / TypeScript / JSX parser written in Zig.

A recursive-descent parser with a `MultiArrayList`-backed AST, a SIMD/bitmap
lexer, an event-driven semantic layer (scope tree, symbol table, reference
resolution), and a four-tier diagnostic system (error / warning / info / hint).
Extracted from the Ez linter.

## Conformance

Verified against external corpora (run via the steps under [Building](#building)):

| Suite | Result |
|-------|--------|
| [tc39/test262-parser-tests](https://github.com/tc39/test262-parser-tests) | must-parse 3,966 / 3,966 · must-reject 1,389 / 1,389 |
| TypeScript compiler tests (`tests/cases`) | 19,128 / 19,136 |
| Babel parser fixtures — valid | 2,041 / 2,041 |
| Babel parser fixtures — invalid (correctly rejected) | 1,548 / 1,548 |

The remaining TypeScript failures require cross-file type analysis or
transpile-level error recovery, which a single-file parser does not perform.

## Features

- **Languages**: JS, TS, JSX, TSX, `.d.ts`
- **ES2025**: async/await, generators, optional chaining, nullish coalescing, import attributes, `using` declarations, decorators
- **SIMD lexer**: bitmap-accelerated tokenization
- **Scope analysis**: lexical scopes, symbol table, reference resolution
- **CFG**: control-flow graph for reachability analysis
- **Diagnostics**: four severity tiers (error / warning / info / hint)
- **Error recovery**: produces a usable AST even from broken input

## Requirements

Zig `0.17.0-dev.305+bdfbf432d` or later.

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

Then in `build.zig` — the dependency is named `es_parser`, and it exposes a module
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

// Parse
var tree = try es.Parser.parse(allocator, source, lr.tokens.slice());
defer tree.deinit(allocator);

// tree.nodes  — MultiArrayList of AST nodes
// tree.errors — diagnostics; each carries a `.severity`
//               (.@"error" / .warning / .info / .hint).
// A clean parse has no `.@"error"`-severity entries.
for (tree.errors) |d| {
    if (d.severity == .@"error") std.debug.print("error: {s}\n", .{d.message});
}
```

For TypeScript / JSX or module mode:

```zig
var lr = try es.Lexer.tokenizeWithLanguage(allocator, source, .ts);
defer lr.deinit(allocator);

var tree = try es.Parser.parseWithOptions(allocator, source, lr.tokens.slice(), .{
    .language = .ts,     // .js, .jsx, .ts, or .tsx
    .is_module = true,   // enable import/export + strict-mode semantics
});
defer tree.deinit(allocator);
```

### Semantic analysis

```zig
var sem = try es.semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, is_module);
defer sem.deinit(allocator);

// sem.scopes      — scope tree
// sem.symbols     — symbol table
// sem.references  — reference list
// sem.diagnostics — early errors (duplicate bindings, etc.)
```

## Building

```sh
zig build              # build
zig build test         # unit + lexer + parser + semantic tests + test262-parser-tests
```

### Conformance suites

Each runner takes its corpus directory as an argument; the fixture repos are large
and fetched separately:

```sh
# tc39/test262-parser-tests
zig build conformance-parser-tests -- tests/conformance/test262-parser-tests

# Full tc39/test262
git submodule add https://github.com/tc39/test262.git tests/conformance/test262
zig build conformance-test262 -- tests/conformance/test262/test

# Babel parser fixtures
git submodule add https://github.com/babel/babel.git tests/conformance/babel
zig build conformance-babel -- tests/conformance/babel/packages/babel-parser/test/fixtures

# TypeScript compiler tests
git submodule add https://github.com/microsoft/TypeScript.git tests/conformance/typescript
zig build conformance-typescript -- tests/conformance/typescript/tests/cases
```

## Support

If you find es-parser useful, please consider:

- **Starring the repo** — it helps others discover the project and motivates continued development
- **Sponsoring** — if this parser saves you time or powers your tooling, a donation helps me maintain and improve it full time: [GitHub Sponsors](https://github.com/sponsors/ericsssan)

Your support means a lot and directly enables better conformance, performance, and new features. Thank you!

## License

MIT
