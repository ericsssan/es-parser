# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0]

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

### Notes

- The token stream (tags, offsets, lengths, `has_newline_before`,
  `has_unicode_escape`) is byte-for-byte identical to 0.1.x across the
  conformance corpus; parser and semantic-analysis behavior is unchanged. Line
  starts produced by `span.computeLineStarts` match the previous values except
  for a single malformed-input edge case where the new (single-source-scan)
  result is the more correct one.
