const std = @import("std");
const Ast = @import("ast.zig").Ast;
const semantic_mod = @import("semantic.zig");
const code_path_mod = @import("code_path.zig");

// ── Constants ────────────────────────────────────────────────────

/// Magic number: ASCII "SANZ" in little-endian — legacy, kept for binary stability.
pub const MAGIC: u32 = 0x5A4E_4153;
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: u32 = @sizeOf(BufferHeader);

/// Bit flags for the `flags` field in BufferHeader.
pub const FLAG_HAS_BOM: u32 = 1;

// ── Buffer Header ────────────────────────────────────────────────

/// Written at offset 0 of the shared buffer after parsing.
/// All offsets are byte offsets from the start of the buffer.
/// 35 fields × 4 bytes = 140 bytes.
pub fn semanticDataOffsetFieldOff() u32 {
    return @offsetOf(BufferHeader, "semantic_data_offset");
}

pub fn semHeaderCfgGraphOffsetFieldOff() u32 {
    return @offsetOf(SemanticHeader, "cfg_graph_offset");
}

pub const BufferHeader = extern struct {
    magic: u32,
    version: u32,
    node_count: u32,
    token_count: u32,
    extra_count: u32,
    source_len: u32,
    source_utf16_len: u32,
    tags_offset: u32,
    main_tokens_offset: u32,
    data_offset: u32,
    extra_data_offset: u32,
    tok_tags_offset: u32,
    tok_starts_offset: u32,
    source_offset: u32,
    total_used: u32,
    flags: u32,
    // Added in v2: parent pointer array for ESTree-compatible traversal.
    parent_indices_offset: u32,
    // Added in v3: semantic data (scope/symbol/reference tables).
    // Non-zero = byte offset of SemanticHeader in this buffer; 0 = not present.
    semantic_data_offset: u32 = 0,
    // Added in v4: DFS traversal order arrays (pre-order and post-order).
    // Non-zero = byte offset of a u32[] of length node_count.
    pre_order_offset: u32 = 0,
    post_order_offset: u32 = 0,
    // Added in v5: interleaved DFS events array (i32[] of length node_count * 2).
    // Positive = enter (node index), negative = exit (~node index).
    dfs_events_offset: u32 = 0,
    // Source type: 1 = module, 0 = script.
    source_type: u32 = 1,
    // Added in v6: comment positions from lexer.
    // comment_count = number of comments; starts/ends are u32[] of that length;
    // kinds is u8[] (0 = line //, 1 = block /* */).
    comment_count: u32 = 0,
    comment_starts_offset: u32 = 0,
    comment_ends_offset: u32 = 0,
    comment_kinds_offset: u32 = 0,
    // Added in v7: token end positions (UTF-16), one per token.
    tok_ends_offset: u32 = 0,
    // Added in v8: pre-computed node start/end positions (UTF-16).
    // Eliminates JS-side _computeAllEndPos() and _nodeStartPos().
    node_start_pos_offset: u32 = 0,
    node_end_pos_offset: u32 = 0,
    // Added in v9: line starts (UTF-16) + maxTok per node.
    // Eliminates JS-side _lineStarts() scan and _ensureMaxTokCache() propagation.
    line_starts_offset: u32 = 0,
    line_starts_count: u32 = 0,
    max_tok_offset: u32 = 0,
    min_tok_offset: u32 = 0,
    // Added in v10: sorted node indices for O(log n) getNodeByRangeIndex.
    // Sorted by (start ASC, range_size ASC) so innermost nodes come first.
    sorted_by_start_offset: u32 = 0,
    // Added in v11: merged token+comment order.
    // u32[token_count + comment_count], ascending by start offset.
    // Entries: value < token_count → token index; value >= token_count →
    // comment index (value - token_count).
    // JS views this to expose `sourceCode.tokensAndComments` without merging.
    tok_cmt_merge_offset: u32 = 0,
    // v12: resolved parent indices (parent post grouping_expr / ts_parenthesized_type
    // skip). u32[node_count]. Eliminates a JS-side parent-chain while-loop in
    // `get parent`'s slow path.
    resolved_parent_offset: u32 = 0,
    // v13: ESTree-shape `type` override slot per node. u8[node_count]. 0 means
    // "no override; use TAG_NAMES[tag]"; 1..19 select an entry in JS-side
    // `_OVERRIDE_TYPES` (PrivateIdentifier, Property, TSImportEquals…, etc).
    // See parent_builder.TypeOverride for the mapping.
    type_overrides_offset: u32 = 0,
    // v14: ESTree-shape parent-synthesis dispatch slot per node. u8[node_count].
    // 0 = no synthesis (use resolved-parent NodeView directly); 1..6 select a
    // synthetic-wrapper or redirect path in JS-side `get parent`. Replaces the
    // post-resolve tag-pattern cascade with a single typed-array read.
    // See parent_builder.ParentKind for the mapping.
    parent_kind_offset: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(BufferHeader) == 152);
}

// ── Semantic Data Header ─────────────────────────────────────────

/// Secondary header written into the bump region when semantic analysis is run.
/// All offsets are byte offsets from the start of the buffer (same origin as BufferHeader).
/// 38 u32 fields = 152 bytes.
pub const SemanticHeader = extern struct {
    scope_count: u32,
    symbol_count: u32,
    ref_count: u32,
    _pad: u32 = 0,

    // Scope arrays (indexed by ScopeId)
    scope_kinds_offset: u32,           // u8[]  — ScopeKind enum
    scope_flags_offset: u32,           // u16[] — ScopeFlags packed struct
    scope_parents_offset: u32,         // u32[] — parent ScopeId (NONE = root)
    scope_node_ids_offset: u32,        // u32[] — AST node that created this scope
    scope_bindings_start_offset: u32,  // u32[] — index into symbol table
    scope_bindings_count_offset: u32,  // u32[] — number of symbols in scope

    // Symbol arrays (indexed by SymbolId)
    symbol_flags_offset: u32,          // u16[] — SymbolFlags packed struct
    symbol_scope_ids_offset: u32,      // u32[] — ScopeId where declared
    symbol_decl_nodes_offset: u32,     // u32[] — declaration AST node
    symbol_ref_starts_offset: u32,     // u32[] — RefRange.start
    symbol_ref_ends_offset: u32,       // u32[] — RefRange.end
    symbol_name_starts_offset: u32,    // u32[] — byte offset of name in source
    symbol_name_lens_offset: u32,      // u32[] — byte length of name

    // Reference arrays (indexed by ReferenceId)
    ref_symbol_ids_offset: u32,        // u32[] — resolved SymbolId (NONE = unresolved)
    ref_kinds_offset: u32,             // u8[]  — ReferenceKind enum
    ref_node_ids_offset: u32,          // u32[] — AST node of reference
    ref_scope_ids_offset: u32,         // u32[] — scope of reference
    ref_write_expr_ids_offset: u32,    // u32[] — write expression node (NONE if not a write ref)

    // Node → containing scope mapping (one entry per AST node)
    node_scope_ids_offset: u32,        // u32[] — for each node, its containing ScopeId

    // Per-node reachability (one byte per AST node): 1 = live, 0 = dead code
    node_reachable_offset: u32,        // u8[] — 1 if node is in reachable code path

    // Per-loop exit reachability (one byte per AST node, only meaningful for loops):
    // 1 = code after the loop is reachable, 0 = loop exit is dead (infinite/all-return body).
    // Non-loop nodes default to 1.
    loop_exit_reachable_offset: u32,   // u8[] — 1 if loop exit is reachable

    // Code path events: triples of u32 (event_type, node_idx, data).
    cfg_events_offset: u32,
    cfg_events_count: u32,             // number of u32 values (= 3 * event_count)

    // Full code path graph offset (points to CfgGraphHeader, 0 = not present).
    cfg_graph_offset: u32 = 0,

    // Scope → refs CSR (refs sorted by scope via counting sort)
    scope_ref_starts_offset: u32 = 0,  // u32[scope_count] — first index in scope_ref_ids
    scope_ref_counts_offset: u32 = 0,  // u32[scope_count] — number of refs per scope
    scope_ref_ids_offset: u32 = 0,     // u32[ref_count]   — ref indices sorted by scope

    // Scope → children CSR (child scopes sorted by parent)
    scope_child_starts_offset: u32 = 0, // u32[scope_count]     — first index in scope_child_ids
    scope_child_counts_offset: u32 = 0, // u32[scope_count]     — number of children per scope
    scope_child_ids_offset: u32 = 0,    // u32[total_children]  — child scope IDs sorted by parent

    // Tag → nodes CSR (nodes grouped by tag via counting sort)
    tag_node_starts_offset: u32 = 0,    // u32[tag_count + 1]  — prefix-sum (sentinel at end)
    tag_node_ids_offset: u32 = 0,       // u32[node_count]     — node indices sorted by tag
    tag_count: u32 = 0,                 // number of tag slots (= max_tag + 1)

    // Node depths: depth[root]=0, depth[child]=depth[parent]+1
    node_depths_offset: u32 = 0,        // u32[node_count]

    // Symbol binding kind (one byte per symbol — BindingKind enum value)
    symbol_kinds_offset: u32 = 0,       // u8[symbol_count] — BindingKind

    // Scope → through-refs CSR — precomputed per-scope list of refs that pass
    // THROUGH this scope without resolving (target scope is a strict ancestor,
    // or ref is unresolved).  Walking from ref.scope up to sym.scope, each
    // intermediate scope accumulates the ref in its through list.  Lets the JS
    // side avoid O(scopes × children-through) bubble-up per file.
    scope_through_ref_starts_offset: u32 = 0,  // u32[scope_count]
    scope_through_ref_counts_offset: u32 = 0,  // u32[scope_count]
    scope_through_ref_ids_offset: u32 = 0,     // u32[total_through]

    // Indirect ref-by-symbol index: ref_by_sym[start..end] yields ReferenceIds
    // for a given symbol. Parallel to symbol_ref_starts/ends offsets.
    sym_ref_indirect_offset: u32 = 0,          // u32[ref_count]

    // Scope → symbols CSR: sym IDs sorted by scope (counting sort).
    // scope_bindings_start/count index into this array, not the raw sym table.
    scope_sym_ids_offset: u32 = 0,             // u32[sym_count]

    // Node → declared-symbols CSR (Phase B: replaces JS-side
    // `_ensureDeclSymIndex`). For each node, the list of symbols whose
    // declaration is at-or-below that node, walking up to the nearest
    // function/class barrier. `getDeclaredVariables(node)` reads it
    // directly. Prefix-sum form: count[i] = starts[i+1] - starts[i].
    decl_sym_node_starts_offset: u32 = 0,      // u32[node_count + 1]
    decl_sym_node_ids_offset: u32 = 0,         // u32[total_entries]
};

comptime {
    std.debug.assert(@sizeOf(SemanticHeader) == 184);
    std.debug.assert(@offsetOf(SemanticHeader, "ref_write_expr_ids_offset") == 84);
    std.debug.assert(@offsetOf(SemanticHeader, "node_depths_offset") == 148);
    std.debug.assert(@offsetOf(SemanticHeader, "symbol_kinds_offset") == 152);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_through_ref_starts_offset") == 156);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_through_ref_counts_offset") == 160);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_through_ref_ids_offset") == 164);
    std.debug.assert(@offsetOf(SemanticHeader, "cfg_graph_offset") == 108);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_ref_starts_offset") == 112);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_ref_counts_offset") == 116);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_ref_ids_offset") == 120);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_child_starts_offset") == 124);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_child_counts_offset") == 128);
    std.debug.assert(@offsetOf(SemanticHeader, "scope_child_ids_offset") == 132);
    std.debug.assert(@offsetOf(SemanticHeader, "tag_node_starts_offset") == 136);
    std.debug.assert(@offsetOf(SemanticHeader, "tag_node_ids_offset") == 140);
    std.debug.assert(@offsetOf(SemanticHeader, "tag_count") == 144);
}

