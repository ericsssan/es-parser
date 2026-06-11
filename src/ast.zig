const std = @import("std");
const TokenTag = @import("token.zig").Tag;
const meta_compat = @import("meta_compat.zig");
const Span = @import("span.zig").Span;
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const ScopeEvent = @import("scope_events.zig").Event;

pub const ByteOffset = @import("span.zig").ByteOffset;

/// Index into the node array.
pub const NodeIndex = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(self: NodeIndex) ?u32 {
        return if (self == .none) null else @intFromEnum(self);
    }

    pub fn toInt(self: NodeIndex) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(i: u32) NodeIndex {
        return @enumFromInt(i);
    }
};

/// Index into the token array.
pub const TokenIndex = u32;

/// Index into the extra_data array.
pub const ExtraIndex = u32;

/// The AST node — 20 bytes per node with parent pointer.
/// Stored in a MultiArrayList for SoA layout.
pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    /// Extern struct for guaranteed C-compatible layout (needed for
    /// zero-copy JS buffer transfer — JS reads lhs/rhs at known offsets).
    pub const Data = extern struct {
        lhs: NodeIndex,
        rhs: NodeIndex,
    };

    /// ES2024 JavaScript AST node tags (~140 variants).
    pub const Tag = enum(u8) {
        // ── Program ────────────────────────────────────────────
        /// Top-level root node. lhs = extra index to SubRange of top-level statements
        root,

        // ── Statements ─────────────────────────────────────────
        /// { ... }. lhs = extra index to SubRange of statements
        block_stmt,
        /// ;
        empty_stmt,
        /// expr;  lhs = expression node
        expression_stmt,
        /// if (cond) consequent. lhs = condition, rhs = consequent
        if_stmt,
        /// if (cond) consequent else alternate. lhs = condition, rhs = extra index to IfData
        if_else_stmt,
        /// while (cond) body. lhs = condition, rhs = body
        while_stmt,
        /// do body while (cond). lhs = body, rhs = condition
        do_while_stmt,
        /// for (init; cond; update) body. lhs = extra index to ForData, rhs = body
        for_stmt,
        /// for (lhs in rhs) body. lhs = extra index to ForInOfData
        for_in_stmt,
        /// for (lhs of rhs) body. lhs = extra index to ForInOfData
        for_of_stmt,
        /// for await (lhs of rhs) body. lhs = extra index to ForInOfData
        for_await_of_stmt,
        /// switch (expr) { cases }. lhs = discriminant, rhs = extra index to SubRange of cases
        switch_stmt,
        /// case expr: stmts. lhs = test expr, rhs = extra index to SubRange of statements
        switch_case,
        /// default: stmts. lhs = none, rhs = extra index to SubRange of statements
        switch_default,
        /// return expr;  lhs = expression (or none)
        return_stmt,
        /// throw expr;  lhs = expression
        throw_stmt,
        /// break;
        break_stmt,
        /// break label;  main_token = break, lhs stores label token offset
        break_label,
        /// continue;
        continue_stmt,
        /// continue label;
        continue_label,
        /// label: stmt. lhs = statement
        labeled_stmt,
        /// try { } catch (e) { }. lhs = block, rhs = extra index to TryData
        try_stmt,
        /// catch (param) { body }. lhs = param (or none), rhs = body block
        catch_clause,
        /// debugger;
        debugger_stmt,
        /// with (expr) stmt. lhs = object expr, rhs = body
        with_stmt,

        // ── Declarations ───────────────────────────────────────
        /// var declarators. lhs = extra index to SubRange of declarators
        var_decl,
        /// let declarators.
        let_decl,
        /// const declarators.
        const_decl,
        /// name = init. lhs = binding pattern/identifier, rhs = init (or none)
        declarator,
        /// function name(params) { body }. lhs = extra index to FnData
        fn_decl,
        /// async function name(params) { body }.
        async_fn_decl,
        /// function* name(params) { body }.
        generator_fn_decl,
        /// async function* name(params) { body }.
        async_generator_fn_decl,
        /// class name extends superclass { body }. lhs = extra index to ClassData
        class_decl,

        // ── Module ─────────────────────────────────────────────
        /// import ... from '...'. lhs = extra index to ImportData
        import_decl,
        /// import { x as y }. lhs = imported name token, rhs = local name token
        import_specifier,
        /// import x (default import). lhs = local name token
        import_default_specifier,
        /// import * as x. lhs = local name token
        import_namespace_specifier,
        /// export { x, y }. lhs = range start, rhs = range end (no from).
        /// Also: export var/let/const/fn/class — lhs = decl, rhs = .none.
        export_named,
        /// export default expr. lhs = expression
        export_default_expr,
        /// export default function. lhs = fn_decl node
        export_default_fn,
        /// export default class. lhs = class_decl node
        export_default_class,
        /// export * from '...'. lhs = source string token
        export_all,
        /// export { x as y }. lhs = local name token, rhs = exported name token
        export_specifier,

        // ── Expressions — Literals ─────────────────────────────
        /// Identifier reference. main_token = identifier token
        identifier,
        /// 42, 3.14, etc. main_token = number token
        number_literal,
        /// "hello", 'world'. main_token = string token
        string_literal,
        /// true or false. main_token = true/false token
        boolean_literal,
        /// null. main_token = null token
        null_literal,
        /// /regex/flags. main_token = regex token
        regex_literal,
        /// 42n. main_token = bigint token
        bigint_literal,
        /// this.
        this_expr,
        /// super.
        super_expr,

        // ── Expressions — Compound ─────────────────────────────
        /// [a, b, c]. lhs = extra index to SubRange of elements
        array_literal,
        /// { a: b, c }. lhs = extra index to SubRange of properties
        object_literal,
        /// key: value. lhs = key, rhs = value
        property,
        /// { x } shorthand. lhs = identifier node
        shorthand_property,
        /// { [expr]: value }. lhs = computed key, rhs = value
        computed_property,
        /// ...expr. lhs = argument
        spread_element,
        /// `head${expr}middle${expr}tail`. lhs = extra index to SubRange of parts
        template_literal,
        /// tag`template`. lhs = tag expr, rhs = template_literal node
        tagged_template,
        /// Raw template part. main_token = template token
        template_element,

        // ── Expressions — Function/Class ───────────────────────
        /// function(params) { body }. lhs = extra index to FnData
        fn_expr,
        /// async function(params) { body }.
        async_fn_expr,
        /// function*(params) { body }.
        generator_fn_expr,
        /// async function*(params) { body }.
        async_generator_fn_expr,
        /// class [name] [extends] { body }.
        class_expr,
        /// (params) => body. lhs = extra index to ArrowData
        arrow_fn,
        /// async (params) => body.
        async_arrow_fn,

        // ── Expressions — Unary ────────────────────────────────
        /// +expr. lhs = operand
        unary_plus,
        /// -expr. lhs = operand
        unary_minus,
        /// ~expr. lhs = operand
        bitwise_not,
        /// !expr. lhs = operand
        logical_not,
        /// typeof expr. lhs = operand
        typeof_expr,
        /// void expr. lhs = operand
        void_expr,
        /// delete expr. lhs = operand
        delete_expr,
        /// ++expr. lhs = operand
        prefix_inc,
        /// --expr. lhs = operand
        prefix_dec,
        /// expr++. lhs = operand
        postfix_inc,
        /// expr--. lhs = operand
        postfix_dec,
        /// await expr. lhs = operand
        await_expr,
        /// yield expr. lhs = operand (or none)
        yield_expr,
        /// yield* expr. lhs = operand
        yield_delegate,

        // ── Expressions — Binary Arithmetic ────────────────────
        /// lhs + rhs
        add,
        /// lhs - rhs
        subtract,
        /// lhs * rhs
        multiply,
        /// lhs / rhs
        divide,
        /// lhs % rhs
        modulo,
        /// lhs ** rhs
        exponentiate,

        // ── Expressions — Binary Comparison ────────────────────
        /// lhs == rhs
        equal,
        /// lhs != rhs
        not_equal,
        /// lhs === rhs
        strict_equal,
        /// lhs !== rhs
        strict_not_equal,
        /// lhs < rhs
        less_than,
        /// lhs > rhs
        greater_than,
        /// lhs <= rhs
        less_equal,
        /// lhs >= rhs
        greater_equal,
        /// lhs instanceof rhs
        instanceof_expr,
        /// lhs in rhs
        in_expr,

        // ── Expressions — Binary Bitwise ───────────────────────
        /// lhs & rhs
        bitwise_and,
        /// lhs | rhs
        bitwise_or,
        /// lhs ^ rhs
        bitwise_xor,
        /// lhs << rhs
        shift_left,
        /// lhs >> rhs
        shift_right,
        /// lhs >>> rhs
        unsigned_shift_right,

        // ── Expressions — Binary Logical ───────────────────────
        /// lhs && rhs
        logical_and,
        /// lhs || rhs
        logical_or,
        /// lhs ?? rhs
        nullish_coalesce,

        // ── Expressions — Assignment ───────────────────────────
        /// lhs = rhs
        assign,
        /// lhs += rhs
        add_assign,
        /// lhs -= rhs
        sub_assign,
        /// lhs *= rhs
        mul_assign,
        /// lhs /= rhs
        div_assign,
        /// lhs %= rhs
        mod_assign,
        /// lhs **= rhs
        exp_assign,
        /// lhs &= rhs
        and_assign,
        /// lhs |= rhs
        or_assign,
        /// lhs ^= rhs
        xor_assign,
        /// lhs <<= rhs
        shl_assign,
        /// lhs >>= rhs
        shr_assign,
        /// lhs >>>= rhs
        ushr_assign,
        /// lhs &&= rhs
        logical_and_assign,
        /// lhs ||= rhs
        logical_or_assign,
        /// lhs ??= rhs
        nullish_assign,

        // ── Expressions — Other ────────────────────────────────
        /// cond ? then : else. lhs = condition, rhs = extra index to Conditional
        conditional,
        /// callee(args). lhs = callee, rhs = extra index to SubRange of args
        call_expr,
        /// new Ctor(args). lhs = callee, rhs = extra index to SubRange of args (or none)
        new_expr,
        /// obj.prop. lhs = object, rhs encodes property token
        member_expr,
        /// obj[expr]. lhs = object, rhs = computed expression
        computed_member_expr,
        /// obj?.prop. lhs = object, rhs encodes property token
        optional_member_expr,
        /// obj?.[expr]. lhs = object, rhs = computed expression
        optional_computed_member_expr,
        /// obj?.(args). lhs = callee, rhs = extra index to SubRange of args
        optional_call_expr,
        /// a, b, c. lhs = extra index to SubRange of expressions
        sequence_expr,
        /// (expr). lhs = inner expression
        grouping_expr,
        /// import(source). lhs = source expression
        import_expr,
        /// import.meta.
        import_meta,
        /// new.target.
        new_target,

        // ── Patterns ───────────────────────────────────────────
        /// [a, b, ...rest]. lhs = extra index to SubRange of elements
        array_pattern,
        /// { a, b: c }. lhs = extra index to SubRange of properties
        object_pattern,
        /// a = default. lhs = target, rhs = default value
        assignment_pattern,
        /// ...rest. lhs = argument
        rest_element,

        // ── Class Members ──────────────────────────────────────
        /// method(params) { body }. lhs = key, rhs = extra index to MethodData
        method_def,
        /// prop = value. lhs = key, rhs = extra index to PropertyData
        property_def,
        /// static { ... }. lhs = extra index to SubRange of statements
        static_block,
        /// get name() { body }. lhs = key, rhs = fn body data
        getter_def,
        /// set name(param) { body }. lhs = key, rhs = fn body data
        setter_def,
        /// constructor(params) { body }.
        constructor_def,
        /// [expr]() { body }. lhs = computed key expr, rhs = extra index to MethodData
        computed_method_def,
        /// [expr] = value. lhs = computed key expr, rhs = extra index to PropertyData
        computed_property_def,
        /// get [expr]() { body }.
        computed_getter_def,
        /// set [expr](param) { body }.
        computed_setter_def,

        // ── Parameters ─────────────────────────────────────────
        /// (a, b, c). lhs = extra index to SubRange of parameters
        formal_parameters,

        // ── TypeScript Declarations ────────────────────────────
        /// interface Name [extends ...] { ... }. lhs = extra index to InterfaceData
        ts_interface_decl,
        /// type Name = Type. lhs = extra index to TypeAliasData
        ts_type_alias_decl,
        /// enum Name { ... }. lhs = extra index to EnumData
        ts_enum_decl,
        /// name = value (inside enum). lhs = name node, rhs = value (or none)
        ts_enum_member,
        /// namespace Name { ... }. lhs = name, rhs = body block
        ts_namespace_decl,
        /// module Name { ... }. lhs = name, rhs = body block
        ts_module_decl,

        // ── TypeScript Types ──────────────────────────────────
        /// : Type  annotation. lhs = type node
        ts_type_annotation,
        /// Foo, Foo<T>. lhs = name node, rhs = type args SubRange extra (or none)
        ts_type_reference,
        /// x is Type. lhs = param name, rhs = type node
        ts_type_predicate,
        /// A | B. lhs = extra SubRange of types
        ts_union_type,
        /// A & B. lhs = extra SubRange of types
        ts_intersection_type,
        /// [A, B, C]. lhs = extra SubRange of types
        ts_tuple_type,
        /// T[]. lhs = element type
        ts_array_type,
        /// (params) => ReturnType. lhs = extra index to FnData
        ts_function_type,
        /// new (params) => Type. lhs = extra index to FnData
        ts_constructor_type,
        /// { members }. lhs = extra SubRange of members
        ts_type_literal,
        /// { [K in T]: V }. lhs = extra SubRange of contents
        ts_mapped_type,
        /// T extends U ? X : Y. lhs = extra index
        ts_conditional_type,
        /// infer T. lhs = type parameter
        ts_infer_type,
        /// typeof x. lhs = expression
        ts_typeof_type,
        /// keyof T. lhs = type
        ts_keyof_type,
        /// T[K]. lhs = object type, rhs = index type
        ts_indexed_access_type,
        /// `str${Type}`. lhs = extra SubRange of parts
        ts_template_literal_type,
        /// typeof import("x"). lhs = source
        ts_type_query,
        /// (Type). lhs = inner type
        ts_parenthesized_type,

        // ── TypeScript Expressions ────────────────────────────
        /// expr as Type. lhs = expression, rhs = type node
        ts_as_expr,
        /// expr satisfies Type. lhs = expression, rhs = type node
        ts_satisfies_expr,
        /// expr!  (non-null assertion). lhs = expression
        ts_non_null_expr,
        /// <Type>expr. lhs = type node, rhs = expression
        ts_type_assertion,

        // ── TypeScript Other ──────────────────────────────────
        /// Parameter property: public/private/protected/readonly param.
        /// lhs = parameter binding, rhs = default (or none)
        ts_parameter_property,

        // ── JSX ───────────────────────────────────────────────
        /// <tag attrs>children</tag>. lhs = extra index to JsxElementData
        jsx_element,
        /// <tag attrs />. lhs = extra index to JsxOpeningData
        jsx_self_closing,
        /// <tag attrs>. lhs = extra index to JsxOpeningData
        jsx_opening_element,
        /// </tag>. lhs = name node
        jsx_closing_element,
        /// name=value. lhs = name (identifier), rhs = value
        jsx_attribute,
        /// {...expr}. lhs = expression
        jsx_spread_attribute,
        /// {expr} inside JSX children. lhs = expression (or none for {})
        jsx_expression_container,
        /// {...expr} inside JSX children — JSXSpreadChild. lhs = expression
        jsx_spread_child,
        /// Raw text between JSX tags. main_token = jsx_text token
        jsx_text_node,
        /// <>children</>. lhs = extra SubRange of children
        jsx_fragment,

        // ── Special ────────────────────────────────────────────
        /// Error recovery node. main_token = position of error
        error_node,
        /// export { x, y } from 'source'. lhs = extra index to ImportData (specifiers + source), rhs = .none
        /// Added at end to preserve existing ordinals for JS T table compatibility.
        export_named_from,
        /// A name used as a property key, not a variable reference.
        /// main_token = identifier/keyword token.
        /// Created for: member expression property, import/export specifier names.
        /// Type=Identifier in ESTree. Does NOT create a reference in semantic analysis.
        property_ident,
        /// A string literal used as an import/export specifier name (ES2022).
        /// main_token = string_literal token. Type=Literal in ESTree.
        property_literal,
        /// Class body block. lhs = body_start, rhs = body_end (SubRange). main_token = l_brace
        class_body,
        /// Empty expression inside {}: {/*comment*/} or {}.
        /// main_token = l_brace, data.lhs = byte offset after '{', data.rhs = byte offset of '}'.
        jsx_empty_expr,
        /// JSX tag/attribute name identifier. Type=JSXIdentifier in ESTree.
        /// main_token = identifier token. No children.
        jsx_identifier,
        /// JSX member expression (Foo.Bar). Type=JSXMemberExpression in ESTree.
        /// main_token = dot token. lhs = object (jsx_identifier|jsx_member_expr), rhs = property (jsx_identifier).
        jsx_member_expr,
        /// JSX namespaced name (foo:bar). Type=JSXNamespacedName in ESTree.
        /// main_token = colon token. lhs = namespace (jsx_identifier), rhs = name (jsx_identifier).
        jsx_namespaced_name,
        /// Lexer-skipped gap (irregular whitespace) inside JSX children.
        /// lhs = gap_start_byte, rhs = gap_end_byte (both as NodeIndex.fromInt byte offsets).
        jsx_gap_node,

        // ── TypeScript interface member kinds ─────────────────────
        // Distinct tags eliminate JS-side type detection via charCode checks.
        /// Call signature: (): ReturnType. lhs = extra index to InterfaceSigData (key=.none)
        ts_call_signature,
        /// Construct signature: new(): ReturnType. lhs = extra index to InterfaceSigData (key=.none)
        ts_construct_signature,
        /// Method signature: name(): ReturnType. lhs = extra index to InterfaceSigData
        ts_method_signature,
        /// Property signature: name: Type. lhs = name node, rhs = type annotation (or .none)
        ts_property_signature,
        /// Index signature: [key: Type]: Type. lhs = param identifier, rhs = value type
        ts_index_signature,

        /// Decorator: @expression. main_token = @ token, lhs = expression node
        decorator,
        /// declare function / overload signature (no body). lhs = extra index to FnData
        ts_declare_function,
        /// expr<TypeArgs> — TS instantiation expression. lhs = expression, rhs = extra index to SubRange of type args
        ts_instantiation_expr,
        /// TS type parameter: `T extends C = D`. main_token = name identifier,
        /// lhs = constraint (or .none), rhs = default (or .none).
        ts_type_parameter,
        /// TS import-type expression in type position: `import('mod')` or
        /// `import('mod').X`. main_token = `import` keyword. lhs/rhs unused.
        ts_import_type,
    };
};

