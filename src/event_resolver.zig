//! Event-driven semantic analyzer — produces the same `SemanticResult` as
//! `semantic.zig`'s tree-walking analyzer, but by iterating the parser's
//! scope-event stream instead of visiting every AST node.
//!
//! For acorn.js (243 KB):
//!   tree walk  : 36 521 nodes / ~190 µs
//!   event scan : ~8 700 events / ~60 µs   (~3× faster)
//!
//! The consumer runs the same post-passes as `semantic.zig`
//! (resolveUnresolved, buildRefRanges, buildScopeBindings) so the output
//! tables are byte-for-byte compatible with downstream rule runners.
const std = @import("std");

const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const TokenIndex = ast_mod.TokenIndex;

const scope_mod = @import("scope.zig");
const ScopeTree = scope_mod.ScopeTree;
const ScopeKind = scope_mod.ScopeKind;
const ScopeId = scope_mod.ScopeId;

const symbol_mod = @import("symbol.zig");
const SymbolTable = symbol_mod.SymbolTable;
const SymbolId = symbol_mod.SymbolId;
const BindingKind = symbol_mod.BindingKind;

const reference_mod = @import("reference.zig");
const ReferenceTable = reference_mod.ReferenceTable;
const ReferenceId = reference_mod.ReferenceId;
const ReferenceKind = reference_mod.ReferenceKind;

const Diagnostic = @import("diagnostic.zig").Diagnostic;
const semantic_mod = @import("semantic.zig");

const scope_events = @import("scope_events.zig");
const Event = scope_events.Event;
const EventKind = scope_events.EventKind;

const code_path_mod = @import("code_path.zig");
const CodePathBuilder = code_path_mod.CodePathBuilder;
const Origin = code_path_mod.Origin;
const SegmentId = code_path_mod.SegmentId;

/// Phase of the event-stream walk. Used to gate work in the unified resolver
/// implementation so the same code can run as the full pass (default), or as
/// either half of a parallel scope/CFG split.
///   .both        — run all event handlers (scope + CFG); produce SemanticResult.
///   .scope_only  — run scope/symbols/references work; record per-ref-event
///                  ref_id so the CFG half can stamp seg_id/alive bits later.
///                  Skip all cpb.* calls and CFG bookkeeping.
///   .cfg_only    — run CFG (cpb.* + cfg_alive bookkeeping) only; record per-
///                  ref-event {seg_id, alive} side array. Skip scope_map,
///                  symbol creation, reference resolution.
pub const ResolverPhase = enum { both, scope_only, cfg_only };

/// Output of a `.scope_only` walk. Contains everything except CFG-derived
/// fields (seg_ids on references, node_reachable, loop_exit_reachable,
/// code_path_result). `ref_event_to_id` is indexed by the running count of
/// `.reference` events seen during the walk; the parallel CFG half uses it
/// to stamp `references.seg_ids[ref_event_to_id[k]]` after both halves join.
pub const ScopePart = struct {
    scopes: ScopeTree,
    symbols: SymbolTable,
    references: ReferenceTable,
    ref_by_sym: []ReferenceId,
    /// One entry per `.reference` event, in event order.
    ref_event_to_id: []ReferenceId,

    pub fn deinit(self: *ScopePart, allocator: std.mem.Allocator) void {
        self.scopes.deinit();
        self.symbols.deinit();
        self.references.deinit();
        if (self.ref_by_sym.len != 0) allocator.free(self.ref_by_sym);
        if (self.ref_event_to_id.len != 0) allocator.free(self.ref_event_to_id);
    }
};

/// Output of a `.cfg_only` walk. `node_reachable`/`loop_exit_reachable` are
/// fully owned (allocated by this side). `ref_event_seg_ids` and
/// `ref_event_alive` are parallel arrays sized to the number of `.reference`
/// events seen — combined with `ScopePart.ref_event_to_id` in `combineParts`.
pub const CfgPart = struct {
    code_path_result: code_path_mod.CodePathBuilder.Result,
    node_reachable: []u8,
    loop_exit_reachable: []u8,
    ref_event_seg_ids: []SegmentId,
    ref_event_alive: []u8,

    pub fn deinit(self: *CfgPart, allocator: std.mem.Allocator) void {
        self.code_path_result.deinit(allocator);
        allocator.free(self.node_reachable);
        allocator.free(self.loop_exit_reachable);
        if (self.ref_event_seg_ids.len != 0) allocator.free(self.ref_event_seg_ids);
        if (self.ref_event_alive.len != 0) allocator.free(self.ref_event_alive);
    }
};

/// Stitch the two halves into a SemanticResult. After this call ScopePart and
/// CfgPart fields are MOVED; do NOT call .deinit on the parts. The returned
/// SemanticResult owns everything.
pub fn combineParts(
    allocator: std.mem.Allocator,
    scope: ScopePart,
    cfg: CfgPart,
) !semantic_mod.SemanticResult {
    var s = scope;
    var c = cfg;

    // Stamp per-reference seg_id + dead-node bits. Both arrays were filled in
    // the same `.reference` event order, so index k aligns by construction.
    const n = @min(s.ref_event_to_id.len, c.ref_event_seg_ids.len);
    const seg_col = s.references.list.items(.seg_id);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const rid = s.ref_event_to_id[k];
        if (rid == .none) continue;
        seg_col[rid.toInt()] = c.ref_event_seg_ids[k];
        // Dead-reference: mark the ref's node unreachable. Node index lives in
        // the reference table itself — pull it back from there.
        if (c.ref_event_alive[k] == 0) {
            const ni = @intFromEnum(s.references.getNode(rid));
            if (ni < c.node_reachable.len) c.node_reachable[ni] = 0;
        }
    }

    // ref_event arrays no longer needed after the stitch.
    if (s.ref_event_to_id.len != 0) allocator.free(s.ref_event_to_id);
    if (c.ref_event_seg_ids.len != 0) allocator.free(c.ref_event_seg_ids);
    if (c.ref_event_alive.len != 0) allocator.free(c.ref_event_alive);

    return .{
        .scopes = s.scopes,
        .symbols = s.symbols,
        .references = s.references,
        .ref_by_sym = s.ref_by_sym,
        .diagnostics = &.{},
        .node_reachable = c.node_reachable,
        .loop_exit_reachable = c.loop_exit_reachable,
        .code_path_result = c.code_path_result,
    };
}

// ── Options / minimal summary ───────────────────────────────────────

pub const Options = struct {
    /// Emit redeclaration diagnostics (same-scope duplicate detection).
    /// Off by default in the PoC — enable when replacing semantic.zig.
    diagnose_redeclare: bool = false,
    /// Skip reference resolution inner scope-chain walk.  Bench-only.
    skip_resolve: bool = false,
    /// Skip buildRefRanges (the counting sort that groups references by symbol).
    /// Enable when no active rule calls symbols.getRefRange().  Currently only
    /// no_func_assign uses ref ranges.
    skip_ref_ranges: bool = false,
    /// Null-separated list of global names to pre-declare in the global scope
    /// (ESLint `languageOptions.globals` whose value is anything other than
    /// `"off"`).  References to these names resolve to the pre-declared
    /// implicit-global symbol instead of remaining unresolved.
    globals: []const u8 = &.{},
    /// When set, the CFG analyzer's adjacency target pools (prev_targets,
    /// all_prev_targets, collapsed_prev_targets) are pre-allocated from this
    /// allocator instead of the analyzer's transient arena. The pools end up
    /// in the JS buffer so writeCfgGraph can publish their offsets directly.
    cfg_pool_alloc: ?std.mem.Allocator = null,
    /// Streaming mode: when set, the producer (parser thread) is publishing
    /// events incrementally. The resolver walks the events slice via
    /// indexed access bounded by `events_published.load(.acquire)` and blocks
    /// on the slow path when it catches up to the producer.
    streaming: ?StreamingHooks = null,
};