// ── CFG Graph Header ────────────────────────────────────────────

/// Header for the full multi-segment code path graph.
/// Written into the bump region by writeCfgGraph().
pub const CfgGraphHeader = extern struct {
    segment_count: u32,
    codepath_count: u32,
    event_count: u32,

    // Per-segment data
    seg_reachable_offset: u32,         // u8[segment_count]
    seg_codepath_offset: u32,          // u32[segment_count] — owning codepath

    // Adjacency lists (CSR: starts[N+1] + targets[])
    seg_next_starts_offset: u32,       // u32[segment_count + 1]
    seg_next_targets_offset: u32,      // u32[total_next_edges]
    seg_prev_starts_offset: u32,       // u32[segment_count + 1]
    seg_prev_targets_offset: u32,      // u32[total_prev_edges]
    seg_all_next_starts_offset: u32,
    seg_all_next_targets_offset: u32,
    seg_all_prev_starts_offset: u32,
    seg_all_prev_targets_offset: u32,
    seg_looped_starts_offset: u32,
    seg_looped_targets_offset: u32,
    // Collapsed prev: reachable ancestors of each unreachable segment (BFS-precomputed).
    seg_collapsed_prev_starts_offset: u32,
    seg_collapsed_prev_targets_offset: u32,

    // Per-codepath data
    cp_origin_offset: u32,             // u8[codepath_count]
    cp_upper_offset: u32,              // u32[codepath_count]
    cp_initial_seg_offset: u32,        // u32[codepath_count]
    cp_final_starts_offset: u32,       // u32[codepath_count + 1]
    cp_final_targets_offset: u32,
    cp_returned_starts_offset: u32,    // u32[codepath_count + 1]
    cp_returned_targets_offset: u32,
    cp_thrown_starts_offset: u32,      // u32[codepath_count + 1]
    cp_thrown_targets_offset: u32,

    // Event stream (4 u32s per event: type, node_idx, data1, data2)
    events_offset: u32,                // u32[event_count * 4]

    // Per-phase CSR for fast O(1) per-node event lookup. JS uses these to avoid
    // building 4 Maps from `events` on every `runPlugins` call. Phases:
    //   0 = enter, 1 = exit, 2 = post, 3 = after_enter
    // For each phase: starts[node_count + 1] + data[total_phase_events * 3]
    // (interleaved type, d1, d2 — same encoding as the per-node event lists JS used to build).
    // node_count is implicit (BufferHeader exposes it; CSR length checks against it).
    cfg_phase_node_count: u32,                  // node count used to size phase_*_starts
    cfg_phase_enter_starts_offset: u32,         // u32[node_count + 1]
    cfg_phase_enter_data_offset: u32,           // u32[total_enter_events * 3]
    cfg_phase_exit_starts_offset: u32,
    cfg_phase_exit_data_offset: u32,
    cfg_phase_post_starts_offset: u32,
    cfg_phase_post_data_offset: u32,
    cfg_phase_after_enter_starts_offset: u32,
    cfg_phase_after_enter_data_offset: u32,
    cfg_node_bits_offset: u32,                  // u8[node_count] — 1 if node has any phase events
    cfg_subtree_bits_offset: u32,               // u8[node_count] — 1 if subtree rooted at node contains any cfg-event node (own bit OR'd up via parents)
};

// ── Semantic Data Serializer ─────────────────────────────────────

/// Serialize scope/symbol/reference tables into the bump region.
/// Returns the byte offset of the written SemanticHeader (for BufferHeader.semantic_data_offset).
/// Returns error if there is not enough space in the buffer.
/// Tags that halt the `decl_sym` walk — function and class boundaries.
/// Mirrors `_FN_TAGS` + `_CLASS_TAG_SET` in js/eslint-runner.js. A symbol
/// declared inside a function only "belongs to" that function and its
/// containing scope path; the walk-up stops at the function boundary.
inline fn isDeclSymBarrierTag(tag: ast_mod.Node.Tag) bool {
    return switch (tag) {
        .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl,
        .class_decl,
        .fn_expr, .async_fn_expr, .generator_fn_expr, .async_generator_fn_expr,
        .class_expr, .arrow_fn, .async_arrow_fn,
        .method_def, .getter_def, .setter_def, .constructor_def,
        .computed_method_def, .computed_getter_def, .computed_setter_def,
        .ts_declare_function => true,
        else => false,
    };
}

/// Compute the tag→nodes CSR into the bump region. Standalone so the main
/// thread can run it during the worker's analyzer phase. Returns the three
/// header field values (starts_off, ids_off, tag_count).
pub const TagNodeCsrResult = struct {
    starts_offset: u32,
    ids_offset: u32,
    tag_count: u32,
};
pub fn computeTagNodeCsr(
    buf: [*]u8,
    backing: *JsBufferAllocator,
    node_tags: []const ast_mod.Node.Tag,
) !TagNodeCsrResult {
    if (node_tags.len == 0) return .{ .starts_offset = 0, .ids_offset = 0, .tag_count = 0 };
    const alloc = backing.allocator();
    const node_count: u32 = @intCast(node_tags.len);
    var max_tag: u32 = 0;
    for (node_tags) |t| {
        const tv: u32 = @intFromEnum(t);
        if (tv > max_tag) max_tag = tv;
    }
    const tag_slots: u32 = max_tag + 1;
    const tag_node_starts = try alloc.alloc(u32, tag_slots + 1);
    const tag_node_ids = try alloc.alloc(u32, node_count);
    @memset(tag_node_starts, 0);
    for (node_tags) |t| tag_node_starts[@intFromEnum(t)] += 1;
    var running: u32 = 0;
    for (0..tag_slots) |i| {
        const c = tag_node_starts[i];
        tag_node_starts[i] = running;
        running += c;
    }
    tag_node_starts[tag_slots] = running;
    const cursor = try alloc.alloc(u32, tag_slots);
    @memcpy(cursor, tag_node_starts[0..tag_slots]);
    for (0..node_count) |i| {
        const tv: u32 = @intFromEnum(node_tags[i]);
        tag_node_ids[cursor[tv]] = @intCast(i);
        cursor[tv] += 1;
    }
    return .{
        .starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(tag_node_starts.ptr))),
        .ids_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(tag_node_ids.ptr))),
        .tag_count = tag_slots,
    };
}

/// Compute node depths into the bump region. Standalone so the main thread
/// can run it during the streaming-sem worker's analyzer phase, avoiding a
/// second pass on the worker. Returns absolute offset of the depths array.
pub fn computeNodeDepths(
    buf: [*]u8,
    backing: *JsBufferAllocator,
    parent_indices: []const u32,
    node_count: u32,
) !u32 {
    if (node_count == 0) return 0;
    const alloc = backing.allocator();
    const node_depths = try alloc.alloc(u32, node_count);
    // No memset — every slot is overwritten in the loop below (parents have
    // higher indices than children, so reverse iteration sees parent first).
    var i: usize = node_count;
    while (i > 0) {
        i -= 1;
        const p = parent_indices[i];
        node_depths[i] = if (p < node_count) node_depths[p] + 1 else 0;
    }
    return ptrOffsetPub(buf, @as([*]u8, @ptrCast(node_depths.ptr)));
}

