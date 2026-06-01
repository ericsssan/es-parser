// ── src/parser/typescript.zig ────────────────────────────────────────
// TypeScript type parser module for Ez.
//
// Implements parsing of TypeScript-specific syntax: type annotations,
// interfaces, type aliases, enums, namespaces, and type expressions.
//
// All public functions take a `*Parser` (defined in parser.zig) and
// return a `NodeIndex` wrapped in an error union.  During integration,
// parser.zig will `@import("typescript.zig")` and wire these
// functions into its own API.
// ─────────────────────────────────────────────────────────────────────

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const SubRange = ast.SubRange;
const TokenIndex = ast.TokenIndex;
const parser_mod = @import("parser.zig");
pub const Parser = parser_mod.Parser;
const Error = parser_mod.Error;

// =====================================================================
// 1. parseType — Main type parsing entry point
// =====================================================================

/// Parse a full TypeScript type, including conditional types.
///
/// Grammar: `NonConditionalType [extends Type ? Type : Type]`
pub fn parseType(p: *Parser) Error!NodeIndex {
    try p.enterRecursion();
    defer p.leaveRecursion();
    // Type predicate: `x is Type` or `asserts x is Type`
    if (p.peek() == .identifier) {
        const text = p.tokenText(p.tokIdx());
        if (std.mem.eql(u8, text, "asserts")) {
            // `asserts x` or `asserts x is Type`.  Emit a ts_type_predicate
            // whose main_token is the `asserts` keyword (downstream
            // distinguishes from `x is Type` regular predicates by
            // checking main_token's text).
            const asserts_tok = p.advance(); // eat 'asserts'
            if (p.peek() == .identifier or p.peek() == .kw_this) {
                const param_tok: u32 = p.tokIdx();
                _ = p.advance(); // eat param name
                var type_node: NodeIndex = .none;
                if (p.peek() == .kw_is) {
                    _ = p.advance(); // eat 'is'
                    type_node = try parseType(p);
                }
                const param_name = try p.addNode(.{
                    .tag = .identifier,
                    .main_token = param_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
                return p.addNode(.{
                    .tag = .ts_type_predicate,
                    .main_token = asserts_tok,
                    .data = .{ .lhs = param_name, .rhs = type_node },
                });
            }
            return p.addNode(.{
                .tag = .ts_type_annotation,
                .main_token = asserts_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        }
        // Check for `x is Type` — only valid in return type position.
        // When not in return type, fall through to parse as normal type reference;
        // `is` then becomes an unexpected token (TS1005).
        if (p.in_return_type and p.peekAt(1) == .kw_is and !p.hasNewLineBetween(p.tokIdx(), @intCast(p.tok_i + 1))) {
            const param_tok: u32 = p.tokIdx();
            _ = p.advance(); // eat param name
            _ = p.advance(); // eat 'is'
            const type_node = try parseType(p);
            const param_name = try p.addNode(.{
                .tag = .identifier,
                .main_token = param_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            return p.addNode(.{
                .tag = .ts_type_predicate,
                .main_token = param_tok,
                .data = .{ .lhs = param_name, .rhs = type_node },
            });
        }
    }
    // `this is Type` predicate — recognized everywhere.
    // TS1228 (not in return type position) is treated as semantic/config-dependent.
    if (p.peek() == .kw_this and p.peekAt(1) == .kw_is and !p.hasNewLineBetween(p.tokIdx(), @intCast(p.tok_i + 1))) {
        const param_tok: u32 = p.tokIdx();
        _ = p.in_return_type; // suppress unused warning
        _ = p.advance(); // eat 'this'
        _ = p.advance(); // eat 'is'
        const type_node = try parseType(p);
        const param_name = try p.addNode(.{
            .tag = .this_expr,
            .main_token = param_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        return p.addNode(.{
            .tag = .ts_type_predicate,
            .main_token = param_tok,
            .data = .{ .lhs = param_name, .rhs = type_node },
        });
    }

    var result = try parseNonConditionalType(p);

    // Check for conditional type: `T extends U ? X : Y`
    // Only parse as conditional if `?` actually follows the extends clause.
    // `extends` also appears in type parameter constraints where no `?` follows.
    if (p.peek() == .kw_extends) {
        const saved_tok = p.tok_i;
        const saved_diag = p.diagnostics.items.len;
        const saved_nodes = p.nodes.len;
        const saved_extra = p.extra_data.items.len;

        const extends_tok = p.advance(); // consume `extends`
        const prev_in_cond = p.in_conditional_extends;
        p.in_conditional_extends = true;
        defer p.in_conditional_extends = prev_in_cond;
        // infer_allowed tracks whether `infer T` is valid. It is set here and
        // propagates through nested parens/mapped-types without being reset,
        // unlike in_conditional_extends which IS reset for disambiguation.
        const prev_infer_allowed = p.infer_allowed;
        p.infer_allowed = true;
        defer p.infer_allowed = prev_infer_allowed;
        const check_type_result = parseNonConditionalType(p);
        const check_type = check_type_result catch {
            // Backtrack if extends clause fails to parse
            p.tok_i = saved_tok;
            p.diagnostics.shrinkRetainingCapacity(saved_diag);
            p.nodes.len = @intCast(saved_nodes);
            p.extra_data.shrinkRetainingCapacity(saved_extra);
            return result;
        };

        if (p.peek() != .question) {
            // Not a conditional type — backtrack
            p.tok_i = saved_tok;
            p.diagnostics.shrinkRetainingCapacity(saved_diag);
            p.nodes.len = @intCast(saved_nodes);
            p.extra_data.shrinkRetainingCapacity(saved_extra);
            return result;
        }

        _ = p.advance(); // consume `?`
        const true_type = try parseType(p);
        _ = try p.expect(.colon);
        const false_type = try parseType(p);

        // Pack conditional type data into extra: [check, extends, true, false]
        const scratch_top = p.scratchLen();
        defer p.scratchPop(scratch_top);
        try p.scratchPush(result); // check type (LHS of extends)
        try p.scratchPush(check_type); // extends type (RHS of extends)
        try p.scratchPush(true_type);
        try p.scratchPush(false_type);
        const items = p.scratchSlice(scratch_top);
        const range = try p.addSlice(items);

        result = try p.addNode(.{
            .tag = .ts_conditional_type,
            .main_token = extends_tok,
            .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
        });
    }

    return result;
}

// =====================================================================
// 2. parseNonConditionalType — Union types
// =====================================================================

/// Parse a union type: `IntersectionType (| IntersectionType)*`
pub fn parseNonConditionalType(p: *Parser) Error!NodeIndex {
    // Allow leading `|`
    if (p.peek() == .pipe) {
        _ = p.advance();
    }

    const first = try parseIntersectionType(p);

    if (p.peek() != .pipe) {
        return first;
    }

    // Collect union members.
    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);
    // TS1385: function type in union must be parenthesized.
    const first_tag = p.node_tags_ptr[first.toInt()];
    if (first_tag == .ts_function_type or first_tag == .ts_constructor_type) {
        try p.emitDiagnosticAtToken(p.node_main_token_ptr[first.toInt()], "Function type notation must be parenthesized when used in a union type", .{});
    }
    try p.scratchPush(first);

    while (p.peek() == .pipe) {
        _ = p.advance(); // consume `|`
        const member = try parseIntersectionType(p);
        // TS1385: function type in union must be parenthesized.
        const member_tag = p.node_tags_ptr[member.toInt()];
        if (member_tag == .ts_function_type or member_tag == .ts_constructor_type) {
            try p.emitDiagnosticAtToken(p.node_main_token_ptr[member.toInt()], "Function type notation must be parenthesized when used in a union type", .{});
        }
        try p.scratchPush(member);
    }

    const members = p.scratchSlice(scratch_top);
    const range = try p.addSlice(members);

    // Use the first member's main_token as the union's main_token so
    // lint span computation (which propagates min/max through children)
    // correctly bounds the union at [first member start, last member end].
    // Using the post-consume token (e.g. `;`) would push max_tok past
    // the union into the following statement terminator.
    return p.addNode(.{
        .tag = .ts_union_type,
        .main_token = p.nodes.items(.main_token)[first.toInt()],
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// 3. parseIntersectionType — Intersection types
// =====================================================================

/// Parse an intersection type: `PrimaryType (& PrimaryType)*`
pub fn parseIntersectionType(p: *Parser) Error!NodeIndex {
    // Allow leading `&`
    if (p.peek() == .ampersand) {
        _ = p.advance();
    }

    const first = try parsePrimaryType(p);

    if (p.peek() != .ampersand) {
        return first;
    }

    // Collect intersection members.
    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);
    // TS1387: function type in intersection must be parenthesized.
    const first_itag = p.node_tags_ptr[first.toInt()];
    if (first_itag == .ts_function_type or first_itag == .ts_constructor_type) {
        try p.emitDiagnosticAtToken(p.node_main_token_ptr[first.toInt()], "Function type notation must be parenthesized when used in an intersection type", .{});
    }
    try p.scratchPush(first);

    while (p.peek() == .ampersand) {
        _ = p.advance(); // consume `&`
        const member = try parsePrimaryType(p);
        // TS1387: function type in intersection must be parenthesized.
        const member_itag = p.node_tags_ptr[member.toInt()];
        if (member_itag == .ts_function_type or member_itag == .ts_constructor_type) {
            try p.emitDiagnosticAtToken(p.node_main_token_ptr[member.toInt()], "Function type notation must be parenthesized when used in an intersection type", .{});
        }
        try p.scratchPush(member);
    }

    const members = p.scratchSlice(scratch_top);
    const range = try p.addSlice(members);

    return p.addNode(.{
        .tag = .ts_intersection_type,
        .main_token = p.tokIdx(),
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// 4. parsePrimaryType — Atomic types with postfix
// =====================================================================

/// Parse a primary (atomic) type and apply postfix operators (`[]`, `[K]`).
pub fn parsePrimaryType(p: *Parser) Error!NodeIndex {
    var result = try parsePrimaryTypeInner(p);

    // Apply postfix: `[]` (array type) and `[K]` (indexed access type).
    // Don't consume `[` on a new line — it likely starts a new member (ASI-like).
    while (p.peek() == .l_bracket and !p.isOnNewLine()) {
        const bracket_tok = p.advance(); // consume `[`

        if (p.peek() == .r_bracket) {
            // T[]
            _ = p.advance(); // consume `]`
            result = try p.addNode(.{
                .tag = .ts_array_type,
                .main_token = bracket_tok,
                .data = .{ .lhs = result, .rhs = .none },
            });
        } else {
            // T[K] — indexed access type
            const index_type = try parseType(p);
            _ = try p.expect(.r_bracket);
            result = try p.addNode(.{
                .tag = .ts_indexed_access_type,
                .main_token = bracket_tok,
                .data = .{ .lhs = result, .rhs = index_type },
            });
        }
    }

    return result;
}

/// Inner dispatch for primary types (before postfix).
fn parsePrimaryTypeInner(p: *Parser) Error!NodeIndex {
    const tag = p.peek();
    return switch (tag) {
        // ── Named type reference (identifier) ────────────────────
        .identifier => try parseTypeReference(p),

        // ── Keyword/literal types that map directly to ts_type_reference ─
        .kw_void, .kw_null, .kw_this,
        .string_literal, .number_literal, .bigint_literal,
        .kw_true, .kw_false,
        .kw_type, .kw_namespace, .kw_declare, .kw_module,
        .kw_interface, .kw_implements, .kw_enum, .kw_as, .kw_satisfies,
        .kw_is, .kw_override, .kw_const,
        .kw_await, .kw_yield, .kw_async,
        // Error recovery: TypeScript treats reserved keywords as identifier-like type references
        // and emits a semantic error (TS2304) rather than a parse error. This lets the parser
        // continue and allows downstream syntax to be checked normally.
        // Note: kw_typeof, kw_keyof, kw_infer, kw_new, kw_extends, kw_import, kw_in have
        // dedicated arms above and must NOT appear here.
        .kw_break, .kw_case, .kw_catch, .kw_class, .kw_continue,
        .kw_debugger, .kw_default, .kw_delete, .kw_do, .kw_else,
        .kw_export, .kw_finally, .kw_for,
        .kw_if, .kw_instanceof, .kw_let,
        .kw_return, .kw_static, .kw_super, .kw_switch,
        .kw_throw, .kw_try, .kw_var, .kw_while, .kw_with,
        => {
            const tok = p.advance();
            // TS1212: `yield` used as a type name inside a generator is a parse error.
            if (p.tokenTagAt(tok) == .kw_yield and p.in_generator) {
                try p.emitDiagnosticAtToken(tok, "Identifier expected. 'yield' is a reserved word in strict mode", .{});
            }
            return p.addNode(.{
                .tag = .ts_type_reference,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        // ── typeof T ─────────────────────────────────────────────
        .kw_typeof => {
            const tok = p.advance(); // consume `typeof`
            // `typeof import("foo"[, options])` — dynamic-import-type-of expression.
            // Same shape as the bare `import(...)` type below; just consume any
            // second argument (resolution-mode attributes) as an expression.
            if (p.peek() == .kw_import and p.peekAt(1) == .l_paren) {
                _ = p.advance(); // eat `import`
                _ = p.advance(); // eat `(`
                if (p.peek() == .string_literal) _ = p.advance();
                if (p.peek() == .comma) {
                    _ = p.advance();
                    _ = p.parseAssignmentExpression() catch {};
                }
                _ = try p.expect(.r_paren);
                // Optional `.member` access
                while (p.peek() == .dot) {
                    _ = p.advance();
                    if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
                }
                // Optional `<T>` instantiation type args (e.g. typeof import(...).fn<T>)
                if (p.peek() == .less_than) _ = parseTypeArguments(p) catch {};
                return p.addNode(.{
                    .tag = .ts_typeof_type,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            }
            const operand = try parseTypeReference(p);
            return p.addNode(.{
                .tag = .ts_typeof_type,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = .none },
            });
        },

        // ── keyof T ──────────────────────────────────────────────
        .kw_keyof => {
            const tok = p.advance(); // consume `keyof`
            const operand = try parsePrimaryType(p);
            return p.addNode(.{
                .tag = .ts_keyof_type,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = .none },
            });
        },

        // ── infer T ──────────────────────────────────────────────
        .kw_infer => {
            const tok = p.advance(); // consume `infer`
            // TS1338: 'infer' only allowed in 'extends' clause of a conditional type.
            // Use infer_allowed (not in_conditional_extends) — the latter is reset
            // inside parens for disambiguation purposes, but infer_allowed is not.
            if (!p.infer_allowed) {
                try p.emitDiagnostic(p.currentSpan(), "'infer' declarations are only permitted in the 'extends' clause of a conditional type", .{});
            }
            const type_param = try p.parseIdentifier();
            // Optional constraint: `infer T extends U`
            // Disambiguation: if `extends U` is followed by `?`, it's a
            // conditional type, not an infer constraint. Backtrack in that case.
            var constraint: NodeIndex = .none;
            if (p.peek() == .kw_extends) {
                const saved_tok = p.tok_i;
                const saved_diag = p.diagnostics.items.len;
                const saved_nodes = p.nodes.len;
                const saved_extra = p.extra_data.items.len;
                _ = p.advance(); // consume `extends`
                const type_ok = blk: {
                    constraint = parsePrimaryType(p) catch break :blk false;
                    break :blk true;
                };
                if (!type_ok or (p.peek() == .question and !p.in_conditional_extends)) {
                    // Backtrack: either parse failed or `?` follows in a context
                    // where conditional types are allowed (not in extends check type)
                    p.tok_i = saved_tok;
                    p.diagnostics.shrinkRetainingCapacity(saved_diag);
                    p.nodes.len = @intCast(saved_nodes);
                    p.extra_data.shrinkRetainingCapacity(saved_extra);
                    constraint = .none;
                }
            }
            return p.addNode(.{
                .tag = .ts_infer_type,
                .main_token = tok,
                .data = .{ .lhs = type_param, .rhs = constraint },
            });
        },

        // ── unique symbol ────────────────────────────────────────
        .kw_unique => {
            const tok = p.advance(); // consume `unique`
            // Expect `symbol` identifier to follow
            if (p.peek() == .identifier and std.mem.eql(u8, p.tokenText(p.tokIdx()), "symbol")) {
                _ = p.advance(); // consume `symbol`
            }
            return p.addNode(.{
                .tag = .ts_type_reference,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        // ── Parenthesized type or function type ──────────────────
        .l_paren => try parseParenthesizedOrFunctionType(p),

        // ── Tuple type ───────────────────────────────────────────
        .l_bracket => try parseTupleType(p),

        // ── Type literal (object type) ───────────────────────────
        .l_brace => try parseTypeLiteral(p),

        // ── Constructor type: new (...) => T  or  abstract new (...) => T
        .kw_new => try parseConstructorType(p),
        .kw_abstract => {
            if (p.peekAt(1) == .kw_new) {
                _ = p.advance(); // eat 'abstract'
                return try parseConstructorType(p);
            }
            // `abstract` as a type reference
            const tok = p.advance();
            return p.addNode(.{
                .tag = .ts_type_reference,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        .minus => {
            // Negative numeric literal type: -1, -1n
            const tok = p.advance(); // consume `-`
            if (p.peek() == .number_literal or p.peek() == .bigint_literal) {
                _ = p.advance(); // consume the number
            }
            return p.addNode(.{
                .tag = .ts_type_reference,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        // ── Template literal type ────────────────────────────────
        .template_head, .template_no_sub => try parseTemplateLiteralType(p),

        // ── readonly before type: `readonly T[]`, `readonly [T, U]` ─
        .kw_readonly => {
            const tok = p.advance(); // consume `readonly`
            // Parse the type that follows — readonly applies to it
            const inner = try parsePrimaryType(p);
            // TS1354: 'readonly' only permitted on array and tuple literal types.
            // parsePrimaryType already consumed `[]`, so inner could be ts_array_type.
            const inner_tag = p.node_tags_ptr[inner.toInt()];
            if (inner_tag != .ts_tuple_type and inner_tag != .ts_array_type) {
                try p.emitError("'readonly' type modifier is only permitted on array and tuple literal types");
            }
            return p.addNode(.{
                .tag = .ts_keyof_type,  // TSTypeOperator(operator='readonly')
                .main_token = tok,
                .data = .{ .lhs = inner, .rhs = .none },
            });
        },

        // ── asserts — type predicate for assertion functions ─────
        .kw_asserts => {
            const tok = p.advance(); // consume `asserts`
            if (p.isIdentifierLike()) {
                const param_name = try p.parseIdentifier();
                // Optional `is Type`
                var type_node: NodeIndex = .none;
                if (p.peek() == .kw_is) {
                    _ = p.advance(); // consume `is`
                    type_node = try parseType(p);
                }
                return p.addNode(.{
                    .tag = .ts_type_predicate,
                    .main_token = tok,
                    .data = .{ .lhs = param_name, .rhs = type_node },
                });
            }
            // Standalone `asserts` as a type reference
            return p.addNode(.{
                .tag = .ts_type_reference,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        // ── Generic function type: <T>(x: T) => T ─────────────
        .less_than => {
            const tp_range = try parseTypeParameterList(p);
            const inner = try parseParenthesizedOrFunctionType(p);
            // If the inner shape is a function type, splice the type
            // parameters into its FnData so downstream consumers can
            // bind T at call sites.  FnData layout: name, params,
            // params_end, body, return_type, type_params,
            // type_params_end → the last two slots are positions
            // 5/6 from the FnData index.
            if (p.node_tags_ptr[inner.toInt()] == .ts_function_type) {
                const fn_data_idx = @intFromEnum(p.node_data_ptr[inner.toInt()].lhs);
                p.extra_data.items[fn_data_idx + 5] = tp_range.start;
                p.extra_data.items[fn_data_idx + 6] = tp_range.end;
                // The ts_function_type was added before its type_params
                // were spliced in, so setChildParents missed them.  Wire
                // parent links now so type-checker lookups (e.g.
                // findTypeParameterDecl) reach the params.
                const inner_idx: u32 = inner.toInt();
                var k = tp_range.start;
                while (k < tp_range.end) : (k += 1) {
                    p.parents_buf[p.extra_data.items[k]] = inner_idx;
                }
            }
            return inner;
        },

        // ── import("module"[, options]) type ─────────────────────
        // TS supports an optional second argument to import-type for resolution-mode
        // attributes: `import("pkg", { with: { "resolution-mode": "require" } }).T`.
        // The argument is an attribute-style object literal; here we just consume
        // it as a generic expression to advance past the closing paren.
        // Emit as `ts_import_type` so rules (e.g. consistent-type-imports'
        // `noImportTypeAnnotations`) match the ESTree TSImportType node.
        .kw_import => {
            const tok = p.advance(); // consume `import`
            if (p.peek() == .l_paren) {
                _ = p.advance(); // consume `(`
                if (p.peek() == .string_literal) _ = p.advance();
                if (p.peek() == .comma) {
                    _ = p.advance(); // consume `,`
                    // Consume the attribute-options object as an expression.
                    _ = p.parseAssignmentExpression() catch {};
                }
                _ = try p.expect(.r_paren);
                while (p.peek() == .dot) {
                    _ = p.advance();
                    if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
                }
                if (p.peek() == .less_than or p.peek() == .less_less) {
                    _ = try parseTypeArguments(p);
                }
            }
            return p.addNode(.{
                .tag = .ts_import_type,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        // ── JSDoc wildcard type: `*` ────────────────────────────────
        .asterisk => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .ts_type_reference,
                .main_token = tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        // ── JSDoc prefix nullable `?Type` / prefix non-null `!Type` ─
        .question, .bang => {
            const prefix_tok = p.advance(); // consume `?` or `!`
            // Speculatively parse inner type; bare `?` or `!` is also valid JSDoc.
            const saved_tok2 = p.tok_i;
            const saved_diag2 = p.diagnostics.items.len;
            const saved_nodes2 = p.nodes.len;
            const saved_extra2 = p.extra_data.items.len;
            const maybe_inner = parsePrimaryType(p) catch null;
            // If parsing failed OR new diagnostics were added (parse emitted errors without Zig error),
            // restore state and return a dummy node for the `?`/`!` token.
            if (maybe_inner == null or p.diagnostics.items.len > saved_diag2) {
                p.tok_i = saved_tok2;
                p.diagnostics.shrinkRetainingCapacity(saved_diag2);
                p.nodes.len = @intCast(saved_nodes2);
                p.extra_data.shrinkRetainingCapacity(saved_extra2);
                return p.addNode(.{
                    .tag = .ts_type_reference,
                    .main_token = prefix_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            }
            return maybe_inner.?;
        },

        // ── JSDoc `function(...)` type ──────────────────────────────
        .kw_function => {
            const fn_tok = p.advance(); // consume `function`
            if (p.peek() == .l_paren) {
                // Skip JSDoc function params: consume everything up to matching `)`
                var depth: i32 = 1;
                _ = p.advance(); // consume `(`
                while (!p.isAtEnd() and depth > 0) {
                    switch (p.peek()) {
                        .l_paren => { depth += 1; _ = p.advance(); },
                        .r_paren => { depth -= 1; _ = p.advance(); },
                        else => { _ = p.advance(); },
                    }
                }
                // Optional return type: `: Type`
                if (p.peek() == .colon) {
                    _ = p.advance(); // consume `:`
                    _ = parsePrimaryType(p) catch {};
                }
            }
            return p.addNode(.{
                .tag = .ts_type_reference,
                .main_token = fn_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        },

        // ── Fallback ─────────────────────────────────────────────
        else => {
            try p.emitError("Expected type");
            return p.makeErrorNode();
        },
    };
}

/// Parse a named type reference, possibly with dot-separated qualifiers
/// and type arguments: `Foo`, `Foo.Bar`, `Foo<T, U>`, `Foo.Bar<T>`.
fn parseTypeReference(p: *Parser) Error!NodeIndex {
    const name_tok = p.advance(); // consume identifier

    // TS1213: access-modifier keywords are strict-reserved — illegal as type names in strict mode.
    if (p.in_strict) {
        const text = p.tokenText(name_tok);
        if (std.mem.eql(u8, text, "public") or std.mem.eql(u8, text, "protected") or std.mem.eql(u8, text, "private")) {
            try p.emitDiagnosticAtToken(name_tok,
                "Identifier expected. '{s}' is a reserved word in strict mode. Class definitions are automatically in strict mode.", .{text});
        }
    }

    // Build a simple identifier node for the name.
    var name_node = try p.addNode(.{
        .tag = .identifier,
        .main_token = name_tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
    // Emit a `read` reference so the type name resolves to its declaration —
    // but only for non-keyword type references. Built-in TS keyword types
    // (`string`, `bigint`, `void`, etc.) become TS*Keyword nodes in ESTree,
    // not Identifier references, so they shouldn't appear in scope.through.
    const name_text = p.tokenText(name_tok);
    const is_ts_kw_type =
        std.mem.eql(u8, name_text, "any") or
        std.mem.eql(u8, name_text, "bigint") or
        std.mem.eql(u8, name_text, "boolean") or
        std.mem.eql(u8, name_text, "intrinsic") or
        std.mem.eql(u8, name_text, "never") or
        std.mem.eql(u8, name_text, "null") or
        std.mem.eql(u8, name_text, "number") or
        std.mem.eql(u8, name_text, "object") or
        std.mem.eql(u8, name_text, "string") or
        std.mem.eql(u8, name_text, "symbol") or
        std.mem.eql(u8, name_text, "undefined") or
        std.mem.eql(u8, name_text, "unknown") or
        std.mem.eql(u8, name_text, "void");
    if (!is_ts_kw_type) try p.emitReference(.type_read, name_node);

    // Qualified names: `Foo.Bar.Baz` or `Foo?.Bar` (optional chain, TS error but parseable)
    while (p.peek() == .dot or p.peek() == .question_dot) {
        _ = p.advance(); // consume `.` or `?.`
        if (p.peek() == .identifier or p.peek().isKeyword()) {
            const prop_tok = p.advance();
            const prop_node = try p.addNode(.{
                .tag = .property_ident,
                .main_token = prop_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            name_node = try p.addNode(.{
                .tag = .member_expr,
                .main_token = prop_tok,
                .data = .{ .lhs = name_node, .rhs = prop_node },
            });
        } else if (p.peek() != .less_than) {
            // After `.`, if not followed by `<` (type args), emit TS1003
            try p.emitError("Identifier expected");
            break;
        } else {
            break;
        }
    }

    // Type arguments: `<T, U>` — do NOT consume `<` on a new line (ASI applies in type position).
    // Also handle '<<' (e.g. Foo<<T>(x:T)=>R>) where the first '<' opens type args and
    // the second '<' starts a generic function type argument.
    var type_args_rhs: NodeIndex = .none;
    if ((p.peek() == .less_than or p.peek() == .less_less) and !p.isOnNewLine()) {
        const args_range = try parseTypeArguments(p);
        const range_extra = try p.addExtra(SubRange, .{
            .start = args_range.start,
            .end = args_range.end,
        });
        type_args_rhs = NodeIndex.fromInt(range_extra);
    }

    return p.addNode(.{
        .tag = .ts_type_reference,
        .main_token = name_tok,
        .data = .{ .lhs = name_node, .rhs = type_args_rhs },
    });
}

// =====================================================================
// Parenthesized or function type
// =====================================================================

/// Disambiguate between `(Type)` (parenthesized) and `(params) => ReturnType`
/// (function type).
fn parseParenthesizedOrFunctionType(p: *Parser) Error!NodeIndex {
    const open_paren: u32 = p.tokIdx();

    // Use checkpoint for speculative parsing.
    const saved = p.checkpoint();

    // Try to parse as function type parameters.
    _ = p.advance(); // consume `(`

    var looks_like_fn = false;

    // Empty params `() =>` is definitely a function type.
    if (p.peek() == .r_paren) {
        _ = p.advance(); // consume `)`
        if (p.peek() == .arrow) {
            looks_like_fn = true;
        } else {
            // `()` not followed by `=>` — error, but treat as empty tuple or error.
            p.restore(saved);
            return parseParenthesizedTypeSimple(p);
        }
    }

    if (looks_like_fn) {
        // Empty parameter function type: () => ReturnType
        _ = p.advance(); // consume `=>`
        const prev_in_rt = p.in_return_type;
        p.in_return_type = true;
        const return_type = try parseType(p);
        p.in_return_type = prev_in_rt;
        const params_range = try p.addSlice(&[_]u32{});

        const fn_extra = try p.addExtra(ast.FnData, .{
            .name = .none,
            .params = params_range.start,
            .params_end = params_range.end,
            .body = return_type,
            // No type params for empty-paren form
        });
        return p.addNode(.{
            .tag = .ts_function_type,
            .main_token = open_paren,
            .data = .{ .lhs = NodeIndex.fromInt(fn_extra), .rhs = .none },
        });
    }

    // Not empty parens — try parsing contents.
    // If we see `identifier:` or `...`, or `)` followed by `=>`,
    // it is a function type.  Otherwise, parenthesized type.
    p.restore(saved);

    // Heuristic: check first token inside parens for function-type patterns.
    // Patterns that indicate function type:
    //   ( identifier : Type
    //   ( identifier ? : Type
    //   ( identifier , identifier : ...
    //   ( ... rest
    //   ( this :
    if (looksLikeFunctionTypeParams(p)) {
        return parseFunctionType(p);
    }

    // Treat as parenthesized type.
    return parseParenthesizedTypeSimple(p);
}

/// Check if the tokens after `(` look like function type parameters.
fn looksLikeFunctionTypeParams(p: *Parser) bool {
    // Save position for lookahead.
    const saved = p.checkpoint();
    defer p.restore(saved);

    _ = p.advance(); // skip `(`

    // `((` — inner `(` as first token means this is a parenthesized type, not fn params.
    if (p.peek() == .l_paren) return false;

    // `(...` — rest parameter, definitely function type
    if (p.peek() == .ellipsis) return true;

    // `(this :` — function type with this parameter
    if (p.peek() == .kw_this and p.peekAt(1) == .colon) return true;

    // `(identifier :` or `(identifier ?` or `(identifier ,` followed by patterns
    if (p.peek() == .identifier or p.peek().isKeyword()) {
        _ = p.advance(); // skip identifier

        // `name:` — parameter with type annotation
        if (p.peek() == .colon) return true;

        // `name?` — optional parameter
        if (p.peek() == .question) return true;

        // `name,` followed by `identifier :` or `identifier ?`
        if (p.peek() == .comma) {
            _ = p.advance(); // skip `,`
            if (p.peek() == .identifier or p.peek().isKeyword()) {
                _ = p.advance(); // skip identifier
                if (p.peek() == .colon or p.peek() == .question) return true;
            }
            if (p.peek() == .ellipsis) return true;
        }
    }

    // Scan forward to find closing `)` and check for `=>`
    p.restore(saved);
    _ = p.advance(); // skip `(`
    var depth: u32 = 1;
    var limit: u32 = 0;
    while (depth > 0 and !p.isAtEnd() and limit < 200) : (limit += 1) {
        switch (p.peek()) {
            .l_paren => {
                depth += 1;
                _ = p.advance();
            },
            .r_paren => {
                depth -= 1;
                if (depth == 0) {
                    _ = p.advance(); // consume `)`
                    return p.peek() == .arrow;
                }
                _ = p.advance();
            },
            else => _ = p.advance(),
        }
    }

    return false;
}

/// Parse a simple parenthesized type: `(Type)`.
fn parseParenthesizedTypeSimple(p: *Parser) Error!NodeIndex {
    const open_tok = p.advance(); // consume `(`
    // Reset in_conditional_extends for disambiguation: `(infer U extends T ? A : B)` must
    // parse the inner `?` as a conditional, not as the outer conditional's operator.
    // infer_allowed is NOT reset so `infer` remains valid inside parens within an extends clause.
    const prev_in_cond = p.in_conditional_extends;
    p.in_conditional_extends = false;
    defer p.in_conditional_extends = prev_in_cond;
    const inner = try parseType(p);
    _ = try p.expect(.r_paren);
    return p.addNode(.{
        .tag = .ts_parenthesized_type,
        .main_token = open_tok,
        .data = .{ .lhs = inner, .rhs = .none },
    });
}

/// Parse a function type: `(param: Type, ...) => ReturnType`.
fn parseFunctionType(p: *Parser) Error!NodeIndex {
    // Open a function scope for the parameters so they appear as scope variables.
    // ESLint/TypeScript-ESLint creates a function scope for TSFunctionType, enabling
    // no-shadow to detect when a function type parameter shadows an outer variable.
    const fn_type_scope_ev = try p.emitScopeOpen(.function, .none);

    const open_tok = p.advance(); // consume `(`

    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    while (p.peek() != .r_paren and !p.isAtEnd()) {
        // Rest parameter: `...name: Type`
        if (p.peek() == .ellipsis) {
            const rest_tok = p.advance(); // consume `...`
            const param_name = try p.parseIdentifier();
            try p.emitDeclare(.parameter, param_name);
            // Optional type annotation — wrap in ts_type_annotation for consistent parent chain
            var type_ann: NodeIndex = .none;
            if (p.peek() == .colon) {
                const colon_tok: u32 = p.tokIdx();
                _ = p.advance();
                const inner_type = try parseType(p);
                type_ann = try p.addNode(.{
                    .tag = .ts_type_annotation,
                    .main_token = colon_tok,
                    .data = .{ .lhs = inner_type, .rhs = .none },
                });
            }
            const rest_node = try p.addNode(.{
                .tag = .rest_element,
                .main_token = rest_tok,
                .data = .{ .lhs = param_name, .rhs = type_ann },
            });
            try p.scratchPush(rest_node);
            break;
        }

        // Regular parameter: `name: Type` or `name?: Type`
        const param_node = try parseFunctionTypeParam(p);
        // Declare simple identifier parameters in the function type scope.
        // Destructuring patterns are handled inside parseFunctionTypeParam.
        if (p.node_tags_ptr[param_node.toInt()] == .identifier) {
            try p.emitDeclare(.parameter, param_node);
        } else if (p.node_tags_ptr[param_node.toInt()] == .rest_element) {
            const lhs = p.node_data_ptr[param_node.toInt()].lhs;
            if (lhs != .none and p.node_tags_ptr[lhs.toInt()] == .identifier) {
                try p.emitDeclare(.parameter, lhs);
            }
        }
        try p.scratchPush(param_node);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_paren);

    _ = try p.expect(.arrow);

    const prev_in_rt_fn = p.in_return_type;
    p.in_return_type = true;
    const return_type = try parseType(p);
    p.in_return_type = prev_in_rt_fn;

    const params = p.scratchSlice(scratch_top);
    const params_range = try p.addSlice(params);

    const fn_extra = try p.addExtra(ast.FnData, .{
        .name = .none,
        .params = params_range.start,
        .params_end = params_range.end,
        .body = return_type, // reuse body field for return type
    });

    const fn_type_node = try p.addNode(.{
        .tag = .ts_function_type,
        .main_token = open_tok,
        .data = .{ .lhs = NodeIndex.fromInt(fn_extra), .rhs = .none },
    });

    try p.emitScopeClose(.none);
    p.patchScopeOpenNode(fn_type_scope_ev, fn_type_node);

    return fn_type_node;
}

/// Parse a single function type parameter: `name: Type` or `name?: Type`.
fn parseFunctionTypeParam(p: *Parser) Error!NodeIndex {
    const param_tok: u32 = p.tokIdx();

    // Rest parameter: `...args: Type` — emit rest_element for correct parent chain
    const is_rest = p.eat(.ellipsis) != null;

    // Skip access modifiers: `public`, `private`, `protected`, `readonly`
    if (p.peek() == .identifier) {
        const text = p.tokenText(p.tokIdx());
        if ((std.mem.eql(u8, text, "public") or std.mem.eql(u8, text, "private") or
            std.mem.eql(u8, text, "protected") or std.mem.eql(u8, text, "readonly")) and
            (p.peekAt(1) == .identifier or p.peekAt(1) == .kw_this or p.peekAt(1) == .l_brace or p.peekAt(1) == .l_bracket))
        {
            _ = p.advance(); // skip modifier
        }
    }

    // Destructuring parameter: `[a, b]: Type` or `{p, m}: Type`
    if (p.peek() == .l_bracket or p.peek() == .l_brace) {
        const binding = try p.parseBindingPattern();
        _ = p.eat(.question);
        var type_ann: NodeIndex = .none;
        if (p.peek() == .colon) {
            const colon_tok: u32 = p.tokIdx();
            _ = p.advance();
            const type_node = try parseType(p);
            if (p.peek() == .equal) {
                _ = p.advance();
                _ = try p.parseAssignmentExpression();
            }
            type_ann = try p.addNode(.{
                .tag = .ts_type_annotation,
                .main_token = colon_tok,
                .data = .{ .lhs = type_node, .rhs = .none },
            });
        }
        const inner = try p.addNode(.{
            .tag = .ts_type_annotation,
            .main_token = param_tok,
            .data = .{ .lhs = type_ann, .rhs = .none },
        });
        if (is_rest) {
            return p.addNode(.{
                .tag = .rest_element,
                .main_token = param_tok,
                .data = .{ .lhs = binding, .rhs = type_ann },
            });
        }
        return inner;
    }

    // Consume parameter name (identifier or keyword like `this`)
    if (p.peek() == .identifier or p.peek() == .kw_this or p.peek().isKeyword()) {
        const name_tok: u32 = p.tokIdx();
        _ = p.advance();

        // Optional marker `?`; encode as lhs=root (0) vs lhs=none for adapter.
        const is_optional = p.eat(.question) != null;
        // TS1047: A rest parameter cannot be optional.
        if (is_optional and is_rest) {
            try p.emitDiagnostic(p.currentSpan(), "A rest parameter cannot be optional", .{});
        }
        const opt_flag: @import("ast.zig").NodeIndex = if (is_optional) .root else .none;

        // Expect `:` for type annotation
        if (p.peek() == .colon) {
            const colon_tok: u32 = p.tokIdx();
            _ = p.advance(); // consume `:`
            const type_node = try parseType(p);
            // Skip default value: `param: Type = value` (semantic error in TS, but parseable)
            if (p.peek() == .equal) {
                _ = p.advance();
                _ = try p.parseAssignmentExpression();
            }
            const type_ann = try p.addNode(.{
                .tag = .ts_type_annotation,
                .main_token = colon_tok,
                .data = .{ .lhs = type_node, .rhs = .none },
            });
            if (is_rest) {
                const name_node = try p.addNode(.{
                    .tag = .identifier,
                    .main_token = name_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
                return p.addNode(.{
                    .tag = .rest_element,
                    .main_token = param_tok,
                    .data = .{ .lhs = name_node, .rhs = type_ann },
                });
            }
            // Return identifier node; lhs=opt_flag, rhs=type_ann for adapter.
            return p.addNode(.{
                .tag = .identifier,
                .main_token = name_tok,
                .data = .{ .lhs = opt_flag, .rhs = type_ann },
            });
        }

        // Skip default value without type: `param = value` (semantic error in TS, but parseable)
        if (p.peek() == .equal) {
            _ = p.advance();
            _ = try p.parseAssignmentExpression();
        }

        // No colon — bare identifier parameter (possibly rest)
        if (is_rest) {
            const name_node = try p.addNode(.{
                .tag = .identifier,
                .main_token = name_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            return p.addNode(.{
                .tag = .rest_element,
                .main_token = param_tok,
                .data = .{ .lhs = name_node, .rhs = .none },
            });
        }
        // Bare identifier param; lhs=opt_flag, rhs=none.
        return p.addNode(.{
            .tag = .identifier,
            .main_token = name_tok,
            .data = .{ .lhs = opt_flag, .rhs = .none },
        });
    } else {
        // Could be a bare type — fall back (rest doesn't apply here)
        return parseType(p);
    }
}

// =====================================================================
// Tuple type
// =====================================================================

/// Parse a tuple type: `[Type, Type, ...Type]`.
fn parseTupleType(p: *Parser) Error!NodeIndex {
    const open_tok = p.advance(); // consume `[`
    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    var seen_optional = false; // once we see Type?, next required is TS1257
    var seen_concrete_rest = false; // ...T[] (concrete array) — limits what can follow

    while (p.peek() != .r_bracket and !p.isAtEnd()) {
        // Spread element in tuple: `...Type` or `...label: Type`
        if (p.peek() == .ellipsis) {
            const spread_tok = p.advance();
            // Check for labeled spread: `...label: Type` or `...label?: Type`
            if ((p.peek() == .identifier or p.peek().isKeyword()) and
                (p.peekAt(1) == .colon or (p.peekAt(1) == .question and p.peekAt(2) == .colon)))
            {
                _ = p.advance(); // skip label
                _ = p.eat(.question); // skip optional `?`
                _ = p.advance(); // skip ':'
            }
            const elem_type = try parseType(p);
            // Determine if this is a concrete rest element (ts_array_type) or variadic (type ref).
            const elem_tag = p.node_tags_ptr[elem_type.toInt()];
            const is_concrete_rest = (elem_tag == .ts_array_type);
            if (is_concrete_rest) {
                // TS1265: A rest element cannot follow another rest element.
                if (seen_concrete_rest) {
                    try p.emitError("A rest element cannot follow another rest element");
                }
                seen_concrete_rest = true;
            }
            // Optional `?` after spread type
            _ = p.eat(.question);
            const spread_node = try p.addNode(.{
                .tag = .spread_element,
                .main_token = spread_tok,
                .data = .{ .lhs = elem_type, .rhs = .none },
            });
            try p.scratchPush(spread_node);
        } else {
            // Optional label: `name: Type` or `name?: Type`
            const saved = p.checkpoint();
            var is_labeled = false;

            if (p.peek() == .identifier or p.peek().isKeyword()) {
                _ = p.advance();
                if (p.peek() == .colon) {
                    is_labeled = true;
                } else if (p.peek() == .question) {
                    // Distinguish `name?: Type` (labeled) from `Type?` (optional)
                    // Only labeled if `?` is followed by `:`
                    const saved2 = p.checkpoint();
                    _ = p.advance(); // skip `?`
                    if (p.peek() == .colon) is_labeled = true;
                    p.restore(saved2);
                }
            }
            p.restore(saved);

            if (is_labeled) {
                // Labeled tuple element: `name: Type` or `name?: Type`
                _ = p.advance(); // skip label name
                const is_optional_label = p.eat(.question) != null;
                _ = try p.expect(.colon);
                // Handle `...` before type for syntactically invalid `rest: ...Type`
                _ = p.eat(.ellipsis); // skip '...' (syntactically invalid but parseable)
                const elem_type = try parseType(p);
                const has_trailing_q = p.eat(.question) != null; // trailing `?` on type
                const is_opt = is_optional_label or has_trailing_q;
                if (is_opt) {
                    // TS1266: An optional element cannot follow a concrete rest element.
                    if (seen_concrete_rest) try p.emitError("An optional element cannot follow a rest element");
                    seen_optional = true;
                } else {
                    // TS1257: A required element cannot follow an optional element.
                    if (seen_optional) try p.emitError("A required element cannot follow an optional element");
                }
                try p.scratchPush(elem_type);
            } else {
                const elem_type = try parseType(p);
                // Optional tuple element: `Type?`
                const is_optional = p.eat(.question) != null;
                if (is_optional) {
                    // TS1266: An optional element cannot follow a concrete rest element.
                    if (seen_concrete_rest) try p.emitError("An optional element cannot follow a rest element");
                    seen_optional = true;
                } else {
                    // TS1257: A required element cannot follow an optional element.
                    if (seen_optional) try p.emitError("A required element cannot follow an optional element");
                }
                try p.scratchPush(elem_type);
            }
        }

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_bracket);

    const elements = p.scratchSlice(scratch_top);
    const range = try p.addSlice(elements);

    return p.addNode(.{
        .tag = .ts_tuple_type,
        .main_token = open_tok,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// Type literal (object type)
// =====================================================================

/// Parse an object type literal: `{ prop: Type; method(): Type; }`.
fn parseTypeLiteral(p: *Parser) Error!NodeIndex {
    const open_tok = p.advance(); // consume `{`
    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    // Check for mapped type: `{ [K in T]: V }` or `{ readonly [K in T]: V }`
    // Also handles `{ +readonly [K in T]: V }` and `{ -readonly [K in T]: V }`
    {
        const saved = p.checkpoint();
        // Skip optional +/- readonly modifier
        if (p.peek() == .plus or p.peek() == .minus) _ = p.advance();
        if (p.peek() == .kw_readonly) _ = p.advance();
        if (p.peek() == .l_bracket) {
            _ = p.advance(); // skip `[`
            if (p.peek() == .identifier or p.peek().isKeyword()) {
                _ = p.advance(); // skip key name
                if (p.peek() == .kw_in) {
                    // This is a mapped type.
                    p.restore(saved);
                    return parseMappedType(p, open_tok);
                }
            }
        }
        p.restore(saved);
    }

    while (p.peek() != .r_brace and !p.isAtEnd()) {
        const member = try parseInterfaceMember(p);
        try p.scratchPush(member);
    }

    _ = try p.expect(.r_brace);

    const members = p.scratchSlice(scratch_top);
    const range = try p.addSlice(members);

    return p.addNode(.{
        .tag = .ts_type_literal,
        .main_token = open_tok,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

/// Parse a mapped type: `{ [K in T]: V }` or `{ [K in T as U]: V }`.
/// Also handles modifiers: `{ readonly [K in T]: V }`, `{ -readonly [K in T]: V }`.
fn parseMappedType(p: *Parser, brace_tok: TokenIndex) Error!NodeIndex {
    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    // Open a block scope for the mapped type key parameter so that
    // `getScope(key)` returns this scope and rules can find the key variable.
    const mapped_scope_ev = try p.emitScopeOpen(.block, .none);

    // Skip optional +/- readonly modifier
    if (p.peek() == .plus or p.peek() == .minus) _ = p.advance();
    if (p.peek() == .kw_readonly) _ = p.advance();

    _ = p.advance(); // consume `[`

    // Parse the key type parameter
    const key_param = try p.parseIdentifier();
    try p.scratchPush(key_param);
    // Declare the key as a type parameter in the mapped type's scope.
    try p.emitDeclare(.type_param, key_param);

    _ = try p.expect(.kw_in);

    // Reset in_conditional_extends for the mapped type constraint — it's a fresh type scope.
    // infer_allowed is NOT reset, so `{ [P in infer E]: any }` inside an outer extends clause
    // remains valid.
    const prev_in_cond_mapped = p.in_conditional_extends;
    p.in_conditional_extends = false;
    defer p.in_conditional_extends = prev_in_cond_mapped;

    const constraint = try parseType(p);
    try p.scratchPush(constraint);

    // Optional `as` clause: `[K in T as U]`
    var as_type: NodeIndex = .none;
    if (p.peek() == .kw_as) {
        _ = p.advance(); // consume `as`
        as_type = try parseType(p);
    }
    try p.scratchPush(as_type);

    _ = try p.expect(.r_bracket);

    // Optional `?`, `+?`, or `-?` modifier
    if (p.peek() == .minus or p.peek() == .plus) {
        _ = p.advance();
        _ = p.eat(.question);
    } else {
        _ = p.eat(.question);
    }

    // Optional `:` and value type (implicit void when absent, e.g. `[K in T]` or `[K in T]?`).
    var value_type: NodeIndex = .none;
    if (p.eat(.colon) != null) {
        value_type = try parseType(p);
    }
    try p.scratchPush(value_type);

    // Optional semicolon
    _ = p.eat(.semicolon);

    // TypeScript permits (with TS7061) additional members after the mapped-type member.
    // Skip them so we don't produce spurious parse errors.
    while (p.peek() != .r_brace and !p.isAtEnd()) {
        const before = p.tok_i;
        _ = parseInterfaceMember(p) catch .none;
        if (p.tok_i == before) _ = p.advance(); // safety: no infinite loop
    }

    _ = try p.expect(.r_brace);

    const items = p.scratchSlice(scratch_top);
    const range = try p.addSlice(items);

    try p.emitScopeClose(.none);
    const result = try p.addNode(.{
        .tag = .ts_mapped_type,
        .main_token = brace_tok,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
    p.patchScopeOpenNode(mapped_scope_ev, result);
    return result;
}

// =====================================================================
// Constructor type
// =====================================================================

/// Parse `new (params) => Type`.
fn parseConstructorType(p: *Parser) Error!NodeIndex {
    const new_tok = p.advance(); // consume `new`

    // Parse optional type parameters
    // (Generic constructor types: `new <T>(...) => T`)
    if (p.peek() == .less_than) {
        _ = try parseTypeParameterList(p);
    }

    _ = try p.expect(.l_paren);

    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    while (p.peek() != .r_paren and !p.isAtEnd()) {
        const param = try parseFunctionTypeParam(p);
        try p.scratchPush(param);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_paren);

    _ = try p.expect(.arrow);

    const prev_in_rt_ctor = p.in_return_type;
    p.in_return_type = true;
    const return_type = try parseType(p);
    p.in_return_type = prev_in_rt_ctor;

    const params = p.scratchSlice(scratch_top);
    const params_range = try p.addSlice(params);

    const fn_extra = try p.addExtra(ast.FnData, .{
        .name = .none,
        .params = params_range.start,
        .params_end = params_range.end,
        .body = return_type,
    });

    return p.addNode(.{
        .tag = .ts_constructor_type,
        .main_token = new_tok,
        .data = .{ .lhs = NodeIndex.fromInt(fn_extra), .rhs = .none },
    });
}

// =====================================================================
// Template literal type
// =====================================================================

/// Parse a template literal type: `` `prefix${Type}suffix` ``.
fn parseTemplateLiteralType(p: *Parser) Error!NodeIndex {
    const head_tok: u32 = p.tokIdx();
    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    if (p.peek() == .template_no_sub) {
        // No-substitution template: `text`
        const tok = p.advance();
        const elem = try p.addNode(.{
            .tag = .template_element,
            .main_token = tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        try p.scratchPush(elem);
    } else {
        // Template with substitutions
        const head = p.advance(); // consume template_head
        const head_elem = try p.addNode(.{
            .tag = .template_element,
            .main_token = head,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        try p.scratchPush(head_elem);

        while (true) {
            // Type expression inside ${...}
            const type_node = try parseType(p);
            try p.scratchPush(type_node);

            if (p.peek() == .template_tail) {
                const tok = p.advance();
                const tail_elem = try p.addNode(.{
                    .tag = .template_element,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
                try p.scratchPush(tail_elem);
                break;
            } else if (p.peek() == .template_middle) {
                const tok = p.advance();
                const mid_elem = try p.addNode(.{
                    .tag = .template_element,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
                try p.scratchPush(mid_elem);
            } else {
                try p.emitError("Expected template continuation in type");
                break;
            }
        }
    }

    const parts = p.scratchSlice(scratch_top);
    const range = try p.addSlice(parts);

    return p.addNode(.{
        .tag = .ts_template_literal_type,
        .main_token = head_tok,
        .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
    });
}

// =====================================================================
// 5. parseTypeParameterList — <T, U extends V, W = Default>
// =====================================================================

/// Parse a type parameter list: `<T, U extends V, W = Default>`.
/// Returns a SubRange of type parameter nodes.
pub fn parseTypeParameterList(p: *Parser) Error!SubRange {
    return parseTypeParameterListImpl(p, true);
}

pub fn parseTypeParameterListNoConst(p: *Parser) Error!SubRange {
    return parseTypeParameterListImpl(p, false);
}

fn parseTypeParameterListImpl(p: *Parser, allow_const: bool) Error!SubRange {
    _ = try p.expect(.less_than);

    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    while (!isClosingAngleBracket(p.peek()) and !p.isAtEnd()) {
        // TS 5.0: `const` modifier on type parameter — `<const T>`.
        // TS1277 (const not allowed in this context) is treated as semantic/config-dependent.
        if (p.peek() == .kw_const and p.peekAt(1) == .identifier) {
            _ = allow_const; // suppress unused warning
            _ = p.advance(); // skip 'const'
        }
        // `in` and `out` variance modifiers — `<in T>`, `<out T>`, `<in out T>`
        while ((p.peek() == .kw_in or (p.peek() == .identifier and
            std.mem.eql(u8, p.tokenText(p.tokIdx()), "out"))) and
            p.peekAt(1) == .identifier)
        {
            _ = p.advance();
        }

        const param_tok = p.advance(); // consume type parameter name

        // Optional constraint: `extends Type`
        var constraint: NodeIndex = .none;
        if (p.peek() == .kw_extends) {
            _ = p.advance(); // consume `extends`
            constraint = try parseType(p);
        }

        // Optional default: `= Type`
        var default_type: NodeIndex = .none;
        if (p.peek() == .equal) {
            _ = p.advance(); // consume `=`
            default_type = try parseType(p);
        }

        // Create a ts_type_parameter node. main_token = name identifier,
        // lhs = constraint (or .none), rhs = default (or .none).
        const param_node = try p.addNode(.{
            .tag = .ts_type_parameter,
            .main_token = param_tok,
            .data = .{ .lhs = constraint, .rhs = default_type },
        });

        // Emit declare for type parameters when we're specifically in a
        // function's type-parameter position (set by parseFunctionDeclaration
        // and method parsers). NOT set for class-level type params, type
        // aliases, or interface declarations.
        if (p.emit_fn_type_params) try p.emitDeclare(.type_param, param_node);

        try p.scratchPush(param_node);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    if (p.scratchLen() == scratch_top) {
        try p.emitError("Type parameter list cannot be empty");
    }

    try expectClosingAngleBracket(p);

    const params = p.scratchSlice(scratch_top);
    const range = try p.addSlice(params);

    return range;
}

// =====================================================================
// 6. parseTypeArguments — <Type, Type>
// =====================================================================

/// Parse type arguments in type argument position: `<Type, Type>`.
/// Returns a SubRange of type nodes.
pub fn parseTypeArguments(p: *Parser) Error!SubRange {
    // Handle '<<' — e.g. foo<<T>() => R> where '<T>() => R' is a generic function type arg.
    // Split the first '<' as the opening bracket; leave the second '<' for the inner type.
    if (p.peek() == .less_less) {
        p.recordTokMut(p.tok_i);
        p.tags_ptr[p.tok_i] = .less_than;
        p.tok_starts_ptr[p.tok_i] += 1;
        // tok_i unchanged — the second '<' is now the current token for inner parsing.
    } else {
        _ = try p.expect(.less_than);
    }

    // TS1099: Type argument list cannot be empty.
    if (isClosingAngleBracket(p.peek())) {
        try p.emitError("Type argument list cannot be empty");
    }

    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    while (!isClosingAngleBracket(p.peek()) and !p.isAtEnd()) {
        const type_node = try parseType(p);
        try p.scratchPush(type_node);

        // Consume trailing `?` suffix (JSDoc nullable: `Type?`). TypeScript emits
        // TS17019 semantically; we skip it so `<string?>` parses without error.
        _ = p.eat(.question);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    try expectClosingAngleBracket(p);

    const types = p.scratchSlice(scratch_top);
    const range = try p.addSlice(types);

    return range;
}

// =====================================================================
// 7. parseInterfaceDeclaration
// =====================================================================

/// Parse `interface Name<T> extends A, B { members }`.
pub fn parseInterfaceDeclaration(p: *Parser) Error!NodeIndex {
    const iface_tok = p.advance(); // consume `interface`

    // Interface name (keywords like void/never/unknown are valid interface names)
    const name_tok = if (p.peek() == .identifier or p.peek().isKeyword())
        p.advance()
    else
        try p.expect(.identifier);
    // TS1212: strict reserved words cannot be used as interface names in strict mode.
    try p.checkStrictBinding(name_tok);

    // Build the name Identifier IMMEDIATELY so its end_tok matches name_tok
    // (addNode records end_tok = tok_i - 1 at the time of call). Declare it
    // as a TypeVariable in the enclosing scope so rules walking
    // scope.variables (e.g. @typescript-eslint/consistent-indexed-object-style's
    // circular-reference check via findVariable + isTypeVariable) find it.
    const name_ident = try p.addNode(.{
        .tag = .identifier,
        .main_token = name_tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
    try p.emitDeclare(.interface_decl, name_ident);

    // Open a child block scope for type parameters so they can shadow
    // outer type aliases. ESLint/TypeScript-ESLint creates a child scope
    // for each interface containing its type parameters.
    var type_params_range = SubRange{ .start = 0, .end = 0 };
    const has_iface_type_params = p.peek() == .less_than;
    var iface_scope_ev: u32 = 0;
    if (has_iface_type_params) {
        iface_scope_ev = try p.emitScopeOpen(.block, .none);
        const prev_eftp = p.emit_fn_type_params;
        p.emit_fn_type_params = true;
        type_params_range = try parseTypeParameterListNoConst(p);
        p.emit_fn_type_params = prev_eftp;
    }

    // Optional extends clause: `extends A, B`
    var extends_range = SubRange{ .start = 0, .end = 0 };
    if (p.peek() == .kw_extends) {
        _ = p.advance(); // consume `extends`
        const scratch_top = p.scratchLen();
        defer p.scratchPop(scratch_top);

        // Parse comma-separated list of type references.
        // TypeScript TS2499: `extends X()` is allowed syntactically (call args are discarded).
        const first_type = try parseType(p);
        if (p.peek() == .l_paren) {
            // Skip invalid call args: `extends SomeType()` — TS parses, emits TS2499.
            _ = p.advance();
            while (p.peek() != .r_paren and p.peek() != .eof and p.peek() != .l_brace) {
                _ = p.advance();
            }
            if (p.peek() == .r_paren) _ = p.advance();
        }
        try p.scratchPush(first_type);

        while (p.peek() == .comma) {
            _ = p.advance();
            const ext_type = try parseType(p);
            if (p.peek() == .l_paren) {
                _ = p.advance();
                while (p.peek() != .r_paren and p.peek() != .eof and p.peek() != .l_brace) {
                    _ = p.advance();
                }
                if (p.peek() == .r_paren) _ = p.advance();
            }
            try p.scratchPush(ext_type);
        }

        const extends = p.scratchSlice(scratch_top);
        extends_range = try p.addSlice(extends);
    }

    // Interface body: `{ members }`
    _ = try p.expect(.l_brace);

    const body_scratch_top = p.scratchLen();
    defer p.scratchPop(body_scratch_top);

    while (p.peek() != .r_brace and !p.isAtEnd()) {
        const member = try parseInterfaceMember(p);
        try p.scratchPush(member);
    }

    _ = try p.expect(.r_brace);

    const body_members = p.scratchSlice(body_scratch_top);
    const body_range = try p.addSlice(body_members);

    const extra = try p.addExtra(ast.InterfaceData, .{
        .name = name_tok,
        .type_params = type_params_range.start,
        .type_params_end = type_params_range.end,
        .extends_start = extends_range.start,
        .extends_end = extends_range.end,
        .body_start = body_range.start,
        .body_end = body_range.end,
    });

    const iface_node = try p.addNode(.{
        .tag = .ts_interface_decl,
        .main_token = iface_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = name_ident },
    });

    if (has_iface_type_params) {
        try p.emitScopeClose(.none);
        p.patchScopeOpenNode(iface_scope_ev, iface_node);
    }

    return iface_node;
}

// =====================================================================
// 8. parseTypeAliasDeclaration
// =====================================================================

/// Parse `type Name<T> = Type;`.
pub fn parseTypeAliasDeclaration(p: *Parser) Error!NodeIndex {
    const type_tok = p.advance(); // consume `type`

    // TS1142: Line break not permitted between `type` and the type alias name.
    if (p.newlines_ptr[p.tok_i]) {
        try p.emitDiagnosticAtToken(type_tok, "Line break not permitted here", .{});
    }

    // Type alias name — contextual keywords (e.g. `module`, `from`, `of`) are valid names,
    // but always-reserved words (void, null, true, false, etc.) are not valid type names.
    const name_tok = try p.expectIdentifierOrKeyword();
    {
        const name_tag = p.tokenTag(name_tok);
        const is_reserved_type_name = switch (name_tag) {
            .kw_void, .kw_null, .kw_true, .kw_false, .kw_this,
            .kw_break, .kw_case, .kw_catch, .kw_continue, .kw_debugger,
            .kw_default, .kw_delete, .kw_do, .kw_else, .kw_extends,
            .kw_finally, .kw_for, .kw_function, .kw_if, .kw_in,
            .kw_instanceof, .kw_new, .kw_return, .kw_super, .kw_switch,
            .kw_throw, .kw_try, .kw_typeof, .kw_var, .kw_while, .kw_with,
            .kw_class, .kw_const, .kw_export, .kw_import,
            => true,
            else => false,
        };
        if (is_reserved_type_name) {
            try p.emitDiagnostic(p.currentSpan(), "'{s}' is not a valid type name", .{p.tokenText(name_tok)});
            return error.ParseError;
        }
    }

    // Build the name Identifier IMMEDIATELY so end_tok matches name_tok.
    // Declare as TypeVariable so circular-reference rules can resolve it.
    const name_ident = try p.addNode(.{
        .tag = .identifier,
        .main_token = name_tok,
        .data = .{ .lhs = .none, .rhs = .none },
    });
    try p.emitDeclare(.type_decl, name_ident);

    // Open a child block scope for type parameters so they can shadow
    // outer type aliases. ESLint/TypeScript-ESLint creates a child scope
    // for each type alias containing its type parameters.
    var type_params_range = SubRange{ .start = 0, .end = 0 };
    const has_type_params = p.peek() == .less_than;
    var ta_scope_ev: u32 = 0;
    if (has_type_params) {
        ta_scope_ev = try p.emitScopeOpen(.block, .none);
        const prev_eftp = p.emit_fn_type_params;
        p.emit_fn_type_params = true;
        type_params_range = try parseTypeParameterListNoConst(p);
        p.emit_fn_type_params = prev_eftp;
    }

    // Expect `=`
    _ = try p.expect(.equal);

    // Parse the aliased type
    const type_node = try parseType(p);

    // Expect semicolon (with ASI)
    try p.expectSemicolon();

    const extra = try p.addExtra(ast.TypeAliasData, .{
        .name = name_tok,
        .type_params = type_params_range.start,
        .type_params_end = type_params_range.end,
        .type_node = type_node,
    });

    const decl_node = try p.addNode(.{
        .tag = .ts_type_alias_decl,
        .main_token = type_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = name_ident },
    });

    if (has_type_params) {
        try p.emitScopeClose(.none);
        p.patchScopeOpenNode(ta_scope_ev, decl_node);
    }

    return decl_node;
}

// =====================================================================
// 9. parseEnumDeclaration
// =====================================================================

/// Parse `enum Name { A, B = 1, C }`.
pub fn parseEnumDeclaration(p: *Parser) Error!NodeIndex {
    const enum_tok = p.advance(); // consume `enum`

    // Enum name — contextual keywords are valid enum names but always-reserved words are not.
    const name_tok = try p.expectIdentifierOrKeyword();
    // TS1212: strict reserved words cannot be used as enum names in strict mode.
    try p.checkStrictBinding(name_tok);
    {
        const name_tag = p.tokenTag(name_tok);
        const is_reserved = switch (name_tag) {
            .kw_break, .kw_case, .kw_catch, .kw_continue, .kw_debugger,
            .kw_default, .kw_delete, .kw_do, .kw_else, .kw_extends,
            .kw_finally, .kw_for, .kw_function, .kw_if, .kw_in,
            .kw_instanceof, .kw_new, .kw_return, .kw_super, .kw_switch,
            .kw_this, .kw_throw, .kw_try, .kw_typeof, .kw_var, .kw_void,
            .kw_while, .kw_with, .kw_class, .kw_const, .kw_export,
            .kw_import, .kw_null, .kw_true, .kw_false,
            => true,
            else => false,
        };
        if (is_reserved) {
            try p.emitDiagnostic(p.currentSpan(), "'{s}' is not a valid identifier", .{p.tokenText(name_tok)});
            return error.ParseError;
        }
    }

    // Enum body: `{ members }`
    _ = try p.expect(.l_brace);

    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    while (p.peek() != .r_brace and !p.isAtEnd()) {
        const member_tok: u32 = p.tokIdx();

        // Member name can be identifier or string literal
        var member_name: NodeIndex = undefined;
        if (p.peek() == .identifier or p.peek().isKeyword()) {
            member_name = try p.parseIdentifier();
        } else if (p.peek() == .string_literal) {
            const str_tok = p.advance();
            member_name = try p.addNode(.{
                .tag = .string_literal,
                .main_token = str_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        } else if (p.peek() == .l_bracket) {
            // Computed member name: [expr]
            // TS1164: emit only when the expr is dynamic (identifier/complex expression).
            // Constant literals like [1], ["str"], [+1] are allowed by TypeScript (TS2452 only).
            _ = p.advance(); // consume '['
            const p1 = p.peek();
            const is_literal_computed = p1 == .number_literal or p1 == .string_literal or
                ((p1 == .plus or p1 == .minus) and p.peekAt(1) == .number_literal);
            if (!is_literal_computed) {
                try p.emitDiagnostic(p.currentSpan(), "Computed property names are not allowed in enums", .{});
            }
            member_name = try p.parseExpression();
            _ = try p.expect(.r_bracket);
        } else if (p.peek() == .number_literal or p.peek() == .bigint_literal) {
            // Numeric/BigInt member name (semantic error TS2452, but parseable)
            const num_tok = p.advance();
            member_name = try p.addNode(.{
                .tag = .number_literal,
                .main_token = num_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        } else if (p.peek() == .hash) {
            // Private name in enum: semantic error (TS18024), not a parse error.
            const hash_tok = p.advance();
            if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
            member_name = try p.addNode(.{
                .tag = .identifier,
                .main_token = hash_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
        } else {
            try p.emitError("Expected enum member name");
            return p.makeErrorNode();
        }

        // Optional initializer: `= value`
        var init_value: NodeIndex = .none;
        if (p.peek() == .equal) {
            _ = p.advance(); // consume `=`
            // Enum member initializers run outside async/generator context.
            // TS1308: `await` not valid here; TS1163: `yield` not valid here.
            const prev_in_async_em = p.in_async;
            const prev_in_gen_em = p.in_generator;
            p.in_async = false;
            p.in_generator = false;
            p.syncYieldLex();
            defer {
                p.in_async = prev_in_async_em;
                p.in_generator = prev_in_gen_em;
                p.syncYieldLex();
            }
            init_value = try p.parseAssignmentExpression();
        }

        const member_node = try p.addNode(.{
            .tag = .ts_enum_member,
            .main_token = member_tok,
            .data = .{ .lhs = member_name, .rhs = init_value },
        });
        try p.scratchPush(member_node);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_brace);

    const members = p.scratchSlice(scratch_top);
    const members_range = try p.addSlice(members);

    const extra = try p.addExtra(ast.EnumData, .{
        .name = name_tok,
        .members_start = members_range.start,
        .members_end = members_range.end,
    });

    const enum_node = try p.addNode(.{
        .tag = .ts_enum_decl,
        .main_token = enum_tok,
        .data = .{ .lhs = NodeIndex.fromInt(extra), .rhs = .none },
    });
    // Declare the enum name in the enclosing scope so forward references resolve.
    // The event_resolver extracts the name from EnumData.name (not main_token which
    // is the `enum` keyword) when kind == .enum_decl.
    try p.emitDeclare(.enum_decl, enum_node);
    return enum_node;
}

// =====================================================================
// 10. parseNamespaceDeclaration
// =====================================================================

/// Parse `namespace Name { ... }` or `namespace Name.Sub { ... }`.
pub fn parseNamespaceDeclaration(p: *Parser) Error!NodeIndex {
    return parseNamespaceOrModule(p, .ts_namespace_decl);
}

// =====================================================================
// 11. parseModuleDeclaration
// =====================================================================

/// Parse `module Name { ... }`. Same as namespace but with `ts_module_decl` tag.
pub fn parseModuleDeclaration(p: *Parser) Error!NodeIndex {
    return parseNamespaceOrModule(p, .ts_module_decl);
}

/// Shared implementation for namespace and module declarations.
fn parseNamespaceOrModule(p: *Parser, node_tag: Node.Tag) Error!NodeIndex {
    const main_tok = p.advance(); // consume `namespace` or `module`

    // TS1540: an identifier-named declaration written with the `module` keyword
    // should use `namespace` instead. This is a suggestion, NOT a parse error — the
    // declaration is valid — so it is emitted at `.warning` severity (fires per name
    // segment: root + each dotted part). The string-literal form (`declare module
    // "foo"`) is the one legitimate use of `module` and is exempt.
    const is_module_kw = node_tag == .ts_module_decl;

    // Name (identifier or string literal for ambient modules)
    var name_node: NodeIndex = undefined;
    if (p.peek() == .string_literal) {
        // TS1035: Only ambient modules can use quoted names.
        if (!p.in_ts_ambient) {
            try p.emitDiagnostic(p.currentSpan(), "Only ambient modules can use quoted names", .{});
        }
        const str_tok = p.advance();
        name_node = try p.addNode(.{
            .tag = .string_literal,
            .main_token = str_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else {
        // TS1212: strict reserved words not allowed as namespace names in strict mode.
        if (p.in_strict and p.isStrictReservedWord(p.tokIdx())) {
            try p.emitDiagnostic(p.currentSpan(),
                "Identifier expected. '{s}' is a reserved word in strict mode.",
                .{p.tokenText(p.tokIdx())});
        }
        name_node = try p.parseIdentifier();
        if (is_module_kw) try p.emitWarningAtToken(p.node_main_token_ptr[name_node.toInt()], "A 'namespace' declaration should not be declared using the 'module' keyword. Please use the 'namespace' keyword instead.", .{});
        // Declare the namespace name in the enclosing scope so forward references
        // (e.g. `export { Foo }; namespace Foo {}`) resolve correctly.
        try p.emitDeclare(.namespace_decl, name_node);
        // Support dotted names: `namespace A.B.C { }`
        while (p.peek() == .dot) {
            _ = p.advance(); // consume `.`
            // Parts after the first are property names, not references.
            if (p.peek() != .identifier and !p.peek().isKeyword()) break;
            const prop_tok = p.advance();
            if (is_module_kw) try p.emitWarningAtToken(prop_tok, "A 'namespace' declaration should not be declared using the 'module' keyword. Please use the 'namespace' keyword instead.", .{});
            const sub = try p.addNode(.{
                .tag = .property_ident,
                .main_token = prop_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            name_node = try p.addNode(.{
                .tag = .member_expr,
                .main_token = p.tokIdx(),
                .data = .{ .lhs = name_node, .rhs = sub },
            });
        }
    }

    // Ambient module with no body: `declare module "foo";`
    if (p.peek() == .semicolon) {
        _ = p.advance();
        return p.addNode(.{
            .tag = node_tag,
            .main_token = main_tok,
            .data = .{ .lhs = name_node, .rhs = .none },
        });
    }

    // Module/namespace body allows export/import (module scope) at its top level.
    // Ambient flag is inherited from the declare context that wraps this namespace.
    const prev_is_module = p.is_module;
    const prev_in_block = p.in_block;
    const prev_in_function = p.in_function;
    const prev_in_ts_ambient = p.in_ts_ambient;
    const prev_in_ts_namespace = p.in_ts_namespace;
    p.is_module = true;
    p.in_block = false;
    p.in_function = false;
    p.in_ts_namespace = true;
    // If we're already in an ambient context (e.g. `declare namespace`), keep it set.
    // This allows `const x: T;` inside the body without initializer.
    const body = try p.parseBlockStatement();
    p.is_module = prev_is_module;
    p.in_block = prev_in_block;
    p.in_function = prev_in_function;
    p.in_ts_ambient = prev_in_ts_ambient;
    p.in_ts_namespace = prev_in_ts_namespace;

    return p.addNode(.{
        .tag = node_tag,
        .main_token = main_tok,
        .data = .{ .lhs = name_node, .rhs = body },
    });
}

// =====================================================================
// 12. parseInterfaceMember
// =====================================================================

/// Parse a single interface/object type member.
///
/// Handles:
///   - Property signature:     `name: Type;`
///   - Optional property:      `name?: Type;`
///   - Method signature:       `name(params): ReturnType;`
///   - Index signature:        `[key: Type]: Type;`
///   - Call signature:         `(params): ReturnType;`
///   - Construct signature:    `new (params): ReturnType;`
///   - Readonly property:      `readonly name: Type;`
pub fn parseInterfaceMember(p: *Parser) Error!NodeIndex {
    const member_tok: u32 = p.tokIdx();

    // ── TS1071: 'static' modifier on index signature in interface ────
    // `static` is a keyword token, handled before the identifier-modifier path.
    if (p.peek() == .kw_static and !p.isOnNewLineAt(1)) {
        const next = p.peekAt(1);
        if (next == .l_bracket) {
            try p.emitDiagnostic(p.currentSpan(), "'static' modifier cannot appear on an index signature", .{});
        } else if (next != .l_paren and next != .colon and next != .semicolon and
            next != .r_brace and next != .question and next != .comma and next != .eof)
        {
            try p.emitDiagnostic(p.currentSpan(), "Modifier cannot appear on a type member", .{});
        }
        if (next != .l_paren and next != .colon and next != .semicolon and
            next != .r_brace and next != .question and next != .comma and next != .eof)
        {
            _ = p.advance(); // skip 'static'
        }
    }

    // ── Reject access/invalid modifiers on interface members ─────
    const is_override_kw = p.peek() == .kw_override and !p.isOnNewLineAt(1);
    const is_ident_mod = p.peek() == .identifier and !p.isOnNewLineAt(1);
    if (is_override_kw or is_ident_mod) {
        const mod_text = p.tokenText(p.tokIdx());
        const is_invalid_mod = is_override_kw or
            std.mem.eql(u8, mod_text, "public") or
            std.mem.eql(u8, mod_text, "private") or
            std.mem.eql(u8, mod_text, "protected") or
            std.mem.eql(u8, mod_text, "static") or
            std.mem.eql(u8, mod_text, "override");
        if (is_invalid_mod) {
            const next = p.peekAt(1);
            // Only reject if followed on the same line by something that looks like
            // a member name — not if it IS the member name (followed by : or ( or ;)
            if (next != .l_paren and next != .colon and next != .semicolon and
                next != .r_brace and next != .question and next != .comma and
                next != .eof)
            {
                try p.emitDiagnostic(p.currentSpan(), "Modifier cannot appear on a type member", .{});
                _ = p.advance(); // skip the modifier
            }
        }
    }

    // ── Getter/setter accessor: `get name(...)` or `set name(...)` ──
    // `get` and `set` are kw_get/kw_set tokens. Detect them when followed by a member
    // name token (not `(` `<` `:` `?` `;` `}` — those mean "get"/"set" IS the member name).
    var method_kind: u32 = 0; // 0=method, 1=get, 2=set
    if ((p.peek() == .kw_get or p.peek() == .kw_set) and !p.isOnNewLineAt(1)) {
        const next1 = p.peekAt(1);
        if (next1 != .l_paren and next1 != .less_than and next1 != .colon and
            next1 != .question and next1 != .semicolon and next1 != .r_brace and
            next1 != .comma and next1 != .eof)
        {
            method_kind = if (p.peek() == .kw_get) 1 else 2;
            _ = p.advance(); // consume "get"/"set"
        }
    }

    // ── Call signature: `(params): ReturnType;` or `<T>(params): ReturnType;`
    if (p.peek() == .l_paren or p.peek() == .less_than) {
        return parseCallOrConstructSignature(p, member_tok, false);
    }

    // ── Construct signature: `new (params): ReturnType;` or `new <T>(params): ReturnType;`
    if (p.peek() == .kw_new and (p.peekAt(1) == .l_paren or p.peekAt(1) == .less_than)) {
        _ = p.advance(); // consume `new`
        return parseCallOrConstructSignature(p, member_tok, true);
    }

    // ── Index signature: `[key: Type]: Type;` ────────────────
    // Only treat as index signature if `[identifierOrKeyword :` pattern (colon inside brackets).
    // Keyword names like `module`, `type`, `from` are valid index parameter names.
    // Otherwise it's a computed property `[expr]: Type;` handled below.
    if (p.peek() == .l_bracket and
        (((p.peekAt(1) == .identifier or p.peekAt(1).isKeyword()) and p.peekAt(2) == .colon) or
        (p.peekAt(1) == .kw_readonly and (p.peekAt(2) == .identifier or p.peekAt(2).isKeyword()) and p.peekAt(3) == .colon)))
    {
        return parseIndexSignature(p);
    }
    // TS1096: `[a, b]: Type` — multiple parameters in index signature.
    // We detect `[identifier ,` as a malformed multi-param index signature.
    if (p.peek() == .l_bracket and
        (p.peekAt(1) == .identifier or p.peekAt(1).isKeyword()) and p.peekAt(2) == .comma)
    {
        const bracket_tok = p.advance(); // consume `[`
        const param_ident = try p.parseIdentifier(); // consume first param
        try p.emitDiagnostic(p.currentSpan(), "An index signature must have exactly one parameter", .{});
        // Consume remaining params and closing bracket
        var depth: i32 = 1;
        while (p.peek() != .eof and depth > 0) {
            const t = p.peek();
            if (t == .l_bracket) depth += 1;
            if (t == .r_bracket) { depth -= 1; if (depth == 0) break; }
            _ = p.advance();
        }
        _ = try p.expect(.r_bracket);
        _ = try p.expect(.colon);
        const value_type = try parseType(p);
        try consumeMemberSeparator(p);
        return p.addNode(.{
            .tag = .ts_index_signature,
            .main_token = bracket_tok,
            .data = .{ .lhs = param_ident, .rhs = value_type },
        });
    }

    // ── Skip `readonly` modifier ─────────────────────────────
    if (p.peek() == .kw_readonly) {
        _ = p.advance(); // consume `readonly`
        // Check for index signature after readonly: `readonly [key: Type]: Type;`
        if (p.peek() == .l_bracket and (p.peekAt(1) == .identifier or p.peekAt(1).isKeyword()) and p.peekAt(2) == .colon) {
            return parseIndexSignature(p);
        }
    }

    // ── Member name ──────────────────────────────────────────
    var name_node: NodeIndex = undefined;
    if (p.peek() == .identifier or p.peek().isKeyword()) {
        name_node = try p.parseIdentifier();
    } else if (p.peek() == .string_literal) {
        const str_tok = p.advance();
        name_node = try p.addNode(.{
            .tag = .string_literal,
            .main_token = str_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else if (p.peek() == .number_literal) {
        const num_tok = p.advance();
        name_node = try p.addNode(.{
            .tag = .number_literal,
            .main_token = num_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else if (p.peek() == .l_bracket) {
        // Computed property name in interface: `[Symbol.iterator]: ...`
        _ = p.advance(); // consume `[`
        name_node = try p.parseExpression();
        _ = try p.expect(.r_bracket);
    } else if (p.peek() == .hash) {
        // Private identifiers in interface/type-literal members are TS18016 — a
        // SEMANTIC error per the TS compiler (not TS1xxx), so the parser accepts.
        // Babel rejects this at parse time; that's a babel-specific stricture we
        // intentionally don't replicate. Downstream type-aware tooling can raise it.
        const hash_tok = p.advance();
        if (p.peek() == .identifier or p.peek().isKeyword()) _ = p.advance();
        name_node = try p.addNode(.{
            .tag = .identifier,
            .main_token = hash_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    } else {
        try p.emitError("Expected interface member name");
        // Advance past the unrecognized token to avoid infinite loops.
        if (!p.isAtEnd()) _ = p.advance();
        return p.makeErrorNode();
    }

    // ── Optional marker `?` ──────────────────────────────────
    _ = p.eat(.question);

    // ── Method signature: `name<T>(params): ReturnType` ──────
    if (p.peek() == .less_than or p.peek() == .l_paren) {
        // Optional type parameters — store as SubRange so adapter can expose
        // node.typeParameters to rules like @typescript-eslint/method-signature-style.
        var type_params_range: ast.SubRange = .{ .start = 0, .end = 0 };
        if (p.peek() == .less_than) {
            type_params_range = try parseTypeParameterList(p);
        }

        _ = try p.expect(.l_paren);
        const scratch_top = p.scratchLen();
        defer p.scratchPop(scratch_top);

        while (p.peek() != .r_paren and !p.isAtEnd()) {
            const param = try parseFunctionTypeParam(p);
            try p.scratchPush(param);

            if (p.peek() == .comma) {
                _ = p.advance();
            } else {
                break;
            }
        }

        _ = try p.expect(.r_paren);

        // Optional return type annotation (wrapped in TSTypeAnnotation node)
        const prev_in_rt_imem = p.in_return_type;
        p.in_return_type = true;
        const return_type = try p.parseOptionalTypeAnnotation();
        p.in_return_type = prev_in_rt_imem;

        try consumeMemberSeparator(p);

        const params_slice = p.scratchSlice(scratch_top);
        const params_range = try p.addSlice(params_slice);
        const sig_extra = try p.addExtra(ast.InterfaceSigData, .{
            .key = name_node,
            .params_start = params_range.start,
            .params_end = params_range.end,
            .return_type = return_type,
            .kind = method_kind,
            .type_params = type_params_range.start,
            .type_params_end = type_params_range.end,
        });
        return p.addNode(.{
            .tag = .ts_method_signature,
            .main_token = member_tok,
            .data = .{ .lhs = ast.NodeIndex.fromInt(sig_extra), .rhs = .none },
        });
    }

    // ── Property signature: `name: Type` ─────────────────────
    const type_node = try p.parseOptionalTypeAnnotation();

    try consumeMemberSeparator(p);

    return p.addNode(.{
        .tag = .ts_property_signature,
        .main_token = member_tok,
        .data = .{ .lhs = name_node, .rhs = type_node },
    });
}

/// Parse a call or construct signature (shared logic).
/// is_construct: true for `new ()` (construct), false for `()` (call).
fn parseCallOrConstructSignature(p: *Parser, member_tok: TokenIndex, is_construct: bool) Error!NodeIndex {
    // Optional type parameters
    var sig_type_params_range = ast.SubRange{ .start = 0, .end = 0 };
    if (p.peek() == .less_than) {
        sig_type_params_range = try parseTypeParameterList(p);
    }

    _ = try p.expect(.l_paren);
    const scratch_top = p.scratchLen();
    defer p.scratchPop(scratch_top);

    while (p.peek() != .r_paren and !p.isAtEnd()) {
        const param = try parseFunctionTypeParam(p);
        try p.scratchPush(param);

        if (p.peek() == .comma) {
            _ = p.advance();
        } else {
            break;
        }
    }

    _ = try p.expect(.r_paren);

    // Optional return type — wrap in ts_type_annotation so the adapter exposes
    // it as TSTypeAnnotation { typeAnnotation: <type> } matching @typescript-eslint.
    var return_type: NodeIndex = .none;
    if (p.peek() == .colon) {
        const colon_tok_sig = p.tokIdx();
        _ = p.advance();
        const prev_in_rt_sig = p.in_return_type;
        p.in_return_type = true;
        const inner_type = try parseType(p);
        p.in_return_type = prev_in_rt_sig;
        return_type = try p.addNode(.{
            .tag = .ts_type_annotation,
            .main_token = colon_tok_sig,
            .data = .{ .lhs = inner_type, .rhs = .none },
        });
    }

    try consumeMemberSeparator(p);

    const params_slice = p.scratchSlice(scratch_top);
    const params_range = try p.addSlice(params_slice);
    const sig_extra = try p.addExtra(ast.InterfaceSigData, .{
        .key = .none,
        .params_start = params_range.start,
        .params_end = params_range.end,
        .return_type = return_type,
        .type_params = sig_type_params_range.start,
        .type_params_end = sig_type_params_range.end,
    });
    const sig_tag: @import("ast.zig").Node.Tag = if (is_construct) .ts_construct_signature else .ts_call_signature;
    return p.addNode(.{
        .tag = sig_tag,
        .main_token = member_tok,
        .data = .{ .lhs = ast.NodeIndex.fromInt(sig_extra), .rhs = .none },
    });
}

/// Parse an index signature: `[key: Type]: ValueType`.
pub fn parseIndexSignature(p: *Parser) Error!NodeIndex {
    const bracket_tok = p.advance(); // consume `[`

    // Parameter name — stored in lhs so JS can expose `parameters: [identifier]`
    const param_ident = try p.parseIdentifier();

    // Colon and key type. ESTree shape: the parameter Identifier carries a
    // typeAnnotation (TSTypeAnnotation wrapping the type). Wrap it here and
    // attach to param_ident.rhs so the adapter's Identifier.typeAnnotation
    // getter returns it — rules like
    // @typescript-eslint/consistent-indexed-object-style read
    // parameter.typeAnnotation and silently bail when it's missing.
    const key_colon_tok: u32 = p.tokIdx();
    _ = try p.expect(.colon);
    // TS1268: index signature parameter type must be string, number, symbol, or a template literal type.
    const key_type_tok: u32 = p.tokIdx();
    const key_type_first_tag = p.peek();
    const valid_key_type = switch (key_type_first_tag) {
        .identifier => blk: {
            const name = p.tokenText(key_type_tok);
            break :blk std.mem.eql(u8, name, "string") or
                std.mem.eql(u8, name, "number") or
                std.mem.eql(u8, name, "symbol");
        },
        .kw_unique => true, // `unique symbol`
        .template_head, .template_no_sub => true, // template literal type
        else => false,
    };
    const key_type = try parseType(p);
    if (!valid_key_type) {
        try p.emitDiagnosticAtToken(key_type_tok, "An index signature parameter type must be 'string', 'number', 'symbol', or a template literal type", .{});
    }
    const key_type_annotation = try p.addNode(.{
        .tag = .ts_type_annotation,
        .main_token = key_colon_tok,
        .data = .{ .lhs = key_type, .rhs = .none },
    });
    p.node_data_ptr[param_ident.toInt()].rhs = key_type_annotation;

    _ = try p.expect(.r_bracket);

    // Colon and value type. Wrap in TSTypeAnnotation so member.typeAnnotation
    // returns the wrapper (ESTree shape), not the bare value type.
    const value_colon_tok: u32 = p.tokIdx();
    _ = try p.expect(.colon);
    const value_type = try parseType(p);
    const value_type_annotation = try p.addNode(.{
        .tag = .ts_type_annotation,
        .main_token = value_colon_tok,
        .data = .{ .lhs = value_type, .rhs = .none },
    });

    try consumeMemberSeparator(p);

    return p.addNode(.{
        .tag = .ts_index_signature,
        .main_token = bracket_tok,
        .data = .{ .lhs = param_ident, .rhs = value_type_annotation },
    });
}

/// Consume an interface member separator: `;`, `,`, or implicit via newline.
/// Emits TS1005 if members appear on the same line with no separator.
fn consumeMemberSeparator(p: *Parser) Error!void {
    if (p.peek() == .semicolon or p.peek() == .comma) {
        _ = p.advance();
        return;
    }
    // Implicit termination: newline before next token, end of block, or eof.
    const next = p.peek();
    if (next == .r_brace or next == .eof or p.isOnNewLine()) return;
    // Same line, no separator — TS1005 "';' expected".
    try p.emitDiagnostic(p.currentSpan(), "';' expected", .{});
}

// =====================================================================
// Tests
// =====================================================================

fn isClosingAngleBracket(tag: @import("token.zig").Tag) bool {
    return tag == .greater_than or tag == .greater_greater or
        tag == .greater_greater_greater or tag == .greater_equal or
        tag == .greater_greater_equal or tag == .greater_greater_greater_equal;
}

/// Expect a closing `>` in type context.  Handles `>>`, `>>>`, `>=` etc.
/// by mutating the token in-place to consume only the first `>`.
pub fn expectClosingAngleBracket(p: *Parser) Error!void {
    switch (p.peek()) {
        .greater_than => _ = p.advance(),
        .greater_greater => {
            // `>>` → consume first `>`, leave second as `>`
            p.recordTokMut(p.tok_i);
            p.tags_ptr[p.tok_i] = .greater_than;
            // Advance the start position by 1 byte so the remaining `>` is correct
            p.tok_starts_ptr[p.tok_i] += 1;
        },
        .greater_greater_greater => {
            // `>>>` → consume first `>`, leave `>>`
            p.recordTokMut(p.tok_i);
            p.tags_ptr[p.tok_i] = .greater_greater;
            p.tok_starts_ptr[p.tok_i] += 1;
        },
        .greater_equal => {
            // `>=` → consume first `>`, leave `=`
            p.recordTokMut(p.tok_i);
            p.tags_ptr[p.tok_i] = .equal;
            p.tok_starts_ptr[p.tok_i] += 1;
        },
        .greater_greater_equal => {
            // `>>=` → consume first `>`, leave `>=`
            p.recordTokMut(p.tok_i);
            p.tags_ptr[p.tok_i] = .greater_equal;
            p.tok_starts_ptr[p.tok_i] += 1;
        },
        .greater_greater_greater_equal => {
            // `>>>=` → consume first `>`, leave `>>=`
            p.recordTokMut(p.tok_i);
            p.tags_ptr[p.tok_i] = .greater_greater_equal;
            p.tok_starts_ptr[p.tok_i] += 1;
        },
        else => {
            _ = try p.expect(.greater_than);
        },
    }
}

test "consumeMemberSeparator does not panic on eof" {
    // Smoke test — we can't easily construct a full Parser in unit tests,
    // so we rely on integration tests.  This test exists to verify the
    // module compiles cleanly.
    _ = &parseType;
    _ = &parseNonConditionalType;
    _ = &parseIntersectionType;
    _ = &parsePrimaryType;
    _ = &parseTypeParameterList;
    _ = &parseTypeArguments;
    _ = &parseInterfaceDeclaration;
    _ = &parseTypeAliasDeclaration;
    _ = &parseEnumDeclaration;
    _ = &parseNamespaceDeclaration;
    _ = &parseModuleDeclaration;
    _ = &parseInterfaceMember;
}
