/// Build parent indices and traversal orders for every node in the AST.
///
/// Fast path (parser pre-captures parents):
///   The parser writes parents[child] = parent_idx at addNode time via
///   setChildParents().  buildTraversal() detects this (tree.parents.len == n)
///   and just copies the pre-filled array — no switch pass post-parse.
///
/// Fallback (tree built without parent capture):
///   Forward scan 0..n-1: each node calls setChildParents() to write its children's
///   parent pointers.  child_idx < parent_idx for all non-root nodes (bottom-up
///   build), so one forward pass suffices.
///
/// After parents[] is ready, three simple O(n) passes produce the rest:
///   min_tok  — forward pass using parents[]
///   pre_order — counting sort on min_tok (root at position 0; descending-index
///               tiebreaker gives parent before child for same min_tok bucket)
///   dfs_events — ancestor-stack walk over pre_order
///   post_order — trivial [1..n-1, 0]
const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const SubRange = ast_mod.SubRange;

pub const NONE: u32 = std.math.maxInt(u32);

/// Parent pointers + DFS orders + interleaved events.
/// `parents`, `pre_order`, `post_order`, `min_tok` have length n; `dfs_events` has length 2n.
/// Caller owns all slices.
pub const TraversalResult = struct {
    parents: []u32,
    pre_order: []u32,
    post_order: []u32,
    dfs_events: []i32,
    /// min_tok[i] = minimum main_token index in the subtree rooted at node i.
    min_tok: []u32,
    /// resolved_parents[i] = parents[i] with grouping_expr / ts_parenthesized_type
    /// ancestors skipped — i.e. the parent that ESTree-shaped JS sees after
    /// `nodeView` unwraps parenthesised expressions. Eliminates a hot while-loop
    /// in the JS `get parent` slow path.
    resolved_parents: []u32,
    /// type_overrides[i] = ESTree-shape type override slot for node i, or 0 to
    /// mean "use TAG_NAMES[tag]" (the common default). Lets JS skip the
    /// per-node `_computeNodeType` switch + token text matching for the five
    /// disambiguation cases. See `TypeOverride` below for the slot layout.
    type_overrides: []u8,
    /// parent_kinds[i] = ESTree-shape parent-synthesis dispatch slot for node i,
    /// or 0 to mean "no synthesis; resolved_parents[i]'s NodeView is the parent
    /// directly". Pre-bakes the per-node tag-pattern matching that JS-side
    /// `get parent` runs after resolving the direct parent. See `ParentKind`
    /// below for the slot layout.
    parent_kinds: []u8,
};

/// ESTree-shape parent-synthesis IDs. Slot 0 means "no synthesis" — the JS
/// adapter returns the resolved-parent NodeView unchanged. Slots 1..6 each
/// trigger a specific synthetic-wrapper or redirect path in the JS `get
/// parent` getter, replacing the per-node tag-pattern cascade with a single
/// u8 lookup. Must stay in sync with the dispatch in `js/estree-adapter.js`'s
/// `get parent`.
pub const ParentKind = enum(u8) {
    none = 0,
    /// This node is the outermost optional in a chain — wrap parent NodeView
    /// in a synthetic ChainExpression. Tag is one of optional_member_expr /
    /// optional_computed_member_expr / optional_call_expr, and the direct
    /// parent (post grouping_expr skip) does not extend the chain by using
    /// this as object/callee.
    chain_expression = 1,
    /// Resolved parent is one of method_def / getter_def / setter_def /
    /// constructor_def / computed_method_def / computed_getter_def /
    /// computed_setter_def, and this node is NOT the method's key (lhs).
    /// JS returns the synthetic FunctionExpression (`parent.value`) instead.
    method_value = 2,
    /// Resolved parent is object_pattern and this node is assignment_pattern
    /// or identifier — JS synthesizes a Property wrapper around it.
    object_pattern_property = 3,
    /// Resolved parent is jsx_self_closing and this node is jsx_attribute or
    /// jsx_spread_attribute — JS synthesizes a JSXOpeningElement wrapper.
    jsx_opening_element = 4,
    /// Resolved parent is ts_enum_decl and this node is ts_enum_member — JS
    /// returns the synthetic TSEnumBody (cached on the parent NodeView).
    ts_enum_body = 5,
    /// Resolved parent is ts_interface_decl and this node is one of
    /// ts_method_signature / ts_property_signature / ts_call_signature /
    /// ts_construct_signature / ts_index_signature — JS returns the synthetic
    /// TSInterfaceBody (cached on the parent NodeView).
    ts_interface_body = 6,
    /// This node is a ts_type_parameter whose resolved parent owns a
    /// type_params SubRange. JS synthesizes a TSTypeParameterDeclaration
    /// wrapper around the SubRange and returns it as the parent.
    ts_type_parameter_declaration = 7,
};

/// ESTree-shape type override IDs. Must stay in sync with `_OVERRIDE_TYPES`
/// in `js/estree-adapter.js`. Slot 0 is reserved to mean "no override".
pub const TypeOverride = enum(u8) {
    none = 0,
    private_identifier = 1,
    property = 2, // method_def inside object_literal/object_pattern
    ts_import_equals_declaration = 3,
    ts_module_block = 4,
    ts_literal_type = 5,
    ts_any_keyword = 6,
    ts_bigint_keyword = 7,
    ts_boolean_keyword = 8,
    ts_intrinsic_keyword = 9,
    ts_never_keyword = 10,
    ts_null_keyword = 11,
    ts_number_keyword = 12,
    ts_object_keyword = 13,
    ts_string_keyword = 14,
    ts_symbol_keyword = 15,
    ts_this_type = 16,
    ts_undefined_keyword = 17,
    ts_unknown_keyword = 18,
    ts_void_keyword = 19,
    ts_qualified_name = 20,
    /// `call_expr(ts_instantiation_expr(new_expr(callee,NONE),typeArgs),args)` —
    /// the canonical parse of `new Foo<T>()`. Present to rules as NewExpression.
    new_expression = 21,
    /// ES2024 auto-accessor class field (`accessor method = …`). Presented as
    /// AccessorProperty in ESTree, not PropertyDefinition.
    accessor_property = 22,
    /// Abstract class property (`abstract field: T`). Presented as
    /// TSAbstractPropertyDefinition in ESTree.
    ts_abstract_property_definition = 23,
    /// Abstract accessor class field (`abstract accessor field: T`). Presented as
    /// TSAbstractAccessorProperty in ESTree.
    ts_abstract_accessor_property = 24,
};

