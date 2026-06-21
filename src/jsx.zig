// ── src/parser/jsx.zig ──────────────────────────────────────────────
// JSX parser module for Ez.
//
// Parses JSX elements, fragments, attributes, and expression containers
// according to the JSX specification.  All public functions take a
// `*Parser` and return a `NodeIndex` (or `SubRange`) wrapped in an
// error union.
//
// Follows the same structural conventions as expressions.zig.
// ────────────────────────────────────────────────────────────────────

const ast = @import("ast.zig");
const NodeIndex = ast.NodeIndex;
const SubRange = ast.SubRange;

const parser_mod = @import("parser.zig");
pub const Parser = parser_mod.Parser;
const Error = parser_mod.Error;

// =====================================================================
// Public entry points
// =====================================================================

/// Entry point for JSX parsing.  Called when the parser sees `<` in
/// expression position and the language mode is JSX or TSX.
///
/// The `<` (less_than) token has already been consumed by the caller.
///
/// Dispatches to fragment parsing (`<>`) or element parsing (`<tag`).
pub fn parseJsxElement(p: *Parser) Error!NodeIndex {
    try p.enterRecursion();
    defer p.leaveRecursion();
    // Fragment: `<>children</>`
    if (p.peek() == .greater_than) {
        return parseJsxFragment(p);
    }

    // Stray closing tag `</...>` in expression position (e.g. error recovery for
    // `<div></div><div></div>` where the second closing tag ends up as a binary-expression RHS).
    // Consume the entire closing tag silently and return an error node to allow recovery.
    // parseJsxChildren never calls us with '/' as the first token (it breaks on '</' itself),
    // so this branch only fires when we were called from primary-expression position.
    if (p.peek() == .slash) {
        _ = p.advance(); // consume '/'
        // Consume the tag name (may be dotted like foo.Bar).
        while (p.peek() == .identifier or p.peek().isKeyword() or p.peek() == .dot or p.peek() == .colon) {
            _ = p.advance();
        }
        if (p.peek() == .greater_than) _ = p.advance(); // consume '>'
        return p.makeErrorNode();
    }

    // Regular element or self-closing element.
    const opening = try parseJsxOpeningElement(p);

    // If the opening element was self-closing (`<tag />`), we are done.
    const opening_idx = opening.toInt();
    if (p.nodeTag(opening_idx) == .jsx_self_closing) {
        return opening;
    }

    // Parse children between opening and closing tags.
    const children = try parseJsxChildren(p);

    // Parse the closing element `</tag>`.
    const closing = try parseJsxClosingElement(p);

    // Validate that the closing tag name matches the opening name.
    // Babel rejects `<Foo></Bar>` with a name-mismatch error.
    if (!jsxNameMatches(p, opening, closing)) {
        try p.emitError("Expected corresponding JSX closing tag");
    }

    // Build the full jsx_element node.
    const extra = try p.addExtra(ast.JsxElementData, .{
        .opening = opening,
        .children_start = children.start,
        .children_end = children.end,
        .closing = closing,
    });
    return p.addNode(.{
        .tag = .jsx_element,
        .main_token = p.node_main_token_ptr[opening_idx],
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
    });
}

// =====================================================================
// Opening element:  <tag attrs>  or  <tag attrs />
// =====================================================================