// ── ExtraData structs ──────────────────────────────────────
// Each struct's fields are stored sequentially in extra_data as u32s.

/// A range of indices in extra_data, representing a list of nodes.
pub const SubRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,
};

/// if (cond) consequent else alternate
pub const IfData = struct {
    consequent: NodeIndex,
    alternate: NodeIndex,
};

/// for (init; cond; update) body
pub const ForData = struct {
    init: NodeIndex, // .none if empty
    condition: NodeIndex, // .none if empty
    update: NodeIndex, // .none if empty
};

/// for (binding in/of expr) body
pub const ForInOfData = struct {
    binding: NodeIndex,
    expr: NodeIndex,
    body: NodeIndex,
};

/// try { block } catch (param) { handler } finally { finalizer }
pub const TryData = struct {
    catch_node: NodeIndex,   // .none if no catch; points to a catch_clause node
    finally_body: NodeIndex, // .none if no finally
};

/// Packed modifier bits for class members (methods, constructors).
/// Stored in MethodData.modifiers.
pub const ModifierBit = struct {
    pub const accessibility_mask: u32 = 0x3; // bits 0-1
    pub const acc_none:      u32 = 0x0;
    pub const acc_public:    u32 = 0x1;
    pub const acc_private:   u32 = 0x2;
    pub const acc_protected: u32 = 0x3;
    pub const readonly:    u32 = 1 << 2;
    pub const @"override": u32 = 1 << 3;
    pub const declare:     u32 = 1 << 4;
    pub const abstract:    u32 = 1 << 5;
    pub const @"static":   u32 = 1 << 6;
    pub const @"async":    u32 = 1 << 7;
    pub const generator:   u32 = 1 << 8;
    pub const accessor:    u32 = 1 << 9;
};

