# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