/// Parse the opening part of a JSX element.  The `<` has already been
/// consumed by the caller.
///
/// Returns a node with tag `jsx_opening_element` (if `>` terminates)
/// or `jsx_self_closing` (if `/>` terminates).
fn parseJsxOpeningElement(p: *Parser) Error!NodeIndex {
    const name_tok: u32 = p.tokIdx();

    // Parse element name — identifier or dotted name like Foo.Bar.Baz.
    const name_node = try parseJsxDottedName(p);

    // Emit a read reference for component names (uppercase first letter).
    // Lowercase names are HTML intrinsics; uppercase names are variable references.
    // For member expressions like <Foo.Bar />, only the root <Foo> is a variable.
    try emitJsxComponentRef(p, name_node);

    // TS-only: `<Foo<T> />` — JSX type arguments after the tag name. Speculate
    // so we don't break invalid forms; on failure, restore state and let attribute
    // parsing handle whatever follows.
    if (p.is_ts and p.peek() == .less_than) {
        const saved_tok = p.tok_i;
        const saved_diag = p.diagnostics.items.len;
        const saved_nodes = p.nodes.len;
        const saved_extra = p.extra_data.items.len;
        const typescript = @import("typescript.zig");
        const ok = blk: {
            _ = typescript.parseTypeArguments(p) catch break :blk false;
            break :blk true;
        };
        // After type args, the next token should be `>` (open), `/` (self-close),
        // an attribute name (identifier/keyword), or `{` (spread attribute, e.g.
        // `<Foo<T> {...props} />`). If we land on something unexpected, backtrack.
        if (!ok or (p.peek() != .greater_than and p.peek() != .slash and
                    p.peek() != .l_brace and
                    p.peek() != .identifier and !p.peek().isKeyword()))
        {
            p.tok_i = saved_tok;
            p.diagnostics.shrinkRetainingCapacity(saved_diag);
            p.nodes.len = @intCast(saved_nodes);
            p.extra_data.shrinkRetainingCapacity(saved_extra);
        }
    }

    // Parse attributes until `>` or `/>`.
    const scratch_top = p.scratchLen();

    while (p.peek() != .greater_than and
        p.peek() != .slash and
        p.peek() != .eof)
    {
        const before = p.tok_i;
        const attr = try parseJsxAttribute(p);
        try p.scratchPush(attr);
        // Progress guard: if attribute parsing consumed no tokens (e.g. it hit a
        // token it can't handle and only emitted an error node), force-advance so
        // the loop terminates instead of spinning and exhausting memory.
        if (p.tok_i == before) _ = p.advance();
    }

    const attrs = p.scratchSlice(scratch_top);
    const attrs_range = try p.addSlice(attrs);
    p.scratchPop(scratch_top);

    // Self-closing: `/>`.
    if (p.peek() == .slash) {
        _ = p.advance(); // consume `/`
        _ = try p.expect(.greater_than); // consume `>`

        const extra = try p.addExtra(ast.JsxOpeningData, .{
            .name = name_node,
            .attrs_start = attrs_range.start,
            .attrs_end = attrs_range.end,
        });
        return p.addNode(.{
            .tag = .jsx_self_closing,
            .main_token = name_tok,
            .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
        });
    }

    // Normal opening: `>`.
    _ = try p.expect(.greater_than);

    const extra = try p.addExtra(ast.JsxOpeningData, .{
        .name = name_node,
        .attrs_start = attrs_range.start,
        .attrs_end = attrs_range.end,
    });
    return p.addNode(.{
        .tag = .jsx_opening_element,
        .main_token = name_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
    });
}