/// Called by Parser.addNode to record parent→child edges incrementally.
/// `extra` is the parser's extra_data at the time the node is finalized
/// (all children have already been appended to extra_data before addNode).
/// `idx` is the new node's own index (= the parent index for its children).
pub fn setChildParents(parents: []u32, extra: []const u32, tag: ast_mod.Node.Tag, data: ast_mod.Node.Data, idx: u32) void {
    const lhs = data.lhs;
    const rhs = data.rhs;
    switch (tag) {
        .root => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .block_stmt, .static_block => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .if_stmt => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .if_else_stmt => {
            const ed = extraData(ast_mod.IfData, extra, @intFromEnum(rhs));
            sp(parents, lhs,           idx);
            sp(parents, ed.consequent, idx);
            sp(parents, ed.alternate,  idx);
        },
        .while_stmt, .do_while_stmt => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .for_stmt => {
            const ed = extraData(ast_mod.ForData, extra, @intFromEnum(lhs));
            sp(parents, ed.init,      idx);
            sp(parents, ed.condition, idx);
            sp(parents, ed.update,    idx);
            sp(parents, rhs,          idx);
        },
        .for_in_stmt, .for_of_stmt, .for_await_of_stmt => {
            const ed = extraData(ast_mod.ForInOfData, extra, @intFromEnum(lhs));
            sp(parents, ed.binding, idx);
            sp(parents, ed.expr,    idx);
            sp(parents, ed.body,    idx);
        },
        .switch_stmt => {
            const sub = extraData(SubRange, extra, @intFromEnum(rhs));
            sp(parents, lhs, idx);
            spSub(parents, extra, sub.start, sub.end, idx);
        },
        .switch_case => {
            const sub = extraData(SubRange, extra, @intFromEnum(rhs));
            sp(parents, lhs, idx);
            spSub(parents, extra, sub.start, sub.end, idx);
        },
        .switch_default => {
            const sub = extraData(SubRange, extra, @intFromEnum(rhs));
            spSub(parents, extra, sub.start, sub.end, idx);
        },
        .try_stmt => {
            const ed = extraData(ast_mod.TryData, extra, @intFromEnum(rhs));
            sp(parents, lhs,             idx);
            sp(parents, ed.catch_node,   idx);
            sp(parents, ed.finally_body, idx);
        },
        .catch_clause => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .expression_stmt, .return_stmt, .throw_stmt => {
            sp(parents, lhs, idx);
        },
        .labeled_stmt => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .break_label, .continue_label => {
            sp(parents, lhs, idx);
        },
        .with_stmt => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .var_decl, .let_decl, .const_decl => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .declarator => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
        .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
        .ts_declare_function,
        => {
            const ed = extraData(ast_mod.FnData, extra, @intFromEnum(lhs));
            sp(parents, ed.name, idx);
            spSub(parents, extra, ed.type_params, ed.type_params_end, idx);
            spSub(parents, extra, ed.params, ed.params_end, idx);
            sp(parents, ed.return_type, idx);
            sp(parents, ed.body, idx);
        },
        .arrow_fn, .async_arrow_fn => {
            const ed = extraData(ast_mod.ArrowData, extra, @intFromEnum(lhs));
            spSub(parents, extra, ed.params_start, ed.params_end, idx);
            sp(parents, ed.return_type, idx);
            sp(parents, ed.body, idx);
        },
        .class_decl, .class_expr => {
            const ed = extraData(ast_mod.ClassData, extra, @intFromEnum(lhs));
            sp(parents, ed.name,        idx);
            spSub(parents, extra, ed.type_params, ed.type_params_end, idx);
            sp(parents, ed.super_class, idx);
            sp(parents, ed.body,        idx);
        },
        .class_body => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .method_def, .computed_method_def,
        .getter_def, .computed_getter_def,
        .setter_def, .computed_setter_def,
        .constructor_def,
        => {
            const ed = extraData(ast_mod.MethodData, extra, @intFromEnum(rhs));
            sp(parents, lhs, idx);
            spSub(parents, extra, ed.type_params, ed.type_params_end, idx);
            spSub(parents, extra, ed.params_start, ed.params_end, idx);
            sp(parents, ed.return_type, idx);
            sp(parents, ed.body, idx);
        },
        .property_def, .computed_property_def => {
            const pd = extraData(ast_mod.PropertyData, extra, @intFromEnum(rhs));
            sp(parents, lhs, idx);
            sp(parents, pd.value, idx);
            sp(parents, pd.type_annotation, idx);
        },
        .formal_parameters => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .import_decl => {
            if (lhs != .none) {
                const ed = extraData(ast_mod.ImportData, extra, @intFromEnum(lhs));
                spSub(parents, extra, ed.specifiers_start, ed.specifiers_end, idx);
                sp(parents, ed.source, idx);
            } else if (rhs != .none) {
                sp(parents, rhs, idx);
            }
        },
        .import_specifier => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .import_default_specifier, .import_namespace_specifier => {
            sp(parents, lhs, idx);
        },
        .export_specifier => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .export_named => {
            if (rhs == .none) {
                sp(parents, lhs, idx);
            } else {
                spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
            }
        },
        .export_named_from => {
            const ed = extraData(ast_mod.ImportData, extra, @intFromEnum(lhs));
            spSub(parents, extra, ed.specifiers_start, ed.specifiers_end, idx);
            sp(parents, ed.source, idx);
        },
        .export_default_expr, .export_default_fn, .export_default_class => {
            sp(parents, lhs, idx);
        },
        .export_all => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .new_target, .import_meta => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .array_literal, .object_literal, .template_literal,
        .array_pattern, .object_pattern,
        .sequence_expr, .jsx_fragment,
        => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .call_expr, .optional_call_expr, .new_expr => {
            sp(parents, lhs, idx);
            if (rhs != .none) {
                const sub = extraData(SubRange, extra, @intFromEnum(rhs));
                spSub(parents, extra, sub.start, sub.end, idx);
            }
        },
        .member_expr, .optional_member_expr,
        .computed_member_expr, .optional_computed_member_expr,
        => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .property_ident, .property_literal => {},
        .add, .subtract, .multiply, .divide, .modulo, .exponentiate,
        .equal, .not_equal, .strict_equal, .strict_not_equal,
        .less_than, .greater_than, .less_equal, .greater_equal,
        .instanceof_expr, .in_expr,
        .bitwise_and, .bitwise_or, .bitwise_xor,
        .shift_left, .shift_right, .unsigned_shift_right,
        .logical_and, .logical_or, .nullish_coalesce,
        .assign, .add_assign, .sub_assign, .mul_assign, .div_assign,
        .mod_assign, .exp_assign, .and_assign, .or_assign, .xor_assign,
        .shl_assign, .shr_assign, .ushr_assign,
        .logical_and_assign, .logical_or_assign, .nullish_assign,
        .assignment_pattern, .tagged_template,
        => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .unary_plus, .unary_minus, .bitwise_not, .logical_not,
        .typeof_expr, .void_expr, .delete_expr, .await_expr,
        .yield_expr, .yield_delegate,
        .prefix_inc, .prefix_dec, .postfix_inc, .postfix_dec,
        .spread_element,
        .grouping_expr, .ts_non_null_expr,
        => {
            sp(parents, lhs, idx);
        },
        .ts_as_expr, .ts_satisfies_expr => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .import_expr => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .rest_element => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_type_assertion => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .conditional => {
            const ed = extraData(ast_mod.Conditional, extra, @intFromEnum(rhs));
            sp(parents, lhs,           idx);
            sp(parents, ed.consequent, idx);
            sp(parents, ed.alternate,  idx);
        },
        .property, .computed_property => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .shorthand_property => {
            sp(parents, lhs, idx);
        },
        .ts_interface_decl => {
            const ed = extraData(ast_mod.InterfaceData, extra, @intFromEnum(lhs));
            spSub(parents, extra, ed.type_params,   ed.type_params_end, idx);
            spSub(parents, extra, ed.extends_start, ed.extends_end,     idx);
            spSub(parents, extra, ed.body_start,    ed.body_end,        idx);
            sp(parents, rhs, idx); // rhs = name Identifier
        },
        .ts_type_alias_decl => {
            const ed = extraData(ast_mod.TypeAliasData, extra, @intFromEnum(lhs));
            spSub(parents, extra, ed.type_params, ed.type_params_end, idx);
            sp(parents, ed.type_node, idx);
            sp(parents, rhs, idx); // rhs = name Identifier
        },
        .ts_enum_decl => {
            const ed = extraData(ast_mod.EnumData, extra, @intFromEnum(lhs));
            spSub(parents, extra, ed.members_start, ed.members_end, idx);
        },
        .ts_enum_member => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_namespace_decl, .ts_module_decl => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .jsx_element => {
            const ed = extraData(ast_mod.JsxElementData, extra, @intFromEnum(lhs));
            sp(parents, ed.opening, idx);
            spSub(parents, extra, ed.children_start, ed.children_end, idx);
            sp(parents, ed.closing, idx);
        },
        .jsx_self_closing, .jsx_opening_element => {
            const ed = extraData(ast_mod.JsxOpeningData, extra, @intFromEnum(lhs));
            sp(parents, ed.name, idx);
            spSub(parents, extra, ed.attrs_start, ed.attrs_end, idx);
        },
        .jsx_closing_element => {
            sp(parents, lhs, idx);
        },
        .jsx_attribute => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .jsx_spread_attribute => {
            sp(parents, lhs, idx);
        },
        .jsx_expression_container, .jsx_spread_child => {
            sp(parents, lhs, idx);
        },
        .jsx_member_expr, .jsx_namespaced_name => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .empty_stmt, .break_stmt, .continue_stmt,
        .debugger_stmt, .this_expr, .super_expr,
        .number_literal, .string_literal, .boolean_literal, .null_literal,
        .regex_literal, .bigint_literal, .template_element,
        .jsx_text_node, .jsx_gap_node, .jsx_empty_expr, .jsx_identifier, .error_node,
        .ts_infer_type, .ts_type_query,
        => {},
        .ts_parameter_property => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_type_literal, .ts_mapped_type, .ts_template_literal_type => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .ts_function_type, .ts_constructor_type => {
            const ed = extraData(ast_mod.FnData, extra, @intFromEnum(lhs));
            spSub(parents, extra, ed.params, ed.params_end, idx);
            sp(parents, ed.body, idx);
            if (ed.type_params_end > ed.type_params) {
                spSub(parents, extra, ed.type_params, ed.type_params_end, idx);
            }
        },
        .ts_type_reference => {
            sp(parents, lhs, idx);
            if (rhs != .none) {
                const sr = extraData(ast_mod.SubRange, extra, @intFromEnum(rhs));
                spSub(parents, extra, sr.start, sr.end, idx);
            }
        },
        .identifier => {
            sp(parents, rhs, idx);
        },
        .ts_type_annotation => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_array_type => {
            sp(parents, lhs, idx);
        },
        .ts_indexed_access_type => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_keyof_type, .ts_typeof_type, .ts_parenthesized_type => {
            sp(parents, lhs, idx);
        },
        .ts_type_predicate => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_union_type, .ts_intersection_type, .ts_tuple_type, .ts_conditional_type => {
            spSub(parents, extra, @intFromEnum(lhs), @intFromEnum(rhs), idx);
        },
        .ts_call_signature, .ts_construct_signature, .ts_method_signature => {
            const ed = extraData(ast_mod.InterfaceSigData, extra, @intFromEnum(lhs));
            if (tag == .ts_method_signature) sp(parents, ed.key, idx);
            spSub(parents, extra, ed.type_params, ed.type_params_end, idx);
            spSub(parents, extra, ed.params_start, ed.params_end, idx);
            sp(parents, ed.return_type, idx);
        },
        .ts_property_signature => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_index_signature => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .decorator => {
            sp(parents, lhs, idx);
        },
        .ts_instantiation_expr => {
            sp(parents, lhs, idx);
            if (rhs != .none) {
                const sr = extraData(ast_mod.SubRange, extra, @intFromEnum(rhs));
                spSub(parents, extra, sr.start, sr.end, idx);
            }
        },
        .ts_type_parameter => {
            sp(parents, lhs, idx);
            sp(parents, rhs, idx);
        },
        .ts_import_type => {
            // No AST children — argument string and qualifier dot-chain are
            // consumed as tokens during parsing, not stored as child nodes.
        },
    }
}

