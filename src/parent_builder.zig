//! Parent-pointer construction for the AST — the parser-side primitive.
//!
//! `setChildParents` writes parents[child] = parent_idx from a node's structure.
//! `buildParentsOnly` runs a single forward scan over an already-built tree,
//! then replays `parent_fixups` for the few non-structural links. child_idx <
//! parent_idx for all non-root nodes (bottom-up build), so one pass suffices.
//! The parser does not build parents — semantic calls this on demand.
//!
//! The traversal + ESTree bridge that consumes these parents (pre_order,
//! post_order, dfs_events, resolved_parents, type_overrides) lives in Ez's
//! `cli/traversal_builder.zig`: it shapes a JS-linter visit stream over the
//! serialized buffer and has no place in a general parser.
const std = @import("std");
const ast_mod = @import("ast.zig");
const meta_compat = @import("meta_compat.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const SubRange = ast_mod.SubRange;

pub const NONE: u32 = std.math.maxInt(u32);

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
            if (ed.type_params_end > ed.type_params) {
                spSub(parents, extra, ed.type_params, ed.type_params_end, idx);
            }
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
        .ts_named_tuple_member => {
            // lhs = element type; rhs is an optional flag (.root/.none), not a node.
            sp(parents, lhs, idx);
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

/// Quick path: produce JUST the `parents` array (the only thing needed to
/// start writeSemanticData) in ~0.3ms instead of waiting for the full ~10ms
/// buildTraversal.
/// @returns owned
pub fn buildParentsOnly(tree: *const Ast, alloc: std.mem.Allocator) ![]u32 {
    const n = tree.nodes.len;
    const parents = try alloc.alloc(u32, n);
    if (n == 0) return parents;
    @memset(parents, NONE);
    const tags  = tree.nodes.items(.tag);
    const data  = tree.nodes.items(.data);
    const extra = tree.extra_data;
    for (0..n) |i| {
        setChildParents(parents, extra, tags[i], data[i], @intCast(i));
    }
    // Replay non-structural parent links the forward scan can't derive
    // (e.g. type annotations on destructured params). Flat (child, parent).
    var fi: usize = 0;
    while (fi + 1 < tree.parent_fixups.len) : (fi += 2) {
        const child = tree.parent_fixups[fi];
        if (child < n) parents[child] = tree.parent_fixups[fi + 1];
    }
    return parents;
}


// ── setChildParents primitives ────────────────────────────────────────────

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
    var result: T = undefined;
    inline for (0..meta_compat.fieldCount(T)) |i| {
        const name = comptime meta_compat.structFieldName(T, i);
        const FieldT = @FieldType(T, name);
        const raw: u32 = extra[index + i];
        @field(result, name) = switch (FieldT) {
            NodeIndex => @enumFromInt(raw),
            u32       => raw,
            else      => @compileError("unsupported extra field type: " ++ @typeName(FieldT)),
        };
    }
    return result;
}
