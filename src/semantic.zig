const std = @import("std");
const code_path_mod = @import("code_path.zig");
const CodePathBuilder = code_path_mod.CodePathBuilder;
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const TokenTag = @import("token.zig").Tag;
const scope_mod = @import("scope.zig");
const ScopeTree = scope_mod.ScopeTree;
const symbol_mod = @import("symbol.zig");
const SymbolTable = symbol_mod.SymbolTable;
const ref_mod = @import("reference.zig");
const ReferenceTable = ref_mod.ReferenceTable;
const ReferenceId = ref_mod.ReferenceId;
const Diagnostic = @import("diagnostic.zig").Diagnostic;

const event_resolver = @import("event_resolver.zig");
const parent_builder = @import("parent_builder.zig");

// ── Semantic Result ────────────────────────────────────────

/// The result of semantic analysis: populated scope tree, symbol table,
/// reference table, and any diagnostics produced during the walk.
pub const SemanticResult = struct {
    scopes: ScopeTree,
    symbols: SymbolTable,
    references: ReferenceTable,
    diagnostics: []const Diagnostic = &.{},

    /// Per-node reachability: 1 = live, 0 = dead code.
    /// Length = node count of the analyzed AST.
    node_reachable: []u8 = &.{},

    /// Per-loop exit reachability: 1 = loop exit is reachable, 0 = dead.
    /// Only meaningful for loop nodes (while/for/do-while).
    loop_exit_reachable: []u8 = &.{},

    /// Full multi-segment code path graph (built by CodePathBuilder).
    code_path_result: ?CodePathBuilder.Result = null,

    /// Per-node parent indices: parents[i] is the parent node of node i (NONE for root).
    /// Length = node count when populated, &.{} when not computed.
    parent_indices: []const u32 = &.{},

    /// Indirect ref index sorted by symbol — populated by buildRefRanges.
    /// symbols.getRefRange(sym) returns [start, end) into this slice.
    /// Empty when skip_ref_ranges is true.
    ref_by_sym: []const ReferenceId = &.{},

    /// Return an empty SemanticResult with no scopes/symbols/references.
    /// Used when the caller determines that no semantic-phase rules are active,
    /// allowing `analyze` to be skipped entirely.
    pub fn initEmpty(allocator: std.mem.Allocator) SemanticResult {
        return .{
            .scopes = ScopeTree.init(allocator),
            .symbols = SymbolTable.init(allocator),
            .references = ReferenceTable.init(allocator),
            .diagnostics = &.{},
            .node_reachable = &.{},
            .loop_exit_reachable = &.{},
            .code_path_result = null,
            .parent_indices = &.{},
        };
    }

    pub fn deinit(self: *SemanticResult, allocator: std.mem.Allocator) void {
        self.scopes.deinit();
        self.symbols.deinit();
        self.references.deinit();
        allocator.free(self.diagnostics);
        if (self.node_reachable.len > 0) allocator.free(self.node_reachable);
        if (self.loop_exit_reachable.len > 0) allocator.free(self.loop_exit_reachable);
        if (self.code_path_result) |*cpr| cpr.deinit(allocator);
        if (self.parent_indices.len > 0) allocator.free(self.parent_indices);
        if (self.ref_by_sym.len > 0) allocator.free(self.ref_by_sym);
        self.* = undefined;
    }
};

// ── Semantic Analyzer — thin facade over the event-driven resolver ───
//
// The tree walker was removed in favor of an event stream emitted by the
// parser.  All `analyze*` entry points delegate to `event_resolver.resolveFull`
// which consumes the stream and produces the same `SemanticResult` shape.

