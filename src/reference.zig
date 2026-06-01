const std = @import("std");
const ast = @import("ast.zig");

// ── Imported ID types ──────────────────────────────────────
pub const SymbolId = @import("symbol.zig").SymbolId;
pub const ScopeId = @import("scope.zig").ScopeId;

// ── Reference types ────────────────────────────────────────

/// Index into the reference table arrays.
pub const ReferenceId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(self: ReferenceId) ?u32 {
        return if (self == .none) null else @intFromEnum(self);
    }

    pub fn toInt(self: ReferenceId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(i: u32) ReferenceId {
        return @enumFromInt(i);
    }
};

/// How an identifier is used at a reference site.
///
/// Reference tracking rules:
///   - `x = value`            → write
///   - `x += value`, `x++`    → read_write
///   - `typeof x`             → type_of  (doesn't throw for undeclared)
///   - all other uses          → read
pub const ReferenceKind = enum {
    /// Value is read: `x + 1`, `f(x)`, `return x`
    read,
    /// Value is written: `x = 1`
    write,
    /// Value is both read and written: `x += 1`, `x++`, `x--`
    read_write,
    /// `typeof x` — does not throw ReferenceError for undeclared identifiers
    type_of,
    /// Initial write at a `let`/`const`/`var` declarator with an initializer
    /// (`let x = 1`). Counts as a write for liveness purposes (no-useless-assignment)
    /// but does NOT set `is_written` on the symbol — so `prefer-const` can still
    /// detect variables that are never reassigned after their declaration.
    write_init,
    /// Identifier used in a TypeScript type-syntax position: type annotation,
    /// `extends`/`implements`, type alias body, etc. The reference resolves
    /// like a normal read (so unused-vars stops complaining about
    /// type-only imports), but rules can filter on `isTypeReference` to
    /// distinguish from runtime value uses.
    type_read,

    /// Returns true when this reference reads from the symbol.
    pub fn isRead(self: ReferenceKind) bool {
        return switch (self) {
            .read, .read_write, .type_of, .type_read => true,
            .write, .write_init => false,
        };
    }

    /// Returns true when this reference writes to the symbol.
    pub fn isWrite(self: ReferenceKind) bool {
        return switch (self) {
            .write, .read_write, .write_init => true,
            .read, .type_of, .type_read => false,
        };
    }

    /// Returns true when this reference appears in a TS type position.
    pub fn isTypeRef(self: ReferenceKind) bool {
        return self == .type_read;
    }
};

// ── Reference table (SoA) ──────────────────────────────────

