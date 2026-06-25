const std = @import("std");
const testing = std.testing;
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Token = es_parser.token;
const Tag = Token.Tag;

fn expectTokens(source: []const u8, expected: []const Tag) !void {
    var result = try Lexer.tokenizeWithLanguage(testing.allocator, source, .js);
    defer result.deinit(testing.allocator);
    const tags = result.tokens.items(.tag);
    // tags includes the final EOF token; check expected tags then EOF
    for (expected, 0..) |exp_tag, i| {
        try testing.expectEqual(exp_tag, tags[i]);
    }
    try testing.expectEqual(Tag.eof, tags[expected.len]);
}

fn expectSingleToken(source: []const u8, expected_tag: Tag) !void {
    var result = try Lexer.tokenizeWithLanguage(testing.allocator, source, .js);
    defer result.deinit(testing.allocator);
    const tags = result.tokens.items(.tag);
    try testing.expectEqual(expected_tag, tags[0]);
}

// ── Keywords ─────────────────────────────────────────────

test "keywords" {
    try expectSingleToken("break", .kw_break);
    try expectSingleToken("case", .kw_case);
    try expectSingleToken("catch", .kw_catch);
    try expectSingleToken("continue", .kw_continue);
    try expectSingleToken("debugger", .kw_debugger);
    try expectSingleToken("default", .kw_default);
    try expectSingleToken("delete", .kw_delete);
    try expectSingleToken("do", .kw_do);
    try expectSingleToken("else", .kw_else);
    try expectSingleToken("export", .kw_export);
    try expectSingleToken("extends", .kw_extends);
    try expectSingleToken("finally", .kw_finally);
    try expectSingleToken("for", .kw_for);
    try expectSingleToken("function", .kw_function);
    try expectSingleToken("if", .kw_if);
    try expectSingleToken("import", .kw_import);
    try expectSingleToken("in", .kw_in);
    try expectSingleToken("instanceof", .kw_instanceof);
    try expectSingleToken("new", .kw_new);
    try expectSingleToken("return", .kw_return);
    try expectSingleToken("super", .kw_super);
    try expectSingleToken("switch", .kw_switch);
    try expectSingleToken("this", .kw_this);
    try expectSingleToken("throw", .kw_throw);
    try expectSingleToken("try", .kw_try);
    try expectSingleToken("typeof", .kw_typeof);
    try expectSingleToken("var", .kw_var);
    try expectSingleToken("void", .kw_void);
    try expectSingleToken("while", .kw_while);
    try expectSingleToken("with", .kw_with);
    try expectSingleToken("yield", .kw_yield);
    try expectSingleToken("let", .kw_let);
    try expectSingleToken("const", .kw_const);
    try expectSingleToken("class", .kw_class);
    try expectSingleToken("async", .kw_async);
    try expectSingleToken("await", .kw_await);
    try expectSingleToken("null", .kw_null);
    try expectSingleToken("true", .kw_true);
    try expectSingleToken("false", .kw_false);
}

// ── Identifiers ─────────────────────────────────────────

test "identifiers" {
    try expectSingleToken("foo", .identifier);
    try expectSingleToken("_bar", .identifier);
    try expectSingleToken("$baz", .identifier);
    try expectSingleToken("camelCase", .identifier);
    try expectSingleToken("snake_case", .identifier);
    try expectSingleToken("PascalCase", .identifier);
    try expectSingleToken("_", .identifier);
    try expectSingleToken("$", .identifier);
    try expectSingleToken("$$", .identifier);
    try expectSingleToken("__proto__", .identifier);
}

// ── Number Literals ─────────────────────────────────────

test "decimal numbers" {
    try expectSingleToken("0", .number_literal);
    try expectSingleToken("42", .number_literal);
    try expectSingleToken("3.14", .number_literal);
    try expectSingleToken("1e10", .number_literal);
    try expectSingleToken("1.5e-3", .number_literal);
    try expectSingleToken(".5", .number_literal);
}

test "hex numbers" {
    try expectSingleToken("0xFF", .number_literal);
    try expectSingleToken("0XAB", .number_literal);
    try expectSingleToken("0x0", .number_literal);
}

test "octal numbers" {
    try expectSingleToken("0o77", .number_literal);
    try expectSingleToken("0O10", .number_literal);
}

test "binary numbers" {
    try expectSingleToken("0b1010", .number_literal);
    try expectSingleToken("0B0001", .number_literal);
}

test "bigint" {
    try expectSingleToken("42n", .bigint_literal);
    try expectSingleToken("0xFFn", .bigint_literal);
    try expectSingleToken("0o77n", .bigint_literal);
    try expectSingleToken("0b1010n", .bigint_literal);
}

test "numeric separators" {
    try expectSingleToken("1_000_000", .number_literal);
    try expectSingleToken("0xFF_FF", .number_literal);
    try expectSingleToken("0b1010_0101", .number_literal);
}

// ── String Literals ─────────────────────────────────────

test "string literals" {
    try expectSingleToken("\"hello\"", .string_literal);
    try expectSingleToken("'world'", .string_literal);
    try expectSingleToken("\"\"", .string_literal);
    try expectSingleToken("''", .string_literal);
}