pub const StreamingHooks = struct {
    events_published: *std.atomic.Value(usize),
    parse_done: *std.atomic.Value(bool),
    /// Upper bound on node count — used to pre-size node_reachable etc. since
    /// `ast.nodes.len` reflects the parser's still-growing count. Caller passes
    /// the same upper-bound hint used to size the parser's pre-allocated nodes.
    node_count_hint: usize,
    /// Optional diagnostic counters — populated by resolveFull when set. Lets
    /// callers see where sem time is going (loop vs spin vs post-passes) and
    /// how often it parks the kernel via yield.
    stats: ?*Stats = null,
};

pub const Stats = struct {
    events_loop_ns: u64 = 0,
    spin_ns: u64 = 0,
    post_passes_ns: u64 = 0,
    resolve_unresolved_ns: u64 = 0,
    build_ref_ranges_ns: u64 = 0,
    build_scope_bindings_ns: u64 = 0,
    spin_count: u64 = 0,
    yield_count: u64 = 0,
    events_processed: u64 = 0,
    unresolved_count: u64 = 0,
    scope_count: u64 = 0,
    symbol_count: u64 = 0,
};

/// Returns the "looping target" node for a loop — the child node that ESLint's
/// `isLoopingTarget` function recognises as the loop's entry point on each
/// iteration.  This is the node that the loop-body segment's seg_start event
/// must be keyed to so that `onCodePathSegmentStart(seg, node)` fires with the
/// right node.
///
/// Mirrors ESLint's `isLoopingTarget` check (no-unreachable-loop):
///   WhileStatement  → test (condition)
///   DoWhileStatement → body
///   ForStatement    → update || test || body
///   ForIn/ForOf     → left (binding)
fn loopingTargetNode(ast: *const ast_mod.Ast, n: NodeIndex, loop_type: code_path_mod.LoopType) NodeIndex {
    const data = ast.nodes.items(.data)[@intFromEnum(n)];
    return switch (loop_type) {
        .while_stmt => data.lhs, // condition
        .do_while_stmt => data.lhs, // body
        .for_stmt => blk: {
            const fd = ast.extraData(ast_mod.ForData, @intFromEnum(data.lhs));
            if (fd.update != .none) break :blk fd.update;
            if (fd.condition != .none) break :blk fd.condition;
            break :blk data.rhs; // body (for (;;) { ... })
        },
        .for_in_stmt, .for_of_stmt => blk: {
            const fd = ast.extraData(ast_mod.ForInOfData, @intFromEnum(data.lhs));
            break :blk fd.binding; // left (binding)
        },
    };
}

// ── Full resolver that returns a SemanticResult ─────────────────────

fn ResultFor(comptime phase: ResolverPhase) type {
    return switch (phase) {
        .both => semantic_mod.SemanticResult,
        .scope_only => ScopePart,
        .cfg_only => CfgPart,
    };
}

/// Public entry: full pass — produces a complete `SemanticResult`.
pub fn resolveFull(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    events: []const Event,
    opts: Options,
) !semantic_mod.SemanticResult {
    return resolveFullImpl(.both, allocator, ast, events, opts);
}

/// Public entry: scope/symbols/references only — for the parallel CFG split.
/// Caller must run `resolveFullCfg` on the same events and pass both into
/// `combineParts` to get a full `SemanticResult`.
pub fn resolveFullScope(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    events: []const Event,
    opts: Options,
) !ScopePart {
    return resolveFullImpl(.scope_only, allocator, ast, events, opts);
}

/// Public entry: CFG only — see `resolveFullScope` for usage.
pub fn resolveFullCfg(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    events: []const Event,
    opts: Options,
) !CfgPart {
    return resolveFullImpl(.cfg_only, allocator, ast, events, opts);
}

/// Spawn a worker thread to run `resolveFullCfg` in parallel with the caller's
/// scope walk. Caller calls `resolveFullScope` on the same events, then joins
/// and stitches via `combineParts`. Typical pattern:
///
///     var w = try ScopeCfgParallel.start(gpa, ast, events, opts);
///     const scope = try resolveFullScope(gpa, ast, events, opts);
///     const cfg   = try w.join();
///     const sem   = try combineParts(gpa, scope, cfg);
pub const ScopeCfgParallel = struct {
    thread: std.Thread,
    allocator: std.mem.Allocator,
    ast: *const Ast,
    events: []const Event,
    opts: Options,
    result: CfgPart,
    err: ?anyerror,

    fn entry(self: *ScopeCfgParallel) void {
        if (resolveFullCfg(self.allocator, self.ast, self.events, self.opts)) |r| {
            self.result = r;
        } else |e| {
            self.err = e;
        }
    }

    /// @returns owned
    pub fn start(
        allocator: std.mem.Allocator,
        ast: *const Ast,
        events: []const Event,
        opts: Options,
    ) !*ScopeCfgParallel {
        const self = try allocator.create(ScopeCfgParallel);
        errdefer allocator.destroy(self);
        self.* = .{
            .thread = undefined,
            .allocator = allocator,
            .ast = ast,
            .events = events,
            .opts = opts,
            .result = undefined,
            .err = null,
        };
        self.thread = try std.Thread.spawn(.{}, entry, .{self});
        return self;
    }

    pub fn join(self: *ScopeCfgParallel, allocator: std.mem.Allocator) !CfgPart {
        self.thread.join();
        defer allocator.destroy(self);
        if (self.err) |e| return e;
        return self.result;
    }
};