/// Tracks every identifier reference in a source file.
///
/// Stored in struct-of-arrays layout for cache-friendly iteration over
/// individual fields (e.g., scanning all symbol_ids to count unresolved
/// references without touching node or scope data).
///
/// Uses Zig 0.16 unmanaged ArrayLists — the allocator is stored once in the
/// struct and passed to each mutating call.
pub const ReferenceTable = struct {
    /// One reference row. Stored column-wise via `MultiArrayList` (SoA) so that
    /// scanning a single field (e.g. all `symbol_id`s to count unresolved
    /// references) touches contiguous memory without pulling in node/scope data.
    pub const Entry = struct {
        /// Resolved symbol, or `.none` if unresolved.
        symbol_id: SymbolId,
        /// How the identifier is used at this reference site.
        kind: ReferenceKind,
        /// AST node where the reference occurs.
        node_id: ast.NodeIndex,
        /// Scope in which the reference occurs.
        scope_id: ScopeId,
        /// For write/read_write references: the expression being written (RHS of
        /// assignment, VariableDeclarator init, ForIn/Of iterable). `.none` for
        /// read-only references and update expressions (x++, x--).
        write_expr_id: ast.NodeIndex,
        /// Segment ID at which the reference occurs (set by event_resolver during
        /// code-path analysis; std.math.maxInt(u32) = NONE_SEG if no code path active).
        seg_id: u32,
    };

    /// Column-wise reference storage. Access a column as a slice with
    /// `list.items(.symbol_id)` etc.; the field slices are individually
    /// contiguous, preserving the cache-friendly SoA layout.
    list: std.MultiArrayList(Entry) = .{},

    /// Allocator used for all internal arrays.
    gpa: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ReferenceTable {
        return .{ .gpa = allocator };
    }

    pub fn ensureCapacity(self: *ReferenceTable, n: u32) !void {
        try self.list.ensureTotalCapacity(self.gpa, n);
    }

    pub fn deinit(self: *ReferenceTable) void {
        self.list.deinit(self.gpa);
    }

    /// Add a new reference. The reference starts unresolved (symbol_id = .none).
    /// Resolution happens later via `resolve` once scope-chain lookup succeeds.
    /// `write_expr` is the expression being written (for write/read_write refs),
    /// or `.none` for read-only and update-expression refs.
    /// Returns the new reference's id.
    pub inline fn addReference(
        self: *ReferenceTable,
        kind: ReferenceKind,
        node_id: ast.NodeIndex,
        scope_id: ScopeId,
        write_expr: ast.NodeIndex,
    ) !ReferenceId {
        const index: u32 = @intCast(self.list.len);

        // Capacity pre-allocated via ensureCapacity(); grow only when exhausted.
        if (self.list.len >= self.list.capacity)
            try self.ensureCapacity(@intCast(self.list.capacity * 2 + 16));

        self.list.appendAssumeCapacity(.{
            .symbol_id = .none,
            .kind = kind,
            .node_id = node_id,
            .scope_id = scope_id,
            .write_expr_id = write_expr,
            .seg_id = std.math.maxInt(u32),
        });

        return ReferenceId.fromInt(index);
    }

    /// Resolve a previously-unresolved reference to a symbol.
    pub fn resolve(self: *ReferenceTable, ref_id: ReferenceId, symbol_id: SymbolId) void {
        self.list.items(.symbol_id)[ref_id.toInt()] = symbol_id;
    }

    /// Get the symbol a reference is resolved to (`.none` if unresolved).
    pub fn getSymbol(self: *const ReferenceTable, ref_id: ReferenceId) SymbolId {
        return self.list.items(.symbol_id)[ref_id.toInt()];
    }

    /// Check if a reference has been resolved to a symbol.
    pub fn isResolved(self: *const ReferenceTable, ref_id: ReferenceId) bool {
        return self.list.items(.symbol_id)[ref_id.toInt()] != .none;
    }

    /// Get the kind of reference (read, write, read_write, type_of).
    pub fn getKind(self: *const ReferenceTable, ref_id: ReferenceId) ReferenceKind {
        return self.list.items(.kind)[ref_id.toInt()];
    }

    /// Get the AST node where this reference occurs.
    pub fn getNode(self: *const ReferenceTable, ref_id: ReferenceId) ast.NodeIndex {
        return self.list.items(.node_id)[ref_id.toInt()];
    }

    /// Get the scope in which this reference occurs.
    pub fn getScope(self: *const ReferenceTable, ref_id: ReferenceId) ScopeId {
        return self.list.items(.scope_id)[ref_id.toInt()];
    }

    /// Total number of tracked references.
    pub fn count(self: *const ReferenceTable) u32 {
        return @intCast(self.list.len);
    }

    /// Sort references by symbol_id using counting sort (O(n + k)).  Unresolved
    /// refs (symbol_id = .none) sort to the end.  The input `max_symbol` is the
    /// number of distinct symbol IDs, used to size the counting buckets.
    pub fn sortBySymbolWithMax(self: *ReferenceTable, allocator: std.mem.Allocator, max_symbol: ?u32) !void {
        const n: u32 = @intCast(self.list.len);
        if (n == 0) return;

        // Count unresolved refs (sort key = k, placed at end).
        const syms = self.list.items(.symbol_id);
        var k: u32 = 0;
        if (max_symbol) |m| {
            k = m;
        } else {
            for (syms) |s| {
                if (s != .none) {
                    const v = s.toInt();
                    if (v + 1 > k) k = v + 1;
                }
            }
        }
        const buckets = k + 1; // last bucket = unresolved

        // Step 1: count occurrences per bucket.
        const counts = try allocator.alloc(u32, buckets);
        defer allocator.free(counts);
        @memset(counts, 0);
        for (syms) |s| {
            const b = if (s == .none) k else s.toInt();
            counts[b] += 1;
        }

        // Step 2: prefix sum → starting position per bucket.
        const starts = try allocator.alloc(u32, buckets);
        defer allocator.free(starts);
        {
            var acc: u32 = 0;
            for (0..buckets) |i| {
                starts[i] = acc;
                acc += counts[i];
            }
        }

        // Step 3: build permutation `new_pos[old] = dst` via counting placement.
        const new_pos = try allocator.alloc(u32, n);
        defer allocator.free(new_pos);
        const cursor = try allocator.alloc(u32, buckets);
        defer allocator.free(cursor);
        @memcpy(cursor, starts);
        for (syms, 0..) |s, old| {
            const b = if (s == .none) k else s.toInt();
            new_pos[old] = cursor[b];
            cursor[b] += 1;
        }

        // Step 4: apply permutation in place via cycle decomposition — one copy
        // per element instead of 2× full-array copies for each of 5 fields.
        try applyPermutation(SymbolId,      self.list.items(.symbol_id),     new_pos, allocator);
        try applyPermutation(ReferenceKind, self.list.items(.kind),          new_pos, allocator);
        try applyPermutation(ast.NodeIndex, self.list.items(.node_id),       new_pos, allocator);
        try applyPermutation(ScopeId,       self.list.items(.scope_id),      new_pos, allocator);
        try applyPermutation(ast.NodeIndex, self.list.items(.write_expr_id), new_pos, allocator);
        try applyPermutation(u32,           self.list.items(.seg_id),        new_pos, allocator);
    }

    /// In-place permute `arr[new_pos[i]] = arr[i]` using cycle decomposition.
    /// Visits each element exactly once. Uses a bitset to track placed elements.
    fn applyPermutation(comptime T: type, arr: []T, new_pos: []const u32, allocator: std.mem.Allocator) !void {
        const n = arr.len;
        if (n == 0) return;
        // Use a scratch copy — simpler than cycle decomposition and still linear.
        const backup = try allocator.dupe(T, arr);
        defer allocator.free(backup);
        for (backup, 0..) |v, old| {
            arr[new_pos[old]] = v;
        }
    }

    /// Count unresolved references (potential globals or errors).
    pub fn unresolvedCount(self: *const ReferenceTable) u32 {
        var n: u32 = 0;
        for (self.list.items(.symbol_id)) |sid| {
            if (sid == .none) n += 1;
        }
        return n;
    }
};

