const std = @import("std");
const ast = @import("ast.zig");

// ── Scope Identifiers ──────────────────────────────────────

/// A typed index into the ScopeTree's parallel arrays.
pub const ScopeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn toInt(self: ScopeId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(i: u32) ScopeId {
        return @enumFromInt(i);
    }

    pub fn isValid(self: ScopeId) bool {
        return self != .none;
    }
};

// ── Scope Kind ─────────────────────────────────────────────

pub const ScopeKind = enum(u8) {
    /// Top-level / module scope (script mode).
    global,
    /// ES module scope — always strict.
    module,
    /// Function body — var declarations hoist to here.
    function,
    /// { } block, for, if, while, etc. — let/const/class are scoped here.
    block,
    /// Class body — always strict.
    class,
    /// catch(e) { } — the parameter `e` is scoped to this block.
    catch_clause,
    /// switch body — block scope.
    switch_stmt,
    /// class static { } — block scope within a class.
    static_block,
    /// with(obj) { } — disables lexical optimisation in sloppy mode.
    with_stmt,
    /// Class field initializer — evaluated as a separate execution context.
    /// ESLint creates an implicit function scope for these so rules like
    /// no-use-before-define treat references inside them as crossing a function
    /// boundary.
    class_field_initializer,
    /// Block scope emitted speculatively by the parser but determined to hold
    /// no block-scoped declarations (let/const/class).  event_resolver skips
    /// these — no ScopeId is created and references inside are attributed to
    /// the enclosing scope.  No matching scope_close is emitted.
    elided,
    /// Arrow function scope — var-scope like `function` but no `arguments`
    /// or `this` binding (arrow functions inherit those from the outer scope).
    arrow_function,
    /// TypeScript `enum` body — a block-like scope that holds the enum
    /// member symbols.  Not a var-scope; `var` declarations inside an enum
    /// initializer hoist past the enum body to the enclosing function/module.
    ts_enum,
    /// TypeScript `namespace N { }` / `module N { }` body.  A var-scope —
    /// `var` declarations stop at the namespace boundary instead of hoisting
    /// to the enclosing function/global, matching TypeScript's scope analyzer
    /// (a namespace compiles to an IIFE).  Distinct from `.block` so rules can
    /// recognise namespace bodies (no-shadow, no-inner-declarations, etc.).
    ts_namespace,
};

// ── Scope Flags ────────────────────────────────────────────

/// Bit-packed flags describing the properties of a scope.
///
/// JavaScript scoping rules encoded:
///   - `is_var_scope`:     function or global — var declarations hoist here.
///   - `strict_mode`:      scope itself was marked strict.
///   - `has_use_strict`:   scope contains a "use strict" directive.
///   - `is_async`:         async function scope.
///   - `is_generator`:     generator function scope.
///   - `has_arguments`:    function scope that provides implicit `arguments`
///                         (not arrow functions).
///   - `has_this_binding`: function / class / global provide `this`
///                         (not arrow functions).
pub const ScopeFlags = packed struct(u16) {
    strict_mode: bool = false,
    is_var_scope: bool = false,
    has_use_strict: bool = false,
    is_async: bool = false,
    is_generator: bool = false,
    has_arguments: bool = false,
    has_this_binding: bool = false,
    /// Body block of a ts_namespace_decl or ts_module_decl. Set automatically
    /// for `ScopeKind.ts_namespace` scopes (see addScope). Used by no-shadow to
    /// suppress reports when the outer symbol is declared inside a
    /// namespace/module body (declare namespace).
    is_namespace_body: bool = false,
    _padding: u8 = 0,
};

// ── Scope Tree ─────────────────────────────────────────────

