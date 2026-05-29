const std = @import("std");
const NodeTag = @import("ast.zig").Node.Tag;

// ── Tag Count ────────────────────────────────────────────────────

pub const tag_count: u32 = @typeInfo(NodeTag).@"enum".fields.len;

// ── ESTree Name Table ────────────────────────────────────────────

/// Comptime-generated table mapping each Node.Tag ordinal to its
/// ESTree-compatible type name (null-terminated for C ABI).
pub const tag_names: [tag_count][*:0]const u8 = blk: {
    var names: [tag_count][*:0]const u8 = undefined;
    for (@typeInfo(NodeTag).@"enum".fields) |field| {
        names[field.value] = estreeNameForTag(@enumFromInt(field.value));
    }
    break :blk names;
};

fn estreeNameForTag(tag: NodeTag) [*:0]const u8 {
    return switch (tag) {
        // ── Program ──────────────────────────────────────────
        .root => "Program",

        // ── Statements ───────────────────────────────────────
        .block_stmt => "BlockStatement",
        .empty_stmt => "EmptyStatement",
        .expression_stmt => "ExpressionStatement",
        .if_stmt, .if_else_stmt => "IfStatement",
        .while_stmt => "WhileStatement",
        .do_while_stmt => "DoWhileStatement",
        .for_stmt => "ForStatement",
        .for_in_stmt => "ForInStatement",
        .for_of_stmt, .for_await_of_stmt => "ForOfStatement",
        .switch_stmt => "SwitchStatement",
        .switch_case, .switch_default => "SwitchCase",
        .return_stmt => "ReturnStatement",
        .throw_stmt => "ThrowStatement",
        .break_stmt, .break_label => "BreakStatement",
        .continue_stmt, .continue_label => "ContinueStatement",
        .labeled_stmt => "LabeledStatement",
        .try_stmt => "TryStatement",
        .catch_clause => "CatchClause",
        .debugger_stmt => "DebuggerStatement",
        .with_stmt => "WithStatement",

        // ── Declarations ─────────────────────────────────────
        .var_decl, .let_decl, .const_decl => "VariableDeclaration",
        .declarator => "VariableDeclarator",
        .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl => "FunctionDeclaration",
        .class_decl => "ClassDeclaration",
        .class_body => "ClassBody",

        // ── Module ───────────────────────────────────────────
        .import_decl => "ImportDeclaration",
        .import_specifier => "ImportSpecifier",
        .import_default_specifier => "ImportDefaultSpecifier",
        .import_namespace_specifier => "ImportNamespaceSpecifier",
        .export_named, .export_named_from => "ExportNamedDeclaration",
        .export_default_expr, .export_default_fn, .export_default_class => "ExportDefaultDeclaration",
        .export_all => "ExportAllDeclaration",
        .export_specifier => "ExportSpecifier",

        // ── Literals ─────────────────────────────────────────
        .identifier => "Identifier",
        .number_literal, .string_literal, .boolean_literal, .null_literal, .regex_literal, .bigint_literal => "Literal",
        .this_expr => "ThisExpression",
        .super_expr => "Super",

        // ── Compound ─────────────────────────────────────────
        .array_literal => "ArrayExpression",
        .object_literal => "ObjectExpression",
        .property, .shorthand_property, .computed_property => "Property",
        .spread_element => "SpreadElement",
        .template_literal => "TemplateLiteral",
        .tagged_template => "TaggedTemplateExpression",
        .template_element => "TemplateElement",

        // ── Function / Class Expressions ─────────────────────
        .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr => "FunctionExpression",
        .class_expr => "ClassExpression",
        .arrow_fn, .async_arrow_fn => "ArrowFunctionExpression",

        // ── Unary ────────────────────────────────────────────
        .unary_plus, .unary_minus, .bitwise_not, .logical_not, .typeof_expr, .void_expr, .delete_expr => "UnaryExpression",
        .prefix_inc, .prefix_dec, .postfix_inc, .postfix_dec => "UpdateExpression",
        .await_expr => "AwaitExpression",
        .yield_expr, .yield_delegate => "YieldExpression",

        // ── Binary Arithmetic / Comparison / Bitwise ─────────
        .add, .subtract, .multiply, .divide, .modulo, .exponentiate => "BinaryExpression",
        .equal, .not_equal, .strict_equal, .strict_not_equal => "BinaryExpression",
        .less_than, .greater_than, .less_equal, .greater_equal => "BinaryExpression",
        .instanceof_expr, .in_expr => "BinaryExpression",
        .bitwise_and, .bitwise_or, .bitwise_xor => "BinaryExpression",
        .shift_left, .shift_right, .unsigned_shift_right => "BinaryExpression",

        // ── Logical ──────────────────────────────────────────
        .logical_and, .logical_or, .nullish_coalesce => "LogicalExpression",

        // ── Assignment ───────────────────────────────────────
        .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign, .exp_assign => "AssignmentExpression",
        .and_assign, .or_assign, .xor_assign, .shl_assign, .shr_assign, .ushr_assign => "AssignmentExpression",
        .logical_and_assign, .logical_or_assign, .nullish_assign => "AssignmentExpression",

        // ── Other Expressions ────────────────────────────────
        .conditional => "ConditionalExpression",
        .call_expr, .optional_call_expr => "CallExpression",
        .new_expr => "NewExpression",
        .member_expr, .computed_member_expr, .optional_member_expr, .optional_computed_member_expr => "MemberExpression",
        .property_ident => "Identifier",
        .property_literal => "Literal",
        .sequence_expr => "SequenceExpression",
        .grouping_expr => "ParenthesizedExpression",
        .import_expr => "ImportExpression",
        .import_meta, .new_target => "MetaProperty",

        // ── Patterns ─────────────────────────────────────────
        .array_pattern => "ArrayPattern",
        .object_pattern => "ObjectPattern",
        .assignment_pattern => "AssignmentPattern",
        .rest_element => "RestElement",

        // ── Class Members ────────────────────────────────────
        .method_def, .getter_def, .setter_def, .constructor_def => "MethodDefinition",
        .computed_method_def, .computed_getter_def, .computed_setter_def => "MethodDefinition",
        .property_def, .computed_property_def => "PropertyDefinition",
        .static_block => "StaticBlock",

        // ── Parameters ───────────────────────────────────────
        .formal_parameters => "FormalParameters",

        // ── TypeScript Declarations ──────────────────────────
        .ts_interface_decl => "TSInterfaceDeclaration",
        .ts_type_alias_decl => "TSTypeAliasDeclaration",
        .ts_enum_decl => "TSEnumDeclaration",
        .ts_enum_member => "TSEnumMember",
        .ts_namespace_decl, .ts_module_decl => "TSModuleDeclaration",

        // ── TypeScript Types ─────────────────────────────────
        .ts_type_annotation => "TSTypeAnnotation",
        .ts_type_reference => "TSTypeReference",
        .ts_type_predicate => "TSTypePredicate",
        .ts_union_type => "TSUnionType",
        .ts_intersection_type => "TSIntersectionType",
        .ts_tuple_type => "TSTupleType",
        .ts_array_type => "TSArrayType",
        .ts_function_type => "TSFunctionType",
        .ts_constructor_type => "TSConstructorType",
        .ts_type_literal => "TSTypeLiteral",
        .ts_mapped_type => "TSMappedType",
        .ts_conditional_type => "TSConditionalType",
        .ts_infer_type => "TSInferType",
        .ts_typeof_type, .ts_type_query => "TSTypeQuery",
        .ts_keyof_type => "TSTypeOperator",
        .ts_indexed_access_type => "TSIndexedAccessType",
        .ts_template_literal_type => "TSTemplateLiteralType",
        .ts_parenthesized_type => "TSParenthesizedType",

        // ── TypeScript Expressions ───────────────────────────
        .ts_as_expr => "TSAsExpression",
        .ts_satisfies_expr => "TSSatisfiesExpression",
        .ts_non_null_expr => "TSNonNullExpression",
        .ts_type_assertion => "TSTypeAssertion",

        // ── TypeScript Other ─────────────────────────────────
        .ts_parameter_property => "TSParameterProperty",

        // ── JSX ──────────────────────────────────────────────
        .jsx_element, .jsx_self_closing => "JSXElement",
        .jsx_opening_element => "JSXOpeningElement",
        .jsx_closing_element => "JSXClosingElement",
        .jsx_attribute => "JSXAttribute",
        .jsx_spread_attribute => "JSXSpreadAttribute",
        .jsx_expression_container => "JSXExpressionContainer",
        .jsx_spread_child => "JSXSpreadChild",
        .jsx_text_node, .jsx_gap_node => "JSXText",
        .jsx_fragment => "JSXFragment",

        // ── Special ──────────────────────────────────────────
        .error_node => "ErrorNode",
        // Added at end to preserve existing ordinals
        .jsx_empty_expr => "JSXEmptyExpression",
        .jsx_identifier => "JSXIdentifier",
        .jsx_member_expr => "JSXMemberExpression",
        .jsx_namespaced_name => "JSXNamespacedName",

        // ── TypeScript interface member kinds ─────────────────
        .ts_call_signature => "TSCallSignatureDeclaration",
        .ts_construct_signature => "TSConstructSignatureDeclaration",
        .ts_method_signature => "TSMethodSignature",
        .ts_property_signature => "TSPropertySignature",
        .ts_index_signature => "TSIndexSignature",

        // ── Decorator ─────────────────────────────────────────
        .decorator => "Decorator",

        // ── TypeScript Declare ─────────────────────────────────
        .ts_declare_function => "TSDeclareFunction",
        .ts_instantiation_expr => "TSInstantiationExpression",
        .ts_type_parameter => "TSTypeParameter",
        .ts_import_type => "TSImportType",
    };
}

