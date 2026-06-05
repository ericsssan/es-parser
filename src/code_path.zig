/// Code path analysis — full multi-segment CFG builder.
///
/// This is a Zig port of ESLint's CodePathAnalysis. It builds a complete
/// segment graph during semantic analysis and serializes it to the shared
/// buffer so JS can read precomputed segment/codepath objects without
/// any reconstruction.
///
/// Architecture:
///   CodePathBuilder  — drives the analysis (replaces CodePathAnalyzer + CodePathState)
///   Segment          — a straight-line code block (replaces CodePathSegment)
///   ForkContext       — manages parallel segment arrays (replaces ForkContext)
///   ChoiceContext     — if/else, &&, ||, ?? branching
///   SwitchContext     — switch/case/default
///   TryContext        — try/catch/finally
///   LoopContext       — while/do-while/for/for-in/for-of
///   CodePath          — one per function/program (replaces CodePath)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_mod = @import("ast.zig");
const NodeIndex = ast_mod.NodeIndex;

// ── Segment ──────────────────────────────────────────────────────

pub const SegmentId = u32;
pub const NONE_SEG: SegmentId = std.math.maxInt(SegmentId);

pub const Segment = struct {
    codepath: CodePathId,

    // Prev adjacency — set at segment creation, then immutable.
    all_prev_start: u32,
    all_prev_end: u32,
    prev_start: u32,
    prev_end: u32,
    // Looped prev — set rarely via markLooped.
    looped_prev_start: u32,
    looped_prev_end: u32,
    // Collapsed prev — only populated for unreachable segments. BFS through
    // unreachable predecessors collects the set of REACHABLE ancestors. Lets
    // JS rules (no-useless-return) skip recursive walks at runtime.
    collapsed_prev_start: u32,
    collapsed_prev_end: u32,
};

/// Hot adjacency sidecar — written on every markUsed/markLooped call.
/// Split out from Segment so markUsed touches 16 bytes (one cache line holds 4)
/// instead of a 48-byte struct.
pub const SegNextInfo = struct {
    all_next_start: u32 = 0,
    all_next_end: u32 = 0,
    next_start: u32 = 0,
    next_end: u32 = 0,
};

// ── CodePath ─────────────────────────────────────────────────────

pub const CodePathId = u32;
pub const NONE_CP: CodePathId = std.math.maxInt(CodePathId);

pub const Origin = enum(u8) {
    program = 0,
    function = 1,
    class_field_initializer = 2,
    class_static_block = 3,
};

pub const CodePath = struct {
    origin: Origin,
    upper: CodePathId, // parent code path, NONE_CP = root
    initial_segment: SegmentId,
    // Final/returned/thrown segments stored as ranges into flat arrays.
    final_start: u32,
    final_end: u32,
    returned_start: u32,
    returned_end: u32,
    thrown_start: u32,
    thrown_end: u32,
};

// ── Event ────────────────────────────────────────────────────────

pub const EventType = enum(u8) {
    codepath_start = 0,
    codepath_end = 1,
    seg_start = 2,
    seg_end = 3,
    unreachable_seg_start = 4,
    unreachable_seg_end = 5,
    seg_loop = 6,
};

pub const EventPhase = enum(u2) { enter = 0, exit = 1, post = 2, after_enter = 3 };

pub const Event = struct {
    type: EventType,
    node: NodeIndex,
    data1: u32,
    data2: u32,
    phase: EventPhase,
};

// ── ForkContext ───────────────────────────────────────────────────
// Manages parallel segment arrays. Each element in segments_list is
// a slice of `count` segments representing one step in each fork.

const FC_INLINE_CAP: u32 = 2;

const ForkContext = struct {
    count: u32,
    upper: ?*ForkContext,
    // Inline storage for the first FC_INLINE_CAP entries — most ForkContexts
    // hold ≤2 segment-ID slices before being discarded.  Avoids the default
    // ArrayList 0→8 grow allocation per init.
    sl_inline: [FC_INLINE_CAP][]SegmentId,
    sl_count: u32,
    // Heap spill for entries beyond the inline buffer.
    sl_heap: std.ArrayListUnmanaged([]SegmentId),
    allocator: Allocator,

    fn init(alloc: Allocator, upper: ?*ForkContext, count: u32) ForkContext {
        return .{
            .count = count,
            .upper = upper,
            .sl_inline = undefined,
            .sl_count = 0,
            .sl_heap = .empty,
            .allocator = alloc,
        };
    }

    inline fn totalLen(self: *const ForkContext) usize {
        return @as(usize, self.sl_count) + self.sl_heap.items.len;
    }

    inline fn getEntry(self: *const ForkContext, idx: usize) []SegmentId {
        if (idx < self.sl_count) return self.sl_inline[idx];
        return self.sl_heap.items[idx - self.sl_count];
    }

    fn head(self: *const ForkContext) []SegmentId {
        const n = self.totalLen();
        if (n == 0) return &.{};
        return self.getEntry(n - 1);
    }

    fn empty(self: *const ForkContext) bool {
        return self.sl_count == 0 and self.sl_heap.items.len == 0;
    }

    fn reachable(self: *const ForkContext, builder: *const CodePathBuilder) bool {
        const h = self.head();
        for (h) |seg_id| {
            if (seg_id != NONE_SEG and (builder.seg_reachable.items[seg_id] != 0)) return true;
        }
        return false;
    }

    fn pushEntry(self: *ForkContext, entry: []SegmentId) !void {
        if (self.sl_count < FC_INLINE_CAP) {
            self.sl_inline[self.sl_count] = entry;
            self.sl_count += 1;
            return;
        }
        try self.sl_heap.append(self.allocator, entry);
    }

    fn setLastEntry(self: *ForkContext, entry: []SegmentId) void {
        if (self.sl_heap.items.len > 0) {
            self.sl_heap.items[self.sl_heap.items.len - 1] = entry;
            return;
        }
        // Must be in inline buffer (sl_count > 0 guaranteed by caller).
        self.sl_inline[self.sl_count - 1] = entry;
    }

    fn add(self: *ForkContext, segments: []SegmentId, builder: *CodePathBuilder) !void {
        const merged = try mergeExtraSegments(self, segments, builder);
        try self.pushEntry(merged);
    }

    fn replaceHead(self: *ForkContext, segments: []SegmentId, builder: *CodePathBuilder) !void {
        const merged = try mergeExtraSegments(self, segments, builder);
        if (self.totalLen() > 0) {
            self.setLastEntry(merged);
        } else {
            try self.pushEntry(merged);
        }
    }

    fn addAll(self: *ForkContext, other: *const ForkContext) !void {
        const other_inline_n = other.sl_count;
        for (0..other_inline_n) |i| try self.pushEntry(other.sl_inline[i]);
        for (other.sl_heap.items) |entry| try self.pushEntry(entry);
    }

    fn clear(self: *ForkContext) void {
        self.sl_count = 0;
        self.sl_heap.clearRetainingCapacity();
    }

    /// Create new segments from a range of the segments_list.
    fn makeNext(self: *ForkContext, start_idx: i32, end_idx: i32, builder: *CodePathBuilder) ![]SegmentId {
        return self.createSegments(start_idx, end_idx, builder, .next);
    }

    fn makeUnreachable(self: *ForkContext, start_idx: i32, end_idx: i32, builder: *CodePathBuilder) ![]SegmentId {
        return self.createSegments(start_idx, end_idx, builder, .unreachable_seg);
    }

    const CreateMode = enum { next, unreachable_seg };

    fn createSegments(self: *ForkContext, start_idx: i32, end_idx: i32, builder: *CodePathBuilder, mode: CreateMode) ![]SegmentId {
        const total: i32 = @intCast(self.totalLen());

        // Bump-allocate result slice from the stable pool (no arena overhead,
        // no realloc risk — pool is pre-sized in ensureCapacity).
        // Falls back to arena alloc only if pool is exhausted (unlikely).
        const pool_start = builder.seg_id_pool_top;
        const result: []SegmentId = if (pool_start + self.count <= builder.seg_id_pool_cap) blk: {
            builder.seg_id_pool_top += self.count;
            break :blk builder.seg_id_pool[pool_start .. pool_start + self.count];
        } else try self.allocator.alloc(SegmentId, self.count);

        // Guard: if the list is empty, create segments with no prev
        if (total == 0) {
            for (0..self.count) |i| {
                result[i] = switch (mode) {
                    .next => try builder.newNextSegment(&.{}),
                    .unreachable_seg => try builder.newUnreachableSegment(&.{}),
                };
            }
            return result;
        }

        const norm_start: usize = @intCast(if (start_idx >= 0) start_idx else total + start_idx);
        const norm_end: usize = @intCast(if (end_idx >= 0) end_idx else total + end_idx);
        const range_len = norm_end - norm_start + 1;

        // Stack buffer for prev segments — avoids per-lane arena alloc for the
        // common small case. Falls back to arena allocation when the merge
        // range is wider than the buffer (e.g. a switch with >16 cases without
        // breaks accumulates that many fork-context entries; capping silently
        // would drop predecessors and disconnect break-segments from the
        // post-switch merge).
        var prev_stack: [16]SegmentId = undefined;
        const prev_buf: []SegmentId = if (range_len <= prev_stack.len)
            prev_stack[0..]
        else
            try self.allocator.alloc(SegmentId, range_len);

        for (0..self.count) |i| {
            var n_prev: usize = 0;
            var j = norm_start;
            while (j <= norm_end) : (j += 1) {
                const entry = self.getEntry(j);
                if (i < entry.len) {
                    prev_buf[n_prev] = entry[i];
                    n_prev += 1;
                }
            }
            const prev_slice = prev_buf[0..n_prev];

            result[i] = switch (mode) {
                .next => try builder.newNextSegment(prev_slice),
                .unreachable_seg => try builder.newUnreachableSegment(prev_slice),
            };
        }
        return result;
    }
};

fn mergeExtraSegments(ctx: *ForkContext, segments: []SegmentId, builder: *CodePathBuilder) ![]SegmentId {
    var current = segments;
    while (current.len > ctx.count) {
        const half = current.len / 2;
        const merged = try ctx.allocator.alloc(SegmentId, half);
        for (0..half) |i| {
            const prev = try ctx.allocator.alloc(SegmentId, 2);
            prev[0] = current[i];
            prev[1] = current[i + half];
            merged[i] = try builder.newNextSegment(prev);
        }
        current = merged;
    }
    return current;
}