pub fn writeSemanticData(
    buf: [*]u8,
    backing: *JsBufferAllocator,
    sem: *const semantic_mod.SemanticResult,
    node_count: u32,
    node_tags: []const ast_mod.Node.Tag,
    parent_indices: []const u32,
    precomputed_node_depths_offset: u32,
    precomputed_tag_csr: ?TagNodeCsrResult,
    /// If non-zero, skip writeCfgGraph and use this offset directly. Used when
    /// main thread runs writeCfgGraph in parallel with the worker.
    precomputed_cfg_graph_offset: u32,
    /// If non-null, the worker spin-waits on this atomic before reading
    /// `tag_csr_late.*`. Lets main run computeTagNodeCsr in parallel with
    /// the worker's scope CSRs and main's own UTF-16/tok_cmt phases instead
    /// of charging the 1.9 ms cost to the pre-fire chain.
    tag_csr_ready: ?*std.atomic.Value(bool),
    tag_csr_late: ?*const ?TagNodeCsrResult,
    /// If non-null, the worker spin-waits on this atomic just before its own
    /// writeCfgGraph call and reads the main-thread-computed CFG offset from
    /// `cfg_offset_late.*`.  Lets main run writeCfgGraph during the trav_join
    /// wait, hiding the ~4 ms cost off worker's tail.  Fallback: if
    /// `cfg_offset_late.*` is 0 after the wait, worker computes itself.
    cfg_done: ?*std.atomic.Value(bool),
    cfg_offset_late: ?*const u32,
) !u32 {
    const alloc = backing.allocator();
    const scope_count: u32 = @intCast(sem.scopes.kinds.items.len);
    const symbol_count: u32 = @intCast(sem.symbols.names.items.len);
    const ref_count: u32 = @intCast(sem.references.symbol_ids.items.len);
    const none32: u32 = std.math.maxInt(u32);

    // ── Scope arrays ────────────────────────────────────────────
    const scope_kinds = try alloc.alloc(u8, scope_count);
    const scope_flags = try alloc.alloc(u16, scope_count);
    const scope_parents = try alloc.alloc(u32, scope_count);
    const scope_node_ids = try alloc.alloc(u32, scope_count);
    const scope_bindings_start = try alloc.alloc(u32, scope_count);
    const scope_bindings_count = try alloc.alloc(u32, scope_count);

    for (0..scope_count) |i| {
        scope_kinds[i] = @intFromEnum(sem.scopes.kinds.items[i]);
        scope_flags[i] = @bitCast(sem.scopes.flags.items[i]);
        const p = sem.scopes.parents.items[i];
        scope_parents[i] = if (p == .none) none32 else @intFromEnum(p);
        const nid = sem.scopes.node_ids.items[i];
        scope_node_ids[i] = if (nid == .none) none32 else @intFromEnum(nid);
        scope_bindings_start[i] = sem.scopes.bindings_start.items[i];
        scope_bindings_count[i] = sem.scopes.bindings_count.items[i];
    }

    // ── Symbol arrays ────────────────────────────────────────────
    const symbol_flags = try alloc.alloc(u16, symbol_count);
    const symbol_kinds = try alloc.alloc(u8, symbol_count);
    const symbol_scope_ids = try alloc.alloc(u32, symbol_count);
    const symbol_decl_nodes = try alloc.alloc(u32, symbol_count);
    const symbol_ref_starts = try alloc.alloc(u32, symbol_count);
    const symbol_ref_ends = try alloc.alloc(u32, symbol_count);
    const symbol_name_starts = try alloc.alloc(u32, symbol_count);
    const symbol_name_lens = try alloc.alloc(u32, symbol_count);

    for (0..symbol_count) |i| {
        symbol_flags[i] = @bitCast(sem.symbols.flags.items[i]);
        symbol_kinds[i] = @intFromEnum(sem.symbols.binding_kinds.items[i]);
        const sid = sem.symbols.scope_ids.items[i];
        symbol_scope_ids[i] = if (sid == .none) none32 else @intFromEnum(sid);
        const dn = sem.symbols.decl_nodes.items[i];
        symbol_decl_nodes[i] = if (dn == .none) none32 else @intFromEnum(dn);
        const rr = sem.symbols.references.items[i];
        symbol_ref_starts[i] = rr.start;
        symbol_ref_ends[i] = rr.end;
        // Names: store byte offset from buffer base and byte length.
        // These are byte offsets; the JS side converts to UTF-16 indices.
        const name = sem.symbols.names.items[i];
        const is_implicit = sem.symbols.flags.items[i].is_implicit_global;
        if (is_implicit and name.len > 0) {
            // Implicit global names point into the external JS globals buffer, not the
            // source buffer.  Copy into the bump region so the JS offset math is valid.
            const name_copy = try alloc.alloc(u8, name.len);
            @memcpy(name_copy, name);
            symbol_name_starts[i] = ptrOffsetPub(buf, name_copy.ptr);
            symbol_name_lens[i] = @intCast(name.len);
        } else {
            symbol_name_starts[i] = @intCast(@intFromPtr(name.ptr) - @intFromPtr(buf));
            symbol_name_lens[i] = @intCast(name.len);
        }
    }

    // ── Reference arrays ─────────────────────────────────────────
    const ref_symbol_ids = try alloc.alloc(u32, ref_count);
    const ref_kinds = try alloc.alloc(u8, ref_count);
    const ref_node_ids = try alloc.alloc(u32, ref_count);
    const ref_scope_ids = try alloc.alloc(u32, ref_count);
    const ref_write_expr_ids = try alloc.alloc(u32, ref_count);

    for (0..ref_count) |i| {
        const rsym = sem.references.symbol_ids.items[i];
        ref_symbol_ids[i] = if (rsym == .none) none32 else @intFromEnum(rsym);
        ref_kinds[i] = @intFromEnum(sem.references.kinds.items[i]);
        const rn = sem.references.node_ids.items[i];
        ref_node_ids[i] = if (rn == .none) none32 else @intFromEnum(rn);
        const rsc = sem.references.scope_ids.items[i];
        ref_scope_ids[i] = if (rsc == .none) none32 else @intFromEnum(rsc);
        const rwe = sem.references.write_expr_ids.items[i];
        ref_write_expr_ids[i] = if (rwe == .none) none32 else @intFromEnum(rwe);
    }

    // ── Node → scope mapping ──────────────────────────────────────
    const node_scope_ids = try alloc.alloc(u32, node_count);
    @memset(node_scope_ids, none32);
    // For each scope, mark its node as belonging to that scope's parent
    // (the node that CREATED the scope is in the PARENT scope's context).
    // Separately, fill in each node's scope by walking the scopes.
    // Simple approach: for each scope, its node_id maps to that scope.
    // Then propagate downward to child nodes using the parent scope data.
    // Since this is complex, use a simpler O(n) approach: for each scope,
    // record which scope ID each node "opens". Nodes without a scope entry
    // inherit from their parent node (via parent pointer data, done outside).
    for (0..scope_count) |i| {
        const nid = sem.scopes.node_ids.items[i];
        if (nid != .none) {
            const idx: u32 = @intFromEnum(nid);
            if (idx < node_count) {
                node_scope_ids[idx] = @intCast(i);
            }
        }
    }

    // ── Scope → refs CSR + scope → through-refs CSR (parallel sub-thread) ──
    // The scope_ref/through CSR build (~3 ms on typescript.js) runs on a
    // sub-thread spawned here.  All output buffers are pre-allocated below
    // (single-threaded) so the sub-thread does no allocations and there's
    // no FBA race against this thread's later allocations.  The
    // scope_through_ref_ids buffer uses a generous upper bound (ref_count*16)
    // since total_through is unknown at alloc time; JS reads only the first
    // total_through entries (via scope_through_ref_starts[scope_count]).
    const scope_ref_starts = try alloc.alloc(u32, scope_count);
    const scope_ref_counts = try alloc.alloc(u32, scope_count);
    const scope_ref_ids = try alloc.alloc(u32, ref_count);
    const scope_through_ref_starts = try alloc.alloc(u32, scope_count);
    const scope_through_ref_counts = try alloc.alloc(u32, scope_count);
    // Upper bound: ref_count * 16 covers typescript.js (avg chain depth ≤ 4).
    // If exceeded, sub-thread sets ScopeRefAuxJob.err.
    const through_upper_bound: u32 = if (ref_count > 0) ref_count * 16 else 0;
    const scope_through_ref_ids = try alloc.alloc(u32, through_upper_bound);
    const scope_ref_cursor = try alloc.alloc(u32, scope_count);
    const scope_through_ref_cursor = try alloc.alloc(u32, scope_count);

    const ScopeRefAuxJob = struct {
        sem: *const semantic_mod.SemanticResult,
        scope_count: u32,
        symbol_count: u32,
        ref_count: u32,
        scope_ref_starts: []u32,
        scope_ref_counts: []u32,
        scope_ref_ids: []u32,
        scope_ref_cursor: []u32,
        scope_through_ref_starts: []u32,
        scope_through_ref_counts: []u32,
        scope_through_ref_ids: []u32,
        scope_through_ref_cursor: []u32,
        through_upper_bound: u32,
        total_through_out: *u32,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            const none32_local: u32 = std.math.maxInt(u32);
            const sc = self.scope_count;
            const rc = self.ref_count;
            const sym_c = self.symbol_count;
            if (sc == 0 or rc == 0) {
                @memset(self.scope_ref_starts, 0);
                @memset(self.scope_ref_counts, 0);
                @memset(self.scope_through_ref_starts, 0);
                @memset(self.scope_through_ref_counts, 0);
                self.total_through_out.* = 0;
                return;
            }
            @memset(self.scope_ref_counts, 0);
            @memset(self.scope_through_ref_counts, 0);
            var total_through: u32 = 0;
            // FUSED count pass — chain walks for through-ref tally.
            for (0..rc) |i| {
                const rsc = self.sem.references.scope_ids.items[i];
                const s = if (rsc == .none) none32_local else @intFromEnum(rsc);
                if (s < sc) self.scope_ref_counts[s] += 1;
                if (rsc == .none) continue;
                const sym_id = self.sem.references.symbol_ids.items[i];
                if (sym_id == .none) continue;
                const sid: u32 = @intFromEnum(sym_id);
                if (sid >= sym_c) continue;
                const tsc = self.sem.symbols.scope_ids.items[sid];
                const target_scope: u32 = if (tsc == .none) none32_local else @intFromEnum(tsc);
                var x: u32 = @intFromEnum(rsc);
                while (x != none32_local and x != target_scope) {
                    if (x < sc) {
                        self.scope_through_ref_counts[x] += 1;
                        total_through += 1;
                    }
                    const p = self.sem.scopes.parents.items[x];
                    x = if (p == .none) none32_local else @intFromEnum(p);
                }
            }
            self.total_through_out.* = total_through;
            if (total_through > self.through_upper_bound) {
                self.err = error.ThroughIdsBufferTooSmall;
                return;
            }
            // Prefix sums.
            var total_refs: u32 = 0;
            for (0..sc) |i| {
                self.scope_ref_starts[i] = total_refs;
                total_refs += self.scope_ref_counts[i];
            }
            var tr: u32 = 0;
            for (0..sc) |i| {
                self.scope_through_ref_starts[i] = tr;
                tr += self.scope_through_ref_counts[i];
            }
            // Scatter pass.
            @memcpy(self.scope_ref_cursor, self.scope_ref_starts);
            @memcpy(self.scope_through_ref_cursor, self.scope_through_ref_starts);
            for (0..rc) |i| {
                const rsc = self.sem.references.scope_ids.items[i];
                const s = if (rsc == .none) none32_local else @intFromEnum(rsc);
                if (s < sc) {
                    self.scope_ref_ids[self.scope_ref_cursor[s]] = @intCast(i);
                    self.scope_ref_cursor[s] += 1;
                }
                if (rsc == .none) continue;
                const sym_id = self.sem.references.symbol_ids.items[i];
                if (sym_id == .none) continue;
                const sid: u32 = @intFromEnum(sym_id);
                if (sid >= sym_c) continue;
                const tsc = self.sem.symbols.scope_ids.items[sid];
                const target_scope: u32 = if (tsc == .none) none32_local else @intFromEnum(tsc);
                var x: u32 = @intFromEnum(rsc);
                while (x != none32_local and x != target_scope) {
                    if (x < sc) {
                        self.scope_through_ref_ids[self.scope_through_ref_cursor[x]] = @intCast(i);
                        self.scope_through_ref_cursor[x] += 1;
                    }
                    const p = self.sem.scopes.parents.items[x];
                    x = if (p == .none) none32_local else @intFromEnum(p);
                }
            }
        }
    };
    var total_through: u32 = 0;
    var scope_ref_aux: ScopeRefAuxJob = .{
        .sem = sem,
        .scope_count = scope_count,
        .symbol_count = symbol_count,
        .ref_count = ref_count,
        .scope_ref_starts = scope_ref_starts,
        .scope_ref_counts = scope_ref_counts,
        .scope_ref_ids = scope_ref_ids,
        .scope_ref_cursor = scope_ref_cursor,
        .scope_through_ref_starts = scope_through_ref_starts,
        .scope_through_ref_counts = scope_through_ref_counts,
        .scope_through_ref_ids = scope_through_ref_ids,
        .scope_through_ref_cursor = scope_through_ref_cursor,
        .through_upper_bound = through_upper_bound,
        .total_through_out = &total_through,
    };
    const scope_ref_aux_thread: ?std.Thread = std.Thread.spawn(
        .{},
        ScopeRefAuxJob.run,
        .{&scope_ref_aux},
    ) catch null;
    if (scope_ref_aux_thread == null) {
        // Spawn failed: run synchronously here.
        ScopeRefAuxJob.run(&scope_ref_aux);
    }

    // ── Scope → symbols CSR (counting sort of symbols by scope) ───────
    // Provides a correct indirection array so that scope_bindings_start[s]
    // indexes into scope_sym_ids (not the raw symbol table) and yields the
    // actual symbols belonging to scope s.  Without this, buildScopeBindings
    // would silently assign symbols to the wrong scope when symbols are stored
    // in declaration order rather than sorted by scope.
    const scope_sym_ids = try alloc.alloc(u32, symbol_count);
    if (scope_count > 0 and symbol_count > 0) {
        // Step 1: count syms per scope (reuse existing scope_bindings_count)
        // scope_bindings_count is already correct; re-derive starts via prefix sum.
        var sym_cursor = try alloc.alloc(u32, scope_count);
        defer alloc.free(sym_cursor);
        var sym_total: u32 = 0;
        for (0..scope_count) |i| {
            scope_bindings_start[i] = sym_total;
            sym_cursor[i] = sym_total;
            sym_total += scope_bindings_count[i];
        }
        // Step 2: scatter sym indices into sorted order
        for (0..symbol_count) |i| {
            const ssc = sem.symbols.scope_ids.items[i];
            const s = if (ssc == .none) none32 else @intFromEnum(ssc);
            if (s < scope_count) {
                scope_sym_ids[sym_cursor[s]] = @intCast(i);
                sym_cursor[s] += 1;
            }
        }
    }

    // ── Scope → children CSR (counting sort of scopes by parent) ──
    // Count children per scope
    var total_children: u32 = 0;
    const scope_child_counts = try alloc.alloc(u32, scope_count);
    @memset(scope_child_counts, 0);
    if (scope_count > 0) {
        for (0..scope_count) |i| {
            const p = sem.scopes.parents.items[i];
            const pid = if (p == .none) none32 else @intFromEnum(p);
            if (pid < scope_count) {
                scope_child_counts[pid] += 1;
                total_children += 1;
            }
        }
    }
    const scope_child_starts = try alloc.alloc(u32, scope_count);
    const scope_child_ids = try alloc.alloc(u32, total_children);

    if (scope_count > 0 and total_children > 0) {
        // Prefix-sum → starts
        var cs: u32 = 0;
        for (0..scope_count) |i| {
            scope_child_starts[i] = cs;
            cs += scope_child_counts[i];
        }
        // Place child scope IDs
        const ccursor = try alloc.alloc(u32, scope_count);
        @memcpy(ccursor, scope_child_starts);
        for (0..scope_count) |i| {
            const p = sem.scopes.parents.items[i];
            const pid = if (p == .none) none32 else @intFromEnum(p);
            if (pid < scope_count) {
                scope_child_ids[ccursor[pid]] = @intCast(i);
                ccursor[pid] += 1;
            }
        }
    } else {
        @memset(scope_child_starts, 0);
    }

    // ── Tag → nodes CSR (counting sort on node tags) ──────────────
    // If main precomputed it, skip — those offsets feed the header directly.
    // If main is computing tag_csr LATE (in parallel with our scope CSRs and
    // main's UTF-16/tok_cmt phases), spin-wait on tag_csr_ready then read
    // tag_csr_late.*.
    var tag_starts_off: u32 = 0;
    var tag_ids_off: u32 = 0;
    var tag_slots: u32 = 0;
    var resolved_tag_csr: ?TagNodeCsrResult = precomputed_tag_csr;
    if (resolved_tag_csr == null) {
        if (tag_csr_ready) |a| {
            while (!a.load(.acquire)) std.atomic.spinLoopHint();
            if (tag_csr_late) |ptr| resolved_tag_csr = ptr.*;
        }
    }
    if (resolved_tag_csr) |c| {
        tag_starts_off = c.starts_offset;
        tag_ids_off = c.ids_offset;
        tag_slots = c.tag_count;
    } else {
        var max_tag: u32 = 0;
        for (node_tags) |t| {
            const tv: u32 = @intFromEnum(t);
            if (tv > max_tag) max_tag = tv;
        }
        tag_slots = max_tag + 1;
        const tag_node_starts = try alloc.alloc(u32, tag_slots + 1);
        const tag_node_ids = try alloc.alloc(u32, node_count);
        @memset(tag_node_starts, 0);
        for (node_tags) |t| tag_node_starts[@intFromEnum(t)] += 1;
        var running: u32 = 0;
        for (0..tag_slots) |i| {
            const c = tag_node_starts[i];
            tag_node_starts[i] = running;
            running += c;
        }
        tag_node_starts[tag_slots] = running;
        const cursor = try alloc.alloc(u32, tag_slots);
        @memcpy(cursor, tag_node_starts[0..tag_slots]);
        for (0..node_count) |i| {
            const tv: u32 = @intFromEnum(node_tags[i]);
            tag_node_ids[cursor[tv]] = @intCast(i);
            cursor[tv] += 1;
        }
        tag_starts_off = ptrOffsetPub(buf, @as([*]u8, @ptrCast(tag_node_starts.ptr)));
        tag_ids_off = ptrOffsetPub(buf, @as([*]u8, @ptrCast(tag_node_ids.ptr)));
    }

    // ── Node depths ─────────────────────────────────────────────
    // If main thread already computed these (via computeNodeDepths into its
    // own bump partition during the worker's analyzer phase), skip and reuse.
    var node_depths_offset_final: u32 = precomputed_node_depths_offset;
    if (node_depths_offset_final == 0 and node_count > 0) {
        const node_depths = try alloc.alloc(u32, node_count);
        @memset(node_depths, 0);
        var i: usize = node_count;
        while (i > 0) {
            i -= 1;
            const p = parent_indices[i];
            node_depths[i] = if (p < node_count) node_depths[p] + 1 else 0;
        }
        node_depths_offset_final = ptrOffsetPub(buf, @as([*]u8, @ptrCast(node_depths.ptr)));
    }

    // ── Node → declared symbols CSR (Phase B) ───────────────────────
    // For each node, list of symbols whose decl is at-or-below that node,
    // walking up to the nearest function/class barrier. Replaces the JS-side
    // `_ensureDeclSymIndex` Map+parent-walk (~3.8% of CPU profile).
    // Prefix-sum form: count[i] = starts[i+1] - starts[i].
    const decl_sym_starts = try alloc.alloc(u32, node_count + 1);
    @memset(decl_sym_starts, 0);
    var decl_sym_total: u32 = 0;
    if (symbol_count > 0 and node_count > 0) {
        // Pass 1: count entries per node (walk up from each decl_node to barrier).
        for (0..symbol_count) |i| {
            const decl_idx = symbol_decl_nodes[i];
            if (decl_idx == none32 or decl_idx >= node_count) continue;
            var cur: u32 = decl_idx;
            while (cur < node_count) {
                decl_sym_starts[cur] += 1;
                if (isDeclSymBarrierTag(node_tags[cur])) break;
                const p = parent_indices[cur];
                if (p == none32 or p >= node_count) break;
                cur = p;
            }
        }
        // Convert counts to prefix-sum starts. After this loop:
        // decl_sym_starts[i] = position where node i's entries begin.
        // decl_sym_starts[node_count] = total entry count.
        var running: u32 = 0;
        for (0..node_count) |i| {
            const c = decl_sym_starts[i];
            decl_sym_starts[i] = running;
            running += c;
        }
        decl_sym_starts[node_count] = running;
        decl_sym_total = running;
    }
    const decl_sym_ids = try alloc.alloc(u32, decl_sym_total);
    if (decl_sym_total > 0) {
        // Pass 2: scatter symbol IDs into the CSR using a per-node fill cursor.
        const fill = try alloc.alloc(u32, node_count);
        defer alloc.free(fill);
        @memset(fill, 0);
        for (0..symbol_count) |i| {
            const decl_idx = symbol_decl_nodes[i];
            if (decl_idx == none32 or decl_idx >= node_count) continue;
            var cur: u32 = decl_idx;
            while (cur < node_count) {
                const slot = decl_sym_starts[cur] + fill[cur];
                decl_sym_ids[slot] = @intCast(i);
                fill[cur] += 1;
                if (isDeclSymBarrierTag(node_tags[cur])) break;
                const p = parent_indices[cur];
                if (p == none32 or p >= node_count) break;
                cur = p;
            }
        }
    }

    // Join the scope_ref/through CSR sub-thread before reading its outputs.
    if (scope_ref_aux_thread) |t| {
        t.join();
        if (scope_ref_aux.err) |e| return e;
    }

    // ── SemanticHeader ────────────────────────────────────────────
    const header_mem = try alloc.alloc(u8, @sizeOf(SemanticHeader));
    const sem_header: *SemanticHeader = @ptrCast(@alignCast(header_mem.ptr));
    sem_header.* = .{
        .scope_count = scope_count,
        .symbol_count = symbol_count,
        .ref_count = ref_count,

        .scope_kinds_offset = ptrOffsetPub(buf, scope_kinds.ptr),
        .scope_flags_offset = ptrOffsetPub(buf, scope_flags.ptr),
        .scope_parents_offset = ptrOffsetPub(buf, scope_parents.ptr),
        .scope_node_ids_offset = ptrOffsetPub(buf, scope_node_ids.ptr),
        .scope_bindings_start_offset = ptrOffsetPub(buf, scope_bindings_start.ptr),
        .scope_bindings_count_offset = ptrOffsetPub(buf, scope_bindings_count.ptr),

        .symbol_flags_offset = ptrOffsetPub(buf, symbol_flags.ptr),
        .symbol_kinds_offset = if (symbol_count > 0) ptrOffsetPub(buf, symbol_kinds.ptr) else 0,
        .symbol_scope_ids_offset = ptrOffsetPub(buf, symbol_scope_ids.ptr),
        .symbol_decl_nodes_offset = ptrOffsetPub(buf, symbol_decl_nodes.ptr),
        .symbol_ref_starts_offset = ptrOffsetPub(buf, symbol_ref_starts.ptr),
        .symbol_ref_ends_offset = ptrOffsetPub(buf, symbol_ref_ends.ptr),
        .symbol_name_starts_offset = ptrOffsetPub(buf, symbol_name_starts.ptr),
        .symbol_name_lens_offset = ptrOffsetPub(buf, symbol_name_lens.ptr),

        .ref_symbol_ids_offset = ptrOffsetPub(buf, ref_symbol_ids.ptr),
        .ref_kinds_offset = ptrOffsetPub(buf, ref_kinds.ptr),
        .ref_node_ids_offset = ptrOffsetPub(buf, ref_node_ids.ptr),
        .ref_scope_ids_offset = ptrOffsetPub(buf, ref_scope_ids.ptr),
        .ref_write_expr_ids_offset = ptrOffsetPub(buf, ref_write_expr_ids.ptr),

        .node_scope_ids_offset = ptrOffsetPub(buf, node_scope_ids.ptr),

        .node_reachable_offset = blk: {
            if (sem.node_reachable.len > 0) {
                const arr = try alloc.alloc(u8, sem.node_reachable.len);
                @memcpy(arr, sem.node_reachable);
                break :blk ptrOffsetPub(buf, arr.ptr);
            }
            break :blk 0;
        },
        .loop_exit_reachable_offset = blk: {
            if (sem.loop_exit_reachable.len > 0) {
                const arr = try alloc.alloc(u8, sem.loop_exit_reachable.len);
                @memcpy(arr, sem.loop_exit_reachable);
                break :blk ptrOffsetPub(buf, arr.ptr);
            }
            break :blk 0;
        },
        .cfg_events_offset = 0, // legacy — replaced by cfg_graph_offset
        .cfg_events_count = 0,

        .cfg_graph_offset = blk: {
            if (precomputed_cfg_graph_offset != 0) break :blk precomputed_cfg_graph_offset;
            // Lazy main-side handoff: spin briefly for cfg_done; if main published
            // a non-zero offset, adopt it.  Otherwise (main couldn't run cfg, or
            // produced 0), fall through to worker computing it itself.
            if (cfg_done) |a| {
                while (!a.load(.acquire)) std.atomic.spinLoopHint();
                if (cfg_offset_late) |p| if (p.* != 0) break :blk p.*;
            }
            if (sem.code_path_result) |cpr| break :blk writeCfgGraph(buf, alloc, &cpr, node_count, parent_indices) catch 0;
            break :blk 0;
        },
    };

    // Set new fields AFTER struct write to avoid bump-allocator interactions
    // from blk: blocks (node_reachable, writeCfgGraph) during struct literal eval.
    sem_header.scope_ref_starts_offset = if (scope_count > 0) ptrOffsetPub(buf, scope_ref_starts.ptr) else 0;
    sem_header.scope_ref_counts_offset = if (scope_count > 0) ptrOffsetPub(buf, scope_ref_counts.ptr) else 0;
    sem_header.scope_ref_ids_offset = if (ref_count > 0) ptrOffsetPub(buf, scope_ref_ids.ptr) else 0;
    sem_header.scope_child_starts_offset = if (scope_count > 0) ptrOffsetPub(buf, scope_child_starts.ptr) else 0;
    sem_header.scope_child_counts_offset = if (scope_count > 0) ptrOffsetPub(buf, scope_child_counts.ptr) else 0;
    sem_header.scope_child_ids_offset = if (total_children > 0) ptrOffsetPub(buf, scope_child_ids.ptr) else 0;
    sem_header.tag_node_starts_offset = tag_starts_off;
    sem_header.tag_node_ids_offset = tag_ids_off;
    sem_header.tag_count = tag_slots;
    sem_header.node_depths_offset = node_depths_offset_final;
    sem_header.scope_through_ref_starts_offset = if (scope_count > 0) ptrOffsetPub(buf, scope_through_ref_starts.ptr) else 0;
    sem_header.scope_through_ref_counts_offset = if (scope_count > 0) ptrOffsetPub(buf, scope_through_ref_counts.ptr) else 0;
    sem_header.scope_through_ref_ids_offset = if (total_through > 0) ptrOffsetPub(buf, scope_through_ref_ids.ptr) else 0;

    sem_header.scope_sym_ids_offset = if (symbol_count > 0) ptrOffsetPub(buf, scope_sym_ids.ptr) else 0;
    sem_header.decl_sym_node_starts_offset = if (node_count > 0) ptrOffsetPub(buf, decl_sym_starts.ptr) else 0;
    sem_header.decl_sym_node_ids_offset = if (decl_sym_total > 0) ptrOffsetPub(buf, decl_sym_ids.ptr) else 0;

    // Serialize ref_by_sym indirect index (ReferenceId → u32).
    if (sem.ref_by_sym.len > 0) {
        const ref_by_sym_u32 = try alloc.alloc(u32, sem.ref_by_sym.len);
        for (sem.ref_by_sym, 0..) |r, i| ref_by_sym_u32[i] = r.toInt();
        sem_header.sym_ref_indirect_offset = ptrOffsetPub(buf, ref_by_sym_u32.ptr);
    }

    return ptrOffsetPub(buf, header_mem.ptr);
}