/// function name(params) { body }
pub const FnData = struct {
    name: NodeIndex, // .none for anonymous
    params: ExtraIndex, // SubRange start
    params_end: ExtraIndex, // SubRange end
    body: NodeIndex,
    return_type: NodeIndex = .none, // .none if no return type annotation
    type_params: ExtraIndex = 0, // SubRange start into extra_data for type parameters
    type_params_end: ExtraIndex = 0, // SubRange end (equal means no type params)
};

/// class name extends super { body }
pub const ClassData = struct {
    name: NodeIndex, // .none for anonymous
    super_class: NodeIndex, // .none if no extends
    body: NodeIndex, // class_body node (contains members as SubRange lhs..rhs)
    impls_start: ExtraIndex = 0, // SubRange start into extra_data; each entry = TokenIndex (main_token) of ts_type_reference
    impls_end: ExtraIndex = 0,   // SubRange end (impls_start == impls_end means no implements clause)
    type_params: ExtraIndex = 0, // SubRange start for type parameters
    type_params_end: ExtraIndex = 0, // SubRange end (equal means no type params)
};

/// (params) => body
pub const ArrowData = struct {
    params_start: ExtraIndex,
    params_end: ExtraIndex,
    body: NodeIndex,
    return_type: NodeIndex = .none, // .none if no return type annotation
    type_params: ExtraIndex = 0, // SubRange start into extra_data for type parameters
    type_params_end: ExtraIndex = 0, // SubRange end (equal means no type params)
};

