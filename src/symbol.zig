const std = @import("std");
const ast = @import("ast.zig");
const ScopeId = @import("scope.zig").ScopeId;

// ── Symbol identifier ──────────────────────────────────────

pub const SymbolId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(self: SymbolId) ?u32 {
        return if (self == .none) null else @intFromEnum(self);
    }

    pub fn toInt(self: SymbolId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(i: u32) SymbolId {
        return @enumFromInt(i);
    }
};

// ── Symbol flags (packed into u16) ─────────────────────────

pub const SymbolFlags = packed struct(u16) {
    is_var: bool = false,
    is_let: bool = false,
    is_const: bool = false,
    is_function: bool = false,
    is_class: bool = false,
    is_parameter: bool = false,
    is_catch_param: bool = false,
    is_import: bool = false,
    is_export: bool = false,
    is_hoisted: bool = false,
    is_written: bool = false,
    is_read: bool = false,
    is_type_of: bool = false,
    is_implicit_global: bool = false,
    is_member_written: bool = false, // a member of this symbol was written (e.g. ns.prop = 0)
    /// True for named function-expression and named class-expression name bindings.
    /// These names live inside the expression's own scope (self-reference only) and
    /// must not be treated as shadows of an outer variable with the same name.
    is_expr_name: bool = false,

    pub const EMPTY: SymbolFlags = .{};
};

// ── Binding kind ───────────────────────────────────────────

/// What kind of binding created this symbol.
///
/// Binding semantics:
///   var            — hoisted to function/global scope, no TDZ, can be redeclared
///   let            — block-scoped, has TDZ, cannot be redeclared in same scope
///   const          — like let but also immutable (no reassignment)
///   function_decl  — hoisted to function/global scope (sloppy), block-scoped in strict
///   class_decl     — block-scoped, has TDZ
///   parameter      — function-scoped, can be shadowed by var
///   catch_param    — catch-scoped, can be shadowed
///   import_binding — module-scoped, immutable (like const)
///   implicit_global — never declared, just referenced
pub const BindingKind = enum {
    @"var",
    let,
    @"const",
    function_decl,
    /// Function declaration nested directly in an IfStatement body or
    /// LabelledStatement — Annex B B.3.2.1 eligible. Same semantics as
    /// function_decl in non-AnnexB contexts; differs only in dup-check
    /// (sloppy + AnnexB skips the conflict with let/const/class).
    function_decl_annex_b,
    class_decl,
    parameter,
    catch_param,
    import_binding,
    /// TypeScript: `import type { x }` or `import { type x }` — type-only import binding.
    /// Treated as a value binding for most purposes, but no-shadow uses it to detect
    /// type-import vs value-declaration conflicts for ignoreTypeValueShadow handling.
    type_import_binding,
    implicit_global,
    /// TypeScript: type T = ...
    type_decl,
    /// TypeScript: interface T { ... }  (merging allowed in TS)
    interface_decl,
    /// TypeScript: enum T { ... }
    enum_decl,
    /// TypeScript: member inside an enum body (`A = 1` in `enum E { A = 1 }`).
    /// Declared in the enum's inner scope so shadow-checking rules see it.
    enum_member,
    /// TypeScript: namespace T { } / declare module 'foo' { }
    namespace_decl,
    /// Named function-expression name binding (function's own scope, self-reference).
    fn_expr_name,
    /// Named class-expression name binding (class's own scope, self-reference).
    class_expr_name,
    /// TypeScript type parameter (<T, U> in generic function/type/interface declarations).
    type_param,

    /// Returns true if the binding is immutable after initialization.
    pub fn isImmutable(self: BindingKind) bool {
        return switch (self) {
            // class_expr_name: ES §15.7.2.7 step 7.b uses CreateImmutableBinding.
            .@"const", .import_binding, .type_import_binding, .enum_member, .class_expr_name => true,
            else => false,
        };
    }

    /// Returns true if the binding introduces a TDZ (temporal dead zone).
    pub fn hasTDZ(self: BindingKind) bool {
        return switch (self) {
            .let, .@"const", .class_decl, .class_expr_name => true,
            else => false,
        };
    }

};

// ── Reference range ────────────────────────────────────────