/// Quick path: produce JUST the `parents` array (the only thing the streaming
/// sem worker needs to start writeSemanticData). Lets main fire parents_ready
/// in ~0.3ms instead of waiting for the full ~10ms buildTraversal.
/// @returns owned
pub fn buildParentsOnly(tree: *const Ast, alloc: std.mem.Allocator) ![]u32 {
    const n = tree.nodes.len;
    const parents = try alloc.alloc(u32, n);
    if (n == 0) return parents;
    if (tree.parents.len == n) {
        @memcpy(parents, tree.parents[0..n]);
    } else {
        @memset(parents, NONE);
        const tags  = tree.nodes.items(.tag);
        const data  = tree.nodes.items(.data);
        const extra = tree.extra_data;
        for (0..n) |i| {
            setChildParents(parents, extra, tags[i], data[i], @intCast(i));
        }
    }
    return parents;
}

/// Compute resolved_parents and type_overrides given the parents array.
/// Independent of mintok/preorder/dfs — runs in parallel in
/// buildTraversalParallel().  Both are per-node loops over disjoint output
/// arrays; the only input is parents (read-only) plus tree fields.
pub fn buildTraversalAux(
    tree: *const Ast,
    alloc: std.mem.Allocator,
    parents: []const u32,
) !struct { resolved_parents: []u32, type_overrides: []u8, parent_kinds: []u8 } {
    const n = tree.nodes.len;
    const resolved_parents = try alloc.alloc(u32, n);
    const type_overrides = try alloc.alloc(u8, n);
    const parent_kinds = try alloc.alloc(u8, n);
    @memset(type_overrides, 0);
    @memset(parent_kinds, 0);

    if (n == 0) return .{ .resolved_parents = resolved_parents, .type_overrides = type_overrides, .parent_kinds = parent_kinds };

    const tags = tree.nodes.items(.tag);

    // Resolved parents — skip grouping_expr / ts_parenthesized_type ancestors.
    for (0..n) |i| {
        var p = parents[i];
        var guard: u32 = 0;
        while (p != NONE and (tags[p] == .grouping_expr or tags[p] == .ts_parenthesized_type)) {
            p = parents[p];
            guard += 1;
            if (guard > 64) { p = NONE; break; }
        }
        resolved_parents[i] = p;
    }

    // Type overrides — pre-bake JS adapter's `_computeNodeType` switch.
    const node_main_tokens = tree.nodes.items(.main_token);
    const data = tree.nodes.items(.data);
    const tok_starts = tree.tokens.items(.start);
    const tok_lens = tree.tokens.items(.len);
    const source = tree.source;
    for (0..n) |i| {
        switch (tags[i]) {
            .identifier, .property_ident => {
                const tok = node_main_tokens[i];
                const start = tok_starts[tok];
                if (start < source.len and source[start] == '#') {
                    type_overrides[i] = @intFromEnum(TypeOverride.private_identifier);
                }
            },
            .method_def, .getter_def, .setter_def,
            .computed_method_def, .computed_getter_def, .computed_setter_def,
            => {
                // Class-body members are tagged identically to object-literal
                // properties in ez (method_def/getter_def/setter_def). ESTree
                // distinguishes them by node type: MethodDefinition in classes,
                // Property in object literals. Apply the type-override when the
                // parent is an object literal (or pattern) so rules like
                // accessor-pairs see node.value.parent.type === "Property".
                const p = parents[i];
                if (p != NONE) {
                    const ptag = tags[p];
                    if (ptag == .object_literal or ptag == .object_pattern) {
                        type_overrides[i] = @intFromEnum(TypeOverride.property);
                    }
                }
            },
            .import_decl => {
                if (data[i].lhs == .none and data[i].rhs != .none) {
                    type_overrides[i] = @intFromEnum(TypeOverride.ts_import_equals_declaration);
                }
            },
            .block_stmt => {
                const p = parents[i];
                if (p != NONE) {
                    const ptag = tags[p];
                    if (ptag == .ts_namespace_decl or ptag == .ts_module_decl) {
                        type_overrides[i] = @intFromEnum(TypeOverride.ts_module_block);
                    }
                }
            },
            .ts_type_reference => {
                if (data[i].rhs == .none) {
                    const tok = node_main_tokens[i];
                    const start = tok_starts[tok];
                    const len = tok_lens[tok];
                    if (start + len <= source.len) {
                        const text = source[start .. start + len];
                        if (computeTsTypeRefOverride(text)) |ov| {
                            type_overrides[i] = @intFromEnum(ov);
                        }
                    }
                }
            },
            // `new Foo<T>()` is parsed as call_expr(ts_instantiation_expr(new_expr(callee,NONE),typeArgs),args).
            // Present it to ESLint rules as NewExpression so callee-type checks pass.
            .call_expr => {
                const lhs = data[i].lhs;
                if (lhs != .none and tags[@intFromEnum(lhs)] == .ts_instantiation_expr) {
                    const inner = data[@intFromEnum(lhs)].lhs;
                    if (inner != .none and tags[@intFromEnum(inner)] == .new_expr and
                        data[@intFromEnum(inner)].rhs == .none)
                    {
                        type_overrides[i] = @intFromEnum(TypeOverride.new_expression);
                    }
                }
            },
            // ES2024 auto-accessor class field or abstract class property.
            // Scan backward from the property key through modifier tokens.
            .property_def, .computed_property_def => {
                const tok = node_main_tokens[i];
                var has_accessor = false;
                var has_abstract = false;
                var j: i32 = @as(i32, @intCast(tok)) - 1;
                while (j >= 0) : (j -= 1) {
                    const k = @as(usize, @intCast(j));
                    const ps = tok_starts[k];
                    const pl = tok_lens[k];
                    if (ps + pl > source.len) break;
                    const txt = source[ps..ps + pl];
                    if (std.mem.eql(u8, txt, "accessor")) { has_accessor = true; }
                    else if (std.mem.eql(u8, txt, "abstract")) { has_abstract = true; }
                    else if (std.mem.eql(u8, txt, "public") or
                             std.mem.eql(u8, txt, "private") or
                             std.mem.eql(u8, txt, "protected") or
                             std.mem.eql(u8, txt, "readonly") or
                             std.mem.eql(u8, txt, "static") or
                             std.mem.eql(u8, txt, "declare") or
                             std.mem.eql(u8, txt, "override")) {}
                    else { break; }
                }
                if (has_accessor and has_abstract) {
                    type_overrides[i] = @intFromEnum(TypeOverride.ts_abstract_accessor_property);
                } else if (has_accessor) {
                    type_overrides[i] = @intFromEnum(TypeOverride.accessor_property);
                } else if (has_abstract) {
                    type_overrides[i] = @intFromEnum(TypeOverride.ts_abstract_property_definition);
                }
            },
            else => {},
        }
    }

    // Parent-synthesis kinds — pre-bake the JS `get parent` post-resolve
    // dispatch. Determined entirely from (this.tag, resolved_parent.tag,
    // direct_parent.tag for chain detection, nodeLhs(parent)) — all static.
    {
        for (0..n) |i| {
            const rp = resolved_parents[i];
            if (rp == NONE) continue;
            const this_tag = tags[i];

            // Kind 1: ChainExpression wrap — this node is the outermost
            // optional in its chain. Uses DIRECT parent (post grouping_expr
            // skip only) per `_isChainChild` semantics in the JS adapter.
            //
            // Also fires for regular member_expr/call_expr/computed_member_expr
            // when their callee/object chain reaches an optional `?.`. ESLint
            // wraps the OUTERMOST node of the chain in ChainExpression — that
            // outermost node may be a regular call/member if the optional is
            // nested inside (e.g. `a?.b(c).d` — outer member_expr is the wrap).
            const is_optional_self = this_tag == .optional_member_expr or
                this_tag == .optional_computed_member_expr or
                this_tag == .optional_call_expr;
            var chain_contains_optional = is_optional_self;
            if (!is_optional_self and (this_tag == .member_expr or
                this_tag == .computed_member_expr or this_tag == .call_expr))
            {
                // Walk down the lhs chain (skipping grouping_expr) looking for
                // an optional_* node. If we find one, this regular node may be
                // the chain wrapper.
                var c = data[i].lhs;
                var cguard: u32 = 0;
                while (c != .none and cguard < 128) : (cguard += 1) {
                    const ci = c.toInt();
                    const ct = tags[ci];
                    if (ct == .optional_member_expr or ct == .optional_computed_member_expr or
                        ct == .optional_call_expr) { chain_contains_optional = true; break; }
                    if (ct == .grouping_expr or ct == .member_expr or
                        ct == .computed_member_expr or ct == .call_expr)
                    { c = data[ci].lhs; continue; }
                    break;
                }
            }
            if (chain_contains_optional) {
                var dp = parents[i];
                var dguard: u32 = 0;
                while (dp != NONE and tags[dp] == .grouping_expr) {
                    dp = parents[dp];
                    dguard += 1;
                    if (dguard > 64) { dp = NONE; break; }
                }
                var is_chain_child = false;
                if (dp != NONE) {
                    const dpt = tags[dp];
                    const is_optional = dpt == .optional_member_expr or
                        dpt == .optional_computed_member_expr or
                        dpt == .optional_call_expr;
                    const is_middle = dpt == .member_expr or
                        dpt == .computed_member_expr or
                        dpt == .call_expr;
                    if ((is_optional or is_middle) and data[dp].lhs.toInt() == @as(u32, @intCast(i))) {
                        is_chain_child = true;
                    }
                }
                if (!is_chain_child) {
                    parent_kinds[i] = @intFromEnum(ParentKind.chain_expression);
                    continue;
                }
            }

            const pt = tags[rp];

            // Kind 2: method.value redirect — non-key child of a method-like.
            switch (pt) {
                .method_def, .getter_def, .setter_def, .constructor_def,
                .computed_method_def, .computed_getter_def, .computed_setter_def => {
                    if (data[rp].lhs.toInt() != @as(u32, @intCast(i))) {
                        parent_kinds[i] = @intFromEnum(ParentKind.method_value);
                        continue;
                    }
                },
                .object_pattern => {
                    if (this_tag == .assignment_pattern or this_tag == .identifier) {
                        parent_kinds[i] = @intFromEnum(ParentKind.object_pattern_property);
                        continue;
                    }
                },
                .jsx_self_closing => {
                    if (this_tag == .jsx_attribute or this_tag == .jsx_spread_attribute) {
                        parent_kinds[i] = @intFromEnum(ParentKind.jsx_opening_element);
                        continue;
                    }
                },
                .ts_enum_decl => {
                    if (this_tag == .ts_enum_member) {
                        parent_kinds[i] = @intFromEnum(ParentKind.ts_enum_body);
                        continue;
                    }
                },
                .ts_interface_decl => {
                    if (this_tag == .ts_method_signature or
                        this_tag == .ts_property_signature or
                        this_tag == .ts_call_signature or
                        this_tag == .ts_construct_signature or
                        this_tag == .ts_index_signature)
                    {
                        parent_kinds[i] = @intFromEnum(ParentKind.ts_interface_body);
                        continue;
                    }
                },
                else => {},
            }

            // Kind 7: TSTypeParameterDeclaration wrap — all ts_type_parameter
            // nodes are inside a type_params SubRange of their resolved parent;
            // JS synthesizes the TSTypeParameterDeclaration wrapper.
            if (this_tag == .ts_type_parameter) {
                parent_kinds[i] = @intFromEnum(ParentKind.ts_type_parameter_declaration);
                continue;
            }
        }
    }

    return .{ .resolved_parents = resolved_parents, .type_overrides = type_overrides, .parent_kinds = parent_kinds };
}