/// A flat, SoA-layout scope tree for JavaScript lexical scoping.
///
/// Each scope occupies one slot across all parallel arrays, addressed by
/// `ScopeId`.  The tree structure is encoded via `parents`, `first_child`,
/// and `next_sibling` arrays — the classic left-child / right-sibling
/// representation — so no per-scope heap allocation is needed.
///
/// Bindings are not stored here; instead `bindings_start` and
/// `bindings_count` index into the companion `SymbolTable`.
pub const ScopeTree = struct {
    /// One scope row. Stored column-wise via `MultiArrayList` (SoA). A single
    /// backing allocation keeps every column the same length even across grows
    /// — unlike parallel `ArrayList`s, whose per-element-size capacity rounding
    /// otherwise drifts out of sync.
    pub const Entry = struct {
        kind: ScopeKind,
        flags: ScopeFlags,
        parent: ScopeId,
        first_child: ScopeId,
        last_child: ScopeId,
        next_sibling: ScopeId,
        node_id: ast.NodeIndex,
        bindings_start: u32,
        bindings_count: u32,
        /// Nearest enclosing var-scope (function, arrow_function, static_block,
        /// class_field_initializer, module, global) — including self if this
        /// scope is itself a var-scope.  Set once at addScope time; O(1) lookup.
        var_scope: ScopeId,
    };

    /// Column-wise scope storage. Access a column with `list.items(.kind)` etc.
    list: std.MultiArrayList(Entry) = .{},

    gpa: std.mem.Allocator,

    // ── Lifecycle ──────────────────────────────────────────

    /// Pre-allocate capacity for `n` scopes in one call. Eliminates per-scope
    /// ensureUnusedCapacity overhead in the hot addScope path.
    pub fn ensureCapacity(self: *ScopeTree, n: u32) !void {
        try self.list.ensureTotalCapacity(self.gpa, n);
    }

    pub fn init(allocator: std.mem.Allocator) ScopeTree {
        return .{ .gpa = allocator };
    }

    pub fn deinit(self: *ScopeTree) void {
        self.list.deinit(self.gpa);
    }

    // ── Mutation ───────────────────────────────────────────

    /// Create a new scope, link it into the tree under `parent_id`, and
    /// return its `ScopeId`.
    ///
    /// Flags are initialised based on the scope kind following JavaScript
    /// semantics:
    ///   - `global` and `module` are var-scopes with a `this` binding.
    ///   - `module` and `class` scopes are always strict.
    ///   - `function` scopes are var-scopes with `arguments` and `this`.
    ///   - `arrow_function` scopes are var-scopes without `arguments` or `this`.
    pub fn addScope(
        self: *ScopeTree,
        scope_kind: ScopeKind,
        parent_id: ScopeId,
        node_id: ast.NodeIndex,
    ) !ScopeId {
        const idx: u32 = @intCast(self.list.len);
        const id = ScopeId.fromInt(idx);

        // Derive initial flags from the scope kind.
        var scope_flags = ScopeFlags{};
        switch (scope_kind) {
            .global => {
                scope_flags.is_var_scope = true;
                scope_flags.has_this_binding = true;
            },
            .module => {
                scope_flags.is_var_scope = true;
                scope_flags.has_this_binding = true;
                scope_flags.strict_mode = true; // ES modules are always strict
            },
            .function => {
                scope_flags.is_var_scope = true;
                scope_flags.has_arguments = true;
                scope_flags.has_this_binding = true;
            },
            .class => {
                scope_flags.strict_mode = true; // class bodies are always strict
            },
            .static_block => {
                scope_flags.strict_mode = true; // inherits class strict mode
                scope_flags.has_this_binding = true;
                scope_flags.is_var_scope = true; // var declarations hoist to static block, not beyond
            },
            .block, .catch_clause, .switch_stmt, .with_stmt, .elided, .ts_enum => {},
            .ts_namespace => {
                // Namespace/module bodies are var-scopes: `var` declarations stop
                // here rather than hoisting past the namespace boundary (TS compiles
                // a namespace to an IIFE). Flag the body for no-shadow et al.
                scope_flags.is_var_scope = true;
                scope_flags.is_namespace_body = true;
            },
            .arrow_function => {
                // Arrow functions ARE var-scopes — var declarations stop here,
                // matching ES2015+ spec.  They do not provide `arguments` or
                // `this`; those are inherited from the nearest enclosing
                // non-arrow function.
                scope_flags.is_var_scope = true;
            },
            .class_field_initializer => {
                // Treated as an implicit function scope: var declarations hoist here,
                // this is available, always strict (class context).
                scope_flags.is_var_scope = true;
                scope_flags.has_this_binding = true;
                scope_flags.strict_mode = true;
            },
        }

        // Inherit strict mode from parent.
        if (parent_id.isValid()) {
            if (self.getFlags(parent_id).strict_mode) {
                scope_flags.strict_mode = true;
            }
        }

        const var_scope: ScopeId = if (scope_flags.is_var_scope)
            id
        else if (parent_id.isValid())
            self.list.items(.var_scope)[parent_id.toInt()]
        else
            .none;

        try self.list.append(self.gpa, .{
            .kind = scope_kind,
            .flags = scope_flags,
            .parent = parent_id,
            .first_child = .none,
            .last_child = .none,
            .next_sibling = .none,
            .node_id = node_id,
            .bindings_start = 0,
            .bindings_count = 0,
            .var_scope = var_scope,
        });

        // Link into the parent's child list — O(1) via last_child pointer.
        if (parent_id.isValid()) {
            const last = self.list.items(.last_child)[parent_id.toInt()];
            if (!last.isValid()) {
                self.list.items(.first_child)[parent_id.toInt()] = id;
            } else {
                self.list.items(.next_sibling)[last.toInt()] = id;
            }
            self.list.items(.last_child)[parent_id.toInt()] = id;
        }

        return id;
    }

    /// Set the bindings range for a scope (index into the symbol table).
    pub fn setBindings(self: *ScopeTree, id: ScopeId, start: u32, count: u32) void {
        self.list.items(.bindings_start)[id.toInt()] = start;
        self.list.items(.bindings_count)[id.toInt()] = count;
    }

    pub fn setFlags(self: *ScopeTree, id: ScopeId, scope_flags: ScopeFlags) void {
        self.list.items(.flags)[id.toInt()] = scope_flags;
    }

    // ── Read-only accessors ────────────────────────────────

    pub fn parent(self: *const ScopeTree, id: ScopeId) ScopeId {
        return self.list.items(.parent)[id.toInt()];
    }

    pub fn kind(self: *const ScopeTree, id: ScopeId) ScopeKind {
        return self.list.items(.kind)[id.toInt()];
    }

    pub fn getFlags(self: *const ScopeTree, id: ScopeId) ScopeFlags {
        return self.list.items(.flags)[id.toInt()];
    }

    pub fn nodeId(self: *const ScopeTree, id: ScopeId) ast.NodeIndex {
        return self.list.items(.node_id)[id.toInt()];
    }

    pub fn getBindingsStart(self: *const ScopeTree, id: ScopeId) u32 {
        return self.list.items(.bindings_start)[id.toInt()];
    }

    pub fn getBindingsCount(self: *const ScopeTree, id: ScopeId) u32 {
        return self.list.items(.bindings_count)[id.toInt()];
    }

    // ── Traversal helpers ──────────────────────────────────

    /// Find the nearest enclosing var-scope (function or global).
    /// `var` declarations hoist to this scope.
    /// O(1): reads the precomputed `var_scope` field set at addScope time.
    pub fn nearestVarScope(self: *const ScopeTree, id: ScopeId) ScopeId {
        if (!id.isValid()) return .none;
        return self.list.items(.var_scope)[id.toInt()];
    }

    /// Nearest var-scope of the parent of `id` — i.e. the next var-scope up
    /// the tree.  Returns `.none` if `id` has no parent or no enclosing
    /// var-scope above it.  O(1) via the precomputed `var_scope` column.
    pub fn outerVarScope(self: *const ScopeTree, id: ScopeId) ScopeId {
        const p = self.parent(id);
        if (!p.isValid()) return .none;
        return self.list.items(.var_scope)[p.toInt()];
    }

    /// Find the nearest enclosing function scope.
    /// Returns `.none` if `id` is not inside any function (i.e. at module/global level).
    pub fn nearestFunctionScope(self: *const ScopeTree, id: ScopeId) ScopeId {
        var cur = id;
        while (cur.isValid()) {
            if (self.kind(cur) == .function) return cur;
            cur = self.parent(cur);
        }
        return .none;
    }

    /// Check if a scope is in strict mode.
    ///
    /// Strict mode is inherited: if any ancestor has `strict_mode` set, all
    /// descendants are strict.  Because `addScope` already propagates the
    /// flag downward at creation time, this is a simple flag read — no
    /// ancestor walk required.
    pub fn isStrictMode(self: *const ScopeTree, id: ScopeId) bool {
        return self.getFlags(id).strict_mode;
    }

    /// Compute the depth of a scope (distance to the root / global scope).
    /// The root scope has depth 0.
    pub fn depth(self: *const ScopeTree, id: ScopeId) u32 {
        var d: u32 = 0;
        var cur = self.parent(id);
        while (cur.isValid()) {
            d += 1;
            cur = self.parent(cur);
        }
        return d;
    }

    /// Check if `ancestor_id` is an ancestor of (or equal to) `id`.
    pub fn isAncestor(self: *const ScopeTree, id: ScopeId, ancestor_id: ScopeId) bool {
        var cur = id;
        while (cur.isValid()) {
            if (cur.toInt() == ancestor_id.toInt()) return true;
            cur = self.parent(cur);
        }
        return false;
    }

    /// Return the total number of scopes in the tree.
    pub fn len(self: *const ScopeTree) u32 {
        return @intCast(self.list.len);
    }
};