fn newEmptyForkContext(alloc: Allocator, parent: *ForkContext, should_fork_leaving: bool) ForkContext {
    const count = (if (should_fork_leaving) @as(u32, 2) else @as(u32, 1)) * parent.count;
    return ForkContext.init(alloc, parent, count);
}

// ── Context Types ────────────────────────────────────────────────

pub const ChoiceKind = enum { test_kind, logical_and, logical_or, nullish, loop, switch_kind };

const ChoiceContext = struct {
    upper: ?*ChoiceContext,
    kind: ChoiceKind,
    true_fork: ForkContext,
    false_fork: ForkContext,
    processed: bool,
    // For loop kind: skip last_branch_end (body-end) when forming post-loop segment.
    // True for while/for (body-end loops back, not a post-loop exit); false for do-while.
    skip_last_branch_end: bool = false,
};

const SwitchContext = struct {
    upper: ?*SwitchContext,
    default_segments: ?[]SegmentId,
    prev_break_target_is_switch: bool = false,
};

const TryContext = struct {
    upper: ?*TryContext,
    has_finalizer: bool,
    position: enum { try_body, catch_body, finally_body },
    returned_fork: ForkContext,
    thrown_fork: ForkContext,
    try_end_fork: ForkContext, // segments at end of try body (for merging with catch end)
    pre_try_segments: ?[]SegmentId, // head before try body (for catch entry reachability)
    last_of_try_reachable: bool,
    last_of_catch_reachable: bool,
    first_throwable_called: bool, // has makeFirstThrowablePathInTryBlock been called?
};

pub const LoopType = enum {
    while_stmt,
    do_while_stmt,
    for_stmt,
    for_in_stmt,
    for_of_stmt,
};

const LoopContext = struct {
    upper: ?*LoopContext,
    continue_dest_segments: ?[]SegmentId = null,
    entry_segments: ?[]SegmentId = null,
    continue_fork: ForkContext,
    break_fork: ForkContext,
    node: NodeIndex = .none,
    label: []const u8 = "",
    is_do_while: bool = false,
    has_skip_path: bool = false,
    prev_break_target_is_switch: bool = false,
};

// ── CodePathBuilder ──────────────────────────────────────────────

