//! AST pretty-printer for Ez.
//!
//! Usage:
//!     try debug.dumpAst(&tree, writer);
//!
//! Produces indented tree output like:
//!
//!     root
//!       fn_decl "foo"
//!         formal_parameters
//!           identifier "a"
//!           identifier "b"
//!         block_stmt
//!           return_stmt
//!             add
//!               identifier "a"
//!               identifier "b"

const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const ExtraIndex = @import("ast.zig").ExtraIndex;
const SubRange = @import("ast.zig").SubRange;
const IfData = @import("ast.zig").IfData;
const ForData = @import("ast.zig").ForData;
const ForInOfData = @import("ast.zig").ForInOfData;
const TryData = @import("ast.zig").TryData;
const FnData = @import("ast.zig").FnData;
const ClassData = @import("ast.zig").ClassData;
const ArrowData = @import("ast.zig").ArrowData;
const Conditional = @import("ast.zig").Conditional;
const ImportData = @import("ast.zig").ImportData;
const MethodData = @import("ast.zig").MethodData;
const PropertyData = @import("ast.zig").PropertyData;
const InterfaceData = @import("ast.zig").InterfaceData;
const EnumData = @import("ast.zig").EnumData;
const JsxElementData = @import("ast.zig").JsxElementData;
const JsxOpeningData = @import("ast.zig").JsxOpeningData;
const TokenIndex = @import("ast.zig").TokenIndex;

/// Dump the full AST to `writer` starting from the root node.
pub fn dumpAst(tree: *const Ast, writer: anytype) !void {
    try dumpNode(tree, NodeIndex.root, 0, writer);
}

fn dataToSubRange(data: Node.Data) SubRange {
    return .{ .start = @intFromEnum(data.lhs), .end = @intFromEnum(data.rhs) };
}