/// cond ? consequent : alternate
pub const Conditional = struct {
    consequent: NodeIndex,
    alternate: NodeIndex,
};

/// import { specifiers } from 'source'
pub const ImportData = struct {
    specifiers_start: ExtraIndex,
    specifiers_end: ExtraIndex,
    source: NodeIndex, // string_literal node (real node in AST)
};

/// method(params) { body } inside class
pub const MethodData = struct {
    params_start: ExtraIndex,
    params_end: ExtraIndex,
    body: NodeIndex,
    return_type: NodeIndex = .none, // .none if no return type annotation
    modifiers: u32 = 0, // packed ModifierBit flags
    type_params: ExtraIndex = 0,
    type_params_end: ExtraIndex = 0,
};

/// Interface member signature data: call/construct/method signatures.
/// ts_call_signature / ts_construct_signature: key = .none.
/// ts_method_signature: key = name node.
pub const InterfaceSigData = struct {
    key: NodeIndex = .none,
    params_start: ExtraIndex = 0,
    params_end: ExtraIndex = 0,
    return_type: NodeIndex = .none,
    /// 0=method, 1=get, 2=set
    kind: u32 = 0,
    /// Type parameters SubRange (`name<T>(...)` in interface methods).
    type_params: ExtraIndex = 0,
    type_params_end: ExtraIndex = 0,
};

