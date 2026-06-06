# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.3]

A TypeScript error-recovery and correctness release. No public API changes.

### Fixed

- **TS error-recovery: compound assignment to object/array literal** (`({} *= {})`).
  Previously produced an `error_node`; now emits a diagnostic and recovers in
  TypeScript mode. Hard error preserved in JavaScript mode.
- **TS error-recovery: shorthand property initializer in non-destructuring context**
  (`const x = { y = 1 }`). Previously produced an `error_node`; now emits a
  diagnostic and recovers in TypeScript mode. Hard error preserved in JavaScript mode.
- **TS index signature without value type** (`{ [key: string]; }`). Now emits a
  diagnostic instead of a hard parse error, preserving the `TSIndexSignature` node.
- **TS empty index signature** (`{ []; }`). Now routed to error-recovery path,
  producing a `TSIndexSignature` node with a diagnostic instead of an `error_node`.
- **Ambient module declaration without body or semicolon** (`declare module '*.svg'`).
  The no-semicolon, no-braces form common in `.d.ts` wildcard modules is now accepted.
- **Regex v-flag `\q{...}` with nested `\u{...}` escapes**
  (e.g. `/[\q{\u{1f476}\u{1f3fb}}]/v`). The inner `}` from `\u{...}` no longer
  prematurely terminates the `\q{...}` skip, fixing a spurious class-syntax error.

## [0.2.2]

A performance, correctness, and semantic-analysis release.

### Fixed

- **`new Foo<T>(args)` parsed incorrectly.** TypeScript instantiation expressions
  inside `new` were not consuming the type arguments before checking for an argument
  list, producing `CallExpression(NewExpression(TSInstantiationExpression), args)`
  instead of `NewExpression(TSInstantiationExpression, args)`.
- **Memory leaks on error paths.** Two `toOwnedSlice` struct-literal sites in
  `scalar_lexer.zig` and `event_resolver.zig` leaked their already-allocated slices
  when a subsequent allocation failed. Fixed by binding each slice before constructing
  the return value with `errdefer`.
- **Event-resolver streaming spin-wait hang** on parse-error files.

### Performance

- **`nearestVarScope` / `outerVarScope` are now O(1).** Each scope pre-computes its
  nearest enclosing var-scope at creation time, replacing two depth-first while-loop
  traversals with single array reads.
- **`hoist_map` initial capacity doubled** (`est_syms / 4` → `/ 2`), covering the
  common case without an extra grow+rehash. Measured +3% on the scope-analysis pass
  over large TypeScript files.

### Changed

- **Lean parser port (increment 1).** Block-scope lexical-vs-var and duplicate
  function-declaration redeclaration checks moved from the parser to the semantic
  analyzer, measured at ~9% win on modern JS. The `diagnose_redeclare` option now
  covers import bindings, catch parameters, and catch-scope function declarations.
- **Parent map built in semantic, not parse.** Removes the byte-span-AST overhead
  from the parse phase; parents are derived on demand by the semantic pass.
- **Async-arrow parameters now have their own scope.** Fixes missing declares for
  async arrow functions.

## [0.2.1]

A robustness, tooling, and newer-Zig-compatibility release. No public API
changes (`Ast` gains an additive `is_ts` field).

### Fixed

- **Parser memory-exhaustion on malformed input (DoS-class).** The class-body
  loop for class *declarations* recovered from a parse error without forcing
  token progress, so input where recovery consumed nothing — e.g. a git conflict
  marker (`<<<<<<<`) after a valid member — spun, appending error nodes until
  OutOfMemory. A 97-byte file could exhaust the parser. It now guarantees
  one-token progress, matching the class-expression loop.
- **Newer Zig support.** Abstracted the `@typeInfo(T).@"struct"/.@"enum".fields`
  API change (split into `field_names`/`field_types`/`field_values`) behind a
  small compat shim, so the codebase builds across `0.17.0-dev.305` through
  `dev.657`. Also restored the `@hasField` guard around `b.args` in `build.zig`.

### Changed