/// Wraps an allocator so every fresh allocation (and realloc-grown tail) is
/// zero-filled. `SemanticAnalyzer.analyze` requires zero-initialized memory (it
/// reads sentinel-initialized scope/CFG buffers assuming fresh memory is zero —
/// see its doc comment). Wrap a non-zeroing allocator (a GeneralPurposeAllocator,
/// or an ArenaAllocator over c_allocator that returns reused dirty blocks) with
/// this to satisfy the contract. An ArenaAllocator over `std.heap.page_allocator`
/// already returns zeroed OS pages and needs no wrapper — that is what the
/// production / conformance runners use.
pub const ZeroingAllocator = struct {
    base: std.mem.Allocator,

    pub fn init(base: std.mem.Allocator) ZeroingAllocator {
        return .{ .base = base };
    }

    const vtable = std.mem.Allocator.VTable{ .alloc = zaAlloc, .resize = zaResize, .remap = zaRemap, .free = zaFree };

    pub fn allocator(self: *ZeroingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn zaAlloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ZeroingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.base.vtable.alloc(self.base.ptr, len, a, ra) orelse return null;
        @memset(p[0..len], 0);
        return p;
    }
    fn zaResize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) bool {
        const self: *ZeroingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.base.vtable.resize(self.base.ptr, m, a, nl, ra);
        if (ok and nl > m.len) @memset(m.ptr[m.len..nl], 0);
        return ok;
    }
    fn zaRemap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
        const self: *ZeroingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.base.vtable.remap(self.base.ptr, m, a, nl, ra) orelse return null;
        if (nl > m.len) @memset(p[m.len..nl], 0);
        return p;
    }
    fn zaFree(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *ZeroingAllocator = @ptrCast(@alignCast(ctx));
        self.base.vtable.free(self.base.ptr, m, a, ra);
    }
};

// NOTE: a runtime "is this allocator zeroing?" probe is NOT feasible — in
// Debug/ReleaseSafe the allocator interface fills freshly-allocated memory with
// the 0xAA undefined-poison regardless of the underlying allocator (so a probe
// always sees non-zero, even for a compliant page_allocator), and ReleaseFast
// has no safety hook to run a probe in. The contract is therefore enforced by
// construction: callers that lack a zeroing allocator wrap with ZeroingAllocator
// (effective in ReleaseFast, where the bug lives); the conformance/production
// runners already use ArenaAllocator over page_allocator.

pub const SemanticAnalyzer = struct {
    pub const Options = struct {
        is_module: bool = true,
        globals: []const u8 = &.{},
        /// Compute per-node parent indices.  Set when any active rule needs
        /// `ctx.parentOf()` (e.g. rules inspecting `node.parent.type`).
        build_parents: bool = false,
        /// Build the per-symbol ref-range index (counting sort over all refs).
        /// Skip when no active rule calls symbols.getRefRange().
        build_ref_ranges: bool = true,
        /// Build the control-flow graph + reachability (code paths). Defaults
        /// on to preserve behavior; set false when no active rule needs flow
        /// analysis — the CFG build is ~half of analyze, so skipping it is the
        /// largest single saving in the pipeline. With it off, node_reachable /
        /// loop_exit_reachable are empty (consumers bounds-check → all-alive)
        /// and code_path_result is null.
        need_cfg: bool = true,
    };

    /// Analyze an AST that was parsed with scope-event emission enabled.
    /// Module mode (strict, import/export allowed).
    ///
    /// ALLOCATOR CONTRACT: `allocator` must zero-initialize fresh allocations.
    /// The binder/CFG read sentinel-initialized scope and control-flow buffers
    /// (a 0 means "none"/"unset") and rely on freshly-allocated memory being
    /// zero. A non-zeroing allocator — a raw `GeneralPurposeAllocator`, or an
    /// `ArenaAllocator` over `c_allocator` (which hands back reused dirty blocks)
    /// — yields undefined behavior / crashes in ReleaseFast on some inputs.
    /// Pass an `ArenaAllocator` over `std.heap.page_allocator` (zeroed OS pages —
    /// what the production/conformance runners use) or wrap with
    /// `ZeroingAllocator`. (A runtime probe can't enforce this: Debug/ReleaseSafe
    /// poison-fill all fresh memory with 0xAA, and ReleaseFast has no safety hook.)
    pub fn analyze(allocator: std.mem.Allocator, ast: *const Ast) !SemanticResult {
        return analyzeWithOptions(allocator, ast, .{ .is_module = true });
    }

    /// Analyze with explicit module/script mode.
    pub fn analyzeModule(allocator: std.mem.Allocator, ast: *const Ast, is_module: bool) !SemanticResult {
        return analyzeWithOptions(allocator, ast, .{ .is_module = is_module });
    }

    /// Analyze with JS builtin globals pre-declared in the global scope.
    /// `globals` is a null-separated list of global names.
    pub fn analyzeWithGlobals(allocator: std.mem.Allocator, ast: *const Ast, globals: []const u8) !SemanticResult {
        return analyzeWithOptions(allocator, ast, .{ .is_module = true, .globals = globals });
    }

    /// Returned when `analyze*` is called on an AST that was parsed without
    /// scope-event emission. Semantic analysis is driven entirely by the
    /// parser's event stream, so an empty stream would otherwise yield a
    /// structurally-valid but empty result (no scopes/symbols/references) with
    /// no indication anything went wrong. Parse with `Parser.parse` (events on
    /// by default) or `parseWithOptions(.. .{ .emit_events = true })`.
    pub const Error = error{MissingScopeEvents};

    pub fn analyzeWithOptions(allocator: std.mem.Allocator, ast: *const Ast, opts: Options) !SemanticResult {
        // A parse with emission enabled always emits at least the program
        // scope_open (even for empty source), so an empty stream unambiguously
        // means events were never emitted — fail loudly instead of silently
        // returning an empty result.
        if (ast.scope_events.len == 0) return Error.MissingScopeEvents;
        const ropts = event_resolver.Options{
            .skip_ref_ranges = !opts.build_ref_ranges,
            .globals = opts.globals,
        };
        var result = if (opts.need_cfg)
            try event_resolver.resolveFull(allocator, ast, ast.scope_events, ropts)
        else blk: {
            // Lazy CFG: skip the control-flow graph + reachability build (~half
            // of analyze). Run the scope/symbol/reference walk only and present
            // it as a SemanticResult with empty reachability (all-alive) and no
            // code paths. Callers must only set need_cfg=false when no active
            // rule needs flow analysis.
            const sp = try event_resolver.resolveFullScope(allocator, ast, ast.scope_events, ropts);
            // ref_event_to_id is only used to stitch CFG seg ids; unused here.
            if (sp.ref_event_to_id.len != 0) allocator.free(sp.ref_event_to_id);
            break :blk SemanticResult{
                .scopes = sp.scopes,
                .symbols = sp.symbols,
                .references = sp.references,
                .ref_by_sym = sp.ref_by_sym,
                .diagnostics = &.{},
                .node_reachable = &.{},
                .loop_exit_reachable = &.{},
                .code_path_result = null,
            };
        };
        if (opts.build_parents) {
            if (ast.parents.len > 0) {
                result.parent_indices = try allocator.dupe(u32, ast.parents);
            } else {
                result.parent_indices = try parent_builder.buildParentsOnly(ast, allocator);
            }
        }
        // Loop-exit reachability is derived from the CFG; only meaningful when
        // it was built.
        if (opts.need_cfg) computeLoopBodyExitability(ast, result.loop_exit_reachable, result.node_reachable);
        return result;
    }
};