// ── Tests ──────────────────────────────────────────────────

test "global scope is var scope with this binding" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    try std.testing.expect(tree.getFlags(global).is_var_scope);
    try std.testing.expect(tree.getFlags(global).has_this_binding);
    try std.testing.expect(!tree.getFlags(global).strict_mode);
    try std.testing.expectEqual(@as(u32, 0), tree.depth(global));
}

test "module scope is always strict" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const mod = try tree.addScope(.module, .none, .root);
    try std.testing.expect(tree.isStrictMode(mod));
    try std.testing.expect(tree.getFlags(mod).is_var_scope);
}

test "class scope is always strict" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const class = try tree.addScope(.class, global, .none);
    try std.testing.expect(tree.isStrictMode(class));
    try std.testing.expect(!tree.isStrictMode(global));
}

test "strict mode inherits to children" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const mod = try tree.addScope(.module, .none, .root);
    const func = try tree.addScope(.function, mod, .none);
    const blk = try tree.addScope(.block, func, .none);

    try std.testing.expect(tree.isStrictMode(mod));
    try std.testing.expect(tree.isStrictMode(func));
    try std.testing.expect(tree.isStrictMode(blk));
}

test "var hoisting finds function scope" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const func = try tree.addScope(.function, global, .none);
    const blk = try tree.addScope(.block, func, .none);
    const inner = try tree.addScope(.block, blk, .none);

    // var in a nested block should hoist to the function scope.
    try std.testing.expectEqual(func, tree.nearestVarScope(inner));
    try std.testing.expectEqual(func, tree.nearestVarScope(blk));
    try std.testing.expectEqual(func, tree.nearestVarScope(func));
    try std.testing.expectEqual(global, tree.nearestVarScope(global));
}