- **`diagnose_redeclare` is now JavaScript-only.** It models a JS duplicate-
  binding early error; TypeScript declaration merging (function overloads,
  namespace/interface/class merges) makes the rule inapplicable, so it is skipped
  for TS. (Default-off, so most consumers are unaffected.) TypeScript function
  overloads are no longer flagged as redeclarations.
- **Conformance tooling.** Each `conformance-*` build step now runs a correct
  default fixture path with no arguments (the current Zig build system drops
  trailing `--` args). `conformance-semantic` is a CI **crash gate**: it runs the
  full parse + scope/symbol/reference/CFG/redeclare pipeline over the ~19k-file
  TypeScript corpus and fails the build if any file crashes the pipeline.
- CI is pinned to the declared `minimum_zig_version` (`dev.607`); the Nightly
  workflow tracks `master` as an early-warning canary.

## [0.2.0]

Headline: the tokenizer is rewritten as a single-pass scalar lexer, and
`line_starts` is now built lazily (a breaking API change).

### Performance

- **New single-pass scalar lexer, replacing the two-phase bitmap lexer.** The
  old lexer built character-class bitmaps in one pass and tokenized in a second;
  the new one tokenizes in a single pass with a SIMD ASCII-identifier fast path
  (16-byte vector scan) and the Unicode/escape-correctness machinery moved off
  the hot path. It is a drop-in producing the same token stream and is now the
  default and sole tokenizer — substantially faster, most of all on
  declaration-heavy TypeScript (`.d.ts`). The legacy bitmap lexer is removed.

### Breaking

- **`line_starts` is no longer produced by the lexer.** It is now built lazily
  by the location layer, since it is only ever needed to map a byte offset to a
  line/column for diagnostics — a file that reports no diagnostics never builds
  it. Migration:
  - `lexer_helpers.TokenizeResult` no longer has a `line_starts` field, and
    `TokenizeOptions` no longer has the `line_starts` sink. Code that read
    `result.line_starts` should construct a `span.LineIndex` from the source
    instead and call `.locate(offset)` (or `.ensure()` for the raw `[]const u32`):

    ```zig
    var idx = span.LineIndex.init(allocator, source);
    defer idx.deinit();
    const loc = idx.locate(span_start); // Location{ line, column, ... }
    ```

  - `computeLineStarts` moved from `scalar_lexer` to `span`
    (`span.computeLineStarts(allocator, source)`).
  - `lexer_helpers.blockCommentEnd` dropped its `ls`/`la` parameters; it now
    takes `(src, open)` and reports only `has_nl` (used for the token
    `has_newline_before` flag).

  The diagnostic formatters in `diagnostic.zig` still accept a `line_starts`
  slice, so callers building one via `span.LineIndex` are unaffected there.

### Changed

- Rich-fields tokenization (`tokenizeScalarFull`) is faster now that it no longer
  records line starts: it produces tokens and comment trivia only. The
  parse-only path was already line-starts-free and is unchanged.

### Added

- **Duplicate lexical binding early-errors** (opt-in
  `SemanticAnalyzer.Options.diagnose_redeclare`, default off): within a scope a
  `let`/`const`/`class` — and a module top-level `function` — may not coexist
  with another binding of the same name. `var` and Script-level functions remain
  redeclarable; Annex B B.3.3 functions are exempt.

### Fixed

- Flag-less regex `\u{…}` (e.g. `/\u{41}/`) now parses in JavaScript under Annex
  B (identity escape + quantifier); TypeScript still reports TS1538.
- Annex B B.3.3: a sloppy function in an `if`/label body no longer falsely
  conflicts with an outer lexical binding.
- A statement-level decorator on a non-class declaration is now rejected in
  TypeScript (TS1146).
- tc39/test262 is fully conformant on both must-parse and must-reject; Babel and
  TypeScript parser-conformance suites improved.

### Notes

- The token stream (tags, offsets, lengths, `has_newline_before`,
  `has_unicode_escape`) is byte-for-byte identical to 0.1.x across the
  conformance corpus; parser and semantic-analysis behavior is unchanged. Line
  starts produced by `span.computeLineStarts` match the previous values except
  for a single malformed-input edge case where the new (single-source-scan)
  result is the more correct one.