// ── Loop body exitability analysis ───────────────────────────────────
//
// Determines which loops have a body that always exits on the first iteration
// (via break/return/throw on every path). Sets loop_exit_reachable[i] = 0 for
// such loops, allowing the no-unreachable-loop rule to report them.

pub fn computeLoopBodyExitabilityPub(ast: *const Ast, loop_exit_reachable: []u8, node_reachable: []u8) void {
    return computeLoopBodyExitability(ast, loop_exit_reachable, node_reachable);
}

fn computeLoopBodyExitability(ast: *const Ast, loop_exit_reachable: []u8, node_reachable: []u8) void {
    const tags = ast.nodes.items(.tag);
    const datas = ast.nodes.items(.data);
    const n = ast.nodes.len;



    // Propagate unreachability within statement lists after:
    //   - direct terminators: return, throw, break, continue
    //   - infinite empty loops: while(true);  (no break possible)
    // This ensures no-unreachable fires on statement nodes, not just on the
    // identifier/reference sub-nodes that the event resolver marks via cfg_alive.
    {
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            if (j < node_reachable.len and node_reachable[j] == 0) continue;
            const data_j = datas[j];
            // root and block_stmt both store lhs=SubRange.start, rhs=SubRange.end directly.
            const stmts: []const u32 = switch (tags[j]) {
                .block_stmt, .root => blk: {
                    const start = @intFromEnum(data_j.lhs);
                    const end = @intFromEnum(data_j.rhs);
                    if (start > end or end > ast.extra_data.len) break :blk &.{};
                    break :blk ast.extra_data[start..end];
                },
                else => continue,
            };
            var dead = false;
            for (stmts) |s_raw| {
                if (s_raw >= n) continue;
                if (dead and s_raw < node_reachable.len) node_reachable[s_raw] = 0;
                if (!dead) {
                    const stag = tags[s_raw];
                    if (stag == .return_stmt or stag == .throw_stmt or
                        stag == .break_stmt or stag == .continue_stmt or
                        isInfiniteEmptyLoop(ast, tags, datas, @enumFromInt(s_raw)))
                        dead = true;
                }
            }
        }
    }

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // Skip unreachable loop nodes (e.g., after return or infinite loop).
        // ESLint's rule only fires on reachable code.
        if (i < node_reachable.len and node_reachable[i] == 0) continue;
        const data = datas[i];
        const body: NodeIndex = switch (tags[i]) {
            .while_stmt => data.rhs,
            .do_while_stmt => data.lhs,
            .for_stmt => data.rhs,
            .for_in_stmt, .for_of_stmt, .for_await_of_stmt => blk: {
                const fdata = ast.extraData(ast_mod.ForInOfData, @intFromEnum(data.lhs));
                break :blk fdata.body;
            },
            else => continue,
        };
        if (body == .none) continue;
        if (bodyAlwaysExits(ast, tags, datas, body, false, 0)) {
            loop_exit_reachable[i] = 0;
        }
    }
}

