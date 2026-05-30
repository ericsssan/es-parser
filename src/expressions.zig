// ── src/parser/expressions.zig ─────────────────────────────────────────
// Pratt (precedence-climbing) expression parser for ES2024 JavaScript.
//
// All public functions take a `*Parser` (defined in parser.zig) and
// return a `NodeIndex` wrapped in an error union.  During integration,
// parser.zig will `@import("expressions.zig")` and wire these
// functions into its own API.
// ───────────────────────────────────────────────────────────────────────

const std = @import("std");
const LexHelpers = @import("lexer_helpers.zig");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const SubRange = ast.SubRange;
const TokenIndex = ast.TokenIndex;
const Token = @import("token.zig");
const TokenTag = Token.Tag;

// ── Forward reference to the main parser ──────────────────────────────
// parser.zig defines the Parser struct with the methods listed below.
// During integration, if circular import issues arise, we can switch
// to an opaque-pointer design with function pointers.  For now we
// import directly.
const parser_mod = @import("parser.zig");
pub const Parser = parser_mod.Parser;
const Error = parser_mod.Error;

// ── Helpers ──────────────────────────────────────────────────────────

/// Unwrap nested grouping_expr nodes to find the innermost expression.
/// `(x)`, `((x))`, `(((x)))` all resolve to the tag of `x`.
pub fn unwrapGroupingTag(p: *const Parser, node: NodeIndex) Node.Tag {
    return unwrapGrouping(p, node).tag;
}

pub const UnwrapResult = struct { node: NodeIndex, tag: Node.Tag };

pub fn unwrapGrouping(p: *const Parser, node: NodeIndex) UnwrapResult {
    var current = node;
    var tag = p.node_tags_ptr[current.toInt()];
    while (tag == .grouping_expr) {
        const inner = p.node_data_ptr[current.toInt()].lhs;
        if (inner == .none) break;
        current = inner;
        tag = p.node_tags_ptr[current.toInt()];
    }
    return .{ .node = current, .tag = tag };
}

// ── Precedence ────────────────────────────────────────────────────────

pub const Precedence = enum(u8) {
    none = 0,
    comma = 1,
    assignment = 2,
    conditional = 3,
    nullish_coalesce = 4,
    logical_or = 5,
    logical_and = 6,
    bitwise_or = 7,
    bitwise_xor = 8,
    bitwise_and = 9,
    equality = 10,
    relational = 11,
    shift = 12,
    additive = 13,
    multiplicative = 14,
    exponentiation = 15,
    unary = 16,
    postfix = 17,
    call = 18,
    new_expr = 19,
    primary = 20,

    pub fn isRightAssociative(self: Precedence) bool {
        return self == .assignment or self == .exponentiation;
    }

    /// Return the next-higher precedence for left-associative operators.
    /// Right-associative operators pass their own level unchanged so that
    /// the recursive call binds to the right.
    pub fn next(self: Precedence) Precedence {
        if (self.isRightAssociative()) return self;
        const v = @intFromEnum(self);
        if (v >= @intFromEnum(Precedence.primary)) return self;
        return @enumFromInt(v + 1);
    }
};

// =====================================================================
// Public entry points
// =====================================================================

/// Parse a full expression (comma-separated sequence expression).
pub fn parseExpression(p: *Parser) Error!NodeIndex {
    return parseExpressionPrec(p, .comma);
}

/// Parse an assignment expression (no comma).
pub inline fn parseAssignmentExpression(p: *Parser) Error!NodeIndex {
    const saved_arrow = p.allow_arrow;
    p.allow_arrow = true;
    defer p.allow_arrow = saved_arrow;
    return parseExpressionPrec(p, .assignment);
}

/// Parse a conditional expression (ternary level, no assignment).
pub inline fn parseConditionalExpression(p: *Parser) Error!NodeIndex {
    return parseExpressionPrec(p, .conditional);
}

// =====================================================================
// Core Pratt loop
// =====================================================================

fn parseExpressionPrec(p: *Parser, min_prec: Precedence) Error!NodeIndex {
    // `#x` as primary is only valid at relational precedence (LHS of `in`).
    // Set a one-shot flag so parsePrimary's .hash branch can validate.
    const saved_priv_lhs = p.private_in_lhs_allowed;
    p.private_in_lhs_allowed = (@intFromEnum(min_prec) <= @intFromEnum(Precedence.relational));
    defer p.private_in_lhs_allowed = saved_priv_lhs;
    var left = try parsePrefixExpression(p, min_prec);
    // After consuming the LHS, nested operands (e.g. RHS of `in`) are not
    // valid `#x` positions at this same level — but they go through their
    // own parseExpressionPrec recursion which sets its own flag.
    p.private_in_lhs_allowed = saved_priv_lhs;
    // Hoist: language is set once per parse call. Save the field load on
    // every iter of the Pratt loop (millions of times across a large file).
    const is_ts = p.is_ts;

    while (true) {
        const tag = p.peek();

        // Single table lookup covers eof (.none), call-level (.call), postfix
        // ++/-- (.postfix), and all infix binary operators.
        const prec_entry: u8 = @intFromEnum(prec_table[@intFromEnum(tag)]);

        // Ultra-fast path: call/member/optional-chain (prec 18) is the most
        // common infix token in real JS/TS code.  min_prec is at most .call
        // (18, used only for class `extends`), and prec_entry == 18 here, so
        // `prec_entry < min_prec` is always false — skip it.  .less_than and
        // .kw_in have relational prec (11), never 18, so those guards are also
        // irrelevant on this path.
        if (prec_entry == @intFromEnum(Precedence.call)) {
            // Fast paths for the two dominant call-level tokens.  Both always
            // consume at least one token, so the before_call progress check is
            // not needed — saving a save + load + compare per member/call site.
            if (tag == .dot) {
                left = try parseMemberAccess(p, left);
                continue;
            }
            if (tag == .l_paren) {
                // Arrow functions are not valid call/member targets without parens.
                // In TS mode, skip this check (TypeScript handles it at type-check level).
                if (!is_ts and left != .none) {
                    const left_tag = p.node_tags_ptr[left.toInt()];
                    if (left_tag == .arrow_fn or left_tag == .async_arrow_fn) {
                        try p.emitError("Arrow function is not directly callable (wrap in parens)");
                        break;
                    }
                }
                left = try parseCallExpression(p, left);
                continue;
            }
            // Remaining call-level tokens (.l_bracket, .question_dot, .template_*)
            // may legitimately fail to make progress (e.g. .l_bracket after a
            // postfix op on a new line inside a class field triggers ASI).
            const before_call = p.tok_i;
            left = try parseCallLevelInfix(p, left, tag);
            if (p.tok_i == before_call) break; // no progress (ASI in class field)
            continue;
        }

        if (prec_entry == 0) {
            // Not a standard JS operator.  May be a TS-specific postfix form.
            // .kw_as / .kw_satisfies / .bang all have prec_entry == 0, so they
            // land here; .less_than (relational) is handled below.
            //
            // Accept TS as / satisfies even in JS mode when the syntactic
            // shape is unambiguous (next token is identifier-like — a type
            // reference).  ESLint with a TS-aware parser produces the same
            // AST for these in JS files; matching that node shape closes
            // gaps in rules like no-unneeded-ternary on TS test fixtures.
            // Bang (non-null) requires lookahead to disambiguate from `!a`
            // postfix vs prefix; keep it strictly TS-only for safety.
            const ts_lookalike = !is_ts and switch (tag) {
                .kw_as, .kw_satisfies => blk: {
                    const nx = p.peekAt(1);
                    break :blk nx == .identifier or nx.isKeyword() or nx == .escaped_keyword;
                },
                else => false,
            };
            if (is_ts or ts_lookalike) {
                switch (tag) {
                    .kw_as => {
                        if (@intFromEnum(Precedence.relational) < @intFromEnum(min_prec)) break;
                        // TS1355: `as const` can only be applied to literals, arrays, or objects.
                        if (p.peekAt(1) == .kw_const and !isValidConstAssertionTarget(p, left)) {
                            try p.emitError("A 'const' assertion can only be applied to references to enum members, or string, number, boolean, array, or object literals");
                            return error.ParseError;
                        }
                        left = try parseTsTypePostfix(p, left, .ts_as_expr);
                        continue;
                    },
                    .kw_satisfies => {
                        if (@intFromEnum(Precedence.relational) < @intFromEnum(min_prec)) break;
                        left = try parseTsTypePostfix(p, left, .ts_satisfies_expr);
                        continue;
                    },
                    .bang => if (!p.isOnNewLine() and is_ts) {
                        const post_prec = Precedence.postfix;
                        if (@intFromEnum(post_prec) < @intFromEnum(min_prec)) break;
                        left = try parseTsNonNullExpression(p, left);
                        continue;
                    },
                    else => {},
                }
            }
            break;
        }

        // Standard operator (prec_entry > 0, != call).
        // TS: `<` has relational prec in the table but may open a generic
        // type-argument list — check before treating it as a binary operator.
        if (is_ts and tag == .less_than) {
            const lt_tok: TokenIndex = @intCast(p.tok_i);
            if (tryParseTsTypeArguments(p)) |type_args_range| {
                // TS1477: An instantiation expression cannot be followed by a property access.
                if (p.peek() == .dot or p.peek() == .question_dot) {
                    try p.emitError("An instantiation expression cannot be followed by a property access");
                    return error.ParseError;
                }
                // TS1034: `super<T>\`template\`` is invalid.
                if (left != .none and p.node_tags_ptr[left.toInt()] == .super_expr and
                    (p.peek() == .template_head or p.peek() == .template_no_sub))
                {
                    try p.emitError("'super' must be followed by an argument list or member access");
                    return error.ParseError;
                }
                // Wrap `left` in a ts_instantiation_expr so the type-arg nodes
                // have a real parent. The wrapper is the new callee/operand and
                // remains visible to estree-adapter as TSInstantiationExpression.
                // If the next token is `(` the outer call/new parses normally
                // with this wrapper as its callee.
                const range_extra = try p.addExtra(ast.SubRange, type_args_range);
                left = try p.addNode(.{
                    .tag = .ts_instantiation_expr,
                    .main_token = lt_tok,
                    .data = .{ .lhs = left, .rhs = NodeIndex.fromInt(range_extra) },
                });
                continue;
            }
        }

        // kw_in is suppressed in for-init and similar no-in contexts.
        if (tag == .kw_in and !p.allow_in) break;
        if (prec_entry < @intFromEnum(min_prec)) break;

        // Postfix ++ / -- require no newline before the operator (ASI).
        if (prec_entry == @intFromEnum(Precedence.postfix)) {
            if (p.isOnNewLine()) break;
            left = try parsePostfixUpdate(p, left, tag);
            // TS: postfix result cannot be chained with member access or another postfix on same line.
            if (is_ts and !p.isOnNewLine()) {
                const next2 = p.peek();
                if (next2 == .dot or next2 == .question_dot or
                    next2 == .plus_plus or next2 == .minus_minus)
                {
                    try p.emitError("';' expected");
                    return error.ParseError;
                }
            }
            continue;
        }

        // Infix binary operator.
        const infix_prec: Precedence = @enumFromInt(prec_entry);

        // yield [no LineTerminator here] — if yield returned with no operand
        // and next operator is on a new line, don't consume it
        if (left != .none and p.isOnNewLine()) {
            const left_tag = p.node_tags_ptr[left.toInt()];
            if (left_tag == .yield_expr) {
                const d = p.node_data_ptr[left.toInt()];
                if (d.lhs == .none) break; // yield with no operand — ASI boundary
            }
        }

        // Arrow function cannot be an operand of a binary operator (other than `,`/`=`).
        if (left != .none and prec_entry != @intFromEnum(Precedence.comma) and
            prec_entry != @intFromEnum(Precedence.assignment))
        {
            const left_tag = p.node_tags_ptr[left.toInt()];
            if (left_tag == .arrow_fn or left_tag == .async_arrow_fn) {
                if (!is_ts) {
                    try p.emitError("Arrow function not allowed as operand of binary operator (wrap in parens)");
                    break;
                }
                // TS: block-body arrow functions cannot be used as a binary operand.
                const d = p.node_data_ptr[left.toInt()];
                const ed_idx = d.lhs.toInt();
                if (ed_idx + 2 < p.extra_data.items.len) {
                    const body = NodeIndex.fromInt(p.extra_data.items[ed_idx + 2]);
                    if (body != .none and p.node_tags_ptr[body.toInt()] == .block_stmt) {
                        try p.emitError("';' expected");
                        break;
                    }
                }
            }
        }

        // Inlined parseInfixExpression — saves a function call + branch chain
        // per infix operator (binary is the overwhelmingly common case in the
        // parse profile, ~95%+ of these calls).
        if (tag == .question) {
            left = try parseConditionalTail(p, left);
        } else if (tag == .comma) {
            left = try parseSequenceExpression(p, left);
        } else if (tag.isAssignment()) {
            left = try parseAssignment(p, left);
        } else {
            left = try parseBinaryExpression(p, left, infix_prec, tag);
        }
    }

    return left;
}

// =====================================================================
// Prefix dispatch
// =====================================================================

fn parsePrefixExpression(p: *Parser, min_prec: Precedence) Error!NodeIndex {
    const tag = p.peek();
    // Fast path: plain identifier is the most common primary expression.
    // Skip the parsePrimaryExpression call and switch overhead for this case.
    if (tag == .identifier) {
        @branchHint(.likely);
        return parseIdentifierOrArrow(p);
    }
    return switch (tag) {
        // ── Unary operators ──────────────────────────────────
        .plus => try parseUnaryOp(p, .unary_plus),
        .minus => try parseUnaryOp(p, .unary_minus),
        .tilde => try parseUnaryOp(p, .bitwise_not),
        .bang => try parseUnaryOp(p, .logical_not),

        // ── Prefix update ────────────────────────────────────
        .plus_plus => try parseUnaryOp(p, .prefix_inc),
        .minus_minus => try parseUnaryOp(p, .prefix_dec),

        // ── Keyword unary ────────────────────────────────────
        .kw_typeof => try parseUnaryOp(p, .typeof_expr),
        .kw_void => try parseUnaryOp(p, .void_expr),
        .kw_delete => blk: {
            const del_node = try parseUnaryOp(p, .delete_expr);
            if (del_node != .none) {
                const del_data = p.node_data_ptr[del_node.toInt()];
                if (del_data.lhs != .none) {
                    // Strict mode / TypeScript: `delete identifier` invalid (also through grouping).
                    if (p.in_strict or p.is_ts) {
                        const inner_tag = unwrapGroupingTag(p, del_data.lhs);
                        if (inner_tag == .identifier) {
                            try p.emitError("'delete' of unqualified identifier in strict mode");
                        }
                    }
                    // `delete obj.#priv` / `delete obj?.#priv` — invalid in any mode.
                    if (!p.is_ts and containsPrivateMember(p, del_data.lhs)) {
                        try p.emitError("'delete' of private name is not allowed");
                    }
                }
            }
            break :blk del_node;
        },

        // ── Await ────────────────────────────────────────────
        .kw_await => try parseAwaitExpression(p),

        // ── Yield ────────────────────────────────────────────
        .kw_yield => blk: {
            if (p.in_generator and @intFromEnum(min_prec) > @intFromEnum(Precedence.assignment)) {
                try p.emitError("'yield' expression not allowed in this context");
            }
            break :blk try parseYieldExpression(p);
        },

        // ── New ──────────────────────────────────────────────
        .kw_new => try parseNewExpression(p),

        // ── Everything else → primary ────────────────────────
        else => try parsePrimaryExpression(p),
    };
}

// ── Unary helper ─────────────────────────────────────────────────

/// True if `node` (or any sub-expression reached through paren grouping or
/// member access chain) ultimately accesses a private name (`obj.#x`,
/// `obj?.#x`, etc).
fn containsPrivateMember(p: *Parser, node: NodeIndex) bool {
    if (node == .none) return false;
    const tag = p.node_tags_ptr[node.toInt()];
    const data = p.node_data_ptr[node.toInt()];
    return switch (tag) {
        .grouping_expr => containsPrivateMember(p, data.lhs),
        .member_expr, .optional_member_expr => blk: {
            // rhs holds the property name (property_ident or identifier).
            // Private if its main_token starts with `#`.
            if (data.rhs == .none) break :blk false;
            const main_tok = p.node_main_token_ptr[data.rhs.toInt()];
            const tt = p.tokenTagAt(main_tok);
            break :blk tt == .hash;
        },
        else => false,
    };
}

fn parseUnaryOp(p: *Parser, node_tag: Node.Tag) Error!NodeIndex {
    const tok = p.advance();
    // TS: prefix ++/-- followed by ++/-- on a new line — the second ++/-- is parsed
    // as postfix with no operand, yielding TS1109 "Expression expected".
    if (p.is_ts and (node_tag == .prefix_inc or node_tag == .prefix_dec) and p.isOnNewLine()) {
        const next = p.peek();
        if (next == .plus_plus or next == .minus_minus) {
            try p.emitError("Expression expected");
            return error.ParseError;
        }
    }
    const operand = try parseExpressionPrec(p, .unary);

    // Validate prefix ++/-- operand (parenthesized identifiers valid: ++(x), ++((x)))
    if (node_tag == .prefix_inc or node_tag == .prefix_dec) {
        const op_tag = unwrapGroupingTag(p, operand);
        switch (op_tag) {
            .identifier, .member_expr, .computed_member_expr => {},
            .call_expr => {
                // AnnexB: ++f() permitted in non-strict Script.
                if (p.in_strict or !p.annex_b) {
                    if (!p.is_ts) {
                        try p.emitError("Invalid left-hand side in prefix operation: function call");
                        return error.ParseError;
                    }
                }
            },
            .optional_member_expr, .optional_computed_member_expr => {
                if (!p.is_ts) {
                    try p.emitError("Invalid left-hand side in prefix operation: optional chain");
                    return error.ParseError;
                }
            },
            else => {
                // TS type checker handles most invalid LHS cases, but clearly invalid
                // operands like await/yield/delete are still syntax errors.
                // delete returns bool (not a reference), so ++delete is always invalid.
                if (!p.is_ts or op_tag == .await_expr or op_tag == .yield_expr or
                    op_tag == .yield_delegate or op_tag == .delete_expr)
                {
                    try p.emitError("Invalid left-hand side in prefix operation");
                }
            },
        }
        // TS: prefix ++/-- whose direct operand is already postfix_inc/dec is TS1005.
        if (p.is_ts) {
            const raw_tag = p.node_tags_ptr[operand.toInt()];
            if (raw_tag == .postfix_inc or raw_tag == .postfix_dec) {
                try p.emitError("';' expected");
                return error.ParseError;
            }
        }
        // Strict mode / TypeScript: cannot update eval/arguments
        if (op_tag == .identifier and (p.in_strict or p.is_ts)) {
            const op_tok = p.node_main_token_ptr[operand.toInt()];
            try p.checkStrictAssignTarget(op_tok);
        }
    }

    // Arrow functions are AssignmentExpressions, not valid as unary operands
    if (operand != .none) {
        const op_tag = p.node_tags_ptr[operand.toInt()];
        if (op_tag == .arrow_fn or op_tag == .async_arrow_fn) {
            try p.emitError("Arrow function is not allowed as operand of unary expression");
        }
    }

    // Upgrade prefix ++/-- operand reference to .read_write (it's a read+write).
    // Delete/typeof/void are read-only — leave the reference as `.read`, but
    // typeof gets marked separately by event consumer via kind.
    if (node_tag == .prefix_inc or node_tag == .prefix_dec) {
        if (operand != .none and p.node_tags_ptr[operand.toInt()] == .identifier) {
            const RK = @import("reference.zig").ReferenceKind;
            p.upgradeReferenceKind(operand, RK.read_write);
        }
    } else if (node_tag == .typeof_expr) {
        if (operand != .none and p.node_tags_ptr[operand.toInt()] == .identifier) {
            const RK = @import("reference.zig").ReferenceKind;
            p.upgradeReferenceKind(operand, RK.type_of);
        }
    }

    return p.addNode(.{
        .tag = node_tag,
        .main_token = tok,
        .data = .{ .lhs = operand, .rhs = .none },
    });
}


// postfix_tag is the already-known ++ or -- tag from the Pratt loop.
fn parsePostfixUpdate(p: *Parser, operand: NodeIndex, postfix_tag: TokenTag) Error!NodeIndex {
    // Operand must be assignable (parenthesized identifiers are valid: (x)++, ((x))++)
    const op_tag = unwrapGroupingTag(p, operand);
    switch (op_tag) {
        .identifier, .member_expr, .computed_member_expr => {},
        .call_expr => {
            // AnnexB: f()++ permitted in non-strict Script.
            if (p.in_strict or !p.annex_b) {
                if (!p.is_ts) {
                    try p.emitError("Invalid left-hand side in postfix operation: function call");
                    return error.ParseError;
                }
            }
        },
        .optional_member_expr, .optional_computed_member_expr => {
            if (!p.is_ts) {
                try p.emitError("Invalid left-hand side in postfix operation: optional chain");
                return error.ParseError;
            }
        },
        else => {
            if (!p.is_ts) try p.emitError("Invalid left-hand side in postfix operation");
        },
    }
    // Strict mode / TypeScript: cannot update eval/arguments
    if (op_tag == .identifier and (p.in_strict or p.is_ts)) {
        const op_tok = p.node_main_token_ptr[operand.toInt()];
        try p.checkStrictAssignTarget(op_tok);
    }
    const node_tag: Node.Tag = if (postfix_tag == .plus_plus) .postfix_inc else .postfix_dec;
    const tok = p.advance();

    // Postfix `x++` / `x--` reads and writes `x`.
    if (op_tag == .identifier) {
        const RK = @import("reference.zig").ReferenceKind;
        p.upgradeReferenceKind(operand, RK.read_write);
    }

    return p.addNode(.{
        .tag = node_tag,
        .main_token = tok,
        .data = .{ .lhs = operand, .rhs = .none },
    });
}

// ── Await ────────────────────────────────────────────────────────

fn parseAwaitExpression(p: *Parser) Error!NodeIndex {
    // Determine if `await` is reserved here or can be treated as an identifier.
    // In TypeScript script mode, `in_async` is set at top-level to allow top-level
    // await expressions, but `await` is still a valid identifier in non-function
    // scope (TypeScript only reserves it inside async functions and modules).
    // In TS script mode, `in_async` is set at top-level for top-level await
    // expressions, but `await` is still a valid identifier when not inside an
    // actual async function body/params and not in a module.
    const ts_script_toplevel = p.is_ts and !p.in_function and !p.in_fn_params and !p.is_module;
    // In TypeScript, `await` inside a non-async function body is parsed as an await
    // expression (TypeScript emits TS1308 as a semantic error, not a parse error).
    // Exclude class field initializers (in_class_field) — those use in_function=true
    // from the outer function scope but await is not valid there.
    const ts_non_async_fn = p.is_ts and p.in_function and !p.in_async and !p.in_fn_params and !p.in_class_field;
    if ((!p.in_async or ts_script_toplevel) and !ts_non_async_fn) {
        // In module mode, `await` is a reserved word
        if (p.is_module) {
            try p.emitError("'await' is not allowed as an identifier in module mode");
            return error.ParseError;
        }
        // Inside a class static initialization block (not nested in a fn or its params),
        // `await` is reserved.
        if (p.in_static_block and !p.in_function and !p.in_fn_params) {
            try p.emitError("'await' is not allowed as an identifier in static initialization block");
            return error.ParseError;
        }
        // `await` used outside async context — treat as identifier reference.
        return parseIdentifierRef(p);
    }
    // await expressions are forbidden inside async parameter lists.
    // TypeScript emits TS2524 (semantic) — skip parse-time fatal error in TS mode.
    if (p.in_fn_params and !p.is_ts) {
        try p.emitError("'await' is not allowed in async parameter list");
        return error.ParseError;
    }
    const tok = p.advance(); // consume `await`
    const operand = try parseExpressionPrec(p, .unary);
    return p.addNode(.{
        .tag = .await_expr,
        .main_token = tok,
        .data = .{ .lhs = operand, .rhs = .none },
    });
}

// ── Yield ────────────────────────────────────────────────────────