/// A range into a separate reference table (indices [start..end)).
pub const RefRange = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub fn len(self: RefRange) u32 {
        return self.end - self.start;
    }

    pub fn isEmpty(self: RefRange) bool {
        return self.start == self.end;
    }
};

// ── Symbol table (struct-of-arrays) ────────────────────────

/// SoA symbol table following Oxc's design.
///
/// Each field is a separate contiguous array indexed by SymbolId.
/// When a lint rule iterates over all symbol names (e.g., checking naming
/// conventions), it reads a dense array of name slices without loading
/// flags, scopes, or other metadata into cache.
///
/// All ArrayLists are unmanaged (Zig 0.16 convention) — the allocator
/// is passed explicitly to each mutating call via the `gpa` field.
pub const SymbolTable = struct {
    /// One symbol row. Stored column-wise via `MultiArrayList` (SoA): when a
    /// lint rule iterates all names (e.g. naming conventions) it reads a dense
    /// array of name slices without loading flags/scopes into cache.
    pub const Entry = struct {
        /// Symbol name — slice into the source buffer (zero-copy).
        name: []const u8,
        /// Packed flags describing the symbol's properties.
        flags: SymbolFlags,
        /// What kind of binding created this symbol.
        binding_kind: BindingKind,
        /// Scope where the symbol was declared.
        scope_id: ScopeId,
        /// AST node of the declaration site.
        decl_node: ast.NodeIndex,
        /// Range of references to this symbol in an external reference table.
        ref_range: RefRange,
    };

    /// Column-wise symbol storage. Access a column as a slice with
    /// `list.items(.name)` etc.
    list: std.MultiArrayList(Entry) = .{},

    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) SymbolTable {
        return .{ .gpa = gpa };
    }

    pub fn ensureCapacity(self: *SymbolTable, n: u32) !void {
        try self.list.ensureTotalCapacity(self.gpa, n);
    }

    pub fn deinit(self: *SymbolTable) void {
        self.list.deinit(self.gpa);
        self.* = undefined;
    }

    /// Add a new symbol to the table. Returns its SymbolId.
    pub fn addSymbol(
        self: *SymbolTable,
        name: []const u8,
        symbol_flags: SymbolFlags,
        binding_kind: BindingKind,
        scope_id: ScopeId,
        decl_node: ast.NodeIndex,
    ) !SymbolId {
        const id: u32 = @intCast(self.list.len);

        // Capacity pre-allocated via ensureCapacity(); grow only when exhausted.
        if (self.list.len >= self.list.capacity)
            try self.ensureCapacity(@intCast(self.list.capacity * 2 + 16));

        self.list.appendAssumeCapacity(.{
            .name = name,
            .flags = symbol_flags,
            .binding_kind = binding_kind,
            .scope_id = scope_id,
            .decl_node = decl_node,
            .ref_range = .{},
        });

        return SymbolId.fromInt(id);
    }

    // ── Getters ────────────────────────────────────────────

    pub fn getName(self: *const SymbolTable, id: SymbolId) []const u8 {
        return self.list.items(.name)[id.toInt()];
    }

    pub fn getFlags(self: *const SymbolTable, id: SymbolId) SymbolFlags {
        return self.list.items(.flags)[id.toInt()];
    }

    pub fn getScope(self: *const SymbolTable, id: SymbolId) ScopeId {
        return self.list.items(.scope_id)[id.toInt()];
    }

    pub fn getBindingKind(self: *const SymbolTable, id: SymbolId) BindingKind {
        return self.list.items(.binding_kind)[id.toInt()];
    }

    pub fn getDeclNode(self: *const SymbolTable, id: SymbolId) ast.NodeIndex {
        return self.list.items(.decl_node)[id.toInt()];
    }

    pub fn getRefRange(self: *const SymbolTable, id: SymbolId) RefRange {
        return self.list.items(.ref_range)[id.toInt()];
    }

    // ── Setters ────────────────────────────────────────────

    pub fn setFlags(self: *SymbolTable, id: SymbolId, symbol_flags: SymbolFlags) void {
        self.list.items(.flags)[id.toInt()] = symbol_flags;
    }

    pub fn setRefRange(self: *SymbolTable, id: SymbolId, range: RefRange) void {
        self.list.items(.ref_range)[id.toInt()] = range;
    }

    // ── Mutation helpers ───────────────────────────────────

    /// Mark a symbol as read/referenced.
    pub inline fn markRead(self: *SymbolTable, id: SymbolId) void {
        self.list.items(.flags)[id.toInt()].is_read = true;
    }

    /// Mark a symbol as written/assigned after declaration.
    pub inline fn markWritten(self: *SymbolTable, id: SymbolId) void {
        self.list.items(.flags)[id.toInt()].is_written = true;
    }

    /// Mark a symbol as used in a typeof expression.
    pub inline fn markTypeOf(self: *SymbolTable, id: SymbolId) void {
        self.list.items(.flags)[id.toInt()].is_type_of = true;
    }

    /// Mark a symbol as exported.
    pub fn markExported(self: *SymbolTable, id: SymbolId) void {
        self.list.items(.flags)[id.toInt()].is_export = true;
    }

    // ── Queries ────────────────────────────────────────────

    /// Check if a symbol is used (read, written, or typeof'd).
    pub fn isUsed(self: *const SymbolTable, id: SymbolId) bool {
        const f = self.list.items(.flags)[id.toInt()];
        return f.is_read or f.is_written or f.is_type_of;
    }

    /// Check if a symbol is in the temporal dead zone.
    /// True for let/const/class declarations (they are not hoisted).
    pub fn isInTDZ(self: *const SymbolTable, id: SymbolId) bool {
        return self.list.items(.binding_kind)[id.toInt()].hasTDZ();
    }

    /// Check if a symbol is immutable (const or import binding).
    pub fn isImmutable(self: *const SymbolTable, id: SymbolId) bool {
        return self.list.items(.binding_kind)[id.toInt()].isImmutable();
    }

    /// Check if a symbol is an implicit global (referenced but never declared).
    pub fn isImplicitGlobal(self: *const SymbolTable, id: SymbolId) bool {
        return self.list.items(.flags)[id.toInt()].is_implicit_global;
    }

    /// Get the number of symbols in the table.
    pub fn count(self: *const SymbolTable) u32 {
        return @intCast(self.list.len);
    }

    // ── Bulk iteration helpers ─────────────────────────────

    /// Returns a slice of all symbol names (dense, cache-friendly iteration).
    pub fn allNames(self: *const SymbolTable) []const []const u8 {
        return self.list.items(.name);
    }

    /// Returns a slice of all symbol flags (dense, cache-friendly iteration).
    pub fn allFlags(self: *const SymbolTable) []const SymbolFlags {
        return self.list.items(.flags);
    }
};