/// Returns true if `body` contains no statements (`.none`, empty_stmt, or empty block).
fn emptyBody(
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    body: NodeIndex,
) bool {
    if (body == .none) return true;
    const ni = @intFromEnum(body);
    if (ni >= tags.len) return false;
    return switch (tags[ni]) {
        .empty_stmt => true,
        .block_stmt => blk: {
            const start = @intFromEnum(datas[ni].lhs);
            const end = @intFromEnum(datas[ni].rhs);
            break :blk start >= end;
        },
        else => false,
    };
}

/// Returns true if `node` is a loop that runs forever and has an empty body —
/// i.e., no path through the body can break/return/throw, and the condition is
/// always-true (literal `true`) or absent (`for(;;)`).
/// Such loops make all subsequent siblings in their block unreachable.
fn isInfiniteEmptyLoop(
    ast: *const Ast,
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    node: NodeIndex,
) bool {
    const ni = @intFromEnum(node);
    if (ni >= tags.len) return false;
    const tag = tags[ni];
    const data = datas[ni];
    switch (tag) {
        .while_stmt => {
            const cond = data.lhs;
            if (cond == .none) return false;
            const ci = @intFromEnum(cond);
            if (ci >= tags.len) return false;
            if (tags[ci] != .boolean_literal) return false;
            if (!std.mem.eql(u8, ast.nodeName(cond), "true")) return false;
            return emptyBody(tags, datas, data.rhs);
        },
        .do_while_stmt => {
            const cond = data.rhs;
            if (cond == .none) return false;
            const ci = @intFromEnum(cond);
            if (ci >= tags.len) return false;
            if (tags[ci] != .boolean_literal) return false;
            if (!std.mem.eql(u8, ast.nodeName(cond), "true")) return false;
            return emptyBody(tags, datas, data.lhs);
        },
        .for_stmt => {
            const extra_idx = @intFromEnum(data.lhs);
            if (extra_idx >= ast.extra_data.len) return false;
            const fdata = ast.extraData(ast_mod.ForData, extra_idx);
            if (fdata.condition != .none) return false;
            return emptyBody(tags, datas, data.rhs);
        },
        else => return false,
    }
}