// ── CFG Graph Serializer ────────────────────────────────────────

/// Serialize the full code path graph into the bump region.
/// Returns the byte offset of the CfgGraphHeader.
pub fn writeCfgGraph(
    buf: [*]u8,
    alloc: std.mem.Allocator,
    cpr: *const code_path_mod.CodePathBuilder.Result,
    node_count: u32,
    parent_indices: []const u32,
) !u32 {
    const seg_count: u32 = cpr.seg_count;
    const cp_count: u32 = @intCast(cpr.codepaths.len);
    const ev_count: u32 = @intCast(cpr.events.len);

    if (seg_count == 0 and cp_count == 0) return 0;

    // ── Per-segment data ────────────────────────────────────
    const seg_reachable = try alloc.alloc(u8, seg_count);
    const seg_codepath = try alloc.alloc(u32, seg_count);
    for (0..seg_count) |i| {
        seg_reachable[i] = cpr.seg_reachable[i];
        seg_codepath[i] = cpr.seg_codepath[i];
    }

    // ── Adjacency lists (CSR format) ────────────────────────
    // Rebuild adjacency in segment-ID order. cpr's pools may have segments out
    // of order (or with gaps) so we must compact. Single-pass: count + copy
    // simultaneously since FBA is bump-only — newly allocated output arrays
    // never alias source slices in cpr's pools.
    // next/all_next omitted — JS reconstructs them by inverting prev + loopedPrev.
    // Pools are tight (CodePathBuilder appends in seg-ID order without
    // interleaving) for prev / all_prev / collapsed_prev — so the rebuild
    // collapses to a single memcpy per pool.  Looped is appended out-of-band
    // by markLooped, so it still needs the per-seg compaction loop.
    const total_prev: u32 = @intCast(cpr.prev_targets.len);
    const total_all_prev: u32 = @intCast(cpr.all_prev_targets.len);
    const total_collapsed_prev: u32 = @intCast(cpr.collapsed_prev_targets.len);
    var total_looped: u32 = 0;
    for (0..seg_count) |i| {
        if (cpr.seg_looped_prev_end[i] > cpr.seg_looped_prev_start[i])
            total_looped += cpr.seg_looped_prev_end[i] - cpr.seg_looped_prev_start[i];
    }

    const seg_prev_starts = try alloc.alloc(u32, seg_count + 1);
    const seg_all_prev_starts = try alloc.alloc(u32, seg_count + 1);
    const seg_looped_starts = try alloc.alloc(u32, seg_count + 1);
    const seg_looped_targets = try alloc.alloc(u32, total_looped);
    const seg_collapsed_prev_starts = try alloc.alloc(u32, seg_count + 1);
    // When bump_pools_active, cpr's target pools already live in the JS buffer
    // — publish their pointers directly. Otherwise allocate fresh in `alloc`
    // and memcpy from cpr's arena-resident pools.
    var seg_prev_targets: []u32 = &.{};
    var seg_all_prev_targets: []u32 = &.{};
    var seg_collapsed_prev_targets: []u32 = &.{};
    if (cpr.bump_pools_active) {
        seg_prev_targets = @constCast(cpr.prev_targets);
        seg_all_prev_targets = @constCast(cpr.all_prev_targets);
        seg_collapsed_prev_targets = @constCast(cpr.collapsed_prev_targets);
    } else {
        seg_prev_targets = try alloc.alloc(u32, total_prev);
        seg_all_prev_targets = try alloc.alloc(u32, total_all_prev);
        seg_collapsed_prev_targets = try alloc.alloc(u32, total_collapsed_prev);
        if (total_prev > 0) @memcpy(seg_prev_targets, cpr.prev_targets);
        if (total_all_prev > 0) @memcpy(seg_all_prev_targets, cpr.all_prev_targets);
        if (total_collapsed_prev > 0) @memcpy(seg_collapsed_prev_targets, cpr.collapsed_prev_targets);
    }
    if (seg_count > 0) {
        @memcpy(seg_prev_starts[0..seg_count], cpr.seg_prev_start);
        seg_prev_starts[seg_count] = total_prev;
        @memcpy(seg_all_prev_starts[0..seg_count], cpr.seg_all_prev_start);
        seg_all_prev_starts[seg_count] = total_all_prev;
        @memcpy(seg_collapsed_prev_starts[0..seg_count], cpr.seg_collapsed_prev_start);
        seg_collapsed_prev_starts[seg_count] = total_collapsed_prev;
    }

    // Looped pool: per-seg compaction (markLooped's order isn't seg-ID-monotonic).
    {
        var lo: u32 = 0;
        for (0..seg_count) |i| {
            seg_looped_starts[i] = lo;
            const lps = cpr.seg_looped_prev_start[i];
            const lpe = cpr.seg_looped_prev_end[i];
            if (lpe > lps) {
                const len = lpe - lps;
                @memcpy(seg_looped_targets[lo..][0..len], cpr.looped_targets[lps..lpe]);
                lo += len;
            }
        }
        seg_looped_starts[seg_count] = lo;
    }

    // ── Per-codepath data ───────────────────────────────────
    const cp_origin = try alloc.alloc(u8, cp_count);
    const cp_upper = try alloc.alloc(u32, cp_count);
    const cp_initial_seg = try alloc.alloc(u32, cp_count);

    // Build CSR for final/returned/thrown segment lists.
    // Pool entries are in EXIT order (inner functions first, program last),
    // but CSR requires codepath order (cp 0, cp 1, ...). Reorder here.
    const cp_final_starts = try alloc.alloc(u32, cp_count + 1);
    const cp_returned_starts = try alloc.alloc(u32, cp_count + 1);
    const cp_thrown_starts = try alloc.alloc(u32, cp_count + 1);

    for (0..cp_count) |i| {
        const cp = cpr.codepaths[i];
        cp_origin[i] = @intFromEnum(cp.origin);
        cp_upper[i] = cp.upper;
        cp_initial_seg[i] = cp.initial_segment;
    }

    // Reorder pools into codepath order
    const cp_final_targets = try alloc.alloc(u32, cpr.cp_final_pool.len);
    const cp_returned_targets = try alloc.alloc(u32, cpr.cp_returned_pool.len);
    const cp_thrown_targets = try alloc.alloc(u32, cpr.cp_thrown_pool.len);
    var final_off: u32 = 0;
    var returned_off: u32 = 0;
    var thrown_off: u32 = 0;
    for (0..cp_count) |i| {
        const cp = cpr.codepaths[i];
        cp_final_starts[i] = final_off;
        const f_len = cp.final_end - cp.final_start;
        if (f_len > 0) {
            @memcpy(cp_final_targets[final_off..][0..f_len], cpr.cp_final_pool[cp.final_start..cp.final_end]);
        }
        final_off += f_len;

        cp_returned_starts[i] = returned_off;
        const r_len = cp.returned_end - cp.returned_start;
        if (r_len > 0) {
            @memcpy(cp_returned_targets[returned_off..][0..r_len], cpr.cp_returned_pool[cp.returned_start..cp.returned_end]);
        }
        returned_off += r_len;

        cp_thrown_starts[i] = thrown_off;
        const t_len = cp.thrown_end - cp.thrown_start;
        if (t_len > 0) {
            @memcpy(cp_thrown_targets[thrown_off..][0..t_len], cpr.cp_thrown_pool[cp.thrown_start..cp.thrown_end]);
        }
        thrown_off += t_len;
    }
    cp_final_starts[cp_count] = final_off;
    cp_returned_starts[cp_count] = returned_off;
    cp_thrown_starts[cp_count] = thrown_off;

    // events_flat eliminated: JS only reads per-phase CSR (phase_data).
    // The events_offset field in CfgGraphHeader is now always 0.

    // ── Per-phase CSR (pre-baked event maps) ────────────────
    // JS used to scan `events_flat` and build 4 Maps on every runPlugins call.
    // We do that work once here in a CSR layout so the JS side reads
    // `phase_starts[node]..phase_starts[node+1]` directly.
    //
    // Layout per phase: starts[node_count + 1] (cumulative event count) +
    // data[total_phase_events * 3] (interleaved type, d1, d2).
    //
    // Order within (phase, node) is preserved (matches the original DFS event
    // order, since we walk `cpr.events` in order and use a per-(phase, node)
    // write cursor).

    // Pass 1: count events per (phase, node).
    // Layout: counts[node * 4 + phase] — keeps all 4 phases of one node in
    // a single cache line (16 bytes), turning random-by-node accesses into
    // clustered ones when consecutive events touch the same/nearby nodes.
    const counts = try alloc.alloc(u32, 4 * node_count);
    @memset(counts, 0);
    var phase_totals: [4]u32 = .{ 0, 0, 0, 0 };
    for (0..ev_count) |i| {
        const node_raw = @intFromEnum(cpr.events[i].node);
        if (node_raw >= node_count) continue; // sentinel / out-of-range — ignored by JS too
        const phase: u32 = switch (cpr.events[i].phase) {
            .enter => 0,
            .exit => 1,
            .post => 2,
            .after_enter => 3,
        };
        counts[node_raw * 4 + phase] += 1;
        phase_totals[phase] += 1;
    }

    // Pass 2: allocate starts/data per phase, build prefix sums + seed the
    // scatter cursor into the same `counts` slots in a single fused pass per
    // phase (saves a 4× node_count memcpy versus seeding cursors separately).
    var phase_starts: [4][]u32 = undefined;
    var phase_data: [4][]u32 = undefined;
    for (0..4) |p| {
        phase_starts[p] = try alloc.alloc(u32, node_count + 1);
        phase_data[p] = try alloc.alloc(u32, phase_totals[p] * 3);
        var sum: u32 = 0;
        for (0..node_count) |n| {
            const c = counts[n * 4 + p];
            phase_starts[p][n] = sum;
            counts[n * 4 + p] = sum; // overwrite count with cursor
            sum += c;
        }
        phase_starts[p][node_count] = sum;
    }

    // Pass 3: scatter events. counts[n*4 + p] holds the next write cursor.
    for (0..ev_count) |i| {
        const node_raw = @intFromEnum(cpr.events[i].node);
        if (node_raw >= node_count) continue;
        const phase: u32 = switch (cpr.events[i].phase) {
            .enter => 0,
            .exit => 1,
            .post => 2,
            .after_enter => 3,
        };
        const slot = counts[node_raw * 4 + phase];
        phase_data[phase][slot * 3 + 0] = @intFromEnum(cpr.events[i].type);
        phase_data[phase][slot * 3 + 1] = cpr.events[i].data1;
        phase_data[phase][slot * 3 + 2] = cpr.events[i].data2;
        counts[node_raw * 4 + phase] = slot + 1;
    }

    // Per-node bits: 1 iff the node has any event in any phase.
    const cfg_node_bits = try alloc.alloc(u8, node_count);
    @memset(cfg_node_bits, 0);
    for (0..node_count) |n| {
        if (phase_starts[0][n + 1] > phase_starts[0][n] or
            phase_starts[1][n + 1] > phase_starts[1][n] or
            phase_starts[2][n + 1] > phase_starts[2][n] or
            phase_starts[3][n + 1] > phase_starts[3][n])
        {
            cfg_node_bits[n] = 1;
        }
    }

    // Subtree-cfg bits: 1 iff the subtree rooted at this node contains any
    // cfg-event node. Used by the JS walker as the seed for `subtreeRelevant`
    // pruning; eliminates the per-runPlugins seed-copy loop.
    //
    // Compute by walking up from each cfg-event node via parent_indices and
    // marking each ancestor. Once a node is marked, the walk stops (early-exit
    // on `subtree[p] != 0`), so total work is O(node_count) regardless of
    // tree depth. parent_indices may be empty if the parent pass was skipped;
    // in that case we leave subtree bits == own bits.
    const subtree_cfg_bits = try alloc.alloc(u8, node_count);
    @memcpy(subtree_cfg_bits, cfg_node_bits);
    if (parent_indices.len == node_count) {
        const none32: u32 = std.math.maxInt(u32);
        for (0..node_count) |i| {
            if (cfg_node_bits[i] == 0) continue;
            var p = parent_indices[i];
            while (p != none32 and p < node_count and subtree_cfg_bits[p] == 0) {
                subtree_cfg_bits[p] = 1;
                p = parent_indices[p];
            }
        }
    }

    // ── Write CfgGraphHeader ────────────────────────────────
    // Aligned alloc — `alloc.alloc(u8, ...)` doesn't guarantee struct alignment.
    // NAPI's parse path happens to leave the bump cursor on a 4-byte boundary
    // due to its allocation pattern, masking this latent bug. For embedded
    // hosts with different allocation traces (smaller inputs, fewer prior
    // allocs) the cursor can land on an odd byte and the @alignCast trips.
    const header_mem = try alloc.alignedAlloc(u8, .of(CfgGraphHeader), @sizeOf(CfgGraphHeader));
    const header: *CfgGraphHeader = @ptrCast(@alignCast(header_mem.ptr));
    header.* = .{
        .segment_count = seg_count,
        .codepath_count = cp_count,
        .event_count = ev_count,

        .seg_reachable_offset = ptrOffsetPub(buf, seg_reachable.ptr),
        .seg_codepath_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_codepath.ptr))),

        .seg_next_starts_offset = 0, // reconstructed in JS by inverting prev + loopedPrev
        .seg_next_targets_offset = 0,
        .seg_prev_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_prev_starts.ptr))),
        .seg_prev_targets_offset = if (seg_prev_targets.len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_prev_targets.ptr))) else 0,
        .seg_all_next_starts_offset = 0, // reconstructed in JS
        .seg_all_next_targets_offset = 0,
        .seg_all_prev_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_all_prev_starts.ptr))),
        .seg_all_prev_targets_offset = if (seg_all_prev_targets.len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_all_prev_targets.ptr))) else 0,
        .seg_looped_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_looped_starts.ptr))),
        .seg_looped_targets_offset = if (seg_looped_targets.len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_looped_targets.ptr))) else 0,
        .seg_collapsed_prev_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_collapsed_prev_starts.ptr))),
        .seg_collapsed_prev_targets_offset = if (seg_collapsed_prev_targets.len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(seg_collapsed_prev_targets.ptr))) else 0,

        .cp_origin_offset = ptrOffsetPub(buf, cp_origin.ptr),
        .cp_upper_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_upper.ptr))),
        .cp_initial_seg_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_initial_seg.ptr))),
        .cp_final_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_final_starts.ptr))),
        .cp_final_targets_offset = if (cp_final_targets.len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_final_targets.ptr))) else 0,
        .cp_returned_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_returned_starts.ptr))),
        .cp_returned_targets_offset = if (cp_returned_targets.len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_returned_targets.ptr))) else 0,
        .cp_thrown_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_thrown_starts.ptr))),
        .cp_thrown_targets_offset = if (cp_thrown_targets.len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(cp_thrown_targets.ptr))) else 0,

        .events_offset = 0,

        .cfg_phase_node_count = node_count,
        .cfg_phase_enter_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_starts[0].ptr))),
        .cfg_phase_enter_data_offset = if (phase_data[0].len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_data[0].ptr))) else 0,
        .cfg_phase_exit_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_starts[1].ptr))),
        .cfg_phase_exit_data_offset = if (phase_data[1].len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_data[1].ptr))) else 0,
        .cfg_phase_post_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_starts[2].ptr))),
        .cfg_phase_post_data_offset = if (phase_data[2].len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_data[2].ptr))) else 0,
        .cfg_phase_after_enter_starts_offset = ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_starts[3].ptr))),
        .cfg_phase_after_enter_data_offset = if (phase_data[3].len > 0) ptrOffsetPub(buf, @as([*]u8, @ptrCast(phase_data[3].ptr))) else 0,
        .cfg_node_bits_offset = ptrOffsetPub(buf, cfg_node_bits.ptr),
        .cfg_subtree_bits_offset = ptrOffsetPub(buf, subtree_cfg_bits.ptr),
    };

    return ptrOffsetPub(buf, header_mem.ptr);
}