fn parseYieldExpression(p: *Parser) Error!NodeIndex {
    if (!p.in_generator) {
        // In strict mode, module mode, or TypeScript mode, `yield` cannot be used as an identifier.
        // Emit diagnostic but continue parsing to avoid cascading failures.
        if (p.in_strict or p.is_module or p.is_ts) {
            try p.emitError("'yield' is not allowed as an identifier in strict mode");
        }
        // `yield` outside a generator — treat as identifier (may be arrow param).
        return parseIdentifierOrArrow(p);
    }
    // yield expressions are forbidden inside generator parameter lists.
    // TypeScript only reports this as TS2783 (type error), not a parse error.
    if (p.in_fn_params and !p.is_ts) {
        try p.emitError("'yield' is not allowed in generator parameter list");
        return error.ParseError;
    }
    const tok = p.advance(); // consume `yield`

    // yield *delegated
    if (p.peek() == .asterisk and !p.isOnNewLine()) {
        _ = p.advance(); // consume `*`
        const operand = try parseAssignmentExpression(p);
        return p.addNode(.{
            .tag = .yield_delegate,
            .main_token = tok,
            .data = .{ .lhs = operand, .rhs = .none },
        });
    }

    // yield (with optional operand — no operand if newline / ; / ) / ] / } follows)
    if (p.isOnNewLine() or isYieldTerminator(p.peek())) {
        return p.addNode(.{
            .tag = .yield_expr,
            .main_token = tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }

    // The lexer does not include kw_yield in regexAllowed, so '/' after yield is
    // emitted as .slash or .slash_equal. In generator context, re-lex as regex.
    const next = p.peek();
    if (next == .slash or next == .slash_equal) blk: {
        const slash_start: u32 = p.tokenStart(p.tokIdx());
        if (slash_start >= p.source.len) break :blk;
        const regex_end = LexHelpers.regexEnd(p.source, slash_start);
        if (regex_end <= slash_start + 1) break :blk;
        const slash_tok: u32 = p.tokIdx();
        while (!p.isAtEnd() and p.tokenStart(p.tokIdx()) < regex_end) _ = p.advance();
        const operand = try p.addNode(.{
            .tag = .regex_literal,
            .main_token = slash_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        return p.addNode(.{
            .tag = .yield_expr,
            .main_token = tok,
            .data = .{ .lhs = operand, .rhs = .none },
        });
    }

    const operand = try parseAssignmentExpression(p);
    return p.addNode(.{
        .tag = .yield_expr,
        .main_token = tok,
        .data = .{ .lhs = operand, .rhs = .none },
    });
}

fn isYieldTerminator(tag: TokenTag) bool {
    return switch (tag) {
        .semicolon, .r_paren, .r_bracket, .r_brace, .comma, .colon, .eof,
        .template_middle, .template_tail,
        => true,
        else => false,
    };
}

/// Check if a token index appears as an identifier param earlier in the list.
fn hasDuplicateParam(p: *Parser, params: []const u32, current_idx: usize, tok: TokenIndex) bool {
    const name = p.source[p.tok_starts_ptr[tok]..];
    for (params[0..current_idx]) |other_raw| {
        const other = NodeIndex.fromInt(other_raw);
        var other_tok: ?TokenIndex = null;
        const other_tag = p.node_tags_ptr[other.toInt()];
        if (other_tag == .identifier) {
            other_tok = p.node_main_token_ptr[other.toInt()];
        } else if (other_tag == .rest_element or other_tag == .spread_element) {
            const d = p.node_data_ptr[other.toInt()];
            if (d.lhs != .none and p.node_tags_ptr[d.lhs.toInt()] == .identifier) {
                other_tok = p.node_main_token_ptr[d.lhs.toInt()];
            }
        }
        if (other_tok) |ot| {
            const other_name = p.source[p.tok_starts_ptr[ot]..];
            // Compare identifier text (up to non-ident char)
            var len: usize = 0;
            while (len < name.len and len < other_name.len and isIdentChar(name[len]) and isIdentChar(other_name[len])) : (len += 1) {}
            if (len > 0 and len < name.len and !isIdentChar(name[len]) and len < other_name.len and !isIdentChar(other_name[len])) {
                const n1 = name[0..len];
                const n2 = other_name[0..len];
                if (std.mem.eql(u8, n1, n2)) return true;
            }
        }
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => true,
        else => false,
    };
}

// ── Pattern validation ───────────────────────────────────────────────

pub fn validatePattern(p: *Parser, node: NodeIndex) Error!void {
    if (node == .none) return;
    // Unwrap parenthesized expressions for validation
    const unwrapped = unwrapGrouping(p, node);
    const tag = unwrapped.tag;
    const effective_node = unwrapped.node;

    if (tag == .array_pattern) {
        const data = p.node_data_ptr[effective_node.toInt()];
        const start = data.lhs.toInt();
        const end = data.rhs.toInt();
        if (end > start) {
            var i = start;
            while (i < end) : (i += 1) {
                const child = NodeIndex.fromInt(p.extra_data.items[i]);
                if (child == .none) continue;
                const child_tag = p.node_tags_ptr[child.toInt()];
                // Rest must be last (also reject trailing comma after rest = elision)
                if (child_tag == .rest_element) {
                    // Check: any non-none elements after this?
                    var has_after = false;
                    var j = i + 1;
                    while (j < end) : (j += 1) {
                        const next = NodeIndex.fromInt(p.extra_data.items[j]);
                        if (next != .none) has_after = true;
                    }
                    // Rest element must be last. In TS mode, we still reject trailing commas
                    // (which appear as .none sentinels), but allow actual elements after rest.
                    const has_trailing_comma = i < end - 1 and !has_after;
                    if (has_trailing_comma or (!p.is_ts and (i < end - 1 or has_after))) {
                        try p.emitError("Rest element must be last in destructuring pattern");
                        return error.ParseError;
                    }
                    // Rest target cannot have a default value or be a literal
                    const rest_data = p.node_data_ptr[child.toInt()];
                    if (rest_data.lhs != .none) {
                        const rest_target_tag = p.node_tags_ptr[rest_data.lhs.toInt()];
                        if (rest_target_tag == .assign or rest_target_tag == .assignment_pattern or
                            rest_target_tag == .import_meta or rest_target_tag == .import_expr or
                            rest_target_tag == .this_expr or rest_target_tag == .number_literal or
                            rest_target_tag == .string_literal or rest_target_tag == .boolean_literal or
                            rest_target_tag == .null_literal or rest_target_tag == .super_expr or
                            rest_target_tag == .call_expr or rest_target_tag == .new_expr or
                            (!p.is_ts and (rest_target_tag == .optional_member_expr or
                            rest_target_tag == .optional_computed_member_expr or
                            rest_target_tag == .optional_call_expr)))
                        {
                            try p.emitError("Invalid rest element target in destructuring");
                            return error.ParseError;
                        }
                        // Parenthesized rest: ...(x) is valid if x is a valid target
                        if (rest_target_tag == .grouping_expr) {
                            const inner = unwrapGroupingTag(p, rest_data.lhs);
                            if (inner != .identifier and inner != .member_expr and inner != .computed_member_expr) {
                                try p.emitError("Invalid rest element target in destructuring");
                                return error.ParseError;
                            }
                        }
                        // Recursively validate rest target (e.g. [...{a: 0}] where 0 is invalid)
                        try validatePattern(p, rest_data.lhs);
                        // Strict mode: eval/arguments cannot be rest target.
                        if (rest_target_tag == .identifier and p.in_strict) {
                            const rt = p.node_main_token_ptr[rest_data.lhs.toInt()];
                            try p.checkStrictAssignTarget(rt);
                        }
                    }
                }
                // Parenthesized simple targets are valid: [(a)] = 1, [(a.b)] = 1
                // But parenthesized patterns are not: [([a])] = 1
                if (child_tag == .grouping_expr) {
                    const inner_tag = unwrapGroupingTag(p, NodeIndex.fromInt(p.extra_data.items[i]));
                    // TypeScript: (a satisfies T) and (a as T) are valid as destructuring targets
                    // (TypeScript allows them with semantic errors).
                    const ts_ok = p.is_ts and (inner_tag == .ts_satisfies_expr or inner_tag == .ts_as_expr);
                    if (!ts_ok and inner_tag != .identifier and inner_tag != .member_expr and inner_tag != .computed_member_expr) {
                        try p.emitError("Invalid destructuring target");
                        return error.ParseError;
                    }
                }
                // Literals, compound assignments are invalid targets.
                // TypeScript's parser accepts literals in array patterns (type errors, not syntax errors).
                if (!p.is_ts and (child_tag == .number_literal or child_tag == .string_literal or
                    child_tag == .boolean_literal or child_tag == .null_literal))
                {
                    try p.emitError("Invalid destructuring target");
                    return error.ParseError;
                }
                if (child_tag == .add_assign or child_tag == .sub_assign or
                    child_tag == .mul_assign or child_tag == .div_assign or
                    child_tag == .mod_assign or child_tag == .exp_assign or
                    child_tag == .and_assign or child_tag == .or_assign or
                    child_tag == .xor_assign or child_tag == .shl_assign or
                    child_tag == .shr_assign or child_tag == .ushr_assign or
                    child_tag == .logical_and_assign or child_tag == .logical_or_assign or
                    child_tag == .nullish_assign or
                    child_tag == .call_expr or child_tag == .new_expr or
                    child_tag == .this_expr or child_tag == .regex_literal or
                    child_tag == .template_literal or child_tag == .tagged_template or
                    child_tag == .super_expr or child_tag == .class_expr or
                    child_tag == .fn_expr or
                    (!p.is_ts and child_tag == .optional_member_expr) or
                    (!p.is_ts and child_tag == .optional_computed_member_expr) or
                    (!p.is_ts and child_tag == .optional_call_expr) or
                    child_tag == .import_meta or
                    child_tag == .import_expr or
                    child_tag == .sequence_expr)
                {
                    try p.emitError("Invalid destructuring target");
                    return error.ParseError;
                }
                // Strict mode: eval/arguments cannot be destructuring targets.
                if (child_tag == .identifier and p.in_strict) {
                    const ctok = p.node_main_token_ptr[child.toInt()];
                    try p.checkStrictAssignTarget(ctok);
                }
                // Recurse into nested patterns / assignment_pattern defaults.
                if (child_tag == .array_pattern or child_tag == .object_pattern or
                    child_tag == .array_literal or child_tag == .object_literal)
                {
                    try validatePattern(p, child);
                }
                if (child_tag == .assignment_pattern) {
                    const ad = p.node_data_ptr[child.toInt()];
                    try validatePattern(p, ad.lhs);
                }
            }
        }
    }

    if (tag == .object_pattern) {
        const data = p.node_data_ptr[effective_node.toInt()];
        const start = data.lhs.toInt();
        const end = data.rhs.toInt();
        var i = start;
        while (i < end) : (i += 1) {
            const prop = NodeIndex.fromInt(p.extra_data.items[i]);
            if (prop == .none) continue;
            const prop_tag = p.node_tags_ptr[prop.toInt()];
            // Strict-mode shorthand `{eval=0}` / `{arguments=0}` rewritten to assignment_pattern.
            if (prop_tag == .assignment_pattern and p.in_strict) {
                const ap = p.node_data_ptr[prop.toInt()];
                if (ap.lhs != .none and p.node_tags_ptr[ap.lhs.toInt()] == .identifier) {
                    const tt = p.node_main_token_ptr[ap.lhs.toInt()];
                    try p.checkStrictAssignTarget(tt);
                }
            }
            // Getter/setter/method definitions are not valid in destructuring patterns
            if (prop_tag == .getter_def or prop_tag == .setter_def or prop_tag == .method_def or
                prop_tag == .computed_method_def or prop_tag == .computed_getter_def or
                prop_tag == .computed_setter_def)
            {
                try p.emitError("Invalid destructuring target: method definition in pattern");
                return error.ParseError;
            }
            // Rest must be last in object pattern. In TS, we still reject trailing
            // commas (sentinel .none after rest), but allow actual elements after rest.
            if (prop_tag == .rest_element) {
                const obj_has_after = blk: {
                    var has = false;
                    var jj = i + 1;
                    while (jj < end) : (jj += 1) {
                        if (NodeIndex.fromInt(p.extra_data.items[jj]) != .none) has = true;
                    }
                    break :blk has;
                };
                const obj_trailing_comma = i < end - 1 and !obj_has_after;
                if (obj_trailing_comma or (!p.is_ts and i < end - 1)) {
                    try p.emitError("Rest element must be last in destructuring pattern");
                    return error.ParseError;
                }
                // Object rest target: must be a simple assignment target.
                const rest_data = p.node_data_ptr[prop.toInt()];
                if (rest_data.lhs != .none) {
                    const target_tag = p.node_tags_ptr[rest_data.lhs.toInt()];
                    switch (target_tag) {
                        .identifier, .member_expr, .computed_member_expr => {},
                        .optional_member_expr, .optional_computed_member_expr,
                        .optional_call_expr => {
                            if (!p.is_ts) {
                                try p.emitError("Invalid rest element target in object pattern");
                                return error.ParseError;
                            }
                        },
                        .grouping_expr => {
                            const inner = unwrapGroupingTag(p, rest_data.lhs);
                            if (!p.is_ts and inner != .identifier and inner != .member_expr and inner != .computed_member_expr) {
                                try p.emitError("Invalid rest element target in object pattern");
                                return error.ParseError;
                            }
                        },
                        else => {
                            if (!p.is_ts) {
                                try p.emitError("Invalid rest element target in object pattern");
                                return error.ParseError;
                            }
                        },
                    }
                }
            }
            // Check property values for invalid targets
            if (prop_tag == .property) {
                const prop_data = p.node_data_ptr[prop.toInt()];
                if (prop_data.rhs != .none) {
                    const val_tag = p.node_tags_ptr[prop_data.rhs.toInt()];
                    // Parenthesized simple targets valid: ({a:(b)} = 1)
                    if (val_tag == .grouping_expr) {
                        const inner_val_tag = unwrapGroupingTag(p, prop_data.rhs);
                        // TypeScript: (e satisfies T) and (e as T) are valid property pattern targets.
                        const ts_val_ok = p.is_ts and (inner_val_tag == .ts_satisfies_expr or inner_val_tag == .ts_as_expr);
                        if (!ts_val_ok and inner_val_tag != .identifier and inner_val_tag != .member_expr and inner_val_tag != .computed_member_expr) {
                            try p.emitError("Invalid destructuring target");
                            return error.ParseError;
                        }
                    } else if (val_tag == .this_expr or
                        val_tag == .number_literal or val_tag == .string_literal or
                        val_tag == .boolean_literal or val_tag == .null_literal or
                        val_tag == .add_assign or val_tag == .sub_assign or
                        val_tag == .mul_assign or val_tag == .div_assign or
                        val_tag == .mod_assign or val_tag == .exp_assign or
                        val_tag == .and_assign or val_tag == .or_assign or
                        val_tag == .xor_assign or val_tag == .shl_assign or
                        val_tag == .shr_assign or val_tag == .ushr_assign or
                        val_tag == .logical_and_assign or val_tag == .logical_or_assign or
                        val_tag == .nullish_assign or
                        val_tag == .call_expr or val_tag == .new_expr or
                        val_tag == .regex_literal or val_tag == .template_literal or
                        val_tag == .tagged_template or val_tag == .super_expr or
                        val_tag == .class_expr or val_tag == .fn_expr or
                        (!p.is_ts and (val_tag == .optional_member_expr or
                        val_tag == .optional_computed_member_expr or
                        val_tag == .optional_call_expr)) or
                        val_tag == .import_meta or
                        val_tag == .import_expr or
                        val_tag == .sequence_expr)
                    {
                        try p.emitError("Invalid destructuring target");
                        return error.ParseError;
                    }
                    // Strict mode: eval/arguments cannot be destructuring targets
                    if (val_tag == .identifier and p.in_strict) {
                        const val_tok = p.node_main_token_ptr[prop_data.rhs.toInt()];
                        try p.checkStrictAssignTarget(val_tok);
                    }
                    // Recursively validate nested patterns
                    try validatePattern(p, prop_data.rhs);
                }
            }
            // Shorthand with numeric/string key
            if (prop_tag == .number_literal or prop_tag == .string_literal) {
                try p.emitError("Invalid shorthand property in destructuring");
                return error.ParseError;
            }
            // Shorthand property with non-identifier key (e.g. {0}, {'a'})
            if (prop_tag == .shorthand_property) {
                const sp_data = p.node_data_ptr[prop.toInt()];
                if (sp_data.lhs != .none) {
                    var sp_lhs = sp_data.lhs;
                    var sp_key_tag = p.node_tags_ptr[sp_lhs.toInt()];
                    // Drill through assignment_pattern: `{eval = 0}` shorthand-with-default.
                    if (sp_key_tag == .assignment_pattern) {
                        const ap_data = p.node_data_ptr[sp_lhs.toInt()];
                        sp_lhs = ap_data.lhs;
                        if (sp_lhs == .none) continue;
                        sp_key_tag = p.node_tags_ptr[sp_lhs.toInt()];
                    }
                    if (sp_key_tag == .number_literal or sp_key_tag == .string_literal) {
                        try p.emitError("Invalid shorthand property in destructuring");
                        return error.ParseError;
                    }
                    // Strict mode: shorthand `{eval}` / `{arguments}` invalid.
                    // Module/strict: `{yield}` is reserved.
                    if (sp_key_tag == .identifier) {
                        const sp_tok = p.node_main_token_ptr[sp_lhs.toInt()];
                        if (p.in_strict or p.is_ts) try p.checkStrictAssignTarget(sp_tok);
                        const sp_text = p.tokenText(sp_tok);
                        if ((p.in_strict or p.is_module) and std.mem.eql(u8, sp_text, "yield")) {
                            try p.emitError("'yield' is reserved");
                            return error.ParseError;
                        }
                        // Escaped reserved words in shorthand destructuring: {var}={}, {public}={} (strict).
                        // Covers .escaped_keyword (resolves to a true keyword) and .identifier with \u
                        // escapes resolving to a strict-reserved word (public/private/protected/etc.).
                        if (std.mem.indexOf(u8, sp_text, "\\") != null or
                            p.tokenTagAt(sp_tok) == .escaped_keyword)
                        {
                            var resolved_buf_esc: [256]u8 = undefined;
                            if (parser_mod.resolveUnicodeEscapesParser(sp_text, &resolved_buf_esc)) |resolved| {
                                if (parser_mod.isAlwaysReservedStr(resolved) or
                                    (p.in_strict and parser_mod.Parser.isStrictReservedStr(resolved)) or
                                    (std.mem.eql(u8, resolved, "yield") and (p.in_generator or p.in_strict)) or
                                    (std.mem.eql(u8, resolved, "await") and
                                        (p.in_async or p.is_module or (p.in_static_block and !p.in_function))))
                                {
                                    try p.emitError("Escaped reserved word cannot be used as an identifier in a destructuring pattern");
                                    return error.ParseError;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ── Strict mode checks ───────────────────────────────────────────────

/// Recursively validate arrow parameter — reject member expressions, literals, etc. deep in patterns.
/// Recursively check if any node in the subtree refers to `await` as an
/// identifier. Used to reject `await` inside async-arrow parameter defaults
/// (where the cover grammar parses await as an identifier ref).
/// In v-mode character classes:
/// - ClassSyntaxCharacters (`(`, `)`, `[`, `{`, `}`, `/`, `-`, `|`) must be
///   escaped (closes 8 breaking-change-from-u-to-v tests).
/// - Reserved double punctuators (`&&`, `!!`, `##`, `$$`, `%%`, `**`, `++`,
///   `,,`, `..`, `::`, `;;`, `<<`, `==`, `>>`, `??`, `@@`, `^^`, `\`\``, `~~`)
///   are reserved as set operators / invalid (closes ~6 tests).
fn validateRegexVFlagClassExtras(p: *Parser, body: []const u8) Error!void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) { i += 2; continue; }
        if (c != '[') { i += 1; continue; }
        try validateRegexVFlagClass(p, body, &i);
    }
}

fn validateRegexVFlagClass(p: *Parser, body: []const u8, i_ptr: *usize) Error!void {
    var i = i_ptr.*;
    i += 1; // consume '['
    const negated = (i < body.len and body[i] == '^');
    if (negated) i += 1;
    var prev_punct: u8 = 0;
    var atom_count: u32 = 0; // count of atoms seen at this nesting level
    while (i < body.len and body[i] != ']') {
        const ch = body[i];
        if (ch == '\\' and i + 1 < body.len) {
            const e = body[i + 1];
            // Property-of-strings inside negated class is invalid.
            if (negated and (e == 'p' or e == 'P') and i + 2 < body.len and body[i + 2] == '{') {
                const upro = @import("unicode_props.zig");
                const name_start = i + 3;
                var k = name_start;
                var has_eq = false;
                while (k < body.len and body[k] != '}') : (k += 1) {
                    if (body[k] == '=') has_eq = true;
                }
                if (k < body.len and !has_eq) {
                    if (upro.isBinaryPropertyOfStrings(body[name_start..k])) {
                        try p.emitError("Property-of-strings cannot appear in negated v-mode character class");
                        return error.ParseError;
                    }
                }
            }
            i += 2;
            // For \p{...}, \P{...}, \q{...}, \u{...} skip past the brace
            // body — these wrap a name / codepoint hex and the inner `{`/`}`
            // are NOT class-syntax punctuation.  Same for \k<name>.
            if ((e == 'p' or e == 'P' or e == 'q' or e == 'u') and i < body.len and body[i] == '{') {
                i += 1;
                while (i < body.len and body[i] != '}') : (i += 1) {}
                if (i < body.len) i += 1;
            } else if (e == 'k' and i < body.len and body[i] == '<') {
                i += 1;
                while (i < body.len and body[i] != '>') : (i += 1) {}
                if (i < body.len) i += 1;
            }
            prev_punct = 0;
            atom_count += 1;
            continue;
        }
        if (ch == '[') {
            try validateRegexVFlagClass(p, body, &i);
            prev_punct = 0;
            atom_count += 1;
            continue;
        }
        // Reserved double punctuator check (excludes && and --).
        if (ch == prev_punct and isReservedDoublePunctuator(ch)) {
            try p.emitError("Reserved double-punctuator in v-mode character class");
            return error.ParseError;
        }
        // && and -- are set operators. They must have non-empty operands
        // on both sides. `[&&...]` (empty left) or `[...&&]` (empty right)
        // is invalid.
        if (ch == prev_punct and (ch == '&' or ch == '-')) {
            // Check left operand: there must have been at least one atom
            // before the operator. atom_count is incremented after each
            // atom; the previous char (the first &/-) was just punct.
            // We require atom_count >= 1 here.
            if (atom_count == 0) {
                try p.emitError("Set operator at start of v-mode character class");
                return error.ParseError;
            }
            // Check right operand by peeking past the operator.
            i += 1;
            var rp = i;
            while (rp < body.len and (body[rp] == ' ' or body[rp] == '\t')) : (rp += 1) {}
            if (rp >= body.len or body[rp] == ']') {
                try p.emitError("Set operator with empty right operand in v-mode character class");
                return error.ParseError;
            }
            prev_punct = 0;
            continue;
        }
        prev_punct = ch;
        // Class syntax characters that must be escaped in v-mode.
        switch (ch) {
            '(', ')', '{', '}', '/', '|' => {
                try p.emitError("Unescaped class syntax character in v-mode character class");
                return error.ParseError;
            },
            '-' => {
                // `-` between two ClassSetCharacters is a range; standalone is invalid.
                // Heuristic: if no atom preceded OR next char is `]`, error.
                const next_idx = i + 1;
                if (atom_count == 0 or (next_idx < body.len and body[next_idx] == ']')) {
                    try p.emitError("Unescaped '-' must form a range in v-mode character class");
                    return error.ParseError;
                }
            },
            else => {},
        }
        i += 1;
        atom_count += 1;
    }
    if (i >= body.len) {
        // Outer `[` was never closed — in v-mode this is a SyntaxError because
        // nested class syntax gives `[` a special meaning that requires matching `]`.
        try p.emitError("Unterminated character class in v-mode regular expression");
        return error.ParseError;
    }
    i += 1; // consume ]
    i_ptr.* = i;
}

fn isReservedDoublePunctuator(c: u8) bool {
    // Per ECMA-262: reserved doublings excluding && (intersection) and -- (difference).
    return switch (c) {
        '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`', '~' => true,
        else => false,
    };
}

/// Validate a regex body in u/v (Unicode) mode. Returns SyntaxError on:
/// - Invalid IdentityEscape: `\X` where X is not a SyntaxCharacter, /, or ASCII-letter
///   that's a recognized escape (digits handled separately).
/// - Invalid `\u{...}`: must contain only hex digits.
/// - Legacy octal escape: `\1` etc. (unless valid back-reference, deferred).
/// - `\u` followed by non-hex.
/// Scan a regex body for modifier-group syntax `(?<flags>:...)` and
/// `(?<add>-<remove>:...)`. Validate per spec:
/// - Flags must be from {i, m, s}
/// - No duplicates within add or remove
/// - No overlap between add and remove
/// - Must end with `:`
/// - Add and remove cannot both be empty
/// Distinguishes from other `(?...)` constructs (lookarounds, named groups).
fn validateRegexModifierGroups(p: *Parser, body: []const u8) Error!void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) { i += 2; continue; }
        if (c == '[') {
            // Skip character class — no groups inside.
            i += 1;
            while (i < body.len) : (i += 1) {
                if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                if (body[i] == ']') { i += 1; break; }
            }
            continue;
        }
        if (c != '(' or i + 1 >= body.len or body[i + 1] != '?') {
            i += 1;
            continue;
        }
        // `(?` — what follows determines kind.
        const k = i + 2;
        if (k >= body.len) { i += 1; continue; }
        const k0 = body[k];
        // Skip non-modifier group kinds.
        if (k0 == ':' or k0 == '=' or k0 == '!' or k0 == '<') {
            i += 1;
            continue;
        }
        // Otherwise treat as modifier group: scan flags, optional `-flags`, expect `:`.
        var add_seen: [128]bool = @splat(false);
        var rem_seen: [128]bool = @splat(false);
        var add_count: u32 = 0;
        var rem_count: u32 = 0;
        var j = k;
        while (j < body.len) : (j += 1) {
            const ch = body[j];
            if (ch == '-' or ch == ':' or ch == ')') break;
            switch (ch) {
                'i', 'm', 's' => {},
                else => {
                    try p.emitError("Invalid flag in regex modifier group");
                    return error.ParseError;
                },
            }
            if (add_seen[ch]) {
                try p.emitError("Duplicate flag in regex modifier group");
                return error.ParseError;
            }
            add_seen[ch] = true;
            add_count += 1;
        }
        if (j < body.len and body[j] == '-') {
            j += 1;
            while (j < body.len) : (j += 1) {
                const ch = body[j];
                if (ch == ':' or ch == ')') break;
                switch (ch) {
                    'i', 'm', 's' => {},
                    else => {
                        try p.emitError("Invalid flag in regex modifier group");
                        return error.ParseError;
                    },
                }
                if (rem_seen[ch]) {
                    try p.emitError("Duplicate flag in regex modifier group");
                    return error.ParseError;
                }
                if (add_seen[ch]) {
                    try p.emitError("Flag appears in both add and remove of regex modifier");
                    return error.ParseError;
                }
                rem_seen[ch] = true;
                rem_count += 1;
            }
        }
        // Must be followed by `:`
        if (j >= body.len or body[j] != ':') {
            try p.emitError("Regex modifier group must be followed by ':'");
            return error.ParseError;
        }
        // Spec: both add and remove cannot be empty.
        if (add_count == 0 and rem_count == 0) {
            try p.emitError("Regex modifier group must have at least one flag");
            return error.ParseError;
        }
        i = j + 1;
    }
}

/// Validate a single regex group name — content between `<` and `>` of
/// `(?<NAME>...)` or `\k<NAME>`. Returns the index past the closing `>`.
/// Errors if the name is empty, malformed, or unterminated.
fn validateRegexGroupName(p: *Parser, body: []const u8, start: usize) Error!usize {
    const uid = @import("unicode_id.zig");
    var i = start;
    var first = true;
    var saw_any = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '>') {
            if (!saw_any) {
                try p.emitError("Empty regex group name");
                return error.ParseError;
            }
            return i + 1;
        }
        // Escape sequence: only `\u` or `\u{...}` allowed in identifier.
        if (c == '\\') {
            if (i + 1 >= body.len or body[i + 1] != 'u') {
                try p.emitError("Invalid character in regex group name");
                return error.ParseError;
            }
            i += 1; // 'u'
            // Read codepoint to validate ID_Start / ID_Continue.
            var cp: u32 = 0;
            if (i + 1 < body.len and body[i + 1] == '{') {
                i += 2;
                const cp_start = i;
                while (i < body.len and body[i] != '}') : (i += 1) {}
                if (i >= body.len) {
                    try p.emitError("Unterminated regex group name");
                    return error.ParseError;
                }
                cp = std.fmt.parseInt(u32, body[cp_start..i], 16) catch 0xFFFFFFFF;
                // i now points at '}'; loop's i+=1 advances past it.
            } else {
                if (i + 4 >= body.len) {
                    try p.emitError("Unterminated regex group name");
                    return error.ParseError;
                }
                cp = std.fmt.parseInt(u32, body[i + 1 .. i + 5], 16) catch 0xFFFFFFFF;
                i += 4;
                // Surrogate pair: \uHHHH\uLLLL — combine into single codepoint.
                if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 < body.len and
                    body[i + 1] == '\\' and body[i + 2] == 'u' and body[i + 3] != '{')
                {
                    const lo = std.fmt.parseInt(u32, body[i + 3 .. i + 7], 16) catch 0;
                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }
                }
            }
            const ok = if (first) uid.isIdStart(cp) or cp == '$' or cp == '_'
                else uid.isIdContinueJS(cp) or cp == '$';
            if (!ok) {
                try p.emitError(if (first)
                    "Invalid first character in regex group name"
                else
                    "Invalid character in regex group name");
                return error.ParseError;
            }
            saw_any = true;
            first = false;
            continue;
        }
        if (c >= 0x80) {
            // Decode UTF-8 codepoint and validate against ID tables.
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            if (i + len > body.len) {
                try p.emitError("Unterminated regex group name");
                return error.ParseError;
            }
            const cp_u21 = std.unicode.utf8Decode(body[i .. i + len]) catch 0;
            const cp: u32 = @intCast(cp_u21);
            const ok = if (first) uid.isIdStart(cp)
                else uid.isIdContinueJS(cp);
            if (!ok) {
                try p.emitError(if (first)
                    "Invalid first character in regex group name"
                else
                    "Invalid character in regex group name");
                return error.ParseError;
            }
            // Advance past full UTF-8 sequence; loop's i+=1 advances by 1 more, so adjust.
            i += len - 1;
            saw_any = true;
            first = false;
            continue;
        }
        const is_letter = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        const is_digit = (c >= '0' and c <= '9');
        const is_id_start = is_letter or c == '$' or c == '_';
        const is_id_continue = is_id_start or is_digit;
        if (first) {
            if (!is_id_start) {
                try p.emitError("Invalid first character in regex group name");
                return error.ParseError;
            }
        } else {
            if (!is_id_continue) {
                try p.emitError("Invalid character in regex group name");
                return error.ParseError;
            }
        }
        saw_any = true;
        first = false;
    }
    try p.emitError("Unterminated regex group name");
    return error.ParseError;
}

fn validateRegexNamedGroups(p: *Parser, body: []const u8, is_unicode: bool) Error!void {
    // Pass 1: validate (?<NAME>...) syntax and collect names.
    // Per ES2025: duplicate names ARE allowed if in different alternation
    // branches. Without full pattern parsing, we only flag duplicates when
    // no `|` exists in the pattern.
    var names_buf: [256][]const u8 = undefined;
    var names_count: usize = 0;
    var has_alternation = false;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) { i += 2; continue; }
        if (c == '[') {
            i += 1;
            while (i < body.len) : (i += 1) {
                if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                if (body[i] == ']') { i += 1; break; }
            }
            continue;
        }
        if (c == '|') { has_alternation = true; i += 1; continue; }
        if (c != '(' or i + 2 >= body.len or body[i + 1] != '?' or body[i + 2] != '<') {
            i += 1;
            continue;
        }
        if (i + 3 < body.len and (body[i + 3] == '=' or body[i + 3] == '!')) {
            i += 4;
            continue;
        }
        const name_start = i + 3;
        const name_end = try validateRegexGroupName(p, body, name_start);
        const name = body[name_start .. name_end - 1];
        if (!has_alternation) {
            var d: usize = 0;
            while (d < names_count) : (d += 1) {
                if (std.mem.eql(u8, names_buf[d], name)) {
                    try p.emitError("Duplicate regex group name");
                    return error.ParseError;
                }
            }
        }
        if (names_count < names_buf.len) {
            names_buf[names_count] = name;
            names_count += 1;
        }
        i = name_end;
    }
    // Pass 2: validate \k<NAME> references.
    // In u/v mode, \k followed by `<` is always a named back-reference,
    // and the referenced name must exist. In non-u mode, when no named
    // groups exist, `\k` is treated as literal escape sequence (AnnexB).
    if (names_count == 0 and !is_unicode) return;
    i = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '[') {
            i += 1;
            while (i < body.len) : (i += 1) {
                if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                if (body[i] == ']') { i += 1; break; }
            }
            continue;
        }
        if (c != '\\' or i + 1 >= body.len) { i += 1; continue; }
        if (body[i + 1] != 'k') { i += 2; continue; }
        if (i + 2 >= body.len or body[i + 2] != '<') {
            try p.emitError("Invalid named back-reference: '\\k' must be followed by '<NAME>'");
            return error.ParseError;
        }
        const ref_start = i + 3;
        const ref_end = try validateRegexGroupName(p, body, ref_start);
        const ref_name = body[ref_start .. ref_end - 1];
        var found = false;
        var n: usize = 0;
        while (n < names_count) : (n += 1) {
            if (std.mem.eql(u8, names_buf[n], ref_name)) { found = true; break; }
        }
        if (!found) {
            try p.emitError("Reference to undefined regex group name");
            return error.ParseError;
        }
        i = ref_end;
    }
}

/// In u/v mode, class ranges X-Y cannot have class-escape (\\d, \\D, \\s, \\S,
/// \\w, \\W) or property-escape (\\p{...}) on either side.
fn validateRegexClassRangesUnicode(p: *Parser, body: []const u8) Error!void {
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '\\' and i + 1 < body.len) { i += 2; continue; }
        if (body[i] != '[') { i += 1; continue; }
        i += 1;
        // Walk character class. Track each "atom" — single char or class-escape.
        // ClassEscape := \d \D \s \S \w \W \p{...} \P{...}
        // When we see `atom1 - atom2`, if either is class-escape, error.
        // We track is_class_escape flag for the most recent atom.
        var prev_is_class_escape = false;
        var pending_dash = false;
        while (i < body.len and body[i] != ']') {
            const ch = body[i];
            var atom_is_class_escape = false;
            if (ch == '\\' and i + 1 < body.len) {
                const e = body[i + 1];
                switch (e) {
                    'd', 'D', 's', 'S', 'w', 'W' => atom_is_class_escape = true,
                    'p', 'P' => {
                        atom_is_class_escape = true;
                        // skip `\p{...}` body
                        i += 2;
                        if (i < body.len and body[i] == '{') {
                            i += 1;
                            while (i < body.len and body[i] != '}') : (i += 1) {}
                            if (i < body.len) i += 1;
                        }
                        if (pending_dash) {
                            try p.emitError("Invalid character class range in regular expression with u/v flag");
                            return error.ParseError;
                        }
                        prev_is_class_escape = atom_is_class_escape;
                        pending_dash = false;
                        continue;
                    },
                    'q' => {
                        // \q{...} v-flag string literal
                        i += 2;
                        if (i < body.len and body[i] == '{') {
                            i += 1;
                            var qd: u32 = 1;
                            while (i < body.len and qd > 0) : (i += 1) {
                                if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                                if (body[i] == '{') qd += 1
                                else if (body[i] == '}') qd -= 1;
                            }
                        }
                        prev_is_class_escape = false;
                        pending_dash = false;
                        continue;
                    },
                    else => {},
                }
                if (pending_dash and atom_is_class_escape) {
                    try p.emitError("Invalid character class range in regular expression with u/v flag");
                    return error.ParseError;
                }
                i += 2;
                prev_is_class_escape = atom_is_class_escape;
                pending_dash = false;
                continue;
            }
            if (ch == '[') {
                // Nested class (v-flag). Recurse-like: find matching ]. Skip.
                var depth: u32 = 1;
                i += 1;
                while (i < body.len and depth > 0) : (i += 1) {
                    if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                    if (body[i] == '[') depth += 1
                    else if (body[i] == ']') depth -= 1;
                }
                prev_is_class_escape = false;
                pending_dash = false;
                continue;
            }
            if (ch == '-') {
                if (prev_is_class_escape) {
                    try p.emitError("Invalid character class range in regular expression with u/v flag");
                    return error.ParseError;
                }
                pending_dash = true;
                i += 1;
                continue;
            }
            // Plain char.
            if (pending_dash) pending_dash = false;
            prev_is_class_escape = false;
            i += 1;
        }
        if (i < body.len) i += 1; // consume ]
    }
}

/// Reject quantifier (?, *, +, {N,M}) as the first atom of a Disjunction
/// alternative — i.e. at the start of the regex, immediately after `(`,
/// or immediately after `|`. There's no atom to quantify in those positions.
fn validateRegexBalancedGroups(p: *Parser, body: []const u8) Error!void {
    var i: usize = 0;
    var depth: i32 = 0;
    var in_class = false;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\') { i += 2; continue; }
        if (in_class) {
            if (c == ']') in_class = false;
            i += 1;
            continue;
        }
        if (c == '[') { in_class = true; i += 1; continue; }
        if (c == '(') { depth += 1; i += 1; continue; }
        if (c == ')') {
            depth -= 1;
            if (depth < 0) {
                try p.emitError("Unmatched ')' in regular expression");
                return error.ParseError;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    if (depth > 0) {
        try p.emitError("Unterminated group in regular expression");
        return error.ParseError;
    }
}

fn validateRegexNoLeadingQuantifier(p: *Parser, body: []const u8) Error!void {
    if (body.len == 0) return;
    var i: usize = 0;
    var prev_is_atom_start = true; // start of pattern
    while (i < body.len) {
        const c = body[i];
        if (prev_is_atom_start) {
            if (c == '?' or c == '*' or c == '+' or c == '{') {
                // For `{`, only reject if it forms a valid quantifier syntax.
                // Otherwise the `{` may be a literal (Annex B extension).
                if (c == '{') {
                    var k = i + 1;
                    const sk = k;
                    while (k < body.len and body[k] >= '0' and body[k] <= '9') : (k += 1) {}
                    var is_quant = false;
                    if (k > sk and k < body.len) {
                        if (body[k] == '}') is_quant = true
                        else if (body[k] == ',') {
                            k += 1;
                            while (k < body.len and body[k] >= '0' and body[k] <= '9') : (k += 1) {}
                            if (k < body.len and body[k] == '}') is_quant = true;
                        }
                    }
                    if (!is_quant) {
                        prev_is_atom_start = false;
                        i += 1;
                        continue;
                    }
                }
                try p.emitError("Nothing to repeat in regular expression");
                return error.ParseError;
            }
        }
        if (c == '\\' and i + 1 < body.len) {
            i += 2;
            prev_is_atom_start = false;
            continue;
        }
        if (c == '[') {
            i += 1;
            while (i < body.len) : (i += 1) {
                if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                if (body[i] == ']') { i += 1; break; }
            }
            prev_is_atom_start = false;
            continue;
        }
        if (c == '(') {
            i += 1;
            // Skip past `(?...` group prefixes so they don't look like quantifiers.
            if (i < body.len and body[i] == '?') {
                i += 1;
                if (i < body.len) {
                    const k0 = body[i];
                    if (k0 == ':' or k0 == '=' or k0 == '!') {
                        i += 1;
                    } else if (k0 == '<') {
                        i += 1;
                        if (i < body.len and (body[i] == '=' or body[i] == '!')) {
                            i += 1;
                        } else {
                            // Named group: skip until `>` (or end).
                            while (i < body.len and body[i] != '>') : (i += 1) {}
                            if (i < body.len) i += 1;
                        }
                    } else {
                        // Modifier group: skip until `:` (or `)` for empty).
                        while (i < body.len and body[i] != ':' and body[i] != ')') : (i += 1) {}
                        if (i < body.len and body[i] == ':') i += 1;
                    }
                }
            }
            prev_is_atom_start = true;
            continue;
        }
        if (c == '|') { prev_is_atom_start = true; i += 1; continue; }
        prev_is_atom_start = false;
        i += 1;
    }
}

/// Lookbehind groups (?<=...) (?<!...) cannot be quantified in any mode.
fn validateRegexLookbehindQuant(p: *Parser, body: []const u8) Error!void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) { i += 2; continue; }
        if (c == '[') {
            i += 1;
            while (i < body.len) : (i += 1) {
                if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                if (body[i] == ']') { i += 1; break; }
            }
            continue;
        }
        if (c != '(' or i + 3 >= body.len or body[i + 1] != '?' or
            body[i + 2] != '<' or (body[i + 3] != '=' and body[i + 3] != '!'))
        {
            i += 1;
            continue;
        }
        // Lookbehind: find matching ).
        var depth: u32 = 1;
        var j = i + 4;
        while (j < body.len) : (j += 1) {
            const ch = body[j];
            if (ch == '\\' and j + 1 < body.len) { j += 1; continue; }
            if (ch == '[') {
                j += 1;
                while (j < body.len) : (j += 1) {
                    if (body[j] == '\\' and j + 1 < body.len) { j += 1; continue; }
                    if (body[j] == ']') break;
                }
                continue;
            }
            if (ch == '(') depth += 1
            else if (ch == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (j >= body.len) { i += 1; continue; }
        const next_idx = j + 1;
        if (next_idx < body.len) {
            const nc = body[next_idx];
            if (nc == '?' or nc == '*' or nc == '+' or nc == '{') {
                try p.emitError("Lookbehind group cannot be quantified");
                return error.ParseError;
            }
        }
        i = next_idx;
    }
}

/// In u/v mode, lookahead/lookbehind groups cannot be quantified. Find each
/// `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)` and ensure no quantifier
/// follows the closing `)`.
fn validateRegexLookaroundUnicode(p: *Parser, body: []const u8) Error!void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) { i += 2; continue; }
        if (c == '[') {
            i += 1;
            while (i < body.len) : (i += 1) {
                if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                if (body[i] == ']') { i += 1; break; }
            }
            continue;
        }
        if (c != '(' or i + 2 >= body.len or body[i + 1] != '?') {
            i += 1;
            continue;
        }
        const k = body[i + 2];
        var is_lookaround = false;
        var skip: usize = 3;
        if (k == '=' or k == '!') {
            is_lookaround = true;
        } else if (k == '<' and i + 3 < body.len and (body[i + 3] == '=' or body[i + 3] == '!')) {
            is_lookaround = true;
            skip = 4;
        }
        if (!is_lookaround) {
            i += 1;
            continue;
        }
        // Find matching close paren.
        var depth: u32 = 1;
        var j = i + skip;
        while (j < body.len) : (j += 1) {
            const ch = body[j];
            if (ch == '\\' and j + 1 < body.len) { j += 1; continue; }
            if (ch == '[') {
                j += 1;
                while (j < body.len) : (j += 1) {
                    if (body[j] == '\\' and j + 1 < body.len) { j += 1; continue; }
                    if (body[j] == ']') break;
                }
                continue;
            }
            if (ch == '(') depth += 1
            else if (ch == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (j >= body.len) { i += 1; continue; }
        // Check next char.
        const next_idx = j + 1;
        if (next_idx < body.len) {
            const nc = body[next_idx];
            if (nc == '?' or nc == '*' or nc == '+' or nc == '{') {
                try p.emitError("Lookaround group cannot be quantified in u/v-mode regex");
                return error.ParseError;
            }
        }
        i = next_idx;
    }
}