/// Parse a JSX element name, including dotted names like `Foo.Bar.Baz`
/// and namespaced names like `foo:Bar`.
/// Returns a jsx_identifier, jsx_member_expr, or jsx_namespaced_name node.
fn parseJsxDottedName(p: *Parser) Error!NodeIndex {
    var name_node = try parseJsxHyphenatedIdent(p);

    // Namespaced name: foo:Bar
    if (p.peek() == .colon) {
        const colon_tok = p.advance(); // consume `:`
        const local_tag = p.peek();
        if (local_tag != .identifier and !local_tag.isKeyword()) {
            try p.emitError("Expected JSX element name after ':'");
            return p.makeErrorNode();
        }
        const local = try parseJsxSimpleName(p);
        return p.addNode(.{
            .tag = .jsx_namespaced_name,
            .main_token = colon_tok,
            .data = .{ .lhs = name_node, .rhs = local },
        });
    }

    // Dotted member expression: Foo.Bar.Baz
    while (p.peek() == .dot) {
        const dot_tok = p.advance(); // consume `.`
        const prop_tag = p.peek();
        if (prop_tag != .identifier and !prop_tag.isKeyword()) {
            try p.emitError("Expected JSX element name");
            return p.makeErrorNode();
        }
        const prop_tok = p.advance();
        const prop_node = try p.addNode(.{
            .tag = .jsx_identifier,
            .main_token = prop_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        name_node = try p.addNode(.{
            .tag = .jsx_member_expr,
            .main_token = dot_tok,
            .data = .{ .lhs = name_node, .rhs = prop_node },
        });
    }
    return name_node;
}

/// Parse a single JSX element name token (identifier or keyword-as-tag).
fn parseJsxSimpleName(p: *Parser) Error!NodeIndex {
    const tag = p.peek();
    if (tag == .identifier or tag.isKeyword()) {
        // JSX tag/attribute names are matched by the runtime as plain
        // strings against a fixed inventory — unicode escapes (`\uXXXX`)
        // are not valid here. Babel rejects `<\u{2F804}></\u{2F804}>`.
        // Emit the diagnostic but consume the token so the rest of the
        // element parses (error recovery — see parseJsxHyphenatedIdent).
        if (p.has_escape_ptr[p.tok_i]) {
            try p.emitError("Unexpected token");
        }
        const tok = p.advance();
        return p.addNode(.{
            .tag = .jsx_identifier,
            .main_token = tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }
    try p.emitError("Expected JSX element name");
    return p.makeErrorNode();
}

/// Parse a potentially hyphenated JSX name: `ident (-ident)*`.
/// Used for element names like `not-meta` and attribute names like `aria-fake`.
///
/// Returns a `jsx_identifier` node.  For compound names, `lhs` holds the
/// end byte position (past the last character) so the adapter can extract
/// the full text including hyphens.  For simple names, `lhs = .none`.
fn parseJsxHyphenatedIdent(p: *Parser) Error!NodeIndex {
    const tag = p.peek();
    if (tag != .identifier and !tag.isKeyword()) {
        try p.emitError("Expected JSX name");
        return p.makeErrorNode();
    }
    // Reject unicode escapes in tag names (see parseJsxSimpleName) — but consume
    // the offending token so the rest of the JSX element still parses. Without
    // advancing, the caller would re-enter on the same token and loop.
    if (p.has_escape_ptr[p.tok_i]) {
        try p.emitError("Unexpected token");
    }
    const first_tok = p.advance();

    // Check for hyphen continuation: `-` followed immediately by an identifier.
    // Use token start positions to detect adjacent tokens (no whitespace gap).
    const starts = p.tok_starts_ptr;
    const lens = p.tok_lens_ptr;
    var last_tok: u32 = first_tok;

    while (p.peek() == .minus) {
        // The `-` must be immediately after the previous token (no space).
        const minus_tok = p.tok_i;
        if (starts[minus_tok] != starts[last_tok] + lens[last_tok]) break;
        // The next token after `-` must be an identifier immediately adjacent.
        const next_tok_idx = minus_tok + 1;
        if (!p.tokenExists(next_tok_idx)) break;
        const next_tag = p.tags_ptr[next_tok_idx];
        if ((next_tag != .identifier and !next_tag.isKeyword()) or
            starts[next_tok_idx] != starts[minus_tok] + lens[minus_tok]) break;
        // Consume `-` and the following identifier.
        _ = p.advance(); // consume minus
        last_tok = p.advance(); // consume identifier
    }

    return p.addNode(.{
        .tag = .jsx_identifier,
        .main_token = first_tok,
        .data = .{
            // For compound names (e.g. aria-fake), lhs = last token index so the
            // JS adapter can extract the full text via source.slice(start, end).
            .lhs = if (last_tok != first_tok) NodeIndex.fromInt(last_tok) else .none,
            .rhs = .none,
        },
    });
}

/// Parse a JSX attribute name: `(ident (-ident)*)(:ident(-ident)*)`.
/// Handles both plain names (`className`, `aria-fake`) and namespaced names
/// (`xlink:href`, `xml:lang`).
fn parseJsxAttributeName(p: *Parser) Error!NodeIndex {
    const tag = p.peek();
    if (tag != .identifier and !tag.isKeyword()) {
        try p.emitError("Expected JSX attribute name");
        return p.makeErrorNode();
    }
    const name_tok = p.tok_i;
    const prefix_node = try parseJsxHyphenatedIdent(p);

    // Namespaced attribute: `xlink:href`, `xml:lang`
    if (p.peek() == .colon) {
        const colon_tok = p.advance(); // consume `:`
        const local_tag = p.peek();
        if (local_tag != .identifier and !local_tag.isKeyword()) {
            try p.emitError("Expected JSX attribute name after ':'");
            return p.makeErrorNode();
        }
        const local_node = try parseJsxHyphenatedIdent(p);
        return p.addNode(.{
            .tag = .jsx_namespaced_name,
            .main_token = colon_tok,
            .data = .{ .lhs = prefix_node, .rhs = local_node },
        });
    }
    _ = name_tok;
    return prefix_node;
}

// =====================================================================
// Children:  text, {expr}, or nested elements between open/close
// =====================================================================

/// Parse JSX children between opening and closing tags.
///
/// Children can be:
///   - `{expression}` — expression container
///   - `<element>` — nested JSX element (or fragment)
///   - `</` — signals end of children (closing tag ahead)
///   - anything else — treated as JSX text content
///
/// Returns a SubRange of child node indices.
///
/// Emit a `jsx_gap_node` for pure-whitespace tokens between the previous child
/// and the current token, so whitespace-sensitive lint rules (react/jsx-newline
/// etc.) can inspect inter-child gaps. No-op at the start of the child list or
/// when the previous child was a text node (text absorbs its trailing gap into
/// its own end range).
fn emitJsxGap(p: *Parser, last_child_was_text: bool) !void {
    if (last_child_was_text or p.tok_i == 0) return;
    const starts = p.tok_starts_ptr;
    const lens = p.tok_lens_ptr;
    const prev_end = starts[p.tok_i - 1] + lens[p.tok_i - 1];
    const cur_start = starts[p.tok_i];
    if (prev_end < cur_start) {
        const gap_node = try p.addNode(.{
            .tag = .jsx_gap_node,
            .main_token = @intCast(p.tok_i - 1),
            .data = .{
                .lhs = NodeIndex.fromInt(prev_end),
                .rhs = NodeIndex.fromInt(cur_start),
            },
        });
        try p.scratchPush(gap_node);
    }
}

fn parseJsxChildren(p: *Parser) Error!SubRange {
    const scratch_top = p.scratchLen();
    const starts = p.tok_starts_ptr;
    const lens = p.tok_lens_ptr;
    var last_child_was_text = false;

    while (!p.isAtEnd()) {
        const tag = p.peek();

        // `</` signals the closing tag — stop collecting children.
        // Before breaking, emit a gap node if there is whitespace before the closing `</`
        // that is NOT already covered by a preceding text node's range.
        // (Text nodes absorb their trailing gap into the node end via lhs = next_tok_idx.)
        if (tag == .less_than) {
            if (p.peekAt(1) == .slash) {
                // Emit gap before closing tag only if last child wasn't a text node.
                // (If last child was text, its end already extends to tok_starts[<].)
                try emitJsxGap(p, last_child_was_text);
                break;
            }

            // Before consuming a child element, emit any gap from the previous token.
            // This gap is pure whitespace (no text tokens) and needs to be a JSXText node
            // so rules like react/jsx-newline can inspect the whitespace between elements.
            try emitJsxGap(p, last_child_was_text);

            // Nested JSX element or fragment: `<Foo>` or `<>`.
            _ = p.advance(); // consume `<`
            const child = try parseJsxElement(p);
            try p.scratchPush(child);
            last_child_was_text = false;
            continue;
        }

        // Expression container: `{expr}` or `{}`.
        if (tag == .l_brace) {
            // Emit gap before expression if last child wasn't a text node.
            try emitJsxGap(p, last_child_was_text);

            const brace_tok = p.advance(); // consume `{`

            // Empty expression container: `{}` or `{/*comment*/}`.
            if (p.peek() == .r_brace) {
                const l_brace_end = starts[brace_tok] + lens[brace_tok];
                const r_brace_start = starts[p.tok_i];
                _ = p.advance(); // consume `}`
                const empty_expr = try p.addNode(.{
                    .tag = .jsx_empty_expr,
                    .main_token = brace_tok,
                    .data = .{
                        .lhs = NodeIndex.fromInt(l_brace_end),
                        .rhs = NodeIndex.fromInt(r_brace_start),
                    },
                });
                const container = try p.addNode(.{
                    .tag = .jsx_expression_container,
                    .main_token = brace_tok,
                    .data = .{ .lhs = empty_expr, .rhs = .none },
                });
                try p.scratchPush(container);
                last_child_was_text = false;
                continue;
            }

            // Spread child: `{...expr}` — JSXSpreadChild.
            // Must come BEFORE the regular expression branch because `...`
            // is not a valid expression starter.
            if (p.peek() == .ellipsis) {
                _ = p.advance(); // consume `...`
                const expr = try p.parseAssignmentExpression();
                _ = try p.expect(.r_brace);
                const spread = try p.addNode(.{
                    .tag = .jsx_spread_child,
                    .main_token = brace_tok,
                    .data = .{ .lhs = expr, .rhs = .none },
                });
                try p.scratchPush(spread);
                last_child_was_text = false;
                continue;
            }

            // `{expr}` inside children.
            // Track the first token to detect whether the expression is parenthesized.
            const expr_first_tok = p.tok_i;
            const expr = try p.parseExpression();
            // Sequence expressions are not allowed directly in JSX containers:
            // `{a, b}` is invalid, but `{(a, b)}` (parenthesized) is allowed.
            if (p.node_tags_ptr[expr.toInt()] == .sequence_expr and
                p.tags_ptr[expr_first_tok] != .l_paren)
            {
                try p.emitDiagnostic(p.currentSpan(), "Sequence expressions cannot be directly nested inside JSX. Did you mean to wrap it in parentheses (...)?", .{});
            }
            _ = try p.expect(.r_brace);

            const container = try p.addNode(.{
                .tag = .jsx_expression_container,
                .main_token = brace_tok,
                .data = .{ .lhs = expr, .rhs = .none },
            });
            try p.scratchPush(container);
            last_child_was_text = false;
            continue;
        }

        // EOF — bail out.
        if (tag == .eof) break;

        // Bare `}` inside JSX text is a syntax error — Babel rejects
        // `<div>}</div>` because closing braces only have meaning inside
        // expression containers. The lexer can't catch this (it just
        // emits an `r_brace` token); flag it here.
        if (tag == .r_brace) {
            try p.emitError("Unexpected token, expected jsx text or expression container");
            _ = p.advance();
            continue;
        }

        // Text content: collect everything that isn't `<`, `{`, or eof into a single
        // JSXText node.  This includes:
        //   - Regular tokens like identifiers, punctuation, keywords
        //   - HTML entities split by the lexer (e.g. `&`, `nbsp`, `;`)
        //   - Gaps (lexer-skipped chars like \u00a0) between tokens — absorbed into value
        //
        // Both leading AND trailing gaps are absorbed into the text node's range:
        //   lhs = next_tok_idx (token AFTER text span): end = tok_starts[lhs], includes trailing gap
        //   rhs = leading_gap_start byte offset (or .none): start override for napi.zig
        // This produces a single JSXText covering e.g. "\n  foo\n  " before <a>.
        {
            // Leading gap before first text token.
            var leading_gap_start: ?u32 = null;
            if (p.tok_i > 0) {
                const prev_end = starts[p.tok_i - 1] + lens[p.tok_i - 1];
                if (prev_end < starts[p.tok_i]) {
                    leading_gap_start = prev_end;
                }
            }

            const first_tok: u32 = p.tokIdx();
            _ = p.advance(); // consume first token

            // Consume all subsequent text tokens (no `<`, `{`, eof).
            while (!p.isAtEnd()) {
                const next = p.peek();
                if (next == .less_than or next == .l_brace or next == .eof) break;
                _ = p.advance();
            }

            // lhs = next_tok_idx (always): end position = tok_starts[lhs], absorbs trailing gap.
            // rhs = leading_gap_start byte (or .none): start override.
            const text_node = try p.addNode(.{
                .tag = .jsx_text_node,
                .main_token = first_tok,
                .data = .{
                    .lhs = NodeIndex.fromInt(p.tokIdx()), // next token after text span
                    .rhs = if (leading_gap_start) |gs| NodeIndex.fromInt(gs) else .none,
                },
            });
            try p.scratchPush(text_node);
            last_child_was_text = true;
        }
    }

    const children = p.scratchSlice(scratch_top);
    const range = try p.addSlice(children);
    p.scratchPop(scratch_top);
    return range;
}

// =====================================================================
// Closing element:  </tag>
// =====================================================================

/// Parse `</tag>`.
///
/// Expects the token stream to be positioned at `<`.
fn parseJsxClosingElement(p: *Parser) Error!NodeIndex {
    const lt_tok = try p.expect(.less_than);
    _ = try p.expect(.slash);

    // Parse the closing tag name (including dotted names like `</Foo.Bar>`).
    const name_node = try parseJsxDottedName(p);

    _ = try p.expect(.greater_than);

    return p.addNode(.{
        .tag = .jsx_closing_element,
        .main_token = lt_tok,
        .data = .{ .lhs = name_node, .rhs = .none },
    });
}

// =====================================================================
// Attributes
// =====================================================================

/// Parse a single JSX attribute.
///
/// Forms:
///   - `{...expr}` — spread attribute
///   - `name="value"` — string value
///   - `name={expr}` — expression value
///   - `name` — boolean attribute (no value, rhs = .none)
fn parseJsxAttribute(p: *Parser) Error!NodeIndex {
    // Spread attribute: `{...expr}`.
    if (p.peek() == .l_brace) {
        const brace_tok = p.advance(); // consume `{`
        _ = try p.expect(.ellipsis); // consume `...`
        const expr = try p.parseAssignmentExpression();
        _ = try p.expect(.r_brace);
        return p.addNode(.{
            .tag = .jsx_spread_attribute,
            .main_token = brace_tok,
            .data = .{ .lhs = expr, .rhs = .none },
        });
    }

    // Named attribute.
    const name_tok: u32 = p.tokIdx();
    const name_node = try parseJsxAttributeName(p);

    // No value — boolean attribute: `<input disabled />`.
    if (p.peek() != .equal) {
        return p.addNode(.{
            .tag = .jsx_attribute,
            .main_token = name_tok,
            .data = .{ .lhs = name_node, .rhs = .none },
        });
    }

    // Consume `=`.
    _ = p.advance();

    // Value: string literal or expression container.
    const value_node: NodeIndex = if (p.peek() == .string_literal) blk: {
        const str_tok = p.advance();
        break :blk try p.addNode(.{
            .tag = .string_literal,
            .main_token = str_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else if (p.peek() == .l_brace) blk: {
        const brace_tok = p.advance(); // consume `{`
        // Empty expression container: `{}` — in non-TS mode emit a diagnostic (Babel rejects this);
        // in TS mode allow it silently (TypeScript emits TS17000 as a semantic check, not parse error).
        if (p.peek() == .r_brace) {
            if (!p.is_ts) try p.emitDiagnostic(p.currentSpan(), "JSX attributes must only be assigned a non-empty expression", .{});
            const l_brace_end = p.tok_starts_ptr[brace_tok] + p.tok_lens_ptr[brace_tok];
            const r_brace_start = p.tok_starts_ptr[p.tok_i];
            _ = p.advance(); // consume `}`
            const empty_expr = try p.addNode(.{
                .tag = .jsx_empty_expr,
                .main_token = brace_tok,
                .data = .{
                    .lhs = NodeIndex.fromInt(l_brace_end),
                    .rhs = NodeIndex.fromInt(r_brace_start),
                },
            });
            break :blk try p.addNode(.{
                .tag = .jsx_expression_container,
                .main_token = brace_tok,
                .data = .{ .lhs = empty_expr, .rhs = .none },
            });
        }
        const expr = try p.parseAssignmentExpression();
        _ = try p.expect(.r_brace);
        break :blk try p.addNode(.{
            .tag = .jsx_expression_container,
            .main_token = brace_tok,
            .data = .{ .lhs = expr, .rhs = .none },
        });
    } else if (p.peek() == .less_than) blk: {
        // JSX element as attribute value (non-standard propElementValues extension).
        _ = p.advance(); // consume '<'
        const elem = try parseJsxElement(p);
        break :blk elem;
    } else blk: {
        try p.emitError("Expected string literal or '{' for JSX attribute value");
        break :blk try p.makeErrorNode();
    };

    return p.addNode(.{
        .tag = .jsx_attribute,
        .main_token = name_tok,
        .data = .{ .lhs = name_node, .rhs = value_node },
    });
}

// =====================================================================
// Fragment:  <>children</>
// =====================================================================

/// Parse a JSX fragment.  The opening `<` has already been consumed
/// by the caller, and we are looking at `>` (the closing angle bracket
/// of the `<>` opening).
fn parseJsxFragment(p: *Parser) Error!NodeIndex {
    const open_tok: u32 = p.tokIdx();
    // Classic JSX transform: <> compiles to React.createElement(React.Fragment, null, …).
    p.jsx_has_intrinsic = true;
    _ = try p.expect(.greater_than); // consume `>` to complete `<>`

    // Parse children.
    const children = try parseJsxChildren(p);

    // Expect closing fragment: `</>`.
    _ = try p.expect(.less_than);
    _ = try p.expect(.slash);
    _ = try p.expect(.greater_than);

    return p.addNode(.{
        .tag = .jsx_fragment,
        .main_token = open_tok,
        .data = .{
            .lhs = NodeIndex.fromInt(children.start),
            .rhs = NodeIndex.fromInt(children.end),
        },
    });
}

// =====================================================================
// Helpers
// =====================================================================

/// Compare opening (`jsx_opening_element` / `jsx_self_closing`) and
/// closing (`jsx_closing_element`) tag names. Returns true if they
/// refer to the same identifier / dotted member / namespaced name.
/// Used by `parseJsxElement` to surface `<Foo></Bar>` mismatches.
fn jsxNameMatches(p: *Parser, opening: NodeIndex, closing: NodeIndex) bool {
    const open_idx = opening.toInt();
    const open_tag = p.nodeTag(open_idx);
    if (open_tag != .jsx_opening_element and open_tag != .jsx_self_closing) return true;
    // JsxOpeningData has `name: NodeIndex` at offset 0. data.lhs is the extra index.
    const open_extra: u32 = @intFromEnum(p.nodeData(open_idx).lhs);
    const open_name = NodeIndex.fromInt(p.extra_data.items[open_extra]);

    const close_idx = closing.toInt();
    if (p.nodeTag(close_idx) != .jsx_closing_element) return true;
    const close_name = p.nodeData(close_idx).lhs;

    return jsxNameEql(p, open_name, close_name);
}

fn jsxNameEql(p: *Parser, a: NodeIndex, b: NodeIndex) bool {
    const ai = a.toInt();
    const bi = b.toInt();
    const ta = p.nodeTag(ai);
    const tb = p.nodeTag(bi);
    if (ta != tb) return false;
    switch (ta) {
        .jsx_identifier => {
            const at = p.tokenText(p.node_main_token_ptr[ai]);
            const bt = p.tokenText(p.node_main_token_ptr[bi]);
            return std.mem.eql(u8, at, bt);
        },
        .jsx_member_expr, .jsx_namespaced_name => {
            const ad = p.nodeData(ai);
            const bd = p.nodeData(bi);
            return jsxNameEql(p, ad.lhs, bd.lhs) and jsxNameEql(p, ad.rhs, bd.rhs);
        },
        else => return true, // unrecognized — accept (recovery)
    }
}

const std = @import("std");

/// Emit a read reference for JSX component names.
/// In JSX, uppercase-initial names (e.g. <Foo>, <Foo.Bar>) are variable
/// references, not HTML intrinsics. We emit a .read reference so the scope
/// analysis tracks that the variable is used.
fn emitJsxComponentRef(p: *Parser, name_node: NodeIndex) !void {
    if (!p.emit_scope_events) return;
    // Walk down to the root identifier (lhs of member expressions).
    // Track whether the original name was a member expression — if so, the
    // root identifier is always a component ref regardless of case (e.g.
    // <components.Button /> uses `components` even though it's lowercase).
    var root = name_node;
    var is_member = false;
    while (true) {
        if (root == .none) return;
        const idx = @intFromEnum(root);
        const t = p.nodeTag(idx);
        if (t == .jsx_identifier) break;
        if (t == .jsx_member_expr) {
            is_member = true;
            root = p.nodeData(idx).lhs;
        } else {
            return; // namespaced names (foo:Bar) — no variable reference
        }
    }
    // For direct identifiers only uppercase-initial names are components.
    // For member expressions the root object is always a variable reference.
    if (!is_member) {
        const root_tok = p.node_main_token_ptr[@intFromEnum(root)];
        const text = p.tokenText(root_tok);
        if (text.len == 0 or text[0] < 'A' or text[0] > 'Z') {
            // Intrinsic element — classic transform uses the factory for these too.
            p.jsx_has_intrinsic = true;
            return;
        }
    }
    try p.emitReference(.read, root);
}

