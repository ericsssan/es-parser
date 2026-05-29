# es-parser

A fast JavaScript and TypeScript parser written in Zig.

Includes a lexer, recursive-descent parser, and semantic analyzer (scope tree, symbol table, reference tracking). Extracted from the Ez linter.

## Conformance

| Suite | Must-parse | Must-reject |
|-------|-----------|-------------|
| [tc39/test262-parser-tests](https://github.com/tc39/test262-parser-tests) | **3,966 / 3,966 (100%)** | **1,389 / 1,389 (100%)** |
| tc39/test262 (full) | 48,491 / 48,495 (99.99%) | 4,301 / 4,595 (93.6%) |
| Babel parser fixtures | 1,923 / 1,931 (99.6%) | 1,453 / 1,550 (93.7%) |
| TypeScript conformance | 4,951 / 4,968 (99.7%) | 839 / 903 (92.9%) |

## Features

- **Languages**: JS, TS, JSX, TSX, `.d.ts`
- **ES2025**: async/await, generators, optional chaining, nullish coalescing, import attributes, `using` declarations, decorators
- **SIMD lexer**: bitmap-accelerated tokenization
- **Scope analysis**: lexical scopes, symbol table, reference resolution
- **CFG**: control-flow graph for reachability analysis
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

Then in `build.zig`:

```zig
const es_parser = b.dependency("es_parser", .{ .target = target, .optimize = optimize });
my_module.addImport("es_parser", es_parser.module("es-parser"));
```

### Parsing

```zig
const es = @import("es_parser");

// Lex
var lr = try es.Lexer.tokenize(allocator, source);
defer lr.deinit(allocator);

// Parse
var tree = try es.Parser.parse(allocator, source, lr.tokens.slice());
defer tree.deinit(allocator);

// tree.errors.len == 0 means clean parse
// tree.nodes — MultiArrayList of AST nodes
```

For TypeScript or module mode:

```zig
var lr = try es.Lexer.tokenizeWithLanguage(allocator, source, .ts);
defer lr.deinit(allocator);

var tree = try es.Parser.parseWithOptions(allocator, source, lr.tokens.slice(), .{
    .language = .ts,
    .is_module = true,
});
defer tree.deinit(allocator);
```

### Semantic analysis

```zig
var sem = try es.semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, is_module);
defer sem.deinit(allocator);

// sem.scopes   — scope tree
// sem.symbols  — symbol table
// sem.references — reference list
// sem.diagnostics — early errors (duplicate bindings, etc.)
```

## Building

```sh
zig build              # build
zig build test         # unit tests + tc39/test262-parser-tests conformance
```

### Optional conformance suites

These require the fixture repos (large — fetch separately):

```sh
# Full tc39/test262
git submodule add https://github.com/tc39/test262.git tests/conformance/test262
zig build conformance-test262 -- tests/conformance/test262/test

# Babel parser fixtures
git submodule add https://github.com/babel/babel.git tests/conformance/babel
zig build conformance-babel -- tests/conformance/babel/packages/babel-parser/test/fixtures

# TypeScript conformance
git submodule add https://github.com/microsoft/TypeScript.git tests/conformance/typescript
zig build conformance-typescript -- tests/conformance/typescript/tests/cases/conformance
```

## License

MIT