// ── TypeScript ExtraData structs ────────────────────────────

/// interface Name<T> extends A, B { members }
pub const InterfaceData = struct {
    name: u32, // token index of name
    type_params: u32, // SubRange start of type params (0 if none)
    type_params_end: u32, // SubRange end
    extends_start: u32, // SubRange start of extends types (0 if none)
    extends_end: u32, // SubRange end
    body_start: u32, // SubRange start of members
    body_end: u32, // SubRange end
};

/// enum Name { members }
pub const EnumData = struct {
    name: u32, // token index of name
    members_start: u32,
    members_end: u32,
};

/// type Name<T> = Type
pub const TypeAliasData = struct {
    name: u32, // token index of name
    type_params: u32, // SubRange start of type params (0 if none)
    type_params_end: u32, // SubRange end
    type_node: NodeIndex, // the aliased type
};

/// PropertyDefinition (class field). lhs = key, rhs = extra index to PropertyData.
/// Covers both property_def (computed_property_def uses the same layout).
pub const PropertyData = struct {
    value: NodeIndex = .none,          // initializer expression (or .none)
    type_annotation: NodeIndex = .none, // TSTypeAnnotation node (or .none)
    optional: u32 = 0,                 // 1 if TS optional marker `?` present
};

/// <tag attrs>children</tag>
pub const JsxElementData = struct {
    opening: NodeIndex,
    children_start: u32,
    children_end: u32,
    closing: NodeIndex,
};