fn validateRegexBodyUnicode(p: *Parser, body: []const u8, v_mode: bool) Error!void {
    // First count the number of capturing groups (ignoring (?:...), (?=...) etc.).
    var group_count: u32 = 0;
    {
        var j: usize = 0;
        var class_d2: u32 = 0;
        while (j < body.len) : (j += 1) {
            const ch = body[j];
            if (ch == '\\' and j + 1 < body.len) { j += 1; continue; }
            if (ch == '[') { class_d2 += 1; continue; }
            if (ch == ']') { if (class_d2 > 0) class_d2 -= 1; continue; }
            if (class_d2 > 0) continue;
            if (ch != '(') continue;
            // Capturing group unless followed by `?` (any non-capture form except (?<NAME>...)).
            if (j + 1 < body.len and body[j + 1] == '?') {
                if (j + 2 < body.len and body[j + 2] == '<' and
                    j + 3 < body.len and body[j + 3] != '=' and body[j + 3] != '!')
                {
                    group_count += 1; // named capturing group
                }
                continue;
            }
            group_count += 1;
        }
    }
    var i: usize = 0;
    var class_depth: u32 = 0; // v-flag allows nested `[[ ... ]]`
    while (i < body.len) {
        // Outside character class, validate `{` quantifier syntax.
        if (class_depth == 0 and body[i] == '{') {
            // Quantifier: {N}, {N,}, {N,M}
            var k = i + 1;
            const start_k = k;
            while (k < body.len and body[k] >= '0' and body[k] <= '9') : (k += 1) {}
            const ok_first = (k > start_k);
            if (ok_first and k < body.len and body[k] == '}') {
                i = k + 1;
                continue;
            }
            if (ok_first and k < body.len and body[k] == ',') {
                k += 1;
                while (k < body.len and body[k] >= '0' and body[k] <= '9') : (k += 1) {}
                if (k < body.len and body[k] == '}') {
                    i = k + 1;
                    continue;
                }
            }
            try p.emitError("Invalid '{' in regular expression with u/v flag");
            return error.ParseError;
        }
        if (class_depth == 0 and body[i] == '}') {
            try p.emitError("Invalid '}' in regular expression with u/v flag");
            return error.ParseError;
        }
        const c = body[i];
        if (c == '[') { class_depth += 1; i += 1; continue; }
        if (c == ']') { if (class_depth > 0) class_depth -= 1; i += 1; continue; }
        if (c != '\\') { i += 1; continue; }
        // Backslash escape.
        i += 1;
        if (i >= body.len) {
            try p.emitError("Invalid regular expression: trailing backslash");
            return error.ParseError;
        }
        const esc = body[i];
        switch (esc) {
            'f', 'n', 'r', 't', 'v' => i += 1,
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/', '-' => i += 1,
            'd', 'D', 's', 'S', 'w', 'W' => i += 1,
            'p', 'P' => {
                const is_negated = (esc == 'P');
                i += 1;
                if (i >= body.len or body[i] != '{') {
                    try p.emitError("Property escape '\\p' must be followed by '{'");
                    return error.ParseError;
                }
                i += 1;
                const name_start = i;
                var eq_pos: ?usize = null;
                while (i < body.len and body[i] != '}') : (i += 1) {
                    if (body[i] == '=' and eq_pos == null) eq_pos = i;
                }
                if (i >= body.len) {
                    try p.emitError("Unterminated property escape in regular expression");
                    return error.ParseError;
                }
                const upro = @import("unicode_props.zig");
                const name = if (eq_pos) |ep| body[name_start..ep] else body[name_start..i];
                const value: ?[]const u8 = if (eq_pos) |ep| body[ep + 1 .. i] else null;
                if (!upro.isValidPropertyRef(name, value, v_mode)) {
                    try p.emitError("Invalid property name in regular expression");
                    return error.ParseError;
                }
                // Property-of-strings can only be used with \p (positive), not \P.
                if (is_negated and v_mode and value == null and
                    upro.isBinaryPropertyOfStrings(name))
                {
                    try p.emitError("Property-of-strings cannot be negated with '\\P'");
                    return error.ParseError;
                }
                i += 1; // consume '}'
            },
            'k' => {
                i += 1;
                if (i < body.len and body[i] == '<') {
                    i += 1;
                    while (i < body.len and body[i] != '>') : (i += 1) {}
                    if (i < body.len) i += 1;
                }
            },
            // \q{...} — v-flag string literal (only inside character class)
            'q' => {
                i += 1;
                if (i < body.len and body[i] == '{') {
                    i += 1;
                    var qd: u32 = 1;
                    while (i < body.len and qd > 0) : (i += 1) {
                        if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                        if (body[i] == '{') qd += 1
                        else if (body[i] == '}') qd -= 1;
                    }
                }
            },
            'b', 'B' => i += 1,
            'c' => {
                i += 1;
                if (i >= body.len or !((body[i] >= 'a' and body[i] <= 'z') or (body[i] >= 'A' and body[i] <= 'Z'))) {
                    try p.emitError("Invalid control letter escape in regular expression with u/v flag");
                    return error.ParseError;
                }
                i += 1;
            },
            'x' => {
                i += 1;
                if (i + 2 > body.len or !isHexDigit(body[i]) or !isHexDigit(body[i + 1])) {
                    try p.emitError("Invalid hex escape in regular expression");
                    return error.ParseError;
                }
                i += 2;
            },
            'u' => {
                i += 1;
                if (i < body.len and body[i] == '{') {
                    i += 1;
                    const start = i;
                    while (i < body.len and body[i] != '}') : (i += 1) {
                        if (!isHexDigit(body[i])) {
                            try p.emitError("Invalid unicode escape in regular expression");
                            return error.ParseError;
                        }
                    }
                    if (start == i or i >= body.len) {
                        try p.emitError("Invalid unicode escape in regular expression");
                        return error.ParseError;
                    }
                    // Codepoint must be <= 0x10FFFF.
                    const cp = std.fmt.parseInt(u32, body[start..i], 16) catch 0xFFFFFFFF;
                    if (cp > 0x10FFFF) {
                        try p.emitError("Unicode code point out of range in regular expression");
                        return error.ParseError;
                    }
                    i += 1;
                } else {
                    if (i + 4 > body.len) {
                        try p.emitError("Invalid unicode escape in regular expression");
                        return error.ParseError;
                    }
                    var k: usize = 0;
                    while (k < 4) : (k += 1) {
                        if (!isHexDigit(body[i + k])) {
                            try p.emitError("Invalid unicode escape in regular expression");
                            return error.ParseError;
                        }
                    }
                    i += 4;
                }
            },
            '0' => {
                i += 1;
                if (i < body.len and body[i] >= '0' and body[i] <= '9') {
                    try p.emitError("Invalid decimal escape in regular expression with u/v flag");
                    return error.ParseError;
                }
            },
            '1', '2', '3', '4', '5', '6', '7' => {
                if (class_depth > 0) {
                    try p.emitError("Invalid decimal escape in character class");
                    return error.ParseError;
                }
                const num_start = i;
                i += 1;
                while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
                const ref_n = std.fmt.parseInt(u32, body[num_start..i], 10) catch group_count + 1;
                if (ref_n > group_count) {
                    try p.emitError("Back-reference to non-existent group in regular expression with u/v flag");
                    return error.ParseError;
                }
            },
            '8', '9' => {
                // \8 and \9 are not back-references and not octal; invalid in u/v mode.
                try p.emitError("Invalid decimal escape '\\8' or '\\9' in regular expression with u/v flag");
                return error.ParseError;
            },
            else => {
                // IdentityEscape in u-mode requires SyntaxCharacter or `/` or `-` (in class).
                // ASCII letters/digits/_ are invalid identity escapes outside class.
                if (class_depth == 0 and ((esc >= 'a' and esc <= 'z') or (esc >= 'A' and esc <= 'Z') or esc == '_')) {
                    try p.emitError("Invalid identity escape in regular expression with u/v flag");
                    return error.ParseError;
                }
                i += 1;
            },
        }
    }
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Walk AST and return true if `node` (or any descendant, stopping at function
/// boundaries) has the given tag. Used to detect yield_expr/await_expr in
/// arrow param defaults (ArrowParameters Contains YieldExpression/AwaitExpression).
fn containsNodeTag(p: *Parser, node: NodeIndex, target: ast.Node.Tag) bool {
    if (node == .none) return false;
    const idx = node.toInt();
    if (idx >= p.nodes.len) return false;
    const tag = p.node_tags_ptr[idx];
    if (tag == target) return true;
    switch (tag) {
        // Stop at function/arrow boundaries — they have their own Yield/Await context.
        .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
        .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
        .method_def, .getter_def, .setter_def,
        .arrow_fn, .async_arrow_fn,
        => return false,
        else => {},
    }
    const data = p.node_data_ptr[idx];
    if (containsNodeTag(p, data.lhs, target)) return true;
    switch (tag) {
        .array_literal, .array_pattern, .object_literal, .object_pattern,
        .var_decl, .let_decl, .const_decl, .sequence_expr,
        => {
            var i = data.lhs.toInt();
            while (i < data.rhs.toInt()) : (i += 1) {
                const child = NodeIndex.fromInt(p.extra_data.items[i]);
                if (containsNodeTag(p, child, target)) return true;
            }
            return false;
        },
        // call_expr and optional_call_expr store args via extra_data SubRange.
        // data.lhs = callee (already checked above), data.rhs = extra index to SubRange.
        .call_expr, .optional_call_expr => {
            const range_idx = data.rhs.toInt();
            if (range_idx + 1 < p.extra_data.items.len) {
                const arg_start = p.extra_data.items[range_idx];
                const arg_end = p.extra_data.items[range_idx + 1];
                var i = arg_start;
                while (i < arg_end) : (i += 1) {
                    const arg = NodeIndex.fromInt(p.extra_data.items[i]);
                    if (containsNodeTag(p, arg, target)) return true;
                }
            }
            return false;
        },
        else => {},
    }
    if (containsNodeTag(p, data.rhs, target)) return true;
    return false;
}

fn containsAwaitIdentifier(p: *Parser, node: NodeIndex) bool {
    if (node == .none) return false;
    const idx = node.toInt();
    const tag = p.node_tags_ptr[idx];
    const data = p.node_data_ptr[idx];
    if (tag == .identifier) {
        const tok = p.node_main_token_ptr[idx];
        if (p.tokenTagAt(tok) == .kw_await) return true;
    }
    // Stop at function boundaries — those have their own [Await] context.
    // Class member methods stop (own [Await]). Arrow functions inherit
    // [Await] from parent, so we descend into their params (but NOT body —
    // body inherits but is parsed in its own scope). Async arrows stop
    // because their body has [Await]=true regardless and any await there
    // would be an await_expr, not an identifier.
    switch (tag) {
        .fn_expr, .async_fn_expr, .generator_fn_expr,
        .method_def, .getter_def, .setter_def,
        .async_arrow_fn,
        => return false,
        .arrow_fn => {
            // data.lhs is an extra-data index to ArrowData; decode it and
            // walk only params, skipping body.
            const ed_idx = data.lhs.toInt();
            if (ed_idx + 2 >= p.extra_data.items.len) return false;
            const params_start = p.extra_data.items[ed_idx];
            const params_end = p.extra_data.items[ed_idx + 1];
            var i: u32 = params_start;
            while (i < params_end) : (i += 1) {
                const child = NodeIndex.fromInt(p.extra_data.items[i]);
                if (containsAwaitIdentifier(p, child)) return true;
            }
            return false;
        },
        // For property nodes the key (data.lhs) is just a name — reserved
        // words allowed there. Only the value (data.rhs) is an expression.
        .property, .computed_property => return containsAwaitIdentifier(p, data.rhs),
        else => {},
    }
    // Children via lhs / rhs.
    if (data.lhs != .none and containsAwaitIdentifier(p, data.lhs)) return true;
    // For nodes whose data.{lhs,rhs} is a SubRange (start/end indices into extra_data),
    // walk the range. We detect by tag.
    switch (tag) {
        .array_literal, .array_pattern, .object_literal, .object_pattern,
        .var_decl, .let_decl, .const_decl, .sequence_expr,
        => {
            var i = data.lhs.toInt();
            while (i < data.rhs.toInt()) : (i += 1) {
                const child = NodeIndex.fromInt(p.extra_data.items[i]);
                if (containsAwaitIdentifier(p, child)) return true;
            }
            return false;
        },
        else => {},
    }
    if (data.rhs != .none and containsAwaitIdentifier(p, data.rhs)) return true;
    return false;
}

fn validateArrowParam(p: *Parser, node: NodeIndex) !void {
    if (node == .none) return;
    const tag = p.node_tags_ptr[node.toInt()];
    switch (tag) {
        .identifier => {},
        .assignment_pattern, .assign => {
            // Recurse into LHS (the actual binding pattern).
            const d = p.node_data_ptr[node.toInt()];
            if (d.lhs != .none) try validateArrowParam(p, d.lhs);
        },
        .rest_element, .spread_element => {
            // Validate rest target recursively
            const d = p.node_data_ptr[node.toInt()];
            if (d.lhs != .none) {
                const tt = p.node_tags_ptr[d.lhs.toInt()];
                if (tt == .assign or tt == .assignment_pattern) {
                    return p.emitError("Rest parameter may not have a default initializer");
                }
                try validateArrowParam(p, d.lhs);
            }
        },
        .array_literal, .array_pattern => {
            const d = p.node_data_ptr[node.toInt()];
            const s = d.lhs.toInt();
            const e = d.rhs.toInt();
            var i = s;
            while (i < e) : (i += 1) {
                const child = NodeIndex.fromInt(p.extra_data.items[i]);
                if (child != .none) {
                    const ct = p.node_tags_ptr[child.toInt()];
                    if (ct == .rest_element or ct == .spread_element) {
                        // Rest must be last; trailing comma after rest is invalid in BindingPattern.
                        if (i < e - 1) {
                            return p.emitError("Rest element must be last in destructuring pattern");
                        }
                    }
                }
                try validateArrowParam(p, child);
            }
        },
        .object_literal, .object_pattern => {
            const d = p.node_data_ptr[node.toInt()];
            const s = d.lhs.toInt();
            const e = d.rhs.toInt();
            var i = s;
            while (i < e) : (i += 1) {
                const prop = NodeIndex.fromInt(p.extra_data.items[i]);
                const prop_tag = p.node_tags_ptr[prop.toInt()];
                if (prop_tag == .property or prop_tag == .computed_property) {
                    // Validate the value (rhs) of the property
                    const prop_data = p.node_data_ptr[prop.toInt()];
                    try validateArrowParam(p, prop_data.rhs);
                } else if (prop_tag == .shorthand_property) {
                    // Shorthand property key must be an identifier, not a literal
                    const prop_data = p.node_data_ptr[prop.toInt()];
                    if (prop_data.lhs != .none) {
                        const key_tag = p.node_tags_ptr[prop_data.lhs.toInt()];
                        if (key_tag == .number_literal or key_tag == .string_literal or
                            key_tag == .boolean_literal)
                        {
                            return p.emitError("Invalid destructuring in arrow function parameter");
                        }
                    }
                } else if (prop_tag == .rest_element or prop_tag == .spread_element) {
                    // Rest/spread in object pattern: validate the target
                    const prop_data = p.node_data_ptr[prop.toInt()];
                    try validateArrowParam(p, prop_data.lhs);
                } else if (prop_tag == .getter_def or prop_tag == .setter_def or prop_tag == .method_def) {
                    return p.emitError("Invalid destructuring in arrow function parameter");
                }
            }
        },
        .member_expr, .computed_member_expr, .call_expr,
        .getter_def, .setter_def, .method_def,
        .number_literal, .string_literal,
        .grouping_expr,
        => return p.emitError("Invalid destructuring in arrow function parameter"),
        else => {},
    }
}

/// Emit diagnostic for octal number in strict mode (non-fatal — parsing continues).
fn checkStrictOctalNumber(p: *Parser) !void {
    const start = p.tok_starts_ptr[p.tok_i];
    if (start >= p.source.len) return;
    if (p.source[start] == '0' and start + 1 < p.source.len) {
        const next = p.source[start + 1];
        if (next >= '0' and next <= '7') {
            try p.emitError("Octal literals are not allowed in strict mode");
        } else if (next == '8' or next == '9') {
            try p.emitError("Decimals with leading zeros are not allowed in strict mode");
        }
    }
}

/// Emit TS1121/TS1489 for legacy octal/leading-zero literals in TypeScript mode.
/// Only called when is_ts and NOT already in_strict (strict path already handles these).
fn checkTsOctalNumber(p: *Parser) !void {
    const start = p.tok_starts_ptr[p.tok_i];
    if (start + 1 >= p.source.len) return;
    if (p.source[start] != '0') return;
    const next = p.source[start + 1];
    // Skip modern prefix literals (0x, 0b, 0o, 0X, 0B, 0O) and floats (0., 0e).
    if (next == 'x' or next == 'X' or next == 'b' or next == 'B' or
        next == 'o' or next == 'O' or next == '.' or next == 'e' or
        next == 'E' or next == 'n' or next == '_' or
        next < '0' or next > '9') return;
    // Scan integer digits of the token to decide TS1121 vs TS1489.
    const tok_len = p.tok_lens_ptr[p.tok_i];
    const tok_end = @min(start + tok_len, p.source.len);
    var has_89 = false;
    var i: usize = start + 1;
    while (i < tok_end) : (i += 1) {
        const c = p.source[i];
        if (c < '0' or c > '9') break; // stop at '.', 'e', 'n', etc.
        if (c == '8' or c == '9') has_89 = true;
    }
    if (has_89) {
        try p.emitError("Decimals with leading zeros are not allowed");
    } else {
        try p.emitError("Octal literals are not allowed. Use the syntax '0o" ++ "...'.");
    }
}

/// Emit diagnostic for octal escape in string in strict mode (non-fatal).
/// Validate \u and \x escape sequences in string content (any mode).
/// Rejects `\u` followed by fewer than 4 hex digits, malformed `\u{...}`,
/// and `\x` followed by fewer than 2 hex digits.
fn checkStringEscapes(p: *Parser) !void {
    const start = p.tok_starts_ptr[p.tok_i];
    const tok_len = p.tok_lens_ptr[p.tok_i];
    if (tok_len < 2 or start + tok_len > p.source.len) return;
    // Use token length to bound the scan — avoids per-byte quote comparison.
    const content_end = start + tok_len - 1; // position of closing quote (not scanned)
    // Fast path: most strings have no escape sequences.
    if (std.mem.indexOfScalar(u8, p.source[start + 1 .. content_end], '\\') == null) return;
    var i = start + 1;
    while (i < content_end) {
        if (p.source[i] == '\\' and i + 1 < content_end + 1) {
            const esc = p.source[i + 1];
            i += 2;
            if (esc == 'u') {
                if (i < p.source.len and p.source[i] == '{') {
                    i += 1;
                    const hex_start = i;
                    var cp: u32 = 0;
                    var overflow = false;
                    while (i < p.source.len and p.source[i] != '}') : (i += 1) {
                        const c = p.source[i];
                        const dv: u32 = if (c >= '0' and c <= '9') c - '0'
                            else if (c >= 'a' and c <= 'f') c - 'a' + 10
                            else if (c >= 'A' and c <= 'F') c - 'A' + 10
                            else 0xff;
                        if (dv == 0xff) {
                            try p.emitError("Invalid unicode escape in string");
                            return;
                        }
                        if (!overflow) {
                            cp = (cp << 4) | dv;
                            if (cp > 0x10FFFF) overflow = true;
                        }
                    }
                    if (i >= p.source.len or p.source[i] != '}') {
                        try p.emitError("Unterminated \\u{...} escape in string");
                        return;
                    }
                    if (i == hex_start) {
                        try p.emitError("Empty \\u{} escape in string");
                        return;
                    }
                    if (overflow) {
                        try p.emitError("Unicode codepoint must not be greater than 0x10FFFF");
                        return;
                    }
                    i += 1;
                } else {
                    var hc: u32 = 0;
                    while (hc < 4 and i < p.source.len) : ({ hc += 1; i += 1; }) {
                        const c = p.source[i];
                        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                            try p.emitError("Invalid \\u escape in string");
                            return;
                        }
                    }
                    if (hc < 4) {
                        try p.emitError("\\u escape requires 4 hex digits");
                        return;
                    }
                }
            } else if (esc == 'x') {
                var hc: u32 = 0;
                while (hc < 2 and i < p.source.len) : ({ hc += 1; i += 1; }) {
                    const c = p.source[i];
                    if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                        try p.emitError("Invalid \\x escape in string");
                        return;
                    }
                }
                if (hc < 2) {
                    try p.emitError("\\x escape requires 2 hex digits");
                    return;
                }
            }
            continue;
        }
        i += 1;
    }
}

fn checkStrictOctalString(p: *Parser) !void {
    const start = p.tok_starts_ptr[p.tok_i];
    const tok_len = p.tok_lens_ptr[p.tok_i];
    if (tok_len < 2 or start + tok_len > p.source.len) return;
    const content_end = start + tok_len - 1;
    // Fast path: most strings have no escape sequences.
    if (std.mem.indexOfScalar(u8, p.source[start + 1 .. content_end], '\\') == null) return;
    var i = start + 1;
    while (i < content_end) {
        if (p.source[i] == '\\' and i + 1 < content_end + 1) {
            const esc = p.source[i + 1];
            if (esc >= '1' and esc <= '7') {
                try p.emitError("Octal escape sequences are not allowed in strict mode");
                return;
            }
            if (esc == '8' or esc == '9') {
                try p.emitError("\\8 and \\9 are not allowed in strict mode");
                return;
            }
            if (esc == '0' and i + 2 < p.source.len and p.source[i + 2] >= '0' and p.source[i + 2] <= '9') {
                try p.emitError("Octal escape sequences are not allowed in strict mode");
                return;
            }
            i += 2;
            continue;
        }
        i += 1;
    }
}

// =====================================================================
// Primary expressions
// =====================================================================