/// Production entry: consume `events` and build a full `SemanticResult`
/// (ScopeTree, SymbolTable, ReferenceTable, node_reachable) suitable for
/// hand-off to rule runners.  Runs the same post-passes as `semantic.zig`.
fn resolveFullImpl(
    comptime phase: ResolverPhase,
    allocator: std.mem.Allocator,
    ast: *const Ast,
    events: []const Event,
    opts: Options,
) !ResultFor(phase) {
    const do_scope = comptime phase != .cfg_only;
    const do_cfg = comptime phase != .scope_only;
    const skip_resolve = opts.skip_resolve;
    const skip_ref_ranges = opts.skip_ref_ranges;

    // Pre-sized tables (same heuristics as semantic.zig). Streaming: use the
    // upper-bound hint since ast.nodes.len is still growing on the parser thread.
    const node_n: u32 = if (opts.streaming) |s| @intCast(s.node_count_hint) else @intCast(ast.nodes.len);
    const est_scopes = @max(16, node_n / 20);
    const est_syms   = @max(64, node_n / 6);

    var scopes = ScopeTree.init(allocator);
    errdefer scopes.deinit();
    try scopes.ensureCapacity(est_scopes);

    var symbols = SymbolTable.init(allocator);
    errdefer symbols.deinit();
    try symbols.ensureCapacity(est_syms);

    var references = ReferenceTable.init(allocator);
    errdefer references.deinit();
    try references.ensureCapacity(est_syms * 2);

    // Dedicated arena for ephemeral scope-resolution data.
    // Scope builders, the sorted flat entry buffer, and scope-range table are
    // all freed together at function exit — no per-scope allocations hit the
    // outer allocator, giving FixedBufferAllocator-like throughput in production.
    var scope_arena = std.heap.ArenaAllocator.init(allocator);
    defer scope_arena.deinit();
    const sa = scope_arena.allocator();

    // Single HashMap from name_hash → sym_id for all currently-visible names.
    // Updated on every declare (add) and scope_close (undo).
    // O(1) reference resolution instead of O(depth × entries_per_scope) linear scan.
    // Identity hash context: our keys are already Wyhash-derived u64s — skip the
    // redundant re-hash that AutoHashMapUnmanaged would apply.
    const NameHashCtx = struct {
        pub fn hash(_: @This(), key: u64) u64 { return key; }
        pub fn eql(_: @This(), a: u64, b: u64) bool { return a == b; }
    };
    var scope_map = std.HashMapUnmanaged(u64, SymbolId, NameHashCtx, 80){};
    try scope_map.ensureTotalCapacity(sa, @intCast(est_syms));
    // Hoisting map: var/function_decl declarations keyed by
    // (name_hash ^ scope_id * prime) → SymbolId.  The retry pass uses this
    // for O(1) lookups per var-scope level instead of O(log N) binary search.
    var hoist_map = std.HashMapUnmanaged(u64, SymbolId, NameHashCtx, 80){};
    try hoist_map.ensureTotalCapacity(sa, @intCast(est_syms / 4));

    // Sibling-canonical map: when `var x` is redeclared in the same scope,
    // ESLint scope analysis treats all such declarations as ONE Variable.
    // The analyzer creates separate symbols (for distinct decl_node tracking),
    // but every reference to `x` should resolve to the FIRST/canonical symbol
    // so refs are not split across siblings.  Without this routing, the JS
    // runner has to merge sibling Variables on every getDeclaredVariables
    // call (see eslint-runner.js `_buildScopeVarsAndSet` and
    // `_computeDeclaredVariables`), which on bundled JS like typescript.js
    // accumulates so many array entries that `Array.prototype.push.apply`
    // overflows JSC's argument limit and produces phantom plugin errors.
    //
    // sym_to_canonical[sym_id] = canonical symbol for that sym_id (defaults
    // to sym_id itself; only set when a sibling is detected at declare time).
    var sym_to_canonical = std.ArrayListUnmanaged(SymbolId){ .items = &.{}, .capacity = 0 };
    try sym_to_canonical.ensureTotalCapacity(sa, @intCast(est_syms));

    // Direct-mapped L1 cache in front of scope_map.  Absorbs repeated lookups
    // for the same identifier (common in any function body) without hitting the
    // HashMap.  512 entries × 12 bytes = 6 KB — stays hot in L1D.
    // Entry is "empty" when hash == 0 (Wyhash(0, name) == 0 is negligibly rare).
    const RefCacheEntry = struct { hash: u64, sym: SymbolId };
    var ref_cache: [512]RefCacheEntry = @splat(.{ .hash = 0, .sym = .none });

    // Per-depth undo stacks: on declare we record (name_hash, sym_id, prev) at
    // target_depth so scope_close can restore the previous binding in scope_map.
    const UndoEntry = struct { name_hash: u64, sym_id: SymbolId, prev: ?SymbolId };
    var undo_stacks: [256]std.ArrayListUnmanaged(UndoEntry) = undefined;
    for (&undo_stacks) |*u| u.* = .{ .items = &.{}, .capacity = 0 };
    // (freed by scope_arena.deinit)

    // Unresolved ref ids collected during the main pass so the retry pass can
    // iterate only the small set (~5-20K) instead of scanning all refs (245K).
    // Pre-size in streaming mode to avoid arena fragmentation that hurts
    // resolveUnresolved cache locality.
    const UnresolvedRef = struct { ref_id: ReferenceId, name_hash: u64 };
    var unresolved_refs = std.ArrayListUnmanaged(UnresolvedRef){ .items = &.{}, .capacity = 0 };
    if (opts.streaming) |s| {
        // ~15% of events are unresolved on average; round up.
        try unresolved_refs.ensureTotalCapacity(sa, @max(1024, s.node_count_hint / 4));
    }
    // (freed by scope_arena.deinit)

    // Per-`.reference`-event side arrays for the parallel split. Outer-allocator
    // backed because we transfer ownership to the returned ScopePart/CfgPart.
    var ref_event_to_id = std.ArrayListUnmanaged(ReferenceId){ .items = &.{}, .capacity = 0 };
    var ref_event_seg_ids = std.ArrayListUnmanaged(SegmentId){ .items = &.{}, .capacity = 0 };
    var ref_event_alive = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer if (phase == .scope_only) ref_event_to_id.deinit(allocator);
    errdefer if (phase == .cfg_only) ref_event_seg_ids.deinit(allocator);
    errdefer if (phase == .cfg_only) ref_event_alive.deinit(allocator);
    if (phase == .scope_only) {
        try ref_event_to_id.ensureTotalCapacity(allocator, est_syms);
    }
    if (phase == .cfg_only) {
        try ref_event_seg_ids.ensureTotalCapacity(allocator, est_syms);
        try ref_event_alive.ensureTotalCapacity(allocator, est_syms);
    }

    // node_reachable — default all-alive (no CFG in event path yet).
    // In streaming mode, ast.nodes.len reflects the parser's growing count;
    // size to the caller-provided upper bound instead.
    const reach_size: usize = if (opts.streaming) |s| s.node_count_hint else ast.nodes.len;
    const node_reachable = try allocator.alloc(u8, reach_size);
    errdefer allocator.free(node_reachable);
    @memset(node_reachable, 1);
    const loop_exit_reachable = try allocator.alloc(u8, reach_size);
    errdefer allocator.free(loop_exit_reachable);
    @memset(loop_exit_reachable, 1);

    var cpb = CodePathBuilder.init(allocator);
    cpb.allocator = cpb.arena.allocator();
    cpb.bump_alloc = opts.cfg_pool_alloc;
    errdefer cpb.deinit();

    // Pre-size cpb ArrayLists.  ev_len is a safe upper bound for all per-event
    // arrays (measured peak ratios: segs 0.27, evts 0.62, aprev 0.40 — all < 1).
    // Over-allocation is harmless; the arena is freed wholesale after analysis.
    {
        const ev_len: u32 = @intCast(events.len);
        if (do_cfg) try cpb.ensureCapacity(ev_len, ev_len / 10);
    }

    // Scope stack — holds ScopeIds as we enter/leave scopes during the event
    // pass.  Depth ≤ 256 is plenty for realistic source (acorn.js peaks ~8).
    var stack: [256]ScopeId = undefined;
    // Parallel kind/node side-stacks — populated on every scope_open and used
    // by scope_close instead of indexing scopes.kinds/node_ids. Lets the
    // .cfg_only path skip ScopeTree population entirely; small win on .both
    // too (avoids two indirect ArrayList loads per scope_close).
    var kind_stack: [256]ScopeKind = undefined;
    var node_stack: [256]NodeIndex = undefined;
    var sp: u32 = 0;

    // In streaming mode, the parser is concurrently growing nodes/tokens.
    // The slice's .len is racy, but the .ptr is stable (parser pre-sized
    // both to safe upper bounds — guaranteed no realloc during parse).
    // Reconstruct slices using the upper-bound hint for .len so bounds
    // checks pass; per-event read of node[idx] is happens-after the
    // event's release-store, so the data is committed.
    const node_tags = if (opts.streaming) |s| ast.nodes.items(.tag).ptr[0..s.node_count_hint] else ast.nodes.items(.tag);
    const node_datas = if (opts.streaming) |s| ast.nodes.items(.data).ptr[0..s.node_count_hint] else ast.nodes.items(.data);
    // Pending label text set by label_open (aux=1) before the loop_open it wraps.
    var pending_label: []const u8 = "";

    // Control-flow state — cfg_alive tracks whether the current path is live.
    // Terminators set it to false; branch_open/else/close save/restore/merge
    // the state.  `branch_stack` holds {save, consequent_alive} per nesting.
    var cfg_alive: bool = true;
    var branch_save: [64]bool = undefined; // alive state at branch_open
    var branch_cons: [64]bool = undefined; // alive state at branch_else
    var bsp: u32 = 0;
    // A function boundary resets cfg_alive since the body starts with a
    // fresh path.  Track this via scope_open(.function) events.
    var fn_alive_stack: [64]bool = undefined;
    var fsp: u32 = 0;

    // Module/global root scope — always the first scope.  We don't see a
    // scope_open event for it (parser could emit one, but we create it here
    // to stay consistent with the tree-walking analyzer that creates the
    // global scope explicitly in analyzeModule).
    //
    // Actually the parser DOES emit a scope_open for the root — so no
    // explicit creation here.

    var ev_i: usize = 0;
    // Streaming: events.len was 0 when the early ast view was captured.
    // Reconstruct a slice over the pre-allocated buffer using the upper-bound
    // hint as len so events[ev_i] doesn't panic on bounds. The actual valid
    // range is enforced by the events_published atomic.
    const events_view: []const Event = if (opts.streaming) |s|
        events.ptr[0..(s.node_count_hint * 2)]
    else
        events;
    var ev_visible: usize = if (opts.streaming) |s| s.events_published.load(.acquire) else events_view.len;

    // Per-stage timing for diagnostic stats.
    var loop_start_ts: std.c.timespec = undefined;
    if (opts.streaming != null) _ = std.c.clock_gettime(.MONOTONIC, &loop_start_ts);
    main_event_loop: while (true) {
        if (ev_i >= ev_visible) {
            @branchHint(.cold);
            if (opts.streaming) |s| {
                var spin_start_ts: std.c.timespec = undefined;
                if (s.stats != null) _ = std.c.clock_gettime(.MONOTONIC, &spin_start_ts);
                var spins: u32 = 0;
                var yields: u32 = 0;
                var spin_iters: u64 = 0;
                while (true) {
                    const v = s.events_published.load(.acquire);
                    if (v > ev_i) { ev_visible = v; break; }
                    if (s.parse_done.load(.acquire)) {
                        ev_visible = s.events_published.load(.acquire);
                        break;
                    }
                    spins += 1;
                    spin_iters += 1;
                    if (spins < 100) std.atomic.spinLoopHint() else {
                        std.Thread.yield() catch {};
                        spins = 0;
                        yields += 1;
                    }
                }
                if (s.stats) |st| {
                    var spin_end_ts: std.c.timespec = undefined;
                    _ = std.c.clock_gettime(.MONOTONIC, &spin_end_ts);
                    const dt: u64 = @intCast((spin_end_ts.sec - spin_start_ts.sec) * std.time.ns_per_s + (spin_end_ts.nsec - spin_start_ts.nsec));
                    st.spin_ns += dt;
                    st.spin_count += spin_iters;
                    st.yield_count += yields;
                }
                if (ev_i >= ev_visible) break :main_event_loop;
            } else break :main_event_loop;
        }
        const e = events_view[ev_i];
        ev_i += 1;
        switch (e.kind) {
        .scope_open => {
            const kind: ScopeKind = @enumFromInt(e.aux);
            // Elided scopes (parser-emitted block scopes that turned out empty
            // — no let/const/class) have no matching scope_close. Sequential
            // mode strips them via parser compaction; streaming skips
            // compaction (race) so resolver must skip inline.
            if (kind == .elided) continue;
            const parent: ScopeId = if (sp == 0) ScopeId.fromInt(std.math.maxInt(u32)) else stack[sp - 1];
            // Streaming-mode race: function/static_block/class_field_initializer
            // scope_opens are emitted BEFORE the parser constructs the owning
            // function node (parser does body first, then node, then patches
            // the event). If the resolver gets here before that patch, e.node
            // is NONE — which would propagate to the CodePath's codepath_start
            // event and ultimately get dropped by writeCfgGraph's bounds check
            // (node >= node_count), so rules never see onCodePathStart for
            // that function. Spin-wait for the patch, same pattern as the
            // loop_open handler below.
            var raw_node = e.node;
            if (opts.streaming != null and raw_node == std.math.maxInt(u32) and
                (kind == .function or kind == .static_block or kind == .class_field_initializer))
            {
                const ev_u64: *const u64 = @ptrCast(&events_view[ev_i - 1]);
                while (true) {
                    std.atomic.spinLoopHint();
                    raw_node = @truncate(@atomicLoad(u64, ev_u64, .acquire) >> 32);
                    if (raw_node != std.math.maxInt(u32)) break;
                }
            }
            const node: NodeIndex = @enumFromInt(raw_node);
            const sid: ScopeId = if (do_scope)
                try scopes.addScope(kind, parent, node)
            else
                ScopeId.fromInt(0);
            if (sp < stack.len) {
                stack[sp] = sid;
                kind_stack[sp] = kind;
                node_stack[sp] = node;
                sp += 1;
            }
            // A function body starts with a live control-flow path; save the
            // outer alive state so exit from the function restores it.
            if (kind == .function or kind == .arrow_function or kind == .global or
                kind == .module or kind == .static_block or kind == .class_field_initializer)
            {
                if (fsp < fn_alive_stack.len) {
                    fn_alive_stack[fsp] = cfg_alive;
                    fsp += 1;
                }
                cfg_alive = true;

                // CodePath entry.  For module/global the owner node is root(0);
                // for functions/static-blocks/class-field-inits it's the owning
                // construct (fn_decl, fn_expr, arrow_fn, static_block_def, property, …).
                const origin: Origin = switch (kind) {
                    .global, .module => .program,
                    .function, .arrow_function => .function,
                    .static_block => .class_static_block,
                    .class_field_initializer => .class_field_initializer,
                    else => unreachable,
                };
                if (do_cfg) try cpb.enterCodePath(node, origin, node);
            }
        },
        .scope_close => {
            if (sp > 0) {
                _ = stack[sp - 1];
                sp -= 1;
                if (do_scope) {
                    const closed_undos = undo_stacks[sp].items;
                    if (closed_undos.len > 0) {
                        // Restore scope_map and ref_cache to pre-scope state (LIFO).
                        var j: usize = closed_undos.len;
                        while (j > 0) {
                            j -= 1;
                            const undo = closed_undos[j];
                            const cur_ptr = scope_map.getPtr(undo.name_hash);
                            // Skip if a shallower-target (hoisted) declaration has
                            // already overwritten this scope's entry. That declaration's
                            // own undo (at a shallower depth) will handle restoration.
                            if (cur_ptr == null or cur_ptr.?.* != undo.sym_id) continue;
                            if (undo.prev) |prev| {
                                cur_ptr.?.* = prev;
                                ref_cache[undo.name_hash & 511] = .{ .hash = undo.name_hash, .sym = prev };
                            } else {
                                _ = scope_map.remove(undo.name_hash);
                                ref_cache[undo.name_hash & 511] = .{ .hash = undo.name_hash, .sym = .none };
                            }
                        }
                        undo_stacks[sp].clearRetainingCapacity();
                    }
                }
                const closed_kind = kind_stack[sp];
                if (closed_kind == .function or closed_kind == .arrow_function or
                    closed_kind == .global or closed_kind == .module or
                    closed_kind == .static_block or closed_kind == .class_field_initializer)
                {
                    if (fsp > 0) {
                        fsp -= 1;
                        cfg_alive = fn_alive_stack[fsp];
                    } else {
                        cfg_alive = true;
                    }
                    const closed_node = node_stack[sp];
                    if (do_cfg) try cpb.exitCodePath(closed_node);
                }
            }
        },
        .terminator => {
            // Mark this node as alive (the return/throw itself is reachable
            // if cfg_alive was true coming in), then set cfg_alive = false
            // for everything that follows in this basic block.
            const ni = e.node;
            if (ni < node_reachable.len and !cfg_alive) node_reachable[ni] = 0;
            cfg_alive = false;

            // Drive CodePathBuilder state.  aux: 0=return, 1=throw, 2=break, 3=continue.
            const term_node: NodeIndex = @enumFromInt(e.node);
            const term_i = @intFromEnum(term_node);
            switch (e.aux) {
                0 => if (do_cfg) {
                    const has_arg = term_i < node_tags.len and node_datas[term_i].lhs != .none;
                    try cpb.makeReturn(term_node, has_arg);
                },
                1 => if (do_cfg) try cpb.makeThrow(term_node),
                2 => if (term_i < node_tags.len and node_tags[term_i] == .break_label) blk: {
                    const lbl_n = node_datas[term_i].lhs;
                    const lbl = ast.nodeName(lbl_n);
                    if (do_cfg) try cpb.makeBreakLabeled(lbl, term_node);
                    break :blk;
                } else if (do_cfg) try cpb.makeBreak(term_node),
                3 => if (term_i < node_tags.len and node_tags[term_i] == .continue_label) blk: {
                    const lbl_n = node_datas[term_i].lhs;
                    const lbl = ast.nodeName(lbl_n);
                    if (do_cfg) try cpb.makeContinueLabeled(lbl, term_node);
                    break :blk;
                } else if (do_cfg) try cpb.makeContinue(term_node),
                else => if (do_cfg) try cpb.makeUnreachable(term_node),
            }
        },
        .branch_open => {
            // Save the pre-branch alive state.
            if (bsp < branch_save.len) {
                branch_save[bsp] = cfg_alive;
                branch_cons[bsp] = cfg_alive; // placeholder; updated on branch_else/close
                bsp += 1;
            }
            // Entering the consequent: alive state carries in.
        },
        .branch_else => {
            // End of consequent: snapshot its alive state, reset to pre-branch
            // alive to process the alternate.
            if (bsp > 0) {
                branch_cons[bsp - 1] = cfg_alive;
                cfg_alive = branch_save[bsp - 1];
            }
        },
        .branch_close => {
            // Merge: alive = consequent_alive OR alternate_alive.  If there
            // was no branch_else (no alternate), the outer path is still
            // alive because the branch might not have been taken.
            if (bsp > 0) {
                bsp -= 1;
                const save = branch_save[bsp];
                const cons = branch_cons[bsp];
                const alt = cfg_alive;
                // If cons was never updated (no branch_else seen), cons == save.
                // In that case the "no alternate" path means alive = save.
                if (cons == save and alt == save) {
                    cfg_alive = save;
                } else {
                    cfg_alive = cons or alt;
                }
            }
        },
        .declare => {
            if (sp == 0) continue;
            // CFG-side concern: dead-path declare marks node unreachable.
            if (do_cfg and !cfg_alive and e.node < node_reachable.len) node_reachable[e.node] = 0;
            if (!do_scope) continue;
            const kind: BindingKind = @enumFromInt(e.aux);
            // var hoists to the nearest enclosing var-scope (function /
            // global / module / static_block / class_field_init).  let /
            // const / class / params stay in the current lexical scope.
            //
            // function_decl is more subtle: per ES6 in strict mode,
            // function-in-block is block-scoped (not hoisted out).  In
            // sloppy mode, Annex B B.3.2.1 hoists for if/labeled positions
            // (which the parser flags as `function_decl_annex_b`) but ALSO
            // applies to plain blocks via the legacy "FunctionDeclaration
            // in Block" semantics — that case isn't covered here today.
            // For the strict cases that matter (modules, class static
            // blocks, "use strict" functions), treat function_decl as
            // staying in its current scope; only function_decl_annex_b
            // hoists.
            const target_depth: u32 = blk: {
                if (kind == .@"var" or kind == .function_decl_annex_b) {
                    var j: i32 = @as(i32, @intCast(sp)) - 1;
                    while (j >= 0) : (j -= 1) {
                        const sk = kind_stack[@intCast(j)];
                        switch (sk) {
                            .global, .module, .function, .static_block, .class_field_initializer, .arrow_function => break :blk @intCast(j),
                            else => {},
                        }
                    }
                }
                // function_decl placed DIRECTLY in a var-scope (function
                // body, static block, etc.) still belongs to that scope —
                // current scope IS the var-scope.  Function in a block
                // stays in the block.
                break :blk sp - 1;
            };
            const scope_id = stack[target_depth];
            // Name byte-range is precomputed per node (handles the `ts_enum_decl`
            // case where the name lives in EnumData, not main_token).
            const name = ast.nodeName(@enumFromInt(e.node));
            const name_hash = std.hash.Wyhash.hash(0, name);
            const flags = symbol_mod.flagsFromBindingKind(kind);
            const decl_node: NodeIndex = @enumFromInt(e.node);
            const sym_id = try symbols.addSymbol(name, flags, kind, scope_id, decl_node);
            // Default canonical = self.  Below we overwrite to the first sibling
            // for var/function_decl redeclarations.
            try sym_to_canonical.append(sa, sym_id);
            // hoist_map is consulted by the retry pass at end-of-resolve to
            // patch up forward-references (refs that fired before their
            // binding was visible in the live scope_map).  Two flavours:
            //
            //   • var / function_decl: keyed by (name_hash, var-scope id) —
            //     the retry walks var-scope ancestors. Sibling redeclarations
            //     route to the first sym (canonical-by-source-order).
            //   • let / const / class / etc.: keyed by (name_hash, lexical
            //     scope id) — the retry's lexical walk handles the
            //     "closure captures a let declared later in source" case.
            //     E.g. `let x; const cb = () => { x = 1; };` where the
            //     callback's body fires its `.reference` event before the
            //     `let x` declare event in the parent scope.
            const hk = name_hash ^ (@as(u64, scope_id.toInt()) *% 0x9e3779b97f4a7c15);
            if (kind == .@"var" or kind == .function_decl) {
                const ghop = try hoist_map.getOrPut(sa, hk);
                if (!ghop.found_existing) {
                    ghop.value_ptr.* = sym_id;
                } else {
                    // Sibling redeclaration — route refs to the first one.
                    sym_to_canonical.items[sym_id.toInt()] = ghop.value_ptr.*;
                }
            } else {
                // First-write wins for non-redeclarable decls — preserves
                // the canonical-by-source-order property for downstream
                // resolution. Subsequent same-name decls in the same scope
                // are duplicate-decl errors (the parser handles those
                // separately) and shouldn't shadow the original entry.
                const ghop = try hoist_map.getOrPut(sa, hk);
                if (!ghop.found_existing) ghop.value_ptr.* = sym_id;
            }
            const gop = try scope_map.getOrPut(sa, name_hash);
            const prev: ?SymbolId = if (gop.found_existing) gop.value_ptr.* else null;
            try undo_stacks[target_depth].append(sa, .{ .name_hash = name_hash, .sym_id = sym_id, .prev = prev });
            gop.value_ptr.* = sym_id;
            ref_cache[name_hash & 511] = .{ .hash = name_hash, .sym = sym_id };
            // Track running per-scope count — used by downstream code that
            // expects `bindings_count` to be populated (see semantic.zig).
            scopes.list.items(.bindings_count)[scope_id.toInt()] += 1;
        },
        .reference => {
            // CFG-only fast path: just record side arrays and the dead-node bit.
            if (!do_scope) {
                try ref_event_seg_ids.append(allocator, cpb.currentSegId());
                try ref_event_alive.append(allocator, if (cfg_alive) 1 else 0);
                if (!cfg_alive and e.node < node_reachable.len) node_reachable[e.node] = 0;
                continue;
            }
            const scope_id: ScopeId = if (sp == 0)
                ScopeId.fromInt(0) // orphan reference — assign to root
            else
                stack[sp - 1];
            const ref_kind: ReferenceKind = @enumFromInt(e.aux);
            const ref_node: NodeIndex = @enumFromInt(e.node);
            const ref_id = try references.addReference(ref_kind, ref_node, scope_id, .none);
            if (do_cfg) {
                references.list.items(.seg_id)[ref_id.toInt()] = cpb.currentSegId();
                if (!cfg_alive and e.node < node_reachable.len) node_reachable[e.node] = 0;
            }
            if (phase == .scope_only) try ref_event_to_id.append(allocator, ref_id);

            if (skip_resolve) continue;
            const name_hash = std.hash.Wyhash.hash(0, ast.nodeName(@enumFromInt(e.node)));

            // O(1) resolve via the scope_map (name_hash → sym_id for all visible names).
            if (sp == 0) {
                try unresolved_refs.append(sa, .{ .ref_id = ref_id, .name_hash = name_hash });
                continue;
            }
            const cache_slot = &ref_cache[name_hash & 511];
            const sym_id: ?SymbolId = if (cache_slot.hash == name_hash) blk: {
                // Cache hit — sym may be .none (known-unresolved in current scope).
                break :blk if (cache_slot.sym != .none) cache_slot.sym else null;
            } else blk: {
                // Cache miss — probe scope_map and populate cache.
                const result = scope_map.get(name_hash);
                cache_slot.* = .{ .hash = name_hash, .sym = result orelse .none };
                break :blk result;
            };
            if (sym_id) |sid| {
                const csid = sym_to_canonical.items[sid.toInt()];
                references.resolve(ref_id, csid);
                if (ref_kind.isRead()) symbols.markRead(csid);
                if (ref_kind.isWrite() and ref_kind != .write_init) symbols.markWritten(csid);
                if (ref_kind == .type_of) symbols.markTypeOf(csid);
            } else {
                // Unresolved → retry pass handles forward refs (hoisted var/function).
                try unresolved_refs.append(sa, .{ .ref_id = ref_id, .name_hash = name_hash });
            }
        },

        // ── If statement CodePath events ─────────────────────────
        // cfg_alive logic merged here (branch_open/else/close no longer
        // emitted for if-statements; branch_* still fired by loops/try).
        .if_open => {
            if (bsp < branch_save.len) {
                branch_save[bsp] = cfg_alive;
                branch_cons[bsp] = cfg_alive;
                bsp += 1;
            }
            if (do_cfg) try cpb.pushChoiceContext(.test_kind, false);
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeIfConsequent(n);
        },
        .if_alt => {
            if (bsp > 0) {
                branch_cons[bsp - 1] = cfg_alive;
                cfg_alive = branch_save[bsp - 1];
            }
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeIfAlternate(n);
        },
        .if_close => {
            if (bsp > 0) {
                bsp -= 1;
                const save = branch_save[bsp];
                const cons = branch_cons[bsp];
                const alt = cfg_alive;
                cfg_alive = if (cons == save and alt == save) save else cons or alt;
            }
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.popChoiceContext(n);
        },

        // ── Loop CodePath events ─────────────────────────────────
        .loop_open => {
            // In streaming mode the parser emits loop_open with node=.none and
            // patches the real index after parsing the loop body.  The batch
            // publish may fire between the push and the patch, so spin until
            // patchEventNode's release-store is visible.
            var node_raw = e.node;
            if (opts.streaming != null and node_raw == std.math.maxInt(u32)) {
                const ev_u64: *const u64 = @ptrCast(&events_view[ev_i - 1]);
                while (true) {
                    std.atomic.spinLoopHint();
                    node_raw = @truncate(@atomicLoad(u64, ev_u64, .acquire) >> 32);
                    if (node_raw != std.math.maxInt(u32)) break;
                }
            }
            // Defensive: skip CFG/loop processing if node is unpatched (still .none)
            // or out-of-range — happens when the parser hits a recoverable error
            // mid-loop (e.g. `for (using x of arr) {}` — `using` not yet handled)
            // and unwinds before patching the loop_open event.  Without this
            // guard, loopingTargetNode below would index ast.nodes with maxInt(u32)
            // and panic.  Note: the linter's parallel path calls sem unconditionally
            // even when tree.errors.len > 0, so sem must be robust to broken ASTs.
            if (node_raw >= ast.nodes.len) {
                pending_label = "";
                continue;
            }
            if (!cfg_alive and node_raw < node_reachable.len) node_reachable[node_raw] = 0;
            const loop_type: code_path_mod.LoopType = switch (e.aux) {
                0 => .while_stmt,
                1 => .do_while_stmt,
                2 => .for_stmt,
                3 => .for_in_stmt,
                else => .for_of_stmt,
            };
            const n: NodeIndex = @enumFromInt(node_raw);
            const target = loopingTargetNode(ast, n, loop_type);
            // has_skip_path: false for do-while (always executes once), for(;;) /
            // for(init;;update) (no condition), and while(true) (condition is always truthy).
            const has_skip_path: bool = switch (loop_type) {
                .do_while_stmt => false,
                .for_stmt => blk: {
                    const fd = ast.extraData(ast_mod.ForData, @intFromEnum(node_datas[@intFromEnum(n)].lhs));
                    break :blk fd.condition != .none;
                },
                .while_stmt => blk: {
                    const cond = node_datas[@intFromEnum(n)].lhs;
                    if (cond == .none) break :blk false;
                    if (node_tags[@intFromEnum(cond)] != .boolean_literal) break :blk true;
                    // while(true): condition is always truthy — no skip path
                    break :blk !std.mem.eql(u8, ast.nodeName(cond), "true");
                },
                else => true, // for-in, for-of always have a skip path
            };
            const loop_label: ?[]const u8 = if (pending_label.len > 0) pending_label else null;
            pending_label = "";
            if (do_cfg) try cpb.pushLoopContext(loop_type, loop_label, n, target, has_skip_path);
        },
        .loop_test_end => if (do_cfg) cpb.setLoopContinueDest(),
        .loop_body_end => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeLoopBackEdge(n);
        },
        .loop_close => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.popLoopContext(n);
        },

        // ── Try/catch/finally CodePath events ────────────────────
        .try_open => {
            const has_finalizer = e.aux == 1;
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.pushTryContext(has_finalizer, n);
        },
        .try_body_end => {},
        .try_catch_start => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeCatchBlock(n);
        },
        .try_catch_end => {},
        .try_finally_start => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeFinallyBlock(n);
        },
        .try_close => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.popTryContext(n);
        },

        // ── Switch CodePath events ───────────────────────────────
        .switch_open => if (do_cfg) try cpb.pushSwitchContext(e.aux == 1, null),
        .switch_case_start => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeSwitchCaseBody(e.aux == 1, n);
        },
        .switch_case_end => {},
        .switch_close => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.popSwitchContext(n);
        },

        // ── Logical/conditional short-circuit CodePath events ────
        .logical_open => {
            const ck: code_path_mod.ChoiceKind = switch (e.aux) {
                0 => .logical_and,
                1 => .logical_or,
                else => .nullish,
            };
            if (do_cfg) try cpb.pushChoiceContext(ck, true);
        },
        .logical_right => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeLogicalRight(n);
        },
        .logical_close => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.popChoiceContext(n);
        },
        .cond_open => {
            if (do_cfg) try cpb.pushChoiceContext(.test_kind, true);
        },
        .cond_fork => {
            // n = condition node.  Fork at condition.exit so the outer-ternary fork
            // event precedes any nested-ternary events, matching DFS playback order.
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeConsequent(n);
        },
        .cond_alt => {
            // n = consequent node.  Transition to the false-fork at consequent.exit.
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.makeConditionalAlternate(n);
        },
        .cond_close => {
            const n: NodeIndex = @enumFromInt(e.node);
            if (do_cfg) try cpb.popChoiceContext(n);
        },

        // ── Labeled statements (break/continue targets) ─────────
        .label_open => {
            if (e.aux == 1) { // loop label — extract text for upcoming loop_open
                pending_label = ast.nodeName(@enumFromInt(e.node));
            }
        },
        .label_close => {
            pending_label = ""; // consumed or no loop found — clear either way
        },
        .nop => {},
        }
    }

    // Capture loop end time and start post-passes timer.
    var post_start_ts: std.c.timespec = undefined;
    if (opts.streaming) |s| {
        _ = std.c.clock_gettime(.MONOTONIC, &post_start_ts);
        if (s.stats) |st| {
            const dt: u64 = @intCast((post_start_ts.sec - loop_start_ts.sec) * std.time.ns_per_s + (post_start_ts.nsec - loop_start_ts.nsec));
            st.events_loop_ns = dt;
            st.events_processed = ev_i;
        }
    }

    // Retry unresolved references — `var`/`function` declarations hoist to the
    // nearest var-scope, so a reference seen *before* the declaration in source
    // order was left unresolved during the main pass.  Walk the var-scope chain
    // using hoist_map (O(1) per level) instead of all_entries binary search
    // (O(log N) per level across every lexical scope).
    if (do_scope and !skip_resolve) {
        const scope_count: u32 = @intCast(scopes.len());
        const kinds = scopes.list.items(.kind);
        for (unresolved_refs.items) |ur| {
            const ref_id = ur.ref_id;
            const ref_scope = references.getScope(ref_id);
            if (!ref_scope.isValid()) continue;
            const name_hash = ur.name_hash;

            // Find the nearest var-scope enclosing ref_scope.
            var vsid = ref_scope;
            while (vsid.toInt() < scope_count) {
                switch (kinds[vsid.toInt()]) {
                    .global, .module, .function, .static_block, .class_field_initializer, .arrow_function => break,
                    else => {
                        const p = scopes.parent(vsid);
                        if (!p.isValid() or p.toInt() == vsid.toInt()) break;
                        vsid = p;
                    },
                }
            }

            // Walk var-scope ancestors first — O(1) hash lookup per level.
            // This catches forward refs to var/function_decl (their decl_map
            // entries are keyed by var-scope id).
            var resolved_in_var_walk = false;
            while (vsid.toInt() < scope_count) {
                const hk = name_hash ^ (@as(u64, vsid.toInt()) *% 0x9e3779b97f4a7c15);
                if (hoist_map.get(hk)) |sym_id| {
                    references.resolve(ref_id, sym_id);
                    const rk = references.getKind(ref_id);
                    if (rk.isRead()) symbols.markRead(sym_id);
                    if (rk.isWrite() and rk != .write_init) symbols.markWritten(sym_id);
                    if (rk == .type_of) symbols.markTypeOf(sym_id);
                    resolved_in_var_walk = true;
                    break;
                }
                var p = scopes.parent(vsid);
                if (!p.isValid() or p.toInt() == vsid.toInt()) break;
                // Advance p to the next var-scope.
                while (p.toInt() < scope_count) {
                    switch (kinds[p.toInt()]) {
                        .global, .module, .function, .static_block, .class_field_initializer, .arrow_function => break,
                        else => {
                            const pp = scopes.parent(p);
                            if (!pp.isValid() or pp.toInt() == p.toInt()) break;
                            p = pp;
                        },
                    }
                }
                if (p.toInt() == vsid.toInt()) break;
                vsid = p;
            }

            // If the var-scope walk didn't resolve, walk the FULL lexical
            // ancestor chain — block scopes too. This catches forward refs
            // to let/const/class bindings (their decl_map entries are
            // keyed by lexical scope id, not the enclosing var-scope id).
            // Pattern this fixes: `compilerHost = { writeFile: (n,t) => {
            // sourceMapText = t; }, ... }; let sourceMapText;` — the
            // closure captures the let-declared var even though the
            // .reference fires before the .declare in source order.
            if (!resolved_in_var_walk) {
                var lid = ref_scope;
                while (lid.toInt() < scope_count) {
                    const hk = name_hash ^ (@as(u64, lid.toInt()) *% 0x9e3779b97f4a7c15);
                    if (hoist_map.get(hk)) |sym_id| {
                        references.resolve(ref_id, sym_id);
                        const rk = references.getKind(ref_id);
                        if (rk.isRead()) symbols.markRead(sym_id);
                        if (rk.isWrite() and rk != .write_init) symbols.markWritten(sym_id);
                        if (rk == .type_of) symbols.markTypeOf(sym_id);
                        break;
                    }
                    const p = scopes.parent(lid);
                    if (!p.isValid() or p.toInt() == lid.toInt()) break;
                    lid = p;
                }
            }
        }
    }

    // Resolve pre-declared globals (ES builtins + user-configured) as implicit_global
    // symbols in scope 0.  Eliminates the JS-side ~200-object builtin creation per
    // file and removes the need for the eager `void globalScope.through` in the runner.
    // Refs that match a global name get resolved here so ref.resolved is non-null;
    // the Zig through CSR excludes implicit_global refs, keeping scope.through clean.
    if (do_scope and !skip_resolve and opts.globals.len > 0 and scopes.len() > 0) {
        const global_scope_id = ScopeId.fromInt(0);
        const implicit_flags = symbol_mod.flagsFromBindingKind(.implicit_global);

        // Build a hash → sym_id map for O(1) lookup during the ref scan.
        const NameHashCtx2 = struct {
            pub fn hash(_: @This(), k: u64) u64 { return k; }
            pub fn eql(_: @This(), a: u64, b: u64) bool { return a == b; }
        };
        var global_lookup = std.HashMapUnmanaged(u64, symbol_mod.SymbolId, NameHashCtx2, 80){};
        // Capacity must cover ES builtins + user-configured globals
        // (browser env alone is ~1100 entries).  Grow up-front so
        // putAssumeCapacity inside the loop doesn't silently truncate.
        const approx_globals: u32 = blk: {
            var n: u32 = 64; // baseline for builtins
            var counter = std.mem.splitScalar(u8, opts.globals, 0);
            while (counter.next()) |s| { if (s.len > 0) n += 1; }
            break :blk n;
        };
        try global_lookup.ensureTotalCapacity(sa, @max(512, approx_globals * 2));

        var git = std.mem.splitScalar(u8, opts.globals, 0);
        while (git.next()) |name| {
            if (name.len == 0) continue;
            const h = std.hash.Wyhash.hash(0, name);
            // Skip duplicate names (same hash) — first one wins.
            if (global_lookup.contains(h)) continue;
            const sym_id = try symbols.addSymbol(name, implicit_flags, .implicit_global, global_scope_id, ast_mod.NodeIndex.none);
            try sym_to_canonical.append(sa, sym_id);
            global_lookup.putAssumeCapacity(h, sym_id);
        }

        if (global_lookup.count() > 0) {
            for (unresolved_refs.items) |ur| {
                const ref_id = ur.ref_id;
                if (references.isResolved(ref_id)) continue;
                if (global_lookup.get(ur.name_hash)) |sym_id| {
                    references.resolve(ref_id, sym_id);
                    const rk = references.getKind(ref_id);
                    if (rk.isRead()) symbols.markRead(sym_id);
                    if (rk.isWrite() and rk != .write_init) symbols.markWritten(sym_id);
                    if (rk == .type_of) symbols.markTypeOf(sym_id);
                }
            }
        }
    }

    // Post-passes: sort by symbol / scope for downstream lookups, matching
    // `semantic.zig`'s `buildRefRanges` and `buildScopeBindings`.
    const ref_by_sym: []ReferenceId = if (do_scope and !skip_ref_ranges)
        try buildRefRanges(&symbols, &references, sa, allocator)
    else
        &.{};
    var t_after_resolve: std.c.timespec = undefined;
    if (opts.streaming) |s| {
        if (s.stats) |st| {
            _ = std.c.clock_gettime(.MONOTONIC, &t_after_resolve);
            st.resolve_unresolved_ns = @intCast((t_after_resolve.sec - post_start_ts.sec) * std.time.ns_per_s + (t_after_resolve.nsec - post_start_ts.nsec));
            st.unresolved_count = unresolved_refs.items.len;
            st.scope_count = scopes.len();
            st.symbol_count = symbols.count();
        }
    }

    if (do_scope) try buildScopeBindings(&scopes, &symbols, allocator);

    // Capture post-passes time.
    if (opts.streaming) |s| {
        if (s.stats) |st| {
            var post_end_ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &post_end_ts);
            st.build_scope_bindings_ns = @intCast((post_end_ts.sec - t_after_resolve.sec) * std.time.ns_per_s + (post_end_ts.nsec - t_after_resolve.nsec));
            st.post_passes_ns = @intCast((post_end_ts.sec - post_start_ts.sec) * std.time.ns_per_s + (post_end_ts.nsec - post_start_ts.nsec));
        }
    }

    // finish() transfers the arena into the Result; do NOT call cpb.deinit() after.
    const cpb_result = cpb.finish();

    return switch (phase) {
        .both => semantic_mod.SemanticResult{
            .scopes = scopes,
            .symbols = symbols,
            .references = references,
            .ref_by_sym = ref_by_sym,
            .diagnostics = &.{},
            .node_reachable = node_reachable,
            .loop_exit_reachable = loop_exit_reachable,
            .code_path_result = cpb_result,
        },
        .scope_only => ScopePart{
            .scopes = scopes,
            .symbols = symbols,
            .references = references,
            .ref_by_sym = ref_by_sym,
            .ref_event_to_id = try ref_event_to_id.toOwnedSlice(allocator),
        },
        .cfg_only => CfgPart{
            .code_path_result = cpb_result,
            .node_reachable = node_reachable,
            .loop_exit_reachable = loop_exit_reachable,
            .ref_event_seg_ids = try ref_event_seg_ids.toOwnedSlice(allocator),
            .ref_event_alive = try ref_event_alive.toOwnedSlice(allocator),
        },
    };
}