test "string escape sequences" {
    try expectSingleToken("\"hello\\nworld\"", .string_literal);
    try expectSingleToken("\"tab\\there\"", .string_literal);
    try expectSingleToken("\"quote\\\"inside\"", .string_literal);
    try expectSingleToken("'it\\'s'", .string_literal);
    try expectSingleToken("\"\\u0041\"", .string_literal);
    try expectSingleToken("\"\\u{1F600}\"", .string_literal);
}

// ── Template Literals ───────────────────────────────────

test "simple template" {
    try expectSingleToken("`hello`", .template_no_sub);
}

test "template with expression" {
    try expectTokens("`hello ${x}`", &.{ .template_head, .identifier, .template_tail });
}

test "deeply nested template literals lex correctly past the inline brace cap (#19)" {
    // 17 levels of `${ … }` — one past the lexer's inline [16] brace-depth fast
    // path. Pre-fix, tmpl_depth stopped incrementing at 16, so the brace tracking
    // desynced and the closing `}`s of deeper templates mis-lexed as r_brace,
    // producing spurious parse errors on valid ECMAScript. The fix spills the
    // brace buffer to the heap past the inline cap; the token stream must stay
    // exactly N template_head / identifier / N template_tail at any depth.
    const depth = 17;
    const alloc = testing.allocator;
    var src: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    defer src.deinit(alloc);
    var expected: std.ArrayListUnmanaged(Tag) = .{ .items = &.{}, .capacity = 0 };
    defer expected.deinit(alloc);

    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try src.appendSlice(alloc, "`${");
        try expected.append(alloc, .template_head);
    }
    try src.append(alloc, 'x');
    try expected.append(alloc, .identifier);
    i = 0;
    while (i < depth) : (i += 1) {
        try src.appendSlice(alloc, "}`");
        try expected.append(alloc, .template_tail);
    }

    var result = try Lexer.tokenizeWithLanguage(alloc, src.items, .js);
    defer result.deinit(alloc);
    const tags = result.tokens.items(.tag);
    for (expected.items, 0..) |exp, k| try testing.expectEqual(exp, tags[k]);
    try testing.expectEqual(Tag.eof, tags[expected.items.len]);
}

// ── Operators ───────────────────────────────────────────

test "arithmetic operators" {
    try expectSingleToken("+", .plus);
    try expectSingleToken("-", .minus);
    try expectSingleToken("*", .asterisk);
    // '/' at statement start is context-sensitive: test it after an expression
    try expectTokens("x / y", &.{ .identifier, .slash, .identifier });
    try expectSingleToken("%", .percent);
    try expectTokens("**", &.{.asterisk_asterisk});
}

test "comparison operators" {
    try expectTokens("==", &.{.equal_equal});
    try expectTokens("!=", &.{.bang_equal});
    try expectTokens("===", &.{.equal_equal_equal});
    try expectTokens("!==", &.{.bang_equal_equal});
    try expectSingleToken("<", .less_than);
    try expectSingleToken(">", .greater_than);
    try expectTokens("<=", &.{.less_equal});
    try expectTokens(">=", &.{.greater_equal});
}

test "logical operators" {
    try expectTokens("&&", &.{.ampersand_ampersand});
    try expectTokens("||", &.{.pipe_pipe});
    try expectTokens("??", &.{.question_question});
}

test "assignment operators" {
    try expectSingleToken("=", .equal);
    try expectTokens("+=", &.{.plus_equal});
    try expectTokens("-=", &.{.minus_equal});
    try expectTokens("*=", &.{.asterisk_equal});
    // '/=' at statement start is context-sensitive: test it after an expression
    try expectTokens("x /= y", &.{ .identifier, .slash_equal, .identifier });
    try expectTokens("%=", &.{.percent_equal});
    try expectTokens("**=", &.{.asterisk_asterisk_equal});
    try expectTokens("&&=", &.{.ampersand_ampersand_equal});
    try expectTokens("||=", &.{.pipe_pipe_equal});
    try expectTokens("??=", &.{.question_question_equal});
}

test "shift operators" {
    try expectTokens("<<", &.{.less_less});
    try expectTokens(">>", &.{.greater_greater});
    try expectTokens(">>>", &.{.greater_greater_greater});
}

test "update operators" {
    try expectTokens("++", &.{.plus_plus});
    try expectTokens("--", &.{.minus_minus});
}

// ── Punctuation ─────────────────────────────────────────

test "punctuation" {
    try expectSingleToken("(", .l_paren);
    try expectSingleToken(")", .r_paren);
    try expectSingleToken("{", .l_brace);
    try expectSingleToken("}", .r_brace);
    try expectSingleToken("[", .l_bracket);
    try expectSingleToken("]", .r_bracket);
    try expectSingleToken(";", .semicolon);
    try expectSingleToken(",", .comma);
    try expectSingleToken(".", .dot);
    try expectSingleToken("?", .question);
    try expectSingleToken(":", .colon);
    try expectSingleToken("#", .hash);
}