/// Returns true if no path through `node` has a `break`/`break_label` that could
/// escape the immediately enclosing infinite loop.  `return` and `throw` are NOT
/// counted as break-escapes: they propagate upward but don't create a normal loop
/// exit path.  Nested loops absorb their own unlabeled breaks.
fn bodyHasNoBreakEscape(
    ast: *const Ast,
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    node: NodeIndex,
    in_switch: bool,
    depth: u32,
) bool {
    if (depth > 48) return true;
    if (node == .none) return true;
    const ni = @intFromEnum(node);
    if (ni >= tags.len) return true;
    const tag = tags[ni];
    const data = datas[ni];
    const d = depth + 1;
    return switch (tag) {
        // return/throw propagate upward — don't create a normal loop exit.
        .return_stmt, .throw_stmt => true,
        // break outside a switch exits the infinite loop (creates normal exit path).
        // break inside a switch exits only the switch — absorbed, doesn't escape the infinite loop.
        .break_stmt => in_switch,
        // break_label always escapes some enclosing loop (conservatively, the infinite one).
        .break_label => false,
        .block_stmt => blk: {
            const start = @intFromEnum(data.lhs);
            const end = @intFromEnum(data.rhs);
            if (start > end or end > ast.extra_data.len) break :blk true;
            for (ast.extra_data[start..end]) |s_raw| {
                if (s_raw >= tags.len) continue;
                if (!bodyHasNoBreakEscape(ast, tags, datas, @enumFromInt(s_raw), in_switch, d)) break :blk false;
            }
            break :blk true;
        },
        .if_stmt => bodyHasNoBreakEscape(ast, tags, datas, data.rhs, in_switch, d),
        .if_else_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk true;
            const ifdata = ast.extraData(ast_mod.IfData, extra_idx);
            break :blk bodyHasNoBreakEscape(ast, tags, datas, ifdata.consequent, in_switch, d) and
                bodyHasNoBreakEscape(ast, tags, datas, ifdata.alternate, in_switch, d);
        },
        // Nested loops absorb their own unlabeled breaks — don't recurse into them.
        .while_stmt, .do_while_stmt, .for_stmt,
        .for_in_stmt, .for_of_stmt, .for_await_of_stmt => true,
        // Switch absorbs unlabeled breaks.
        .switch_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk true;
            const range = ast.extraData(ast_mod.SubRange, extra_idx);
            if (range.start > range.end or range.end > ast.extra_data.len) break :blk true;
            for (ast.extraSlice(range)) |c_raw| {
                if (c_raw >= datas.len) continue;
                const c_data = datas[c_raw];
                const c_extra_idx = @intFromEnum(c_data.rhs);
                if (c_extra_idx >= ast.extra_data.len) continue;
                const c_range = ast.extraData(ast_mod.SubRange, c_extra_idx);
                if (c_range.start > c_range.end or c_range.end > ast.extra_data.len) continue;
                for (ast.extraSlice(c_range)) |s_raw| {
                    if (s_raw >= tags.len) continue;
                    if (!bodyHasNoBreakEscape(ast, tags, datas, @enumFromInt(s_raw), true, d)) break :blk false;
                }
            }
            break :blk true;
        },
        .labeled_stmt => bodyHasNoBreakEscape(ast, tags, datas, data.lhs, in_switch, d),
        else => true,
    };
}