pub const CodePathBuilder = struct {
    /// Arena owns all internal allocations (ArrayLists backing, ForkContexts, etc.).
    /// Freed as a unit in deinit().
    arena: std.heap.ArenaAllocator,
    /// Shortcut to arena.allocator() — set in init().
    allocator: Allocator,

    // Results
    segments: std.MultiArrayList(Segment),
    /// Hot sidecar of segments.items[i].reachable — 1 byte per segment.
    seg_reachable: std.ArrayList(u8),
    /// Sidecar of used flag — hot in flattenUnused + markUsed early-exit.
    seg_used: std.ArrayList(u8),
    /// Hot adjacency sidecar (all_next_*, next_* pairs). 16 bytes per segment.
    seg_next: std.ArrayList(SegNextInfo),
    codepaths: std.ArrayList(CodePath),
    events: std.ArrayList(Event),

    // Adjacency target pools (segments reference ranges into these)
    all_prev_targets: std.ArrayList(SegmentId),
    prev_targets: std.ArrayList(SegmentId),
    all_next_targets: std.ArrayList(SegmentId),
    next_targets: std.ArrayList(SegmentId),
    looped_targets: std.ArrayList(SegmentId),
    /// Collapsed-prev pool — populated for unreachable segments only.
    collapsed_prev_targets: std.ArrayList(SegmentId),
    /// Per-segment visit generation for buildCollapsedPrev. Avoids O(N²)
    /// dedup. Grown alongside segments. Each new BFS bumps `collapse_gen`.
    seg_collapse_visit: std.ArrayList(u32),
    collapse_gen: u32,
    /// Reused BFS frontier — cleared (retain capacity) between calls so we
    /// don't pay ArrayList alloc per createSegment.
    collapse_frontier: std.ArrayList(SegmentId),

    // CodePath segment pools (flat — populated by `flattenCpPools()` at the
    // end of building, consumed by writeCfgGraph). During building we
    // accumulate per-codepath into `cp_returned_lists` / `cp_thrown_lists`
    // because shared-pool indexing breaks when codepaths interleave (e.g.,
    // a nested function pushes/pops while an outer codepath is still active
    // — the outer's `(start, end)` slice would silently overlap the inner's).
    cp_final_pool: std.ArrayList(SegmentId),
    cp_returned_pool: std.ArrayList(SegmentId),
    cp_thrown_pool: std.ArrayList(SegmentId),
    /// Per-codepath returned segments. `cp_returned_lists.items[cp_id]` is
    /// the segment list for codepath `cp_id`. Populated by `makeReturn` and
    /// the implicit-return path in `exitCodePath`. Flattened into
    /// `cp_returned_pool` by `flattenCpPools()`.
    cp_returned_lists: std.ArrayList(std.ArrayList(SegmentId)),
    /// Per-codepath thrown segments — same shape, populated by `makeThrow`.
    cp_thrown_lists: std.ArrayList(std.ArrayList(SegmentId)),

    // State
    fork_context: *ForkContext,
    current_codepath: CodePathId,
    choice_context: ?*ChoiceContext,
    switch_context: ?*SwitchContext,
    try_context: ?*TryContext,
    loop_context: ?*LoopContext,
    break_target_is_switch: bool,

    // ── ChoiceContext slab ───────────────────────────────────────
    // Pre-allocated pool of ChoiceContext structs — eliminates per-push
    // arena allocation (44K+ calls per file for if/logical/ternary).
    // Max nesting depth of 128 covers all realistic JS source.
    choice_slab: []ChoiceContext,
    choice_slab_top: u32,

    // ── Segment-ID result pool ───────────────────────────────────
    // createSegments returns []SegmentId slices that ForkContext stores
    // as entries.  Instead of arena-allocating each result slice, we
    // bump-allocate from this fixed-size pool.  Slices remain valid
    // (no realloc) for the lifetime of the CPB arena.
    seg_id_pool: [*]SegmentId,
    seg_id_pool_top: u32,
    seg_id_pool_cap: u32,

    // ── JS-buffer bump allocator (optional) ──────────────────────
    // When set, the JS-readable adjacency pools (prev_targets,
    // all_prev_targets, collapsed_prev_targets) are pre-allocated from this
    // allocator to a worst-case capacity, so writeCfgGraph can publish their
    // offsets directly without copying. Non-pool fields (HashMaps, scratch
    // ArrayLists, etc.) still use `self.allocator` (arena).
    bump_alloc: ?Allocator,
    bump_pools_active: bool,

    pub fn init(alloc: Allocator) CodePathBuilder {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .allocator = undefined, // fixed up by caller: self.cpb.allocator = self.cpb.arena.allocator()
            .segments = .empty,
            .seg_reachable = .empty,
            .seg_used = .empty,
            .seg_next = .empty,
            .codepaths = .empty,
            .events = .empty,
            .all_prev_targets = .empty,
            .prev_targets = .empty,
            .all_next_targets = .empty,
            .next_targets = .empty,
            .looped_targets = .empty,
            .collapsed_prev_targets = .empty,
            .seg_collapse_visit = .empty,
            .collapse_gen = 0,
            .collapse_frontier = .empty,
            .cp_final_pool = .empty,
            .cp_returned_pool = .empty,
            .cp_thrown_pool = .empty,
            .cp_returned_lists = .empty,
            .cp_thrown_lists = .empty,
            .fork_context = undefined,
            .current_codepath = NONE_CP,
            .choice_context = null,
            .switch_context = null,
            .try_context = null,
            .loop_context = null,
            .break_target_is_switch = false,
            .choice_slab = &.{},
            .choice_slab_top = 0,
            .seg_id_pool = undefined,
            .seg_id_pool_top = 0,
            .seg_id_pool_cap = 0,
            .bump_alloc = null,
            .bump_pools_active = false,
        };
    }

    /// Establish an empty root fork context so `fork_context` is never the
    /// `undefined` init value. enterCodePath replaces it; this only matters if a
    /// segment op (makeNext/leave/…) is reached before the first enterCodePath —
    /// which a well-formed event stream never does, but a malformed one under a
    /// non-zeroing allocator can, otherwise dereferencing an uninitialized
    /// `fork_context` (head() → totalLen) and segfaulting. Empty ⇒ head() = &.{}.
    pub fn initForkContext(self: *CodePathBuilder) !void {
        const fc = try self.allocator.create(ForkContext);
        fc.* = ForkContext.init(self.allocator, null, 0);
        self.fork_context = fc;
    }

    /// Pre-size internal ArrayLists to avoid growth reallocs during event
    /// processing.  Hints come from the event stream (scope/declare/reference
    /// counts).  Over-estimation is fine — arena-backed, so unused capacity
    /// lives in the final arena reset.
    pub fn ensureCapacity(self: *CodePathBuilder, est_segments: u32, est_codepaths: u32) !void {
        if (self.bump_alloc != null) self.bump_pools_active = true;

        // Most pools stay in the analyzer's arena — no bump-partition pressure.
        // Only the JS-readable adjacency target pools get bump-allocated so
        // writeCfgGraph can publish their offsets without copying.
        // est_segments is parser ev_len (capacity ≈ 2-3× actual events).
        try self.segments.ensureTotalCapacity(self.allocator, est_segments);
        try self.seg_reachable.ensureTotalCapacity(self.allocator, est_segments);
        try self.seg_used.ensureTotalCapacity(self.allocator, est_segments);
        try self.seg_next.ensureTotalCapacity(self.allocator, est_segments);
        try self.codepaths.ensureTotalCapacity(self.allocator, est_codepaths);
        try self.events.ensureTotalCapacity(self.allocator, est_segments);

        const target_alloc: std.mem.Allocator = if (self.bump_alloc) |ba| ba else self.allocator;
        try self.all_prev_targets.ensureTotalCapacity(target_alloc, est_segments);
        try self.prev_targets.ensureTotalCapacity(target_alloc, est_segments);
        try self.collapsed_prev_targets.ensureTotalCapacity(target_alloc, if (self.bump_alloc != null) est_segments else est_segments / 4);

        try self.all_next_targets.ensureTotalCapacity(self.allocator, est_segments);
        try self.next_targets.ensureTotalCapacity(self.allocator, est_segments);
        try self.looped_targets.ensureTotalCapacity(self.allocator, est_codepaths * 8);
        try self.cp_final_pool.ensureTotalCapacity(self.allocator, est_codepaths * 2);
        try self.cp_returned_pool.ensureTotalCapacity(self.allocator, est_codepaths);
        try self.cp_thrown_pool.ensureTotalCapacity(self.allocator, est_codepaths / 4);
        try self.cp_returned_lists.ensureTotalCapacity(self.allocator, est_codepaths);
        try self.cp_thrown_lists.ensureTotalCapacity(self.allocator, est_codepaths);

        try self.seg_collapse_visit.ensureTotalCapacity(self.allocator, est_segments);
        try self.collapse_frontier.ensureTotalCapacity(self.allocator, 64);
        // ChoiceContext slab: 128 slots covers realistic nesting depth.
        self.choice_slab = try self.allocator.alloc(ChoiceContext, 128);
        self.choice_slab_top = 0;
        // Segment-ID result pool: each createSegments call uses count slots (usually 1).
        // est_segments is a safe upper bound for the total pool usage per file.
        const pool = try self.allocator.alloc(SegmentId, est_segments);
        self.seg_id_pool = pool.ptr;
        self.seg_id_pool_top = 0;
        self.seg_id_pool_cap = @intCast(pool.len);
    }

    /// Free all internal allocations. Call after finish() returns the Result.
    pub fn deinit(self: *CodePathBuilder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns the segment ID at the current execution point, or NONE_SEG if no
    /// code path is active. Used by event_resolver to tag each reference with
    /// the segment where it occurs.
    pub fn currentSegId(self: *const CodePathBuilder) SegmentId {
        if (self.current_codepath == NONE_CP) return NONE_SEG;
        const h = self.fork_context.head();
        if (h.len == 0) return NONE_SEG;
        return h[0];
    }

    // ── Segment creation ─────────────────────────────────────

    fn newRootSegment(self: *CodePathBuilder) !SegmentId {
        const id: SegmentId = @intCast(self.segments.len);
        // Capture CURRENT pool lengths — earlier root segments may have been
        // created mid-pool (after other segments appended), so leaving these
        // at 0 breaks the CSR-tight invariant that writeCfgGraph relies on
        // (`seg_prev_start[i+1] == seg_prev_end[i]`).  Empty range at the
        // current end is correct: this segment contributes 0 to each pool.
        const ap_pos: u32 = @intCast(self.all_prev_targets.items.len);
        const p_pos: u32 = @intCast(self.prev_targets.items.len);
        const cp_pos: u32 = @intCast(self.collapsed_prev_targets.items.len);
        try self.segments.append(self.allocator, .{
            .codepath = self.current_codepath,
            .all_prev_start = ap_pos,
            .all_prev_end = ap_pos,
            .prev_start = p_pos,
            .prev_end = p_pos,
            .looped_prev_start = 0,
            .looped_prev_end = 0,
            .collapsed_prev_start = cp_pos,
            .collapsed_prev_end = cp_pos,
        });
        try self.seg_reachable.append(self.allocator, 1);
        try self.seg_used.append(self.allocator, 0);
        try self.seg_next.append(self.allocator, .{});
        try self.seg_collapse_visit.append(self.allocator, 0);
        return id;
    }

    /// Create a new segment that follows the given previous segments.
    /// Reachable if any prev is reachable.
    pub fn newNextSegment(self: *CodePathBuilder, all_prev: []const SegmentId) !SegmentId {
        const flattened = try self.flattenUnused(all_prev);
        var any_reachable = false;
        for (flattened) |p| {
            if (p != NONE_SEG and (self.seg_reachable.items[p] != 0)) {
                any_reachable = true;
                break;
            }
        }
        return self.createSegment(flattened, any_reachable, false);
    }

    /// Create an unreachable segment.
    pub fn newUnreachableSegment(self: *CodePathBuilder, all_prev: []const SegmentId) !SegmentId {
        const flattened = try self.flattenUnused(all_prev);
        const id = try self.createSegment(flattened, false, false);
        // Unreachable segments are immediately marked used (ESLint behavior).
        try self.markUsed(id);
        return id;
    }

    /// Create a disconnected segment (no edge connections, inherits reachability).

    fn createSegment(self: *CodePathBuilder, all_prev: []const SegmentId, is_reachable: bool, _: bool) !SegmentId {
        const id: SegmentId = @intCast(self.segments.len);
        const alloc = self.allocator;
        // When bump pools are active, the JS-buffer pools were pre-sized to a
        // worst-case upper bound. Any growth would land in the wrong arena
        // (and FBA can't grow non-last allocs anyway), so route to bump.
        const pool_alloc = if (self.bump_alloc) |ba| ba else alloc;

        // Single fused pass over all_prev — one capacity check per target list,
        // no re-read of the input slice.
        try self.all_prev_targets.ensureUnusedCapacity(pool_alloc, all_prev.len);
        try self.prev_targets.ensureUnusedCapacity(pool_alloc, all_prev.len);
        const ap_start: u32 = @intCast(self.all_prev_targets.items.len);
        const p_start: u32 = @intCast(self.prev_targets.items.len);
        const reach_s = self.seg_reachable.items;
        for (all_prev) |p| {
            self.all_prev_targets.appendAssumeCapacity(p);
            if (p != NONE_SEG and reach_s[p] != 0) {
                self.prev_targets.appendAssumeCapacity(p);
            }
        }
        const ap_end: u32 = @intCast(self.all_prev_targets.items.len);
        const p_end: u32 = @intCast(self.prev_targets.items.len);

        // For unreachable segments: BFS through unreachable predecessors to
        // collect their reachable ancestors. Used by JS to give rules a
        // direct reachable-ancestor list (skips runtime walks).
        const cp_start: u32 = @intCast(self.collapsed_prev_targets.items.len);
        if (!is_reachable and all_prev.len > 0) {
            try self.buildCollapsedPrev(pool_alloc, all_prev);
        }
        const cp_end: u32 = @intCast(self.collapsed_prev_targets.items.len);

        try self.segments.append(alloc, .{
            .codepath = self.current_codepath,
            .all_prev_start = ap_start,
            .all_prev_end = ap_end,
            .prev_start = p_start,
            .prev_end = p_end,
            .looped_prev_start = 0,
            .looped_prev_end = 0,
            .collapsed_prev_start = cp_start,
            .collapsed_prev_end = cp_end,
        });
        try self.seg_reachable.append(alloc, if (is_reachable) 1 else 0);
        try self.seg_used.append(alloc, 0);
        try self.seg_next.append(alloc, .{});
        try self.seg_collapse_visit.append(alloc, 0);
        return id;
    }

    /// Compute the reachable-ancestor closure of an unreachable segment by
    /// inheriting from each prev: if prev is reachable, include it directly;
    /// if unreachable, include its already-computed collapsed_prev set.
    /// O(prev_count + sum_of_inherited_sets) per call, dedup via gen counter.
    fn buildCollapsedPrev(self: *CodePathBuilder, alloc: Allocator, all_prev: []const SegmentId) !void {
        const reach_s = self.seg_reachable.items;
        const cps_arr = self.segments.items(.collapsed_prev_start);
        const cpe_arr = self.segments.items(.collapsed_prev_end);

        self.collapse_gen +%= 1;
        if (self.collapse_gen == 0) {
            @memset(self.seg_collapse_visit.items, 0);
            self.collapse_gen = 1;
        }
        const gen = self.collapse_gen;
        const visit = self.seg_collapse_visit.items;

        // Reserve worst-case capacity for collapsed_prev_targets in one shot:
        // sum of all_prev's reachable contributions. Upper bound: sum of each
        // unreachable prev's collapsed_prev_end - collapsed_prev_start, plus
        // count of reachable prevs.
        var max_add: usize = 0;
        for (all_prev) |p| {
            if (p == NONE_SEG) continue;
            if (reach_s[p] != 0) {
                max_add += 1;
            } else {
                max_add += cpe_arr[p] - cps_arr[p];
            }
        }
        try self.collapsed_prev_targets.ensureUnusedCapacity(alloc, max_add);

        const cpt = &self.collapsed_prev_targets;
        for (all_prev) |p| {
            if (p == NONE_SEG) continue;
            if (reach_s[p] != 0) {
                if (visit[p] != gen) {
                    visit[p] = gen;
                    cpt.appendAssumeCapacity(p);
                }
                continue;
            }
            // Unreachable prev — inherit its already-built collapsed list.
            const cps = cps_arr[p];
            const cpe = cpe_arr[p];
            for (cpt.items[cps..cpe]) |reach_id| {
                if (visit[reach_id] != gen) {
                    visit[reach_id] = gen;
                    cpt.appendAssumeCapacity(reach_id);
                }
            }
        }
    }

    /// Mark a segment as used — registers it in prev segments' next lists.
    pub inline fn markUsed(self: *CodePathBuilder, seg_id: SegmentId) !void {
        if (seg_id == NONE_SEG) return;
        if (self.seg_used.items[seg_id] != 0) return;
        self.seg_used.items[seg_id] = 1;
        const aps = self.segments.items(.all_prev_start)[seg_id];
        const ape = self.segments.items(.all_prev_end)[seg_id];

        const all_prev = self.all_prev_targets.items[aps..ape];
        const alloc = self.allocator;
        const is_reachable = self.seg_reachable.items[seg_id] != 0;
        const next_info = self.seg_next.items;

        try self.all_next_targets.ensureUnusedCapacity(alloc, all_prev.len);
        if (is_reachable) try self.next_targets.ensureUnusedCapacity(alloc, all_prev.len);

        for (all_prev) |prev_id| {
            if (prev_id == NONE_SEG) continue;
            const ni = &next_info[prev_id];
            if (ni.all_next_end == 0) {
                ni.all_next_start = @intCast(self.all_next_targets.items.len);
            }
            self.all_next_targets.appendAssumeCapacity(seg_id);
            ni.all_next_end = @intCast(self.all_next_targets.items.len);

            if (is_reachable) {
                if (ni.next_end == 0) {
                    ni.next_start = @intCast(self.next_targets.items.len);
                }
                self.next_targets.appendAssumeCapacity(seg_id);
                ni.next_end = @intCast(self.next_targets.items.len);
            }
        }
    }

    /// Mark a prev segment as looped (back-edge from loop end to loop head).
    pub fn markLooped(self: *CodePathBuilder, seg_id: SegmentId, prev_seg_id: SegmentId) !void {
        if (seg_id == NONE_SEG or prev_seg_id == NONE_SEG) return;
        const lp_start = &self.segments.items(.looped_prev_start)[seg_id];
        const lp_end = &self.segments.items(.looped_prev_end)[seg_id];
        const ni_prev = &self.seg_next.items[prev_seg_id];

        if (lp_end.* == 0) {
            lp_start.* = @intCast(self.looped_targets.items.len);
        }
        try self.looped_targets.append(self.allocator, prev_seg_id);
        lp_end.* = @intCast(self.looped_targets.items.len);

        if (ni_prev.all_next_end == 0) {
            ni_prev.all_next_start = @intCast(self.all_next_targets.items.len);
        }
        try self.all_next_targets.append(self.allocator, seg_id);
        ni_prev.all_next_end = @intCast(self.all_next_targets.items.len);

        if (self.seg_reachable.items[prev_seg_id] != 0) {
            if (ni_prev.next_end == 0) {
                ni_prev.next_start = @intCast(self.next_targets.items.len);
            }
            try self.next_targets.append(self.allocator, seg_id);
            ni_prev.next_end = @intCast(self.next_targets.items.len);
        }
    }

    /// Flatten unused segments: replace unused segments with their prev segments.
    /// Returns the INPUT slice unchanged when no dedup/expand was needed —
    /// callers treat the returned slice as read-only.
    fn flattenUnused(self: *CodePathBuilder, segments: []const SegmentId) ![]SegmentId {
        if (segments.len == 0) return &.{};

        // Single-segment fast path — 60%+ of calls.  Used: pass through the
        // caller's slice (no alloc).  Unused: return the prev range directly.
        if (segments.len == 1) {
            const s = segments[0];
            if (s == NONE_SEG) return &.{};
            if (self.seg_used.items[s] != 0) {
                return @constCast(segments);
            }
            const aps = self.segments.items(.all_prev_start)[s];
            const ape = self.segments.items(.all_prev_end)[s];
            return self.all_prev_targets.items[aps..ape];
        }

        // Small linear-scan dedup on a stack buffer.  32 covers all real cases;
        // HashMap fallback only when pathological deduplication hits.
        var buf: [32]SegmentId = undefined;
        const n_first = self.flattenSmall(segments, &buf) orelse {
            // Input exceeded buffer — must use HashMap.
            return self.flattenLarge(segments);
        };

        // If output == input verbatim, return the input slice (no alloc).
        if (n_first == segments.len) {
            var i: usize = 0;
            while (i < n_first) : (i += 1) if (buf[i] != segments[i]) break;
            if (i == n_first) return @constCast(segments);
        }

        const out = try self.allocator.alloc(SegmentId, n_first);
        @memcpy(out, buf[0..n_first]);
        return out;
    }

    /// Linear-scan flatten into a caller-provided stack buffer.
    /// Returns `null` if more than buf.len distinct segments would be produced.
    inline fn flattenSmall(self: *CodePathBuilder, segments: []const SegmentId, buf: *[32]SegmentId) ?usize {
        var n: usize = 0;
        const used_s = self.seg_used.items;
        const aps_arr = self.segments.items(.all_prev_start);
        const ape_arr = self.segments.items(.all_prev_end);
        outer: for (segments) |seg_id| {
            if (seg_id == NONE_SEG) continue;
            if (used_s[seg_id] != 0) {
                for (buf[0..n]) |e| if (e == seg_id) continue :outer;
                if (n >= buf.len) return null;
                buf[n] = seg_id;
                n += 1;
            } else {
                const prev = self.all_prev_targets.items[aps_arr[seg_id]..ape_arr[seg_id]];
                prev_loop: for (prev) |p| {
                    if (p == NONE_SEG) continue;
                    for (buf[0..n]) |e| if (e == p) continue :prev_loop;
                    if (n >= buf.len) return null;
                    buf[n] = p;
                    n += 1;
                }
            }
        }
        return n;
    }

    /// Pathological path — input produces >32 distinct segments.  Uses HashMap.
    fn flattenLarge(self: *CodePathBuilder, segments: []const SegmentId) ![]SegmentId {
        var result: std.ArrayListUnmanaged(SegmentId) = .empty;
        var seen = std.AutoHashMap(SegmentId, void).init(self.allocator);
        defer seen.deinit();
        try seen.ensureTotalCapacity(@intCast(segments.len));
        try result.ensureTotalCapacity(self.allocator, segments.len);

        const aps_arr = self.segments.items(.all_prev_start);
        const ape_arr = self.segments.items(.all_prev_end);
        for (segments) |seg_id| {
            if (seg_id == NONE_SEG) continue;
            if (seen.contains(seg_id)) continue;

            if (self.seg_used.items[seg_id] == 0) {
                const prev = self.all_prev_targets.items[aps_arr[seg_id]..ape_arr[seg_id]];
                for (prev) |p| {
                    if (p != NONE_SEG and !seen.contains(p)) {
                        try seen.put(p, {});
                        try result.append(self.allocator, p);
                    }
                }
            } else {
                try seen.put(seg_id, {});
                try result.append(self.allocator, seg_id);
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    // ── CodePath management ──────────────────────────────────

    /// Enter a new code path (function, program, class field, static block).
    /// Enter a new code path. `node` = the function/program node. `body_node` = the body
    /// (BlockStatement) — initial segment events fire at body_node so they're after the
    /// function node's enter handler (rules set up state in MethodDefinition handler first).
    pub fn enterCodePath(self: *CodePathBuilder, node: NodeIndex, origin: Origin, body_node: NodeIndex) !void {
        const cp_id: CodePathId = @intCast(self.codepaths.items.len);
        const upper = self.current_codepath;
        self.current_codepath = cp_id;

        // Create initial segment
        const initial_seg = try self.newRootSegment();

        // Create fork context (save current as upper for restore on exitCodePath)
        const fc = try self.allocator.create(ForkContext);
        const upper_fc: ?*ForkContext = if (upper != NONE_CP) self.fork_context else null;
        fc.* = ForkContext.init(self.allocator, upper_fc, 1);
        const seg_slice = try self.allocator.alloc(SegmentId, 1);
        seg_slice[0] = initial_seg;
        try fc.add(seg_slice, self);
        self.fork_context = fc;

        try self.codepaths.append(self.allocator, .{
            .origin = origin,
            .upper = upper,
            .initial_segment = initial_seg,
            // Pool ranges are filled in by `flattenCpPools()` at finish time.
            .final_start = 0,
            .final_end = 0,
            .returned_start = 0,
            .returned_end = 0,
            .thrown_start = 0,
            .thrown_end = 0,
        });
        // Per-cp scratch lists — kept parallel to `self.codepaths`.
        try self.cp_returned_lists.append(self.allocator, .empty);
        try self.cp_thrown_lists.append(self.allocator, .empty);

        // Emit events (enter phase)
        try self.events.append(self.allocator, .{
            .type = .codepath_start,
            .node = node,
            .data1 = cp_id,
            .data2 = 0,
            .phase = .enter,
        });

        // Mark initial segment used and emit segment start at body_node
        // (fires at body enter, after the function node's enter handler)
        try self.markUsed(initial_seg);
        try self.emitSegStart(initial_seg, body_node, .enter);
    }

    /// Exit the current code path.
    pub fn exitCodePath(self: *CodePathBuilder, node: NodeIndex) !void {
        const cp_id = self.current_codepath;

        // End current segments (post phase — fires AFTER exit handlers)
        const head = self.fork_context.head();
        for (head) |seg_id| {
            if (seg_id != NONE_SEG) {
                try self.emitSegEnd(seg_id, node, .post);
            }
        }

        // Record final segments.
        // ESLint populates finalSegments incrementally: when return/throw is called,
        // the REACHABLE segments at that point are added. At exit, the head may be
        // unreachable (after return/throw), but finalSegments already has the reachable ones.
        // We replicate: use returned+thrown as finals, plus any reachable head segments.
        //
        // `cp_final_pool` is filled CONTIGUOUSLY per codepath here, at exit time,
        // when no other codepath can interleave — so the (start, end) range scheme
        // is safe for finals. (`returned`/`thrown` ARE interleavable and live in
        // per-cp lists instead — flattened by `flattenCpPools()`.)
        var cp = &self.codepaths.items[cp_id];
        cp.final_start = @intCast(self.cp_final_pool.items.len);
        const ret_list = &self.cp_returned_lists.items[cp_id];
        const thr_list = &self.cp_thrown_lists.items[cp_id];
        // Add returned segments first (reachable at point of return)
        for (ret_list.items) |seg_id| {
            try self.cp_final_pool.append(self.allocator, seg_id);
        }
        // Add thrown segments
        for (thr_list.items) |seg_id| {
            var dup = false;
            for (self.cp_final_pool.items[cp.final_start..]) |existing| {
                if (existing == seg_id) { dup = true; break; }
            }
            if (!dup) try self.cp_final_pool.append(self.allocator, seg_id);
        }
        // Add reachable head segments (for paths that reach the end without return/throw)
        for (head) |seg_id| {
            if (seg_id != NONE_SEG and (self.seg_reachable.items[seg_id] != 0)) {
                var dup = false;
                for (self.cp_final_pool.items[cp.final_start..]) |existing| {
                    if (existing == seg_id) { dup = true; break; }
                }
                if (!dup) try self.cp_final_pool.append(self.allocator, seg_id);
            }
        }
        // If nothing was added (all paths exit and head is unreachable), add head anyway
        if (self.cp_final_pool.items.len == cp.final_start) {
            for (head) |seg_id| {
                try self.cp_final_pool.append(self.allocator, seg_id);
            }
        }
        cp.final_end = @intCast(self.cp_final_pool.items.len);

        // Reachable final segments are also returned segments (implicit return).
        // Only add reachable ones — unreachable finals mean all paths explicitly
        // return/throw, so they shouldn't appear in returnedSegments.
        if (cp.origin != .program) {
            for (head) |seg_id| {
                if (seg_id != NONE_SEG and (self.seg_reachable.items[seg_id] != 0)) {
                    try ret_list.append(self.allocator, seg_id);
                }
            }
        }

        // Emit codepath end (post phase — fires AFTER exit handlers)
        try self.events.append(self.allocator, .{
            .type = .codepath_end,
            .node = node,
            .data1 = cp_id,
            .data2 = 0,
            .phase = .post,
        });

        // Restore upper code path
        self.current_codepath = cp.upper;
        if (self.fork_context.upper) |upper_fc| {
            self.fork_context = upper_fc;
        }
    }

    // ── Segment event emission ───────────────────────────────

    fn emitSegStart(self: *CodePathBuilder, seg_id: SegmentId, node: NodeIndex, phase: EventPhase) !void {
        if (seg_id == NONE_SEG) return;
        const is_reachable = self.seg_reachable.items[seg_id] != 0;
        try self.events.append(self.allocator, .{
            .type = if (is_reachable) .seg_start else .unreachable_seg_start,
            .node = node,
            .data1 = seg_id,
            .data2 = 0,
            .phase = phase,
        });
    }

    fn emitSegEnd(self: *CodePathBuilder, seg_id: SegmentId, node: NodeIndex, phase: EventPhase) !void {
        if (seg_id == NONE_SEG) return;
        const is_reachable = self.seg_reachable.items[seg_id] != 0;
        try self.events.append(self.allocator, .{
            .type = if (is_reachable) .seg_end else .unreachable_seg_end,
            .node = node,
            .data1 = seg_id,
            .data2 = 0,
            .phase = phase,
        });
    }

    fn emitSegLoop(self: *CodePathBuilder, from_seg: SegmentId, to_seg: SegmentId, node: NodeIndex) !void {
        try self.events.append(self.allocator, .{
            .type = .seg_loop,
            .node = node,
            .data1 = from_seg,
            .data2 = to_seg,
            .phase = .exit, // loop events always fire at exit
        });
    }

    // ── Forward head segments (emit end + start for new segments) ─

    pub fn forwardCurrentToHead(self: *CodePathBuilder, node: NodeIndex, phase: EventPhase) !void {
        const head = self.fork_context.head();
        for (head) |seg_id| {
            if (seg_id != NONE_SEG) {
                try self.markUsed(seg_id);
                try self.emitSegStart(seg_id, node, phase);
            }
        }
    }

    pub fn leaveFromCurrentSegment(self: *CodePathBuilder, node: NodeIndex, phase: EventPhase) !void {
        const head = self.fork_context.head();
        for (head) |seg_id| {
            if (seg_id != NONE_SEG) {
                try self.emitSegEnd(seg_id, node, phase);
            }
        }
    }

    // ── Choice (if/else, logical, conditional) ───────────────

    pub fn pushChoiceContext(self: *CodePathBuilder, kind: ChoiceKind, is_forking: bool) !void {
        _ = is_forking;
        // Use the pre-allocated slab instead of arena alloc.
        // Falls back to arena alloc only when nesting exceeds 128 (pathological).
        const ctx: *ChoiceContext = if (self.choice_slab_top < self.choice_slab.len) blk: {
            const c = &self.choice_slab[self.choice_slab_top];
            self.choice_slab_top += 1;
            break :blk c;
        } else try self.allocator.create(ChoiceContext);
        ctx.* = .{
            .upper = self.choice_context,
            .kind = kind,
            .true_fork = newEmptyForkContext(self.allocator, self.fork_context, false),
            .false_fork = newEmptyForkContext(self.allocator, self.fork_context, false),
            .processed = false,
        };
        self.choice_context = ctx;
    }

    pub fn popChoiceContext(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.choice_context orelse return;
        self.choice_context = ctx.upper;
        // Return slab slot if this context came from the slab.
        if (@intFromPtr(ctx) >= @intFromPtr(self.choice_slab.ptr) and
            @intFromPtr(ctx) < @intFromPtr(self.choice_slab.ptr) + self.choice_slab.len * @sizeOf(ChoiceContext))
        {
            self.choice_slab_top -= 1;
        }

        const last_branch_end = self.fork_context.head();
        try self.leaveFromCurrentSegment(node, .exit);

        var combined = newEmptyForkContext(self.allocator, self.fork_context, false);
        if (ctx.kind == .loop or ctx.kind == .switch_kind) {
            // Loop: addAll entries — skip-path + all continue/break exits must all
            // become predecessors of the post-loop segment.
            // Switch: each `case … break;` adds its head to true_fork; all such
            // break exits must merge into the post-switch segment (not just the
            // last one — otherwise earlier breaks lose their successor edge and
            // backward liveness misreports their writes as useless).
            const n_tf = ctx.true_fork.totalLen();
            for (0..n_tf) |i| {
                try combined.add(ctx.true_fork.getEntry(i), self);
            }
        } else if (!ctx.true_fork.empty()) {
            try combined.add(ctx.true_fork.head(), self);
        }
        // For while/for loops: body-end loops back (not a post-loop exit); skip it so
        // post-loop is formed from true_fork only (skip-path + break exits).
        // For do-while: condition-end IS the exit path; include last_branch_end.
        if (!ctx.skip_last_branch_end) {
            try combined.add(last_branch_end, self);
        }

        if (!combined.empty()) {
            const merged = try combined.makeNext(0, -1, self);
            try self.fork_context.replaceHead(merged, self);
            try self.forwardCurrentToHead(node, .exit);
        } else if (!ctx.skip_last_branch_end) {
            // Non-loop contexts with empty combined: current head is unchanged, still emit start.
            // Loop contexts: head was already started by makeUnreachable, skip double-fire.
            try self.forwardCurrentToHead(node, .exit);
        }
    }

    pub fn makeIfConsequent(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.choice_context orelse return;
        if (!ctx.processed) {
            ctx.processed = true;
            // Fork current head into both forks — arena-backed slice stays valid.
            const head = self.fork_context.head();
            try ctx.true_fork.add(head, self);
            try ctx.false_fork.add(head, self);
        }
        // End current segments BEFORE switching to the true fork path
        try self.leaveFromCurrentSegment(node, .enter);
        const new_segs = try ctx.true_fork.makeNext(0, -1, self);
        try self.fork_context.replaceHead(new_segs, self);
        try self.forwardCurrentToHead(node, .enter);
    }

    /// Fork at condition.exit for ternary `?:`.
    /// Like makeIfConsequent but fires at the .exit phase of the condition node
    /// rather than the .enter phase of the consequent node.  This ensures the
    /// outer-ternary fork event is written before any nested-ternary events in
    /// the resolver stream, so DFS playback always sees SEG_START before SEG_END.
    pub fn makeConsequent(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.choice_context orelse return;
        if (!ctx.processed) {
            ctx.processed = true;
            const head = self.fork_context.head();
            try ctx.true_fork.add(head, self);
            try ctx.false_fork.add(head, self);
        }
        try self.leaveFromCurrentSegment(node, .exit);
        const new_segs = try ctx.true_fork.makeNext(0, -1, self);
        try self.fork_context.replaceHead(new_segs, self);
        try self.forwardCurrentToHead(node, .exit);
    }

    /// Called between LHS and RHS of a logical expression (&&, ||, ??).
    /// For `a && b`: LHS evaluated, now fork — truthy continues to RHS,
    /// falsy short-circuits to merge. Save LHS-end to the short-circuit
    /// branch, create new segment for RHS.
    pub fn makeLogicalRight(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.choice_context orelse return;
        // Save LHS ending to the short-circuit branch (true_fork).
        // leaveFromCurrentSegment replaces fork_context.head but leaves the old
        // arena-backed slice alive — true_fork keeps a valid reference.
        try ctx.true_fork.add(self.fork_context.head(), self);
        // End LHS segment, create new segment for RHS.
        // node is the LHS operand; fire at its .exit phase so the transition
        // fires after the LHS subtree is fully traversed (matching ESLint behavior).
        try self.leaveFromCurrentSegment(node, .exit);
        const new_segs = try self.fork_context.makeNext(-1, -1, self);
        try self.fork_context.replaceHead(new_segs, self);
        try self.forwardCurrentToHead(node, .exit);
    }

    pub fn makeIfAlternate(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.choice_context orelse return;
        // Save end of true branch (arena-backed slice stays valid after replaceHead).
        try ctx.true_fork.add(self.fork_context.head(), self);
        // End current (true branch ending) BEFORE switching to false path
        try self.leaveFromCurrentSegment(node, .enter);
        // Switch to false fork path
        const new_segs = try ctx.false_fork.makeNext(0, -1, self);
        try self.fork_context.replaceHead(new_segs, self);
        // Start new (else branch) segments
        try self.forwardCurrentToHead(node, .enter);
    }

    /// Like makeIfAlternate but fires at the .exit phase of `node` (the consequent).
    /// Used for ternary `?:` expressions where `node` is the consequent operand,
    /// so the transition fires after the consequent is fully traversed.
    pub fn makeConditionalAlternate(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.choice_context orelse return;
        try ctx.true_fork.add(self.fork_context.head(), self);
        try self.leaveFromCurrentSegment(node, .exit);
        const new_segs = try ctx.false_fork.makeNext(0, -1, self);
        try self.fork_context.replaceHead(new_segs, self);
        try self.forwardCurrentToHead(node, .exit);
    }

    // ── Switch ───────────────────────────────────────────────

    pub fn pushSwitchContext(self: *CodePathBuilder, has_case: bool, label: ?[]const u8) !void {
        _ = has_case;
        _ = label;

        const ctx = try self.allocator.create(SwitchContext);
        ctx.* = .{
            .upper = self.switch_context,
            .default_segments = null,
            .prev_break_target_is_switch = self.break_target_is_switch,
        };
        self.switch_context = ctx;
        self.break_target_is_switch = true;

        // Push fork context and choice context for the switch
        try self.pushForkContext();
        try self.pushChoiceContext(.switch_kind, false);
    }

    pub fn popSwitchContext(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.switch_context orelse return;
        self.switch_context = ctx.upper;
        self.break_target_is_switch = ctx.prev_break_target_is_switch;
        // Merge switch-break segments into the choice context BEFORE merging.
        try self.popChoiceContext(node);

        // If the switch has a default case, all branches are covered.
        if (ctx.default_segments != null) {
            const fc = self.fork_context;
            if (fc.totalLen() > 1) {
                const last = fc.head();
                fc.clear();
                try fc.pushEntry(last);
            }
        }

        try self.popForkContext(node);
    }

    pub fn makeSwitchCaseBody(self: *CodePathBuilder, is_default: bool, node: NodeIndex) !void {
        const ctx = self.switch_context orelse return;
        if (is_default) {
            // Arena slice stays valid; no dupe.
            ctx.default_segments = self.fork_context.head();
        }

        // End current segments (fires before SwitchCase handler)
        try self.leaveFromCurrentSegment(node, .enter);

        // Merge ALL entries in the fork context (0 to -1), not just the last.
        // This combines fallthrough from previous case + discriminant fork path.
        const list_len = self.fork_context.totalLen();
        if (list_len > 1) {
            // Multiple entries exist (fallthrough + fork): merge all
            const new_segs = try self.fork_context.makeNext(0, -1, self);
            try self.fork_context.add(new_segs, self);
        } else {
            const new_segs = try self.fork_context.makeNext(-1, -1, self);
            try self.fork_context.add(new_segs, self);
        }
        // Fire SEGMENT_START after the SwitchCase handler (after_enter phase) so that
        // sonarjs/no-fallthrough's `enteringSwitchCase` flag is set before onCodePathSegmentStart fires.
        try self.forwardCurrentToHead(node, .after_enter);
    }

    // ── Try/catch/finally ────────────────────────────────────

    pub fn pushTryContext(self: *CodePathBuilder, has_finalizer: bool, try_body_node: NodeIndex) !void {
        // Save pre-try head BEFORE creating try-body segment.  The arena-backed
        // slice stays valid even after replaceHead (only overwrites the list entry).
        const pre_try = self.fork_context.head();

        // Create a new segment for the try body so it's separate from pre-try.
        // Catch predecessor must be pre-try (before any try-body code ran).
        try self.leaveFromCurrentSegment(try_body_node, .enter);
        const try_body_segs = try self.fork_context.makeNext(-1, -1, self);
        try self.fork_context.replaceHead(try_body_segs, self);
        try self.forwardCurrentToHead(try_body_node, .enter);

        const ctx = try self.allocator.create(TryContext);
        ctx.* = .{
            .upper = self.try_context,
            .has_finalizer = has_finalizer,
            .position = .try_body,
            .returned_fork = newEmptyForkContext(self.allocator, self.fork_context, false),
            .thrown_fork = newEmptyForkContext(self.allocator, self.fork_context, false),
            .try_end_fork = newEmptyForkContext(self.allocator, self.fork_context, false),
            .pre_try_segments = pre_try,
            .last_of_try_reachable = false,
            .last_of_catch_reachable = false,
            .first_throwable_called = false,
        };
        self.try_context = ctx;

        if (has_finalizer) {
            try self.pushForkContext();
        }
    }

    pub fn popTryContext(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.try_context orelse return;
        self.try_context = ctx.upper;

        if (ctx.has_finalizer) {
            if (!ctx.thrown_fork.empty()) {
                // Pop the doubled-count fork. Extract only lane 0 (normal path).
                // Lane 1 (exception) re-throws — code after try/finally doesn't run on it.
                const doubled_fc = self.fork_context;
                if (doubled_fc.upper) |parent_fc| {
                    const parent_count = parent_fc.count;
                    const head = doubled_fc.head();
                    const lane0 = try self.allocator.alloc(SegmentId, parent_count);
                    for (0..parent_count) |i| {
                        lane0[i] = if (i < head.len) head[i] else NONE_SEG;
                    }
                    try self.leaveFromCurrentSegment(node, .exit);
                    try parent_fc.replaceHead(lane0, self);
                    self.fork_context = parent_fc;
                    try self.forwardCurrentToHead(node, .exit);
                }
            } else {
                try self.popForkContext(node);
            }
        }

        // Merge try-end + catch-end as reachable continuations
        // (either try completed normally OR catch completed)
        if (!ctx.try_end_fork.empty()) {
            try self.leaveFromCurrentSegment(node, .exit);
            var combined = newEmptyForkContext(self.allocator, self.fork_context, false);
            try combined.addAll(&ctx.try_end_fork);
            // Current head has catch-end segments.  combined is transient; no dupe needed.
            try combined.add(self.fork_context.head(), self);
            if (!combined.empty()) {
                const merged = try combined.makeNext(0, -1, self);
                try self.fork_context.replaceHead(merged, self);
            }
            try self.forwardCurrentToHead(node, .exit);
        }

        // If there's a finally block and all paths into it were via return/throw
        // (both try and catch ended unreachably), AND there were no throwable expressions
        // in the try body (thrown_fork empty), code after the try-finally is dead.
        // When thrown_fork is non-empty, ESLint propagates leaving segments to the
        // enclosing return context (leavingSegments forwarding) which we don't do;
        // applying makeUnreachable in that case causes no-useless-return FPs.
        if (ctx.has_finalizer and ctx.thrown_fork.empty() and
            !ctx.last_of_try_reachable and !ctx.last_of_catch_reachable)
        {
            try self.leaveFromCurrentSegment(node, .exit);
            const unreachable_segs = try self.fork_context.makeUnreachable(-1, -1, self);
            try self.fork_context.replaceHead(unreachable_segs, self);
            try self.forwardCurrentToHead(node, .exit);
        }
    }

    pub fn makeCatchBlock(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.try_context orelse return;
        ctx.last_of_try_reachable = self.fork_context.reachable(self);
        // Save try-body exit segments for merging in popTryContext.
        // Arena backing stays valid after subsequent replaceHead.
        try ctx.try_end_fork.add(self.fork_context.head(), self);
        ctx.position = .catch_body;

        // End try body segments, start catch segments.
        try self.leaveFromCurrentSegment(node, .enter);
        // Catch is unreachable only if: (a) no throwable expressions in try body, AND
        // (b) the try body always exits (return/throw/break — current head is unreachable).
        // Otherwise catch is reachable from pre-try segments.
        const try_body_dead = !self.fork_context.reachable(self);
        if (!ctx.first_throwable_called and try_body_dead) {
            // Try body exited without any throwable expression — catch is dead.
            const unreachable_segs = try self.fork_context.makeUnreachable(-1, -1, self);
            try self.fork_context.replaceHead(unreachable_segs, self);
            try self.forwardCurrentToHead(node, .enter);
        } else {
            // Catch is reachable from pre-try.  pre_try's arena data is immortal;
            // replaceHead just overwrites the list entry pointer.
            if (ctx.pre_try_segments) |pre_try| {
                try self.fork_context.replaceHead(pre_try, self);
            }
            const catch_segs = try self.fork_context.makeNext(-1, -1, self);
            try self.fork_context.replaceHead(catch_segs, self);
            try self.forwardCurrentToHead(node, .enter);
        }
    }

    pub fn makeFinallyBlock(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.try_context orelse return;
        ctx.last_of_catch_reachable = self.fork_context.reachable(self);
        ctx.position = .finally_body;

        try self.leaveFromCurrentSegment(node, .enter);

        // If thrownForkContext has entries (from makeFirstThrowablePathInTryBlock),
        // create a doubled-count fork for the finally body. Lane 0 = normal path,
        // lane 1 = exception/thrown path.
        if (!ctx.thrown_fork.empty() or !ctx.returned_fork.empty()) {
            // Merge normal path + returned paths for the finally entry.
            // Finally is always reachable because at least one path leads to it.
            var fc_for_normal = newEmptyForkContext(self.allocator, self.fork_context, false);
            // Add current head (may be unreachable after return).  fc_for_normal
            // is transient; shared ref into fork_context.segments_list is safe.
            const cur_head = self.fork_context.head();
            if (cur_head.len > 0) {
                try fc_for_normal.add(cur_head, self);
            }
            // Add returned paths (these are reachable — they existed before return made code dead)
            if (!ctx.returned_fork.empty()) {
                try fc_for_normal.addAll(&ctx.returned_fork);
            }
            const normal_segs = try fc_for_normal.makeNext(0, -1, self);

            // Create the exception-path finally entry from thrown segments
            const thrown_segs = try ctx.thrown_fork.makeNext(0, -1, self);

            // Push a doubled-count fork context
            const parent_count = self.fork_context.count;
            const new_fc = try self.allocator.create(ForkContext);
            new_fc.* = ForkContext.init(self.allocator, self.fork_context, parent_count * 2);

            // Seed with [normal_lane..., exception_lane...]
            const doubled = try self.allocator.alloc(SegmentId, parent_count * 2);
            for (0..parent_count) |i| {
                doubled[i] = if (i < normal_segs.len) normal_segs[i] else NONE_SEG;
                doubled[i + parent_count] = if (i < thrown_segs.len) thrown_segs[i] else NONE_SEG;
            }
            try new_fc.pushEntry(doubled);
            self.fork_context = new_fc;
            // Start both lanes
            try self.forwardCurrentToHead(node, .enter);
        } else {
            // No throwable paths — simple finally (no count doubling)
            const new_segs = try self.fork_context.makeNext(-1, -1, self);
            try self.fork_context.replaceHead(new_segs, self);
            try self.forwardCurrentToHead(node, .enter);
        }
    }

    // ── Loops ────────────────────────────────────────────────

    /// `target_node`: the loop's condition/body/update child node for isLoopingTarget matching.
    /// `has_skip_path`: true when the loop has a condition that can be false initially (while/for
    ///   with condition, for-in/of with potentially empty collection).  false for do-while and
    ///   for(;;) / for(init;;update) — loops that cannot be skipped on the first iteration.
    pub fn pushLoopContext(self: *CodePathBuilder, loop_type: LoopType, label: ?[]const u8, loop_node: NodeIndex, target_node: NodeIndex, has_skip_path: bool) !void {
        const ctx = try self.allocator.create(LoopContext);
        ctx.* = .{
            .upper = self.loop_context,
            .continue_fork = newEmptyForkContext(self.allocator, self.fork_context, false),
            .break_fork = newEmptyForkContext(self.allocator, self.fork_context, false),
            .node = loop_node,
            .label = label orelse "",
            .is_do_while = (loop_type == .do_while_stmt),
            .has_skip_path = has_skip_path,
            .prev_break_target_is_switch = self.break_target_is_switch,
        };
        self.loop_context = ctx;
        self.break_target_is_switch = false;

        try self.pushChoiceContext(.loop, false);

        // For while/for loops (non-do-while): body-end doesn't directly reach
        // post-loop — it either loops back or exits via break. Skip last_branch_end
        // when forming the post-loop segment in popChoiceContext.
        // For do-while: condition-end IS the exit path, so include last_branch_end.
        if (self.choice_context) |cc| {
            cc.skip_last_branch_end = !ctx.is_do_while;
        }

        // For while/for loops, save current head as the "loop skipped" path.
        // If the condition is false initially, control skips the body entirely.
        // do-while and for(;;) cannot be skipped, so no false/skip path.
        //
        // Insert a fresh segment between pre-loop code and the loop test BEFORE
        // saving the skip-path head. Without this, ez merges any pre-loop
        // statements into the same segment that holds the test fork — backward
        // liveness then walks back through pre-loop writes when computing the
        // back-edge entry's liveness, wrongly killing values that body writes
        // to keep alive across iterations. ESLint's CFG already separates
        // these; this matches the model.
        //
        // Fire the SEG_START event with the loop statement node (not target_node)
        // so JS-side rules don't misclassify this segment. constructor-super in
        // particular has a special case for `node.parent.update === node` that
        // treats for-update segments as "super called in every path"; firing
        // with target_node = the update expression would falsely match.
        if (has_skip_path) {
            try self.leaveFromCurrentSegment(loop_node, .enter);
            const test_segs = try self.fork_context.makeNext(-1, -1, self);
            try self.fork_context.replaceHead(test_segs, self);
            try self.forwardCurrentToHead(loop_node, .enter);
            if (self.choice_context) |cc| {
                try cc.true_fork.add(self.fork_context.head(), self);
            }
        }

        // Emit segment transition: end current, start loop body segment
        // Use target_node (test/body/update child) so isLoopingTarget matches
        try self.leaveFromCurrentSegment(target_node, .enter);
        const new_segs = try self.fork_context.makeNext(-1, -1, self);
        try self.fork_context.replaceHead(new_segs, self);
        try self.forwardCurrentToHead(target_node, .enter);
        // Always save entry segments for LOOP event (used as toSegment).
        ctx.entry_segments = self.fork_context.head();
    }

    pub fn popLoopContext(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.loop_context orelse return;
        self.loop_context = ctx.upper;
        self.break_target_is_switch = ctx.prev_break_target_is_switch;
        if (self.choice_context) |cc| {
            if (!ctx.continue_fork.empty()) try cc.true_fork.addAll(&ctx.continue_fork);
            if (!ctx.break_fork.empty()) try cc.true_fork.addAll(&ctx.break_fork);
        }
        // Use the loop statement node for segment events so they fire at the correct
        // AST node during traversal. The loop_close event arrives with node=.none
        // (only loop_open is patched); fall back to `node` if ctx.node is unset.
        const loop_node = if (ctx.node != .none) ctx.node else node;
        // For infinite loops (no condition, no skip path, not do-while): body-end loops
        // forever so mark it unreachable — post-loop is formed from break exits only.
        // Loops with a skip path (while/for with condition) and do-while are excluded:
        // their body-end is reachable (loops back), or the condition-end is the exit.
        if (!ctx.is_do_while and !ctx.has_skip_path) try self.makeUnreachable(loop_node);
        try self.popChoiceContext(loop_node);
    }

    pub fn makeLoopBackEdge(self: *CodePathBuilder, node: NodeIndex) !void {
        const ctx = self.loop_context orelse return;
        const head = self.fork_context.head();
        const dest = ctx.continue_dest_segments orelse ctx.entry_segments;
        if (dest) |d| {
            for (head) |from_seg| {
                // Only create back-edges from reachable segments.
                // If the loop body always exits (return/throw/break), no back-edge.
                if (from_seg != NONE_SEG and (self.seg_reachable.items[from_seg] != 0)) {
                    for (d) |to_seg| {
                        if (to_seg != NONE_SEG) {
                            try self.markLooped(to_seg, from_seg);
                        }
                    }
                }
            }
        }
        // Emit LOOP event with entry_segments as toSegment (for isLoopingTarget).
        // Also emit from continue_fork segments — `continue` creates back-edges too.
        const entry = ctx.entry_segments orelse ctx.continue_dest_segments;
        if (entry) |e| {
            const loop_node = if (ctx.node != .none) ctx.node else node;
            for (head) |from_seg| {
                if (from_seg != NONE_SEG and (self.seg_reachable.items[from_seg] != 0)) {
                    for (e) |to_seg| {
                        if (to_seg != NONE_SEG) try self.emitSegLoop(from_seg, to_seg, loop_node);
                    }
                }
            }
            // continue-based back-edges
            const n_cont = ctx.continue_fork.totalLen();
            for (0..n_cont) |ei| {
                for (ctx.continue_fork.getEntry(ei)) |from_seg| {
                    if (from_seg == NONE_SEG or self.seg_reachable.items[from_seg] == 0) continue;
                    for (e) |to_seg| {
                        if (to_seg != NONE_SEG) try self.emitSegLoop(from_seg, to_seg, loop_node);
                    }
                }
            }
        }
    }

    pub fn setLoopContinueDest(self: *CodePathBuilder) void {
        const ctx = self.loop_context orelse return;
        ctx.continue_dest_segments = self.fork_context.head();
    }

    // ── Return/Throw ─────────────────────────────────────────

    pub fn makeReturn(self: *CodePathBuilder, node: NodeIndex, has_argument: bool) !void {
        const cp_id = self.current_codepath;
        if (cp_id == NONE_CP) return;

        // Record reachable segments (unreachable returns are dead code). Append
        // to this cp's per-cp list — flattened into `cp_returned_pool` later.
        const head = self.fork_context.head();
        var any_reachable = false;
        const reach_s = self.seg_reachable.items;
        const ret_list = &self.cp_returned_lists.items[cp_id];
        for (head) |seg_id| {
            if (seg_id != NONE_SEG and reach_s[seg_id] != 0) {
                any_reachable = true;
                try ret_list.append(self.allocator, seg_id);
            }
        }

        // If inside a try-with-finally, add head to the try's returned_fork.
        if (self.try_context) |tc| {
            if (tc.has_finalizer and tc.position != .finally_body) {
                try tc.returned_fork.add(head, self);
            }
            // `return expr;` evaluates an expression that can throw — same as makeThrow,
            // it makes the catch body reachable from the pre-try state.
            if (has_argument and tc.position == .try_body and !tc.first_throwable_called) {
                tc.first_throwable_called = true;
                try tc.thrown_fork.add(head, self);
            }
        }

        // Already-dead head: no new unreachable segment needed.
        if (!any_reachable) return;

        try self.leaveFromCurrentSegment(node, .post);
        const unreachable_segs = try self.fork_context.makeUnreachable(-1, -1, self);
        try self.fork_context.replaceHead(unreachable_segs, self);
        try self.forwardCurrentToHead(node, .post);
    }

    /// Mark current head as unreachable (e.g., after infinite loop with no break).
    pub fn makeUnreachable(self: *CodePathBuilder, node: NodeIndex) !void {
        // If the current head is already all-unreachable, skip creating
        // another unreachable segment — the existing one is semantically
        // equivalent as a successor target.  Terminator-after-terminator
        // (break then return, etc.) hits this path.
        const head = self.fork_context.head();
        var any_reachable = false;
        const reach_s = self.seg_reachable.items;
        for (head) |s| {
            if (s != NONE_SEG and reach_s[s] != 0) { any_reachable = true; break; }
        }
        if (!any_reachable) return;

        try self.leaveFromCurrentSegment(node, .exit);
        const unreachable_segs = try self.fork_context.makeUnreachable(-1, -1, self);
        try self.fork_context.replaceHead(unreachable_segs, self);
        try self.forwardCurrentToHead(node, .exit);
    }

    pub fn makeContinue(self: *CodePathBuilder, node: NodeIndex) !void {
        if (self.loop_context) |lc| {
            try lc.continue_fork.add(self.fork_context.head(), self);
        }
        try self.makeUnreachable(node);
    }

    /// Labeled `continue lbl` — walks the LoopContext chain and adds to the
    /// matching loop's continue_fork.  Falls back to innermost if not found.
    pub fn makeContinueLabeled(self: *CodePathBuilder, label: []const u8, node: NodeIndex) !void {
        var lc = self.loop_context;
        while (lc) |ctx| : (lc = ctx.upper) {
            if (ctx.label.len > 0 and std.mem.eql(u8, ctx.label, label)) {
                try ctx.continue_fork.add(self.fork_context.head(), self);
                break;
            }
        } else if (self.loop_context) |lc_inner| {
            try lc_inner.continue_fork.add(self.fork_context.head(), self);
        }
        try self.makeUnreachable(node);
    }

    /// Labeled `break lbl` — walks the LoopContext chain and adds to the
    /// matching loop's break_fork.  Falls back to innermost if not found.
    pub fn makeBreakLabeled(self: *CodePathBuilder, label: []const u8, node: NodeIndex) !void {
        var lc = self.loop_context;
        while (lc) |ctx| : (lc = ctx.upper) {
            if (ctx.label.len > 0 and std.mem.eql(u8, ctx.label, label)) {
                try ctx.break_fork.add(self.fork_context.head(), self);
                break;
            }
        } else if (self.loop_context) |lc_inner| {
            if (!self.break_target_is_switch) {
                try lc_inner.break_fork.add(self.fork_context.head(), self);
            }
        }
        try self.makeUnreachable(node);
    }

    pub fn makeBreak(self: *CodePathBuilder, node: NodeIndex) !void {
        if (!self.break_target_is_switch) {
            if (self.loop_context) |lc| {
                try lc.break_fork.add(self.fork_context.head(), self);
            }
        } else {
            // break inside switch: save the current head to the switch's choice
            // context true_fork so popChoiceContext includes it in the post-switch
            // merge. Walk UP the choice-context stack to find the switch — the
            // break may be nested inside an `if`/ternary whose own choice context
            // is on top, and adding to that one drops the break-segment from the
            // switch's post-merge entirely.
            var cc_opt = self.choice_context;
            while (cc_opt) |cc| : (cc_opt = cc.upper) {
                if (cc.kind == .switch_kind) {
                    try cc.true_fork.add(self.fork_context.head(), self);
                    break;
                }
            }
        }
        try self.makeUnreachable(node);
    }

    pub fn makeThrow(self: *CodePathBuilder, node: NodeIndex) !void {
        const cp_id = self.current_codepath;
        if (cp_id == NONE_CP) return;

        const head = self.fork_context.head();
        var any_reachable = false;
        const reach_s = self.seg_reachable.items;
        const thr_list = &self.cp_thrown_lists.items[cp_id];
        for (head) |seg_id| {
            if (seg_id != NONE_SEG and reach_s[seg_id] != 0) {
                any_reachable = true;
                try thr_list.append(self.allocator, seg_id);
            }
        }

        if (self.try_context) |ctx| {
            if (ctx.position == .try_body) {
                ctx.first_throwable_called = true;
                try ctx.thrown_fork.add(head, self);
            }
        }

        if (!any_reachable) return;

        try self.leaveFromCurrentSegment(node, .post);
        const unreachable_segs = try self.fork_context.makeUnreachable(-1, -1, self);
        try self.fork_context.replaceHead(unreachable_segs, self);
        try self.forwardCurrentToHead(node, .post);
    }

    // ── Fork context management ──────────────────────────────

    pub fn pushForkContext(self: *CodePathBuilder) !void {
        const new_fc = try self.allocator.create(ForkContext);
        new_fc.* = ForkContext.init(self.allocator, self.fork_context, self.fork_context.count);
        // Carry over parent's current head so child operations can reference them as prev.
        // Parent stays alive as new_fc.upper — no dupe needed.
        const parent_head = self.fork_context.head();
        if (parent_head.len > 0) {
            try new_fc.add(parent_head, self);
        }
        self.fork_context = new_fc;
    }

    pub fn popForkContext(self: *CodePathBuilder, node: NodeIndex) !void {
        const fc = self.fork_context;
        if (fc.upper) |upper| {
            if (!fc.empty()) {
                // End current segments before merge
                try self.leaveFromCurrentSegment(node, .exit);
                const merged = try fc.makeNext(0, -1, self);
                try upper.replaceHead(merged, self);
            }
            self.fork_context = upper;
            // Start the merged segments so they get SEG_START events
            if (!fc.empty()) {
                try self.forwardCurrentToHead(node, .exit);
            }
        }
    }

    // ── Result extraction ────────────────────────────────────

    pub const Result = struct {
        /// True iff prev_targets / all_prev_targets / collapsed_prev_targets
        /// were allocated from a bump partition exposed via writeCfgGraph's
        /// `buf` argument. When set, writeCfgGraph can publish their offsets
        /// directly without copying.
        bump_pools_active: bool = false,
        seg_count: u32,
        /// Segment fields as parallel slices (SoA).  Hot reads of individual
        /// fields avoid a 28-byte struct load.
        seg_codepath: []const CodePathId,
        seg_all_prev_start: []const u32,
        seg_all_prev_end: []const u32,
        seg_prev_start: []const u32,
        seg_prev_end: []const u32,
        seg_looped_prev_start: []const u32,
        seg_looped_prev_end: []const u32,
        seg_collapsed_prev_start: []const u32,
        seg_collapsed_prev_end: []const u32,
        /// Per-segment flags.
        seg_reachable: []const u8,
        /// Per-segment adjacency (all_next_*/next_*) ranges.
        seg_next: []const SegNextInfo,
        codepaths: []const CodePath,
        events: []const Event,
        // Adjacency target pools
        all_prev_targets: []const SegmentId,
        prev_targets: []const SegmentId,
        all_next_targets: []const SegmentId,
        next_targets: []const SegmentId,
        looped_targets: []const SegmentId,
        collapsed_prev_targets: []const SegmentId,
        // CodePath segment pools
        cp_final_pool: []const SegmentId,
        cp_returned_pool: []const SegmentId,
        cp_thrown_pool: []const SegmentId,
        /// Arena owning all the above slices.  `finish()` transfers ownership
        /// of the builder's arena here so we skip ~20 MB of per-array memcpy.
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *Result, _: std.mem.Allocator) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    /// Flatten per-codepath `cp_returned_lists` / `cp_thrown_lists` into the
    /// flat `cp_returned_pool` / `cp_thrown_pool`, filling each codepath's
    /// `(start, end)` slice indices. Called once, just before `finish()` returns.
    ///
    /// This is the crux of the interleaving fix: during building, multiple
    /// codepaths can append returns/throws in any order (outer fn → inner fn
    /// → back to outer). The flat pool sees an arbitrary interleave. By
    /// keeping per-cp lists during building and only flattening at the end —
    /// in `self.codepaths.items` order, contiguous per cp — every codepath's
    /// `(start, end)` range covers exactly its own entries.
    fn flattenCpPools(self: *CodePathBuilder) !void {
        const cp_count = self.codepaths.items.len;
        // Returned pool.
        self.cp_returned_pool.clearRetainingCapacity();
        for (0..cp_count) |i| {
            var cp = &self.codepaths.items[i];
            cp.returned_start = @intCast(self.cp_returned_pool.items.len);
            const list = self.cp_returned_lists.items[i].items;
            if (list.len > 0) {
                try self.cp_returned_pool.appendSlice(self.allocator, list);
            }
            cp.returned_end = @intCast(self.cp_returned_pool.items.len);
        }
        // Thrown pool.
        self.cp_thrown_pool.clearRetainingCapacity();
        for (0..cp_count) |i| {
            var cp = &self.codepaths.items[i];
            cp.thrown_start = @intCast(self.cp_thrown_pool.items.len);
            const list = self.cp_thrown_lists.items[i].items;
            if (list.len > 0) {
                try self.cp_thrown_pool.appendSlice(self.allocator, list);
            }
            cp.thrown_end = @intCast(self.cp_thrown_pool.items.len);
        }
    }

    /// Optional dump of the CFG event list — fires when `EZ_DUMP_CFG_EVENTS`
    /// points to a writable path. Used to bisect ordering divergences between
    /// the streaming and non-streaming `resolveFullImpl` paths. Format is
    /// stable so the two paths' dumps can be diffed line-by-line.
    fn maybeDumpEvents(self: *const CodePathBuilder) void {
        const path_z = std.c.getenv("EZ_DUMP_CFG_EVENTS") orelse return;
        // Convert C string to slice.
        var path_len: usize = 0;
        while (path_z[path_len] != 0) path_len += 1;
        const path = path_z[0..path_len];
        // Open via std.c (we link libc); avoid Io complexity here.
        const fd = std.c.open(@ptrCast(path_z), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var buf: [256]u8 = undefined;
        for (self.events.items, 0..) |ev, i| {
            const slice = std.fmt.bufPrint(&buf, "{d} type={d} node={d} d1={d} d2={d} phase={d}\n", .{
                i,
                @intFromEnum(ev.type),
                @intFromEnum(ev.node),
                ev.data1,
                ev.data2,
                @intFromEnum(ev.phase),
            }) catch continue;
            _ = std.c.write(fd, slice.ptr, slice.len);
        }
        _ = path; // captured into the open() call already
    }

    /// Consume the builder and return a Result that owns the arena.
    /// After finish(), `self` is invalid — do NOT call deinit() on it.
    /// `Result.deinit()` frees the arena.
    pub fn finish(self: *CodePathBuilder) Result {
        // Errors here would only come from arena OOM. The caller already
        // had to handle that during building; surface it as a hard panic so
        // we don't have to thread errors through the finish() API and every
        // call site. Realistically unreachable.
        self.flattenCpPools() catch |e| @panic(@errorName(e));
        self.maybeDumpEvents();
        const result: Result = .{
            .bump_pools_active = self.bump_pools_active,
            .seg_count = @intCast(self.segments.len),
            .seg_codepath = self.segments.items(.codepath),
            .seg_all_prev_start = self.segments.items(.all_prev_start),
            .seg_all_prev_end = self.segments.items(.all_prev_end),
            .seg_prev_start = self.segments.items(.prev_start),
            .seg_prev_end = self.segments.items(.prev_end),
            .seg_looped_prev_start = self.segments.items(.looped_prev_start),
            .seg_looped_prev_end = self.segments.items(.looped_prev_end),
            .seg_collapsed_prev_start = self.segments.items(.collapsed_prev_start),
            .seg_collapsed_prev_end = self.segments.items(.collapsed_prev_end),
            .seg_reachable = self.seg_reachable.items,
            .seg_next = self.seg_next.items,
            .codepaths = self.codepaths.items,
            .events = self.events.items,
            .all_prev_targets = self.all_prev_targets.items,
            .prev_targets = self.prev_targets.items,
            .all_next_targets = self.all_next_targets.items,
            .next_targets = self.next_targets.items,
            .looped_targets = self.looped_targets.items,
            .collapsed_prev_targets = self.collapsed_prev_targets.items,
            .cp_final_pool = self.cp_final_pool.items,
            .cp_returned_pool = self.cp_returned_pool.items,
            .cp_thrown_pool = self.cp_thrown_pool.items,
            .arena = self.arena,
        };
        self.* = undefined;
        return result;
    }
};