test "function scope has arguments and this" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const func = try tree.addScope(.function, global, .none);

    try std.testing.expect(tree.getFlags(func).has_arguments);
    try std.testing.expect(tree.getFlags(func).has_this_binding);
    try std.testing.expect(tree.getFlags(func).is_var_scope);
}

test "catch clause scoping" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const func = try tree.addScope(.function, global, .none);
    const catch_scope = try tree.addScope(.catch_clause, func, .none);

    try std.testing.expectEqual(ScopeKind.catch_clause, tree.kind(catch_scope));
    // catch is not a var scope — var inside catch hoists to function.
    try std.testing.expect(!tree.getFlags(catch_scope).is_var_scope);
    try std.testing.expectEqual(func, tree.nearestVarScope(catch_scope));
}

test "depth counts parent hops" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const s0 = try tree.addScope(.global, .none, .root);
    const s1 = try tree.addScope(.function, s0, .none);
    const s2 = try tree.addScope(.block, s1, .none);
    const s3 = try tree.addScope(.block, s2, .none);

    try std.testing.expectEqual(@as(u32, 0), tree.depth(s0));
    try std.testing.expectEqual(@as(u32, 1), tree.depth(s1));
    try std.testing.expectEqual(@as(u32, 2), tree.depth(s2));
    try std.testing.expectEqual(@as(u32, 3), tree.depth(s3));
}