pub fn parsePrimaryExpression(p: *Parser) Error!NodeIndex {
    const tag = p.peek();
    return switch (tag) {
        .identifier, .escaped_keyword,
        .kw_get, .kw_set, .kw_of, .kw_from, .kw_as, .kw_target, .kw_meta,
        => try parseIdentifierOrArrow(p),
        // Strict-mode reserved words: valid identifiers in non-strict JS, always reserved in TS/strict mode
        .kw_let, .kw_static, .kw_implements, .kw_interface, => {
            if (p.in_strict or p.is_ts) {
                try p.emitError("Expected expression");
                return error.ParseError;
            }
            return try parseIdentifierOrArrow(p);
        },
        // await/yield as identifiers when not in their reserved contexts.
        // In TypeScript, `in_async` is set at top level to allow top-level await
        // expressions, but `await` is still a valid identifier in non-function,
        // non-module TS script context (TypeScript only reserves it in async fns/modules).
        .kw_await => if (!p.is_module and
            !(p.in_static_block and !p.in_function) and
            (!p.in_async or (p.is_ts and !p.in_function and !p.in_fn_params and !p.is_module))) try parseIdentifierOrArrow(p) else {
            try p.emitError("Expected expression");
            return p.makeErrorNode();
        },
        .kw_yield => if (!p.in_generator and !p.in_strict) try parseIdentifierOrArrow(p) else {
            try p.emitError("Expected expression");
            return p.makeErrorNode();
        },
        .number_literal => blk: {
            if (p.in_strict) try checkStrictOctalNumber(p) else if (p.is_ts) try checkTsOctalNumber(p);
            break :blk try parseLiteral(p, .number_literal);
        },
        .string_literal => blk: {
            const tok = p.tok_i;
            const ts = p.tok_starts_ptr[tok];
            const tl = p.tok_lens_ptr[tok];
            if (tl < 2 or ts + tl > p.source.len) {
                try p.emitError("Unterminated string literal");
                return error.ParseError;
            }
            const open = p.source[ts];
            // Single SIMD scan for backslash in [ts+1..ts+tl).
            // Common case (no escapes): verify termination in O(1) from lexer's
            // token boundary — the closing quote must be the last byte.
            // Backslash case: fall through to the careful walk + helper checks.
            if (std.mem.indexOfScalar(u8, p.source[ts + 1 .. ts + tl], '\\') == null) {
                if (p.source[ts + tl - 1] != open) {
                    try p.emitError("Unterminated string literal");
                    return error.ParseError;
                }
                // No escape sequences — nothing for checkStringEscapes or
                // checkStrictOctalString to flag.
            } else {
                // Has backslash — walk to verify termination then run escape checks.
                var ix: u32 = ts + 1;
                const stop = ts + tl;
                var terminated = false;
                while (ix < stop) : (ix += 1) {
                    const c = p.source[ix];
                    if (c == '\\') {
                        if (ix + 1 < stop) ix += 1;
                        continue;
                    }
                    if (c == open) {
                        if (ix + 1 == stop) terminated = true;
                        break;
                    }
                }
                if (!terminated) {
                    try p.emitError("Unterminated string literal");
                    return error.ParseError;
                }
                try checkStringEscapes(p);
                if (p.in_strict) try checkStrictOctalString(p);
            }
            break :blk try parseLiteral(p, .string_literal);
        },
        .bigint_literal => try parseLiteral(p, .bigint_literal),
        .regex_literal => blk: {
            // Detect unterminated regex (lexer emits up to LF/CR/EOF).
            const tok = p.tok_i;
            const ts = p.tok_starts_ptr[tok];
            const tl = p.tok_lens_ptr[tok];
            // Find the body end: scan to last `/` not inside char class.
            var has_close = false;
            var has_newline_escape = false;
            if (ts + tl <= p.source.len and tl >= 2) {
                var i: u32 = ts + 1;
                var in_class = false;
                const stop = ts + tl;
                while (i < stop) : (i += 1) {
                    const c = p.source[i];
                    if (c == '\\' and i + 1 < stop) {
                        // Backslash-newline inside regex is invalid.
                        const nc = p.source[i + 1];
                        if (nc == '\n' or nc == '\r') has_newline_escape = true;
                        i += 1;
                        continue;
                    }
                    if (c == '[') in_class = true
                    else if (c == ']') in_class = false
                    else if (c == '/' and !in_class) { has_close = true; break; }
                }
            }
            if (!has_close) {
                try p.emitError("Unterminated regular expression literal");
                return error.ParseError;
            }
            if (has_newline_escape) {
                try p.emitError("Invalid line terminator in regular expression literal");
                return error.ParseError;
            }
            // Check for U+2028 (LS) / U+2029 (PS) inside body — invalid line
            // terminators per spec.
            {
                var li: u32 = ts;
                const stop3 = ts + tl;
                while (li + 2 < stop3) : (li += 1) {
                    if (p.source[li] == 0xE2 and p.source[li + 1] == 0x80 and
                        (p.source[li + 2] == 0xA8 or p.source[li + 2] == 0xA9))
                    {
                        try p.emitError("Line terminator in regular expression literal");
                        return error.ParseError;
                    }
                }
            }
            // Validate regex flags: no duplicates, `u` and `v` mutually exclusive.
            // Find flags region: after closing `/` to token end.
            {
                var ci: u32 = ts + 1;
                var ic = false;
                const stop2 = ts + tl;
                var close: u32 = stop2;
                while (ci < stop2) : (ci += 1) {
                    const c = p.source[ci];
                    if (c == '\\' and ci + 1 < stop2) { ci += 1; continue; }
                    if (c == '[') ic = true
                    else if (c == ']') ic = false
                    else if (c == '/' and !ic) { close = ci + 1; break; }
                }
                var seen: [128]bool = @splat(false);
                var has_u = false;
                var has_v = false;
                var fi: u32 = close;
                while (fi < stop2) : (fi += 1) {
                    const c = p.source[fi];
                    // Spec valid flags: g i m s u y d v
                    switch (c) {
                        'g', 'i', 'm', 's', 'u', 'y', 'd', 'v' => {},
                        else => {
                            try p.emitError("Invalid regular expression flag");
                            return error.ParseError;
                        },
                    }
                    if (seen[c]) {
                        try p.emitError("Duplicate regular expression flag");
                        return error.ParseError;
                    }
                    seen[c] = true;
                    if (c == 'u') has_u = true;
                    if (c == 'v') has_v = true;
                }
                if (has_u and has_v) {
                    try p.emitError("Regex flags 'u' and 'v' are mutually exclusive");
                    return error.ParseError;
                }
                // Validate balanced groups (e.g. /fo(o/).
                try validateRegexBalancedGroups(p, p.source[ts + 1 .. close - 1]);
                // Validate quantifier-without-atom (e.g. /?/, /{2}/).
                try validateRegexNoLeadingQuantifier(p, p.source[ts + 1 .. close - 1]);
                // Validate regex modifier-group syntax: `(?<flags>:...)` etc.
                try validateRegexModifierGroups(p, p.source[ts + 1 .. close - 1]);
                // Validate named groups: collect names, validate format, check refs.
                try validateRegexNamedGroups(p, p.source[ts + 1 .. close - 1], has_u or has_v);
                // Lookbehind cannot be quantified in any mode.
                try validateRegexLookbehindQuant(p, p.source[ts + 1 .. close - 1]);
                // TS1538: \u{...} escape sequences require the u or v flag.
                if (!has_u and !has_v) {
                    const body = p.source[ts + 1 .. close - 1];
                    var bi: usize = 0;
                    while (bi + 3 < body.len) : (bi += 1) {
                        if (body[bi] == '\\' and body[bi + 1] == 'u' and body[bi + 2] == '{') {
                            try p.emitError("Unicode escape sequences are only available when the Unicode (u) flag or the Unicode Sets (v) flag is set");
                            break;
                        }
                    }
                }
                // With u or v flag, validate body for u-mode requirements.
                if (has_u or has_v) {
                    try validateRegexBodyUnicode(p, p.source[ts + 1 .. close - 1], has_v);
                    try validateRegexLookaroundUnicode(p, p.source[ts + 1 .. close - 1]);
                    if (has_u and !has_v) {
                        try validateRegexClassRangesUnicode(p, p.source[ts + 1 .. close - 1]);
                    }
                    if (has_v) {
                        try validateRegexVFlagClassExtras(p, p.source[ts + 1 .. close - 1]);
                    }
                }
            }
            break :blk try parseLiteral(p, .regex_literal);
        },
        .kw_true, .kw_false => try parseLiteral(p, .boolean_literal),
        .kw_null => try parseLiteral(p, .null_literal),
        .kw_this => try parseLiteral(p, .this_expr),
        .kw_super => blk: {
            if (!p.in_class and !p.in_method and !p.is_ts) try p.emitError("'super' is only valid inside a class or method");
            // super must be followed by `.`, `[`, `(`, or `<` (TS type args) — bare `super` is invalid
            const next = p.peekAt(1);
            if (next != .dot and next != .l_bracket and next != .l_paren and
                !(next == .less_than and p.is_ts))
            {
                if (!p.is_ts) try p.emitError("'super' keyword unexpected here");
            }
            break :blk try parseLiteral(p, .super_expr);
        },
        .template_head, .template_no_sub => try parseTemplateLiteral(p),
        .l_paren => try parseParenthesized(p),
        .l_bracket => try parseArrayLiteral(p),
        .l_brace => try parseObjectLiteral(p),
        .kw_function => try parseFunctionExpression(p),
        .kw_class => try parseClassExpression(p),
        .at_sign => blk: {
            // Decorator(s) before class expression: @expr class { }
            while (p.peek() == .at_sign) {
                _ = p.advance(); // eat @
                _ = try parseAssignmentExpression(p);
            }
            if (p.peek() == .kw_class) {
                break :blk try parseClassExpression(p);
            }
            try p.emitError("Expected class after decorator");
            break :blk try p.makeErrorNode();
        },
        .kw_async => try parseAsyncExpressionOrIdentifier(p),
        .kw_import => try parseImportExpression(p),
        .hash => blk: {
            // #identifier — private brand check. Only valid as LHS of `in`,
            // which means: caller is at relational precedence (or below) AND
            // `#x` is followed immediately by `in`.
            if (!p.in_class and !p.is_ts) {
                try p.emitError("Private name '#...' is not allowed outside a class body");
                return error.ParseError;
            }
            if (!p.is_ts and !p.private_in_lhs_allowed) {
                try p.emitError("Private name '#...' must be the left operand of 'in'");
                return error.ParseError;
            }
            const hash_tok = p.advance();
            if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
            if (!p.is_ts and (p.peek() != .kw_in or !p.allow_in)) {
                try p.emitError("Private name '#...' must be the left operand of 'in'");
                return error.ParseError;
            }
            try p.private_refs.append(p.gpa, hash_tok);
            break :blk try p.addNode(.{
                .tag = .identifier,
                .main_token = hash_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },
        .less_than => {
            // TSX disambiguation: in `.tsx` files, `<T extends X>(...) => ...`,
            // `<T,>(...) => ...`, and `<T = X>(...) => ...` are generic arrow
            // functions, not JSX. Peek ahead before committing to JSX so we
            // don't get an "expected JSX closing tag" error on a generic arrow.
            if (p.is_jsx and p.is_ts) {
                if (looksLikeTsxGenericArrow(p)) {
                    return parseTsTypeAssertion(p);
                }
                const jsx_mod = @import("jsx.zig");
                _ = p.advance(); // consume '<'
                return jsx_mod.parseJsxElement(p);
            }
            // JSX element: <tag> or <> fragment
            if (p.is_jsx) {
                const jsx_mod = @import("jsx.zig");
                _ = p.advance(); // consume '<'
                return jsx_mod.parseJsxElement(p);
            }
            // TS type assertion: <Type>expr
            if (p.is_ts) {
                return parseTsTypeAssertion(p);
            }
            try p.emitError("Expected expression");
            return p.makeErrorNode();
        },
        // The lexer tokenized `/` as division, but we're in expression position.
        // Re-scan the source as a regex literal.
        .slash, .slash_equal => return try rescanSlashAsRegex(p),
        else => {
            if (tag.isTsContextualKeyword()) {
                return try parseIdentifierRef(p);
            }
            try p.emitError("Expected expression");
            _ = p.advance(); // skip unexpected token to guarantee forward progress
            return p.makeErrorNode();
        },
    };
}

// ── Slash rescan as regex ────────────────────────────────────────
//
// When the lexer tokenized `/` as division (wrong context), but the parser
// is in expression position, re-scan the source from that position as a
// regex literal.  Advance past all pre-tokenized tokens that fall within
// the regex span.

fn rescanSlashAsRegex(p: *Parser) Error!NodeIndex {
    const slash_tok: u32 = p.tokIdx();
    const start = p.tokenStart(slash_tok);
    const source = p.source;

    // Body starts after the opening `/`
    var idx: u32 = start + 1;
    var in_char_class = false;

    while (idx < source.len) {
        const c = source[idx];
        if (c == '\\') {
            idx += 1;
            if (idx < source.len and source[idx] != '\n' and source[idx] != '\r') {
                idx += 1;
            } else break; // invalid regex
            continue;
        }
        if (c == '\n' or c == '\r') break;
        if (c == '[') {
            in_char_class = true;
            idx += 1;
            continue;
        }
        if (c == ']') {
            in_char_class = false;
            idx += 1;
            continue;
        }
        if (c == '/' and !in_char_class) {
            idx += 1; // skip closing /
            const flags_start = idx;
            // Scan flags (alphanumeric, but validate below)
            while (idx < source.len) {
                const fc = source[idx];
                if ((fc >= 'a' and fc <= 'z') or (fc >= 'A' and fc <= 'Z') or
                    (fc >= '0' and fc <= '9'))
                {
                    idx += 1;
                } else break;
            }
            // Advance tok_i past all tokens within the regex span
            while (p.tok_i < p.tokens.len - 1 and p.tokenStart(p.tokIdx()) < idx) {
                p.tok_i += 1;
            }
            // Validate flags: only g i m s u y d v are valid; no duplicates; u/v exclusive
            var seen: [128]bool = @splat(false);
            var has_u = false;
            var has_v = false;
            var fi = flags_start;
            while (fi < idx) : (fi += 1) {
                const fc = source[fi];
                switch (fc) {
                    'g', 'i', 'm', 's', 'u', 'y', 'd', 'v' => {},
                    else => {
                        try p.emitError("Invalid regular expression flag");
                        return error.ParseError;
                    },
                }
                if (seen[fc]) {
                    try p.emitError("Duplicate regular expression flag");
                    return error.ParseError;
                }
                seen[fc] = true;
                if (fc == 'u') has_u = true;
                if (fc == 'v') has_v = true;
            }
            if (has_u and has_v) {
                try p.emitError("Regex flags 'u' and 'v' are mutually exclusive");
                return error.ParseError;
            }
            return p.addNode(.{
                .tag = .regex_literal,
                .main_token = slash_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        }
        idx += 1;
    }
    // Failed to re-scan as regex
    try p.emitError("Expected expression");
    _ = p.advance();
    return p.makeErrorNode();
}

// ── Simple literals ──────────────────────────────────────────────

fn parseLiteral(p: *Parser, node_tag: Node.Tag) Error!NodeIndex {
    const tok = p.advance();
    return p.addNode(.{
        .tag = node_tag,
        .main_token = tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
}

// ── Identifier (with possible single-param arrow) ────────────────

/// Create an `.identifier` AST node WITHOUT emitting a semantic event.
/// Used when the identifier is a declaration name (function name, class name,
/// binding pattern), or otherwise decided by the caller.
fn parseIdentifier(p: *Parser) Error!NodeIndex {
    const tok = p.advance();
    return p.addNode(.{
        .tag = .identifier,
        .main_token = tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
}

/// Expression-position identifier: produces a `.identifier` node AND emits a
/// `reference(.read)` semantic event.  Used from parsePrimaryExpression.
fn identRefsArguments(p: *const Parser, tok: u32) bool {
    const raw = p.tokenText(tok);
    if (std.mem.eql(u8, raw, "arguments")) return true;
    // Check escaped form: arguments → "arguments"
    if (std.mem.indexOfScalar(u8, raw, '\\') != null) {
        var buf: [256]u8 = undefined;
        if (parser_mod.resolveUnicodeEscapesParser(raw, &buf)) |resolved| {
            return std.mem.eql(u8, resolved, "arguments");
        }
    }
    return false;
}

fn parseIdentifierRef(p: *Parser) Error!NodeIndex {
    const tok = p.advance();
    // Class field initializers cannot reference 'arguments'.
    // TypeScript emits TS2815 (semantic), so skip the parse-time error in TS mode.
    if (!p.is_ts and p.in_class_field and identRefsArguments(p, tok)) {
        try p.emitError("'arguments' is not allowed in class field initializer");
        return error.ParseError;
    }
    const node = try p.addNode(.{
        .tag = .identifier,
        .main_token = tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
    try p.emitReference(.read, node);
    return node;
}

fn parseIdentifierOrArrow(p: *Parser) Error!NodeIndex {
    const tok = p.advance(); // consume identifier
    // identifier => body  (single-parameter arrow without parens)
    if (p.peek() == .arrow and !p.isOnNewLine() and p.allow_arrow) {
        return parseArrowFunctionBody(p, tok, false);
    }
    // Class field initializers cannot reference 'arguments'.
    // TypeScript emits TS2815 (semantic), so skip the parse-time error in TS mode.
    if (!p.is_ts and p.in_class_field and identRefsArguments(p, tok)) {
        try p.emitError("'arguments' is not allowed in class field initializer");
        return error.ParseError;
    }
    // Spec: IdentifierName decoded to a ReservedWord is SyntaxError as IdentifierReference.
    const tok_tag = p.tokenTagAt(tok);
    if (tok_tag == .identifier) {
        // Only fetch tokenText when strict/TS checks are needed — saves two array loads
        // on the common non-strict path.  Gate on raw length first: strict reserved
        // words are 6+ chars, so short identifiers can't match even with \u escapes
        // (decoded length ≤ raw length).
        if (p.in_strict or p.is_ts) {
            if (p.tok_lens_ptr[tok] >= 6) {
                const text = p.tokenText(tok);
                // For raw .identifier text in strict/TS mode: let/yield/static/interface are already
                // keyword tags; implements is kw_implements in TS. Only public/package/private/protected
                // (all start with 'p') can be strict-reserved .identifier tokens.
                if (text[0] == 'p' and Parser.isStrictReservedAccessModifier(text)) {
                    try p.emitDiagnostic(p.currentSpan(),
                        "'{s}' is not allowed as an identifier in strict mode", .{text});
                    return error.ParseError;
                }
                if (!p.is_ts and text[0] == 'i' and text.len == 10 and
                    std.mem.eql(u8, text, "implements"))
                {
                    try p.emitDiagnostic(p.currentSpan(),
                        "'{s}' is not allowed as an identifier in strict mode", .{text});
                    return error.ParseError;
                }
            }
        }
    } else if (tok_tag == .escaped_keyword) {
        // .escaped_keyword always has \u escapes and always decodes to a Token.keywords member,
        // which is a superset of isAlwaysReservedStr. Raw text never matches isStrictReservedStr
        // (backslashes cause length/content mismatch), so skip that check entirely.
        const text = p.tokenText(tok);
        var resolved_buf: [256]u8 = undefined;
        if (parser_mod.resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
            if (parser_mod.isAlwaysReservedStr(resolved)) {
                try p.emitDiagnostic(p.currentSpan(),
                    "'{s}' is a reserved word and cannot be used as an identifier", .{resolved});
                return error.ParseError;
            }
            // yield is reserved inside generators and strict mode
            if (std.mem.eql(u8, resolved, "yield") and (p.in_generator or p.in_strict)) {
                try p.emitDiagnostic(p.currentSpan(),
                    "'yield' cannot be used as an identifier in this context", .{});
                return error.ParseError;
            }
            // await is reserved in async functions, modules, and static blocks
            if (std.mem.eql(u8, resolved, "await") and
                !p.in_ts_ambient and
                (p.in_async or p.is_module or (p.in_static_block and !p.in_function)))
            {
                try p.emitDiagnostic(p.currentSpan(),
                    "'await' cannot be used as an identifier in this context", .{});
                return error.ParseError;
            }
        }
    }
    const node = try p.addNode(.{
        .tag = .identifier,
        .main_token = tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
    try p.emitReference(.read, node);
    return node;
}

// ── async expression or identifier ───────────────────────────────
// `async` is a keyword token (.kw_async).  It can appear as:
//   1. `async function ...`  → async function expression
//   2. `async (...)  => ...` → async arrow function
//   3. `async ident => ...`  → async arrow function (single param)
//   4. `async` (standalone)  → identifier

fn parseAsyncExpressionOrIdentifier(p: *Parser) Error!NodeIndex {
    const async_tok = p.advance(); // consume `async`

    // Must be on the same line to be an async prefix (ASI rule).
    if (p.isOnNewLine()) {
        return p.addNode(.{
            .tag = .identifier,
            .main_token = async_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }

    const next_tag = p.peek();

    // async function ...
    if (next_tag == .kw_function) {
        return parseAsyncFunctionExpression(p, async_tok);
    }

    // async <TypeParams>(params) => body (TS generic async arrow)
    if (p.is_ts and next_tag == .less_than) {
        const ts_mod = @import("typescript.zig");
        const saved_tok = p.tok_i;
        const saved_diag = p.diagnostics.items.len;
        const saved_nodes = p.nodes.len;
        const saved_extra = p.extra_data.items.len;
        const type_params_ok = blk: {
            _ = ts_mod.parseTypeParameterList(p) catch break :blk false;
            break :blk true;
        };
        if (type_params_ok and p.peek() == .l_paren) {
            return parseAsyncParenArrowOrCall(p, async_tok);
        }
        // Backtrack — not a generic arrow
        p.tok_i = saved_tok;
        p.diagnostics.shrinkRetainingCapacity(saved_diag);
        p.nodes.len = @intCast(saved_nodes);
        p.extra_data.shrinkRetainingCapacity(saved_extra);
    }

    // async (params) => body
    if (next_tag == .l_paren) {
        return parseAsyncParenArrowOrCall(p, async_tok);
    }

    // async ident => body (includes contextual keywords like `of`, `let`, etc.)
    if (next_tag == .identifier or next_tag == .kw_of or next_tag == .kw_let or
        next_tag == .kw_get or next_tag == .kw_set or next_tag == .kw_from or
        next_tag == .kw_as or next_tag == .kw_static) {
        const ident_tok = p.advance();
        if (p.peek() == .arrow and !p.isOnNewLine() and p.allow_arrow) {
            return parseArrowFunctionBody(p, ident_tok, true);
        }
        // Not an arrow — the `async` was an identifier and the ident
        // is the start of a new expression.  We need to put ident_tok
        // back.  Since we don't have unget, model `async` as identifier.
        // This is a simplification; in production we would use a
        // checkpoint/restore mechanism.  For now, emit `async` as
        // identifier and re-parse from ident_tok.
        p.putBack(ident_tok);
        return p.addNode(.{
            .tag = .identifier,
            .main_token = async_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }

    // `async => expr` — async used as a parameter name in arrow function
    if (next_tag == .arrow and !p.isOnNewLine()) {
        return parseArrowFunctionBody(p, async_tok, false);
    }

    // Standalone `async` as identifier.
    return p.addNode(.{
        .tag = .identifier,
        .main_token = async_tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
}

// ── async function expression ────────────────────────────────────

fn parseAsyncFunctionExpression(p: *Parser, async_tok: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // consume `function`

    const is_generator = p.peek() == .asterisk;
    if (is_generator) _ = p.advance();

    // Optional name — for named function expressions (`async function foo() {}`)
    // the name binds only inside the function's own scope (ESLint: fn-expr-name scope).
    const name_node: NodeIndex = if (p.peek() == .identifier) blk: {
        try p.checkStrictBinding(p.tokIdx());
        const name_tok = p.advance();
        break :blk try p.addNode(.{
            .tag = .identifier,
            .main_token = name_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else .none;

    // Open the function scope BEFORE parsing params so parameter declarations
    // land inside the function scope, not the enclosing (module/block) scope.
    // This matches parseFunctionDeclaration and the regular fn-expression path.
    const fn_scope_ev = try p.emitScopeOpen(.function, .none);
    if (name_node != .none) {
        try p.emitDeclare(.fn_expr_name, name_node);
    }

    // Set async/generator BEFORE parsing params — await/yield reserved in params
    const saved_fn = p.in_function;
    const saved_async = p.in_async;
    const saved_gen = p.in_generator;
    const saved_cf_afe = p.in_class_field;
    const saved_ic_afe = p.in_class;
    const saved_nta_afe = p.new_target_allowed;
    p.in_function = true;
    p.in_async = true;
    p.in_generator = is_generator;
    p.in_class_field = false;
    p.new_target_allowed = true;
    p.syncYieldLex();
    defer p.new_target_allowed = saved_nta_afe;
    p.in_class = false;
    defer p.in_function = saved_fn;
    defer p.in_async = saved_async;
    defer { p.in_generator = saved_gen; p.syncYieldLex(); }
    defer p.in_class_field = saved_cf_afe;
    defer p.in_class = saved_ic_afe;

    p.emit_fn_type_params = true;
    const async_fn_type_params = try p.parseOptionalTypeParameters();
    p.emit_fn_type_params = false;
    const saved_fp_afe = p.in_fn_params;
    defer p.in_fn_params = saved_fp_afe;
    const params_range = try parseFormalParameters(p);
    p.in_fn_params = false; // body context: await/yield valid in async/generator body
    p.in_return_type = true;
    const async_fn_expr_return_type = try p.parseOptionalTypeAnnotation();
    p.in_return_type = false;

    // TS ambient async function expressions can be bodyless
    if (p.is_ts and p.peek() != .l_brace) {
        _ = p.eat(.semicolon);
        try p.emitScopeClose(.none);
        const ts_node = try p.addNode(.{
            .tag = .ts_type_annotation,
            .main_token = async_tok,
            .data = .{ .lhs = name_node, .rhs = .none },
        });
        p.patchScopeOpenNode(fn_scope_ev, ts_node);
        return ts_node;
    }

    const body = try parseBlockBodyWithStrictChecks(p, params_range, name_node);
    try p.emitScopeClose(.none); // close function scope

    const fn_tag: Node.Tag = if (is_generator) .async_generator_fn_expr else .async_fn_expr;

    const extra = try p.addExtra(ast.FnData, .{
        .name = name_node,
        .params = params_range.start,
        .params_end = params_range.end,
        .body = body,
        .return_type = async_fn_expr_return_type,
        .type_params = async_fn_type_params.start,
        .type_params_end = async_fn_type_params.end,
    });
    const fn_node = try p.addNode(.{
        .tag = fn_tag,
        .main_token = async_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
    });
    p.patchScopeOpenNode(fn_scope_ev, fn_node);
    return fn_node;
}

// ── async (...) → could be arrow params or just call ─────────────

fn parseAsyncParenArrowOrCall(p: *Parser, async_tok: TokenIndex) Error!NodeIndex {
    // Save position so we can reinterpret if needed.
    const open_paren = p.advance(); // consume `(`

    // TS: if params look typed, parse as formal parameters directly
    if (p.is_ts and (p.peek() == .r_paren or looksLikeTsArrowParams(p))) {
        // Params may go into the outer or the arrow's scope depending on `=>`.
        // Suppress declare emission during parse; we'll replay declares into
        // the arrow's scope once confirmed.
        // Set in_async=true so `await` in parameter defaults is treated as a
        // keyword (TS1109: "Expression expected" if no operand follows).
        const saved_suppress = p.suppress_param_declares;
        const saved_async_pre = p.in_async;
        p.suppress_param_declares = true;
        p.in_async = true;
        const params_range = try parseFormalParameters_inner(p, open_paren);
        p.suppress_param_declares = saved_suppress;
        p.in_async = saved_async_pre;
        p.in_return_type = true;
        const async_typed_arrow_return_type = try p.parseOptionalTypeAnnotation();
        p.in_return_type = false;

        if (p.peek() == .arrow and !p.isOnNewLine() and p.allow_arrow) {
            _ = p.advance(); // consume `=>`
            const saved_fn = p.in_function;
            const saved_async = p.in_async;
            p.in_function = true;
            p.in_async = true;
            defer p.in_function = saved_fn;
            defer p.in_async = saved_async;
            const arrow_scope_ev = try p.emitScopeOpen(.arrow_function, .none);
            try p.emitParamDeclaresFromRange(params_range);
            const body = try parseArrowBody(p);
            try p.emitScopeClose(.none);
            const extra = try p.addExtra(ast.ArrowData, .{
                .params_start = params_range.start,
                .params_end = params_range.end,
                .body = body,
                .return_type = async_typed_arrow_return_type,
            });
            const arrow_node = try p.addNode(.{
                .tag = .async_arrow_fn,
                .main_token = async_tok,
                .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
            });
            p.patchScopeOpenNode(arrow_scope_ev, arrow_node);
            return arrow_node;
        }
        // Not an arrow — fallback to call
        if (params_range.end > params_range.start) {
            const callee = try p.addNode(.{ .tag = .identifier, .main_token = async_tok, .data = .{ .lhs = .none, .rhs = .none } });
            const range_extra = try p.addExtra(SubRange, .{ .start = params_range.start, .end = params_range.end });
            return p.addNode(.{ .tag = .call_expr, .main_token = open_paren, .data = .{ .lhs = callee, .rhs = NodeIndex.fromInt(range_extra) } });
        }
        return p.addNode(.{ .tag = .identifier, .main_token = async_tok, .data = .{ .lhs = .none, .rhs = .none } });
    }

    // Collect inner expressions into scratch space.
    const scratch_top = p.scratchLen();

    var async_has_trailing_comma = false;
    if (p.peek() != .r_paren) {
        const first = try parseAssignmentOrSpread(p);
        try p.scratchPush(first);

        while (p.peek() == .comma) {
            _ = p.advance(); // consume `,`
            if (p.peek() == .r_paren) { async_has_trailing_comma = true; break; } // trailing comma
            const elem = try parseAssignmentOrSpread(p);
            try p.scratchPush(elem);
        }
    }

    _ = try p.expect(.r_paren);

    // TS return type annotation: `async (): Type =>`
    _ = try p.parseOptionalTypeAnnotation();

    // If `=>` follows on the same line, this is an async arrow.
    if (p.peek() == .arrow and !p.isOnNewLine() and p.allow_arrow) {
        const params = p.scratchSlice(scratch_top);
        // Reinterpret expressions as patterns.
        for (params) |node_raw| {
            reinterpretAsPattern(p, NodeIndex.fromInt(node_raw));
        }
        for (params) |node_raw| {
            const pn = NodeIndex.fromInt(node_raw);
            if (pn != .none) try validatePattern(p, pn);
        }

        // Check restrictions on async arrow params
        for (params, 0..) |node_raw, idx| {
            const param_node = NodeIndex.fromInt(node_raw);
            if (param_node == .none) continue;
            const pt = p.node_tags_ptr[param_node.toInt()];
            if (pt == .identifier) {
                const ptok = p.node_main_token_ptr[param_node.toInt()];
                // In async arrows, `await` cannot be a parameter name
                const ptext = p.tokenText(ptok);
                if (std.mem.eql(u8, ptext, "await")) {
                    try p.emitError("'await' is not allowed as a parameter name in async arrow");
                    return error.ParseError;
                }
            }
            // TS1109: `await` used as an expression without operand in a default value
            // (e.g., `async (a = await) =>`). `await` is a keyword in async param defaults.
            if (p.is_ts and pt == .assignment_pattern) {
                const rhs = p.node_data_ptr[param_node.toInt()].rhs;
                if (rhs != .none and p.node_tags_ptr[rhs.toInt()] == .identifier) {
                    const rtok = p.node_main_token_ptr[rhs.toInt()];
                    if (std.mem.eql(u8, p.tokenText(rtok), "await")) {
                        try p.emitError("Expression expected");
                        return error.ParseError;
                    }
                }
            }
            if (pt == .identifier) {
                const ptok = p.node_main_token_ptr[param_node.toInt()];
                if (p.in_strict) {
                    try p.checkStrictBinding(ptok);
                }
            }
            // Rest param with trailing comma rejected.
            if (!p.is_ts and (pt == .rest_element or pt == .spread_element)) {
                if (idx < params.len - 1) {
                    try p.emitError("Rest parameter must be last in async arrow");
                    return error.ParseError;
                }
                if (async_has_trailing_comma) {
                    try p.emitError("Rest parameter must not have a trailing comma");
                    return error.ParseError;
                }
                // rest with default is invalid
                const rd = p.node_data_ptr[param_node.toInt()];
                if (rd.lhs != .none and p.node_tags_ptr[rd.lhs.toInt()] == .assignment_pattern) {
                    try p.emitError("Rest parameter cannot have a default value");
                    return error.ParseError;
                }
            }
            // Deep validate (rejects parens around bindings, member expr, etc).
            if (!p.is_ts and (pt == .array_pattern or pt == .object_pattern or
                pt == .array_literal or pt == .object_literal or
                pt == .assign or pt == .assignment_pattern or
                pt == .grouping_expr))
            {
                validateArrowParam(p, param_node) catch {
                    return error.ParseError;
                };
            }
            // Async arrow params cannot reference 'await' anywhere in defaults.
            if (!p.is_ts and containsAwaitIdentifier(p, param_node)) {
                try p.emitError("'await' is not allowed in async arrow parameter list");
                return error.ParseError;
            }
            // Async arrow params cannot contain await expressions in defaults.
            if (!p.is_ts and (pt == .assign or pt == .assignment_pattern)) {
                const d = p.node_data_ptr[param_node.toInt()];
                if (d.rhs != .none and containsNodeTag(p, d.rhs, .await_expr)) {
                    try p.emitError("Arrow function parameters cannot contain await expressions");
                    return error.ParseError;
                }
            }
        }

        const params_range = try p.addSlice(params);
        p.scratchPop(scratch_top);

        // Async arrow params must be unique (UniqueFormalParameters).
        try p.checkUniqueParams(params_range);

        _ = p.advance(); // consume `=>`
        const saved_async = p.in_async;
        const saved_fn4 = p.in_function;
        const saved_gen4 = p.in_generator;
        const saved_fp4 = p.in_fn_params;
        p.in_async = true;
        p.in_function = true;
        p.in_generator = false;
        p.in_fn_params = false;
        p.syncYieldLex();
        defer p.in_async = saved_async;
        defer p.in_function = saved_fn4;
        defer { p.in_generator = saved_gen4; p.syncYieldLex(); }
        defer p.in_fn_params = saved_fp4;
        const body = if (p.peek() == .l_brace)
            try parseBlockBodyWithStrictChecks(p, params_range, .none)
        else
            try parseAssignmentExpression(p);

        const extra = try p.addExtra(ast.ArrowData, .{
            .params_start = params_range.start,
            .params_end = params_range.end,
            .body = body,
        });
        return p.addNode(.{
            .tag = .async_arrow_fn,
            .main_token = async_tok,
            .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
        });
    }

    // Not an arrow — `async(args)` is a call expression where `async`
    // is the callee identifier.  Args were collected speculatively with the
    // cover grammar (could have become arrow params), so now that we've
    // committed to call-expression semantics we must run the same
    // CoverInitializedName check that parseArgumentList does — otherwise
    // patterns like `async({ foo = 1 })` slip through silently.
    const callee = try p.addNode(.{
        .tag = .identifier,
        .main_token = async_tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });

    const args = p.scratchSlice(scratch_top);
    for (args) |raw| p.checkCoverInitializedNameFast(NodeIndex.fromInt(raw));
    const args_range = try p.addSlice(args);
    p.scratchPop(scratch_top);

    const range_extra = try p.addExtra(SubRange, .{
        .start = args_range.start,
        .end = args_range.end,
    });
    return p.addNode(.{
        .tag = .call_expr,
        .main_token = open_paren,
        .data = .{ .lhs = callee, .rhs = NodeIndex.fromInt(range_extra) },
    });
}

// ── Parenthesized / grouping / arrow params ──────────────────────

fn parseParenthesized(p: *Parser) Error!NodeIndex {
    const open_paren = p.advance(); // consume `(`
    // `in` is always allowed inside `(...)` (even in for-in init)
    const saved_allow_in_paren = p.allow_in;
    p.allow_in = true;
    defer p.allow_in = saved_allow_in_paren;

    // Empty parens → must be arrow params `() => ...` or `(): Type => ...`
    if (p.peek() == .r_paren) {
        _ = p.advance(); // consume `)`
        // TS return type annotation: `(): Type =>`
        p.in_return_type = true;
        const empty_arrow_return_type = try p.parseOptionalTypeAnnotation();
        p.in_return_type = false;
        if (p.peek() == .arrow and !p.isOnNewLine() and p.allow_arrow) {
            _ = p.advance(); // consume `=>`
            const saved_fn2 = p.in_function;
            const saved_async2 = p.in_async;
            p.in_function = true;
            p.in_async = false;
            defer p.in_function = saved_fn2;
            defer p.in_async = saved_async2;
            const empty_arrow_ev = try p.emitScopeOpen(.arrow_function, .none);
            // ConciseBody[?In]: restore outer allow_in before parsing body.
            p.allow_in = saved_allow_in_paren;
            const body = try parseArrowBody(p);
            try p.emitScopeClose(.none);
            const params_range = try p.addSlice(&[_]u32{});
            const extra = try p.addExtra(ast.ArrowData, .{
                .params_start = params_range.start,
                .params_end = params_range.end,
                .body = body,
                .return_type = empty_arrow_return_type,
            });
            const empty_arrow_node = try p.addNode(.{
                .tag = .arrow_fn,
                .main_token = open_paren,
                .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
            });
            p.patchScopeOpenNode(empty_arrow_ev, empty_arrow_node);
            return empty_arrow_node;
        }
        // Empty parens not followed by `=>` — error.
        try p.emitError("Unexpected token ')'");
        return p.makeErrorNode();
    }

    // TS arrow function fast path: if `(identifier :` or `(this :` or `(...` or `({` or `([`
    // followed by `:`, parse as typed arrow parameters.
    if (p.is_ts and looksLikeTsArrowParams(p)) {
        const saved_suppress2 = p.suppress_param_declares;
        p.suppress_param_declares = true;
        const params_range = try parseFormalParameters_inner(p, open_paren);
        p.suppress_param_declares = saved_suppress2;
        p.in_return_type = true;
        const typed_arrow_return_type = try p.parseOptionalTypeAnnotation(); // return type
        p.in_return_type = false;
        if (p.peek() == .arrow and !p.isOnNewLine()) {
            _ = p.advance(); // consume `=>`
            const saved_fn = p.in_function;
            const saved_async_ts = p.in_async;
            p.in_function = true;
            p.in_async = false;
            defer p.in_function = saved_fn;
            defer p.in_async = saved_async_ts;
            const typed_arrow_ev = try p.emitScopeOpen(.arrow_function, .none);
            try p.emitParamDeclaresFromRange(params_range);
            // ConciseBody[?In]: restore outer allow_in before parsing body.
            p.allow_in = saved_allow_in_paren;
            const body = try parseArrowBody(p);
            try p.emitScopeClose(.none);
            const extra = try p.addExtra(ast.ArrowData, .{
                .params_start = params_range.start,
                .params_end = params_range.end,
                .body = body,
                .return_type = typed_arrow_return_type,
            });
            const typed_arrow_node = try p.addNode(.{
                .tag = .arrow_fn,
                .main_token = open_paren,
                .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
            });
            p.patchScopeOpenNode(typed_arrow_ev, typed_arrow_node);
            return typed_arrow_node;
        }
        // Not an arrow — parsed params but no `=>`.  This is an error or a parenthesized expr.
        // Fall through to error or return first param as expression.
        if (params_range.end > params_range.start) {
            const first_param = NodeIndex.fromInt(p.extra_data.items[params_range.start]);
            return first_param;
        }
        return p.makeErrorNode();
    }

    // Parse first expression (may include spread for arrow params).
    const scratch_top = p.scratchLen();
    const first = try parseAssignmentOrSpread(p);
    try p.scratchPush(first);

    // Sequence: `(a, b, c)`
    var has_trailing_comma = false;
    while (p.peek() == .comma) {
        _ = p.advance(); // consume `,`
        if (p.peek() == .r_paren) {
            has_trailing_comma = true;
            break; // trailing comma — only valid if this becomes arrow params
        }
        const elem = try parseAssignmentOrSpread(p);
        try p.scratchPush(elem);
    }

    _ = try p.expect(.r_paren);

    // TS: `(params): ReturnType => body` — return type annotation before arrow.
    // Inside a conditional consequent (`cond ? (...) : alt`), the `:` is genuinely
    // ambiguous: it could open the conditional alternate OR be a typed-arrow return
    // annotation. Speculate the typed-arrow path; if we're in conditional context
    // and the parsed body doesn't leave a `:` for the conditional alternate, the
    // `:` we ate was the conditional separator — backtrack.
    if (p.is_ts and p.peek() == .colon) {
        const saved_tok = p.tok_i;
        const saved_diag_len = p.diagnostics.items.len;
        const saved_nodes_len = p.nodes.len;
        const saved_extra_len = p.extra_data.items.len;
        // Snapshot scratch contents so we can restore even after scratchPop.
        const params_count = p.scratch.items.len - scratch_top;
        var params_snapshot: [16]u32 = undefined;
        const can_snapshot = params_count <= params_snapshot.len;
        if (can_snapshot) {
            @memcpy(params_snapshot[0..params_count], p.scratch.items[scratch_top..]);
        }
        const colon_tok = p.advance(); // eat ':'
        const typescript = @import("typescript.zig");
        const prev_in_rt_spec = p.in_return_type;
        p.in_return_type = true;
        var ret_type_node: NodeIndex = .none;
        const type_ok = blk: {
            ret_type_node = typescript.parseType(p) catch break :blk false;
            break :blk true;
        };
        p.in_return_type = prev_in_rt_spec;
        // Wrap the parsed type in a ts_type_annotation so downstream
        // consumers can peel it consistently with parseOptionalTypeAnnotation.
        const ret_type_ann: NodeIndex = if (type_ok and ret_type_node != .none)
            try p.addNode(.{
                .tag = .ts_type_annotation,
                .main_token = colon_tok,
                .data = .{ .lhs = ret_type_node, .rhs = .none },
            })
        else
            .none;
        if (type_ok and p.peek() == .arrow and !p.isOnNewLine()) {
            const params = p.scratchSlice(scratch_top);
            for (params) |node_raw| {
                reinterpretAsPattern(p, NodeIndex.fromInt(node_raw));
            }
            for (params) |node_raw| {
                const pn = NodeIndex.fromInt(node_raw);
                if (pn != .none) try validatePattern(p, pn);
            }
            const params_range = try p.addSlice(params);
            p.scratchPop(scratch_top);
            _ = p.advance(); // consume `=>`
            const saved_fn5 = p.in_function;
            const saved_gen5 = p.in_generator;
            p.in_function = true;
            p.in_generator = false;
            p.syncYieldLex();
            defer p.in_function = saved_fn5;
            defer { p.in_generator = saved_gen5; p.syncYieldLex(); }
            // Body parses outside this conditional's consequent context; nested
            // conditionals inside the body should NOT re-trigger our backtrack.
            const saved_cc = p.in_conditional_consequent;
            p.in_conditional_consequent = false;
            const body = if (p.peek() == .l_brace)
                try parseBlockBodyWithStrictChecks(p, params_range, .none)
            else
                try parseAssignmentExpression(p);
            p.in_conditional_consequent = saved_cc;
            // If we were in conditional consequent and no `:` follows the body,
            // the typed-arrow interpretation stole the conditional separator.
            // Backtrack to bare-paren and let the caller see `:` again.
            if (saved_cc and p.peek() != .colon and can_snapshot) {
                p.tok_i = saved_tok;
                p.diagnostics.shrinkRetainingCapacity(saved_diag_len);
                p.nodes.len = @intCast(saved_nodes_len);
                p.extra_data.shrinkRetainingCapacity(saved_extra_len);
                // Restore scratch contents (scratchPop above truncated to scratch_top).
                p.scratch.shrinkRetainingCapacity(scratch_top);
                for (params_snapshot[0..params_count]) |raw| {
                    try p.scratch.append(p.gpa, raw);
                }
                // Fall through to the bare-paren interpretation below.
            } else {
                const extra = try p.addExtra(ast.ArrowData, .{
                    .params_start = params_range.start,
                    .params_end = params_range.end,
                    .body = body,
                    .return_type = ret_type_ann,
                });
                return p.addNode(.{
                    .tag = .arrow_fn,
                    .main_token = open_paren,
                    .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
                });
            }
        } else {
            // Type didn't parse or no `=>` — backtrack the type annotation only.
            p.tok_i = saved_tok;
            p.diagnostics.shrinkRetainingCapacity(saved_diag_len);
            p.nodes.len = @intCast(saved_nodes_len);
            p.extra_data.shrinkRetainingCapacity(saved_extra_len);
        }
    }

    // If `=>` follows, reinterpret as arrow parameters.
    if (p.peek() == .arrow and !p.isOnNewLine() and p.allow_arrow) {
        const params = p.scratchSlice(scratch_top);

        // Validate arrow parameters
        for (params, 0..) |node_raw, idx| {
            const param_node = NodeIndex.fromInt(node_raw);
            const param_tag = p.node_tags_ptr[param_node.toInt()];
            switch (param_tag) {
                .identifier => {
                    if (!p.is_ts) {
                        const tok = p.node_main_token_ptr[param_node.toInt()];
                        if (hasDuplicateParam(p, params, idx, tok)) {
                            try p.emitError("Duplicate parameter name in arrow function");
                            return p.makeErrorNode();
                        }
                    }
                },
                .assign, .assignment_pattern => {
                    // Recurse into LHS pattern for inner-parens validation.
                    validateArrowParam(p, param_node) catch {
                        return p.makeErrorNode();
                    };
                    // Check default expression for yield/await — spec early errors:
                    // "ArrowParameters Contains YieldExpression/AwaitExpression"
                    if (!p.is_ts) {
                        const d = p.node_data_ptr[param_node.toInt()];
                        if (d.rhs != .none) {
                            if (p.in_generator and
                                (containsNodeTag(p, d.rhs, .yield_expr) or
                                 containsNodeTag(p, d.rhs, .yield_delegate)))
                            {
                                try p.emitError("Arrow function parameters cannot contain yield expressions");
                                return p.makeErrorNode();
                            }
                            if (p.in_async and containsNodeTag(p, d.rhs, .await_expr)) {
                                try p.emitError("Arrow function parameters cannot contain await expressions");
                                return p.makeErrorNode();
                            }
                        }
                    }
                },
                .array_pattern, .object_pattern, .array_literal,
                .object_literal,
                => {
                    // Deep validate for member exprs, literals, etc.
                    validateArrowParam(p, param_node) catch {
                        return p.makeErrorNode();
                    };
                },
                .member_expr, .computed_member_expr, .call_expr,
                .getter_def, .setter_def, .method_def,
                => {
                    try p.emitError("Invalid destructuring in arrow function parameter");
                    return p.makeErrorNode();
                },
                .rest_element, .spread_element => {
                    if (!p.is_ts and idx < params.len - 1) {
                        try p.emitError("Rest parameter must be last");
                        return p.makeErrorNode();
                    }
                    // Trailing comma after rest is forbidden.
                    if (!p.is_ts and has_trailing_comma) {
                        try p.emitError("Rest parameter must not have a trailing comma");
                        return p.makeErrorNode();
                    }
                    // Validate rest target contents (reject literals in patterns)
                    if (!p.is_ts) {
                        const rest_data = p.node_data_ptr[param_node.toInt()];
                        if (rest_data.lhs != .none) {
                            const rest_tag = p.node_tags_ptr[rest_data.lhs.toInt()];
                            if (rest_tag == .assign or rest_tag == .assignment_pattern) {
                                try p.emitError("Rest parameter may not have a default initializer");
                                return p.makeErrorNode();
                            }
                            if (rest_tag == .identifier) {
                                const rest_tok = p.node_main_token_ptr[rest_data.lhs.toInt()];
                                if (hasDuplicateParam(p, params, idx, rest_tok)) {
                                    try p.emitError("Duplicate parameter name in arrow function");
                                    return p.makeErrorNode();
                                }
                            } else {
                                validateArrowParam(p, rest_data.lhs) catch {
                                    return p.makeErrorNode();
                                };
                            }
                        }
                    }
                },
                .yield_expr => {
                    // Bare `yield` (no operand) can be a parameter name in sloppy mode:
                    // arrows are never generators, so `yield` is an identifier inside them.
                    const d = p.node_data_ptr[param_node.toInt()];
                    if (!p.in_strict and !p.in_generator and d.lhs == .none) {
                        p.setNodeTag(param_node.toInt(), .identifier);
                    } else {
                        try p.emitError("Invalid arrow function parameter");
                        return p.makeErrorNode();
                    }
                },
                .number_literal, .string_literal, .boolean_literal,
                .null_literal, .this_expr, .grouping_expr,
                .yield_delegate, .await_expr,
                // sequence_expr: `(a, (b, c)) =>` — nested comma expression is not a valid param.
                .sequence_expr,
                => {
                    try p.emitError("Invalid arrow function parameter");
                    return p.makeErrorNode();
                },
                else => {},
            }
        }

        for (params) |node_raw| {
            reinterpretAsPattern(p, NodeIndex.fromInt(node_raw));
        }
        for (params) |node_raw| {
            const pn = NodeIndex.fromInt(node_raw);
            if (pn != .none) try validatePattern(p, pn);
        }

        // Check strict-mode restrictions on arrow params
        if (p.in_strict) {
            for (params) |node_raw| {
                const param_node = NodeIndex.fromInt(node_raw);
                if (param_node == .none) continue;
                const pt = p.node_tags_ptr[param_node.toInt()];
                if (pt == .identifier) {
                    const ptok = p.node_main_token_ptr[param_node.toInt()];
                    try p.checkStrictBinding(ptok);
                }
            }
        }

        const params_range = try p.addSlice(params);
        p.scratchPop(scratch_top);

        _ = p.advance(); // consume `=>`

        const saved_fn3 = p.in_function;
        const saved_gen3 = p.in_generator;
        const saved_async3 = p.in_async;
        p.in_function = true;
        p.in_generator = false;
        p.in_async = false;
        p.syncYieldLex();
        defer p.in_function = saved_fn3;
        defer { p.in_generator = saved_gen3; p.syncYieldLex(); }
        defer p.in_async = saved_async3;

        // Arrow scope — params were parsed as expression identifiers and
        // emitted reference events into the enclosing scope; those become
        // orphan refs, but the arrow body's own refs resolve correctly here.
        const paren_arrow_ev = try p.emitScopeOpen(.arrow_function, .none);
        try p.emitParamDeclaresFromRange(params_range);

        // Arrow params: spec rejects duplicate parameter names always.
        try p.checkUniqueParams(params_range);

        // Arrow body: block { } with strict checks, or concise expression.
        // ConciseBody[?In]: the spec propagates [?In] to the concise body, so
        // `for (() => x in y;;)` must see `allow_in=false` inside the concise body —
        // otherwise `x in y` would be parsed as a binary expression instead of
        // stopping at `in` and making the outer for-loop look like a for-in.
        // Block bodies always allow `in` (FunctionBody is always [In]).
        const body = if (p.peek() == .l_brace)
            try parseBlockBodyWithStrictChecks(p, params_range, .none)
        else blk: {
            p.allow_in = saved_allow_in_paren;
            break :blk try parseAssignmentExpression(p);
        };

        try p.emitScopeClose(.none);

        const extra = try p.addExtra(ast.ArrowData, .{
            .params_start = params_range.start,
            .params_end = params_range.end,
            .body = body,
        });
        const paren_arrow_node = try p.addNode(.{
            .tag = .arrow_fn,
            .main_token = open_paren,
            .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
        });
        p.patchScopeOpenNode(paren_arrow_ev, paren_arrow_node);
        return paren_arrow_node;
    }

    // Not an arrow — validate no spread elements (spread is only valid in arrows, arrays, calls)
    // If we had trailing comma but no arrow, it's invalid
    if (has_trailing_comma) {
        try p.emitError("Unexpected trailing comma in parenthesized expression");
    }

    const elems = p.scratchSlice(scratch_top);
    for (elems) |elem_raw| {
        const elem_node = NodeIndex.fromInt(elem_raw);
        if (elem_node != .none and p.node_tags_ptr[elem_node.toInt()] == .spread_element) {
            try p.emitError("Unexpected spread in parenthesized expression (not an arrow function)");
        }
    }

    if (elems.len == 1) {
        const first_tag = p.node_tags_ptr[first.toInt()];

        // Parenthesized super is invalid — super must be followed directly by `.`, `[`, or `(`
        if (first_tag == .super_expr) {
            try p.emitError("'super' keyword unexpected here");
        }

        // Check for CoverInitializedName: ({a = 0}) without => is invalid
        if (first_tag == .object_literal) {
            const d = p.node_data_ptr[first.toInt()];
            const s = d.lhs.toInt();
            const e = d.rhs.toInt();
            var i = s;
            while (i < e) : (i += 1) {
                const prop = NodeIndex.fromInt(p.extra_data.items[i]);
                if (prop != .none) {
                    const pt = p.node_tags_ptr[prop.toInt()];
                    if (pt == .assignment_pattern) {
                        try p.emitError("Invalid shorthand property initializer (not a destructuring pattern)");
                    }
                }
            }
        }

        p.scratchPop(scratch_top);
        return p.addNode(.{
            .tag = .grouping_expr,
            .main_token = open_paren,
            .data = .{ .lhs = first, .rhs = .none },
        });
    }

    // Multiple comma-separated → sequence expression.
    const range = try p.addSlice(elems);
    p.scratchPop(scratch_top);
    return p.addNode(.{
        .tag = .sequence_expr,
        .main_token = open_paren,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// ── Arrow function body (expression or block) ────────────────────

fn parseArrowBody(p: *Parser) Error!NodeIndex {
    // Arrow functions are never generators — reset in_generator so that
    // `yield` is treated as an identifier inside the arrow body.
    const saved_gen = p.in_generator;
    p.in_generator = false;
    p.syncYieldLex();
    defer { p.in_generator = saved_gen; p.syncYieldLex(); }
    // Arrow body clears the outer fn-param context.
    const saved_fp_ab = p.in_fn_params;
    p.in_fn_params = false;
    defer p.in_fn_params = saved_fp_ab;
    if (p.peek() == .l_brace) {
        // Entering a new function body: always allow `in` operator.
        // The `allow_in = false` flag from a for-loop init must not propagate
        // into arrow function bodies (per spec, a new function scope resets it).
        const saved_allow_in = p.allow_in;
        p.allow_in = true;
        defer p.allow_in = saved_allow_in;
        return parseBlockBody(p);
    }
    return parseAssignmentExpression(p);
}

/// Build an arrow node for a single-parameter arrow: `ident => body`.
/// `param_tok` is the identifier token for the parameter.
fn parseArrowFunctionBody(p: *Parser, param_tok: TokenIndex, is_async: bool) Error!NodeIndex {
    // For `async x => ...`, the `async` keyword is the actual start of
    // the async_arrow_fn node — record it for nodeSpan / range
    // computation.  Without this, the span begins at the parameter
    // identifier and rules like `strict-boolean-expressions` anchor
    // their `predicateCannotBeAsync` diagnostic at the wrong column.
    const start_tok: TokenIndex = if (is_async and param_tok > 0) param_tok - 1 else param_tok;
    // Check strict-mode restrictions on the single parameter
    try p.checkStrictBinding(param_tok);

    // Create the parameter node BEFORE advancing past `=>`, so its end_tok
    // records the identifier (not the arrow). Without this, sourceCode.getText
    // on the param returns "name => " — breaks rules like unicorn/no-array-for-each
    // which extract the parameter source to build a fix.
    const param_node = try p.addNode(.{
        .tag = .identifier,
        .main_token = param_tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });

    const arrow_tok = p.advance(); // consume `=>`
    _ = arrow_tok;

    const params = try p.addSlice(&[_]u32{param_node.toInt()});

    // Arrow function scope: the parameter binds inside it.
    const single_arrow_ev = try p.emitScopeOpen(.arrow_function, .none);
    try p.emitDeclare(.parameter, param_node);

    // Reset decl_name_text: arrow body should not inherit outer binding name.
    const saved_decl_name_arrow = p.decl_name_text;
    p.decl_name_text = &.{};
    defer p.decl_name_text = saved_decl_name_arrow;

    const saved_fn = p.in_function;
    const saved_async = p.in_async;
    p.in_function = true;
    p.in_async = is_async;
    defer p.in_function = saved_fn;
    defer p.in_async = saved_async;
    // Use parseBlockBodyWithStrictChecks for block bodies to retroactively validate
    // the parameter against any "use strict" directive in the body (e.g. `eval => {"use strict"}`).
    const body = if (p.peek() == .l_brace)
        try parseBlockBodyWithStrictChecks(p, params, .none)
    else
        try parseArrowBody(p);
    try p.emitScopeClose(.none);

    const extra = try p.addExtra(ast.ArrowData, .{
        .params_start = params.start,
        .params_end = params.end,
        .body = body,
    });
    const fn_tag: Node.Tag = if (is_async) .async_arrow_fn else .arrow_fn;
    const arrow_node = try p.addNode(.{
        .tag = fn_tag,
        .main_token = start_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
    });
    p.patchScopeOpenNode(single_arrow_ev, arrow_node);
    return arrow_node;
}

// ── Parse assignment-level expression or spread ──────────────────

inline fn parseAssignmentOrSpread(p: *Parser) Error!NodeIndex {
    if (p.peek() == .ellipsis) {
        const tok = p.advance();
        const arg = try parseAssignmentExpression(p);
        return p.addNode(.{
            .tag = .spread_element,
            .main_token = tok,
            .data = .{ .lhs = arg, .rhs = .none },
        });
    }
    return parseAssignmentExpression(p);
}

// =====================================================================
// Array literal
// =====================================================================

fn parseArrayLiteral(p: *Parser) Error!NodeIndex {
    const open = p.advance(); // consume `[`
    const scratch_top = p.scratchLen();
    // Array elements allow `in` even in for-loop context (for destructuring defaults)
    const saved_allow_in_arr = p.allow_in;
    p.allow_in = true;
    defer p.allow_in = saved_allow_in_arr;

    while (p.peek() != .r_bracket and p.peek() != .eof) {
        // Elision (hole): consecutive commas
        if (p.peek() == .comma) {
            // Push a .none element to represent the hole.
            try p.scratchPush(NodeIndex.none);
            _ = p.advance();
            continue;
        }

        const elem = try parseAssignmentOrSpread(p);
        try p.scratchPush(elem);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_bracket);

    const elements = p.scratchSlice(scratch_top);

    // Check rest/spread with trailing comma: `[...a,]` is valid as array literal (expression),
    // but invalid in destructuring `[...a,] = b`. We record the trailing comma presence
    // by pushing a .none sentinel after the spread, so validatePattern can detect it.
    if (elements.len > 0) {
        const last_elem = NodeIndex.fromInt(elements[elements.len - 1]);
        if (last_elem != .none and p.node_tags_ptr[last_elem.toInt()] == .spread_element) {
            // Check if there was a trailing comma (consumed at line above)
            if (p.tok_i > 0 and p.tokenTagAt(@intCast(p.tok_i - 1)) == .r_bracket and
                p.tok_i > 1 and p.tokenTagAt(@intCast(p.tok_i - 2)) == .comma)
            {
                // Push a .none sentinel so validatePattern can detect the trailing comma
                try p.scratchPush(NodeIndex.none);
            }
        }
    }
    // Re-read elements after possible sentinel push
    const final_elements = p.scratchSlice(scratch_top);
    _ = final_elements;

    const range = try p.addSlice(p.scratchSlice(scratch_top));
    p.scratchPop(scratch_top);

    return p.addNode(.{
        .tag = .array_literal,
        .main_token = open,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// Object literal
// =====================================================================

fn parseObjectLiteral(p: *Parser) Error!NodeIndex {
    const open = p.advance(); // consume `{`
    const scratch_top = p.scratchLen();

    // TS1117: track property names to detect duplicates.
    // Getter+setter pair with same name is allowed; all other duplicates are errors.
    // is_computed=true for [expr] keys; only compare computed vs computed (not computed vs literal).
    const SeenProp = struct { key: []const u8, is_getter: bool, is_setter: bool, is_computed: bool };
    var seen_buf: [64]SeenProp = undefined;
    // Per-slot buffers to hold formatted numeric canonical keys (e.g. "1" for 1.0).
    var seen_num_bufs: [64][32]u8 = undefined;
    var seen_count: usize = 0;

    while (p.peek() != .r_brace and p.peek() != .eof) {
        const prop = try parseObjectProperty(p);
        try p.scratchPush(prop);

        // TS1117: duplicate key:value property names in TypeScript mode.
        // Only checks .property nodes (colon syntax). Method shorthand and getter/setter
        // pairs are NOT flagged here (they become TS2300 semantic errors or are allowed).
        // Private names (#x) are skipped.
        // Properties whose value is a plain identifier are skipped to avoid false rejects
        // in cover grammar: `{ a: x, a: y }` might be a destructuring pattern LHS.
        if (p.is_ts and p.node_tags_ptr[prop.toInt()] == .property) {
            const pdata = p.node_data_ptr[prop.toInt()];
            const key_node = pdata.lhs;
            const val_node = pdata.rhs;
            const val_is_ident = val_node != .none and p.node_tags_ptr[val_node.toInt()] == .identifier;
            if (!val_is_ident and key_node != .none) {
                // Compute canonical key: ident/string → text, number → normalized string.
                const key_canonical: ?[]const u8 = blk: {
                    const ktag = p.node_tags_ptr[key_node.toInt()];
                    const ktok = p.node_main_token_ptr[key_node.toInt()];
                    if (ktag == .identifier) {
                        const name = p.tokenText(ktok);
                        if (name.len > 0 and name[0] == '#') break :blk null;
                        break :blk name;
                    } else if (ktag == .string_literal) {
                        const start = p.tok_starts_ptr[ktok];
                        break :blk p.getStringContent(start);
                    } else if (ktag == .number_literal) {
                        const text = p.tokenText(ktok);
                        const val = std.fmt.parseFloat(f64, text) catch break :blk null;
                        if (std.math.isNan(val) or std.math.isInf(val)) break :blk null;
                        if (seen_count >= seen_buf.len) break :blk null;
                        // Normalize: if the value is a non-negative integer, use integer form.
                        const canonical = if (val >= 0 and val == @trunc(val) and val < 1e15)
                            std.fmt.bufPrint(&seen_num_bufs[seen_count], "{d}", .{@as(u64, @intFromFloat(val))}) catch break :blk null
                        else
                            std.fmt.bufPrint(&seen_num_bufs[seen_count], "{d}", .{val}) catch break :blk null;
                        break :blk canonical;
                    } else break :blk null;
                };
                if (key_canonical) |name| {
                    for (seen_buf[0..seen_count]) |seen| {
                        if (std.mem.eql(u8, seen.key, name)) {
                            // Computed key `[x]` where x is an identifier shouldn't
                            // duplicate literal key `x:` — they represent different values.
                            // Computed keys with literal text (number/string) CAN duplicate.
                            if (seen.is_computed) {
                                const key_is_literal = name.len > 0 and
                                    ((name[0] >= '0' and name[0] <= '9') or
                                    name[0] == '"' or name[0] == '\'' or name[0] == '`');
                                if (!key_is_literal) continue;
                            }
                            try p.emitDiagnostic(p.currentSpan(), "An object literal cannot have multiple properties with the same name", .{});
                            break;
                        }
                    }
                    if (seen_count < seen_buf.len) {
                        seen_buf[seen_count] = .{ .key = name, .is_getter = false, .is_setter = false, .is_computed = false };
                        seen_count += 1;
                    }
                }
            }
        }

        // TS1117: duplicate computed property keys — compare source text of [key] spans.
        if (p.is_ts and p.node_tags_ptr[prop.toInt()] == .computed_property) {
            const open_bracket = p.node_main_token_ptr[prop.toInt()]; // `[` token
            // Scan forward to find the matching `]`, tracking bracket depth.
            var depth: u32 = 1;
            var r_tok = open_bracket + 1;
            while (r_tok < p.parsed_len and depth > 0) : (r_tok += 1) {
                switch (p.tags_ptr[r_tok]) {
                    .l_bracket => depth += 1,
                    .r_bracket => depth -= 1,
                    else => {},
                }
            }
            // r_tok is now one past the `]`; r_tok-1 is the `]`.
            const open_pos = p.tok_starts_ptr[open_bracket];
            const r_pos = if (r_tok > 0 and r_tok - 1 < p.parsed_len)
                p.tok_starts_ptr[r_tok - 1]
            else
                p.source.len;
            if (open_pos + 1 <= r_pos) {
                const key_text = std.mem.trim(u8, p.source[open_pos + 1 .. r_pos], " \t\r\n");
                if (key_text.len > 0) {
                    // Only compare against literal (non-computed) keys if the computed key
                    // source text represents a literal value (number/string), not an identifier
                    // or complex expression. `[num]` with source "num" is an identifier whose
                    // runtime value differs from literal key "num".
                    const key_looks_like_literal = key_text[0] == '"' or key_text[0] == '\'' or
                        key_text[0] == '`' or (key_text[0] >= '0' and key_text[0] <= '9') or
                        key_text[0] == '+' or key_text[0] == '-';
                    // Skip computed-vs-computed comparison when the source text contains binary
                    // operators (e.g., 'foo'+'' is a compound expression TypeScript doesn't track).
                    const key_has_binary_ops = std.mem.indexOfAny(u8, key_text, "+*|&^") != null;
                    for (seen_buf[0..seen_count]) |seen| {
                        const match = if (seen.is_computed)
                            !key_has_binary_ops and std.mem.eql(u8, seen.key, key_text)
                        else
                            key_looks_like_literal and std.mem.eql(u8, seen.key, key_text);
                        if (match) {
                            try p.emitDiagnostic(p.currentSpan(), "An object literal cannot have multiple properties with the same name", .{});
                            break;
                        }
                    }
                    if (seen_count < seen_buf.len) {
                        seen_buf[seen_count] = .{ .key = key_text, .is_getter = false, .is_setter = false, .is_computed = true };
                        seen_count += 1;
                    }
                }
            }
        }

        // TS1118: duplicate get/set accessors with same name in object literal.
        if (p.is_ts) {
            const prop_tag = p.node_tags_ptr[prop.toInt()];
            if (prop_tag == .getter_def or prop_tag == .setter_def) {
                const is_getter = prop_tag == .getter_def;
                const key_node = p.node_data_ptr[prop.toInt()].lhs;
                if (key_node != .none) {
                    const key_tok = p.node_main_token_ptr[key_node.toInt()];
                    const name = p.tokenText(key_tok);
                    var gsfound = false;
                    for (seen_buf[0..seen_count]) |*seen| {
                        if (std.mem.eql(u8, seen.key, name)) {
                            gsfound = true;
                            if ((is_getter and seen.is_getter) or (!is_getter and seen.is_setter)) {
                                try p.emitDiagnostic(p.currentSpan(), "An object literal cannot have multiple get/set accessors with the same name", .{});
                            }
                            if (is_getter) seen.is_getter = true else seen.is_setter = true;
                            break;
                        }
                    }
                    if (!gsfound and seen_count < seen_buf.len) {
                        seen_buf[seen_count] = .{ .key = name, .is_getter = is_getter, .is_setter = !is_getter, .is_computed = false };
                        seen_count += 1;
                    }
                }
            }
        }

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_brace);

    const props = p.scratchSlice(scratch_top);
    // Trailing comma after rest is valid in object literal but invalid as destructuring
    // pattern. Push a .none sentinel so reinterpretAsPattern can detect it.
    if (props.len > 0) {
        const last_prop = NodeIndex.fromInt(props[props.len - 1]);
        if (last_prop != .none and p.node_tags_ptr[last_prop.toInt()] == .spread_element) {
            if (p.tok_i > 1 and p.tokenTagAt(@intCast(p.tok_i - 1)) == .r_brace and
                p.tokenTagAt(@intCast(p.tok_i - 2)) == .comma)
            {
                try p.scratchPush(NodeIndex.none);
            }
        }
    }

    const range = try p.addSlice(p.scratchSlice(scratch_top));
    p.scratchPop(scratch_top);

    const node = try p.addNode(.{
        .tag = .object_literal,
        .main_token = open,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
    // Register this node for the post-parse __proto__ duplicate scan (JS mode only).
    // TS mode skips the scan; the TS type-checker handles duplicate property errors.
    if (!p.is_ts) {
        try p.proto_check_nodes.append(p.gpa, @intFromEnum(node));
    }
    return node;
}

fn parseObjectProperty(p: *Parser) Error!NodeIndex {
    const tag = p.peek();

    // Private names (#x) are only valid in class bodies, not object literals.
    // Catch direct `#x:` form here; methods (get/set/async/generator with #x)
    // are caught after the prefix consumption (e.g. `async * #x` → peek after async/* is .hash).
    // TypeScript emits only type-level errors for these cases, so skip in TS mode.
    if (!p.is_ts) {
        if (tag == .hash) {
            try p.emitError("Private fields can only be declared in classes");
        }
        if ((tag == .kw_get or tag == .kw_set) and p.peekAt(1) == .hash) {
            try p.emitError("Private fields can only be declared in classes");
        }
        if (tag == .asterisk and p.peekAt(1) == .hash) {
            try p.emitError("Private fields can only be declared in classes");
        }
        if (tag == .kw_async) {
            if (p.peekAt(1) == .hash) try p.emitError("Private fields can only be declared in classes");
            if (p.peekAt(1) == .asterisk and p.peekAt(2) == .hash) try p.emitError("Private fields can only be declared in classes");
        }
    }

    // Spread: `...expr`
    if (tag == .ellipsis) {
        const tok = p.advance();
        const arg = try parseAssignmentExpression(p);
        return p.addNode(.{
            .tag = .spread_element,
            .main_token = tok,
            .data = .{ .lhs = arg, .rhs = .none },
        });
    }

    // `get` / `set` methods:  get name() { } / set name(v) { }
    if ((tag == .kw_get or tag == .kw_set) and isPropertyNameStart(p.peekAt(1))) {
        return parseGetterSetter(p);
    }

    // `async` method: async name() { }  or  async * name() { }
    if (tag == .kw_async and !p.isOnNewLineAt(1) and isMethodStart(p.peekAt(1))) {
        return parseAsyncMethod(p);
    }

    // Generator method: * name() { }
    if (tag == .asterisk) {
        return parseGeneratorMethod(p);
    }

    // Computed property: [expr]: value  or  [expr]() { }
    if (tag == .l_bracket) {
        return parseComputedProperty(p);
    }

    // Regular property or shorthand.
    return parseRegularProperty(p);
}

fn parseGetterSetter(p: *Parser) Error!NodeIndex {
    const accessor_tok = p.advance(); // consume `get` or `set`
    const accessor_tag = p.tokenTag(accessor_tok);

    const is_computed = p.peek() == .l_bracket;
    const computed_open: u32 = p.tokIdx(); // save `[` token index for computed case
    const key = try parsePropertyName(p);

    // Set method flags BEFORE parsing params so super works in setter param defaults.
    // Reset in_generator — getters/setters are never generators, so `yield` is a valid binding.
    const saved_fn = p.in_function;
    const saved_method = p.in_method;
    const saved_gen_gs = p.in_generator;
    const saved_async_gs = p.in_async;
    const saved_cf_gs = p.in_class_field;
    p.in_function = true;
    p.in_method = true;
    const _saved_nta_x = p.new_target_allowed;
    p.new_target_allowed = true;
    defer p.new_target_allowed = _saved_nta_x;
    p.in_generator = false;
    p.in_async = false;
    p.in_class_field = false;
    p.syncYieldLex();
    defer p.in_function = saved_fn;
    defer p.in_method = saved_method;
    defer { p.in_generator = saved_gen_gs; p.syncYieldLex(); }
    defer p.in_async = saved_async_gs;
    defer p.in_class_field = saved_cf_gs;

    // Parse function part
    const gs_scope_ev = try p.emitScopeOpen(.function, .none);
    _ = try p.expect(.l_paren);

    // Validate getter/setter parameter count before parsing (skip in TS — type error not syntax)
    if (!p.is_ts) {
        if (accessor_tag == .kw_get and p.peek() != .r_paren) {
            try p.emitError("Getter must have zero parameters");
            return error.ParseError;
        }
        if (accessor_tag == .kw_set and p.peek() == .r_paren) {
            try p.emitError("Setter must have exactly one parameter");
            return error.ParseError;
        }
    }

    const params_range = if (accessor_tag == .kw_set) blk: {
        const scratch_top = p.scratchLen();

        // TS: skip `this` parameter in setter: `set x(this: Type, value)`
        if (p.is_ts and p.peek() == .kw_this) {
            const this_tok = p.advance();
            if (p.peek() == .colon) {
                _ = try p.parseOptionalTypeAnnotation();
            }
            if (p.peek() == .comma) _ = p.advance();
            // Add `this` as a pseudo-param node
            const this_node = try p.addNode(.{
                .tag = .identifier,
                .main_token = this_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            try p.scratchPush(this_node);
        }

        const param = try parseBindingElement(p);
        const param_tag = p.node_tags_ptr[param.toInt()];
        // Setter param must not be rest
        if (param_tag == .rest_element) {
            try p.emitError("Setter parameter must not be a rest parameter");
            return error.ParseError;
        }
        // In strict mode, eval/arguments cannot be setter param names
        if (p.in_strict and param_tag == .identifier) {
            const param_name = p.tokenText(p.node_main_token_ptr[param.toInt()]);
            if (std.mem.eql(u8, param_name, "eval") or std.mem.eql(u8, param_name, "arguments")) {
                try p.emitError("'eval' or 'arguments' can't be used as parameter name in strict mode");
                return error.ParseError;
            }
        }
        // TS1052: A 'set' accessor parameter cannot have an initializer.
        if (p.is_ts and param_tag == .assignment_pattern) {
            try p.emitError("A 'set' accessor parameter cannot have an initializer");
        }
        // TS1051: A 'set' accessor cannot have an optional parameter.
        if (p.is_ts and param_tag == .identifier and p.node_data_ptr[param.toInt()].lhs == .root) {
            try p.emitError("A 'set' accessor cannot have an optional parameter");
        }
        try p.scratchPush(param);
        // Trailing comma after setter param is valid: `set x(a,) {}`
        if (p.peek() == .comma and p.peekAt(1) == .r_paren) {
            _ = p.advance(); // consume trailing comma
        } else if (p.peek() == .comma) {
            if (!p.is_ts) {
                try p.emitError("Setter must have exactly one parameter");
                return error.ParseError;
            }
            // TS1049: A 'set' accessor must have exactly one parameter.
            try p.emitError("A 'set' accessor must have exactly one parameter");
            // skip extra params to avoid cascading errors
            while (p.peek() == .comma) {
                _ = p.advance();
                if (p.peek() == .r_paren) break;
                _ = try parseBindingElement(p);
            }
        }
        const params = p.scratchSlice(scratch_top);
        const range = try p.addSlice(params);
        p.scratchPop(scratch_top);
        break :blk range;
    } else blk: {
        // TS: getter can have a `this` parameter: `get x(this: Type)`
        if (p.is_ts and p.peek() == .kw_this) {
            const scratch_top = p.scratchLen();
            const this_tok = p.advance();
            if (p.peek() == .colon) {
                _ = try p.parseOptionalTypeAnnotation();
            }
            const this_node = try p.addNode(.{
                .tag = .identifier,
                .main_token = this_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            try p.scratchPush(this_node);
            const params = p.scratchSlice(scratch_top);
            const range = try p.addSlice(params);
            p.scratchPop(scratch_top);
            break :blk range;
        }
        break :blk try p.addSlice(&[_]u32{});
    };

    _ = try p.expect(.r_paren);
    p.in_return_type = true;
    const gs_return_type = try p.parseOptionalTypeAnnotation(); // TS return type
    p.in_return_type = false;
    // TS1095: A 'set' accessor cannot have a return type annotation.
    if (p.is_ts and accessor_tag == .kw_set and gs_return_type != .none) {
        try p.emitError("A 'set' accessor cannot have a return type annotation");
    }

    const body = try parseBlockBodyWithStrictChecks(p, params_range, .none);

    const method_extra = try p.addExtra(ast.MethodData, .{
        .params_start = params_range.start,
        .params_end = params_range.end,
        .body = body,
    });

    try p.emitScopeClose(.none);
    const node_tag: Node.Tag = if (accessor_tag == .kw_get)
        (if (is_computed) .computed_getter_def else .getter_def)
    else
        (if (is_computed) .computed_setter_def else .setter_def);
    const gs_node = try p.addNode(.{
        .tag = node_tag,
        .main_token = if (is_computed) computed_open else accessor_tok,
        .data = .{ .lhs = key, .rhs = NodeIndex.fromInt(method_extra) },
    });
    p.patchScopeOpenNode(gs_scope_ev, gs_node);
    return gs_node;
}

fn parseAsyncMethod(p: *Parser) Error!NodeIndex {
    const async_tok = p.advance(); // consume `async`
    const is_generator = p.peek() == .asterisk;
    if (is_generator) _ = p.advance();

    const is_computed = p.peek() == .l_bracket;
    const computed_open: u32 = p.tokIdx(); // save `[` token index for computed case
    const key = try parsePropertyName(p);

    // Set flags BEFORE parsing params
    const saved_fn = p.in_function;
    const saved_async = p.in_async;
    const saved_gen = p.in_generator;
    const saved_method = p.in_method;
    const saved_cf_am = p.in_class_field;
    p.in_function = true;
    p.in_async = true;
    p.in_generator = is_generator;
    p.in_method = true;
    const _saved_nta_x = p.new_target_allowed;
    p.new_target_allowed = true;
    defer p.new_target_allowed = _saved_nta_x;
    p.in_class_field = false;
    p.syncYieldLex();
    defer p.in_function = saved_fn;
    defer p.in_async = saved_async;
    defer { p.in_generator = saved_gen; p.syncYieldLex(); }
    defer p.in_method = saved_method;
    defer p.in_class_field = saved_cf_am;

    const async_method_type_params = try p.parseOptionalTypeParameters();
    const async_method_scope_ev = try p.emitScopeOpen(.function, .none);
    const params_range = try parseFormalParameters(p);
    const async_method_return_type = try p.parseOptionalTypeAnnotation();
    const body = try parseBlockBodyWithStrictChecks(p, params_range, .none);
    try p.emitScopeClose(.none);

    const method_extra = try p.addExtra(ast.MethodData, .{
        .params_start = params_range.start,
        .params_end = params_range.end,
        .body = body,
        .return_type = async_method_return_type,
        .modifiers = ast.ModifierBit.@"async" | (if (is_generator) ast.ModifierBit.generator else 0),
        .type_params = async_method_type_params.start,
        .type_params_end = async_method_type_params.end,
    });
    const async_method_node = try p.addNode(.{
        .tag = if (is_computed) .computed_method_def else .method_def,
        .main_token = if (is_computed) computed_open else async_tok,
        .data = .{ .lhs = key, .rhs = NodeIndex.fromInt(method_extra) },
    });
    p.patchScopeOpenNode(async_method_scope_ev, async_method_node);
    return async_method_node;
}

fn parseGeneratorMethod(p: *Parser) Error!NodeIndex {
    const star_tok = p.advance(); // consume `*`

    const is_computed = p.peek() == .l_bracket;
    const computed_open: u32 = p.tokIdx(); // save `[` token index for computed case
    const key = try parsePropertyName(p);

    // Set flags BEFORE parsing params
    const saved_fn = p.in_function;
    const saved_gen = p.in_generator;
    const saved_method = p.in_method;
    const saved_cf_gm = p.in_class_field;
    p.in_function = true;
    p.in_generator = true;
    p.in_method = true;
    const _saved_nta_x = p.new_target_allowed;
    p.new_target_allowed = true;
    defer p.new_target_allowed = _saved_nta_x;
    p.in_class_field = false;
    p.syncYieldLex();
    defer p.in_function = saved_fn;
    defer { p.in_generator = saved_gen; p.syncYieldLex(); }
    defer p.in_method = saved_method;
    defer p.in_class_field = saved_cf_gm;

    const gen_method_type_params = try p.parseOptionalTypeParameters();
    const gen_method_scope_ev = try p.emitScopeOpen(.function, .none);
    const params_range = try parseFormalParameters(p);
    p.in_return_type = true;
    const gen_method_return_type = try p.parseOptionalTypeAnnotation(); // TS return type
    p.in_return_type = false;
    const body = try parseBlockBodyWithStrictChecks(p, params_range, .none);
    try p.emitScopeClose(.none);

    const method_extra = try p.addExtra(ast.MethodData, .{
        .params_start = params_range.start,
        .params_end = params_range.end,
        .body = body,
        .return_type = gen_method_return_type,
        .modifiers = ast.ModifierBit.generator,
        .type_params = gen_method_type_params.start,
        .type_params_end = gen_method_type_params.end,
    });
    const gen_method_node = try p.addNode(.{
        .tag = if (is_computed) .computed_method_def else .method_def,
        .main_token = if (is_computed) computed_open else star_tok,
        .data = .{ .lhs = key, .rhs = NodeIndex.fromInt(method_extra) },
    });
    p.patchScopeOpenNode(gen_method_scope_ev, gen_method_node);
    return gen_method_node;
}

fn parseComputedProperty(p: *Parser) Error!NodeIndex {
    const open = p.advance(); // consume `[`
    // Computed property keys always allow `in` (e.g. `{ ['x' in obj]() {} }` in for-loop)
    const saved_allow_in = p.allow_in;
    p.allow_in = true;
    defer p.allow_in = saved_allow_in;
    const key_expr = try parseAssignmentExpression(p);
    _ = try p.expect(.r_bracket);

    // TS type parameters on computed method: [expr]<T>()
    var comp_method_type_params = ast.SubRange{ .start = 0, .end = 0 };
    if (p.is_ts and p.peek() == .less_than) {
        const ts_mod = @import("typescript.zig");
        comp_method_type_params = try ts_mod.parseTypeParameterList(p);
    }

    // Computed method: [expr]() { }
    if (p.peek() == .l_paren) {
        const saved_fn = p.in_function;
        const saved_method = p.in_method;
        p.in_function = true;
        p.in_method = true;
        const _saved_nta_x = p.new_target_allowed;
        p.new_target_allowed = true;
        defer p.new_target_allowed = _saved_nta_x;
        defer p.in_function = saved_fn;
        defer p.in_method = saved_method;
        const comp_method_scope_ev = try p.emitScopeOpen(.function, .none);
        const params_range = try parseFormalParameters(p);
        p.in_return_type = true;
        const comp_method_return_type = try p.parseOptionalTypeAnnotation(); // TS return type
        p.in_return_type = false;
        const body = try parseBlockBodyWithStrictChecks(p, params_range, .none);
        try p.emitScopeClose(.none);
        const method_extra = try p.addExtra(ast.MethodData, .{
            .params_start = params_range.start,
            .params_end = params_range.end,
            .body = body,
            .return_type = comp_method_return_type,
            .type_params = comp_method_type_params.start,
            .type_params_end = comp_method_type_params.end,
        });
        const comp_method_node = try p.addNode(.{
            .tag = .computed_method_def,
            .main_token = open,
            .data = .{ .lhs = key_expr, .rhs = NodeIndex.fromInt(method_extra) },
        });
        p.patchScopeOpenNode(comp_method_scope_ev, comp_method_node);
        return comp_method_node;
    }

    // Computed property: [expr]: value (only valid in object literals, not class bodies)
    // In TS class bodies, [expr]: Type is valid (computed field with type annotation)
    // When inside a function/method body (in_function=true), we are NOT at class-body level
    // even if in_class is still set — so [expr]: val in object literals is valid.
    if (p.peek() == .colon) {
        if (p.in_class and !p.in_function and !p.is_ts) {
            try p.emitError("Unexpected ':' in class body (use '=' for field initializers)");
            return error.ParseError;
        }
        _ = p.advance();
        const value = try parseAssignmentExpression(p);
        return p.addNode(.{
            .tag = .computed_property,
            .main_token = open,
            .data = .{ .lhs = key_expr, .rhs = value },
        });
    }

    // Computed field with initializer (class body)
    if (p.peek() == .equal) {
        _ = p.advance();
        const value = try parseAssignmentExpression(p);
        _ = p.eat(.semicolon);
        const comp_extra = try p.addExtra(ast.PropertyData, .{ .value = value, .type_annotation = .none });
        return p.addNode(.{
            .tag = .computed_property_def,
            .main_token = open,
            .data = .{ .lhs = key_expr, .rhs = NodeIndex.fromInt(comp_extra) },
        });
    }

    // Computed field without initializer (class body)
    if (p.in_class) {
        _ = p.eat(.semicolon);
        const comp_extra_empty = try p.addExtra(ast.PropertyData, .{});
        return p.addNode(.{
            .tag = .computed_property_def,
            .main_token = open,
            .data = .{ .lhs = key_expr, .rhs = NodeIndex.fromInt(comp_extra_empty) },
        });
    }

    try p.emitError("Expected ':' or '(' after computed property name");
    return p.makeErrorNode();
}

fn parseRegularProperty(p: *Parser) Error!NodeIndex {
    const key_tok: u32 = p.tokIdx();
    const key = try parsePropertyName(p);

    // TS generic method: name<T>() { }
    var reg_method_type_params = ast.SubRange{ .start = 0, .end = 0 };
    if (p.is_ts and p.peek() == .less_than) {
        reg_method_type_params = try p.parseOptionalTypeParameters();
    }

    // Method shorthand: name() { }
    if (p.peek() == .l_paren) {
        // Set method flags BEFORE parsing params so super.prop works in defaults
        const saved_fn = p.in_function;
        const saved_method = p.in_method;
        p.in_function = true;
        p.in_method = true;
        const _saved_nta_x = p.new_target_allowed;
        p.new_target_allowed = true;
        defer p.new_target_allowed = _saved_nta_x;
        defer p.in_function = saved_fn;
        defer p.in_method = saved_method;
        const method_scope_ev = try p.emitScopeOpen(.function, .none);
        const params_range = try parseFormalParameters(p);
        p.in_return_type = true;
        const obj_method_return_type = try p.parseOptionalTypeAnnotation();
        p.in_return_type = false;
        const body = try parseBlockBodyWithStrictChecks(p, params_range, .none);
        try p.emitScopeClose(.none);
        const method_extra = try p.addExtra(ast.MethodData, .{
            .params_start = params_range.start,
            .params_end = params_range.end,
            .body = body,
            .return_type = obj_method_return_type,
            .type_params = reg_method_type_params.start,
            .type_params_end = reg_method_type_params.end,
        });
        const method_node = try p.addNode(.{
            .tag = .method_def,
            .main_token = key_tok,
            .data = .{ .lhs = key, .rhs = NodeIndex.fromInt(method_extra) },
        });
        p.patchScopeOpenNode(method_scope_ev, method_node);
        return method_node;
    }

    // key: value (allow `in` for destructuring defaults: `{ a: b = 'x' in {} }`)
    if (p.peek() == .colon) {
        _ = p.advance();
        const saved_allow_in2 = p.allow_in;
        p.allow_in = true;
        defer p.allow_in = saved_allow_in2;
        const value = try parseAssignmentExpression(p);
        return p.addNode(.{
            .tag = .property,
            .main_token = key_tok,
            .data = .{ .lhs = key, .rhs = value },
        });
    }

    // Shorthand: key token must be a valid binding name, not a reserved keyword.
    // { function } or { var } are invalid shorthand (reserved words can't be bindings).
    // { function: val } and class { function(){} } are fine (handled above).
    const key_tag = p.tokenTag(key_tok);
    if (key_tag.isKeyword()) {
        const is_contextual = isContextualKeyword(key_tag);
        // yield is reserved in generators AND in strict mode
        const yield_reserved = key_tag == .kw_yield and (p.in_generator or p.in_strict);
        const await_reserved = key_tag == .kw_await and (p.in_async or p.is_module or (p.in_static_block and !p.in_function));
        // let/static are reserved as binding names in strict mode
        const let_reserved = (key_tag == .kw_let or key_tag == .kw_static) and p.in_strict;
        if (!is_contextual or yield_reserved or await_reserved or let_reserved) {
            try p.emitError("Unexpected reserved word as shorthand property");
            return error.ParseError;
        }
    }
    // In strict mode, future reserved words (package, private, etc.) can't be bindings.
    // These are lexed as .identifier, so check the source text.
    if (p.in_strict and key_tag == .identifier) {
        const name = p.tokenText(key_tok);
        if (isStrictFutureReserved(name)) {
            try p.emitError("Unexpected strict mode reserved word as shorthand property");
            return error.ParseError;
        }
    }
    // An escaped keyword that resolves to an always-reserved word (e.g. br\u{65}ak = break)
    // is invalid as a shorthand property — the identifier value would be a reserved word.
    if (key_tag == .escaped_keyword) {
        const text = p.tokenText(key_tok);
        var resolved_buf: [256]u8 = undefined;
        if (@import("parser.zig").resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
            if (@import("parser.zig").isAlwaysReservedStr(resolved)) {
                try p.emitError("Escaped reserved word cannot be used as shorthand property");
                return error.ParseError;
            }
        }
    }

    // Shorthand property: { x }  or  { x = default }
    if (p.peek() == .equal) {
        // Shorthand with default — cover grammar for destructuring.
        // Default value allows `in` expressions even in for-of context.
        _ = p.advance();
        const saved_allow_in = p.allow_in;
        p.allow_in = true;
        defer p.allow_in = saved_allow_in;
        const default_val = try parseAssignmentExpression(p);
        return p.addNode(.{
            .tag = .assignment_pattern,
            .main_token = key_tok,
            .data = .{ .lhs = key, .rhs = default_val },
        });
    }

    // Shorthand requires an IdentifierReference key — literal/computed keys are invalid.
    switch (key_tag) {
        .number_literal, .string_literal, .bigint_literal, .l_bracket => {
            try p.emitError("Invalid shorthand property: missing value for non-identifier key");
            return error.ParseError;
        },
        else => {},
    }

    // Plain shorthand: { x } — emit a read reference so scope analysis can see
    // the identifier usage. When the cover-grammar expression is later converted
    // to a destructuring pattern, emitDeclaresFromPatternImpl cancels this ref
    // via cancelReferenceForNode before emitting the declare event.
    try p.emitReference(.read, key);
    return p.addNode(.{
        .tag = .shorthand_property,
        .main_token = key_tok,
        .data = .{ .lhs = key, .rhs = .none },
    });
}

fn parsePropertyName(p: *Parser) Error!NodeIndex {
    const tag = p.peek();
    return switch (tag) {
        .hash => {
            // Private name: #field (keywords valid: #await in `#await in obj`)
            const hash_tok = p.advance();
            { const phk = p.peek(); if (phk == .identifier or phk.isKeyword() or phk == .escaped_keyword) _ = p.advance(); }
            return p.addNode(.{
                .tag = .identifier,
                .main_token = hash_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },
        .identifier, .escaped_keyword => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .identifier,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },
        .string_literal => blk: {
            if (p.in_strict) try checkStrictOctalString(p);
            break :blk parseLiteral(p, .string_literal);
        },
        .number_literal => blk: {
            if (p.in_strict) try checkStrictOctalNumber(p);
            break :blk parseLiteral(p, .number_literal);
        },
        .bigint_literal => parseLiteral(p, .bigint_literal),
        .l_bracket => {
            _ = p.advance(); // consume `[`
            // Computed property keys always allow `in`
            const saved_allow_in = p.allow_in;
            p.allow_in = true;
            defer p.allow_in = saved_allow_in;
            const expr = try parseAssignmentExpression(p);
            _ = try p.expect(.r_bracket);
            return expr;
        },
        else => {
            // All keywords are valid as property names (e.g. { void: 1, enum: 2 })
            if (tag.isKeyword()) {
                const tok = p.advance();
                return p.addNode(.{
                    .tag = .identifier,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            }
            try p.emitError("Expected property name");
            return p.makeErrorNode();
        },
    };
}

/// Strict mode future reserved words (lexed as .identifier, not keyword tokens).
fn isStrictFutureReserved(name: []const u8) bool {
    return std.mem.eql(u8, name, "implements") or
        std.mem.eql(u8, name, "interface") or
        std.mem.eql(u8, name, "package") or
        std.mem.eql(u8, name, "private") or
        std.mem.eql(u8, name, "protected") or
        std.mem.eql(u8, name, "public");
}

/// Contextual keywords that can be used as identifiers/bindings in non-strict mode.
fn isContextualKeyword(tag: TokenTag) bool {
    return switch (tag) {
        .kw_get, .kw_set, .kw_async, .kw_static, .kw_let, .kw_of,
        .kw_from, .kw_as, .kw_target, .kw_meta, .kw_yield, .kw_await,
        // TypeScript-specific contextual keywords (valid as identifiers/property names)
        .kw_type, .kw_interface, .kw_declare, .kw_namespace, .kw_module,
        .kw_abstract, .kw_readonly, .kw_override, .kw_keyof, .kw_infer,
        .kw_is, .kw_asserts, .kw_satisfies, .kw_unique,
        => true,
        else => false,
    };
}

fn isPropertyNameStart(tag: TokenTag) bool {
    return switch (tag) {
        .identifier, .escaped_keyword, .string_literal, .number_literal, .bigint_literal, .l_bracket, .hash,
        => true,
        else => tag.isKeyword(),
    };
}

fn isMethodStart(tag: TokenTag) bool {
    return isPropertyNameStart(tag) or tag == .asterisk;
}

// =====================================================================
// Function expression
// =====================================================================

fn parseFunctionExpression(p: *Parser) Error!NodeIndex {
    const fn_tok = p.advance(); // consume `function`

    const is_generator = p.peek() == .asterisk;
    if (is_generator) _ = p.advance();

    // Optional name (includes contextual keywords like yield/await when allowed).
    // Per spec, FunctionExpression uses BindingIdentifier[~Yield, ~Await], so
    // yield/await are only reserved when this function itself is a generator/async,
    // NOT when the enclosing function is.
    const can_be_name = p.peek() == .identifier or p.peek() == .escaped_keyword or
        (p.peek() == .kw_yield and !is_generator and !p.in_strict) or
        (p.peek() == .kw_await and !p.is_module);
    const name_node: NodeIndex = if (can_be_name) blk: {
        try p.checkStrictBinding(p.tokIdx());
        const name_tok = p.advance();
        break :blk try p.addNode(.{
            .tag = .identifier,
            .main_token = name_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else .none;

    // Set generator flag BEFORE parsing params — yield is reserved in generator params
    const saved_fn = p.in_function;
    p.in_function = true;
    defer p.in_function = saved_fn;
    const saved_nta_fe = p.new_target_allowed;
    p.new_target_allowed = true;
    defer p.new_target_allowed = saved_nta_fe;
    const saved_gen = p.in_generator;
    p.in_generator = is_generator;
    p.syncYieldLex();
    defer { p.in_generator = saved_gen; p.syncYieldLex(); }
    // Non-async function expression body has its own [~Await] flag.
    const saved_async_fe = p.in_async;
    p.in_async = false;
    defer p.in_async = saved_async_fe;
    // Function body has its own `arguments` — the class-field-init restriction stops here.
    const saved_cf = p.in_class_field;
    p.in_class_field = false;
    defer p.in_class_field = saved_cf;
    // Function/arrow body clears the outer fn-param context (await/yield now valid).
    const saved_fp = p.in_fn_params;
    p.in_fn_params = false;
    defer p.in_fn_params = saved_fp;
    // Non-method function expressions have no super binding.
    const saved_ic = p.in_class;
    p.in_class = false;
    defer p.in_class = saved_ic;

    // Named function expression: name binds only inside the function's own
    // scope.  We emit the declare AFTER emitting scope_open so the consumer
    // places the binding in the inner scope, not the enclosing one.
    const fn_expr_ev = try p.emitScopeOpen(.function, .none);
    // Named function expression: always emit as `.fn_expr_name`. The name
    // binds only inside the function's own scope (it's a self-reference,
    // not a declaration in the enclosing scope). ESLint's scope-manager
    // puts this binding in a separate "function-expression-name" scope
    // above the body — JS-side scope construction extracts it. Without the
    // distinct binding kind, the FE-name and any same-named inner
    // declaration (e.g. `(function a() { function a(){} })()`) merge into
    // one Variable and rules like no-shadow can't detect the inner shadow.
    if (name_node != .none) {
        try p.emitDeclare(.fn_expr_name, name_node);
    }
    // Reset decl_name_text: don't propagate outer binding name into this fn's body.
    const saved_decl_name_fn = p.decl_name_text;
    p.decl_name_text = &.{};
    defer p.decl_name_text = saved_decl_name_fn;

    p.emit_fn_type_params = true;
    const fn_expr_type_params = try p.parseOptionalTypeParameters();
    p.emit_fn_type_params = false;
    const params_range = try parseFormalParameters(p);
    p.in_fn_params = false; // body: yield/await valid in generator/async fn
    p.in_return_type = true;
    const fn_expr_return_type = try p.parseOptionalTypeAnnotation();
    p.in_return_type = false;

    // TS ambient function expressions can be bodyless in certain contexts
    if (p.is_ts and p.peek() != .l_brace) {
        _ = p.eat(.semicolon);
        try p.emitScopeClose(.none);
        const ts_node = try p.addNode(.{
            .tag = .ts_type_annotation,
            .main_token = fn_tok,
            .data = .{ .lhs = name_node, .rhs = .none },
        });
        p.patchScopeOpenNode(fn_expr_ev, ts_node);
        return ts_node;
    }

    const body = try parseBlockBodyWithStrictChecks(p, params_range, name_node);
    try p.emitScopeClose(.none);

    const fn_tag: Node.Tag = if (is_generator) .generator_fn_expr else .fn_expr;

    const extra = try p.addExtra(ast.FnData, .{
        .name = name_node,
        .params = params_range.start,
        .params_end = params_range.end,
        .body = body,
        .return_type = fn_expr_return_type,
        .type_params = fn_expr_type_params.start,
        .type_params_end = fn_expr_type_params.end,
    });
    const fn_expr_node = try p.addNode(.{
        .tag = fn_tag,
        .main_token = fn_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
    });
    p.patchScopeOpenNode(fn_expr_ev, fn_expr_node);
    return fn_expr_node;
}

// =====================================================================
// Class expression
// =====================================================================

fn parseClassExpression(p: *Parser) Error!NodeIndex {
    const class_tok = p.advance(); // consume `class`

    // Optional name (contextual keywords allowed when not reserved).
    // In TypeScript, access-modifier keywords (private/protected/public/etc.) that are
    // lexed as identifiers must NOT be consumed as the class name when they are followed
    // by something other than `{`, `<`, `extends`, or `implements` — in that case they
    // are class-member modifiers, not the name.
    const peek_is_ts_modifier = p.is_ts and blk: {
        const txt = p.tokenText(p.tokIdx());
        break :blk std.mem.eql(u8, txt, "private") or std.mem.eql(u8, txt, "protected") or
            std.mem.eql(u8, txt, "public") or std.mem.eql(u8, txt, "abstract") or
            std.mem.eql(u8, txt, "readonly") or std.mem.eql(u8, txt, "override") or
            std.mem.eql(u8, txt, "declare");
    };
    const next_is_class_continuation = blk: {
        const nx = p.peekAt(1);
        break :blk nx == .l_brace or nx == .less_than or nx == .kw_extends or nx == .kw_implements;
    };
    // Class bodies are always strict mode — `yield` is never a valid class name.
    if (p.peek() == .kw_yield) {
        try p.emitDiagnostic(p.currentSpan(), "'yield' is not a valid class name in strict mode", .{});
        return error.ParseError;
    }
    const can_name = (p.peek() == .identifier or p.peek() == .escaped_keyword or
        (p.peek() == .kw_await and !p.in_async and !p.is_module and !(p.in_static_block and !p.in_function))) and
        (!peek_is_ts_modifier or next_is_class_continuation);
    const name_node: NodeIndex = if (can_name) blk: {
        const name_tok = p.advance();
        // Class bodies are always strict mode — reject strict-reserved identifiers.
        if (p.isStrictReservedWord(name_tok)) {
            try p.emitDiagnostic(p.currentSpan(),
                "'{s}' is not a valid class name in strict mode", .{p.tokenText(name_tok)});
            return error.ParseError;
        }
        // `await` reserved in module / async function (escape form too).
        if (p.is_module or p.in_async) {
            const t = p.tokenText(name_tok);
            if (std.mem.indexOfScalar(u8, t, '\\') != null) {
                var rb: [256]u8 = undefined;
                if (parser_mod.resolveUnicodeEscapesParser(t, &rb)) |r| {
                    if (std.mem.eql(u8, r, "await")) {
                        try p.emitDiagnostic(p.currentSpan(),
                            "'await' cannot be used as identifier here", .{});
                        return error.ParseError;
                    }
                }
            }
        }
        break :blk try p.addNode(.{
            .tag = .identifier,
            .main_token = name_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else .none;

    // TS type parameters: class<T> or class Foo<T, U>
    const class_expr_type_params: ast.SubRange = if (p.is_ts and p.peek() == .less_than) blk: {
        const ts_mod = @import("typescript.zig");
        break :blk try ts_mod.parseTypeParameterList(p);
    } else .{ .start = 0, .end = 0 };

    // Per ES spec, the class expression's name binding is created BEFORE
    // the extends clause is evaluated (the name is visible to extends in a
    // TDZ).  ESLint's scope-analyzer reflects this — `class C extends C {}`
    // resolves the inner `C` to the class's own name.  Open the class
    // scope and declare the name BEFORE parsing extends so the reference
    // resolves to the class-expr-name binding.
    const class_expr_scope_ev = try p.emitScopeOpen(.class, .none);
    if (name_node != .none) try p.emitDeclare(.class_expr_name, name_node);

    // Optional extends.
    var had_extends = false;
    const super_node: NodeIndex = if (p.eat(.kw_extends)) |_| blk: {
        had_extends = true;
        if (p.is_ts) {
            const ts_mod = @import("typescript.zig");
            // Use expression parsing for tokens that are expressions but not types
            if (p.peek() == .l_paren or p.peek() == .kw_class or
                p.peek() == .kw_function or p.peek() == .kw_new)
            {
                _ = try p.parseAssignmentExpression();
            } else {
                _ = try ts_mod.parseType(p);
            }
            // Handle mixin call after type: extends Base<T>()
            if (p.peek() == .l_paren) {
                _ = p.advance();
                while (p.peek() != .r_paren and !p.isAtEnd()) {
                    _ = try p.parseAssignmentExpression();
                    if (p.peek() == .comma) _ = p.advance() else break;
                }
                _ = try p.expect(.r_paren);
            }
            // Handle member access chain: extends Base<T>.Inner
            while (p.peek() == .dot) {
                _ = p.advance();
                if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
            }
            // Handle multiple extends (TS interfaces): extends A, B
            while (p.peek() == .comma) {
                _ = p.advance();
                _ = try ts_mod.parseType(p);
            }
            break :blk .none;
        }
        const expr = try parseExpressionPrec(p, .call);
        const et = p.node_tags_ptr[expr.toInt()];
        switch (et) {
            .logical_not, .bitwise_not, .unary_plus, .unary_minus,
            .typeof_expr, .void_expr, .delete_expr,
            .arrow_fn, .async_arrow_fn,
            => try p.emitError("extends requires a constructor, not an expression"),
            else => {},
        }
        break :blk expr;
    } else .none;
    // TS implements clause for class expressions: `class implements X { ... }`
    // / `class C extends Base implements X, Y { ... }`.  Class
    // declarations already record impls via a dedicated SubRange; for
    // class expressions we just consume the clause to satisfy the
    // parser (downstream lint rules source-scan the slice between
    // `class` and `{`).
    if (p.is_ts and p.peek() == .kw_implements) {
        _ = p.advance(); // eat `implements`
        const ts_mod = @import("typescript.zig");
        _ = try ts_mod.parseType(p);
        while (p.peek() == .comma) {
            _ = p.advance();
            _ = try ts_mod.parseType(p);
        }
    }
    const l_brace_tok = try p.expect(.l_brace);
    const prev_in_class = p.in_class;
    const prev_strict = p.in_strict;
    const prev_heritage = p.class_has_heritage;
    const prev_in_static_block_ce = p.in_static_block;
    p.class_has_heritage = had_extends;
    defer p.class_has_heritage = prev_heritage;
    p.in_class = true;
    p.in_strict = true;
    p.in_static_block = false; // nested class resets static-block context
    p.syncYieldLex();
    defer p.in_class = prev_in_class;
    defer p.in_static_block = prev_in_static_block_ce;
    defer { p.in_strict = prev_strict; p.syncYieldLex(); }

    // AllPrivateNamesValid: snapshot stacks for this class expression body.
    const private_decls_start_ce = p.private_decls.items.len;
    const private_refs_start_ce = p.private_refs.items.len;
    p.class_body_depth += 1;
    defer p.class_body_depth -= 1;

    const scratch_top = p.scratchLen();

    while (true) {
        const tc = p.peek();
        if (tc == .r_brace or tc == .eof or tc == .r_paren) break;
        if (tc == .semicolon) {
            _ = p.advance();
            continue;
        }
        const before = p.tok_i;
        // Route to the canonical parser.zig implementation. The expressions.zig
        // copy below (parseClassMember) is a stale duplicate that misses
        // type-annotation + initializer combos and many TS features; kept only
        // as dead code pending removal.
        const member = p.parseClassMember() catch |err| switch (err) {
            error.ParseError => {
                p.synchronize();
                if (p.tok_i == before) _ = p.advance();
                const err_node = p.makeErrorNode() catch return error.OutOfMemory;
                try p.scratchPush(err_node);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try p.scratchPush(member);
    }

    _ = try p.expect(.r_brace);
    try p.emitScopeClose(.none);

    const members = p.scratchSlice(scratch_top);

    // Collect this class's private decls and check for duplicates.
    {
        var seen = std.StringHashMap(u32).init(p.gpa);
        defer seen.deinit();
        for (members) |idx_int| {
            const m = NodeIndex.fromInt(idx_int);
            if (m == .none) continue;
            const m_tag = p.node_tags_ptr[m.toInt()];
            if (m_tag != .property_def and m_tag != .method_def and
                m_tag != .getter_def and m_tag != .setter_def) continue;
            const m_data = p.node_data_ptr[m.toInt()];
            const key = m_data.lhs;
            if (key == .none) continue;
            const key_tag = p.node_tags_ptr[key.toInt()];
            if (key_tag != .identifier) continue;
            const key_tok = p.node_main_token_ptr[key.toInt()];
            if (p.tokenTag(key_tok) != .hash) continue;
            if (key_tok + 1 >= p.tokens.len) continue;
            const name_text = p.tokenText(key_tok + 1);
            const extra_idx = m_data.rhs.toInt();
            const is_static_member = if (extra_idx + 4 < p.extra_data.items.len)
                (p.extra_data.items[extra_idx + 4] & ast.ModifierBit.@"static") != 0
            else
                false;
            const bit: u32 = switch (m_tag) {
                .getter_def => if (is_static_member) @as(u32, 4) else @as(u32, 1),
                .setter_def => if (is_static_member) @as(u32, 8) else @as(u32, 2),
                else => if (is_static_member) @as(u32, 32) else @as(u32, 16),
            };
            const gop = try seen.getOrPut(name_text);
            if (!gop.found_existing) {
                gop.value_ptr.* = bit;
                try p.private_decls.append(p.gpa, name_text);
            } else {
                const combined = gop.value_ptr.* | bit;
                const allowed = combined == (1 | 2) or combined == (4 | 8);
                if (!allowed and !p.is_ts) {
                    try p.emitError("Duplicate private name in class body");
                    return error.ParseError;
                }
                gop.value_ptr.* = combined;
            }
        }
    }

    // Duplicate constructor check for class expressions.
    if (!p.is_ts) {
        var ctor_count: u8 = 0;
        for (members) |idx_int| {
            const m = NodeIndex.fromInt(idx_int);
            if (m == .none) continue;
            if (p.node_tags_ptr[m.toInt()] != .method_def) continue;
            const m_data = p.node_data_ptr[m.toInt()];
            const key = m_data.lhs;
            if (key == .none) continue;
            const key_tag = p.node_tags_ptr[key.toInt()];
            const key_tok = p.node_main_token_ptr[key.toInt()];
            const is_ctor_name = (key_tag == .identifier and
                std.mem.eql(u8, p.tokenText(key_tok), "constructor")) or
                (key_tag == .string_literal and
                std.mem.eql(u8, p.getStringContent(p.tokenStart(key_tok)), "constructor"));
            if (!is_ctor_name) continue;
            const extra_idx = m_data.rhs.toInt();
            if (extra_idx + 4 < p.extra_data.items.len) {
                const modifiers = p.extra_data.items[extra_idx + 4];
                if ((modifiers & ast.ModifierBit.@"static") != 0) continue;
            }
            ctor_count += 1;
            if (ctor_count > 1) {
                try p.emitError("A class may only have one constructor");
                return error.ParseError;
            }
        }
    }

    // Validate refs accumulated in this class expression body.
    {
        const refs_slice = p.private_refs.items[private_refs_start_ce..];
        const decls_in_scope = p.private_decls.items;
        var ref_buf: [128]u8 = undefined;
        var decl_buf: [128]u8 = undefined;
        var write: usize = private_refs_start_ce;
        const outermost = (p.class_body_depth == 1);
        for (refs_slice) |hash_tok| {
            if (hash_tok + 1 >= p.tokens.len) continue;
            const name = p.tokenText(hash_tok + 1);
            const ref_len = Parser.decodeIdentForCompare(name, &ref_buf);
            const ref_norm = ref_buf[0..ref_len];
            var found = false;
            for (decls_in_scope) |d| {
                const dl = Parser.decodeIdentForCompare(d, &decl_buf);
                if (std.mem.eql(u8, decl_buf[0..dl], ref_norm)) { found = true; break; }
            }
            if (!found) {
                if (outermost and !p.is_ts) {
                    try p.emitError("Reference to undeclared private name");
                    return error.ParseError;
                }
                p.private_refs.items[write] = hash_tok;
                write += 1;
            }
        }
        p.private_refs.shrinkRetainingCapacity(write);
        p.private_decls.shrinkRetainingCapacity(private_decls_start_ce);
    }
    const range = try p.addSlice(members);
    p.scratchPop(scratch_top);

    const class_body_node = try p.addNode(.{
        .tag = .class_body,
        .main_token = l_brace_tok,
        .data = .{
            .lhs = ast.NodeIndex.fromInt(range.start),
            .rhs = ast.NodeIndex.fromInt(range.end),
        },
    });
    const extra = try p.addExtra(ast.ClassData, .{
        .name = name_node,
        .super_class = super_node,
        .body = class_body_node,
        .type_params = class_expr_type_params.start,
        .type_params_end = class_expr_type_params.end,
    });
    const class_expr_node = try p.addNode(.{
        .tag = .class_expr,
        .main_token = class_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
    });
    p.patchScopeOpenNode(class_expr_scope_ev, class_expr_node);
    return class_expr_node;
}


// =====================================================================
// New expression
// =====================================================================

/// Walk an expression subtree looking for optional chain nodes.
/// Used by `new`-expression validation. Stops at non-member/call boundaries.
fn containsOptionalChain(p: *Parser, node: NodeIndex) bool {
    if (node == .none) return false;
    var cur = node;
    while (true) {
        const t = p.node_tags_ptr[cur.toInt()];
        switch (t) {
            .optional_member_expr, .optional_computed_member_expr, .optional_call_expr => return true,
            .member_expr, .computed_member_expr, .call_expr => {
                cur = p.node_data_ptr[cur.toInt()].lhs;
                if (cur == .none) return false;
            },
            .grouping_expr => {
                // `new (foo?.bar)()` — Babel rejects this too.
                cur = p.node_data_ptr[cur.toInt()].lhs;
                if (cur == .none) return false;
            },
            else => return false,
        }
    }
}

fn parseNewExpression(p: *Parser) Error!NodeIndex {
    const new_tok = p.advance(); // consume `new`

    // new.target — create the `new` meta identifier BEFORE consuming
    // subsequent tokens so its end_tok records the `new` keyword only,
    // not the trailing `.target`. Otherwise sourceCode.getTokenBefore /
    // getFirstTokenBetween produce wrong tokens and crash rules like
    // indent that compute offsets relative to MetaProperty.meta.
    if (p.peek() == .dot) {
        const meta_node = try p.addNode(.{
            .tag = .property_ident,
            .main_token = new_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        _ = p.advance(); // consume `.`
        if (p.peek() == .kw_target or (p.peek() == .identifier and std.mem.eql(u8, p.tokenText(p.tokIdx()), "target"))) {
            const target_tok = p.advance(); // consume `target`
            if (!p.new_target_allowed and !p.in_class and !p.is_ts) {
                try p.emitError("'new.target' is only valid inside functions or class members");
            }
            const prop_node = try p.addNode(.{
                .tag = .property_ident,
                .main_token = target_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            return p.addNode(.{
                .tag = .new_target,
                .main_token = new_tok,
                .data = .{ .lhs = meta_node, .rhs = prop_node },
            });
        }
        try p.emitError("Expected 'target' after 'new.'");
        return p.makeErrorNode();
    }

    // TS: `new <T>Foo()` is invalid — angle bracket type assertion cannot be a new target.
    if (p.is_ts and p.peek() == .less_than) {
        try p.emitError("Expression expected");
        return error.ParseError;
    }

    // Recursive: `new new Foo()` is valid.
    var callee: NodeIndex = undefined;
    if (p.peek() == .kw_new) {
        callee = try parseNewExpression(p);
    } else {
        callee = try parsePrimaryExpression(p);
    }

    // `new import(...)` is invalid — import() is a CallExpression, not a valid new target
    if (callee != .none) {
        const callee_tag = p.node_tags_ptr[callee.toInt()];
        if (callee_tag == .import_expr) {
            try p.emitError("Cannot use 'new' with 'import()'");
        }
    }
    const is_bare_super = callee != .none and p.node_tags_ptr[callee.toInt()] == .super_expr;

    // Consume member accesses that bind tighter than new (`.prop`, `[expr]`).
    while (true) {
        switch (p.peek()) {
            .dot => {
                _ = p.advance();
                // Private name: .#ident — save '#' token as main_token for PrivateIdentifier detection.
                var hash_tok: ?TokenIndex = null;
                if (p.peek() == .hash) {
                    hash_tok = p.advance(); // save '#', don't discard
                    // keywords are valid private names: obj.#await, obj.#static, etc.
                    { const ppr = p.peek(); if (ppr == .identifier or ppr.isKeyword() or ppr == .escaped_keyword) _ = p.advance(); }
                    try p.private_refs.append(p.gpa, hash_tok.?);
                }
                // Accept identifier, keyword, or escaped keyword after `.`
                const ppt = p.peek();
                const prop_tok = if (hash_tok) |ht| ht else if (ppt == .identifier or ppt.isKeyword() or ppt == .escaped_keyword)
                    p.advance()
                else
                    try p.expect(.identifier); // will emit error
                const prop_node = try p.addNode(.{
                    .tag = .property_ident,
                    .main_token = prop_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
                callee = try p.addNode(.{
                    .tag = .member_expr,
                    .main_token = prop_tok,
                    .data = .{ .lhs = callee, .rhs = prop_node },
                });
            },
            .l_bracket => {
                const bracket = p.advance();
                const saved_allow_in_new = p.allow_in;
                p.allow_in = true;
                const index_expr = try parseExpression(p);
                p.allow_in = saved_allow_in_new;
                _ = try p.expect(.r_bracket);
                callee = try p.addNode(.{
                    .tag = .computed_member_expr,
                    .main_token = bracket,
                    .data = .{ .lhs = callee, .rhs = index_expr },
                });
            },
            .template_head, .template_no_sub => {
                // Use the template's starting token as main_token (not new_tok)
                // so node_min_toks/node_max_toks span the tagged-template
                // range correctly.  Otherwise `new tag`X`` would report a
                // TaggedTemplateExpression starting at `new` (col 1) instead
                // of at `tag` (col 5) — diverging from ESLint and breaking
                // rules like template-tag-spacing that use node.loc.start.
                const tmpl_start_tok: u32 = p.tokIdx();
                const tmpl = try parseTemplateLiteralTagged(p);
                callee = try p.addNode(.{
                    .tag = .tagged_template,
                    .main_token = tmpl_start_tok,
                    .data = .{ .lhs = callee, .rhs = tmpl },
                });
            },
            else => break,
        }
    }

    // `new super()` is invalid but `new super.prop()` is valid
    // TypeScript emits TS2351/TS17011 (semantic) — skip parse-time error in TS mode.
    if (is_bare_super and p.node_tags_ptr[callee.toInt()] == .super_expr and !p.is_ts) {
        try p.emitError("'super' is not valid as a new expression target");
    }

    // Optional chains in new target are SyntaxError: `new foo?.bar()` etc.
    // TypeScript emits TS1209 (non-fatal) for this case.
    if (callee != .none and containsOptionalChain(p, callee)) {
        try p.emitError("Optional chain not allowed as new expression target");
        if (!p.is_ts) return error.ParseError;
    }

    // Optional argument list.
    if (p.peek() == .l_paren) {
        const args_range = try parseArgumentList(p);
        const range_extra = try p.addExtra(SubRange, .{
            .start = args_range.start,
            .end = args_range.end,
        });
        return p.addNode(.{
            .tag = .new_expr,
            .main_token = new_tok,
            .data = .{ .lhs = callee, .rhs = NodeIndex.fromInt(range_extra) },
        });
    }

    // `new Foo` (without parens). Optional chain immediately after new
    // (`new X?.y` or `new X?.()`) is a SyntaxError per spec.
    // TypeScript also rejects this with TS1209 (non-fatal).
    if (p.peek() == .question_dot) {
        try p.emitError("Optional chain is not allowed immediately after 'new' expression");
        if (!p.is_ts) return error.ParseError;
    }
    return p.addNode(.{
        .tag = .new_expr,
        .main_token = new_tok,
        .data = .{ .lhs = callee, .rhs = .none },
    });
}

// =====================================================================
// Template literal
// =====================================================================

/// Check if a template element contains invalid escape sequences.
/// Template literals (untagged) reject octal escapes (\0n, \1-\7, \8, \9)
/// and malformed \x, \u sequences.
fn hasInvalidTemplateEscape(source: []const u8, start: u32, end: u32) bool {
    const s = @min(start, @as(u32, @intCast(source.len)));
    const e = @min(end, @as(u32, @intCast(source.len)));
    const text = source[s..e];
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') continue;
        i += 1;
        if (i >= text.len) break;
        const esc = text[i];
        switch (esc) {
            '0' => {
                // \0 alone is OK (null char), but \0n (where n is octal digit) is not
                if (i + 1 < text.len and text[i + 1] >= '0' and text[i + 1] <= '9') return true;
            },
            '1', '2', '3', '4', '5', '6', '7' => return true, // octal
            '8', '9' => return true, // legacy non-octal
            'x' => {
                // \xHH — need exactly 2 hex digits
                if (i + 2 >= text.len) return true;
                if (!isHex(text[i + 1]) or !isHex(text[i + 2])) return true;
                i += 2;
            },
            'u' => {
                i += 1;
                if (i >= text.len) return true;
                if (text[i] == '{') {
                    // \u{XXXX} — need hex digits and closing }
                    i += 1;
                    var digits: u32 = 0;
                    var code_point: u32 = 0;
                    while (i < text.len and text[i] != '}') : (i += 1) {
                        if (!isHex(text[i])) return true;
                        digits += 1;
                        const digit_val: u32 = if (text[i] >= '0' and text[i] <= '9')
                            text[i] - '0'
                        else if (text[i] >= 'a' and text[i] <= 'f')
                            text[i] - 'a' + 10
                        else
                            text[i] - 'A' + 10;
                        code_point = code_point *| 16 +| digit_val;
                    }
                    if (i >= text.len or digits == 0) return true;
                    // Check code point <= 0x10FFFF
                    if (code_point > 0x10FFFF) return true;
                } else {
                    // \uXXXX — need exactly 4 hex digits
                    if (i + 3 >= text.len) return true;
                    if (!isHex(text[i]) or !isHex(text[i + 1]) or !isHex(text[i + 2]) or !isHex(text[i + 3])) return true;
                    i += 3;
                }
            },
            else => {},
        }
    }
    return false;
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub fn parseTemplateLiteral(p: *Parser) Error!NodeIndex {
    return parseTemplateLiteralInner(p, true);
}

fn parseTemplateLiteralTagged(p: *Parser) Error!NodeIndex {
    return parseTemplateLiteralInner(p, false);
}

fn parseTemplateLiteralInner(p: *Parser, validate_escapes: bool) Error!NodeIndex {
    const head_tok: u32 = p.tokIdx();

    // No-substitution template: `text`
    if (p.peek() == .template_no_sub) {
        const tok = p.advance();
        // Detect unterminated template (must end with backtick).
        const ts = p.tok_starts_ptr[tok];
        const tl = p.tok_lens_ptr[tok];
        if (tl < 2 or ts + tl > p.source.len or p.source[ts + tl - 1] != '`') {
            try p.emitError("Unterminated template literal");
            return error.ParseError;
        }
        // Validate escape sequences in untagged template
        if (validate_escapes) {
            const tok_start = p.tokenStart(tok);
            const next_start = if (tok + 1 < p.tokens.len) p.tokenStart(tok + 1) else @as(u32, @intCast(p.source.len));
            if (hasInvalidTemplateEscape(p.source, tok_start, next_start)) {
                try p.emitError("Invalid escape sequence in template literal");
                return p.makeErrorNode();
            }
        }
        const elem = try p.addNode(.{
            .tag = .template_element,
            .main_token = tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        const range = try p.addSlice(&[_]u32{elem.toInt()});
        return p.addNode(.{
            .tag = .template_literal,
            .main_token = head_tok,
            .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
        });
    }

    // Template with substitutions: `head${expr}middle${expr}tail`
    const scratch_top = p.scratchLen();

    // Head text part.
    {
        const tok = p.advance(); // consume template_head
        // Validate escape sequences in untagged template head
        if (validate_escapes) {
            const tok_start = p.tokenStart(tok);
            const next_start = if (tok + 1 < p.tokens.len) p.tokenStart(tok + 1) else @as(u32, @intCast(p.source.len));
            if (hasInvalidTemplateEscape(p.source, tok_start, next_start)) {
                try p.emitError("Invalid escape sequence in template literal");
                return p.makeErrorNode();
            }
        }
        const head_elem = try p.addNode(.{
            .tag = .template_element,
            .main_token = tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        try p.scratchPush(head_elem);
    }

    // Parse expression + middle/tail parts.
    while (true) {
        // Expression inside ${ ... }
        const expr = try parseExpression(p);
        try p.scratchPush(expr);

        const part_tag = p.peek();
        if (part_tag == .template_tail) {
            // Tail — last text part.
            const tok = p.advance();
            // Detect unterminated template (must end with backtick).
            const ts = p.tok_starts_ptr[tok];
            const tl = p.tok_lens_ptr[tok];
            if (tl < 1 or ts + tl > p.source.len or p.source[ts + tl - 1] != '`') {
                try p.emitError("Unterminated template literal");
                return error.ParseError;
            }
            if (validate_escapes) {
                const tok_start = p.tokenStart(tok);
                const next_start = if (tok + 1 < p.tokens.len) p.tokenStart(tok + 1) else @as(u32, @intCast(p.source.len));
                if (hasInvalidTemplateEscape(p.source, tok_start, next_start)) {
                    try p.emitError("Invalid escape sequence in template literal");
                    return p.makeErrorNode();
                }
            }
            const tail_elem = try p.addNode(.{
                .tag = .template_element,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            try p.scratchPush(tail_elem);
            break;
        } else if (part_tag == .template_middle) {
            // Middle — more expressions follow.
            const tok = p.advance();
            if (validate_escapes) {
                const tok_start = p.tokenStart(tok);
                const next_start = if (tok + 1 < p.tokens.len) p.tokenStart(tok + 1) else @as(u32, @intCast(p.source.len));
                if (hasInvalidTemplateEscape(p.source, tok_start, next_start)) {
                    try p.emitError("Invalid escape sequence in template literal");
                    return p.makeErrorNode();
                }
            }
            const mid_elem = try p.addNode(.{
                .tag = .template_element,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            try p.scratchPush(mid_elem);
        } else {
            // Error recovery: unexpected token inside template.
            try p.emitError("Expected template continuation");
            break;
        }
    }

    const parts = p.scratchSlice(scratch_top);
    const range = try p.addSlice(parts);
    p.scratchPop(scratch_top);

    return p.addNode(.{
        .tag = .template_literal,
        .main_token = head_tok,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// Import expression:  import(source)  /  import.meta
// =====================================================================

fn parseImportExpression(p: *Parser) Error!NodeIndex {
    const import_tok = p.advance(); // consume `import`

    // import.meta / import.source(...) / import.defer(...)
    if (p.peek() == .dot) {
        // Create the `import` meta identifier BEFORE consuming `.meta`
        // so its end_tok records only the `import` keyword.
        const meta_id_node = try p.addNode(.{
            .tag = .property_ident,
            .main_token = import_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        _ = p.advance(); // consume `.`
        if (p.peek() == .kw_meta or
            (p.peek() == .identifier and std.mem.eql(u8, p.tokenText(p.tokIdx()), "meta")))
        {
            const meta_tok = p.advance(); // consume `meta`
            if (!p.is_module and !p.is_ts) {
                try p.emitError("'import.meta' is only valid in modules");
            }
            const prop_node = try p.addNode(.{
                .tag = .property_ident,
                .main_token = meta_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            return p.addNode(.{
                .tag = .import_meta,
                .main_token = import_tok,
                .data = .{ .lhs = meta_id_node, .rhs = prop_node },
            });
        }
        // import.source(...) and import.defer(...) are valid dynamic import variants
        if (p.peek() == .identifier) {
            const prop_text = p.tokenText(p.tokIdx());
            if (std.mem.eql(u8, prop_text, "source") or std.mem.eql(u8, prop_text, "defer")) {
                _ = p.advance(); // consume property name
                // These require a call expression: import.source(specifier)
                _ = try p.expect(.l_paren);
                const arg = try p.parseAssignmentExpression();
                _ = try p.expect(.r_paren);
                return p.addNode(.{
                    .tag = .import_expr,
                    .main_token = import_tok,
                    .data = .{ .lhs = arg, .rhs = .none },
                });
            }
        }
        try p.emitError("The only valid meta property for import is 'import.meta'");
        return p.makeErrorNode();
    }

    // import(source) or import(source, options) — always allow `in` in args
    _ = try p.expect(.l_paren);
    const saved_allow_in = p.allow_in;
    p.allow_in = true;
    defer p.allow_in = saved_allow_in;
    const source = try parseAssignmentExpression(p);
    // Optional second argument (import attributes)
    var options: NodeIndex = .none;
    if (p.eat(.comma) != null) {
        if (p.peek() == .r_paren) {
            // TS1009: trailing comma in import() is not allowed in TypeScript.
            if (p.is_ts) try p.emitError("Trailing comma not allowed");
        } else {
            options = try parseAssignmentExpression(p);
            if (p.eat(.comma) != null) {
                // TS1009: trailing comma after second argument.
                if (p.is_ts) try p.emitError("Trailing comma not allowed");
            }
        }
    }
    _ = try p.expect(.r_paren);

    return p.addNode(.{
        .tag = .import_expr,
        .main_token = import_tok,
        .data = .{ .lhs = source, .rhs = options },
    });
}

// =====================================================================
// Infix precedence table
// =====================================================================

// Unified Pratt precedence table: single array load covers infix ops,
// call-level tokens, and postfix ++/--.  .none (0) means "break the loop".
// kw_in is stored as .relational; the allow_in special case is handled at call time.
// Call-level tokens (.call = 18): l_paren, dot, l_bracket, question_dot,
//   template_head, template_no_sub.
// Postfix tokens (.postfix = 17): plus_plus, minus_minus.
const prec_table: [256]Precedence = blk: {
    var tbl: [256]Precedence = @splat(.none);
    tbl[@intFromEnum(TokenTag.comma)] = .comma;
    for ([_]TokenTag{
        .equal,           .plus_equal,                   .minus_equal,
        .asterisk_equal,  .slash_equal,                  .percent_equal,
        .asterisk_asterisk_equal, .ampersand_equal,       .pipe_equal,
        .caret_equal,     .less_less_equal,               .greater_greater_equal,
        .greater_greater_greater_equal, .ampersand_ampersand_equal,
        .pipe_pipe_equal, .question_question_equal,
    }) |t| tbl[@intFromEnum(t)] = .assignment;
    tbl[@intFromEnum(TokenTag.question)] = .conditional;
    tbl[@intFromEnum(TokenTag.question_question)] = .nullish_coalesce;
    tbl[@intFromEnum(TokenTag.pipe_pipe)] = .logical_or;
    tbl[@intFromEnum(TokenTag.ampersand_ampersand)] = .logical_and;
    tbl[@intFromEnum(TokenTag.pipe)] = .bitwise_or;
    tbl[@intFromEnum(TokenTag.caret)] = .bitwise_xor;
    tbl[@intFromEnum(TokenTag.ampersand)] = .bitwise_and;
    tbl[@intFromEnum(TokenTag.equal_equal)] = .equality;
    tbl[@intFromEnum(TokenTag.bang_equal)] = .equality;
    tbl[@intFromEnum(TokenTag.equal_equal_equal)] = .equality;
    tbl[@intFromEnum(TokenTag.bang_equal_equal)] = .equality;
    for ([_]TokenTag{ .less_than, .greater_than, .less_equal, .greater_equal, .kw_instanceof, .kw_in }) |t|
        tbl[@intFromEnum(t)] = .relational;
    tbl[@intFromEnum(TokenTag.less_less)] = .shift;
    tbl[@intFromEnum(TokenTag.greater_greater)] = .shift;
    tbl[@intFromEnum(TokenTag.greater_greater_greater)] = .shift;
    tbl[@intFromEnum(TokenTag.plus)] = .additive;
    tbl[@intFromEnum(TokenTag.minus)] = .additive;
    tbl[@intFromEnum(TokenTag.asterisk)] = .multiplicative;
    tbl[@intFromEnum(TokenTag.slash)] = .multiplicative;
    tbl[@intFromEnum(TokenTag.percent)] = .multiplicative;
    tbl[@intFromEnum(TokenTag.asterisk_asterisk)] = .exponentiation;
    // Postfix update operators (require !isOnNewLine check at call time).
    tbl[@intFromEnum(TokenTag.plus_plus)] = .postfix;
    tbl[@intFromEnum(TokenTag.minus_minus)] = .postfix;
    // Call-level tokens (member access, calls, optional chain, tagged template).
    tbl[@intFromEnum(TokenTag.l_paren)] = .call;
    tbl[@intFromEnum(TokenTag.dot)] = .call;
    tbl[@intFromEnum(TokenTag.l_bracket)] = .call;
    tbl[@intFromEnum(TokenTag.question_dot)] = .call;
    tbl[@intFromEnum(TokenTag.template_head)] = .call;
    tbl[@intFromEnum(TokenTag.template_no_sub)] = .call;
    break :blk tbl;
};

/// Tokens that are parsed at call-level precedence (left-to-right).
fn isCallPrec(tag: TokenTag) bool {
    return prec_table[@intFromEnum(tag)] == .call;
}

// =====================================================================
// Infix expression dispatch
// =====================================================================

// tag is passed from the Pratt loop where it was already peeked.
fn parseInfixExpression(p: *Parser, left: NodeIndex, prec: Precedence, tag: TokenTag) Error!NodeIndex {
    // ── Conditional (ternary) ────────────────────────────────
    if (tag == .question) {
        return parseConditionalTail(p, left);
    }

    // ── Comma → sequence expression ─────────────────────────
    if (tag == .comma) {
        return parseSequenceExpression(p, left);
    }

    // ── Assignment ───────────────────────────────────────────
    if (tag.isAssignment()) {
        return parseAssignment(p, left);
    }

    // ── Binary / logical ─────────────────────────────────────
    return parseBinaryExpression(p, left, prec, tag);
}

// ── Call-level infix (member access, calls, etc.) ────────────────

// tag is passed from the Pratt loop where it was already peeked.
inline fn parseCallLevelInfix(p: *Parser, left: NodeIndex, tag: TokenTag) Error!NodeIndex {
    // Order by frequency in real JS/TS: member access (.dot) is the most common
    // call-level infix, followed by function calls (.l_paren). Explicit if/else
    // lets the branch predictor specialise on the most common path without waiting
    // for the full jump table dispatch that the compiler would emit for the switch.
    if (tag == .dot) return try parseMemberAccess(p, left);
    if (tag == .l_paren) return try parseCallExpression(p, left);
    return switch (tag) {
        .l_bracket => {
            // TS: after postfix ++/--, a `[` on a new line applies ASI (new class member).
            // For other expressions (e.g. literal `0`), no ASI — `0[e2]` is valid subscript.
            if (p.in_class_field and p.isOnNewLine()) {
                const left_tag = p.node_tags_ptr[left.toInt()];
                if (left_tag == .postfix_inc or left_tag == .postfix_dec) return left;
            }
            return try parseComputedMember(p, left);
        },
        .question_dot => try parseOptionalChain(p, left),
        .template_head, .template_no_sub => try parseTaggedTemplate(p, left),
        else => left,
    };
}

// ── Binary expression ────────────────────────────────────────────

// op_tag is the already-known current token tag, passed from parseInfixExpression.
fn parseBinaryExpression(p: *Parser, left: NodeIndex, prec: Precedence, op_tag: TokenTag) Error!NodeIndex {
    const op_tok = p.advance();

    // Nullish coalescing cannot be mixed with || or && without parentheses
    // In TS mode, this is a type error, not syntax error
    if (!p.is_ts) {
        if (op_tag == .question_question and left != .none) {
            const left_tag = p.node_tags_ptr[left.toInt()];
            if (left_tag == .logical_or or left_tag == .logical_and) {
                try p.emitError("Cannot mix '??' with '||' or '&&' without parentheses");
                return error.ParseError;
            }
        }
        if ((op_tag == .pipe_pipe or op_tag == .ampersand_ampersand) and left != .none) {
            const left_tag = p.node_tags_ptr[left.toInt()];
            if (left_tag == .nullish_coalesce) {
                try p.emitError("Cannot mix '??' with '||' or '&&' without parentheses");
                return error.ParseError;
            }
        }
    }

    // Exponentiation: unary operators cannot be the base of **
    // (e.g., `delete x ** 2` is invalid — must use `(delete x) ** 2`)
    // TypeScript's parser accepts these with type-level errors only (TS2362), so only
    // hard-fail in JavaScript mode.
    if (!p.is_ts and op_tag == .asterisk_asterisk and left != .none) {
        const left_tag = p.node_tags_ptr[left.toInt()];
        switch (left_tag) {
            .delete_expr, .typeof_expr, .void_expr,
            .logical_not, .bitwise_not, .unary_plus, .unary_minus,
            .await_expr,
            => {
                try p.emitError("Unary expression cannot be the left operand of exponentiation");
                return error.ParseError;
            },
            else => {},
        }
    }

    // Arrow functions are not valid in binary RHS — they're only AssignmentExpressions
    const saved_arrow = p.allow_arrow;
    p.allow_arrow = false;
    defer p.allow_arrow = saved_arrow;

    // Short-circuiting operators need CFG events so CodePathBuilder can model
    // the left/right execution as a choice context.
    const logical_kind: ?Parser.LogicalKind = switch (op_tag) {
        .ampersand_ampersand => .logical_and,
        .pipe_pipe => .logical_or,
        .question_question => .nullish_coalesce,
        else => null,
    };
    var logical_ev: u32 = 0;
    if (logical_kind) |lk| {
        logical_ev = try p.emitLogicalOpen(lk, .none);
        try p.emitLogicalRight(lk, left);
    }

    const rhs = try parseExpressionPrec(p, prec.next());

    // CoalesceExpression: `a ?? b` requires b to be a BitwiseORExpression — `||`/`&&` not allowed.
    if (!p.is_ts and op_tag == .question_question and rhs != .none) {
        const rhs_tag = p.node_tags_ptr[rhs.toInt()];
        if (rhs_tag == .logical_or or rhs_tag == .logical_and) {
            try p.emitError("Cannot mix '??' with '||' or '&&' without parentheses");
            return error.ParseError;
        }
    }

    // YieldExpression is at AssignmentExpression level; cannot be RHS of binary operators
    // above the assignment level. Comma and assignment are not at this prec class.
    if (!p.is_ts and rhs != .none) {
        const rhs_tag = p.node_tags_ptr[rhs.toInt()];
        if (rhs_tag == .yield_expr or rhs_tag == .yield_delegate) {
            try p.emitError("Yield expression not allowed as binary operand (wrap in parens)");
            return error.ParseError;
        }
    }

    const node_tag: Node.Tag = tokenToBinaryTag(op_tag);
    const node = try p.addNode(.{
        .tag = node_tag,
        .main_token = op_tok,
        .data = .{ .lhs = left, .rhs = rhs },
    });
    if (logical_kind) |lk| {
        try p.emitLogicalClose(lk, node);
        p.patchEventNode(logical_ev, node);
    }
    return node;
}

fn tokenToBinaryTag(tag: TokenTag) Node.Tag {
    return switch (tag) {
        .plus => .add,
        .minus => .subtract,
        .asterisk => .multiply,
        .slash => .divide,
        .percent => .modulo,
        .asterisk_asterisk => .exponentiate,
        .ampersand => .bitwise_and,
        .pipe => .bitwise_or,
        .caret => .bitwise_xor,
        .less_less => .shift_left,
        .greater_greater => .shift_right,
        .greater_greater_greater => .unsigned_shift_right,
        .equal_equal => .equal,
        .bang_equal => .not_equal,
        .equal_equal_equal => .strict_equal,
        .bang_equal_equal => .strict_not_equal,
        .less_than => .less_than,
        .greater_than => .greater_than,
        .less_equal => .less_equal,
        .greater_equal => .greater_equal,
        .kw_instanceof => .instanceof_expr,
        .kw_in => .in_expr,
        .ampersand_ampersand => .logical_and,
        .pipe_pipe => .logical_or,
        .question_question => .nullish_coalesce,
        else => .error_node,
    };
}

// ── Assignment expression ────────────────────────────────────────

fn parseAssignment(p: *Parser, left: NodeIndex) Error!NodeIndex {
    const left_tag = p.node_tags_ptr[left.toInt()];
    const op_tag = p.tokenTag(p.tokIdx());

    // Array/object destructuring only valid with plain `=`
    if (op_tag != .equal) {
        switch (left_tag) {
            .array_literal, .array_pattern, .object_literal, .object_pattern => {
                try p.emitError("Invalid left-hand side in compound assignment");
                return error.ParseError;
            },
            else => {},
        }
    }

    // Validate assignment target — reject literals, binary exprs, calls, optional chains, etc.
    // Parenthesized simple targets: (x) = 1, ((x)) = 1, (a.b) = 1 are valid
    // But parenthesized destructuring patterns: ([a]) = 1, ({a}) = 1 are NOT valid
    const effective_left_tag = if (left_tag == .grouping_expr) unwrapGroupingTag(p, left) else left_tag;
    if (left_tag == .grouping_expr and op_tag == .equal) {
        if (effective_left_tag == .array_literal or effective_left_tag == .array_pattern or
            effective_left_tag == .object_literal or effective_left_tag == .object_pattern)
        {
            try p.emitError("Invalid destructuring assignment target: parenthesized pattern");
            return error.ParseError;
        }
    }
    switch (effective_left_tag) {
        .identifier, .member_expr, .computed_member_expr,
        .array_literal, .array_pattern, .object_literal, .object_pattern,
        .assignment_pattern, .spread_element, .rest_element,
        => {},
        .call_expr => {
            // AnnexB: f() = 1 / f() += 1 etc permitted in non-strict Script.
            // Logical assignment ops (&&=, ||=, ??=) added in ES2021 do NOT
            // get this relaxation per spec.
            const is_logical_assign = (op_tag == .ampersand_ampersand_equal or
                op_tag == .pipe_pipe_equal or op_tag == .question_question_equal);
            const allow = p.annex_b and !p.in_strict and !is_logical_assign;
            if (!allow and !p.is_ts) {
                try p.emitError("Invalid left-hand side in assignment: function call");
                return error.ParseError;
            }
        },
        .optional_member_expr, .optional_computed_member_expr, .optional_call_expr => {
            // Optional chain has AssignmentTargetType=invalid per spec —
            // parens don't change this. Closes parenthesized-optionalexpression.
            if (!p.is_ts) {
                try p.emitError("Invalid left-hand side in assignment: optional chain");
                return error.ParseError;
            }
        },
        .in_expr, .instanceof_expr,
        // `await x = y` and `yield x = y` are never valid LHS — not an lvalue.
        .await_expr, .yield_expr, .yield_delegate,
        => {
            try p.emitError("';' expected");
            return error.ParseError;
        },
        else => {
            if (!p.is_ts) {
                try p.emitError("Invalid left-hand side in assignment");
                return error.ParseError;
            }
        },
    }

    // Strict mode / TypeScript: cannot assign to eval or arguments (also through parens).
    if (effective_left_tag == .identifier and (p.in_strict or p.is_ts)) {
        const inner = if (left_tag == .grouping_expr) unwrapGrouping(p, left).node else left;
        const left_tok = p.node_main_token_ptr[inner.toInt()];
        try p.checkStrictAssignTarget(left_tok);
    }

    const op_tok = p.advance();

    // Upgrade the LHS reference event kind from the speculative `.read` that
    // parseIdentifierRef emitted to the actual write kind. Plain `=` → .write;
    // compound ops (`+=`, `*=`, etc.) → .read_write.
    // `(x) = 1` wraps the identifier in a grouping — walk back further.
    if (effective_left_tag == .identifier) {
        const RK = @import("reference.zig").ReferenceKind;
        const ref_kind: RK = if (op_tag == .equal) .write else .read_write;
        p.upgradeReferenceKind(left, ref_kind);
    }

    // Plain `=` may need the LHS converted to a pattern.
    if (op_tag == .equal) {
        reinterpretAsPattern(p, left);
        try validatePattern(p, left);
        // For destructuring assignment, upgrade all identifier refs in the
        // LHS pattern from read to write. Simple identifier case is already
        // handled above by upgradeReferenceKind.
        if (effective_left_tag != .identifier) {
            try p.upgradePatternRefsToWrite(left);
        }
    }

    // Right-associative: recurse at assignment precedence.
    const rhs = try parseExpressionPrec(p, .assignment);

    const node_tag: Node.Tag = assignTokenToTag(op_tag);
    return p.addNode(.{
        .tag = node_tag,
        .main_token = op_tok,
        .data = .{ .lhs = left, .rhs = rhs },
    });
}

fn assignTokenToTag(tag: TokenTag) Node.Tag {
    return switch (tag) {
        .equal => .assign,
        .plus_equal => .add_assign,
        .minus_equal => .sub_assign,
        .asterisk_equal => .mul_assign,
        .slash_equal => .div_assign,
        .percent_equal => .mod_assign,
        .asterisk_asterisk_equal => .exp_assign,
        .ampersand_equal => .and_assign,
        .pipe_equal => .or_assign,
        .caret_equal => .xor_assign,
        .less_less_equal => .shl_assign,
        .greater_greater_equal => .shr_assign,
        .greater_greater_greater_equal => .ushr_assign,
        .ampersand_ampersand_equal => .logical_and_assign,
        .pipe_pipe_equal => .logical_or_assign,
        .question_question_equal => .nullish_assign,
        else => .error_node,
    };
}

// ── Conditional (ternary) ────────────────────────────────────────

fn parseConditionalTail(p: *Parser, condition: NodeIndex) Error!NodeIndex {
    const q_tok = p.advance(); // consume `?`

    const cond_ev = try p.emitCondOpen(.none);
    // Fork at condition.exit BEFORE parsing the consequent so the outer fork
    // event precedes any nested-ternary events in the resolver stream.
    try p.emitCondFork(condition);
    // Parse consequent at assignment level (commas are part of ternary, not grouping).
    // Set in_conditional_consequent so paren-arrow parsing knows to leave the
    // trailing `:` for the conditional alternate rather than consuming it as
    // a TS return-type annotation. Restore after.
    const saved_in = p.allow_in;
    const saved_cc = p.in_conditional_consequent;
    p.allow_in = true;
    p.in_conditional_consequent = true;
    const consequent = try parseAssignmentExpression(p);
    p.allow_in = saved_in;
    p.in_conditional_consequent = saved_cc;
    try p.emitCondAlt(consequent);

    _ = try p.expect(.colon);
    const alternate = try parseAssignmentExpression(p);

    const extra = try p.addExtra(ast.Conditional, .{
        .consequent = consequent,
        .alternate = alternate,
    });
    const cond_node = try p.addNode(.{
        .tag = .conditional,
        .main_token = q_tok,
        .data = .{ .lhs = condition, .rhs = NodeIndex.fromInt(extra) },
    });
    try p.emitCondClose(cond_node);
    p.patchEventNode(cond_ev, cond_node);
    return cond_node;
}

// ── Sequence expression (comma) ──────────────────────────────────

fn parseSequenceExpression(p: *Parser, first: NodeIndex) Error!NodeIndex {
    const comma_tok: u32 = p.tokIdx();
    const scratch_top = p.scratchLen();
    try p.scratchPush(first);

    while (p.peek() == .comma) {
        _ = p.advance(); // consume `,`
        const expr = try parseAssignmentExpression(p);
        try p.scratchPush(expr);
    }

    const exprs = p.scratchSlice(scratch_top);
    const range = try p.addSlice(exprs);
    p.scratchPop(scratch_top);

    return p.addNode(.{
        .tag = .sequence_expr,
        .main_token = comma_tok,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// Call expression
// =====================================================================

fn parseCallExpression(p: *Parser, callee: NodeIndex) Error!NodeIndex {
    // super() is only valid in class constructors (skip check in TS mode — type error not syntax error)
    if (callee != .none and !p.is_ts) {
        const callee_tag = p.node_tags_ptr[callee.toInt()];
        if (callee_tag == .super_expr) {
            if (p.in_class_field) {
                try p.emitError("'super()' is not allowed in class field initializers");
            } else if (!p.in_constructor) {
                try p.emitError("'super()' is only valid in class constructors");
            } else if (!p.class_has_heritage) {
                try p.emitError("'super()' is only valid in derived classes (with 'extends')");
            }
        }
    }
    const open_paren: u32 = p.tokIdx();
    const args_range = try parseArgumentList(p);
    const range_extra = try p.addExtra(SubRange, .{
        .start = args_range.start,
        .end = args_range.end,
    });
    return p.addNode(.{
        .tag = .call_expr,
        .main_token = open_paren,
        .data = .{ .lhs = callee, .rhs = NodeIndex.fromInt(range_extra) },
    });
}

fn parseArgumentList(p: *Parser) Error!SubRange {
    _ = p.advance(); // consume `(`
    // `in` is always allowed inside `(...)` (even in for-in init)
    const saved_allow_in_args = p.allow_in;
    p.allow_in = true;
    defer p.allow_in = saved_allow_in_args;
    const scratch_top = p.scratchLen();

    while (true) {
        const cur = p.peek();
        if (cur == .r_paren or cur == .eof) break;
        const arg = try parseAssignmentOrSpread(p);
        // Check for CoverInitializedName ({a = 0}) immediately — call/new/optional-call
        // args are never patterns, so {a=0} is always invalid.  Checking here covers all
        // call contexts (not just statement-level calls) and lets us remove .call_expr from
        // tagNeedsCoverCheck, eliminating the post-parse argument walk.
        p.checkCoverInitializedNameFast(arg);
        try p.scratchPush(arg);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_paren);

    const args = p.scratchSlice(scratch_top);
    const range = try p.addSlice(args);
    p.scratchPop(scratch_top);
    return range;
}

// =====================================================================
// Member access:  obj.prop
// =====================================================================

fn parseMemberAccess(p: *Parser, object: NodeIndex) Error!NodeIndex {
    _ = p.advance(); // consume `.`

    // Allow keywords and private names as property names.
    const pt = p.peek();
    const prop_tok = if (pt.isKeyword() or pt == .identifier or pt == .escaped_keyword)
        p.advance()
    else if (pt == .hash) blk: {
        if (!p.in_class and !p.is_ts) {
            try p.emitError("Private field access is only allowed inside a class");
        }
        // Spec: super.#x is invalid — private fields cannot be accessed via super.
        if (object != .none and p.node_tags_ptr[object.toInt()] == .super_expr) {
            try p.emitError("Private fields cannot be accessed via 'super'");
        }
        const hash = p.advance();
        // Spec: no whitespace between `#` and identifier — token must be
        // contiguous (start of ident == hash.start + 1).
        const hash_start = p.tok_starts_ptr[hash];
        const pi = p.peek();
        if (pi == .identifier or pi.isKeyword() or pi == .escaped_keyword) {
            const ident_start = p.tok_starts_ptr[p.tok_i];
            if (ident_start != hash_start + 1) {
                try p.emitError("No whitespace allowed between `#` and identifier");
            }
            _ = p.advance();
        } else {
            try p.emitError("Expected identifier after `#`");
        }
        // Track for AllPrivateNamesValid validation.
        try p.private_refs.append(p.gpa, hash);
        break :blk hash;
    } else blk: {
        try p.emitError("Expected property name after '.'");
        break :blk p.tokIdx();
    };

    const prop_node = try p.addNode(.{
        .tag = .property_ident,
        .main_token = prop_tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
    return p.addNode(.{
        .tag = .member_expr,
        .main_token = prop_tok,
        .data = .{ .lhs = object, .rhs = prop_node },
    });
}

// =====================================================================
// Computed member access:  obj[expr]
// =====================================================================

fn parseComputedMember(p: *Parser, object: NodeIndex) Error!NodeIndex {
    const bracket = p.advance(); // consume `[`
    // TS1011: An element access expression should take an argument.
    if (p.peek() == .r_bracket) {
        try p.emitDiagnostic(p.currentSpan(), "An element access expression should take an argument", .{});
    }
    // `in` is always allowed inside `[...]` (even in for-in init)
    const saved_allow_in = p.allow_in;
    p.allow_in = true;
    const index_expr = try parseExpression(p);
    p.allow_in = saved_allow_in;
    _ = try p.expect(.r_bracket);
    return p.addNode(.{
        .tag = .computed_member_expr,
        .main_token = bracket,
        .data = .{ .lhs = object, .rhs = index_expr },
    });
}

// =====================================================================
// Optional chaining:  obj?.prop  obj?.[expr]  obj?.(args)
// =====================================================================

fn parseOptionalChain(p: *Parser, object: NodeIndex) Error!NodeIndex {
    const q_dot_tok = p.advance(); // consume `?.`

    switch (p.peek()) {
        // obj?.(args)
        .l_paren => {
            const args_range = try parseArgumentList(p);
            const range_extra = try p.addExtra(SubRange, .{
                .start = args_range.start,
                .end = args_range.end,
            });
            return p.addNode(.{
                .tag = .optional_call_expr,
                .main_token = q_dot_tok,
                .data = .{ .lhs = object, .rhs = NodeIndex.fromInt(range_extra) },
            });
        },
        // obj?.[expr]
        .l_bracket => {
            _ = p.advance(); // consume `[`
            const index_expr = try parseExpression(p);
            _ = try p.expect(.r_bracket);
            return p.addNode(.{
                .tag = .optional_computed_member_expr,
                .main_token = q_dot_tok,
                .data = .{ .lhs = object, .rhs = index_expr },
            });
        },
        // obj?.prop or obj?.#private
        else => {
            // Accept private identifier: obj?.#field (keywords valid: obj?.#await)
            if (p.peek() == .hash) {
                const hash_tok = p.advance();
                { const ph5 = p.peek(); if (ph5 == .identifier or ph5.isKeyword() or ph5 == .escaped_keyword) _ = p.advance(); }
                try p.private_refs.append(p.gpa, hash_tok);
                const prop_node = try p.addNode(.{
                    .tag = .identifier,
                    .main_token = hash_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
                return p.addNode(.{
                    .tag = .optional_member_expr,
                    .main_token = hash_tok,
                    .data = .{ .lhs = object, .rhs = prop_node },
                });
            }
            const pq = p.peek();
            const prop_tok = if (pq.isKeyword() or pq == .identifier or pq == .escaped_keyword)
                p.advance()
            else blk: {
                try p.emitError("Expected property name after '?.'");
                break :blk p.tokIdx();
            };
            const prop_node = try p.addNode(.{
                .tag = .property_ident,
                .main_token = prop_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            return p.addNode(.{
                .tag = .optional_member_expr,
                .main_token = prop_tok,
                .data = .{ .lhs = object, .rhs = prop_node },
            });
        },
    }
}

// =====================================================================
// Tagged template:  tag`template`
// =====================================================================

fn parseTaggedTemplate(p: *Parser, tag_expr: NodeIndex) Error!NodeIndex {
    // Tagged templates require MemberExpression or CallExpression
    if (tag_expr != .none) {
        const te = p.node_tags_ptr[tag_expr.toInt()];
        if (te == .postfix_inc or te == .postfix_dec or te == .prefix_inc or te == .prefix_dec) {
            try p.emitError("Tagged template cannot follow an update expression");
        }
        // Optional chaining cannot have a tagged template in tail position
        if (te == .optional_member_expr or te == .optional_computed_member_expr or
            te == .optional_call_expr)
        {
            try p.emitError("Tagged template cannot follow an optional chain");
            return error.ParseError;
        }
    }
    const main_tok: u32 = p.tokIdx();
    const tmpl = try parseTemplateLiteralTagged(p);
    return p.addNode(.{
        .tag = .tagged_template,
        .main_token = main_tok,
        .data = .{ .lhs = tag_expr, .rhs = tmpl },
    });
}

// =====================================================================
// Formal parameters:  (a, b = 1, ...rest)
// =====================================================================

fn parseFormalParameters(p: *Parser) Error!SubRange {
    _ = try p.expect(.l_paren);
    const prev_fp_params = p.in_fn_params;
    p.in_fn_params = true;
    defer p.in_fn_params = prev_fp_params;
    const scratch_top = p.scratchLen();

    while (p.peek() != .r_paren and p.peek() != .eof) {
        const param = try parseBindingElement(p);
        try p.scratchPush(param);

        // Check: rest parameter cannot have trailing comma
        const ptag = p.node_tags_ptr[param.toInt()];
        if (ptag == .rest_element and p.peek() == .comma) {
            try p.emitError("Rest parameter must not have a trailing comma");
            return error.ParseError;
        }

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_paren);

    const params = p.scratchSlice(scratch_top);

    // Rest parameter must be last (skip in TS — semantic error)
    if (!p.is_ts and params.len > 1) {
        for (params[0 .. params.len - 1]) |param_raw| {
            const ptag = p.node_tags_ptr[@intCast(param_raw)];
            if (ptag == .rest_element) {
                try p.emitError("Rest parameter must be last formal parameter");
                return error.ParseError;
            }
        }
    }

    const range = try p.addSlice(params);
    p.scratchPop(scratch_top);
    return range;
}

/// Parse a single binding element (parameter).
/// Handles: identifier, { pattern }, [ pattern ], ...rest, param = default
fn parseBindingElement(p: *Parser) Error!NodeIndex {
    // Rest element
    if (p.peek() == .ellipsis) {
        const tok = p.advance();
        const arg = try parseBindingPattern(p);
        if (!p.suppress_param_declares) try p.emitDeclaresFromPattern(arg, .parameter);
        const type_ann = try p.parseOptionalTypeAnnotation();
        return p.addNode(.{
            .tag = .rest_element,
            .main_token = tok,
            .data = .{ .lhs = arg, .rhs = type_ann },
        });
    }

    // TS parameter decorators: @dec before parameter
    if (p.is_ts) {
        while (p.peek() == .at_sign) {
            _ = p.advance(); // skip '@'
            // Skip decorator expression: @(expr) or @ident(.ident)*(args)?
            if (p.peek() == .l_paren) {
                skipBalancedParens(p);
            } else {
                // Skip identifier chain: ident.ident.ident
                if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
                while (p.peek() == .dot) {
                    _ = p.advance();
                    if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
                }
                // Optional call args
                if (p.peek() == .l_paren) skipBalancedParens(p);
            }
        }
    }

    // TS parameter modifiers: public, private, protected, readonly, override
    // If any access/readonly modifier is present, wrap the param in ts_parameter_property.
    var param_prop_main_tok: ?ast.TokenIndex = null;
    if (p.is_ts) {
        const saved_tok = p.tok_i;
        var first_mod_tok: ?ast.TokenIndex = null;
        while (p.peek() == .identifier or p.peek() == .kw_readonly or
            p.peek() == .kw_override or p.peek() == .kw_declare)
        {
            const text = p.tokenText(p.tokIdx());
            const is_mod = std.mem.eql(u8, text, "public") or
                std.mem.eql(u8, text, "private") or
                std.mem.eql(u8, text, "protected") or
                std.mem.eql(u8, text, "readonly") or
                std.mem.eql(u8, text, "override");
            if (!is_mod) break;
            const next = p.peekAt(1);
            if (next == .colon or next == .comma or next == .r_paren or
                next == .equal or next == .question)
                break;
            if (first_mod_tok == null) first_mod_tok = p.tokIdx();
            _ = p.advance();
        }
        if (first_mod_tok != null and p.tok_i > saved_tok) {
            param_prop_main_tok = first_mod_tok;
        }
    }

    // TS `this` parameter: `this: Type` or `this` (contextual typing).
    // Preserve the annotation in `data.rhs` so type-aware rules can read
    // it (matches how regular binding identifiers store annotations).
    if (p.is_ts and p.peek() == .kw_this) {
        const next = p.peekAt(1);
        if (next == .colon or next == .comma or next == .r_paren) {
            const this_tok = p.advance();
            var annotation: NodeIndex = .none;
            if (p.peek() == .colon) {
                annotation = try p.parseOptionalTypeAnnotation();
            }
            return p.addNode(.{
                .tag = .identifier,
                .main_token = this_tok,
                .data = .{ .lhs = .none, .rhs = annotation },
            });
        }
    }

    const binding_main_tok = p.tok_i;
    var node = try parseBindingPattern(p);
    if (!p.suppress_param_declares) try p.emitDeclaresFromPattern(node, .parameter);

    // TS optional parameter marker and type annotation
    if (p.is_ts) {
        const is_optional_ts = p.eat(.question) != null;
        const type_ann = try p.parseOptionalTypeAnnotation();
        // Attach type annotation to identifier binding so typeAnnotation getter works.
        // Skip if wrapped in TSParameterProperty — jsdocUtils path diverges for that case
        // and the proto-deletion fix handles it correctly without the attachment.
        if (type_ann != .none and param_prop_main_tok == null) {
            const node_tag = p.node_tags_ptr[node.toInt()];
            if (node_tag == .identifier) {
                p.node_data_ptr[node.toInt()].rhs = type_ann;
                // @typescript-eslint extends the parameter Identifier's range
                // through its typeAnnotation; rules call sourceCode.getText(param)
                // and expect `name: Type`, not just `name`.
                p.node_end_toks[node.toInt()] = if (p.tok_i > 0) @intCast(p.tok_i - 1) else 0;
                // Patch parents[type_ann] = node so the parent chain
                // reaches the binding identifier (addNode's initial
                // setChildParents ran before this mutation).
                const ann_idx = type_ann.toInt();
                if (ann_idx < p.parents_buf.len) p.parents_buf[ann_idx] = @intCast(node.toInt());
            } else if (node_tag == .object_pattern or node_tag == .array_pattern) {
                // Patterns can't store the annotation inline (their
                // data slots hold a SubRange), but we still need
                // downstream rules (no-unsafe-*, unbound-method, …) to
                // reach the annotation.  Wire parents[type_ann] = node
                // so a parent-walk from the annotation lands on the
                // pattern, and let rules discover it by scanning all
                // ts_type_annotation children whose parent matches.
                const ann_idx = type_ann.toInt();
                if (ann_idx < p.parents_buf.len) p.parents_buf[ann_idx] = @intCast(node.toInt());
                p.node_end_toks[node.toInt()] = if (p.tok_i > 0) @intCast(p.tok_i - 1) else 0;
            }
        }
        // Encode optional `?` marker in lhs (lhs=root/0 means optional; lhs=none means not).
        if (is_optional_ts) {
            const node_tag = p.node_tags_ptr[node.toInt()];
            if (node_tag == .identifier) {
                p.node_data_ptr[node.toInt()].lhs = .root;
            }
        }
        // TS1015: Parameter cannot have both '?' (optional) and '=' (initializer).
        if (is_optional_ts and p.peek() == .equal) {
            try p.emitDiagnostic(p.currentSpan(), "Parameter cannot have question mark and initializer", .{});
        }
    }

    // Default initializer
    if (p.peek() == .equal) {
        const eq_tok = p.advance();
        const default_val = try parseAssignmentExpression(p);
        node = try p.addNode(.{
            .tag = .assignment_pattern,
            .main_token = eq_tok,
            .data = .{ .lhs = node, .rhs = default_val },
        });
    }

    // Wrap in TSParameterProperty if access/readonly modifiers were present.
    if (param_prop_main_tok) |mod_tok| {
        _ = binding_main_tok; // suppress unused warning
        return p.addNode(.{
            .tag = .ts_parameter_property,
            .main_token = mod_tok,
            .data = .{ .lhs = node, .rhs = .none },
        });
    }

    _ = binding_main_tok;
    return node;
}

fn parseBindingPattern(p: *Parser) Error!NodeIndex {
    return switch (p.peek()) {
        .identifier => blk: {
            // Strict mode: `eval` and `arguments` cannot be binding names.
            // (TS without strict mode permits them — matches typescript-eslint
            // test expectations for fixtures like
            // `function (foo, arguments) { ... }`.)
            if (p.in_strict) {
                const text = p.tokenText(p.tokIdx());
                if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "arguments")) {
                    try p.emitError("cannot use eval or arguments as a binding name in strict mode");
                    return p.makeErrorNode();
                }
            }
            break :blk parseIdentifier(p);
        },
        .l_brace => parseObjectBindingPattern(p),
        .l_bracket => parseArrayBindingPattern(p),
        // yield can be binding name outside generators/strict
        .kw_yield => {
            if (p.in_generator or p.in_strict) {
                try p.emitError("'yield' cannot be used as binding name in this context");
                return p.makeErrorNode();
            }
            return parseIdentifier(p);
        },
        // await is reserved in async/module/static-block contexts.
        // In TypeScript: same rule, but allow in ambient declarations.
        .kw_await => {
            if (!p.in_ts_ambient and (p.in_async or p.is_module or (p.in_static_block and !p.in_function))) {
                try p.emitError("'await' cannot be used as binding name in this context");
                return p.makeErrorNode();
            }
            return parseIdentifier(p);
        },
        // Contextual keywords that can be binding names in non-strict
        .kw_let, .kw_static, .kw_of, .kw_from, .kw_as, .kw_get, .kw_set => {
            // TypeScript ambient declarations allow keywords like `static` as binding names
            // (e.g., `declare var static: any`). Skip the strict-mode check in that context.
            if (p.in_strict and (p.peek() == .kw_let or p.peek() == .kw_static) and
                !(p.is_ts and p.in_ts_ambient))
            {
                try p.emitError("Cannot use reserved word as binding in strict mode");
                return p.makeErrorNode();
            }
            return parseIdentifier(p);
        },
        .escaped_keyword => {
            const text = p.tokenText(p.tokIdx());
            var resolved_buf: [256]u8 = undefined;
            if (parser_mod.resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
                if (parser_mod.isAlwaysReservedStr(resolved)) {
                    try p.emitError("escaped reserved word cannot be used as a binding name");
                    return p.makeErrorNode();
                }
                if (std.mem.eql(u8, resolved, "yield") and (p.in_generator or p.in_strict)) {
                    try p.emitError("'yield' cannot be used as a binding name in this context");
                    return p.makeErrorNode();
                }
                if (std.mem.eql(u8, resolved, "await") and
                    !p.in_ts_ambient and
                    (p.in_async or p.is_module or (p.in_static_block and !p.in_function)))
                {
                    try p.emitError("'await' cannot be used as a binding name in this context");
                    return p.makeErrorNode();
                }
                if (p.in_strict and parser_mod.Parser.isStrictReservedStr(resolved)) {
                    try p.emitError("escaped reserved word cannot be used as binding name in strict mode");
                    return p.makeErrorNode();
                }
            }
            return parseIdentifier(p);
        },
        // TS contextual keywords can be binding names
        .kw_type, .kw_declare, .kw_namespace, .kw_module,
        .kw_interface, .kw_abstract, .kw_readonly, .kw_override,
        .kw_keyof, .kw_infer, .kw_is, .kw_asserts, .kw_satisfies,
        .kw_unique, .kw_async,
        => {
            if (p.is_ts) return parseIdentifier(p);
            try p.emitError("Expected binding pattern");
            return p.makeErrorNode();
        },
        else => {
            try p.emitError("Expected binding pattern");
            return p.makeErrorNode();
        },
    };
}

fn parseObjectBindingPattern(p: *Parser) Error!NodeIndex {
    const open = p.advance(); // consume `{`
    // Allow `in` operator inside binding patterns (needed for `for (let {x = 'a' in {}} = ...)`)
    const saved_allow_in = p.allow_in;
    p.allow_in = true;
    defer p.allow_in = saved_allow_in;
    const scratch_top = p.scratchLen();

    while (p.peek() != .r_brace and p.peek() != .eof) {
        if (p.peek() == .ellipsis) {
            const tok = p.advance();
            const arg = try parseBindingPattern(p);
            // TypeScript TS2566: `{ ...a: b }` — rest element with property name.
            // Parse (and ignore) the `: binding` part; emit as rest_element.
            if (p.is_ts and p.peek() == .colon) {
                _ = p.advance(); // eat ':'
                _ = try parseBindingPattern(p); // discard the rename binding
            }
            const rest = try p.addNode(.{
                .tag = .rest_element,
                .main_token = tok,
                .data = .{ .lhs = arg, .rhs = .none },
            });
            try p.scratchPush(rest);
            if (!p.is_ts) break; // rest must be last (TS: semantic error)
            if (p.peek() == .comma) {
                _ = p.advance();
            } else {
                break;
            }
            continue;
        }

        const prop = try parseBindingProperty(p);
        try p.scratchPush(prop);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_brace);

    const props = p.scratchSlice(scratch_top);
    const range = try p.addSlice(props);
    p.scratchPop(scratch_top);

    return p.addNode(.{
        .tag = .object_pattern,
        .main_token = open,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

fn parseBindingProperty(p: *Parser) Error!NodeIndex {
    const key_tok: u32 = p.tokIdx();

    // Computed key: [expr]: pattern
    if (p.peek() == .l_bracket) {
        _ = p.advance();
        const key_expr = try parseAssignmentExpression(p);
        _ = try p.expect(.r_bracket);
        _ = try p.expect(.colon);
        // The outer object-pattern walk in emitDeclaresFromPatternImpl
        // recurses into computed_property.rhs to emit binding declares.
        // parseBindingElement also emits declares for its parsed pattern,
        // so calling it here unsuppressed double-emits — same name, same
        // decl_node, two distinct symbol IDs in the same scope. Suppress
        // the inner emit and let the outer walker own it.
        const saved_s1 = p.suppress_param_declares;
        p.suppress_param_declares = true;
        const value = parseBindingElement(p) catch |err| {
            p.suppress_param_declares = saved_s1;
            return err;
        };
        p.suppress_param_declares = saved_s1;
        return p.addNode(.{
            .tag = .computed_property,
            .main_token = key_tok,
            .data = .{ .lhs = key_expr, .rhs = value },
        });
    }

    const key = try parsePropertyName(p);

    // key: pattern — same double-emit reason as the computed-key branch.
    if (p.peek() == .colon) {
        _ = p.advance();
        const saved_s2 = p.suppress_param_declares;
        p.suppress_param_declares = true;
        const value = parseBindingElement(p) catch |err| {
            p.suppress_param_declares = saved_s2;
            return err;
        };
        p.suppress_param_declares = saved_s2;
        return p.addNode(.{
            .tag = .property,
            .main_token = key_tok,
            .data = .{ .lhs = key, .rhs = value },
        });
    }

    // Shorthand { x = default }
    if (p.peek() == .equal) {
        _ = p.advance();
        const default_val = try parseAssignmentExpression(p);
        return p.addNode(.{
            .tag = .assignment_pattern,
            .main_token = key_tok,
            .data = .{ .lhs = key, .rhs = default_val },
        });
    }

    // Shorthand { x } — check for reserved keyword as binding name
    const key_tag_bp = p.tokenTag(key_tok);
    if (key_tag_bp == .kw_yield and p.in_generator) {
        try p.emitError("'yield' is not allowed as a binding name in generator");
        return error.ParseError;
    }
    if (key_tag_bp == .kw_await and (p.in_async or p.is_module)) {
        try p.emitError("'await' is not allowed as a binding name here");
        return error.ParseError;
    }

    return p.addNode(.{
        .tag = .shorthand_property,
        .main_token = key_tok,
        .data = .{ .lhs = key, .rhs = .none },
    });
}

fn parseArrayBindingPattern(p: *Parser) Error!NodeIndex {
    const open = p.advance(); // consume `[`
    // Allow `in` operator inside binding patterns (needed for `for (let [x = 'a' in {}] = ...)`)
    const saved_allow_in = p.allow_in;
    p.allow_in = true;
    defer p.allow_in = saved_allow_in;
    const scratch_top = p.scratchLen();

    while (p.peek() != .r_bracket and p.peek() != .eof) {
        // Elision
        if (p.peek() == .comma) {
            try p.scratchPush(NodeIndex.none);
            _ = p.advance();
            continue;
        }

        if (p.peek() == .ellipsis) {
            const tok = p.advance();
            const arg = try parseBindingPattern(p);
            const rest = try p.addNode(.{
                .tag = .rest_element,
                .main_token = tok,
                .data = .{ .lhs = arg, .rhs = .none },
            });
            try p.scratchPush(rest);
            if (!p.is_ts) break; // rest must be last (TS: semantic error)
            if (p.peek() == .comma) {
                _ = p.advance();
            } else {
                break;
            }
            continue;
        }

        const elem = try parseBindingElement(p);
        try p.scratchPush(elem);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_bracket);

    const elements = p.scratchSlice(scratch_top);
    const range = try p.addSlice(elements);
    p.scratchPop(scratch_top);

    return p.addNode(.{
        .tag = .array_pattern,
        .main_token = open,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// Block body (shared by function / class / arrow / getter / setter)
// =====================================================================

/// Parse `{ statements }`.  Delegates to the statement parser in
/// parser.zig.  This is a thin wrapper that consumes braces.
fn parseBlockBody(p: *Parser) Error!NodeIndex {
    return parseBlockBodyWithStrictChecks(p, null, .none);
}

/// Parse block body with optional strict-mode checks for function params/name.
fn parseBlockBodyWithStrictChecks(p: *Parser, params: ?SubRange, name: NodeIndex) Error!NodeIndex {
    // Check for "use strict" directive in function body
    const prev_strict = p.in_strict;
    var has_use_strict = false;
    var became_strict = false;
    if (p.peek() == .l_brace) {
        // Look past the { for directive prologue
        const saved = p.tok_i;
        _ = p.tok_i; // don't advance, just peek ahead
        var pos = saved + 1; // skip {
        while (pos < p.tokens.len) {
            const tag = p.tags_ptr[pos];
            if (tag != .string_literal) break;
            const start = p.tok_starts_ptr[pos];
            const text = p.getStringContent(start);
            if (std.mem.eql(u8, text, "use strict")) {
                has_use_strict = true;
                if (!prev_strict) {
                    p.in_strict = true;
                    became_strict = true;
                }
                break;
            }
            pos += 1;
            if (pos < p.tokens.len and p.tags_ptr[pos] == .semicolon) pos += 1;
        }
    }
    defer p.in_strict = prev_strict;

    // Function bodies isolate break/continue/label context — can't break out of a function.
    const prev_in_loop = p.in_loop;
    const prev_in_switch = p.in_switch;
    const prev_label_count_fn = p.ts_label_count;
    const prev_label_fn_depth = p.ts_label_fn_depth;
    p.in_loop = false;
    p.in_switch = false;
    p.ts_label_count = 0; // labels from outer scope not visible inside function body
    if (p.ts_label_fn_depth < std.math.maxInt(u16)) p.ts_label_fn_depth += 1;
    defer p.in_loop = prev_in_loop;
    defer p.in_switch = prev_in_switch;
    defer p.ts_label_count = prev_label_count_fn;
    defer p.ts_label_fn_depth = prev_label_fn_depth;

    // "use strict" with non-simple parameters is a SyntaxError in plain JS.
    // In TypeScript, this is TS1346/TS1347 (target-dependent, semantic-only),
    // so TypeScript's parser accepts it; we skip the restriction in TS mode.
    if (has_use_strict and !p.is_ts) {
        if (params) |pr| {
            if (p.hasNonSimpleParams(pr)) {
                try p.emitError("\"use strict\" directive not allowed in function with non-simple parameters");
                return error.ParseError;
            }
        }
    }

    // Methods always reject duplicate params; functions reject if strict or non-simple.
    if (params) |pr| {
        const must_unique = p.in_method or p.in_strict or p.hasNonSimpleParams(pr);
        if (must_unique) try p.checkUniqueParams(pr);
    }

    // If body made us newly strict, check additional restrictions retroactively
    if (became_strict) {
        if (params) |pr| {
            // Check params for eval/arguments
            try p.checkParamsStrictMode(pr);
        }
        // Function name must not be eval/arguments or strict-reserved in strict mode
        if (name != .none) {
            const fn_name_tok = p.node_main_token_ptr[name.toInt()];
            const fn_name_text = p.tokenText(fn_name_tok);
            if (std.mem.eql(u8, fn_name_text, "eval") or std.mem.eql(u8, fn_name_text, "arguments")) {
                try p.emitError("Unexpected eval or arguments in strict mode");
                return error.ParseError;
            }
            if (!p.is_ts and p.isStrictReservedWord(fn_name_tok)) {
                try p.emitError("Function name is a reserved word in strict mode");
                return error.ParseError;
            }
        }
    }

    const prev_fn_body = p.is_fn_body_block;
    p.is_fn_body_block = true;
    defer p.is_fn_body_block = prev_fn_body;
    const body = try p.parseBlock();
    // Check that no formal parameter name is lex-re-declared in the function body.
    // Applies to: methods, generators, async functions, and strict-mode functions.
    if (params) |pr| {
        if (p.in_method or p.in_generator or p.in_async or p.in_strict) {
            try p.checkParamBodyLexConflict(pr, body);
        }
    }
    return body;
}

// =====================================================================
// Cover grammar: reinterpret expression as pattern
// =====================================================================

/// Walk the AST subtree rooted at `node` and mutate node tags so that
/// expression forms become their destructuring-pattern equivalents.
/// Called when we discover `(expr) =>` and need arrow parameters, or
/// when `=` is used on an expression LHS.
///
/// Rewriting rules:
///   array_literal   → array_pattern
///   object_literal  → object_pattern
///   spread_element  → rest_element
///   assign          → assignment_pattern
///   property        stays property (key: value stays the same)
///   shorthand_property stays shorthand_property
///   grouping_expr   → unwrap to inner expression, then reinterpret
///
/// Other tags are left unchanged (identifiers, member expressions, etc.)
/// and may be validated later as valid assignment targets.
pub fn reinterpretAsPattern(p: *Parser, node: NodeIndex) void {
    if (node == .none) return;

    const idx = node.toInt();
    const tag = p.nodeTag(idx);

    switch (tag) {
        .array_literal => {
            p.setNodeTag(idx, .array_pattern);
            // Reinterpret each element.
            const data = p.nodeData(idx);
            const start = data.lhs.toInt();
            const end = data.rhs.toInt();
            var i = start;
            while (i < end) : (i += 1) {
                const child = NodeIndex.fromInt(p.getExtraData(i));
                reinterpretAsPattern(p, child);
            }
        },
        .object_literal => {
            p.setNodeTag(idx, .object_pattern);
            const data = p.nodeData(idx);
            const start = data.lhs.toInt();
            const end = data.rhs.toInt();
            var i = start;
            while (i < end) : (i += 1) {
                const child = NodeIndex.fromInt(p.getExtraData(i));
                reinterpretAsPattern(p, child);
            }
        },
        .spread_element => {
            p.setNodeTag(idx, .rest_element);
            const data = p.nodeData(idx);
            reinterpretAsPattern(p, data.lhs);
        },
        .assign => {
            p.setNodeTag(idx, .assignment_pattern);
            const data = p.nodeData(idx);
            reinterpretAsPattern(p, data.lhs);
        },
        .property => {
            // Property value may need reinterpretation.
            const data = p.nodeData(idx);
            reinterpretAsPattern(p, data.rhs);
        },
        .shorthand_property => {
            // Nothing to reinterpret — identifier shorthand is already a
            // valid binding.
        },
        .computed_property => {
            // Reinterpret the value part.
            const data = p.nodeData(idx);
            reinterpretAsPattern(p, data.rhs);
        },
        .grouping_expr => {
            // Unwrap grouping and reinterpret the inner expression.
            const data = p.nodeData(idx);
            reinterpretAsPattern(p, data.lhs);
        },
        .sequence_expr => {
            // In arrow parameters context, a sequence in parens is valid
            // because the parenthesized handler already split elements.
            // If we reach here, each element needs reinterpretation.
            const data = p.nodeData(idx);
            const start = data.lhs.toInt();
            const end = data.rhs.toInt();
            var i = start;
            while (i < end) : (i += 1) {
                const child = NodeIndex.fromInt(p.getExtraData(i));
                reinterpretAsPattern(p, child);
            }
        },
        // Identifiers, member expressions, etc. are valid assignment
        // targets and don't need tag changes.
        else => {},
    }
}

// =====================================================================
// TypeScript expression extensions
// =====================================================================

/// TS1355: Check whether a node is a valid target for `as const`.
/// Valid targets: literals (string, number, bigint, boolean, template), array/object literals,
/// parenthesized versions thereof, unary +/- on numeric literals, and member expressions (enum members).
fn isValidConstAssertionTarget(p: *Parser, node: NodeIndex) bool {
    if (node == .none) return false;
    return switch (p.node_tags_ptr[node.toInt()]) {
        .string_literal, .number_literal, .bigint_literal, .boolean_literal,
        .template_literal, .array_literal, .object_literal => true,
        .unary_plus, .unary_minus => blk: {
            const inner = p.node_data_ptr[node.toInt()].lhs;
            if (inner == .none) break :blk false;
            const inner_tag = p.node_tags_ptr[inner.toInt()];
            break :blk inner_tag == .number_literal or inner_tag == .bigint_literal;
        },
        .grouping_expr => blk: {
            const inner = p.node_data_ptr[node.toInt()].lhs;
            break :blk isValidConstAssertionTarget(p, inner);
        },
        // Enum member access (e.g., MyEnum.Value)
        .member_expr, .computed_member_expr,
        .optional_member_expr, .optional_computed_member_expr => true,
        else => false,
    };
}

/// Parse `expr as Type` or `expr satisfies Type`.
fn parseTsTypePostfix(p: *Parser, left: NodeIndex, node_tag: Node.Tag) Error!NodeIndex {
    const op_tok = p.advance();
    const ts_mod = @import("typescript.zig");
    const type_node = try ts_mod.parseType(p);
    return p.addNode(.{
        .tag = node_tag,
        .main_token = op_tok,
        .data = .{ .lhs = left, .rhs = type_node },
    });
}

/// Parse `expr!` — TS non-null assertion.
fn parseTsNonNullExpression(p: *Parser, left: NodeIndex) Error!NodeIndex {
    const bang_tok = p.advance(); // consume `!`
    return p.addNode(.{
        .tag = .ts_non_null_expr,
        .main_token = bang_tok,
        .data = .{ .lhs = left, .rhs = .none },
    });
}

/// Parse `<Type>expr` — TS type assertion (angle bracket form).
fn parseTsTypeAssertion(p: *Parser) Error!NodeIndex {
    const ts_mod = @import("typescript.zig");

    // Try to detect generic arrow function: <T extends X>(params) => body
    // vs type assertion: <Type>expr
    // Heuristic: speculatively parse as type parameters; if followed by `(`, it's a generic arrow.
    {
        const saved_tok: u32 = p.tokIdx();
        const saved_diag = p.diagnostics.items.len;
        const saved_nodes = p.nodes.len;
        const saved_extra = p.extra_data.items.len;

        var generic_arrow_type_params = ast.SubRange{ .start = 0, .end = 0 };
        const type_params_ok = blk: {
            generic_arrow_type_params = ts_mod.parseTypeParameterList(p) catch break :blk false;
            break :blk true;
        };

        if (type_params_ok and p.peek() == .l_paren) {
            // Speculatively try generic arrow: <T>(params) => body.
            // Suppress declare emission during speculative params parse; replayed into the
            // arrow's function scope below (same pattern as typed non-generic arrows).
            var params_range = ast.SubRange{ .start = 0, .end = 0 };
            var generic_arrow_return_type: ast.NodeIndex = .none;
            const arrow_ok = blk: {
                _ = p.advance(); // consume `(`
                const saved_suppress = p.suppress_param_declares;
                p.suppress_param_declares = true;
                const pr = parseFormalParameters_inner(p, saved_tok) catch {
                    p.suppress_param_declares = saved_suppress;
                    break :blk false;
                };
                p.suppress_param_declares = saved_suppress;
                params_range = pr;
                generic_arrow_return_type = p.parseOptionalTypeAnnotation() catch break :blk false;
                if (p.peek() == .arrow and !p.isOnNewLine()) break :blk true;
                break :blk false;
            };
            if (arrow_ok) {
                _ = p.advance(); // consume `=>`
                const saved_fn = p.in_function;
                const saved_async_ts2 = p.in_async;
                p.in_function = true;
                p.in_async = false;
                defer p.in_function = saved_fn;
                defer p.in_async = saved_async_ts2;
                const generic_arrow_ev = try p.emitScopeOpen(.arrow_function, .none);
                // Emit type parameter declares into the arrow scope.
                var k = generic_arrow_type_params.start;
                while (k < generic_arrow_type_params.end) : (k += 1) {
                    const tp_node: @import("ast.zig").NodeIndex = @enumFromInt(p.extra_data.items[k]);
                    try p.emitDeclare(.type_param, tp_node);
                }
                try p.emitParamDeclaresFromRange(params_range);
                const body = try parseArrowBody(p);
                try p.emitScopeClose(.none);
                const extra = try p.addExtra(ast.ArrowData, .{
                    .params_start = params_range.start,
                    .params_end = params_range.end,
                    .body = body,
                    .return_type = generic_arrow_return_type,
                });
                const generic_arrow_node = try p.addNode(.{
                    .tag = .arrow_fn,
                    .main_token = saved_tok,
                    .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
                });
                p.patchScopeOpenNode(generic_arrow_ev, generic_arrow_node);
                return generic_arrow_node;
            }
            // Not a generic arrow — backtrack
        }

        p.tok_i = saved_tok;
        p.diagnostics.shrinkRetainingCapacity(saved_diag);
        p.nodes.len = @intCast(saved_nodes);
        p.extra_data.shrinkRetainingCapacity(saved_extra);
    }

    const lt_tok = p.advance(); // consume `<`
    const type_node = try ts_mod.parseType(p);
    _ = try ts_mod.expectClosingAngleBracket(p);
    const expr = try parseExpressionPrec(p, .unary);
    return p.addNode(.{
        .tag = .ts_type_assertion,
        .main_token = lt_tok,
        .data = .{ .lhs = type_node, .rhs = expr },
    });
}

// =====================================================================
// Scratch helpers — these delegate to Parser methods
// =====================================================================
//
// The scratch buffer is a temporary u32 array used during parsing to
// collect variable-length lists (arguments, array elements, etc.)
// before committing them to extra_data.
//
// The Parser struct provides:
//   p.scratchLen()            → current scratch length
//   p.scratchPush(NodeIndex)  → push a node index
//   p.scratchSlice(top)       → get slice from top to current end
//   p.scratchPop(top)         → reset scratch to top
//   p.addSlice([]const u32)   → commit slice to extra_data, return SubRange
//
// These are used throughout the expression parser and are not
// re-declared here.

// =====================================================================
// Tests
// =====================================================================

test "Precedence ordering" {
    const std_testing = std.testing;

    // Verify precedence levels are ordered correctly.
    try std_testing.expect(@intFromEnum(Precedence.comma) < @intFromEnum(Precedence.assignment));
    try std_testing.expect(@intFromEnum(Precedence.assignment) < @intFromEnum(Precedence.conditional));
    try std_testing.expect(@intFromEnum(Precedence.conditional) < @intFromEnum(Precedence.nullish_coalesce));
    try std_testing.expect(@intFromEnum(Precedence.logical_or) < @intFromEnum(Precedence.logical_and));
    try std_testing.expect(@intFromEnum(Precedence.additive) < @intFromEnum(Precedence.multiplicative));
    try std_testing.expect(@intFromEnum(Precedence.multiplicative) < @intFromEnum(Precedence.exponentiation));
    try std_testing.expect(@intFromEnum(Precedence.exponentiation) < @intFromEnum(Precedence.unary));
    try std_testing.expect(@intFromEnum(Precedence.call) < @intFromEnum(Precedence.primary));
}

test "Precedence right-associativity" {
    const std_testing = std.testing;

    try std_testing.expect(Precedence.assignment.isRightAssociative());
    try std_testing.expect(Precedence.exponentiation.isRightAssociative());
    try std_testing.expect(!Precedence.additive.isRightAssociative());
    try std_testing.expect(!Precedence.equality.isRightAssociative());
    try std_testing.expect(!Precedence.call.isRightAssociative());
}

test "Precedence.next for right-associative" {
    const std_testing = std.testing;

    // Right-associative operators return themselves from .next().
    try std_testing.expectEqual(Precedence.assignment, Precedence.assignment.next());
    try std_testing.expectEqual(Precedence.exponentiation, Precedence.exponentiation.next());

    // Left-associative operators advance by one.
    try std_testing.expectEqual(@intFromEnum(Precedence.additive) + 1, @intFromEnum(Precedence.additive.next()));
}

test "tokenToBinaryTag mapping" {
    const std_testing = std.testing;

    try std_testing.expectEqual(Node.Tag.add, tokenToBinaryTag(.plus));
    try std_testing.expectEqual(Node.Tag.subtract, tokenToBinaryTag(.minus));
    try std_testing.expectEqual(Node.Tag.multiply, tokenToBinaryTag(.asterisk));
    try std_testing.expectEqual(Node.Tag.divide, tokenToBinaryTag(.slash));
    try std_testing.expectEqual(Node.Tag.exponentiate, tokenToBinaryTag(.asterisk_asterisk));
    try std_testing.expectEqual(Node.Tag.strict_equal, tokenToBinaryTag(.equal_equal_equal));
    try std_testing.expectEqual(Node.Tag.logical_and, tokenToBinaryTag(.ampersand_ampersand));
    try std_testing.expectEqual(Node.Tag.logical_or, tokenToBinaryTag(.pipe_pipe));
    try std_testing.expectEqual(Node.Tag.nullish_coalesce, tokenToBinaryTag(.question_question));
    try std_testing.expectEqual(Node.Tag.instanceof_expr, tokenToBinaryTag(.kw_instanceof));
    try std_testing.expectEqual(Node.Tag.in_expr, tokenToBinaryTag(.kw_in));
}

test "assignTokenToTag mapping" {
    const std_testing = std.testing;

    try std_testing.expectEqual(Node.Tag.assign, assignTokenToTag(.equal));
    try std_testing.expectEqual(Node.Tag.add_assign, assignTokenToTag(.plus_equal));
    try std_testing.expectEqual(Node.Tag.sub_assign, assignTokenToTag(.minus_equal));
    try std_testing.expectEqual(Node.Tag.mul_assign, assignTokenToTag(.asterisk_equal));
    try std_testing.expectEqual(Node.Tag.exp_assign, assignTokenToTag(.asterisk_asterisk_equal));
    try std_testing.expectEqual(Node.Tag.logical_and_assign, assignTokenToTag(.ampersand_ampersand_equal));
    try std_testing.expectEqual(Node.Tag.nullish_assign, assignTokenToTag(.question_question_equal));
}

test "isCallPrec" {
    const std_testing = std.testing;

    try std_testing.expect(isCallPrec(.l_paren));
    try std_testing.expect(isCallPrec(.dot));
    try std_testing.expect(isCallPrec(.l_bracket));
    try std_testing.expect(isCallPrec(.question_dot));
    try std_testing.expect(isCallPrec(.template_head));
    try std_testing.expect(isCallPrec(.template_no_sub));
    try std_testing.expect(!isCallPrec(.plus));
    try std_testing.expect(!isCallPrec(.identifier));
    try std_testing.expect(!isCallPrec(.eof));
}

test "isPropertyNameStart" {
    const std_testing = std.testing;

    try std_testing.expect(isPropertyNameStart(.identifier));
    try std_testing.expect(isPropertyNameStart(.string_literal));
    try std_testing.expect(isPropertyNameStart(.number_literal));
    try std_testing.expect(isPropertyNameStart(.l_bracket));
    try std_testing.expect(isPropertyNameStart(.kw_get));
    try std_testing.expect(isPropertyNameStart(.kw_set));
    try std_testing.expect(!isPropertyNameStart(.plus));
    try std_testing.expect(!isPropertyNameStart(.eof));
}

test "isYieldTerminator" {
    const std_testing = std.testing;

    try std_testing.expect(isYieldTerminator(.semicolon));
    try std_testing.expect(isYieldTerminator(.r_paren));
    try std_testing.expect(isYieldTerminator(.r_bracket));
    try std_testing.expect(isYieldTerminator(.eof));
    try std_testing.expect(!isYieldTerminator(.plus));
    try std_testing.expect(!isYieldTerminator(.identifier));
}

// ── TS arrow function helpers ─────────────────────────────────────

/// Try to parse `<Type, Type>` as type arguments in expression position.
/// Returns the SubRange of type args on success, null if it's actually a comparison.
/// Uses token position save/restore for backtracking.
fn tryParseTsTypeArguments(p: *Parser) ?ast.SubRange {
    const saved_tok = p.tok_i;
    const saved_diag_len = p.diagnostics.items.len;
    const saved_nodes_len = p.nodes.len;
    const saved_extra_len = p.extra_data.items.len;

    // Try parsing type arguments
    const typescript = @import("typescript.zig");
    const range = typescript.parseTypeArguments(p) catch {
        // Failed — backtrack.
        // Free any diagnostic messages allocated during the failed attempt
        // before shrinking the list; shrinkRetainingCapacity does not free them.
        for (p.diagnostics.items[saved_diag_len..]) |d| p.gpa.free(d.message);
        p.tok_i = saved_tok;
        p.diagnostics.shrinkRetainingCapacity(saved_diag_len);
        p.nodes.len = @intCast(saved_nodes_len);
        p.extra_data.shrinkRetainingCapacity(saved_extra_len);
        return null;
    };

    // Check what follows — if it's a valid continuation for type arguments, accept
    const next = p.peek();
    if (next == .l_paren or next == .r_paren or next == .r_bracket or
        next == .dot or next == .comma or next == .semicolon or
        next == .question or next == .colon or next == .arrow or
        next == .equal_equal or next == .equal_equal_equal or
        next == .bang_equal or next == .bang_equal_equal or
        next == .ampersand_ampersand or next == .pipe_pipe or
        next == .question_question or next == .template_head or
        next == .template_no_sub or next == .eof or next == .r_brace or
        next == .bang or next == .l_brace or next == .kw_implements or
        next == .kw_extends or next == .kw_as or next == .kw_satisfies)
    {
        return range;
    }

    // Not a valid type argument context — backtrack
    p.tok_i = saved_tok;
    p.diagnostics.shrinkRetainingCapacity(saved_diag_len);
    p.nodes.len = @intCast(saved_nodes_len);
    p.extra_data.shrinkRetainingCapacity(saved_extra_len);
    return null;
}

/// Skip balanced parentheses, consuming from `(` to matching `)`.
fn skipBalancedParens(p: *Parser) void {
    if (p.peek() != .l_paren) return;
    _ = p.advance(); // consume '('
    var depth: u32 = 1;
    while (depth > 0 and !p.isAtEnd()) {
        const tok = p.peek();
        if (tok == .l_paren) depth += 1;
        if (tok == .r_paren) depth -= 1;
        _ = p.advance();
    }
}

/// Check if content after `(` looks like TS typed arrow parameters.
/// Heuristic: first token is `identifier` followed by `:` or `?:`,
/// or first token is `this` followed by `:`, or `...`, `{`, `[`.
/// TSX-only disambiguator: in `.tsx` files at a `<` token, decide whether the
/// upcoming syntax is a generic arrow function (`<T extends X>(...) => ...`,
/// `<T,>(...)=>...`, `<T = X>(...)=>...`) versus a JSX element (`<Foo>...`).
/// Looks 1–3 tokens past the `<` for unambiguous markers. False = treat as JSX.
fn looksLikeTsxGenericArrow(p: *Parser) bool {
    // Token at offset 0 is the `<`. Peek tokens 1+.
    if (p.peekAt(1) != .identifier) return false;
    const after = p.peekAt(2);
    // `<T extends X>(...)` — TS generic with constraint.
    if (after == .kw_extends) return true;
    // `<T,...>(...)` — trailing/leading comma in type-param list (ESBuild's marker).
    if (after == .comma) return true;
    // `<T = X>(...)` — generic with default.
    if (after == .equal) return true;
    return false;
}

fn looksLikeTsArrowParams(p: *Parser) bool {
    const tag = p.peek();
    // (identifier : or (tsKeyword : — typed param
    const is_ident_like = tag == .identifier or tag.isTsContextualKeyword();
    if (is_ident_like) {
        const next = p.peekAt(1);
        if (next == .colon) return true;
        // (identifier ?: — optional typed param (but NOT ternary like `(x ? y : z)`)
        if (next == .question) {
            const after_q = p.peekAt(2);
            if (after_q == .colon or after_q == .r_paren or after_q == .comma) return true;
        }
        // Check for TS modifier followed by another identifier
        const text = if (tag == .identifier) p.tokenText(p.tokIdx()) else "";
        if ((std.mem.eql(u8, text, "public") or std.mem.eql(u8, text, "private") or
            std.mem.eql(u8, text, "protected") or std.mem.eql(u8, text, "readonly") or
            tag == .kw_readonly or tag == .kw_override) and
            (next == .identifier or next == .l_brace or next == .l_bracket or next.isTsContextualKeyword()))
            return true;
    }
    // Scan ahead for ident: pattern in later params with bracket-depth tracking.
    // Handles (a, b: T), (a = 1, b: T), (a, b, c: T), (a, private b), etc.
    // Skip over nested brackets to find typed params at depth 0.
    {
        var i: u32 = 0;
        var depth: i32 = 0;
        // Track whether we're at the start of a parameter (after open-paren or comma at depth 0).
        var at_param_start = true;
        const max_scan: u32 = 64; // limit scan to avoid O(n) on large args
        while (i < max_scan) : (i += 1) {
            const t = p.peekAt(i);
            if (t == .eof) break;
            if (t == .r_paren and depth == 0) break;
            // At param start: `({...}: T)` or `([...]: T)` — destructure
            // pattern followed by type annotation.  Detect by checking
            // for matching close bracket then `:` at depth 0.
            if (at_param_start and depth == 0 and (t == .l_brace or t == .l_bracket)) {
                const close: @import("token.zig").Tag = if (t == .l_brace) .r_brace else .r_bracket;
                var j: u32 = i + 1;
                var sub_depth: i32 = 1;
                while (j < max_scan and sub_depth > 0) : (j += 1) {
                    const tt = p.peekAt(j);
                    if (tt == .eof) break;
                    if (tt == .l_brace or tt == .l_bracket or tt == .l_paren) sub_depth += 1
                    else if (tt == .r_brace or tt == .r_bracket or tt == .r_paren) sub_depth -= 1;
                    if (sub_depth == 0 and tt == close) {
                        if (p.peekAt(j + 1) == .colon) return true;
                        break;
                    }
                }
            }
            // Track bracket depth
            if (t == .l_paren or t == .l_bracket or t == .l_brace) {
                depth += 1;
                at_param_start = false;
                continue;
            }
            if (t == .r_paren or t == .r_bracket or t == .r_brace) {
                depth -= 1;
                at_param_start = false;
                continue;
            }
            if (depth != 0) {
                continue; // inside nested expression — skip
            }
            // At depth 0: comma resets param-start flag
            if (t == .comma) {
                at_param_start = true;
                continue;
            }
            // At param start: check for typed pattern
            if (at_param_start and t == .identifier and i + 1 < max_scan) {
                const nt = p.peekAt(i + 1);
                if (nt == .colon) return true;
                if (nt == .question and i + 2 < max_scan) {
                    const after_q = p.peekAt(i + 2);
                    if (after_q == .colon or after_q == .r_paren or after_q == .comma) return true;
                }
                // Check for modifier keywords
                const txt = p.tokenText(@intCast(p.tok_i + i));
                if ((std.mem.eql(u8, txt, "public") or std.mem.eql(u8, txt, "private") or
                    std.mem.eql(u8, txt, "protected") or std.mem.eql(u8, txt, "readonly")) and
                    (nt == .identifier or nt == .l_brace or nt == .l_bracket))
                    return true;
            }
            // At param start: `...ident:` — rest param with type in middle of list
            if (at_param_start and t == .ellipsis and i + 2 < max_scan) {
                const after_dot = p.peekAt(i + 1);
                if (after_dot == .identifier and p.peekAt(i + 2) == .colon) return true;
            }
            at_param_start = false;
        }
    }
    // (this : — this parameter
    if (tag == .kw_this and p.peekAt(1) == .colon) return true;
    // (...ident: type) — rest param with type annotation
    if (tag == .ellipsis) {
        const next = p.peekAt(1);
        if (next == .identifier and (p.peekAt(2) == .colon or p.peekAt(2) == .question)) return true;
        // (...{pattern} or ...[pattern] — destructured rest
        if (next == .l_brace or next == .l_bracket) return true;
    }
    return false;
}

/// Parse formal parameters after `(` was already consumed.
fn parseFormalParameters_inner(p: *Parser, _: u32) Error!SubRange {
    const scratch_top = p.scratchLen();

    while (p.peek() != .r_paren and p.peek() != .eof) {
        const param = try parseBindingElement(p);
        try p.scratchPush(param);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_paren);

    const params = p.scratchSlice(scratch_top);
    const range = try p.addSlice(params);
    p.scratchPop(scratch_top);
    return range;
}
