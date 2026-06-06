# es-parser

A fast JavaScript / TypeScript / JSX parser written in Zig.

Recursive-descent parser with a `MultiArrayList`-backed AST, a single-pass
scalar lexer (SIMD ASCII-identifier fast path), an event-driven semantic layer
(scope tree, symbol table, reference resolution), and a four-tier diagnostic
system (error / warning / info / hint). Extracted from the Ez linter.

## Conformance

| Suite | Result |
|-------|--------|
| [tc39/test262-parser-tests](https://github.com/tc39/test262-parser-tests) | must-parse 3,966 / 3,966 · must-reject 1,389 / 1,389 |
| TypeScript compiler tests (`tests/cases`) | 19,120 / 19,136 |
| Babel parser fixtures — valid | 1,928 / 1,928 |
| Babel parser fixtures — invalid (correctly rejected) | 1,548 / 1,548 |

The remaining TypeScript failures require cross-file type analysis or
transpile-level error recovery, which a single-file parser does not perform.

Babel numbers are over the supported-feature subset: ~1,740 of the 5,216 parser
fixtures are skipped — Flow type syntax, the pipeline operator, and assorted
Stage-x proposals (record/tuple, module blocks, do-expressions, …) — none of
which es-parser targets. TypeScript-specific fixtures are skipped here too;
they run under the TypeScript suite instead.

## Features

- **Languages**: JS, TS, JSX, TSX, `.d.ts` (also `.mjs`, `.cjs`, `.mts`, `.cts`)
- **ES2025**: async/await, generators, optional chaining, nullish coalescing, import attributes, `using` declarations, decorators (standard syntax)
- **Single-pass lexer**: SIMD-accelerated scalar tokenization
- **Scope analysis**: lexical scopes, symbol table, reference resolution
- **CFG**: control-flow graph for reachability analysis
- **Diagnostics**: four severity tiers (error / warning / info / hint)
- **Error recovery**: produces a usable AST even from broken input

## Requirements

Zig `0.17.0-dev.607+456b2ec07` or later.

## Usage

Add es-parser to your `build.zig.zon` with `zig fetch`, which records the URL and
hash for you:

```sh
# Pin to a release tag (recommended):
zig fetch --save https://github.com/ericsssan/es-parser/archive/refs/tags/v0.2.5.tar.gz

# …or track the main branch:
zig fetch --save git+https://github.com/ericsssan/es-parser
```

This writes a `.es_parser` dependency (URL + hash) into your `build.zig.zon`.

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
// sem.diagnostics — semantic diagnostics. Duplicate lexical-binding early
//                   errors are opt-in: analyzeWithOptions(allocator, &tree,
//                   .{ .is_module = true, .diagnose_redeclare = true }).
```

## Building and testing

```sh
zig build test    # unit + lexer + parser + semantic tests + tc39/test262-parser-tests
```

### Conformance suites

Each step runs a built-in default fixture path, so no arguments are needed.
`conformance-parser-tests` uses a bundled submodule; the others are large
external repos registered as submodules and not checked out by default —
initialize the submodule first, then run the step:

```sh
# Bundled — no submodule needed
zig build conformance-parser-tests

# Full tc39/test262
git submodule update --init tests/conformance/test262
zig build conformance-test262

# Babel parser fixtures
git submodule update --init tests/conformance/babel
zig build conformance-babel

# TypeScript compiler tests (also drives conformance-semantic below)
git submodule update --init tests/conformance/typescript
zig build conformance-typescript

# Semantic-analysis robustness sweep: runs the full parse + scope/symbol/
# reference pipeline over the ~19k-file TypeScript corpus to catch analyzer
# crashes. Reports structural tallies (scopes/symbols/refs/diagnostics) — it is
# a robustness sweep, not a correctness gate. Needs the typescript submodule.
zig build conformance-semantic
```

## Support

If you find es-parser useful, please consider:

- **Starring the repo** — it helps others discover the project and motivates continued development
- **Sponsoring** — if this parser saves you time or powers your tooling, a donation helps me maintain and improve it full time: [GitHub Sponsors](https://github.com/sponsors/ericsssan)

Your support means a lot and directly enables better conformance, performance, and new features. Thank you!

## License

MIT