/// Parallel variant of buildTraversal: spawns an aux sub-thread that runs
/// resolved_parents + type_overrides while this thread runs the
/// mintok→preorder→dfs chain.  Both finish in parallel; total wall time
/// drops from sum (8.84 ms on typescript.js) to max(core, aux) ≈ 6.0 ms.
///
/// Optionally also runs computeTagNodeCsr on the aux sub-thread (when
/// `tag_csr_buf` is non-null), signaling `tag_csr_ready` right after.
/// This pulls the ~1.9 ms tag_csr cost off main's pre-fire chain — main
/// can signal parents_ready right after parents_only + depths instead of
/// also waiting on tag_csr.
pub fn buildTraversalParallel(
    tree: *const Ast,
    alloc: std.mem.Allocator,
    tag_csr_buf: ?[*]u8,
    tag_csr_backing: ?*@import("js_buffer.zig").JsBufferAllocator,
    tag_csr_out: ?*?@import("js_buffer.zig").TagNodeCsrResult,
    tag_csr_ready: ?*std.atomic.Value(bool),
) !TraversalResult {
    const n = tree.nodes.len;
    if (n == 0) return buildTraversal(tree, alloc);

    // Pre-allocate parents so aux can read it without extra sync.
    const parents = try alloc.alloc(u32, n);
    if (tree.parents.len == n) {
        @memcpy(parents, tree.parents[0..n]);
    } else {
        @memset(parents, NONE);
        const tags  = tree.nodes.items(.tag);
        const data  = tree.nodes.items(.data);
        const extra = tree.extra_data;
        for (0..n) |i| {
            setChildParents(parents, extra, tags[i], data[i], @intCast(i));
        }
    }

    const AuxJob = struct {
        tree: *const Ast,
        alloc: std.mem.Allocator,
        parents: []const u32,
        tag_csr_buf: ?[*]u8 = null,
        tag_csr_backing: ?*@import("js_buffer.zig").JsBufferAllocator = null,
        tag_csr_out: ?*?@import("js_buffer.zig").TagNodeCsrResult = null,
        tag_csr_ready: ?*std.atomic.Value(bool) = null,
        resolved_parents: []u32 = &.{},
        type_overrides: []u8 = &.{},
        parent_kinds: []u8 = &.{},
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            // tag_csr first (if requested) — signal early so worker doesn't spin.
            if (self.tag_csr_buf) |buf| {
                if (self.tag_csr_backing) |backing| {
                    if (@import("js_buffer.zig").computeTagNodeCsr(
                        buf, backing, self.tree.nodes.items(.tag),
                    )) |csr| {
                        if (self.tag_csr_out) |out| out.* = csr;
                    } else |_| {}
                }
            }
            if (self.tag_csr_ready) |a| a.store(true, .release);
            // Then resolved_parents + type_overrides + parent_kinds.
            if (buildTraversalAux(self.tree, self.alloc, self.parents)) |r| {
                self.resolved_parents = r.resolved_parents;
                self.type_overrides = r.type_overrides;
                self.parent_kinds = r.parent_kinds;
            } else |e| {
                self.err = e;
            }
        }
    };
    var aux_job: AuxJob = .{
        .tree = tree,
        .alloc = alloc,
        .parents = parents,
        .tag_csr_buf = tag_csr_buf,
        .tag_csr_backing = tag_csr_backing,
        .tag_csr_out = tag_csr_out,
        .tag_csr_ready = tag_csr_ready,
    };
    const aux_thread = std.Thread.spawn(.{}, AuxJob.run, .{&aux_job}) catch null;

    // Core path: postorder + mintok + preorder + dfs (parents already done).
    const pre_order = try alloc.alloc(u32, n);
    const post_order = try alloc.alloc(u32, n);
    const dfs_events = try alloc.alloc(i32, n * 2);

    for (1..n) |i| post_order[i - 1] = @intCast(i);
    post_order[n - 1] = 0;

    const min_tok = try alloc.alloc(u32, n);
    const main_tokens = tree.nodes.items(.main_token);
    @memcpy(min_tok, main_tokens[0..n]);

    const counts = try alloc.alloc(u32, tree.tokens.len + 1);
    defer alloc.free(counts);
    @memset(counts, 0);

    var max_min_tok: u32 = 0;
    for (1..n) |i| {
        const v = min_tok[i];
        max_min_tok = @max(max_min_tok, v);
        counts[v] += 1;
        const p = parents[i];
        if (p != NONE) min_tok[p] = @min(min_tok[p], v);
    }

    {
        var sum: u32 = 1;
        for (counts[0..max_min_tok + 1]) |*c| { const old = c.*; c.* = sum; sum += old; }
        pre_order[0] = 0;
        var ii: usize = n;
        while (ii > 1) {
            ii -= 1;
            const k = min_tok[ii];
            pre_order[counts[k]] = @intCast(ii);
            counts[k] += 1;
        }
    }

    {
        const stk = try alloc.alloc(u32, n);
        defer alloc.free(stk);
        var stk_top: usize = 0;
        var ei: u32 = 0;
        for (pre_order) |node| {
            const parent = parents[node];
            if (parent != NONE) {
                while (stk_top > 0 and parent != stk[stk_top - 1]) {
                    stk_top -= 1;
                    dfs_events[ei] = ~@as(i32, @intCast(stk[stk_top]));
                    ei += 1;
                }
            }
            dfs_events[ei] = @intCast(node);
            ei += 1;
            stk[stk_top] = node;
            stk_top += 1;
        }
        while (stk_top > 0) {
            stk_top -= 1;
            dfs_events[ei] = ~@as(i32, @intCast(stk[stk_top]));
            ei += 1;
        }
    }

    if (aux_thread) |t| {
        t.join();
        if (aux_job.err) |e| return e;
    } else {
        // Fallback: aux runs synchronously here.
        if (tag_csr_buf) |buf| {
            if (tag_csr_backing) |b| {
                if (@import("js_buffer.zig").computeTagNodeCsr(
                    buf, b, tree.nodes.items(.tag),
                )) |csr| {
                    if (tag_csr_out) |out| out.* = csr;
                } else |_| {}
            }
        }
        if (tag_csr_ready) |a| a.store(true, .release);
        const r = try buildTraversalAux(tree, alloc, parents);
        aux_job.resolved_parents = r.resolved_parents;
        aux_job.type_overrides = r.type_overrides;
        aux_job.parent_kinds = r.parent_kinds;
    }

    return .{
        .parents = parents,
        .pre_order = pre_order,
        .post_order = post_order,
        .dfs_events = dfs_events,
        .min_tok = min_tok,
        .resolved_parents = aux_job.resolved_parents,
        .type_overrides = aux_job.type_overrides,
        .parent_kinds = aux_job.parent_kinds,
    };
}