// ── Flags construction helpers ─────────────────────────────

/// Create SymbolFlags from a BindingKind, setting the appropriate declaration
/// and hoisting flags automatically.
pub fn flagsFromBindingKind(kind: BindingKind) SymbolFlags {
    var f = SymbolFlags.EMPTY;
    switch (kind) {
        .@"var" => {
            f.is_var = true;
            f.is_hoisted = true;
        },
        .let => {
            f.is_let = true;
        },
        .@"const" => {
            f.is_const = true;
        },
        .function_decl, .function_decl_annex_b => {
            f.is_function = true;
            f.is_hoisted = true;
        },
        .class_decl => {
            f.is_class = true;
        },
        .parameter => {
            f.is_parameter = true;
        },
        .catch_param => {
            f.is_catch_param = true;
        },
        .import_binding, .type_import_binding => {
            f.is_import = true;
        },
        .implicit_global => {
            f.is_implicit_global = true;
        },
        // TS type declarations: no JS-visible flags (tracked for ESLint scope only)
        .type_decl, .interface_decl, .enum_decl, .namespace_decl, .type_param => {},
        .enum_member => {
            f.is_const = true; // enum members are immutable after declaration
        },
        // Named function/class expression name bindings — declared as function/class
        // inside the expression's own scope, but marked is_expr_name to suppress
        // no-shadow false positives (they're self-referential, not real shadows).
        .fn_expr_name => {
            f.is_function = true;
            f.is_expr_name = true;
        },
        .class_expr_name => {
            f.is_class = true;
            f.is_expr_name = true;
        },
    }
    return f;
}

// ── Tests ──────────────────────────────────────────────────

test "SymbolFlags size is u16" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(SymbolFlags));
}