/// Recursively dump a single node and its children.
fn dumpNode(tree: *const Ast, index: NodeIndex, indent: u32, writer: anytype) anyerror!void {
    if (index == .none) return;

    const tag = tree.nodeTag(index);
    const data = tree.nodeData(index);
    const main_tok = tree.nodeMainToken(index);

    // Write indentation
    try writeIndent(writer, indent);

    // Write tag name
    try writer.writeAll(@tagName(tag));

    // Write token text annotation for leaf/named nodes
    switch (tag) {
        .identifier,
        .number_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .regex_literal,
        .bigint_literal,
        .template_element,
        => {
            const text = tree.tokenText(main_tok);
            try writer.print(" \"{s}\"", .{text});
        },
        .break_label,
        .continue_label,
        .labeled_stmt,
        .ts_named_tuple_member,
        => {
            const text = tree.tokenText(main_tok);
            try writer.print(" \"{s}\"", .{text});
        },
        else => {},
    }

    try writer.writeByte('\n');

    // Recurse into children based on tag
    const child_indent = indent + 2;

    switch (tag) {
        // ── Program ──────────────────────────────────────────
        .root, .block_stmt => {
            // lhs/rhs directly encode SubRange start/end
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .empty_stmt => {},
        .expression_stmt => {
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .if_stmt => {
            // lhs = condition, rhs = consequent
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .if_else_stmt => {
            // lhs = condition, rhs = extra index to IfData
            try dumpNode(tree, data.lhs, child_indent, writer);
            const if_data = tree.extraData(IfData, @intFromEnum(data.rhs));
            try dumpNode(tree, if_data.consequent, child_indent, writer);
            try dumpNode(tree, if_data.alternate, child_indent, writer);
        },
        .while_stmt => {
            // lhs = condition, rhs = body
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .do_while_stmt => {
            // lhs = body, rhs = condition
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .for_stmt => {
            // lhs = extra index to ForData, rhs = body
            const for_data = tree.extraData(ForData, @intFromEnum(data.lhs));
            try dumpNode(tree, for_data.init, child_indent, writer);
            try dumpNode(tree, for_data.condition, child_indent, writer);
            try dumpNode(tree, for_data.update, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .for_in_stmt, .for_of_stmt, .for_await_of_stmt => {
            // lhs = extra index to ForInOfData
            const fio = tree.extraData(ForInOfData, @intFromEnum(data.lhs));
            try dumpNode(tree, fio.binding, child_indent, writer);
            try dumpNode(tree, fio.expr, child_indent, writer);
            try dumpNode(tree, fio.body, child_indent, writer);
        },
        .switch_stmt => {
            // lhs = discriminant, rhs = extra index to SubRange of cases
            try dumpNode(tree, data.lhs, child_indent, writer);
            const range = tree.extraData(SubRange, @intFromEnum(data.rhs));
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .switch_case => {
            // lhs = test expr, rhs = extra index to SubRange of statements
            try dumpNode(tree, data.lhs, child_indent, writer);
            const range = tree.extraData(SubRange, @intFromEnum(data.rhs));
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .switch_default => {
            // lhs = none, rhs = extra index to SubRange of statements
            const range = tree.extraData(SubRange, @intFromEnum(data.rhs));
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .return_stmt => {
            // lhs = expression (or none)
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .throw_stmt => {
            // lhs = expression
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .break_stmt, .continue_stmt, .debugger_stmt => {
            // No children
        },
        .break_label, .continue_label => {
            // Label info is in main_token; no child nodes
        },
        .labeled_stmt => {
            // lhs = statement
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .try_stmt => {
            // lhs = block, rhs = extra index to TryData
            try dumpNode(tree, data.lhs, child_indent, writer);
            const try_data = tree.extraData(TryData, @intFromEnum(data.rhs));
            try dumpNode(tree, try_data.catch_node, child_indent, writer);
            try dumpNode(tree, try_data.finally_body, child_indent, writer);
        },
        .catch_clause => {
            // lhs = param (or none), rhs = body block
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .with_stmt => {
            // lhs = object expr, rhs = body
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },

        // ── Declarations ─────────────────────────────────────
        .var_decl, .let_decl, .const_decl => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .declarator => {
            // lhs = binding pattern/identifier, rhs = init (or none)
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
        .ts_declare_function => {
            // lhs = extra index to FnData
            const fn_data = tree.extraData(FnData, @intFromEnum(data.lhs));
            try dumpNode(tree, fn_data.name, child_indent, writer);
            const params_range = SubRange{ .start = fn_data.params, .end = fn_data.params_end };
            try dumpSubRange(tree, params_range, child_indent, writer);
            try dumpNode(tree, fn_data.body, child_indent, writer);
        },
        .class_decl => {
            // lhs = extra index to ClassData
            const cls = tree.extraData(ClassData, @intFromEnum(data.lhs));
            try dumpNode(tree, cls.name, child_indent, writer);
            try dumpNode(tree, cls.super_class, child_indent, writer);
            try dumpNode(tree, cls.body, child_indent, writer);
        },
        .class_body => {
            // lhs = body_start, rhs = body_end (SubRange)
            const body_range = SubRange{ .start = @intFromEnum(data.lhs), .end = @intFromEnum(data.rhs) };
            try dumpSubRange(tree, body_range, child_indent, writer);
        },

        // ── Module ───────────────────────────────────────────
        .import_decl => {
            // lhs = extra index to ImportData
            const imp = tree.extraData(ImportData, @intFromEnum(data.lhs));
            const spec_range = SubRange{ .start = imp.specifiers_start, .end = imp.specifiers_end };
            try dumpSubRange(tree, spec_range, child_indent, writer);
            // Print source string
            try writeIndent(writer, child_indent);
            try writer.print("source \"{s}\"\n", .{tree.tokenText(tree.nodeMainToken(imp.source))});
        },
        .import_specifier => {
            // lhs = imported name token, rhs = local name token
            // These are token indices stored as NodeIndex; print their text.
            try writeIndent(writer, child_indent);
            try writer.print("imported \"{s}\"\n", .{tree.tokenText(@intFromEnum(data.lhs))});
            try writeIndent(writer, child_indent);
            try writer.print("local \"{s}\"\n", .{tree.tokenText(@intFromEnum(data.rhs))});
        },
        .import_default_specifier => {
            // lhs = local name token
            try writeIndent(writer, child_indent);
            try writer.print("local \"{s}\"\n", .{tree.tokenText(@intFromEnum(data.lhs))});
        },
        .import_namespace_specifier => {
            // lhs = local name token
            try writeIndent(writer, child_indent);
            try writer.print("local \"{s}\"\n", .{tree.tokenText(@intFromEnum(data.lhs))});
        },
        .export_named => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            // OR lhs = single declaration node, rhs = .none
            if (data.rhs != .none) {
                const range = dataToSubRange(data);
                try dumpSubRange(tree, range, child_indent, writer);
            } else {
                try dumpNode(tree, data.lhs, child_indent, writer);
            }
        },
        .export_named_from => {
            // lhs = extra index to ImportData { specifiers_start, specifiers_end, source }
            const import_data = tree.extraData(@import("ast.zig").ImportData, @intFromEnum(data.lhs));
            try writeIndent(writer, child_indent);
            try writer.print("source \"{s}\"\n", .{tree.tokenText(tree.nodeMainToken(import_data.source))});
            try dumpSubRange(tree, .{ .start = import_data.specifiers_start, .end = import_data.specifiers_end }, child_indent, writer);
        },
        .export_default_expr => {
            // lhs = expression
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .export_default_fn => {
            // lhs = fn_decl node
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .export_default_class => {
            // lhs = class_decl node
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .export_all => {
            // lhs = source string_literal node, rhs = exported name node (or none)
            try writeIndent(writer, child_indent);
            try writer.print("source \"{s}\"\n", .{tree.tokenText(tree.nodeMainToken(data.lhs))});
            if (data.rhs != .none) {
                try writeIndent(writer, child_indent);
                try writer.print("exported \"{s}\"\n", .{tree.tokenText(tree.nodeMainToken(data.rhs))});
            }
        },
        .export_specifier => {
            // lhs = local name token, rhs = exported name token
            try writeIndent(writer, child_indent);
            try writer.print("local \"{s}\"\n", .{tree.tokenText(@intFromEnum(data.lhs))});
            try writeIndent(writer, child_indent);
            try writer.print("exported \"{s}\"\n", .{tree.tokenText(@intFromEnum(data.rhs))});
        },

        // ── Literals (leaf nodes — no children) ─────────────
        .identifier,
        .number_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .regex_literal,
        .bigint_literal,
        .this_expr,
        .super_expr,
        .template_element,
        .import_meta,
        .new_target,
        => {},

        // ── Compound expressions ─────────────────────────────
        .array_literal => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .object_literal => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .property => {
            // lhs = key, rhs = value
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .shorthand_property => {
            // lhs = identifier node
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .computed_property => {
            // lhs = computed key, rhs = value
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .spread_element => {
            // lhs = argument
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .template_literal => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .tagged_template => {
            // lhs = tag expr, rhs = template_literal node
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },

        // ── Function/Class expressions ───────────────────────
        .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr => {
            // lhs = extra index to FnData
            const fn_data = tree.extraData(FnData, @intFromEnum(data.lhs));
            try dumpNode(tree, fn_data.name, child_indent, writer);
            const params_range = SubRange{ .start = fn_data.params, .end = fn_data.params_end };
            try dumpSubRange(tree, params_range, child_indent, writer);
            try dumpNode(tree, fn_data.body, child_indent, writer);
        },
        .class_expr => {
            // lhs = extra index to ClassData
            const cls = tree.extraData(ClassData, @intFromEnum(data.lhs));
            try dumpNode(tree, cls.name, child_indent, writer);
            try dumpNode(tree, cls.super_class, child_indent, writer);
            try dumpNode(tree, cls.body, child_indent, writer);
        },
        .arrow_fn, .async_arrow_fn => {
            // lhs = extra index to ArrowData
            const arrow = tree.extraData(ArrowData, @intFromEnum(data.lhs));
            const params_range = SubRange{ .start = arrow.params_start, .end = arrow.params_end };
            try dumpSubRange(tree, params_range, child_indent, writer);
            try dumpNode(tree, arrow.body, child_indent, writer);
        },

        // ── Unary expressions ────────────────────────────────
        .unary_plus,
        .unary_minus,
        .bitwise_not,
        .logical_not,
        .typeof_expr,
        .void_expr,
        .delete_expr,
        .prefix_inc,
        .prefix_dec,
        .postfix_inc,
        .postfix_dec,
        .await_expr,
        .yield_expr,
        .yield_delegate,
        => {
            // lhs = operand
            try dumpNode(tree, data.lhs, child_indent, writer);
        },

        // ── Binary expressions ───────────────────────────────
        .add,
        .subtract,
        .multiply,
        .divide,
        .modulo,
        .exponentiate,
        .equal,
        .not_equal,
        .strict_equal,
        .strict_not_equal,
        .less_than,
        .greater_than,
        .less_equal,
        .greater_equal,
        .instanceof_expr,
        .in_expr,
        .bitwise_and,
        .bitwise_or,
        .bitwise_xor,
        .shift_left,
        .shift_right,
        .unsigned_shift_right,
        .logical_and,
        .logical_or,
        .nullish_coalesce,
        => {
            // lhs = left operand, rhs = right operand
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },

        // ── Assignment expressions ───────────────────────────
        .assign,
        .add_assign,
        .sub_assign,
        .mul_assign,
        .div_assign,
        .mod_assign,
        .exp_assign,
        .and_assign,
        .or_assign,
        .xor_assign,
        .shl_assign,
        .shr_assign,
        .ushr_assign,
        .logical_and_assign,
        .logical_or_assign,
        .nullish_assign,
        => {
            // lhs = target, rhs = value
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },

        // ── Other expressions ────────────────────────────────
        .conditional => {
            // lhs = condition, rhs = extra index to Conditional
            try dumpNode(tree, data.lhs, child_indent, writer);
            const cond = tree.extraData(Conditional, @intFromEnum(data.rhs));
            try dumpNode(tree, cond.consequent, child_indent, writer);
            try dumpNode(tree, cond.alternate, child_indent, writer);
        },
        .call_expr, .optional_call_expr => {
            // lhs = callee, rhs = extra index to SubRange of args
            try dumpNode(tree, data.lhs, child_indent, writer);
            const range = tree.extraData(SubRange, @intFromEnum(data.rhs));
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .new_expr => {
            // lhs = callee, rhs = extra index to SubRange of args (or none)
            try dumpNode(tree, data.lhs, child_indent, writer);
            if (data.rhs != .none) {
                const range = tree.extraData(SubRange, @intFromEnum(data.rhs));
                try dumpSubRange(tree, range, child_indent, writer);
            }
        },
        .member_expr, .optional_member_expr => {
            // lhs = object, rhs encodes property token
            try dumpNode(tree, data.lhs, child_indent, writer);
            try writeIndent(writer, child_indent);
            try writer.print(".\"{s}\"\n", .{tree.tokenText(@intFromEnum(data.rhs))});
        },
        .computed_member_expr, .optional_computed_member_expr => {
            // lhs = object, rhs = computed expression
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .sequence_expr => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .grouping_expr => {
            // lhs = inner expression
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .import_expr => {
            // lhs = source expression
            try dumpNode(tree, data.lhs, child_indent, writer);
        },

        // ── Patterns ─────────────────────────────────────────
        .array_pattern => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .object_pattern => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .assignment_pattern => {
            // lhs = target, rhs = default value
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .rest_element => {
            // lhs = argument
            try dumpNode(tree, data.lhs, child_indent, writer);
        },

        // ── Class members ────────────────────────────────────
        .method_def, .computed_method_def => {
            // lhs = key, rhs = extra index to MethodData
            try dumpNode(tree, data.lhs, child_indent, writer);
            const method = tree.extraData(MethodData, @intFromEnum(data.rhs));
            const params_range = SubRange{ .start = method.params_start, .end = method.params_end };
            try dumpSubRange(tree, params_range, child_indent, writer);
            try dumpNode(tree, method.body, child_indent, writer);
        },
        .property_def, .computed_property_def => {
            // lhs = key, rhs = PropertyData extra index
            try dumpNode(tree, data.lhs, child_indent, writer);
            const prop = tree.extraData(PropertyData, @intFromEnum(data.rhs));
            try dumpNode(tree, prop.value, child_indent, writer);
            try dumpNode(tree, prop.type_annotation, child_indent, writer);
        },
        .static_block => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .getter_def, .computed_getter_def => {
            // lhs = key, rhs = extra index to MethodData
            try dumpNode(tree, data.lhs, child_indent, writer);
            const method = tree.extraData(MethodData, @intFromEnum(data.rhs));
            const params_range = SubRange{ .start = method.params_start, .end = method.params_end };
            try dumpSubRange(tree, params_range, child_indent, writer);
            try dumpNode(tree, method.body, child_indent, writer);
        },
        .setter_def, .computed_setter_def => {
            // lhs = key, rhs = extra index to MethodData
            try dumpNode(tree, data.lhs, child_indent, writer);
            const method = tree.extraData(MethodData, @intFromEnum(data.rhs));
            const params_range = SubRange{ .start = method.params_start, .end = method.params_end };
            try dumpSubRange(tree, params_range, child_indent, writer);
            try dumpNode(tree, method.body, child_indent, writer);
        },
        .constructor_def => {
            // Same layout as method_def: lhs = key, rhs = extra index to MethodData
            try dumpNode(tree, data.lhs, child_indent, writer);
            const method = tree.extraData(MethodData, @intFromEnum(data.rhs));
            const params_range = SubRange{ .start = method.params_start, .end = method.params_end };
            try dumpSubRange(tree, params_range, child_indent, writer);
            try dumpNode(tree, method.body, child_indent, writer);
        },

        // ── Parameters ───────────────────────────────────────
        .formal_parameters => {
            // lhs = range.start, rhs = range.end (direct SubRange encoding)
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },

        // ── TypeScript declarations ──────────────────────────
        .ts_interface_decl => {
            const iface = tree.extraData(InterfaceData, @intFromEnum(data.lhs));
            if (iface.body_start != iface.body_end) {
                try dumpSubRange(tree, .{ .start = iface.body_start, .end = iface.body_end }, child_indent, writer);
            }
        },
        .ts_type_alias_decl => {},
        .ts_enum_decl => {
            const enum_data = tree.extraData(EnumData, @intFromEnum(data.lhs));
            const range = SubRange{ .start = enum_data.members_start, .end = enum_data.members_end };
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .ts_enum_member => {
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .ts_namespace_decl, .ts_module_decl => {
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },

        // ── TypeScript types (leaf-like in dump) ────────────
        .ts_type_annotation, .ts_typeof_type, .ts_keyof_type,
        .ts_infer_type, .ts_array_type, .ts_parenthesized_type,
        .ts_non_null_expr,
        => {
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .ts_type_reference, .ts_as_expr, .ts_satisfies_expr,
        .ts_type_assertion, .ts_indexed_access_type,
        .ts_type_predicate,
        => {
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .ts_union_type, .ts_intersection_type, .ts_tuple_type,
        .ts_type_literal, .ts_template_literal_type,
        => {
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },
        .ts_function_type, .ts_constructor_type, .ts_mapped_type,
        .ts_conditional_type, .ts_type_query, .ts_parameter_property,
        => {},
        .ts_named_tuple_member => {
            // lhs = element type; rhs is an optional flag, not a node.
            try dumpNode(tree, data.lhs, child_indent, writer);
        },

        // ── JSX ─────────────────────────────────────────────
        .jsx_element => {
            const jsx_data = tree.extraData(JsxElementData, @intFromEnum(data.lhs));
            try dumpNode(tree, jsx_data.opening, child_indent, writer);
            const children = SubRange{ .start = jsx_data.children_start, .end = jsx_data.children_end };
            try dumpSubRange(tree, children, child_indent, writer);
            try dumpNode(tree, jsx_data.closing, child_indent, writer);
        },
        .jsx_self_closing, .jsx_opening_element => {
            const jsx_open = tree.extraData(JsxOpeningData, @intFromEnum(data.lhs));
            try dumpNode(tree, jsx_open.name, child_indent, writer);
            const attrs = SubRange{ .start = jsx_open.attrs_start, .end = jsx_open.attrs_end };
            try dumpSubRange(tree, attrs, child_indent, writer);
        },
        .jsx_closing_element => try dumpNode(tree, data.lhs, child_indent, writer),
        .jsx_attribute => {
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .jsx_spread_attribute, .jsx_expression_container, .jsx_spread_child => {
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .jsx_text_node, .jsx_gap_node, .jsx_empty_expr, .jsx_identifier => {},
        .jsx_member_expr, .jsx_namespaced_name => {
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .jsx_fragment => {
            const range = dataToSubRange(data);
            try dumpSubRange(tree, range, child_indent, writer);
        },

        // ── Error recovery ───────────────────────────────────
        .error_node => {
            // Nothing more to dump; main_token marks the error position.
        },

        // ── Property names (real nodes, leaf) ────────────────
        .property_ident, .property_literal => {
            // main_token holds the name/string; no children to dump.
        },

        // ── TypeScript interface member kinds ─────────────────
        .ts_call_signature, .ts_construct_signature, .ts_method_signature => {
            // lhs = extra index to InterfaceSigData
            const ISD = @import("ast.zig").InterfaceSigData;
            const ed = tree.extraData(ISD, @intFromEnum(data.lhs));
            if (tag == .ts_method_signature) try dumpNode(tree, ed.key, child_indent, writer);
            for (tree.extra_data[ed.params_start..ed.params_end]) |param_idx| {
                try dumpNode(tree, @enumFromInt(param_idx), child_indent, writer);
            }
            try dumpNode(tree, ed.return_type, child_indent, writer);
        },
        .ts_property_signature => {
            // lhs = name node, rhs = type annotation (or .none)
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .ts_index_signature => {
            // lhs = param identifier, rhs = value type
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },

        // ── Decorator ─────────────────────────────────────────
        .decorator => {
            // lhs = expression node
            try dumpNode(tree, data.lhs, child_indent, writer);
        },
        .ts_instantiation_expr => {
            // lhs = expression, rhs = extra index to SubRange of type args
            try dumpNode(tree, data.lhs, child_indent, writer);
            if (data.rhs != .none) {
                const sr = tree.extraData(SubRange, @intFromEnum(data.rhs));
                try dumpSubRange(tree, sr, child_indent, writer);
            }
        },
        .ts_type_parameter => {
            // lhs = constraint (or none), rhs = default (or none)
            try dumpNode(tree, data.lhs, child_indent, writer);
            try dumpNode(tree, data.rhs, child_indent, writer);
        },
        .ts_import_type => {
            // No AST children.
        },
    }
}

/// Dump a SubRange of node indices from extra_data.
fn dumpSubRange(tree: *const Ast, range: SubRange, indent: u32, writer: anytype) anyerror!void {
    const slice = tree.extraSlice(range);
    for (slice) |raw| {
        const node_idx: NodeIndex = @enumFromInt(raw);
        try dumpNode(tree, node_idx, indent, writer);
    }
}

/// Write `n` spaces for indentation.
fn writeIndent(writer: anytype, n: u32) !void {
    const spaces = "                                                                ";
    var remaining = n;
    while (remaining > 0) {
        const batch = @min(remaining, spaces.len);
        try writer.writeAll(spaces[0..batch]);
        remaining -= batch;
    }
}

// ── Tests ────────────────────────────────────────────────────
test "writeIndent produces correct spaces" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try writeIndent(w, 4);
    const written = aw.written();
    try std.testing.expectEqualStrings("    ", written);
}