pub fn buildTraversal(tree: *const Ast, alloc: std.mem.Allocator) !TraversalResult {
    const n = tree.nodes.len;
    const parents    = try alloc.alloc(u32, n);
    const pre_order  = try alloc.alloc(u32, n);
    const post_order = try alloc.alloc(u32, n);
    const dfs_events = try alloc.alloc(i32, n * 2);

    if (n == 0) {
        const empty_min_tok = try alloc.alloc(u32, 0);
        const empty_resolved = try alloc.alloc(u32, 0);
        const empty_type_ov = try alloc.alloc(u8, 0);
        const empty_parent_kinds = try alloc.alloc(u8, 0);
        return .{ .parents = parents, .pre_order = pre_order, .post_order = post_order, .dfs_events = dfs_events, .min_tok = empty_min_tok, .resolved_parents = empty_resolved, .type_overrides = empty_type_ov, .parent_kinds = empty_parent_kinds };
    }

    // Post-order: trivial (bottom-up build → always [1..n-1, 0]).
    for (1..n) |i| post_order[i - 1] = @intCast(i);
    post_order[n - 1] = 0;

    // ── Step 1: Parents ────────────────────────────────────────────────────────
    // Fast path: parser pre-captured parents at addNode time via setChildParents.
    // Fallback: forward scan over the already-built tree (cold but correct).
    if (tree.parents.len == n) {
        @memcpy(parents, tree.parents[0..n]);
    } else {
        @memset(parents, NONE);
        const tags  = tree.nodes.items(.tag);
        const data  = tree.nodes.items(.data);
        const extra = tree.extra_data;
        for (0..n) |i| {
            setChildParents(parents, extra, tags[i], data[i], @intCast(i));
        }
    }

    // ── Step 2+3a: min_tok forward pass + counting (fused) ───────────────────
    // min_tok[i] is final at iteration i (all children j<i have propagated).
    const min_tok = try alloc.alloc(u32, n);
    const main_tokens = tree.nodes.items(.main_token);
    @memcpy(min_tok, main_tokens[0..n]);

    // Pre-allocate counts using token count (safe upper bound for any min_tok value).
    const counts = try alloc.alloc(u32, tree.tokens.len + 1);
    defer alloc.free(counts);
    @memset(counts, 0);

    var max_min_tok: u32 = 0;
    for (1..n) |i| {
        const v = min_tok[i];
        max_min_tok = @max(max_min_tok, v);
        counts[v] += 1;
        const p = parents[i];
        if (p != NONE) min_tok[p] = @min(min_tok[p], v);
    }

    // ── Step 3b: Counting sort prefix sum + scatter → pre_order ──────────────
    // Root (idx 0) always goes first.  For non-root nodes, descending-index
    // placement within each bucket gives parent (higher idx) before child.
    {
        var sum: u32 = 1; // position 0 reserved for root
        for (counts[0..max_min_tok + 1]) |*c| { const old = c.*; c.* = sum; sum += old; }
        pre_order[0] = 0;
        var ii: usize = n;
        while (ii > 1) {
            ii -= 1;
            const k = min_tok[ii];
            pre_order[counts[k]] = @intCast(ii);
            counts[k] += 1;
        }
    }

    // ── Step 4: dfs_events via ancestor-stack walk ────────────────────────────
    {
        // Raw slice stack avoids ArrayList overhead (capacity checks, optional unwrapping).
        const stk = try alloc.alloc(u32, n);
        defer alloc.free(stk);
        var stk_top: usize = 0;
        var ei: u32 = 0;
        for (pre_order) |node| {
            const parent = parents[node];
            // For nodes with a recorded parent: pop the stack until that parent is
            // on top, emitting exit events for the popped ancestors.
            // For orphan nodes (parent == NONE — root, or a child whose parent the
            // parser failed to record like some TS type annotations): DON'T pop the
            // stack hunting for a NONE that isn't there.  Instead treat the orphan
            // as a child of the current stack top so the DFS shape stays consistent
            // and downstream rule traversal doesn't see fake ancestor exits.
            if (parent != NONE) {
                while (stk_top > 0 and parent != stk[stk_top - 1]) {
                    stk_top -= 1;
                    dfs_events[ei] = ~@as(i32, @intCast(stk[stk_top]));
                    ei += 1;
                }
            }
            dfs_events[ei] = @intCast(node);
            ei += 1;
            stk[stk_top] = node;
            stk_top += 1;
        }
        while (stk_top > 0) {
            stk_top -= 1;
            dfs_events[ei] = ~@as(i32, @intCast(stk[stk_top]));
            ei += 1;
        }
    }

    // ── Resolved parents (post grouping_expr / ts_parenthesized_type skip) ─
    // JS-side `nodeView` transparently unwraps grouping_expr and
    // ts_parenthesized_type, so the ESTree-visible parent of a node whose
    // direct parent is a grouping_expr is the grouping's own parent. The JS
    // `get parent` slow path used to walk this chain on every first access;
    // pre-baking it here turns that walk into a single typed-array read.
    const resolved_parents = try alloc.alloc(u32, n);
    {
        const tags = tree.nodes.items(.tag);
        for (0..n) |i| {
            var p = parents[i];
            var guard: u32 = 0;
            while (p != NONE and (tags[p] == .grouping_expr or tags[p] == .ts_parenthesized_type)) {
                p = parents[p];
                guard += 1;
                if (guard > 64) { p = NONE; break; }
            }
            resolved_parents[i] = p;
        }
    }

    // ── Type overrides (ESTree-shape `type` disambiguation) ────────────────
    // Pre-bake the result of JS-side `_computeNodeType` into a u8 per node so
    // the JS adapter skips its per-node switch + token-text matching. Slot 0
    // means "no override; use TAG_NAMES[tag]" (the common case).
    const type_overrides = try alloc.alloc(u8, n);
    @memset(type_overrides, 0);
    {
        const tags = tree.nodes.items(.tag);
        const node_main_tokens = tree.nodes.items(.main_token);
        const data = tree.nodes.items(.data);
        const tok_starts = tree.tokens.items(.start);
        const tok_lens = tree.tokens.items(.len);
        const source = tree.source;
        for (0..n) |i| {
            switch (tags[i]) {
                .identifier, .property_ident => {
                    const tok = node_main_tokens[i];
                    const start = tok_starts[tok];
                    if (start < source.len and source[start] == '#') {
                        type_overrides[i] = @intFromEnum(TypeOverride.private_identifier);
                    }
                },
                .method_def, .getter_def, .setter_def,
                .computed_method_def, .computed_getter_def, .computed_setter_def,
                => {
                    // Same as the streaming-path arm above: getters/setters in
                    // object literals are Property nodes, not MethodDefinitions.
                    const p = parents[i];
                    if (p != NONE) {
                        const ptag = tags[p];
                        if (ptag == .object_literal or ptag == .object_pattern) {
                            type_overrides[i] = @intFromEnum(TypeOverride.property);
                        }
                    }
                },
                .import_decl => {
                    if (data[i].lhs == .none and data[i].rhs != .none) {
                        type_overrides[i] = @intFromEnum(TypeOverride.ts_import_equals_declaration);
                    }
                },
                .block_stmt => {
                    const p = parents[i];
                    if (p != NONE) {
                        const ptag = tags[p];
                        if (ptag == .ts_namespace_decl or ptag == .ts_module_decl) {
                            type_overrides[i] = @intFromEnum(TypeOverride.ts_module_block);
                        }
                    }
                },
                .ts_type_reference => {
                    if (data[i].rhs == .none) {
                        const tok = node_main_tokens[i];
                        const start = tok_starts[tok];
                        const len = tok_lens[tok];
                        if (start + len <= source.len) {
                            const text = source[start .. start + len];
                            if (computeTsTypeRefOverride(text)) |ov| {
                                type_overrides[i] = @intFromEnum(ov);
                            }
                        }
                    }
                },
                // `new Foo<T>()` is parsed as call_expr(ts_instantiation_expr(new_expr(callee,NONE),typeArgs),args).
                // Present it to ESLint rules as NewExpression so callee-type checks pass.
                .call_expr => {
                    const lhs = data[i].lhs;
                    if (lhs != .none and tags[@intFromEnum(lhs)] == .ts_instantiation_expr) {
                        const inner = data[@intFromEnum(lhs)].lhs;
                        if (inner != .none and tags[@intFromEnum(inner)] == .new_expr and
                            data[@intFromEnum(inner)].rhs == .none)
                        {
                            type_overrides[i] = @intFromEnum(TypeOverride.new_expression);
                        }
                    }
                },
                // ES2024 auto-accessor class field or abstract class property.
                .property_def, .computed_property_def => {
                    const tok = node_main_tokens[i];
                    var has_accessor = false;
                    var has_abstract = false;
                    var j: i32 = @as(i32, @intCast(tok)) - 1;
                    while (j >= 0) : (j -= 1) {
                        const k = @as(usize, @intCast(j));
                        const ps = tok_starts[k];
                        const pl = tok_lens[k];
                        if (ps + pl > source.len) break;
                        const txt = source[ps..ps + pl];
                        if (std.mem.eql(u8, txt, "accessor")) { has_accessor = true; }
                        else if (std.mem.eql(u8, txt, "abstract")) { has_abstract = true; }
                        else if (std.mem.eql(u8, txt, "public") or
                                 std.mem.eql(u8, txt, "private") or
                                 std.mem.eql(u8, txt, "protected") or
                                 std.mem.eql(u8, txt, "readonly") or
                                 std.mem.eql(u8, txt, "static") or
                                 std.mem.eql(u8, txt, "declare") or
                                 std.mem.eql(u8, txt, "override")) {}
                        else { break; }
                    }
                    if (has_accessor and has_abstract) {
                        type_overrides[i] = @intFromEnum(TypeOverride.ts_abstract_accessor_property);
                    } else if (has_accessor) {
                        type_overrides[i] = @intFromEnum(TypeOverride.accessor_property);
                    } else if (has_abstract) {
                        type_overrides[i] = @intFromEnum(TypeOverride.ts_abstract_property_definition);
                    }
                },
                else => {},
            }
        }
    }

    // ── Parent-synthesis kinds ─────────────────────────────────────────────
    // Pre-bake the JS `get parent` post-resolve dispatch (see ParentKind).
    const parent_kinds = try alloc.alloc(u8, n);
    @memset(parent_kinds, 0);
    {
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);
        for (0..n) |i| {
            const rp = resolved_parents[i];
            if (rp == NONE) continue;
            const this_tag = tags[i];

            // Mirror of the kind=1 detection in the streaming arm above.
            const is_optional_self_p = this_tag == .optional_member_expr or
                this_tag == .optional_computed_member_expr or
                this_tag == .optional_call_expr;
            var chain_contains_optional_p = is_optional_self_p;
            if (!is_optional_self_p and (this_tag == .member_expr or
                this_tag == .computed_member_expr or this_tag == .call_expr))
            {
                var c2 = data[i].lhs;
                var cguard2: u32 = 0;
                while (c2 != .none and cguard2 < 128) : (cguard2 += 1) {
                    const ci2 = c2.toInt();
                    const ct2 = tags[ci2];
                    if (ct2 == .optional_member_expr or ct2 == .optional_computed_member_expr or
                        ct2 == .optional_call_expr) { chain_contains_optional_p = true; break; }
                    if (ct2 == .grouping_expr or ct2 == .member_expr or
                        ct2 == .computed_member_expr or ct2 == .call_expr)
                    { c2 = data[ci2].lhs; continue; }
                    break;
                }
            }
            if (chain_contains_optional_p) {
                var dp = parents[i];
                var dguard: u32 = 0;
                while (dp != NONE and tags[dp] == .grouping_expr) {
                    dp = parents[dp];
                    dguard += 1;
                    if (dguard > 64) { dp = NONE; break; }
                }
                var is_chain_child = false;
                if (dp != NONE) {
                    const dpt = tags[dp];
                    const is_optional = dpt == .optional_member_expr or
                        dpt == .optional_computed_member_expr or
                        dpt == .optional_call_expr;
                    const is_middle = dpt == .member_expr or
                        dpt == .computed_member_expr or
                        dpt == .call_expr;
                    if ((is_optional or is_middle) and data[dp].lhs.toInt() == @as(u32, @intCast(i))) {
                        is_chain_child = true;
                    }
                }
                if (!is_chain_child) {
                    parent_kinds[i] = @intFromEnum(ParentKind.chain_expression);
                    continue;
                }
            }

            const pt = tags[rp];
            switch (pt) {
                .method_def, .getter_def, .setter_def, .constructor_def,
                .computed_method_def, .computed_getter_def, .computed_setter_def => {
                    if (data[rp].lhs.toInt() != @as(u32, @intCast(i))) {
                        parent_kinds[i] = @intFromEnum(ParentKind.method_value);
                        continue;
                    }
                },
                .object_pattern => {
                    if (this_tag == .assignment_pattern or this_tag == .identifier) {
                        parent_kinds[i] = @intFromEnum(ParentKind.object_pattern_property);
                        continue;
                    }
                },
                .jsx_self_closing => {
                    if (this_tag == .jsx_attribute or this_tag == .jsx_spread_attribute) {
                        parent_kinds[i] = @intFromEnum(ParentKind.jsx_opening_element);
                        continue;
                    }
                },
                .ts_enum_decl => {
                    if (this_tag == .ts_enum_member) {
                        parent_kinds[i] = @intFromEnum(ParentKind.ts_enum_body);
                        continue;
                    }
                },
                .ts_interface_decl => {
                    if (this_tag == .ts_method_signature or
                        this_tag == .ts_property_signature or
                        this_tag == .ts_call_signature or
                        this_tag == .ts_construct_signature or
                        this_tag == .ts_index_signature)
                    {
                        parent_kinds[i] = @intFromEnum(ParentKind.ts_interface_body);
                        continue;
                    }
                },
                else => {},
            }

            if (this_tag == .ts_type_parameter) {
                parent_kinds[i] = @intFromEnum(ParentKind.ts_type_parameter_declaration);
                continue;
            }
        }
    }

    return .{ .parents = parents, .pre_order = pre_order, .post_order = post_order, .dfs_events = dfs_events, .min_tok = min_tok, .resolved_parents = resolved_parents, .type_overrides = type_overrides, .parent_kinds = parent_kinds };
}