/// Returns true if `node` always exits (break/return/throw) on all paths.
/// `in_switch`: true when inside a switch case body — break exits the switch, not the outer loop.
/// `depth`: recursion depth limit to prevent stack overflow on deeply nested ASTs.
fn bodyAlwaysExits(
    ast: *const Ast,
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    node: NodeIndex,
    in_switch: bool,
    depth: u32,
) bool {
    if (depth > 48) return false;
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (ni >= tags.len) return false;
    const tag = tags[ni];
    const data = datas[ni];
    const d = depth + 1;
    return switch (tag) {
        // Unconditional exits
        .return_stmt, .throw_stmt => true,
        // break/break-label: exits the loop unless we're inside a switch
        .break_stmt, .break_label => !in_switch,
        // Block: exits if any statement in the block always exits.
        // If a statement always terminates (break/continue/return/throw on all paths)
        // but doesn't exit the loop, subsequent statements are unreachable — stop there.
        // Note: block_stmt stores lhs=SubRange.start, rhs=SubRange.end directly
        // (unlike switch_case/switch_stmt which use addExtra to store a SubRange struct).
        .block_stmt => blk: {
            const start = @intFromEnum(data.lhs);
            const end = @intFromEnum(data.rhs);
            if (start > end or end > ast.extra_data.len) break :blk false;
            for (ast.extra_data[start..end]) |s_raw| {
                if (s_raw >= tags.len) continue;
                // If any path through this statement can continue the loop, the block
                // doesn't always exit. Check before bodyAlwaysExits to avoid FP from
                // code after an if-with-continue (e.g. `if (x) { continue; } return;`).
                if (stmtCanContinueLoop(ast, tags, datas, @enumFromInt(s_raw), d)) break :blk false;
                if (bodyAlwaysExits(ast, tags, datas, @enumFromInt(s_raw), in_switch, d)) break :blk true;
                if (bodyAlwaysTerminates(ast, tags, datas, @enumFromInt(s_raw), d)) break :blk false;
            }
            break :blk false;
        },
        // if without else: might skip the body entirely
        .if_stmt => false,
        // if-else: both branches must exit
        .if_else_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const ifdata = ast.extraData(ast_mod.IfData, extra_idx);
            break :blk bodyAlwaysExits(ast, tags, datas, ifdata.consequent, in_switch, d) and
                bodyAlwaysExits(ast, tags, datas, ifdata.alternate, in_switch, d);
        },
        // switch: must have default, and all paths through cases must exit via return/throw
        .switch_stmt => switchBodyAlwaysExits(ast, tags, datas, data, in_switch, d),
        // try-catch: both the try block and catch block must exit
        .try_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const try_data = ast.extraData(ast_mod.TryData, extra_idx);
            if (!bodyAlwaysExits(ast, tags, datas, data.lhs, in_switch, d)) break :blk false;
            if (try_data.catch_node == .none) break :blk true;
            const cn = @intFromEnum(try_data.catch_node);
            if (cn >= datas.len) break :blk false;
            const catch_body = datas[cn].rhs;
            break :blk bodyAlwaysExits(ast, tags, datas, catch_body, in_switch, d);
        },
        // labeled statement: recurse into the inner statement
        .labeled_stmt => bodyAlwaysExits(ast, tags, datas, data.lhs, in_switch, d),
        // An infinite loop (while(true) / for(;;)) with no accessible break/return/throw
        // traps execution — the outer loop body never falls through to the loop-back.
        .while_stmt => blk: {
            const cond = data.lhs;
            if (cond == .none) break :blk false;
            const ci = @intFromEnum(cond);
            if (ci >= tags.len) break :blk false;
            if (tags[ci] != .boolean_literal) break :blk false;
            if (!std.mem.eql(u8, ast.nodeName(cond), "true")) break :blk false;
            break :blk bodyHasNoBreakEscape(ast, tags, datas, data.rhs, false, d);
        },
        .do_while_stmt => blk: {
            const cond = data.rhs;
            if (cond == .none) break :blk false;
            const ci = @intFromEnum(cond);
            if (ci >= tags.len) break :blk false;
            if (tags[ci] != .boolean_literal) break :blk false;
            if (!std.mem.eql(u8, ast.nodeName(cond), "true")) break :blk false;
            break :blk bodyHasNoBreakEscape(ast, tags, datas, data.lhs, false, d);
        },
        .for_stmt => blk: {
            const extra_idx = @intFromEnum(data.lhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const fdata = ast.extraData(ast_mod.ForData, extra_idx);
            if (fdata.condition != .none) break :blk false;
            break :blk bodyHasNoBreakEscape(ast, tags, datas, data.rhs, false, d);
        },
        else => false,
    };
}

/// Check if a switch statement always exits the outer loop.
/// Uses a backward walk over cases to handle fall-through.
fn switchBodyAlwaysExits(
    ast: *const Ast,
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    data: ast_mod.Node.Data,
    in_switch: bool,
    depth: u32,
) bool {
    const extra_idx = @intFromEnum(data.rhs);
    if (extra_idx >= ast.extra_data.len) return false;
    const range = ast.extraData(ast_mod.SubRange, extra_idx);
    if (range.start > range.end or range.end > ast.extra_data.len) return false;
    const cases = ast.extraSlice(range);
    if (cases.len == 0) return false;

    // Switch must have a default case — otherwise execution might skip all cases.
    var has_default = false;
    for (cases) |c_raw| {
        const c_idx = c_raw;
        if (c_idx >= tags.len) continue;
        if (tags[c_idx] == .switch_default) {
            has_default = true;
            break;
        }
    }
    if (!has_default) return false;

    // Backward walk: `suffix_exits` = does the suffix from the next case always exit?
    var suffix_exits = false;
    var i: usize = cases.len;
    while (i > 0) {
        i -= 1;
        const c_raw = cases[i];
        if (c_raw >= datas.len) return false;
        const c: NodeIndex = @enumFromInt(c_raw);
        const c_data = datas[c_raw];
        const c_extra_idx = @intFromEnum(c_data.rhs);
        if (c_extra_idx >= ast.extra_data.len) return false;
        const c_range = ast.extraData(ast_mod.SubRange, c_extra_idx);
        if (c_range.start > c_range.end or c_range.end > ast.extra_data.len) return false;
        const c_stmts = ast.extraSlice(c_range);
        _ = c; // c used below via c_raw

        // Does this case's body exit the outer loop (return/throw)?
        // Call with in_switch=true so break_stmt returns false (exits switch, not loop).
        var body_exits_loop = false;
        for (c_stmts) |s_raw| {
            if (bodyAlwaysExits(ast, tags, datas, @enumFromInt(s_raw), true, depth)) {
                body_exits_loop = true;
                break;
            }
        }

        if (body_exits_loop) {
            suffix_exits = true;
            continue;
        }

        // Does this case have a top-level switch-exit that doesn't exit the loop?
        // break: exits switch, loop continues.
        // continue/continue_label: continues the outer loop (doesn't fall through and doesn't exit loop).
        var has_non_exit_case_terminator = false;
        for (c_stmts) |s_raw| {
            if (s_raw >= tags.len) continue;
            const s_tag = tags[s_raw];
            if (s_tag == .break_stmt or s_tag == .break_label or
                s_tag == .continue_stmt or s_tag == .continue_label)
            {
                has_non_exit_case_terminator = true;
                break;
            }
        }

        if (has_non_exit_case_terminator) {
            // Case exits via break (switch continues, loop continues) or continue (loop continues).
            // Either way, the outer loop can iterate again.
            return false;
        }

        // Case falls through to the next case — inherits suffix.
        if (!suffix_exits) return false;
        // suffix_exits stays true: this case also exits via fall-through.
    }

    _ = in_switch; // not needed — switch cases are always in_switch=true internally
    return suffix_exits;
}