// ── Bump Allocator ───────────────────────────────────────────────

/// Bump allocator backed by a JS-owned ArrayBuffer.
///
/// Layout: `[Header 64B][bump region →  ...gap...  ← source text]`
///
/// Allocates forward from HEADER_SIZE up to `source_start`.
/// Free and resize on non-last allocations are no-ops (arena semantics).
pub const JsBufferAllocator = struct {
    inner: std.heap.FixedBufferAllocator,
    base: [*]u8,

    pub fn init(buf: [*]u8, source_start: u32) JsBufferAllocator {
        std.debug.assert(source_start >= HEADER_SIZE);
        return .{
            .inner = std.heap.FixedBufferAllocator.init(buf[HEADER_SIZE..source_start]),
            .base = buf,
        };
    }

    /// Sub-region constructor: allocate within a custom byte range of the
    /// shared buffer. Used by the streaming-sem path to give the sem worker
    /// thread its own bump partition disjoint from the parser's, so both
    /// threads can write concurrently without locking. JS reads via offsets
    /// from `buf` so it doesn't matter which sub-bump produced any given
    /// allocation. `start_off` and `end_off` are absolute byte offsets
    /// within `buf`; caller must ensure they don't overlap.
    pub fn initRange(buf: [*]u8, start_off: u32, end_off: u32) JsBufferAllocator {
        std.debug.assert(start_off <= end_off);
        return .{
            .inner = std.heap.FixedBufferAllocator.init(buf[start_off..end_off]),
            .base = buf,
        };
    }

    /// Like `bytesUsed()` but returns the absolute end offset (start of FBA
    /// buffer + end_index), not header-relative. Useful when the bump is a
    /// sub-region — caller wants to know "how far into the JS buffer did
    /// this partition reach". Returns `start + bytes_consumed`.
    pub fn endOffset(self: *const JsBufferAllocator) u32 {
        const buf_start = @intFromPtr(self.inner.buffer.ptr) - @intFromPtr(self.base);
        return @intCast(buf_start + self.inner.end_index);
    }

    pub fn allocator(self: *JsBufferAllocator) std.mem.Allocator {
        return self.inner.allocator();
    }

    /// Total bytes consumed in the buffer (header + bump region).
    pub fn bytesUsed(self: *const JsBufferAllocator) u32 {
        return HEADER_SIZE + @as(u32, @intCast(self.inner.end_index));
    }

    /// Reset the bump allocator for buffer reuse across files.
    pub fn reset(self: *JsBufferAllocator) void {
        self.inner.reset();
    }
};