// ── C ABI Exports ────────────────────────────────────────────────

/// Returns the total number of AST node tag variants.
pub export fn ez_tag_count() u32 {
    return tag_count;
}

/// Returns the ESTree-compatible type name for a given tag index.
pub export fn ez_tag_name(index: u8) [*:0]const u8 {
    if (index >= tag_count) return "Unknown";
    return tag_names[index];
}

// ── Tests ────────────────────────────────────────────────────────

test "tag_names covers all tags" {
    // Verify every tag has a non-null name.
    for (0..tag_count) |i| {
        const name = tag_names[i];
        try std.testing.expect(name[0] != 0);
    }
}

test "known tag names" {
    try std.testing.expectEqualStrings("Program", std.mem.span(tag_names[@intFromEnum(NodeTag.root)]));
    try std.testing.expectEqualStrings("Identifier", std.mem.span(tag_names[@intFromEnum(NodeTag.identifier)]));
    try std.testing.expectEqualStrings("BinaryExpression", std.mem.span(tag_names[@intFromEnum(NodeTag.add)]));
    try std.testing.expectEqualStrings("JSXElement", std.mem.span(tag_names[@intFromEnum(NodeTag.jsx_element)]));
    try std.testing.expectEqualStrings("TSInterfaceDeclaration", std.mem.span(tag_names[@intFromEnum(NodeTag.ts_interface_decl)]));
}

test "ez_tag_count matches enum" {
    try std.testing.expectEqual(tag_count, @as(u32, @typeInfo(NodeTag).@"enum".fields.len));
}

test "ez_tag_name out of bounds" {
    try std.testing.expectEqualStrings("Unknown", std.mem.span(ez_tag_name(255)));
}