/// <tag attrs> or <tag attrs />
pub const JsxOpeningData = struct {
    name: NodeIndex,
    attrs_start: u32,
    attrs_end: u32,
};

// ── AST Top-Level ──────────────────────────────────────────

/// The complete AST for a JavaScript source file.
pub const Ast = struct {
    source: []const u8,
    /// True when parsed as TypeScript (ts/tsx/dts). Lets later passes apply
    /// TS-specific semantics — e.g. function/namespace declaration merging, so
    /// duplicate `function f` overloads are not flagged as redeclarations.
    is_ts: bool = false,
    nodes: NodeList.Slice,
    tokens: TokenList.Slice,
    extra_data: []const u32,
    /// True allocation capacity behind extra_data (>= extra_data.len). Non-zero
    /// only when the parser transferred the buffer without shrink-realloc (the
    /// common path). deinit uses this to free with the correct size.
    extra_data_cap: u32 = 0,
    errors: []const Diagnostic,
    /// Scope/declare/reference events emitted during parsing.  Empty when the
    /// parser was invoked without event emission enabled.  When present, the
    /// event-driven semantic analyzer consumes this instead of walking the tree.
    scope_events: []const ScopeEvent = &.{},
    /// True allocation capacity behind scope_events (>= scope_events.len).
    scope_events_cap: u32 = 0,
    /// Per-node last-consumed token index, captured at addNode time.
    /// node_end_toks[i] = last token index consumed for node i.
    /// tok_ends[node_end_toks[i]] gives the correct ESTree end byte position.
    node_end_toks: []const u32 = &.{},
    node_end_toks_cap: u32 = 0,
    /// Flat (child, parent) pairs for parent links that are NOT derivable from
    /// the final tree structure (currently: type annotations on destructured
    /// parameters/bindings, whose pattern node has no slot to hold them).
    /// `buildParentsOnly` replays these after its structural pass so the
    /// semantic-built parents are lossless. Parents themselves are NOT stored on
    /// the Ast — they are built on demand by semantic (`parent_indices`).
    parent_fixups: []const u32 = &.{},
    parent_fixups_cap: u32 = 0,

    pub const NodeList = std.MultiArrayList(Node);
    pub const TokenList = std.MultiArrayList(struct {
        tag: TokenTag,
        start: ByteOffset,
        /// Byte length of the token in source (end = start + len).
        len: u32 = 0,
        /// True if there is a line terminator between the previous token and this one.
        has_newline_before: bool = false,
        /// True if the token text contains a \u unicode escape sequence.
        /// Set by the lexer; lets the parser skip a memchr scan in isStrictReservedWord.
        has_unicode_escape: bool = false,
    });

    // Free a slice that may have been allocated with extra capacity.
    // When cap > 0, the live slice is a sub-slice of a larger backing allocation.
    inline fn freeCapped(allocator: std.mem.Allocator, slice: anytype, cap: u32) void {
        if (cap > 0) {
            allocator.free(slice.ptr[0..cap]);
        } else if (slice.len > 0) {
            allocator.free(slice);
        }
    }

    pub fn deinit(self: *Ast, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        // tokens are NOT owned by Ast — the caller manages their lifetime
        // Free extra_data using the true backing allocation size. When the parser
        // transferred the buffer without shrink-realloc, extra_data_cap records the
        // actual allocation capacity (>= extra_data.len); otherwise cap == 0 and
        // extra_data.len equals the allocation size (toOwnedSlice was used).
        if (self.extra_data_cap > 0) {
            allocator.free(self.extra_data.ptr[0..self.extra_data_cap]);
        } else {
            allocator.free(self.extra_data);
        }
        for (self.errors) |err| {
            allocator.free(err.message);
        }
        allocator.free(self.errors);
        freeCapped(allocator, self.scope_events, self.scope_events_cap);
        freeCapped(allocator, self.node_end_toks, self.node_end_toks_cap);
        freeCapped(allocator, self.parent_fixups, self.parent_fixups_cap);
        self.* = undefined;
    }

    // ── Accessors ──────────────────────────────────────────

    /// @takes node_index_of(self)
    pub inline fn nodeTag(self: *const Ast, index: NodeIndex) Node.Tag {
        if (index == .none) return .root;
        return self.nodes.items(.tag)[index.toInt()];
    }

    /// @takes node_index_of(self)
    pub inline fn nodeMainToken(self: *const Ast, index: NodeIndex) TokenIndex {
        if (index == .none) return 0;
        return self.nodes.items(.main_token)[index.toInt()];
    }

    /// @takes node_index_of(self)
    pub inline fn nodeData(self: *const Ast, index: NodeIndex) Node.Data {
        return self.nodes.items(.data)[index.toInt()];
    }

    pub inline fn tokenTag(self: *const Ast, index: TokenIndex) TokenTag {
        return self.tokens.items(.tag)[index];
    }

    pub inline fn tokenStart(self: *const Ast, index: TokenIndex) ByteOffset {
        return self.tokens.items(.start)[index];
    }

    /// Get the source text of a token. O(1) using stored token length.
    /// @returns borrowed_from(self)
    pub inline fn tokenText(self: *const Ast, index: TokenIndex) []const u8 {
        const start = self.tokenStart(index);
        const len = self.tokens.items(.len)[index];
        if (len > 0) {
            const end = @min(start + len, @as(u32, @intCast(self.source.len)));
            return self.source[start..end];
        }

        // Fallback for tokens with zero len (shouldn't happen in practice).
        const tag = self.tokenTag(index);
        if (tag.lexeme()) |lex| return lex;

        // Re-scan (legacy path — only for edge cases with missing len)
        var end: u32 = start;
        switch (tag) {
            .identifier => {
                while (end < self.source.len and (isIdentChar(self.source[end]) or self.source[end] >= 0x80 or self.source[end] == '\\')) {
                    if (self.source[end] == '\\') {
                        end += 1;
                        if (end < self.source.len and self.source[end] == 'u') {
                            end += 1;
                            if (end < self.source.len and self.source[end] == '{') {
                                while (end < self.source.len and self.source[end] != '}') end += 1;
                                if (end < self.source.len) end += 1;
                            } else {
                                var j: u32 = 0;
                                while (j < 4 and end < self.source.len) : (j += 1) end += 1;
                            }
                        }
                    } else {
                        end += 1;
                    }
                }
            },
            .number_literal, .bigint_literal => {
                while (end < self.source.len and isNumericChar(self.source[end])) end += 1;
            },
            .string_literal => {
                if (end >= self.source.len) return self.source[start..end];
                const quote = self.source[end];
                end += 1;
                while (end < self.source.len and self.source[end] != quote) {
                    if (self.source[end] == '\\') { end += 1; if (end >= self.source.len) break; }
                    end += 1;
                }
                if (end < self.source.len) end += 1;
            },
            .regex_literal => {
                if (end >= self.source.len) return self.source[start..end];
                end += 1; // skip opening /
                while (end < self.source.len and self.source[end] != '/') {
                    if (self.source[end] == '\\') {
                        end += 1;
                        if (end >= self.source.len) break;
                    }
                    end += 1;
                }
                if (end < self.source.len) end += 1; // closing /
                // flags
                while (end < self.source.len and isIdentChar(self.source[end])) {
                    end += 1;
                }
            },
            .template_head, .template_middle, .template_tail, .template_no_sub => {
                // Templates are bounded by ` and ${ or }
                while (end < self.source.len) {
                    if (self.source[end] == '`') {
                        end += 1;
                        break;
                    }
                    if (self.source[end] == '$' and end + 1 < self.source.len and self.source[end + 1] == '{') {
                        end += 2;
                        break;
                    }
                    if (self.source[end] == '\\') end += 1;
                    end += 1;
                }
            },
            .hashbang => {
                while (end < self.source.len and self.source[end] != '\n') {
                    end += 1;
                }
            },
            .jsx_text => {
                while (end < self.source.len and self.source[end] != '<' and self.source[end] != '{') {
                    end += 1;
                }
            },
            else => {},
        }
        return self.source[start..end];
    }

    /// Read a typed extra data struct starting at the given index.
    /// Returns zero-initialized result if index is out of bounds (e.g. .none passed as extra index).
    pub fn extraData(self: *const Ast, comptime T: type, index: ExtraIndex) T {
        var result: T = undefined;
        inline for (0..meta_compat.fieldCount(T)) |i| {
            const name = comptime meta_compat.structFieldName(T, i);
            const FieldT = @FieldType(T, name);
            const raw = if (index + i < self.extra_data.len) self.extra_data[index + i] else 0;
            @field(result, name) = if (FieldT == NodeIndex)
                @enumFromInt(raw)
            else if (FieldT == u32)
                raw
            else
                @compileError("unexpected field type: " ++ @typeName(FieldT));
        }
        return result;
    }

    /// Get a slice of node indices from extra_data.
    /// @returns borrowed_from(self)
    pub inline fn extraSlice(self: *const Ast, range: SubRange) []const u32 {
        if (range.start > range.end or range.end > self.extra_data.len) return &.{};
        return self.extra_data[range.start..range.end];
    }

    /// Get the span of a node.
    /// `end` is the byte position after the node's main token — correct for
    /// single-token nodes (identifiers, literals).  For compound nodes the
    /// true end (closing `}`, `)`, `;`) is only available via
    /// `LintContext.nodeSpan`, which uses a precomputed per-node max-token table.
    /// @takes node_index_of(self)
    pub fn nodeSpan(self: *const Ast, index: NodeIndex) Span {
        const tok = self.nodeMainToken(index);
        const start = self.tokenStart(tok);
        const end = start + self.tokens.items(.len)[tok];
        return .{ .start = start, .end = end };
    }

    /// The source text of a node's name: its name token's text. Usually
    /// `main_token`, except `ts_enum_decl` whose name lives in `extra_data`.
    pub inline fn nodeName(self: *const Ast, index: NodeIndex) []const u8 {
        const i = index.toInt();
        var nt = self.nodeMainToken(index);
        if (self.nodes.items(.tag)[i] == .ts_enum_decl) {
            const extra_idx = @intFromEnum(self.nodes.items(.data)[i].lhs);
            if (extra_idx < self.extra_data.len) nt = self.extra_data[extra_idx];
        }
        return self.tokenText(nt);
    }

};

// ── Helpers ────────────────────────────────────────────────

const isIdentChar = @import("token.zig").isIdentChar;
const isNumericChar = @import("token.zig").isNumericChar;
