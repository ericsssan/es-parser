//! Semantic event stream produced by the parser.
//!
//! Rather than walking the full AST in semantic analysis (36k+ nodes on acorn.js,
//! ~30% of which have no scope/binding/reference significance), the parser emits
//! a linear stream of events as it parses.  Semantic analysis then performs a
//! single linear pass over this stream — no per-node tag dispatch, no recursion,
//! no visiting of literal nodes.
//!
//! Event packing: 8 bytes each.  Fits 8 per cache line.
//!   kind:   u8   (4 variants: open/close/declare/reference)
//!   aux:    u8   (BindingKind for declare, ReferenceKind for reference,
//!                 ScopeKind for open, unused for close)
//!   _pad:   u16
//!   node:   u32  (NodeIndex — for declarations: name token's owning node;
//!                 for references: identifier node; for scopes: the node
//!                 that owns the scope, e.g. block_stmt or fn_decl)
//!
//! The consumer resolves names lazily via the node's main_token.
const std = @import("std");

pub const EventKind = enum(u8) {
    scope_open,   // aux = ScopeKind
    scope_close,  // aux unused
    declare,      // aux = BindingKind
    reference,    // aux = ReferenceKind
    /// A statement that terminates the current control-flow path:
    /// return, throw, break, continue.  Used by the event-driven CFG
    /// approximation to compute `node_reachable` for rules like
    /// `no-unreachable`.  aux byte: 0=return, 1=throw, 2=break, 3=continue.
    terminator,
    /// `if` statement entry — the next two `branch_close` events belong
    /// to this if.  aux: 0 = has-alternate, 1 = no-alternate.
    /// node: the if_stmt node.
    branch_open,
    /// End of the consequent branch of a `branch_open`.  After this event
    /// the resolver reverts to the pre-branch alive state to process the
    /// alternate branch (if any).
    branch_else,
    /// End of a branch_open (closes the if entirely).  The alive state
    /// after this event is the OR of the two branches' alive states.
    branch_close,
    /// Loop boundary events.  aux byte: 0=while, 1=do_while, 2=for,
    /// 3=for_in, 4=for_of.  node: the loop statement node.
    loop_open,
    /// End of loop test expression (before body).  For for-stmt this fires
    /// after the test expression; for do-while it fires before the test.
    /// aux/node: same as the paired loop_open.
    loop_test_end,
    /// End of loop body (before back-edge).  aux/node: same as loop_open.
    loop_body_end,
    loop_close,
    /// Try statement events.  aux: 0=no-finalizer, 1=has-finalizer.  node: try_stmt.
    try_open,
    /// End of try body (entering catch, or finally if no catch).
    try_body_end,
    /// Start of catch block.  node: catch_clause.
    try_catch_start,
    /// End of catch block.  node: catch_clause.
    try_catch_end,
    /// Start of finally block.  node: try_stmt (finalizer block).
    try_finally_start,
    try_close,
    /// Switch statement events.  node: switch_stmt.  aux: 0=no-default, 1=has-default.
    switch_open,
    /// Start of a case (or default).  aux: 0=case, 1=default.  node: switch_case.
    switch_case_start,
    /// End of a case body.  node: switch_case.
    switch_case_end,
    switch_close,
    /// Logical expression events (short-circuiting: &&, ||, ??).
    /// aux: 0=logical_and, 1=logical_or, 2=nullish_coalesce.  node: logical expr.
    logical_open,
    /// Boundary between left and right operand of a logical expression.
    logical_right,
    logical_close,
    /// Conditional (ternary ?:) expression events.  node: conditional_expr.
    cond_open,
    /// Fork at condition.exit (fires before consequent is parsed).
    /// node: the condition expression.  Transitions to the true-fork path.
    /// Separating fork from cond_alt ensures outer-fork events precede
    /// any nested-ternary events in the resolver stream, matching DFS order.
    cond_fork,
    /// End of consequent, start of alternate.  node: the consequent expression.
    cond_alt,
    cond_close,
    /// A labeled statement begins.  node: labeled_stmt.  aux: 0=non-loop, 1=loop.
    label_open,
    label_close,
    /// `if (cond) consequent [else alternate]` — CodePath-specific events.
    /// node: if_stmt or if_else_stmt.  aux: 0=no-alternate, 1=has-alternate.
    if_open,
    if_alt,
    if_close,
    /// Cancelled event — no-op in all resolvers.  Used to neutralise
    /// orphan reference events that were speculatively emitted for arrow
    /// function parameters and later superseded by proper declare events.
    nop,
};

pub const Event = packed struct(u64) {
    kind: EventKind,
    aux: u8,
    _pad: u16 = 0,
    node: u32,
};

/// Growable, unmanaged event buffer.  Caller provides the allocator.
pub const EventStream = struct {
    events: std.ArrayList(Event) = .empty,
    /// Streaming publish: when non-null, push() atomically stores the current
    /// event count to this slot every PUBLISH_BATCH events, allowing a
    /// concurrent sem thread to consume events as they are produced. Null
    /// in sequential mode — branch is predicted not-taken with zero overhead.
    publish_to: ?*std.atomic.Value(usize) = null,
    /// Bitmask for publish granularity (batch_size - 1). Must be power-of-2 - 1.
    sem_batch_mask: usize = PUBLISH_BATCH - 1,

    pub const PUBLISH_BATCH: usize = 4096;

    pub fn deinit(self: *EventStream, alloc: std.mem.Allocator) void {
        self.events.deinit(alloc);
    }

    pub inline fn push(self: *EventStream, alloc: std.mem.Allocator, ev: Event) !void {
        // Fast path: pre-ensured capacity — avoid loading the allocator vtable.
        if (self.events.items.len < self.events.capacity) {
            self.events.appendAssumeCapacity(ev);
        } else {
            try self.events.append(alloc, ev);
        }
        if (self.publish_to) |p| {
            const n = self.events.items.len;
            if ((n & self.sem_batch_mask) == 0) {
                p.store(n, .release);
            }
        }
    }

    pub fn ensureCapacity(self: *EventStream, alloc: std.mem.Allocator, n: usize) !void {
        try self.events.ensureTotalCapacity(alloc, n);
    }

    pub inline fn items(self: *const EventStream) []const Event {
        return self.events.items;
    }

    pub inline fn len(self: *const EventStream) usize {
        return self.events.items.len;
    }
};