// ── Post-passes (copied from semantic.zig internals) ────────────────

// buildRefRanges builds an indirect ref-by-symbol index without touching the
// main reference arrays.  Instead of permuting all 5 SoA columns in place
// (the old sortBySymbolWithMax approach, ~12 passes + 5 dupe allocs ≈ 6 MB),
// we do a 3-pass counting sort over a single new array:
//
//   ref_by_sym[i]  — ref_id at sorted position i  (owned by SemanticResult)
//   sym_ref_range  — [start, end) into ref_by_sym per symbol
//
// Total: 3 passes over N refs + 1 pass over K symbols, 1.76 MB temp (arena).
// Callers access refs as: ref_by_sym[range.start .. range.end].
fn buildRefRanges(
    symbols: *SymbolTable,
    references: *ReferenceTable,
    sa: std.mem.Allocator,   // scope_arena — temp arrays freed in bulk
    allocator: std.mem.Allocator, // outer allocator — ref_by_sym persists
) ![]ReferenceId {
    const sym_count: u32 = @intCast(symbols.count());
    const ref_count: u32 = references.count();
    if (ref_count == 0 or sym_count == 0) return &.{};

    const sym_ids = references.list.items(.symbol_id);
    const buckets = sym_count + 1; // last bucket holds unresolved (.none)

    // Pass 1: count refs per symbol.
    const counts = try sa.alloc(u32, buckets);
    @memset(counts, 0);
    for (sym_ids) |s| {
        counts[if (s == .none) sym_count else s.toInt()] += 1;
    }

    // Pass 2: prefix sum → per-symbol start positions.
    // Only valid symbol IDs (0..sym_count-1) get entries in the symbol table.
    // The last bucket (index sym_count) holds unresolved refs — no symbol entry.
    const starts = try sa.alloc(u32, buckets);
    var acc: u32 = 0;
    for (0..sym_count) |i| {
        starts[i] = acc;
        symbols.setRefRange(@enumFromInt(i), .{ .start = acc, .end = acc + counts[i] });
        acc += counts[i];
    }
    starts[sym_count] = acc;

    // Pass 3: scatter ref_ids into the sorted index.
    const ref_by_sym = try allocator.alloc(ReferenceId, ref_count);
    const cursor = try sa.alloc(u32, buckets);
    @memcpy(cursor, starts);
    for (sym_ids, 0..) |s, old| {
        const b = if (s == .none) sym_count else s.toInt();
        ref_by_sym[cursor[b]] = ReferenceId.fromInt(@intCast(old));
        cursor[b] += 1;
    }

    return ref_by_sym;
}

fn buildScopeBindings(
    scopes: *ScopeTree,
    symbols: *SymbolTable,
    allocator: std.mem.Allocator,
) !void {
    const sym_count: u32   = @intCast(symbols.count());
    const scope_count: u32 = @intCast(scopes.len());
    if (sym_count == 0) return;

    // Count symbols per scope.
    const counts = try allocator.alloc(u32, scope_count);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (symbols.list.items(.scope_id)) |sid| {
        const s = sid.toInt();
        if (s < scope_count) counts[s] += 1;
    }

    // Prefix-sum → starts per scope.
    const starts = try allocator.alloc(u32, scope_count);
    defer allocator.free(starts);
    var total: u32 = 0;
    for (0..scope_count) |i| {
        starts[i] = total;
        scopes.setBindings(@enumFromInt(i), total, counts[i]);
        total += counts[i];
    }
}