test "SymbolTable add and query" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const id = try table.addSymbol(
        "foo",
        flagsFromBindingKind(.@"const"),
        .@"const",
        root_scope,
        ast.NodeIndex.fromInt(1),
    );

    try std.testing.expectEqual(@as(u32, 0), id.toInt());
    try std.testing.expectEqualStrings("foo", table.getName(id));
    try std.testing.expect(table.getFlags(id).is_const);
    try std.testing.expect(!table.getFlags(id).is_var);
    try std.testing.expectEqual(BindingKind.@"const", table.getBindingKind(id));
    try std.testing.expectEqual(root_scope, table.getScope(id));
    try std.testing.expectEqual(ast.NodeIndex.fromInt(1), table.getDeclNode(id));
    try std.testing.expectEqual(@as(u32, 1), table.count());
}

test "SymbolTable mark read/written" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const id = try table.addSymbol(
        "x",
        flagsFromBindingKind(.let),
        .let,
        root_scope,
        ast.NodeIndex.fromInt(0),
    );

    try std.testing.expect(!table.isUsed(id));

    table.markRead(id);
    try std.testing.expect(table.isUsed(id));
    try std.testing.expect(table.getFlags(id).is_read);

    table.markWritten(id);
    try std.testing.expect(table.getFlags(id).is_written);
}

test "SymbolTable TDZ semantics" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const var_id = try table.addSymbol("a", flagsFromBindingKind(.@"var"), .@"var", root_scope, ast.NodeIndex.fromInt(0));
    const let_id = try table.addSymbol("b", flagsFromBindingKind(.let), .let, root_scope, ast.NodeIndex.fromInt(1));
    const const_id = try table.addSymbol("c", flagsFromBindingKind(.@"const"), .@"const", root_scope, ast.NodeIndex.fromInt(2));
    const fn_id = try table.addSymbol("d", flagsFromBindingKind(.function_decl), .function_decl, root_scope, ast.NodeIndex.fromInt(3));
    const fn_expr_id = try table.addSymbol("e", flagsFromBindingKind(.fn_expr_name), .fn_expr_name, root_scope, ast.NodeIndex.fromInt(4));
    const class_id = try table.addSymbol("f", flagsFromBindingKind(.class_decl), .class_decl, root_scope, ast.NodeIndex.fromInt(5));
    const class_expr_id = try table.addSymbol("g", flagsFromBindingKind(.class_expr_name), .class_expr_name, root_scope, ast.NodeIndex.fromInt(6));

    // var, function declarations, and fn_expr_name are not in TDZ.
    // fn_expr_name: the name binding is initialized to the function object before the body
    // runs (ES §15.2.5) — no TDZ window.
    try std.testing.expect(!table.isInTDZ(var_id));
    try std.testing.expect(!table.isInTDZ(fn_id));
    try std.testing.expect(!table.isInTDZ(fn_expr_id));

    // let, const, class, and class-expression names are in TDZ.
    try std.testing.expect(table.isInTDZ(let_id));
    try std.testing.expect(table.isInTDZ(const_id));
    try std.testing.expect(table.isInTDZ(class_id));
    try std.testing.expect(table.isInTDZ(class_expr_id));
}

test "SymbolTable immutability" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const let_id = try table.addSymbol("a", flagsFromBindingKind(.let), .let, root_scope, ast.NodeIndex.fromInt(0));
    const const_id = try table.addSymbol("b", flagsFromBindingKind(.@"const"), .@"const", root_scope, ast.NodeIndex.fromInt(1));
    const import_id = try table.addSymbol("c", flagsFromBindingKind(.import_binding), .import_binding, root_scope, ast.NodeIndex.fromInt(2));
    const class_expr_id = try table.addSymbol("d", flagsFromBindingKind(.class_expr_name), .class_expr_name, root_scope, ast.NodeIndex.fromInt(3));

    try std.testing.expect(!table.isImmutable(let_id));
    try std.testing.expect(table.isImmutable(const_id));
    try std.testing.expect(table.isImmutable(import_id));
    // class expression names are CreateImmutableBinding per ES §15.7.2.7 step 7.b.
    try std.testing.expect(table.isImmutable(class_expr_id));
}