// ── Header Writer ────────────────────────────────────────────────

pub const HeaderInfo = struct {
    source_start: u32,
    source_len: u32,
    source_utf16_len: u32,
    total_used: u32,
    flags: u32,
    parent_indices_offset: u32 = 0,
    semantic_data_offset: u32 = 0,
    pre_order_offset: u32 = 0,
    post_order_offset: u32 = 0,
    dfs_events_offset: u32 = 0,
    source_type: u32 = 1, // 1 = module, 0 = script
    comment_count: u32 = 0,
    comment_starts_offset: u32 = 0,
    comment_ends_offset: u32 = 0,
    comment_kinds_offset: u32 = 0,
    tok_ends_offset: u32 = 0,
    node_start_pos_offset: u32 = 0,
    node_end_pos_offset: u32 = 0,
    line_starts_offset: u32 = 0,
    line_starts_count: u32 = 0,
    max_tok_offset: u32 = 0,
    min_tok_offset: u32 = 0,
    sorted_by_start_offset: u32 = 0,
    tok_cmt_merge_offset: u32 = 0,
    resolved_parent_offset: u32 = 0,
    type_overrides_offset: u32 = 0,
    parent_kind_offset: u32 = 0,
};

/// Write the buffer header at offset 0 after parsing is complete.
pub fn writeHeader(buf: [*]u8, tree: *const Ast, info: HeaderInfo) void {
    const header: *BufferHeader = @ptrCast(@alignCast(buf));
    const n = tree.nodes.len;
    const t = tree.tokens.len;
    const e = tree.extra_data.len;

    header.* = .{
        .magic = MAGIC,
        .version = VERSION,
        .node_count = @intCast(n),
        .token_count = @intCast(t),
        .extra_count = @intCast(e),
        .source_len = info.source_len,
        .source_utf16_len = info.source_utf16_len,
        .tags_offset = if (n > 0) ptrOffset(buf, tree.nodes.items(.tag).ptr) else 0,
        .main_tokens_offset = if (n > 0) ptrOffset(buf, tree.nodes.items(.main_token).ptr) else 0,
        .data_offset = if (n > 0) ptrOffset(buf, tree.nodes.items(.data).ptr) else 0,
        .extra_data_offset = if (e > 0) ptrOffset(buf, tree.extra_data.ptr) else 0,
        .tok_tags_offset = if (t > 0) ptrOffset(buf, tree.tokens.items(.tag).ptr) else 0,
        .tok_starts_offset = if (t > 0) ptrOffset(buf, tree.tokens.items(.start).ptr) else 0,
        .source_offset = info.source_start,
        .total_used = info.total_used,
        .flags = info.flags,
        .parent_indices_offset = info.parent_indices_offset,
        .semantic_data_offset = info.semantic_data_offset,
        .pre_order_offset = info.pre_order_offset,
        .post_order_offset = info.post_order_offset,
        .dfs_events_offset = info.dfs_events_offset,
        .source_type = info.source_type,
        .comment_count = info.comment_count,
        .comment_starts_offset = info.comment_starts_offset,
        .comment_ends_offset = info.comment_ends_offset,
        .comment_kinds_offset = info.comment_kinds_offset,
        .tok_ends_offset = info.tok_ends_offset,
        .node_start_pos_offset = info.node_start_pos_offset,
        .node_end_pos_offset = info.node_end_pos_offset,
        .line_starts_offset = info.line_starts_offset,
        .line_starts_count = info.line_starts_count,
        .max_tok_offset = info.max_tok_offset,
        .min_tok_offset = info.min_tok_offset,
        .sorted_by_start_offset = info.sorted_by_start_offset,
        .tok_cmt_merge_offset = info.tok_cmt_merge_offset,
        .resolved_parent_offset = info.resolved_parent_offset,
        .type_overrides_offset = info.type_overrides_offset,
        .parent_kind_offset = info.parent_kind_offset,
    };
}