/// Returns true if any execution path through `node` can reach `continue`
/// (iterating the immediately enclosing loop). Does NOT recurse into nested
/// loops — their `continue` targets the inner loop, not the outer one.
fn stmtCanContinueLoop(
    ast: *const Ast,
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    node: NodeIndex,
    depth: u32,
) bool {
    if (depth > 48) return false;
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (ni >= tags.len) return false;
    const tag = tags[ni];
    const data = datas[ni];
    const d = depth + 1;
    return switch (tag) {
        .continue_stmt => true,
        // Hard exits and labeled continues don't iterate the immediately enclosing loop.
        .return_stmt, .throw_stmt, .break_stmt, .break_label, .continue_label => false,
        // Nested loops absorb their own continues.
        .while_stmt, .do_while_stmt, .for_stmt,
        .for_in_stmt, .for_of_stmt, .for_await_of_stmt => false,
        .block_stmt => blk: {
            const start = @intFromEnum(data.lhs);
            const end = @intFromEnum(data.rhs);
            if (start > end or end > ast.extra_data.len) break :blk false;
            for (ast.extra_data[start..end]) |s_raw| {
                if (s_raw >= tags.len) continue;
                if (stmtCanContinueLoop(ast, tags, datas, @enumFromInt(s_raw), d)) break :blk true;
            }
            break :blk false;
        },
        .if_stmt => stmtCanContinueLoop(ast, tags, datas, data.rhs, d),
        .if_else_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const ifdata = ast.extraData(ast_mod.IfData, extra_idx);
            break :blk stmtCanContinueLoop(ast, tags, datas, ifdata.consequent, d) or
                stmtCanContinueLoop(ast, tags, datas, ifdata.alternate, d);
        },
        .switch_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const range = ast.extraData(ast_mod.SubRange, extra_idx);
            if (range.start > range.end or range.end > ast.extra_data.len) break :blk false;
            for (ast.extraSlice(range)) |c_raw| {
                if (c_raw >= datas.len) continue;
                const c_data = datas[c_raw];
                const c_extra_idx = @intFromEnum(c_data.rhs);
                if (c_extra_idx >= ast.extra_data.len) continue;
                const c_range = ast.extraData(ast_mod.SubRange, c_extra_idx);
                if (c_range.start > c_range.end or c_range.end > ast.extra_data.len) continue;
                for (ast.extraSlice(c_range)) |s_raw| {
                    if (s_raw >= tags.len) continue;
                    if (stmtCanContinueLoop(ast, tags, datas, @enumFromInt(s_raw), d)) break :blk true;
                }
            }
            break :blk false;
        },
        .try_stmt => blk: {
            if (stmtCanContinueLoop(ast, tags, datas, data.lhs, d)) break :blk true;
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const try_data = ast.extraData(ast_mod.TryData, extra_idx);
            if (try_data.catch_node == .none) break :blk false;
            const cn = @intFromEnum(try_data.catch_node);
            if (cn >= datas.len) break :blk false;
            const catch_body = datas[cn].rhs;
            break :blk stmtCanContinueLoop(ast, tags, datas, catch_body, d);
        },
        .labeled_stmt => stmtCanContinueLoop(ast, tags, datas, data.lhs, d),
        else => false,
    };
}