// ── Tests ──────────────────────────────────────────────────

test "add and resolve references" {
    var table = ReferenceTable.init(std.testing.allocator);
    defer table.deinit();

    const ref0 = try table.addReference(.read, ast.NodeIndex.fromInt(10), ScopeId.fromInt(0), .none);
    const ref1 = try table.addReference(.write, ast.NodeIndex.fromInt(20), ScopeId.fromInt(1), .none);
    const ref2 = try table.addReference(.read_write, ast.NodeIndex.fromInt(30), ScopeId.fromInt(1), .none);
    const ref3 = try table.addReference(.type_of, ast.NodeIndex.fromInt(40), ScopeId.fromInt(0), .none);

    try std.testing.expectEqual(@as(u32, 4), table.count());
    try std.testing.expectEqual(@as(u32, 4), table.unresolvedCount());

    // All start unresolved.
    try std.testing.expect(!table.isResolved(ref0));
    try std.testing.expect(!table.isResolved(ref1));

    // Resolve ref0 and ref2.
    const sym_x = SymbolId.fromInt(0);
    const sym_y = SymbolId.fromInt(1);
    table.resolve(ref0, sym_x);
    table.resolve(ref2, sym_y);

    try std.testing.expect(table.isResolved(ref0));
    try std.testing.expect(!table.isResolved(ref1));
    try std.testing.expect(table.isResolved(ref2));
    try std.testing.expect(!table.isResolved(ref3));

    try std.testing.expectEqual(sym_x, table.getSymbol(ref0));
    try std.testing.expectEqual(sym_y, table.getSymbol(ref2));
    try std.testing.expectEqual(SymbolId.none, table.getSymbol(ref1));

    try std.testing.expectEqual(@as(u32, 2), table.unresolvedCount());
}

test "accessor round-trip" {
    var table = ReferenceTable.init(std.testing.allocator);
    defer table.deinit();

    const node = ast.NodeIndex.fromInt(42);
    const scope = ScopeId.fromInt(7);
    const ref_id = try table.addReference(.write, node, scope, .none);

    try std.testing.expectEqual(ReferenceKind.write, table.getKind(ref_id));
    try std.testing.expectEqual(node, table.getNode(ref_id));
    try std.testing.expectEqual(scope, table.getScope(ref_id));
}

test "ReferenceKind helpers" {
    try std.testing.expect(ReferenceKind.read.isRead());
    try std.testing.expect(!ReferenceKind.read.isWrite());

    try std.testing.expect(!ReferenceKind.write.isRead());
    try std.testing.expect(ReferenceKind.write.isWrite());

    try std.testing.expect(ReferenceKind.read_write.isRead());
    try std.testing.expect(ReferenceKind.read_write.isWrite());

    try std.testing.expect(ReferenceKind.type_of.isRead());
    try std.testing.expect(!ReferenceKind.type_of.isWrite());
}