fn ptrOffset(base: [*]const u8, ptr: anytype) u32 {
    return @intCast(@intFromPtr(ptr) - @intFromPtr(base));
}

/// Public wrapper for use by external callers (e.g., napi.zig).
pub fn ptrOffsetPub(base: [*]const u8, ptr: anytype) u32 {
    return ptrOffset(base, ptr);
}

// ── UTF-16 Span Conversion ───────────────────────────────────────

/// Convert token start offsets from UTF-8 byte positions to UTF-16
/// code unit positions, in-place. Token starts must be sorted.
///
/// Returns the total UTF-16 length of the source.
pub fn convertSpansToUtf16(source: []const u8, tok_starts: []u32) u32 {
    // All-ASCII fast path: if the source has no high bytes, byte offsets already
    // equal UTF-16 offsets — no per-token rewrite needed. Single SIMD scan.
    if (isAllAscii(source)) return @intCast(source.len);

    var byte_pos: u32 = 0;
    var utf16_pos: u32 = 0;
    var tok_idx: usize = 0;

    while (tok_idx < tok_starts.len) {
        // Advance source scanner to this token's byte offset.
        const target = tok_starts[tok_idx];
        // SIMD ASCII fast path: bulk-skip 16 bytes at a time until < 16 remain
        // before the target. Pure-ASCII bytes map 1:1 to UTF-16 code units.
        const simd_end = @min(target, @as(u32, @intCast(source.len)));
        while (byte_pos + 16 <= simd_end) {
            const chunk: @Vector(16, u8) = source[byte_pos..][0..16].*;
            if (!@reduce(.And, chunk < @as(@Vector(16, u8), @splat(0x80)))) break;
            utf16_pos += 16;
            byte_pos += 16;
        }
        // Scalar tail: handles final < 16 bytes and any non-ASCII sequences.
        while (byte_pos < target and byte_pos < source.len) {
            utf16_pos += utf16Advance(source, &byte_pos);
        }
        tok_starts[tok_idx] = utf16_pos;
        tok_idx += 1;
    }

    // Scan remaining source to get total UTF-16 length.
    // SIMD bulk: process 16 ASCII bytes at a time; scalar fallback per non-ASCII
    // sequence (rare in JS/TS), then re-enter SIMD.
    while (byte_pos < source.len) {
        if (byte_pos + 16 <= source.len) {
            const chunk: @Vector(16, u8) = source[byte_pos..][0..16].*;
            if (@reduce(.And, chunk < @as(@Vector(16, u8), @splat(0x80)))) {
                utf16_pos += 16;
                byte_pos += 16;
                continue;
            }
        }
        utf16_pos += utf16Advance(source, &byte_pos);
    }

    return utf16_pos;
}

/// Convert multiple sorted byte-offset arrays to UTF-16 in a single source scan.
/// All arrays must be sorted. Avoids re-scanning the source for each array.
/// Returns the total UTF-16 length of the source.
pub fn convertMultiSpansToUtf16(source: []const u8, arrays: []const []u32) u32 {
    // All-ASCII fast path: byte offsets already equal UTF-16 offsets — the
    // arrays need no rewrite and the total length is just source.len.  One
    // SIMD scan decides it.  Typical JS/TS source is pure ASCII.
    if (isAllAscii(source)) return @intCast(source.len);

    // ASCII-run algorithm: use SIMD to find the longest contiguous ASCII run
    // starting at each block, then process all cursors in that run at once.
    //
    // `diff = byte_pos - utf16_pos` grows only at non-ASCII codepoints and
    // stays constant across any ASCII run.  utf16(P) = P - diff for P in the
    // run, so one cursor loop (or a 4-wide SIMD subtract) handles the whole
    // run instead of repeating the loop once per 16-byte block.
    //
    // For real-world JS/TS (e.g. angular-core.mjs: 1.58 MB, 1510 non-ASCII
    // runs), this reduces ASCII cursor-loop setups from ~98 K to ~1.5 K.
    const MAX_ARRAYS = 16;
    std.debug.assert(arrays.len <= MAX_ARRAYS);
    var cursors: [MAX_ARRAYS]usize = @splat(0);
    const n = @min(arrays.len, MAX_ARRAYS);
    const src_len: u32 = @intCast(source.len);

    var byte_pos: u32 = 0;
    var utf16_pos: u32 = 0;

    while (byte_pos + 16 <= src_len) {
        const chunk: @Vector(16, u8) = source[byte_pos..][0..16].*;
        if (@reduce(.And, chunk < @as(@Vector(16, u8), @splat(0x80)))) {
            // Extend the ASCII run as far as possible in 16-byte strides.
            var run_end: u32 = byte_pos + 16;
            while (run_end + 16 <= src_len) {
                const ext: @Vector(16, u8) = source[run_end..][0..16].*;
                if (!@reduce(.And, ext < @as(@Vector(16, u8), @splat(0x80)))) break;
                run_end += 16;
            }
            // source[byte_pos..run_end] is all ASCII; diff is constant here.
            std.debug.assert(byte_pos >= utf16_pos);
            const diff = byte_pos - utf16_pos;
            if (diff == 0) {
                // utf16 == byte: no rewrite, just skip cursors past the run.
                for (0..n) |a| {
                    var c = cursors[a];
                    while (c < arrays[a].len and arrays[a][c] < run_end) c += 1;
                    cursors[a] = c;
                }
            } else {
                // Subtract diff from every position in the run.
                // 4-wide SIMD handles aligned bulk; scalar cleans the tail.
                // Sorted invariant: arr[c+3] < run_end implies arr[c..c+4] all in run.
                const diff_splat: @Vector(4, u32) = @splat(diff);
                for (0..n) |a| {
                    const arr = arrays[a];
                    var c = cursors[a];
                    while (c + 4 <= arr.len and arr[c + 3] < run_end) {
                        const v: @Vector(4, u32) = arr[c..][0..4].*;
                        arr[c..][0..4].* = v - diff_splat;
                        c += 4;
                    }
                    while (c < arr.len and arr[c] < run_end) {
                        arr[c] -= diff;
                        c += 1;
                    }
                    cursors[a] = c;
                }
            }
            utf16_pos = run_end - diff;
            byte_pos = run_end;
        } else {
            // Non-ASCII block: byte-by-byte to track codepoint boundaries.
            const block_end = byte_pos + 16;
            while (byte_pos < block_end and byte_pos < src_len) {
                for (0..n) |a| {
                    while (cursors[a] < arrays[a].len and arrays[a][cursors[a]] == byte_pos) {
                        arrays[a][cursors[a]] = utf16_pos;
                        cursors[a] += 1;
                    }
                }
                utf16_pos += utf16Advance(source, &byte_pos);
            }
        }
    }

    // Tail: remaining bytes after the last full 16-byte block.
    while (byte_pos < src_len) {
        for (0..n) |a| {
            while (cursors[a] < arrays[a].len and arrays[a][cursors[a]] == byte_pos) {
                arrays[a][cursors[a]] = utf16_pos;
                cursors[a] += 1;
            }
        }
        utf16_pos += utf16Advance(source, &byte_pos);
    }

    // Flush any cursors pointing past end-of-source.
    for (0..n) |a| {
        while (cursors[a] < arrays[a].len) {
            arrays[a][cursors[a]] = utf16_pos;
            cursors[a] += 1;
        }
    }

    return utf16_pos;
}

/// Fast SIMD scan: true if every byte in `source` is < 0x80.
/// Used as fast-path gate for UTF-16 conversion (ASCII = byte offsets
/// already correct; skip entire per-token rewrite pass).
fn isAllAscii(source: []const u8) bool {
    var i: usize = 0;
    const V = @Vector(16, u8);
    while (i + 16 <= source.len) : (i += 16) {
        const chunk: V = source[i..][0..16].*;
        if (!@reduce(.And, chunk < @as(V, @splat(0x80)))) return false;
    }
    while (i < source.len) : (i += 1) {
        if (source[i] >= 0x80) return false;
    }
    return true;
}

inline fn utf16Advance(source: []const u8, byte_pos: *u32) u32 {
    const b = source[byte_pos.*];
    if (b < 0x80) {
        byte_pos.* += 1;
        return 1;
    } else if (b < 0xE0) {
        byte_pos.* += 2;
        return 1;
    } else if (b < 0xF0) {
        byte_pos.* += 3;
        return 1;
    } else {
        byte_pos.* += 4;
        return 2; // surrogate pair
    }
}

// ── Node Position Computation ────────────────────────────────────

const ast_mod = @import("ast.zig");
const token_mod = @import("token.zig");

/// Compute node start and end positions (UTF-16) from the parsed AST.
/// Must be called AFTER tok_starts and tok_ends are converted to UTF-16.
///
/// Algorithm mirrors estree-adapter.js _computeAllEndPos + _nodeStartPos:
/// 1. Propagate max/min main_token through parent pointers
/// 2. Bracket matching via token tags
/// 3. Extend each node's end past maxTok to include trailing ; and matched brackets
pub const NodeSpansResult = struct {
    starts: []u32,
    ends: []u32,
    max_tok: []u32,
    min_tok: []u32,
    sorted_by_start: []u32,
};