/// Match a TSTypeReference's main-token text against TS keyword type names
/// and literal-type sigils, returning the corresponding override slot.
/// Mirrors the `_TS_KW_TYPES` table + literal sigil checks in the JS adapter.
fn computeTsTypeRefOverride(text: []const u8) ?TypeOverride {
    if (text.len == 0) return null;
    // Whitespace trim is unnecessary here — main-token text is already
    // trimmed by the lexer for identifier/keyword tokens.
    const TsKw = struct { name: []const u8, ov: TypeOverride };
    const kws = [_]TsKw{
        .{ .name = "any", .ov = .ts_any_keyword },
        .{ .name = "bigint", .ov = .ts_bigint_keyword },
        .{ .name = "boolean", .ov = .ts_boolean_keyword },
        .{ .name = "intrinsic", .ov = .ts_intrinsic_keyword },
        .{ .name = "never", .ov = .ts_never_keyword },
        .{ .name = "null", .ov = .ts_null_keyword },
        .{ .name = "number", .ov = .ts_number_keyword },
        .{ .name = "object", .ov = .ts_object_keyword },
        .{ .name = "string", .ov = .ts_string_keyword },
        .{ .name = "symbol", .ov = .ts_symbol_keyword },
        .{ .name = "this", .ov = .ts_this_type },
        .{ .name = "undefined", .ov = .ts_undefined_keyword },
        .{ .name = "unknown", .ov = .ts_unknown_keyword },
        .{ .name = "void", .ov = .ts_void_keyword },
    };
    for (kws) |kw| {
        if (std.mem.eql(u8, text, kw.name)) return kw.ov;
    }
    // Literal-type sigils: matches JS `text.charCodeAt(0)` checks for
    // string/template/numeric/boolean/negative-numeric literal type refs.
    const c = text[0];
    if (c == '\'' or c == '"' or c == '`' or (c >= '0' and c <= '9') or c == '-') {
        return .ts_literal_type;
    }
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) {
        return .ts_literal_type;
    }
    return null;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Set parents[child] = parent. No-op for .none or out-of-range children.
inline fn sp(parents: []u32, child: NodeIndex, parent: u32) void {
    if (child == .none) return;
    const ci = child.toInt();
    if (ci < parents.len) parents[ci] = parent;
}

/// Set parents[child] = parent for every NodeIndex in extra[start..end].
inline fn spSub(parents: []u32, extra: []const u32, start: u32, end: u32, parent: u32) void {
    if (start >= end or end > extra.len) return;
    for (extra[start..end]) |ci| sp(parents, @enumFromInt(ci), parent);
}

/// Read an extra-data struct from the flat u32 array without going through Ast.
inline fn extraData(comptime T: type, extra: []const u32, index: u32) T {
    const fields = @typeInfo(T).@"struct".fields;
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        const raw: u32 = extra[index + i];
        @field(result, field.name) = switch (field.type) {
            NodeIndex => @enumFromInt(raw),
            u32       => raw,
            else      => @compileError("unsupported extra field type: " ++ @typeName(field.type)),
        };
    }
    return result;
}
// Force rebuild Thu May 28 20:41:00 +08 2026