test "flagsFromBindingKind sets correct flags" {
    const var_flags = flagsFromBindingKind(.@"var");
    try std.testing.expect(var_flags.is_var);
    try std.testing.expect(var_flags.is_hoisted);
    try std.testing.expect(!var_flags.is_let);

    const fn_flags = flagsFromBindingKind(.function_decl);
    try std.testing.expect(fn_flags.is_function);
    try std.testing.expect(fn_flags.is_hoisted);

    const param_flags = flagsFromBindingKind(.parameter);
    try std.testing.expect(param_flags.is_parameter);
    try std.testing.expect(!param_flags.is_hoisted);

    const global_flags = flagsFromBindingKind(.implicit_global);
    try std.testing.expect(global_flags.is_implicit_global);
}

test "SymbolId.none sentinel" {
    try std.testing.expectEqual(std.math.maxInt(u32), @intFromEnum(SymbolId.none));
}

test "RefRange" {
    const empty = RefRange{};
    try std.testing.expect(empty.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), empty.len());

    const range = RefRange{ .start = 3, .end = 7 };
    try std.testing.expect(!range.isEmpty());
    try std.testing.expectEqual(@as(u32, 4), range.len());
}

test "SymbolTable multiple symbols with bulk iteration" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    _ = try table.addSymbol("alpha", flagsFromBindingKind(.@"var"), .@"var", root_scope, ast.NodeIndex.fromInt(0));
    _ = try table.addSymbol("beta", flagsFromBindingKind(.let), .let, root_scope, ast.NodeIndex.fromInt(1));
    _ = try table.addSymbol("gamma", flagsFromBindingKind(.@"const"), .@"const", root_scope, ast.NodeIndex.fromInt(2));

    const names = table.allNames();
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("alpha", names[0]);
    try std.testing.expectEqualStrings("beta", names[1]);
    try std.testing.expectEqualStrings("gamma", names[2]);

    const all_flags = table.allFlags();
    try std.testing.expect(all_flags[0].is_var);
    try std.testing.expect(all_flags[1].is_let);
    try std.testing.expect(all_flags[2].is_const);
}

test "setFlags overwrites flags" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const id = try table.addSymbol("x", flagsFromBindingKind(.let), .let, root_scope, ast.NodeIndex.fromInt(0));

    try std.testing.expect(!table.getFlags(id).is_export);

    var new_flags = table.getFlags(id);
    new_flags.is_export = true;
    table.setFlags(id, new_flags);

    try std.testing.expect(table.getFlags(id).is_export);
    try std.testing.expect(table.getFlags(id).is_let);
}

test "setRefRange and getRefRange" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const id = try table.addSymbol("x", flagsFromBindingKind(.let), .let, root_scope, ast.NodeIndex.fromInt(0));

    // Initially empty.
    try std.testing.expect(table.getRefRange(id).isEmpty());

    table.setRefRange(id, .{ .start = 5, .end = 10 });
    const r = table.getRefRange(id);
    try std.testing.expectEqual(@as(u32, 5), r.start);
    try std.testing.expectEqual(@as(u32, 10), r.end);
    try std.testing.expectEqual(@as(u32, 5), r.len());
}

test "markExported and markTypeOf" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const id = try table.addSymbol("x", flagsFromBindingKind(.let), .let, root_scope, ast.NodeIndex.fromInt(0));

    try std.testing.expect(!table.getFlags(id).is_export);
    try std.testing.expect(!table.getFlags(id).is_type_of);
    try std.testing.expect(!table.isUsed(id));

    table.markExported(id);
    try std.testing.expect(table.getFlags(id).is_export);

    table.markTypeOf(id);
    try std.testing.expect(table.getFlags(id).is_type_of);
    try std.testing.expect(table.isUsed(id)); // typeof counts as usage
}

test "isImplicitGlobal" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const root_scope = ScopeId.fromInt(0);
    const declared = try table.addSymbol("x", flagsFromBindingKind(.let), .let, root_scope, ast.NodeIndex.fromInt(0));
    const global = try table.addSymbol("console", flagsFromBindingKind(.implicit_global), .implicit_global, root_scope, ast.NodeIndex.fromInt(1));

    try std.testing.expect(!table.isImplicitGlobal(declared));
    try std.testing.expect(table.isImplicitGlobal(global));
}