pub fn buildNodeSpans(
    alloc: std.mem.Allocator,
    node_tags: []const ast_mod.Node.Tag,
    tok_tags: []const token_mod.Tag,
    tok_starts: []const u32,
    tok_ends: []const u32,
    pre_order: []const u32,
    end_toks: []const u32,    // tree.node_end_toks: last consumed token per node
    min_tok_in: []const u32,  // traversal.min_tok: leftmost token per subtree
    node_count: u32,
    source: []const u8,       // source text — used to detect identifier-text modifiers (public/private/protected/accessor) and decorators (@...)
) !NodeSpansResult {
    const n: usize = node_count;

    // Pre-allocate ALL output arrays upfront so the sub-thread does no
    // allocations and can't race against this thread's own allocations.
    const min_tok = try alloc.alloc(u32, n);
    const max_tok = try alloc.alloc(u32, n);
    const node_starts = try alloc.alloc(u32, n);
    const node_ends = try alloc.alloc(u32, n);
    const sorted_by_start = try alloc.alloc(u32, n);

    // Spawn a sub-thread for node_ends + max_tok memcpy.  Both depend only
    // on parse outputs (tok_ends + end_toks); they run in parallel with
    // this thread's min_tok memcpy + node_starts gather + modifier scan
    // + sorted_by_start equal-start-run reverse.  Saves ~1 ms on a 1M-node
    // file by overlapping the two random-gather loops.
    const NodeEndsJob = struct {
        max_tok: []u32,
        end_toks: []const u32,
        node_ends: []u32,
        tok_ends: []const u32,
        n: usize,
        fn run(self: *@This()) void {
            @memcpy(self.max_tok, self.end_toks[0..self.n]);
            for (0..self.n) |i| self.node_ends[i] = self.tok_ends[self.end_toks[i]];
        }
    };
    var node_ends_job: NodeEndsJob = .{
        .max_tok = max_tok,
        .end_toks = end_toks,
        .node_ends = node_ends,
        .tok_ends = tok_ends,
        .n = n,
    };
    const node_ends_thread: ?std.Thread = if (n >= 4096)
        std.Thread.spawn(.{}, NodeEndsJob.run, .{&node_ends_job}) catch null
    else
        null;
    if (node_ends_thread == null) NodeEndsJob.run(&node_ends_job);

    // min_tok: copy from traversal result (already bottom-up propagated there).
    @memcpy(min_tok, min_tok_in[0..n]);

    // node_starts = tok_starts[min_tok[i]]
    for (node_starts, min_tok[0..n]) |*ns, mt| ns.* = tok_starts[mt];

    // Adjust MethodDefinition/PropertyDefinition start to include modifier
    // keywords (get/set/static/async/*) AND TS modifiers (public/private/
    // protected/readonly/abstract/override/declare/accessor) AND decorators
    // (@...) that precede the name and aren't any child's main_token. Rules
    // like @typescript-eslint/member-ordering report `node: member` and expect
    // the range to start at the leftmost modifier (column 3 for indented
    // `public static G()`), not at the method name.
    // JSX element/fragment: `<` is consumed by the caller, not tracked in min_tok.
    for (0..n) |i| {
        switch (node_tags[i]) {
            .method_def, .computed_method_def,
            .getter_def, .computed_getter_def,
            .setter_def, .computed_setter_def,
            .constructor_def,
            .property_def, .computed_property_def,
            => {
                var t = min_tok[i];
                while (t > 0) {
                    const pt = tok_tags[t - 1];
                    var is_modifier = pt == .kw_get or pt == .kw_set or
                        pt == .kw_static or pt == .kw_async or
                        pt == .asterisk or
                        pt == .kw_readonly or pt == .kw_abstract or
                        pt == .kw_override or pt == .kw_declare;
                    // Identifier-text modifiers: public/private/protected/accessor.
                    if (!is_modifier and pt == .identifier) {
                        const ts = tok_starts[t - 1];
                        const te = tok_ends[t - 1];
                        if (te <= source.len) {
                            const txt = source[ts..te];
                            if (std.mem.eql(u8, txt, "public") or
                                std.mem.eql(u8, txt, "private") or
                                std.mem.eql(u8, txt, "protected") or
                                std.mem.eql(u8, txt, "accessor"))
                            {
                                is_modifier = true;
                            }
                        }
                    }
                    if (is_modifier) {
                        t -= 1;
                        continue;
                    }
                    // Decorator: walk back across `r_paren … l_paren` argument list,
                    // then over a dotted identifier chain, then over the `@`.
                    if (pt == .r_paren) {
                        // Find matching `(` by depth-counting.
                        var depth: i32 = 1;
                        var k: i64 = @as(i64, @intCast(t)) - 2;
                        while (k >= 0 and depth > 0) : (k -= 1) {
                            const kt = tok_tags[@intCast(k)];
                            if (kt == .r_paren) depth += 1
                            else if (kt == .l_paren) depth -= 1;
                        }
                        if (depth != 0) break; // unbalanced — give up
                        // k now points one before the matching `(`. Continue walking
                        // back over the dotted identifier chain.
                        var walk: i64 = k;
                        while (walk >= 0) : (walk -= 1) {
                            const wt = tok_tags[@intCast(walk)];
                            if (wt == .identifier or wt == .dot) continue;
                            break;
                        }
                        if (walk < 0 or tok_tags[@intCast(walk)] != .at_sign) break;
                        t = @intCast(walk);
                        continue;
                    }
                    // Decorator with no args: @Name or @ns.Name
                    if (pt == .identifier) {
                        var walk: i64 = @as(i64, @intCast(t)) - 1;
                        while (walk >= 0) : (walk -= 1) {
                            const wt = tok_tags[@intCast(walk)];
                            if (wt == .identifier or wt == .dot) continue;
                            break;
                        }
                        if (walk >= 0 and tok_tags[@intCast(walk)] == .at_sign) {
                            t = @intCast(walk);
                            continue;
                        }
                    }
                    break;
                }
                if (t != min_tok[i]) node_starts[i] = tok_starts[t];
            },
            .jsx_element, .jsx_opening_element, .jsx_self_closing, .jsx_fragment => {
                const mt = min_tok[i];
                if (mt > 0 and tok_tags[mt - 1] == .less_than) {
                    node_starts[i] = tok_starts[mt - 1];
                }
            },
            // `declare module/namespace Foo {}` — the `declare` keyword is
            // consumed by parseStatement before calling parseNamespace/Module,
            // so min_tok points to `module`/`namespace`.  ESTree rules expect
            // the node range to start at `declare`.
            .ts_module_decl, .ts_namespace_decl => {
                const mt = min_tok[i];
                if (mt > 0 and tok_tags[mt - 1] == .kw_declare) {
                    node_starts[i] = tok_starts[mt - 1];
                }
            },
            // TS type annotation `: Type` — ESTree wraps the annotation in a
            // TSTypeAnnotation node whose range starts at `:` (the main_token).
            // min_tok only sees children (the type), so widen left to include `:`.
            .ts_type_annotation => {
                const mt = min_tok[i];
                if (mt > 0 and tok_tags[mt - 1] == .colon) {
                    node_starts[i] = tok_starts[mt - 1];
                }
            },
            // TS inline type modifier: `export { type foo }` / `import { type foo }`.
            // The `type` keyword is consumed before the identifier, so min_tok points to
            // the identifier.  ESTree requires the specifier range to start at `type`.
            .export_specifier, .import_specifier => {
                const mt = min_tok[i];
                if (mt > 0 and tok_tags[mt - 1] == .kw_type) {
                    node_starts[i] = tok_starts[mt - 1];
                }
            },
            else => {},
        }
    }

    // ── Sorted index for getNodeByRangeIndex: no sort required ──
    //
    // pre_order is a DFS traversal in document order, so node_starts
    // indexed through it is already non-decreasing — `for i: starts[pre_order[i]] <= starts[pre_order[i+1]]`.
    // The only deviation from the sort's comparator is same-start ties:
    // pre-order places parent before child (outer first), the comparator
    // wants innermost first.  Parents and their descendants that share a
    // start form a contiguous run in pre-order (siblings have distinct
    // starts as ranges are non-overlapping), so reversing each equal-start
    // run fixes the tie-break in O(n) total — no N log N sort, no
    // per-comparison indirection.
    {
        var p: usize = 0;
        while (p < n) {
            const run_start_key = node_starts[pre_order[p]];
            var q = p + 1;
            while (q < n and node_starts[pre_order[q]] == run_start_key) q += 1;
            // Copy pre_order[p..q] reversed into sorted_by_start[p..q].
            var k: usize = 0;
            while (k < q - p) : (k += 1) {
                sorted_by_start[p + k] = pre_order[q - 1 - k];
            }
            p = q;
        }
    }

    // Join sub-thread before returning (its outputs go in the result).
    if (node_ends_thread) |t| t.join();

    return .{ .starts = node_starts, .ends = node_ends, .max_tok = max_tok, .min_tok = min_tok, .sorted_by_start = sorted_by_start };
}

// ── BOM Handling ─────────────────────────────────────────────────

/// Strip UTF-8 BOM (EF BB BF) from the start of source.
pub fn stripBom(source: []const u8) struct { text: []const u8, has_bom: bool } {
    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
        return .{ .text = source[3..], .has_bom = true };
    }
    return .{ .text = source, .has_bom = false };
}

// ── Tests ────────────────────────────────────────────────────────

test "BufferHeader size is in sync with field count" {
    // Sentinel for ABI changes — bumps when a field is added/removed. Update
    // BOTH this constant AND the buffer `version` field (see top of file) so
    // JS-side readers know to refresh their offset map.
    try std.testing.expectEqual(@as(usize, @sizeOf(BufferHeader)), @sizeOf(BufferHeader));
    // 38 u32 fields × 4 bytes = 152. Verify against an explicit count to
    // catch accidental field-type changes (e.g. u32 → u64 alignment).
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(BufferHeader));
}

test "convertSpansToUtf16 ASCII" {
    var starts = [_]u32{ 0, 5, 10 };
    const utf16_len = convertSpansToUtf16("hello world!", &starts);
    try std.testing.expectEqual(@as(u32, 0), starts[0]);
    try std.testing.expectEqual(@as(u32, 5), starts[1]);
    try std.testing.expectEqual(@as(u32, 10), starts[2]);
    try std.testing.expectEqual(@as(u32, 12), utf16_len);
}

test "convertSpansToUtf16 multibyte" {
    // "café" = 63 61 66 C3 A9 — 5 bytes, 4 UTF-16 code units
    const source = "caf\xc3\xa9";
    var starts = [_]u32{ 0, 3 };
    const utf16_len = convertSpansToUtf16(source, &starts);
    try std.testing.expectEqual(@as(u32, 0), starts[0]);
    try std.testing.expectEqual(@as(u32, 3), starts[1]);
    try std.testing.expectEqual(@as(u32, 4), utf16_len);
}

test "convertSpansToUtf16 surrogate pair" {
    // U+1F600 (😀) = F0 9F 98 80 — 4 bytes, 2 UTF-16 code units
    const source = "a\xf0\x9f\x98\x80b"; // "a😀b" = 6 bytes
    var starts = [_]u32{ 0, 1, 5 };
    const utf16_len = convertSpansToUtf16(source, &starts);
    try std.testing.expectEqual(@as(u32, 0), starts[0]);
    try std.testing.expectEqual(@as(u32, 1), starts[1]);
    try std.testing.expectEqual(@as(u32, 3), starts[2]);
    try std.testing.expectEqual(@as(u32, 4), utf16_len);
}

test "convertSpansToUtf16 empty" {
    var starts = [_]u32{};
    const utf16_len = convertSpansToUtf16("", &starts);
    try std.testing.expectEqual(@as(u32, 0), utf16_len);
}

test "stripBom with BOM" {
    const result = stripBom("\xef\xbb\xbfhello");
    try std.testing.expect(result.has_bom);
    try std.testing.expectEqualStrings("hello", result.text);
}

test "stripBom without BOM" {
    const result = stripBom("hello");
    try std.testing.expect(!result.has_bom);
    try std.testing.expectEqualStrings("hello", result.text);
}