test "multi-char punctuation" {
    try expectTokens("...", &.{.ellipsis});
    try expectTokens("=>", &.{.arrow});
    try expectTokens("?.", &.{.question_dot});
}

// ── Comments ────────────────────────────────────────────

test "line comments are skipped" {
    try expectTokens("a // comment\nb", &.{ .identifier, .identifier });
}

test "block comments are skipped" {
    try expectTokens("a /* comment */ b", &.{ .identifier, .identifier });
}

test "multi-line block comment" {
    try expectTokens("a /* line1\nline2 */ b", &.{ .identifier, .identifier });
}

// ── Whitespace ──────────────────────────────────────────

test "whitespace is skipped" {
    try expectTokens("  a   b  ", &.{ .identifier, .identifier });
    try expectTokens("\ta\t\tb", &.{ .identifier, .identifier });
    try expectTokens("a\nb", &.{ .identifier, .identifier });
    try expectTokens("a\r\nb", &.{ .identifier, .identifier });
}

// ── Full statements ─────────────────────────────────────

test "variable declaration" {
    try expectTokens("let x = 42;", &.{
        .kw_let,
        .identifier,
        .equal,
        .number_literal,
        .semicolon,
    });
}

test "function declaration tokens" {
    try expectTokens("function foo(a, b) { return a + b; }", &.{
        .kw_function,
        .identifier,
        .l_paren,
        .identifier,
        .comma,
        .identifier,
        .r_paren,
        .l_brace,
        .kw_return,
        .identifier,
        .plus,
        .identifier,
        .semicolon,
        .r_brace,
    });
}

test "arrow function tokens" {
    try expectTokens("(a, b) => a + b", &.{
        .l_paren,
        .identifier,
        .comma,
        .identifier,
        .r_paren,
        .arrow,
        .identifier,
        .plus,
        .identifier,
    });
}

test "optional chaining tokens" {
    try expectTokens("a?.b?.[c]?.()", &.{
        .identifier,
        .question_dot,
        .identifier,
        .question_dot,
        .l_bracket,
        .identifier,
        .r_bracket,
        .question_dot,
        .l_paren,
        .r_paren,
    });
}

// ── EOF ─────────────────────────────────────────────────

test "empty source" {
    try expectTokens("", &.{});
}

test "only whitespace" {
    try expectTokens("   \n\t  ", &.{});
}

test "only comments" {
    try expectTokens("// comment\n/* block */", &.{});
}

// ── JSX text tokens (#61) ────────────────────────────────

/// Collect the [start, end) byte ranges of every jsx_text token, in order.
fn expectJsxTextLang(src: []const u8, lang: Token.Language, expected: []const [2]u32) !void {
    var result = try Lexer.tokenizeWithLanguage(testing.allocator, src, lang);
    defer result.deinit(testing.allocator);
    const tags = result.tokens.items(.tag);
    const starts = result.tokens.items(.start);
    const lens = result.tokens.items(.len);
    var got: [16][2]u32 = undefined;
    var k: usize = 0;
    var i: usize = 0;
    while (i < result.tokens.len) : (i += 1) {
        if (tags[i] == .jsx_text) {
            got[k] = .{ starts[i], starts[i] + lens[i] };
            k += 1;
        }
    }
    try testing.expectEqual(expected.len, k);
    for (expected, got[0..k]) |e, g| {
        try testing.expectEqual(e[0], g[0]);
        try testing.expectEqual(e[1], g[1]);
    }
}

fn expectJsxText(src: []const u8, expected: []const [2]u32) !void {
    try expectJsxTextLang(src, .jsx, expected);
}

test "JSX text child is one jsx_text token spanning whitespace (#61)" {
    // The issue's repro: text before/after the expression container are each ONE
    // jsx_text token including the leading "\n   " — matching espree/@typescript-eslint.
    try expectJsxText("<div>\n   unrelated{\n        foo\n    }\n</div>", &.{ .{ 5, 18 }, .{ 37, 38 } });
    // Multi-word text is one token, not several identifiers.
    try expectJsxText("<div>hello world</div>", &.{.{ 5, 16 }});
    // Nested elements: only the innermost text is jsx_text; adjacent tags have none.
    try expectJsxText("<a><b>x</b></a>", &.{.{ 6, 7 }});
    // Text inside a nested element within an expression container.
    try expectJsxText("<div>{cond && <span>hi</span>}</div>", &.{.{ 20, 22 }});
    // Fragment body.
    try expectJsxText("<>frag</>", &.{.{ 2, 6 }});
    // A self-closing element opens no body — the surrounding gaps are not jsx_text.
    try expectJsxText("<div><br/></div>", &.{});
}

test "JSX text tokens are gated to plain JSX, not TSX / non-JSX (#61)" {
    // Plain JS: `<` / `>` are operators, never JSX tags.
    try expectJsxTextLang("a < b > c", .js, &.{});
    // TSX keeps the prior token stream (the JSX-vs-generic ambiguity needs the
    // parser); a generic arrow must NOT be misread as a JSX element opening a body.
    try expectJsxTextLang("const f = <T,>() => 1;", .tsx, &.{});
    try expectJsxTextLang("<div>hi</div>", .tsx, &.{});
}