/// Returns true if `node` always terminates on all paths via any exit:
/// break, continue, return, or throw. Unlike bodyAlwaysExits, this does NOT
/// require the terminator to exit the outer loop — it only checks that all
/// paths reach some terminator. Used to detect unreachable code after a
/// compound statement whose branches all terminate (some via continue).
fn bodyAlwaysTerminates(
    ast: *const Ast,
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    node: NodeIndex,
    depth: u32,
) bool {
    if (depth > 48) return false;
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (ni >= tags.len) return false;
    const tag = tags[ni];
    const data = datas[ni];
    const d = depth + 1;
    return switch (tag) {
        .return_stmt, .throw_stmt, .break_stmt, .break_label, .continue_stmt, .continue_label => true,
        .block_stmt => blk: {
            const start = @intFromEnum(data.lhs);
            const end = @intFromEnum(data.rhs);
            if (start > end or end > ast.extra_data.len) break :blk false;
            for (ast.extra_data[start..end]) |s_raw| {
                if (s_raw >= tags.len) continue;
                if (bodyAlwaysTerminates(ast, tags, datas, @enumFromInt(s_raw), d)) break :blk true;
            }
            break :blk false;
        },
        .if_stmt => false,
        .if_else_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const ifdata = ast.extraData(ast_mod.IfData, extra_idx);
            break :blk bodyAlwaysTerminates(ast, tags, datas, ifdata.consequent, d) and
                bodyAlwaysTerminates(ast, tags, datas, ifdata.alternate, d);
        },
        .switch_stmt => switchBodyAlwaysTerminates(ast, tags, datas, data, d),
        .try_stmt => blk: {
            const extra_idx = @intFromEnum(data.rhs);
            if (extra_idx >= ast.extra_data.len) break :blk false;
            const try_data = ast.extraData(ast_mod.TryData, extra_idx);
            if (!bodyAlwaysTerminates(ast, tags, datas, data.lhs, d)) break :blk false;
            if (try_data.catch_node == .none) break :blk true;
            const cn = @intFromEnum(try_data.catch_node);
            if (cn >= datas.len) break :blk false;
            const catch_body = datas[cn].rhs;
            break :blk bodyAlwaysTerminates(ast, tags, datas, catch_body, d);
        },
        .labeled_stmt => bodyAlwaysTerminates(ast, tags, datas, data.lhs, d),
        else => false,
    };
}

/// Check if a switch statement terminates all paths (via any break/continue/return/throw).
/// Simpler than switchBodyAlwaysExits: does not distinguish loop-exit from switch-exit.
fn switchBodyAlwaysTerminates(
    ast: *const Ast,
    tags: []const ast_mod.Node.Tag,
    datas: []const ast_mod.Node.Data,
    data: ast_mod.Node.Data,
    depth: u32,
) bool {
    const extra_idx = @intFromEnum(data.rhs);
    if (extra_idx >= ast.extra_data.len) return false;
    const range = ast.extraData(ast_mod.SubRange, extra_idx);
    if (range.start > range.end or range.end > ast.extra_data.len) return false;
    const cases = ast.extraSlice(range);
    if (cases.len == 0) return false;

    var has_default = false;
    for (cases) |c_raw| {
        if (c_raw >= tags.len) continue;
        if (tags[c_raw] == .switch_default) {
            has_default = true;
            break;
        }
    }
    if (!has_default) return false;

    var suffix_terminates = false;
    var i: usize = cases.len;
    while (i > 0) {
        i -= 1;
        const c_raw = cases[i];
        if (c_raw >= datas.len) return false;
        const c_data = datas[c_raw];
        const c_extra_idx = @intFromEnum(c_data.rhs);
        if (c_extra_idx >= ast.extra_data.len) return false;
        const c_range = ast.extraData(ast_mod.SubRange, c_extra_idx);
        if (c_range.start > c_range.end or c_range.end > ast.extra_data.len) return false;
        const c_stmts = ast.extraSlice(c_range);

        var body_terminates = false;
        for (c_stmts) |s_raw| {
            if (bodyAlwaysTerminates(ast, tags, datas, @enumFromInt(s_raw), depth)) {
                body_terminates = true;
                break;
            }
        }

        if (body_terminates) {
            suffix_terminates = true;
            continue;
        }

        // Case falls through — inherits suffix.
        if (!suffix_terminates) return false;
    }

    return suffix_terminates;
}