test "sibling linkage" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const a = try tree.addScope(.block, global, .none);
    const b = try tree.addScope(.block, global, .none);
    const c = try tree.addScope(.block, global, .none);

    // first_child of global should be `a`.
    try std.testing.expectEqual(a, tree.list.items(.first_child)[global.toInt()]);
    // Siblings: a -> b -> c -> none.
    try std.testing.expectEqual(b, tree.list.items(.next_sibling)[a.toInt()]);
    try std.testing.expectEqual(c, tree.list.items(.next_sibling)[b.toInt()]);
    try std.testing.expectEqual(ScopeId.none, tree.list.items(.next_sibling)[c.toInt()]);
}

test "isAncestor" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const func = try tree.addScope(.function, global, .none);
    const blk = try tree.addScope(.block, func, .none);

    try std.testing.expect(tree.isAncestor(blk, global));
    try std.testing.expect(tree.isAncestor(blk, func));
    try std.testing.expect(tree.isAncestor(blk, blk)); // self is ancestor of self
    try std.testing.expect(!tree.isAncestor(global, func));
}

test "nearestFunctionScope returns none at global level" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const blk = try tree.addScope(.block, global, .none);

    try std.testing.expectEqual(ScopeId.none, tree.nearestFunctionScope(global));
    try std.testing.expectEqual(ScopeId.none, tree.nearestFunctionScope(blk));
}

test "nearestFunctionScope finds enclosing function" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const outer = try tree.addScope(.function, global, .none);
    const blk = try tree.addScope(.block, outer, .none);
    const inner = try tree.addScope(.function, blk, .none);
    const deep = try tree.addScope(.block, inner, .none);

    try std.testing.expectEqual(inner, tree.nearestFunctionScope(deep));
    try std.testing.expectEqual(inner, tree.nearestFunctionScope(inner));
    try std.testing.expectEqual(outer, tree.nearestFunctionScope(blk));
}

test "static_block inherits strict and has this" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    const class = try tree.addScope(.class, global, .none);
    const sb = try tree.addScope(.static_block, class, .none);

    try std.testing.expect(tree.isStrictMode(sb));
    try std.testing.expect(tree.getFlags(sb).has_this_binding);
}

test "setBindings and getBindings" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    const global = try tree.addScope(.global, .none, .root);
    tree.setBindings(global, 10, 5);

    try std.testing.expectEqual(@as(u32, 10), tree.getBindingsStart(global));
    try std.testing.expectEqual(@as(u32, 5), tree.getBindingsCount(global));
}

test "len tracks scope count" {
    var tree = ScopeTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual(@as(u32, 0), tree.len());
    _ = try tree.addScope(.global, .none, .root);
    try std.testing.expectEqual(@as(u32, 1), tree.len());
    _ = try tree.addScope(.function, ScopeId.fromInt(0), .none);
    try std.testing.expectEqual(@as(u32, 2), tree.len());
}
