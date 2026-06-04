const std = @import("std");
const ast = @import("ast.zig");
const meta_compat = @import("meta_compat.zig");
const Ast = ast.Ast;
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const ExtraIndex = ast.ExtraIndex;
const SubRange = ast.SubRange;
const TokenIndex = ast.TokenIndex;
const Token = @import("token.zig");
const TokenTag = Token.Tag;
const Span = @import("span.zig").Span;
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Severity = @import("diagnostic.zig").Severity;

const TokenList = Ast.TokenList;
const scalar_lexer = @import("scalar_lexer.zig");

/// Fused-lexing token source: the parser pulls tokens from `cursor` into the
/// growable `buf` on demand instead of consuming a pre-materialized array.
const scope_events_mod = @import("scope_events.zig");
const ScopeEventStream = scope_events_mod.EventStream;
const ScopeEvent = scope_events_mod.Event;
const ScopeEventKind = scope_events_mod.EventKind;
// Scope/binding kinds used for the event stream — mirror the semantic tables.
const ScopeKindU8 = @import("scope.zig").ScopeKind;
const BindingKindU8 = @import("symbol.zig").BindingKind;
const ReferenceKindU8 = @import("reference.zig").ReferenceKind;

/// Always-reserved words (cannot appear as IdentifierReference even via escape).
pub fn isAlwaysReservedStr(text: []const u8) bool {
    const list = [_][]const u8{
        "null", "true", "false", "if", "else", "for", "while", "do",
        "function", "return", "break", "continue", "switch", "case",
        "default", "try", "catch", "finally", "throw", "new", "delete",
        "typeof", "void", "instanceof", "in", "var", "const", "class",
        "extends", "super", "this", "import", "export", "debugger", "with",
        "enum",
    };
    inline for (list) |kw| {
        if (std.mem.eql(u8, text, kw)) return true;
    }
    return false;
}

/// Resolve \uXXXX and \u{XXXX} escapes in identifier text.
/// Returns the resolved string as a slice of `buf`, or null if invalid.
pub fn resolveUnicodeEscapesParser(text: []const u8, buf: *[256]u8) ?[]const u8 {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == 'u') {
            i += 2;
            var codepoint: u32 = 0;
            if (i < text.len and text[i] == '{') {
                i += 1;
                while (i < text.len and text[i] != '}') {
                    const d = text[i];
                    const val: u32 = if (d >= '0' and d <= '9') d - '0'
                        else if (d >= 'a' and d <= 'f') d - 'a' + 10
                        else if (d >= 'A' and d <= 'F') d - 'A' + 10
                        else return null;
                    codepoint = codepoint * 16 + val;
                    i += 1;
                }
                if (i < text.len) i += 1;
            } else {
                var count: u32 = 0;
                while (count < 4 and i < text.len) {
                    const d = text[i];
                    const val: u32 = if (d >= '0' and d <= '9') d - '0'
                        else if (d >= 'a' and d <= 'f') d - 'a' + 10
                        else if (d >= 'A' and d <= 'F') d - 'A' + 10
                        else return null;
                    codepoint = codepoint * 16 + val;
                    i += 1;
                    count += 1;
                }
                if (count != 4) return null;
            }
            // Encode as UTF-8
            if (codepoint < 0x80) {
                if (out_len >= buf.len) return null;
                buf[out_len] = @intCast(codepoint);
                out_len += 1;
            } else if (codepoint < 0x800) {
                if (out_len + 2 > buf.len) return null;
                buf[out_len] = @intCast(0xC0 | (codepoint >> 6));
                buf[out_len + 1] = @intCast(0x80 | (codepoint & 0x3F));
                out_len += 2;
            } else if (codepoint < 0x10000) {
                if (out_len + 3 > buf.len) return null;
                buf[out_len] = @intCast(0xE0 | (codepoint >> 12));
                buf[out_len + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
                buf[out_len + 2] = @intCast(0x80 | (codepoint & 0x3F));
                out_len += 3;
            } else {
                if (out_len + 4 > buf.len) return null;
                buf[out_len] = @intCast(0xF0 | (codepoint >> 18));
                buf[out_len + 1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
                buf[out_len + 2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
                buf[out_len + 3] = @intCast(0x80 | (codepoint & 0x3F));
                out_len += 4;
            }
        } else {
            if (out_len >= buf.len) return null;
            buf[out_len] = text[i];
            out_len += 1;
            i += 1;
        }
    }
    return buf[0..out_len];
}

pub const Error = error{ParseError} || std.mem.Allocator.Error;

// ── Lex/Var redeclaration conflict helpers ──────────────────────────────────
//
// These module-level functions walk the already-built AST to detect conflicts
// between LexicallyDeclaredNames and VarDeclaredNames inside a block or switch
// body.  They run AFTER parsing is complete (nodes/extra_data are stable).
//
// "Lex" = let / const / class_decl / fn_decl / async_fn_decl / generator_fn_decl
//         / async_generator_fn_decl (i.e. anything that creates a block-scoped binding)
// "Var" = var_decl (including those nested inside non-function blocks, loops, etc.)
//
// We use fixed-size stack buffers and silently truncate — the goal is to catch
// the common cases mandated by the test262 suite without allocating.

/// Collect the simple identifier name from a binding pattern node.
/// Appends to buf/count; stops when buf is full.
fn collectBindingName(
    p: *const Parser,
    binding: NodeIndex,
    buf: [][]const u8,
    count: *usize,
) void {
    if (binding == .none or count.* >= buf.len) return;
    const bi = binding.toInt();
    if (bi >= p.nodes.len) return;
    const tag = p.node_tags_ptr[bi];
    const data = p.node_data_ptr[bi];
    switch (tag) {
        .identifier => {
            const tok = p.node_main_token_ptr[bi];
            const s = p.tok_starts_ptr[tok];
            const l = p.tok_lens_ptr[tok];
            if (s + l <= p.source.len) {
                buf[count.*] = p.source[s .. s + l];
                count.* += 1;
            }
        },
        .array_pattern => {
            // lhs/rhs are SubRange start/end direct indices into extra_data
            const s = data.lhs.toInt();
            const e = data.rhs.toInt();
            if (s <= e and e <= p.extra_data.items.len) {
                for (p.extra_data.items[s..e]) |raw| {
                    if (count.* >= buf.len) return;
                    const child: NodeIndex = @enumFromInt(raw);
                    if (child == .none) continue;
                    collectBindingName(p, child, buf, count);
                }
            }
        },
        .object_pattern => {
            const s = data.lhs.toInt();
            const e = data.rhs.toInt();
            if (s <= e and e <= p.extra_data.items.len) {
                for (p.extra_data.items[s..e]) |raw| {
                    if (count.* >= buf.len) return;
                    const prop: NodeIndex = @enumFromInt(raw);
                    if (prop == .none) continue;
                    const pi = prop.toInt();
                    if (pi >= p.nodes.len) continue;
                    const ptag = p.node_tags_ptr[pi];
                    const pdata = p.node_data_ptr[pi];
                    switch (ptag) {
                        .shorthand_property => collectBindingName(p, pdata.lhs, buf, count),
                        .property, .computed_property => collectBindingName(p, pdata.rhs, buf, count),
                        .rest_element => collectBindingName(p, pdata.lhs, buf, count),
                        else => {},
                    }
                }
            }
        },
        .assignment_pattern => {
            collectBindingName(p, data.lhs, buf, count);
        },
        .rest_element => {
            collectBindingName(p, data.lhs, buf, count);
        },
        else => {},
    }
}

/// Returns true if `node` is an iteration statement or a labeled statement that
/// transitively wraps an iteration statement (for `continue label` validation).
fn isIterationOrLabeledIteration(p: *const Parser, node: NodeIndex) bool {
    if (node == .none) return false;
    const idx = node.toInt();
    if (idx >= p.nodes.len) return false;
    const tag = p.node_tags_ptr[idx];
    return switch (tag) {
        .while_stmt, .do_while_stmt, .for_stmt,
        .for_in_stmt, .for_of_stmt, .for_await_of_stmt => true,
        .labeled_stmt => isIterationOrLabeledIteration(p, p.node_data_ptr[idx].lhs),
        else => false,
    };
}

/// Returns true if `node` is a LabelledStatement whose innermost LabelledItem
/// is a FunctionDeclaration (possibly through nested labels). Per spec 14.13.1,
/// IsLabelledFunction is true for doubly-nested labels leading to a fn decl.
fn isLabelledFunction(p: *const Parser, node: NodeIndex) bool {
    if (node == .none) return false;
    const idx = node.toInt();
    if (idx >= p.nodes.len) return false;
    if (p.node_tags_ptr[idx] != .labeled_stmt) return false;
    const inner = p.node_data_ptr[idx].lhs;
    if (inner == .none) return false;
    const inner_tag = p.node_tags_ptr[inner.toInt()];
    if (inner_tag == .fn_decl or inner_tag == .async_fn_decl) return true;
    return isLabelledFunction(p, inner);
}

/// Check that bound names from a lex declaration in a for head (let/const) do not
/// conflict with var-declared names in the body. Emits a diagnostic for each conflict.
fn checkForLexVarConflict(self: *Parser, lex_decl: NodeIndex, body: NodeIndex) Error!void {
    if (lex_decl == .none or body == .none or self.is_ts) return;
    const tag = self.node_tags_ptr[lex_decl.toInt()];
    if (tag != .let_decl and tag != .const_decl) return;
    var lex_buf: [32][]const u8 = undefined;
    var lex_n: usize = 0;
    collectLexNamesInNode(self, lex_decl, &lex_buf, &lex_n);
    if (lex_n == 0) return;
    var var_buf: [128][]const u8 = undefined;
    var var_n: usize = 0;
    collectVarNamesInNode(self, body, &var_buf, &var_n);
    for (lex_buf[0..lex_n]) |lex_name| {
        for (var_buf[0..var_n]) |var_name| {
            if (std.mem.eql(u8, lex_name, var_name)) {
                try self.emitDiagnostic(self.currentSpan(),
                    "Identifier '{s}' has already been declared", .{lex_name});
                break;
            }
        }
    }
}

/// Check that bound names in a for-in/of lex declaration are unique.
fn checkForBindingNamesDup(self: *Parser, lex_decl: NodeIndex) Error!void {
    if (lex_decl == .none or self.is_ts) return;
    const tag = self.node_tags_ptr[lex_decl.toInt()];
    if (tag != .let_decl and tag != .const_decl) return;
    var buf: [32][]const u8 = undefined;
    var n: usize = 0;
    collectLexNamesInNode(self, lex_decl, &buf, &n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            if (std.mem.eql(u8, buf[i], buf[j])) {
                try self.emitDiagnostic(self.currentSpan(),
                    "Identifier '{s}' has already been declared", .{buf[i]});
                break;
            }
        }
    }
}

/// Check that no name in catch_param's BoundNames appears in the LexicallyDeclaredNames
/// of the catch body block (top-level only, not nested blocks). Also checks for duplicate
/// names within catch_param itself.
fn checkCatchBindingConflicts(self: *Parser, catch_param: NodeIndex, catch_body: NodeIndex) Error!void {
    if (self.is_ts) return;
    // Check for duplicate names within the catch parameter itself.
    if (catch_param != .none) {
        var dup_buf: [16][]const u8 = undefined;
        var dup_n: usize = 0;
        collectBindingName(self, catch_param, &dup_buf, &dup_n);
        var i: usize = 0;
        while (i < dup_n) : (i += 1) {
            var j: usize = i + 1;
            while (j < dup_n) : (j += 1) {
                if (std.mem.eql(u8, dup_buf[i], dup_buf[j])) {
                    try self.emitDiagnostic(self.currentSpan(),
                        "Identifier '{s}' has already been declared", .{dup_buf[i]});
                    return error.ParseError;
                }
            }
        }
    }
    // Check catch param names against lex names declared at the TOP LEVEL of the catch body.
    // Nested block contents are NOT included (LexicallyDeclaredNames is not transitive).
    if (catch_param == .none or catch_body == .none) return;
    const body_idx = catch_body.toInt();
    if (body_idx >= self.nodes.len) return;
    if (self.node_tags_ptr[body_idx] != .block_stmt) return;
    const body_data = self.node_data_ptr[body_idx];
    var param_buf: [16][]const u8 = undefined;
    var param_n: usize = 0;
    collectBindingName(self, catch_param, &param_buf, &param_n);
    if (param_n == 0) return;
    var lex_buf: [64][]const u8 = undefined;
    var lex_n: usize = 0;
    collectLexNamesInRange(self, body_data.lhs.toInt(), body_data.rhs.toInt(), &lex_buf, &lex_n);
    for (param_buf[0..param_n]) |pname| {
        for (lex_buf[0..lex_n]) |lname| {
            if (std.mem.eql(u8, pname, lname)) {
                try self.emitDiagnostic(self.currentSpan(),
                    "Identifier '{s}' has already been declared", .{pname});
                return error.ParseError;
            }
        }
    }
    // For destructuring catch patterns (array/object), var declarations inside the
    // catch block also conflict. AnnexB B.3.5 exemption only applies to simple
    // identifier catch bindings, not patterns.
    const cp_tag = self.node_tags_ptr[catch_param.toInt()];
    const is_pattern = cp_tag == .array_pattern or cp_tag == .object_pattern;
    if (is_pattern) {
        var var_buf: [64][]const u8 = undefined;
        var var_n: usize = 0;
        collectVarNamesInRange(self, body_data.lhs.toInt(), body_data.rhs.toInt(), &var_buf, &var_n);
        for (param_buf[0..param_n]) |pname| {
            for (var_buf[0..var_n]) |vname| {
                if (std.mem.eql(u8, pname, vname)) {
                    try self.emitDiagnostic(self.currentSpan(),
                        "Identifier '{s}' has already been declared", .{pname});
                    return error.ParseError;
                }
            }
        }
    }
}

/// Collect names from var_decl nodes in extra_data[start..end].
/// Recurses into nested non-function blocks. Stops at function/class scope boundaries.
fn collectVarNamesInRange(
    p: *const Parser,
    start: usize,
    end: usize,
    buf: [][]const u8,
    count: *usize,
) void {
    if (start >= end or end > p.extra_data.items.len) return;
    for (p.extra_data.items[start..end]) |raw| {
        if (count.* >= buf.len) return;
        if (raw == 0) continue; // skip .none (root sentinel) – though 0 = root
        const node: NodeIndex = @enumFromInt(raw);
        // node index 0 = root, which is never a statement in a block
        if (node == .none) continue;
        collectVarNamesInNode(p, node, buf, count);
    }
}

fn collectVarNamesInNode(
    p: *const Parser,
    node: NodeIndex,
    buf: [][]const u8,
    count: *usize,
) void {
    if (node == .none or count.* >= buf.len) return;
    const idx = node.toInt();
    if (idx >= p.nodes.len) return;
    const tag = p.node_tags_ptr[idx];
    const data = p.node_data_ptr[idx];

    switch (tag) {
        .var_decl => {
            // lhs/rhs are SubRange start/end (direct indices into extra_data)
            const s = data.lhs.toInt();
            const e = data.rhs.toInt();
            if (s <= e and e <= p.extra_data.items.len) {
                for (p.extra_data.items[s..e]) |decl_raw| {
                    if (count.* >= buf.len) return;
                    if (decl_raw == 0) continue;
                    const decl: NodeIndex = @enumFromInt(decl_raw);
                    if (decl == .none) continue;
                    const di = decl.toInt();
                    if (di >= p.nodes.len) continue;
                    const binding = p.node_data_ptr[di].lhs;
                    collectBindingName(p, binding, buf, count);
                }
            }
        },
        .block_stmt => {
            // lhs/rhs are SubRange start/end (direct indices into extra_data)
            collectVarNamesInRange(p, data.lhs.toInt(), data.rhs.toInt(), buf, count);
        },
        .if_stmt => {
            // lhs = condition (expr, skip), rhs = consequent (statement)
            collectVarNamesInNode(p, data.rhs, buf, count);
        },
        .if_else_stmt => {
            // lhs = condition, rhs = extra index to IfData { consequent, alternate }
            const extra_idx = data.rhs.toInt();
            if (extra_idx + 1 < p.extra_data.items.len) {
                const consequent: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx]);
                const alternate: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx + 1]);
                collectVarNamesInNode(p, consequent, buf, count);
                collectVarNamesInNode(p, alternate, buf, count);
            }
        },
        .while_stmt => {
            // lhs = condition (expr, skip), rhs = body
            collectVarNamesInNode(p, data.rhs, buf, count);
        },
        .do_while_stmt => {
            // lhs = body, rhs = condition (expr, skip)
            collectVarNamesInNode(p, data.lhs, buf, count);
        },
        .for_stmt => {
            // lhs = extra index to ForData { init, condition, update }, rhs = body
            // ForData: extra_data[lhs] = init, [lhs+1] = condition, [lhs+2] = update
            const extra_idx = data.lhs.toInt();
            if (extra_idx < p.extra_data.items.len) {
                // init may be a var_decl
                const init_node: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx]);
                collectVarNamesInNode(p, init_node, buf, count);
            }
            // body
            collectVarNamesInNode(p, data.rhs, buf, count);
        },
        .for_in_stmt, .for_of_stmt, .for_await_of_stmt => {
            // lhs = extra index to ForInOfData { binding, expr, body }
            const extra_idx = data.lhs.toInt();
            if (extra_idx + 2 < p.extra_data.items.len) {
                const binding_node: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx]);
                const body_node: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx + 2]);
                // binding may be var_decl
                collectVarNamesInNode(p, binding_node, buf, count);
                collectVarNamesInNode(p, body_node, buf, count);
            }
        },
        .labeled_stmt => {
            // lhs = statement
            collectVarNamesInNode(p, data.lhs, buf, count);
        },
        .with_stmt => {
            // lhs = object expr (skip), rhs = body
            collectVarNamesInNode(p, data.rhs, buf, count);
        },
        .try_stmt => {
            // lhs = block, rhs = extra index to TryData { catch_node, finally_body }
            collectVarNamesInNode(p, data.lhs, buf, count);
            const extra_idx = data.rhs.toInt();
            if (extra_idx + 1 < p.extra_data.items.len) {
                const catch_node: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx]);
                const finally_body: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx + 1]);
                // catch_clause: lhs = param (skip), rhs = body block
                if (catch_node != .none) {
                    const ci = catch_node.toInt();
                    if (ci < p.nodes.len and p.node_tags_ptr[ci] == .catch_clause) {
                        collectVarNamesInNode(p, p.node_data_ptr[ci].rhs, buf, count);
                    }
                }
                collectVarNamesInNode(p, finally_body, buf, count);
            }
        },
        .switch_stmt => {
            // lhs = discriminant (skip), rhs = extra index to SubRange of cases
            const extra_idx = data.rhs.toInt();
            if (extra_idx + 1 < p.extra_data.items.len) {
                const case_start = p.extra_data.items[extra_idx];
                const case_end = p.extra_data.items[extra_idx + 1];
                if (case_start <= case_end and case_end <= p.extra_data.items.len) {
                    for (p.extra_data.items[case_start..case_end]) |case_raw| {
                        if (count.* >= buf.len) return;
                        const case_node: NodeIndex = @enumFromInt(case_raw);
                        if (case_node == .none) continue;
                        const ci = case_node.toInt();
                        if (ci >= p.nodes.len) continue;
                        const ctag = p.node_tags_ptr[ci];
                        const cdata = p.node_data_ptr[ci];
                        // switch_case/switch_default: rhs = extra index to SubRange of stmts
                        if (ctag == .switch_case or ctag == .switch_default) {
                            const stmt_extra_idx = cdata.rhs.toInt();
                            if (stmt_extra_idx + 1 < p.extra_data.items.len) {
                                const ss = p.extra_data.items[stmt_extra_idx];
                                const se = p.extra_data.items[stmt_extra_idx + 1];
                                collectVarNamesInRange(p, ss, se, buf, count);
                            }
                        }
                    }
                }
            }
        },
        // Stop at function/class scope boundaries — vars inside are NOT in block scope
        .fn_decl, .fn_expr,
        .async_fn_decl, .async_fn_expr,
        .generator_fn_decl, .generator_fn_expr,
        .async_generator_fn_decl, .async_generator_fn_expr,
        .class_decl, .class_expr,
        .arrow_fn, .async_arrow_fn,
        => {},
        // All other nodes (expressions, declarations etc.) — skip
        else => {},
    }
}

/// Collect lexically-declared names from top-level statements in extra_data[start..end].
/// "Lex" means: let_decl, const_decl, class_decl, fn_decl, async_fn_decl,
/// generator_fn_decl, async_generator_fn_decl.
/// Only collects at the TOP level (does NOT recurse into nested blocks).
fn collectLexNamesInRange(
    p: *const Parser,
    start: usize,
    end: usize,
    buf: [][]const u8,
    count: *usize,
) void {
    if (start >= end or end > p.extra_data.items.len) return;
    for (p.extra_data.items[start..end]) |raw| {
        if (count.* >= buf.len) return;
        if (raw == 0) continue;
        const node: NodeIndex = @enumFromInt(raw);
        if (node == .none) continue;
        collectLexNamesInNode(p, node, buf, count);
    }
}

fn collectLexNamesInNode(
    p: *const Parser,
    node: NodeIndex,
    buf: [][]const u8,
    count: *usize,
) void {
    if (node == .none or count.* >= buf.len) return;
    const idx = node.toInt();
    if (idx >= p.nodes.len) return;
    const tag = p.node_tags_ptr[idx];
    const data = p.node_data_ptr[idx];

    switch (tag) {
        .let_decl, .const_decl => {
            // lhs/rhs = SubRange start/end (declarator nodes)
            const s = data.lhs.toInt();
            const e = data.rhs.toInt();
            if (s <= e and e <= p.extra_data.items.len) {
                for (p.extra_data.items[s..e]) |decl_raw| {
                    if (count.* >= buf.len) return;
                    if (decl_raw == 0) continue;
                    const decl: NodeIndex = @enumFromInt(decl_raw);
                    if (decl == .none) continue;
                    const di = decl.toInt();
                    if (di >= p.nodes.len) continue;
                    const binding = p.node_data_ptr[di].lhs;
                    collectBindingName(p, binding, buf, count);
                }
            }
        },
        .class_decl => {
            // lhs = extra index to ClassData { name, ... }
            const extra_idx = data.lhs.toInt();
            if (extra_idx < p.extra_data.items.len) {
                const name_node: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx]);
                if (name_node != .none) {
                    const ni = name_node.toInt();
                    if (ni < p.nodes.len) {
                        const tok = p.node_main_token_ptr[ni];
                        const s = p.tok_starts_ptr[tok];
                        const l = p.tok_lens_ptr[tok];
                        if (s + l <= p.source.len and count.* < buf.len) {
                            buf[count.*] = p.source[s .. s + l];
                            count.* += 1;
                        }
                    }
                }
            }
        },
        .fn_decl, .async_fn_decl, .generator_fn_decl, .async_generator_fn_decl => {
            // lhs = extra index to FnData { name, params, params_end, body, ... }
            const extra_idx = data.lhs.toInt();
            if (extra_idx < p.extra_data.items.len) {
                const name_node: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx]);
                if (name_node != .none) {
                    const ni = name_node.toInt();
                    if (ni < p.nodes.len) {
                        const tok = p.node_main_token_ptr[ni];
                        const s = p.tok_starts_ptr[tok];
                        const l = p.tok_lens_ptr[tok];
                        if (s + l <= p.source.len and count.* < buf.len) {
                            buf[count.*] = p.source[s .. s + l];
                            count.* += 1;
                        }
                    }
                }
            }
        },
        else => {},
    }
}

/// Collect ONLY plain FunctionDeclaration (fn_decl) names from a statement range.
/// Used for AnnexB B.3.3.4/B.3.3.5: in sloppy mode, duplicate lex names are
/// allowed in block/switch when all duplicates come from FunctionDeclarations.
fn collectFnDeclNamesInRange(
    p: *const Parser,
    start: usize,
    end: usize,
    buf: [][]const u8,
    count: *usize,
) void {
    if (start >= end or end > p.extra_data.items.len) return;
    for (p.extra_data.items[start..end]) |raw| {
        if (count.* >= buf.len) return;
        if (raw == 0) continue;
        const node: NodeIndex = @enumFromInt(raw);
        if (node == .none) continue;
        const idx = node.toInt();
        if (idx >= p.nodes.len) continue;
        if (p.node_tags_ptr[idx] != .fn_decl) continue;
        const extra_idx = p.node_data_ptr[idx].lhs.toInt();
        if (extra_idx >= p.extra_data.items.len) continue;
        const name_node: NodeIndex = @enumFromInt(p.extra_data.items[extra_idx]);
        if (name_node == .none) continue;
        const ni = name_node.toInt();
        if (ni >= p.nodes.len) continue;
        const tok = p.node_main_token_ptr[ni];
        const s = p.tok_starts_ptr[tok];
        const l = p.tok_lens_ptr[tok];
        if (s + l <= p.source.len) {
            buf[count.*] = p.source[s .. s + l];
            count.* += 1;
        }
    }
}

/// Recursive descent parser for JavaScript/ES2024.
///
/// Follows the Zig compiler's pattern: MultiArrayList-backed nodes,
/// extra_data for overflow children, scratch space for building lists.
/// All ArrayLists are unmanaged (Zig 0.16 convention) — the allocator
/// is passed explicitly to each mutating call.
const Language = @import("token.zig").Language;

pub const Parser = struct {
    const LabelEntry = struct { name: []const u8, fn_depth: u16, is_loop: bool = false };

    /// A single recorded token rewrite, used to undo TS `>>`→`>` / `<<`→`<`
    /// splits when a speculative type-argument parse backtracks. See
    /// `tok_mut_log` / `recordTokMut`.
    pub const TokMut = struct { idx: u32, tag: TokenTag, start: u32 };

    source: []const u8,
    tokens: TokenList.Slice,
    /// Cached pointer to the tag array — avoids MultiArrayList.items(.tag)
    /// overhead on the hot peek() path.  Mutable: TS parser rewrites `>>`
    /// into `>` when closing generic type arguments.
    tags_ptr: [*]TokenTag,
    /// Cached pointer to has_newline_before — used by isOnNewLine (called once
    /// per parseExpressionPrec iteration).
    newlines_ptr: [*]const bool,
    /// Cached pointer to has_unicode_escape — lets isStrictReservedWord skip
    /// the O(n) indexOfScalar backslash scan for plain identifiers.
    has_escape_ptr: [*]const bool,
    /// Cached pointer to token byte starts (mutable for TS `>>` splitting).
    tok_starts_ptr: [*]u32,
    /// Cached pointer to token byte lengths.
    tok_lens_ptr: [*]const u32,
    tok_i: usize,
    /// Visible token count for the parser. In sequential (lexer-finalized)
    /// mode this equals `tokens.len`. In streaming (lex-parse pipeline) mode
    /// it is a snapshot of the producer's published count, refreshed via
    /// `refreshParsedLen()` on the slow path when `tok_i` reaches it.
    parsed_len: usize,
    /// Streaming-mode coordination. When non-null, the lex thread is producing
    /// tokens concurrently and `parsed_len` is a stale local cache; refresh by
    /// loading `published_len` (acquire). `lex_done` distinguishes "more tokens
    /// will come" from "EOF reached".
    published_len: ?*std.atomic.Value(usize) = null,
    lex_done: ?*std.atomic.Value(bool) = null,
    /// Event-stream publisher for the 3-stage pipeline: when non-null, the
    /// parser stores `scope_events.len()` to this slot at statement boundaries
    /// so a concurrent semantic analyzer can consume events as they are
    /// produced. Null in 1- and 2-stage modes.
    events_publish_to: ?*std.atomic.Value(usize) = null,
    lex_stall_count: u64 = 0,
    lex_stall_ns: u64 = 0,
    nodes: Ast.NodeList,
    /// Cached pointers into the nodes SoA — refreshed whenever nodes grows.
    /// `MultiArrayList.items(.tag)` reconstructs the slice (loops over field
    /// sizes + pointer arithmetic) on every call; caching saves that work on
    /// every nodeTag/nodeData read.
    node_tags_ptr: [*]Node.Tag,
    node_data_ptr: [*]Node.Data,
    node_main_token_ptr: [*]TokenIndex,
    extra_data: std.ArrayList(u32),
    scratch: std.ArrayList(u32),
    /// List of exported names — used to detect duplicate ExportedBindings
    /// per spec early errors. Tracks bare names like "foo" or "default".
    exported_names: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },
    /// Flat stack of declared private names across all open classes.
    /// AllPrivateNamesValid: every #x reference must resolve to a #x decl
    /// in the lexically-enclosing class chain.
    private_decls: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },
    /// Flat stack of pending #x references (token of the `#` punctuator).
    private_refs: std.ArrayListUnmanaged(TokenIndex) = .{ .items = &.{}, .capacity = 0 },
    /// Depth of currently-open class bodies. When we close the outermost
    /// (depth goes from 1 to 0) any unresolved private refs are SyntaxErrors.
    class_body_depth: u32 = 0,
    /// Set true by parseExpressionPrec when entering at relational precedence
    /// or lower, so parsePrimary's `.hash` branch knows we're in a position
    /// where `#x` could form `#x in expr`.
    private_in_lhs_allowed: bool = false,
    /// Set true while parsing the body of an IfStatement or LabelledStatement
    /// (NOT a Block). Annex B B.3.2.1 makes function-decls in these positions
    /// eligible for the "skip when conflict" extension — the dup-check uses
    /// this to choose `function_decl_annex_b` vs `function_decl`.
    in_annexb_fn_position: bool = false,
    /// Local names referenced by named exports without `from` — must resolve
    /// to a declared module-level binding by end of parsing.
    pending_export_local_toks: std.ArrayListUnmanaged(TokenIndex) = .{ .items = &.{}, .capacity = 0 },
    /// Module-level declared names (var/let/const/function/class/import).
    /// Used to validate exported locals refer to declared bindings.
    module_decl_names: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },
    /// True while parsing at module top level (decrements when entering
    /// function/class/block bodies). Used to scope module_decl_names tracking.
    at_module_top: bool = true,
    diagnostics: std.ArrayList(Diagnostic),
    /// Semantic events emitted during parse.  Enabled when `emit_scope_events`
    /// is true — zero-cost otherwise (all `emitScope*` helpers become dead code
    /// that LLVM eliminates).
    scope_events: ScopeEventStream = .{},
    emit_scope_events: bool = false,
    /// Hoisted write cursor into scope_events.events.items — avoids struct
    /// indirections on the hot emitReference / emitScope* paths.
    /// Initialized from scope_events.events.items.ptr after pre-allocation;
    /// synced back to scope_events.events.items.len at end of parse.
    ev_ptr: [*]ScopeEvent = undefined,
    /// Hoisted write cursor length. Declared as usize (not u32) so Zig places
    /// this in the 8-byte alignment group adjacent to ev_ptr, keeping both on
    /// the same cache line. The actual event count always fits in u32.
    ev_len: usize = 0,
    /// Count of elided scope_open events emitted during parse. Zero means the
    /// compaction pass in parseInternal can be skipped entirely.
    elided_scope_count: u32 = 0,
    /// Set to true when any block-level declaration (let/const/class/function_decl)
    /// is emitted directly inside the current parseBlockStatement call. Saved and
    /// restored at each parseBlockStatement entry so it reflects only the current
    /// block's direct children. When false after parsing a block, the scope_open
    /// for that block can be elided and the expensive event-scan skipped.
    block_has_lexical_decl: bool = false,
    /// Nesting depth relative to the innermost parseBlockStatement, used for
    /// incremental dup-detection (JS mode only). Set to -1 at parseBlockStatement
    /// entry so the block's own scope_open increments it to 0. emitScopeOpen
    /// increments, emitScopeClose decrements; parseBlockStatement saves/restores.
    block_dup_depth: i32 = 0,
    /// Flat buffer of block-level declares for the dup-detection scan. Each
    /// entry encodes (main_tok_idx << 32) | bk. parseBlockStatement uses a
    /// [saved_len..] window into this slice as its own set of depth-0 declares,
    /// then shrinks back to saved_len on exit (stack-of-ranges pattern).
    block_decl_scratch: std.ArrayListUnmanaged(u64) = .empty,
    /// Indices of object_literal nodes created during parsing (JS mode only).
    /// The post-parse duplicate-__proto__ scan iterates this list instead of
    /// scanning ALL nodes — reduces an O(total_nodes) pass to O(object_literals).
    proto_check_nodes: std.ArrayListUnmanaged(u32) = .empty,
    /// Reusable scratch for checkUniqueParams — avoids a malloc/free per function.
    param_names_scratch: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Direct-indexed cache of node-id → event-index for the most recent
    /// reference event for that node. Indexed by NodeIndex value; sentinel
    /// 0xFFFFFFFF means "no recent reference event". Eliminates O(N) backward
    /// scans in cancelReferenceForNode, upgradeReferenceKindUnbounded, and
    /// convertRefToDeclare. Sized to estimated_node_count at parse start;
    /// auto-grows alongside nodes. Direct array beats AutoHashMap because
    /// emitReference fires per-reference (~1.8M times on typescript.js) and
    /// each put incurred wyhash + bucket probe + amortized grow.
    ref_event_idx: []u32 = &.{},
    /// Per-node end token: last consumed token index at addNode time.
    /// Parallel to nodes; pre-allocated to estimated_node_count in parseInternal.
    node_end_toks: []u32 = &.{},
    /// Suppression flag for param-declare emission while we're speculatively
    /// parsing parenthesized content that MIGHT be an arrow's parameter list.
    /// When the arrow is confirmed we walk the params SubRange and emit
    /// declares into the fresh arrow scope.  When not, no declares are
    /// emitted for the expression form.
    suppress_param_declares: bool = false,
    /// Current declarator's binding name — set by parseDeclaratorConst
    /// around its init expression parse.  Used by parseFunctionExpression
    /// (and parseClassExpression) to emit `.fn_expr_name` instead of
    /// `.function_decl` when the NFE name matches the outer var name —
    /// matches ESLint's fn_expr_exceptions rule (affects no-shadow).
    decl_name_text: []const u8 = &.{},
    /// Non-structural (child, parent) parent links recorded for `Ast.parent_fixups`.
    /// The parser does NOT build the parent array (semantic does, via
    /// `buildParentsOnly`); it only records the few links that aren't derivable
    /// from the final tree (type annotations on destructured params/bindings).
    parent_fixups: std.ArrayListUnmanaged(u32) = .empty,
    gpa: std.mem.Allocator,
    max_nodes: usize,

    /// Journal of in-place token rewrites (the TS `>>`→`>` / `<<`→`<` splits)
    /// made while speculatively parsing type arguments. The mutation helpers
    /// in typescript.zig append the original (tag, start) here, but ONLY while
    /// `record_tok_muts` is true. When a speculative `tryParseTsTypeArguments`
    /// backtracks it replays this journal in reverse to undo the splits, which
    /// would otherwise corrupt the token stream for later parses (e.g. a
    /// trailing `>>` in a sibling enum member). Zero cost on the committed path.
    tok_mut_log: std.ArrayListUnmanaged(TokMut) = .{ .items = &.{}, .capacity = 0 },
    record_tok_muts: bool = false,

    /// Current recursive-descent nesting depth, bumped at each statement /
    /// expression / type / JSX recursion chokepoint via `enterRecursion`.
    /// Guards against native stack overflow on pathologically nested input.
    recursion_depth: u16 = 0,

    // Context flags
    in_function: bool,
    in_async: bool,
    in_generator: bool,
    in_class: bool,
    /// True inside a class static initialization block. `await` is reserved
    /// even though no enclosing function is async.
    in_static_block: bool,
    /// True if `new.target` is allowed at the current position. Set on entry
    /// to non-arrow function, method, class field initializer, or static block.
    /// Arrow functions inherit this from the enclosing context.
    new_target_allowed: bool,
    in_loop: bool,
    in_switch: bool,
    allow_in: bool,
    /// False when parsing at a precedence higher than assignment (binary RHS, unary operand).
    /// Arrow functions are only valid as AssignmentExpressions, not as binary operands.
    allow_arrow: bool,
    is_module: bool,
    /// parserOptions.ecmaFeatures.globalReturn — wraps top-level in a
    /// function-like scope (Node-CJS / RequireJS shape). In script mode,
    /// causes parseProgram to emit a synthetic outer global scope above the
    /// program-level scope so top-level vars live inside the inner one.
    global_return: bool = false,
    /// AnnexB web-compat extensions enabled. Default true (matches V8/JSC/SM).
    annex_b: bool = true,
    in_export_default: bool,
    in_strict: bool,
    in_block: bool,
    in_class_field: bool,
    /// One-shot flag: next parseBlock call is a FunctionBody StatementList.
    /// FunctionBody uses TopLevelLexicallyDeclaredNames — FunctionDeclarations
    /// don't participate in the lex/lex redecl check there.
    is_fn_body_block: bool,
    in_constructor: bool,
    /// Set when the lexically-enclosing class has an `extends` clause.
    /// Required for `super(...)` calls in the constructor.
    class_has_heritage: bool = false,
    /// Set while parsing the binding pattern of a `let`/`const` declaration.
    /// `let` as a binding name is forbidden anywhere in the pattern.
    in_lexical_decl: bool = false,
    /// Set while parsing FormalParameters. `yield`/`await` expressions inside
    /// initializers are forbidden when the function is a generator/async.
    in_fn_params: bool = false,
    in_method: bool,
    in_conditional_extends: bool,
    /// True when `infer T` is syntactically valid — set when entering a
    /// conditional-type extends clause, NOT reset inside nested parens or
    /// mapped-type constraints (unlike in_conditional_extends which IS reset
    /// for disambiguation purposes).
    infer_allowed: bool,
    /// True when parsing a function/method return type annotation.
    /// Type predicates (`x is T`, `this is T`) are only valid in return type
    /// position; when false, we emit TS1228.
    in_return_type: bool,
    /// True when parsing the consequent of a `cond ? consequent : alt` ternary.
    /// Used to disable speculative typed-arrow parsing of `(params): Type => body`
    /// — in this position the `:` belongs to the conditional, not a return type.
    in_conditional_consequent: bool = false,
    language: Language,
    /// Cached `language.isTs()` and `language.isJsx()` results. Parser
    /// methods test these on hot paths millions of times across a large
    /// file; reading a precomputed bool beats re-evaluating
    /// `language == .ts or language == .tsx` per call.
    is_ts: bool,
    is_jsx: bool,
    /// True when parsing the immediate body of a `with` statement.
    /// TypeScript does not emit TS1108 for `return` inside a `with` body at top level.
    in_with: bool = false,
    /// True when parsing inside a `declare` ambient context (e.g. `declare namespace N { ... }`).
    /// In ambient contexts, `const` declarations without initializers are valid.
    in_ts_ambient: bool = false,
    /// True when parsing inside an abstract class body.
    in_abstract_class: bool = false,
    /// True when using legacy TypeScript experimental decorators (TS1.x decorator semantics).
    /// Affects which class member decorator placements are allowed.
    experimental_decorators: bool = false,
    /// True when parsing inside a TypeScript namespace/module body (even non-ambient).
    /// Exports are valid in namespace bodies regardless of in_block.
    in_ts_namespace: bool = false,
    /// True when parsing statements directly inside a switch case/default clause
    /// (not inside a nested block within the clause). Used to detect TS1547/TS1548.
    in_case_clause: bool = false,
    /// True when parseTypeParameterList is being called from a function declaration
    /// or method definition (not from class-level type params, type aliases, or
    /// interface declarations). Used to emit type_param declares in the right scope
    /// so no-shadow can detect when a function generic shadows an outer type variable.
    emit_fn_type_params: bool = false,
    /// Heap-allocated (lazy) stack for TS duplicate-label and cross-function-
    /// boundary checks.  Kept as a pointer so the 768-byte inline array does
    /// not bloat the Parser struct and push hot fields (ev_len, gpa, is_ts)
    /// to distant cache lines.  Allocated on first label push; null means no
    /// labels have been seen yet (ts_label_count == 0).
    ts_label_stack: ?*[32]LabelEntry = null,
    ts_label_count: u8 = 0,
    /// Incremented each time we enter a non-arrow function body; used to detect TS1107.
    ts_label_fn_depth: u16 = 0,

    // ────────────────────────────────────────────────────────────
    // Public API
    // ────────────────────────────────────────────────────────────

    /// Main entry point. Creates a Parser, parses all top-level statements,
    /// builds the root node, and returns the completed Ast.
    /// @returns ast
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, tokens: TokenList.Slice) !Ast {
        // Emit scope events into the returned Ast by default so downstream
        // `analyze()` calls automatically take the event-driven fast path.
        // Emission cost is ~1-2% of parse; fast path saves ~10-20% on the
        // semantic side — net win across the whole pipeline.
        return parseWithOptions(allocator, source, tokens, .{ .emit_events = true });
    }

    pub const ParseOptions = struct {
        language: Language = .js,
        is_module: bool = false,
        /// parserOptions.ecmaFeatures.globalReturn (Node-CJS top-level).
        global_return: bool = false,
        /// When non-null, overrides the strict mode that is otherwise implied by
        /// `is_module`. Use `false` for CommonJS/AMD/System modules that allow
        /// ES-module syntax but are NOT automatically strict.
        is_strict: ?bool = null,
        /// AnnexB web-compat extensions (default ON). When false, parser-level
        /// AnnexB rules are disabled (call-as-assignment-target rejected,
        /// function-in-block redecl checked strictly, etc).
        annex_b: bool = true,
        /// When true, enables legacy TypeScript experimental decorators mode.
        /// Affects which decorator placements are allowed vs. rejected.
        experimental_decorators: bool = false,
        /// If non-null, parser emits a linear stream of scope/declare/reference
        /// events into this buffer.  Used by the event-driven semantic analyzer.
        events_out: ?*ScopeEventStream = null,
        /// Emit scope/declare/reference events into the returned Ast's
        /// `scope_events` field.  Enables the fast-path semantic analyzer
        /// automatically when the caller passes the Ast to analyze().
        emit_events: bool = false,
        /// Streaming mode (lex-parse pipeline). When set, the parser blocks
        /// in advance/peekAt slow paths until the producer publishes more
        /// tokens, instead of treating "past tokens.len" as EOF. The producer
        /// (lexer running on another thread) must atomically store the
        /// up-to-date token count to `published_len` (release) and set
        /// `lex_done` true after the final publish.
        streaming: ?StreamingHooks = null,
    };

    pub const StreamingHooks = struct {
        published_len: *std.atomic.Value(usize),
        lex_done: *std.atomic.Value(bool),
        /// Hint used to pre-size parser internal arrays. In streaming mode
        /// `tokens.len` reflects the buffer capacity (not produced tokens),
        /// but estimating from source bytes is generally cleaner.
        capacity_hint: usize,
        /// Optional event-stream publisher for the 3-stage pipeline. When
        /// set, the parser publishes the current event count to this atomic
        /// after every top-level statement so a concurrent sem thread can
        /// consume events incrementally.
        events_publish_to: ?*std.atomic.Value(usize) = null,
        /// Optional output slot for an early Ast view + a "ready" flag. Filled
        /// by the parser after buffer pre-sizing, before parsing begins —
        /// allows a concurrent sem thread to start with stable pointers into
        /// the still-growing nodes/events arrays. The Ast.nodes/.scope_events
        /// .len fields will lag behind the parser's actual count; sem must
        /// use events_publish_to for the bound and node_count_hint for sizing.
        ast_view_out: ?*Ast = null,
        ast_ready: ?*std.atomic.Value(bool) = null,
        /// Populated by the parser with the number of times it blocked waiting
        /// for the lexer and the total nanoseconds spent spinning.
        lex_stall_count_out: ?*u64 = null,
        lex_stall_ns_out: ?*u64 = null,
        /// Publish batch mask for parse→sem (batch_size - 1). Defaults to PUBLISH_BATCH-1.
        sem_batch_mask: usize = scope_events_mod.EventStream.PUBLISH_BATCH - 1,
    };

    pub fn parseWithOptions(allocator: std.mem.Allocator, source: []const u8, tokens: TokenList.Slice, opts: ParseOptions) !Ast {
        const is_strict = opts.is_strict orelse opts.is_module;
        return parseInternal(allocator, source, tokens, opts.language, opts.is_module, opts.global_return, is_strict, opts.events_out, opts.emit_events, opts.streaming, opts.annex_b, opts.experimental_decorators);
    }

    /// Parse with a specific language mode (js/ts/jsx/tsx).
    /// Always emits scope events — the event-driven semantic analyzer is the
    /// sole path (tree walker was removed). AnnexB extensions are ON by default.
    pub fn parseWithLanguage(allocator: std.mem.Allocator, source: []const u8, tokens: TokenList.Slice, language: Language, is_module_file: bool) !Ast {
        return parseInternal(allocator, source, tokens, language, is_module_file, false, is_module_file, null, true, null, true, false);
    }

    /// Same as parseWithLanguage but with an explicit AnnexB flag.
    pub fn parseWithLanguageOpts(allocator: std.mem.Allocator, source: []const u8, tokens: TokenList.Slice, language: Language, is_module_file: bool, annex_b: bool) !Ast {
        return parseInternal(allocator, source, tokens, language, is_module_file, false, is_module_file, null, true, null, annex_b, false);
    }

    fn parseInternal(
        allocator: std.mem.Allocator,
        source: []const u8,
        tokens: TokenList.Slice,
        language: Language,
        is_module_file: bool,
        global_return: bool,
        is_strict_mode: bool,
        events_out: ?*ScopeEventStream,
        emit_events: bool,
        streaming: ?StreamingHooks,
        annex_b: bool,
        experimental_decorators: bool,
    ) !Ast {
        var p = Parser{
            .source = source,
            .tokens = tokens,
            .tags_ptr = tokens.items(.tag).ptr,
            .newlines_ptr = tokens.items(.has_newline_before).ptr,
            .has_escape_ptr = tokens.items(.has_unicode_escape).ptr,
            .tok_starts_ptr = tokens.items(.start).ptr,
            .tok_lens_ptr = tokens.items(.len).ptr,
            .tok_i = 0,
            .parsed_len = if (streaming != null) 0 else tokens.len,
            .published_len = if (streaming) |s| s.published_len else null,
            .lex_done = if (streaming) |s| s.lex_done else null,
            .events_publish_to = if (streaming) |s| s.events_publish_to else null,
            .nodes = .empty,
            .node_tags_ptr = undefined,
            .node_data_ptr = undefined,
            .node_main_token_ptr = undefined,
            .extra_data = .empty,
            .scratch = .empty,
            .diagnostics = .empty,
            .gpa = allocator,
            // In streaming mode tokens.len is the pre-allocated buffer
            // capacity, not the actual produced count — caller passes the
            // tighter `capacity_hint`. Otherwise size by the materialized
            // token count.
            .max_nodes = if (streaming) |s| s.capacity_hint * 16
                else tokens.len * 16,
            .in_function = false,
            // Top-level await: allowed in modules (ES2022) and in TypeScript
            // (TSe / tsc accept it in script files too).
            .in_async = is_module_file or language == .ts or language == .tsx,
            .in_generator = false,
            .in_class = false,
            .in_static_block = false,
            .new_target_allowed = false,
            .in_loop = false,
            .in_switch = false,
            .allow_in = true,
            .allow_arrow = true,
            .is_module = is_module_file,
            .global_return = global_return,
            .annex_b = annex_b,
            .experimental_decorators = experimental_decorators,
            .in_export_default = false,
            .in_strict = is_strict_mode,
            .in_block = false,
            .in_class_field = false,
            .is_fn_body_block = false,
            .in_constructor = false,
            .in_method = false,
            .in_conditional_extends = false,
            .infer_allowed = false,
            .in_return_type = false,
            .language = language,
            .is_ts = language.isTs(),
            .is_jsx = language.isJsx(),
        };
        p.emit_scope_events = events_out != null or emit_events;
        defer p.nodes.deinit(allocator);
        defer p.extra_data.deinit(allocator);
        defer p.scratch.deinit(allocator);
        defer p.parent_fixups.deinit(allocator);
        // If events were requested, hand the stream back; otherwise free it.
        defer if (events_out == null) p.scope_events.deinit(allocator);
        defer if (p.ref_event_idx.len > 0) allocator.free(p.ref_event_idx);
        defer if (p.node_end_toks.len > 0) allocator.free(p.node_end_toks);
        defer p.private_decls.deinit(allocator);
        defer p.private_refs.deinit(allocator);
        defer p.tok_mut_log.deinit(allocator);
        defer p.exported_names.deinit(allocator);
        defer p.pending_export_local_toks.deinit(allocator);
        defer p.module_decl_names.deinit(allocator);
        defer p.block_decl_scratch.deinit(allocator);
        defer p.proto_check_nodes.deinit(allocator);
        defer p.param_names_scratch.deinit(allocator);
        defer if (p.ts_label_stack) |s| allocator.destroy(s);
        // Note: diagnostics ownership transfers to the returned Ast,
        // but we need a defer in case of early error.
        var diag_transferred = false;
        defer if (!diag_transferred) {
            // Free any diagnostic messages we allocated.
            for (p.diagnostics.items) |d| {
                allocator.free(d.message);
            }
            p.diagnostics.deinit(allocator);
        };

        // Empirically ~0.75 AST nodes per token; extra_data grows larger than
        // the 3/8 estimate for typical JS — use 3/4 to avoid regrowths during
        // long statement / arg lists (each grow is an allocator round-trip
        // plus memcpy). In streaming mode tokens.len is the buffer capacity,
        // not the actual produced count — caller passes a tighter hint.
        const sizing_count = if (streaming) |s| s.capacity_hint
            else tokens.len;
        // Streaming mode: shared buffers must NEVER resize during parse,
        // because a sem thread holds raw pointers (node_tags_ptr, events.items)
        // and a realloc would invalidate them. Pre-size to safe upper bounds
        // so addNode / scope_events.push hit the appendAssumeCapacity fast path
        // every time.
        // Streaming mode: same pre-size as sequential (3/4 sizing_count). The
        // 2x factor was speculative safety; in practice typescript.js etc. fit
        // and the larger allocation pushes the node buffer out of L2 → causes
        // the sem thread's post-passes to fall back to RAM bandwidth.
        const estimated_node_count: usize = @max(sizing_count * 3 / 4, 1);
        const estimated_extra_count: usize = @max(sizing_count * 3 / 4, 1);
        try p.nodes.ensureTotalCapacity(allocator, estimated_node_count);
        p.refreshNodePtrs();
        // Allocate to the actual (rounded-up) capacity so the hot path in addNode
        // is always in-bounds. nodes.capacity may exceed estimated_node_count.
        p.node_end_toks = try allocator.alloc(u32, p.nodes.capacity);
        try p.extra_data.ensureTotalCapacity(allocator, estimated_extra_count);
        // Scratch is a stack used by statement-list / arg-list parsers. Peak
        // depth depends on the largest block in the file (could be thousands
        // of top-level statements). Pre-size generously to avoid growth.
        try p.scratch.ensureTotalCapacity(allocator, @max(1024, sizing_count / 16));

        // Pre-size the event buffer. TS/complex JS generates ~0.4× events per
        // token; use 1× tokens as a safe margin for sequential mode (covers TS
        // with headroom). Streaming uses 2× for the concurrent sem thread path.
        if (p.emit_scope_events) {
            const event_cap = if (streaming != null) sizing_count * 2 else sizing_count;
            try p.scope_events.ensureCapacity(allocator, event_cap);
            // Streaming: wire EventStream's per-push publish to the same atomic.
            // This publishes every PUBLISH_BATCH events instead of only at
            // top-level statement boundaries — necessary for files with one
            // huge top-level IIFE (typescript.js etc.).
            if (streaming) |s| {
                p.scope_events.publish_to     = s.events_publish_to;
                p.scope_events.sem_batch_mask = s.sem_batch_mask;
            }
            // Wire hoisted cursor — avoids struct traversal on every event emit.
            p.ev_ptr = p.scope_events.events.items.ptr;
            p.ev_len = 0;
        }

        // Pre-size ref_event_idx to estimated node count — direct array indexed
        // by NodeIndex. Sentinel 0 = "no event recorded"; stored value is event_idx+1.
        // Zero sentinel enables dc zva zero-fill on ARM64 (2x faster than scalar stores).
        // When the parser struct is reused, nodes.capacity may already exceed the
        // estimate, so allocate to the larger of the two to keep the invariant.
        if (p.emit_scope_events) {
            const ref_idx_count = @max(estimated_node_count, p.nodes.capacity);
            p.ref_event_idx = try allocator.alloc(u32, ref_idx_count);
            // Zero the sentinel ("no event" = 0) unconditionally. A prior
            // optimization skipped this in ReleaseFast assuming OS-zeroed mmap
            // pages, but that only holds for fresh whole-page allocations — an
            // arena (or any allocator returning reused memory) hands back
            // garbage, and reading an unwritten entry as an event index then
            // wild-accesses the event stream (a ReleaseFast-only crash).
            @memset(p.ref_event_idx, 0);
        }
        // Pre-size the incremental dup-detection scratch (JS mode only).
        if (p.emit_scope_events and !p.is_ts) {
            try p.block_decl_scratch.ensureTotalCapacity(allocator, 64);
        }

        // Streaming mode: block until the producer publishes the first batch
        // (or signals lex_done). Without this the parser's first peek() —
        // which is a raw tags_ptr load with no bounds check on the hot path —
        // could read an unwritten slot.
        if (streaming != null) p.refreshParsedLen();

        // Streaming mode: publish an early Ast view so a concurrent sem thread
        // can start. Pointers into nodes/scope_events/extra_data are stable
        // (pre-sized to safe upper bounds, never realloc). The .len fields
        // grow during parse — sem must read those via events_publish_to.
        if (streaming) |s| {
            if (s.ast_view_out) |out| {
                // Construct an early Ast view with stable .ptr fields and
                // .len fields set to the pre-allocated capacity (not 0).
                // Indexing within `events_published` bounds is safe because
                // the parser writes node[i] / event[i] before publishing,
                // and sem reads via the atomic acquire.
                var nodes_slice = p.nodes.slice();
                nodes_slice.len = estimated_node_count;
                const event_buf_cap = if (p.emit_scope_events) sizing_count * 2 else 0;
                const events_full = if (p.emit_scope_events)
                    p.ev_ptr[0..event_buf_cap]
                else
                    &[_]@import("scope_events.zig").Event{};
                const extra_full = p.extra_data.items.ptr[0..estimated_extra_count];
                out.* = .{
                    .source = source,
                    .tokens = p.tokens,
                    .nodes = nodes_slice,
                    .extra_data = extra_full,
                    .errors = &.{},
                    .scope_events = events_full,
                };
                if (s.ast_ready) |r| r.store(true, .release);
            }
        }

        p.syncYieldLex();
        try p.parseProgram();

        // Transfer extra_data without a shrink-realloc memcpy. The pre-allocated
        // capacity (3/4 × token count) typically exceeds actual usage; rather than
        // calling toOwnedSlice (which allocates a new smaller buffer, copies all
        // data, and frees the old one — up to 4MB copied per parse), we hand the
        // over-allocated buffer directly to the Ast and record the true capacity so
        // deinit can free with the correct size.
        const extra_data_slice = p.extra_data.items;
        const extra_data_cap: u32 = @intCast(p.extra_data.capacity);
        p.extra_data.items = &.{};
        p.extra_data.capacity = 0;
        // defer p.extra_data.deinit(allocator) is already registered above and
        // will now be a no-op (empty ArrayList). Free on errpath explicitly.
        errdefer if (extra_data_cap > 0)
            allocator.free(extra_data_slice.ptr[0..extra_data_cap]);

        const errors = try p.diagnostics.toOwnedSlice(allocator);
        errdefer allocator.free(errors);
        diag_transferred = true;

        // Sync the hoisted ev_len cursor back into the ArrayList so that
        // toOwnedSlice / resizeTo see the correct length.  Elided scope_open
        // events are kept in-stream; resolveFull already skips them with a
        // `continue` (same handling as streaming mode, which never compacted).
        if (p.emit_scope_events) {
            p.scope_events.events.items.len = p.ev_len;
        }
        // Similarly transfer scope_events without a shrink-realloc memcpy.
        // Pre-allocated capacity (1× token count) is ~2× actual event count;
        // skipping toOwnedSlice avoids copying ~5MB per parse.
        var ast_events_cap: u32 = 0;
        const ast_events: []const scope_events_mod.Event = blk: {
            if (events_out) |out| {
                out.* = p.scope_events;
                p.scope_events = .{};
                break :blk &.{};
            }
            if (p.emit_scope_events) {
                const s = p.scope_events.events.items;
                ast_events_cap = @intCast(p.scope_events.events.capacity);
                p.scope_events.events.items = &.{};
                p.scope_events.events.capacity = 0;
                p.scope_events = .{};
                break :blk s;
            }
            break :blk &.{};
        };
        errdefer if (ast_events_cap > 0)
            allocator.free(ast_events.ptr[0..ast_events_cap]);

        // Transfer node_end_toks to Ast (only first nodes.len entries are valid).
        const final_node_count = p.nodes.len;
        const ast_node_end_toks: []const u32 = p.node_end_toks[0..final_node_count];
        const ast_node_end_toks_cap: u32 = @intCast(p.node_end_toks.len);
        p.node_end_toks = &.{}; // hand off; prevent defer from double-freeing
        errdefer if (ast_node_end_toks_cap > 0) allocator.free(ast_node_end_toks.ptr[0..ast_node_end_toks_cap]);

        // The parser does not build the parent array — semantic builds it on
        // demand via `buildParentsOnly` (structural scan + `parent_fixups`).
        const ast_parent_fixups: []const u32 = try p.parent_fixups.toOwnedSlice(allocator);
        const ast_parent_fixups_cap: u32 = @intCast(ast_parent_fixups.len);
        errdefer if (ast_parent_fixups_cap > 0) allocator.free(ast_parent_fixups.ptr[0..ast_parent_fixups_cap]);

        if (streaming) |s| {
            if (s.lex_stall_count_out) |out| out.* = p.lex_stall_count;
            if (s.lex_stall_ns_out)    |out| out.* = p.lex_stall_ns;
        }

        return Ast{
            .source = source,
            .is_ts = p.is_ts,
            .nodes = p.nodes.toOwnedSlice(),
            .tokens = p.tokens,
            .extra_data = extra_data_slice,
            .extra_data_cap = extra_data_cap,
            .errors = errors,
            .scope_events = ast_events,
            .scope_events_cap = ast_events_cap,
            .node_end_toks = ast_node_end_toks,
            .node_end_toks_cap = ast_node_end_toks_cap,
            .parent_fixups = ast_parent_fixups,
            .parent_fixups_cap = ast_parent_fixups_cap,
        };
    }

    // ────────────────────────────────────────────────────────────
    // Token helpers
    // ────────────────────────────────────────────────────────────

    /// No-op kept to avoid touching the many call sites in expressions.zig.
    /// The monolithic lexer doesn't need this hook — yield/regex disambiguation
    /// is handled at lex time via tokenizeWithLanguage's built-in flags.
    pub inline fn syncYieldLex(_: *Parser) void {}

    /// Current token index as TokenIndex (u32 cast from usize tok_i).
    pub inline fn tokIdx(self: *const Parser) TokenIndex { return @intCast(self.tok_i); }

    /// Consume the current token and return its index.
    pub inline fn advance(self: *Parser) TokenIndex {
        const result: TokenIndex = @intCast(self.tok_i);
        // Hot path identical for iter + non-iter: peek already brought the
        // current token into the materialized buffer (iter mode) or it was
        // pre-tokenized (non-iter mode). Just bump tok_i.
        if (self.tok_i < self.parsed_len - 1) {
            @branchHint(.likely);
            self.tok_i += 1;
            return result;
        }
        return self.advanceSlow(result);
    }

    fn advanceSlow(self: *Parser, result: TokenIndex) TokenIndex {
        @branchHint(.cold);
        if (self.published_len != null) {
            self.refreshParsedLen();
            if (self.tok_i < self.parsed_len - 1) self.tok_i += 1;
        }
        return result;
    }

    /// Does a token exist at absolute index `idx`? A plain bounds check against
    /// the materialized token array.
    pub fn tokenExists(self: *Parser, idx: usize) bool {
        return idx < self.tokens.len;
    }

    /// Streaming slow-path: refresh the visible token count from the lex
    /// thread's published_len. Spins (with thread yield) until either more
    /// tokens are available or the lexer signals EOF. In non-streaming mode
    /// this is a no-op.
    fn refreshParsedLen(self: *Parser) void {
        const pub_atomic = self.published_len orelse return;
        // Fast path: a quick atomic load may already have new tokens.
        const cur = pub_atomic.load(.acquire);
        if (cur > self.parsed_len) {
            self.parsed_len = cur;
            return;
        }
        // Slow path: spin/yield until publisher advances or EOF.
        self.lex_stall_count += 1;
        var ts0: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts0);
        var spins: u32 = 0;
        while (true) {
            const v = pub_atomic.load(.acquire);
            if (v > self.parsed_len) {
                self.parsed_len = v;
                break;
            }
            if (self.lex_done.?.load(.acquire)) {
                self.parsed_len = pub_atomic.load(.acquire);
                break;
            }
            spins += 1;
            if (spins < 100) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
        var ts1: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts1);
        self.lex_stall_ns += @as(u64, @intCast(ts1.sec - ts0.sec)) * 1_000_000_000 +
            @as(u64, @intCast(ts1.nsec)) -% @as(u64, @intCast(ts0.nsec));
    }

    /// Skip balanced parentheses, consuming from `(` to matching `)`.
    pub fn skipBalancedParens(self: *Parser) void {
        if (self.peek() != .l_paren) return;
        _ = self.advance(); // consume '('
        var depth: u32 = 1;
        while (depth > 0 and !self.isAtEnd()) {
            const tok = self.peek();
            if (tok == .l_paren) depth += 1;
            if (tok == .r_paren) depth -= 1;
            _ = self.advance();
        }
    }

    /// If the current token matches `tag`, consume it and return its index; otherwise null.
    pub inline fn eat(self: *Parser, tag: TokenTag) ?TokenIndex {
        if (self.peek() == tag) {
            return self.advance();
        }
        return null;
    }

    /// Consume a token of the given `tag` or emit a diagnostic and return error.
    pub inline fn expect(self: *Parser, tag: TokenTag) Error!TokenIndex {
        if (self.eat(tag)) |tok| {
            @branchHint(.likely);
            return tok;
        }
        return self.expectFail(tag);
    }

    fn expectFail(self: *Parser, tag: TokenTag) Error!TokenIndex {
        @branchHint(.cold);
        const lexeme = tag.lexeme() orelse "<token>";
        try self.emitDiagnostic(
            self.currentSpan(),
            "expected '{s}'",
            .{lexeme},
        );
        return error.ParseError;
    }

    /// Return the tag of the current token.
    pub inline fn peek(self: *Parser) TokenTag {
        if (self.tok_i < self.parsed_len) {
            @branchHint(.likely);
            return self.tags_ptr[self.tok_i];
        }
        return self.peekSlow();
    }

    fn peekSlow(self: *Parser) TokenTag {
        @branchHint(.cold);
        if (self.published_len != null) {
            self.refreshParsedLen();
            if (self.tok_i < self.parsed_len) return self.tags_ptr[self.tok_i];
        }
        return .eof;
    }

    /// Look ahead by `offset` tokens from the current position.
    pub inline fn peekAt(self: *Parser, offset: u32) TokenTag {
        const idx = self.tok_i + offset;
        if (idx < self.parsed_len) {
            @branchHint(.likely);
            return self.tags_ptr[idx];
        }
        return self.peekAtSlow(@intCast(idx));
    }

    fn peekAtSlow(self: *Parser, idx: u32) TokenTag {
        @branchHint(.cold);
        if (self.published_len != null) {
            self.refreshParsedLen();
            if (idx < self.parsed_len) return self.tags_ptr[idx];
        }
        return .eof;
    }

    /// Look ahead from the current position through any chained labeled statements
    /// to determine if the ultimate statement is an iteration statement.
    /// Used by parseLabeledStatement to compute is_loop correctly for nested labels.
    fn peeksAtIterationStmt(self: *Parser) bool {
        var offset: u32 = 0;
        while (true) {
            const tok = self.peekAt(offset);
            switch (tok) {
                .kw_while, .kw_for, .kw_do => return true,
                // Identifier followed by colon = another label, peek through it.
                .identifier, .kw_yield, .kw_await, .kw_let, .kw_static,
                .kw_get, .kw_set, .kw_of, .kw_from, .kw_as,
                => {
                    if (self.peekAt(offset + 1) == .colon) {
                        offset += 2; // skip identifier + colon
                        continue;
                    }
                    return false;
                },
                else => return false,
            }
        }
    }

    /// Get the source text for the token at `index`.
    /// @returns borrowed_from(self)
    pub fn tokenText(self: *const Parser, index: TokenIndex) []const u8 {
        const tag = self.tags_ptr[index];
        // Variable-lexeme tokens (identifiers, literals, escaped_keyword, etc.) are the first
        // 9 enum variants (0..identifier) plus the last 4 (escaped_keyword..jsx_text).
        // A range check is cheaper than the 80-arm lexeme() switch for these common cases.
        const ti = @intFromEnum(tag);
        if (ti <= @intFromEnum(TokenTag.identifier) or ti >= @intFromEnum(TokenTag.escaped_keyword)) {
            const start = self.tok_starts_ptr[index];
            const len = self.tok_lens_ptr[index];
            return self.source[start .. start + len];
        }
        // Fixed-lexeme tokens (keywords, punctuation) — return the canonical string.
        return tag.lexeme().?;
    }

    /// Check whether we have reached the end of input.
    pub fn isAtEnd(self: *Parser) bool {
        return self.peek() == .eof;
    }

    /// Return the byte position of the current token.
    pub fn currentStart(self: *const Parser) u32 {
        // tok_i < parsed_len holds because peek/peekAt drain the iter on
        // miss, and any caller of currentStart has already peeked.
        return self.tok_starts_ptr[self.tok_i];
    }

    /// Return a Span covering the current token's start position.
    pub fn currentSpan(self: *const Parser) Span {
        const s = self.currentStart();
        return .{ .start = s, .end = s };
    }

    /// Return the byte start position for a given token index.
    pub fn tokenStart(self: *const Parser, index: TokenIndex) u32 {
        return self.tok_starts_ptr[index];
    }

    /// Return the tag for a given token index.
    pub fn tokenTagAt(self: *const Parser, index: TokenIndex) TokenTag {
        return self.tags_ptr[index];
    }

    // ────────────────────────────────────────────────────────────
    // AST building helpers
    // ────────────────────────────────────────────────────────────

    /// Append a node to the nodes list and return its index.
    pub inline fn addNode(self: *Parser, node: Node) !NodeIndex {
        const result: u32 = @intCast(self.nodes.len);
        // Fast path: capacity and bound checks almost always pass (cold branches).
        if (result > self.max_nodes) {
            @branchHint(.cold);
            return error.OutOfMemory;
        }
        if (result >= self.nodes.capacity) {
            @branchHint(.cold);
            try self.nodes.ensureTotalCapacity(self.gpa, self.nodes.capacity * 2 + 16);
            self.refreshNodePtrs();
            if (self.ref_event_idx.len < self.nodes.capacity) {
                const old_len = self.ref_event_idx.len;
                self.ref_event_idx = try self.gpa.realloc(self.ref_event_idx, self.nodes.capacity);
                // Always zero the grown tail: realloc does NOT zero new bytes
                // (only fresh whole-page mmap does), so the ReleaseFast skip here
                // left garbage on arena/reused allocators — see parseInternal.
                @memset(self.ref_event_idx[old_len..], 0);
            }
            if (self.node_end_toks.len < self.nodes.capacity) {
                self.node_end_toks = try self.gpa.realloc(self.node_end_toks, self.nodes.capacity);
            }
        }
        // Write via hoisted raw pointers — skips MultiArrayList's internal
        // pointer-chain lookups (fields[0], fields[1], fields[2]).
        self.node_tags_ptr[result]       = node.tag;
        self.node_main_token_ptr[result] = node.main_token;
        self.node_data_ptr[result]       = node.data;
        self.nodes.len += 1;
        self.node_end_toks[result] = if (self.tok_i > 0) @intCast(self.tok_i - 1) else 0;
        return NodeIndex.fromInt(result);
    }

    // ── Event cursor helpers ───────────────────────────────────────

    /// Write one event via hoisted cursor. Grows the EventStream on overflow
    /// (rare — capacity is pre-sized to 1× token count). Sequential mode only;
    /// streaming mode updates ev_ptr/ev_len the same way but also publishes.
    inline fn evPush(self: *Parser, ev: ScopeEvent) !void {
        const n = self.ev_len;
        if (n >= self.scope_events.events.capacity) {
            @branchHint(.cold);
            // The hoisted cursor (`ev_ptr`/`ev_len`) writes events without
            // touching the ArrayList's `items.len`, which lags at its last
            // synced value. `ensureTotalCapacity` only copies `items.len`
            // elements into the grown buffer — so before growing we must expose
            // the `n` events already written through `ev_ptr`, or the realloc
            // drops them and leaves the new buffer's [0..n) uninitialized. (That
            // surfaced as dropped/garbage events whenever the pre-sized event
            // capacity was exceeded; benign under zero-filled pages, fatal under
            // any allocator returning reused memory.)
            self.scope_events.events.items.len = n;
            try self.scope_events.events.ensureTotalCapacity(self.gpa, @max(self.scope_events.events.capacity * 2 + 16, n + 1));
            self.ev_ptr = self.scope_events.events.items.ptr;
        }
        self.ev_ptr[n] = ev;
        self.ev_len = n + 1;
        if (self.scope_events.publish_to) |pp| {
            const new_n = n + 1;
            if ((new_n & self.scope_events.sem_batch_mask) == 0) {
                pp.store(new_n, .release);
            }
        }
    }

    // ── Semantic event emission (opt-in) ───────────────────────────
    // These helpers push a scope event onto the stream when emission is on.
    // When off, LLVM sees `emit_scope_events == false` at the call site and
    // the body is eliminated — zero cost for the default parse path.

    pub inline fn emitScopeOpen(self: *Parser, kind: ScopeKindU8, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .scope_open,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
        if (!self.is_ts) self.block_dup_depth += 1;
        return idx;
    }

    /// Overwrite the `node` field of a previously-emitted scope_open event.
    /// Used when the owning AST node (block_stmt, for_stmt, function, class, …)
    /// is created AFTER the scope is opened, so the event initially carried
    /// `.none` and needs back-patching once the node index is known.
    pub inline fn patchScopeOpenNode(self: *Parser, event_idx: u32, node: NodeIndex) void {
        if (!self.emit_scope_events) return;
        self.ev_ptr[event_idx].node = @intFromEnum(node);
    }

    pub inline fn emitScopeClose(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .scope_close,
            .aux = 0,
            .node = @intFromEnum(node),
        });
        if (!self.is_ts) self.block_dup_depth -= 1;
    }

    pub inline fn emitDeclare(self: *Parser, kind: BindingKindU8, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .declare,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
        // Track block-level declarations for scope-elision fast path in parseBlockStatement.
        // Kinds that are always emitted inside their own scope (parameter, catch_param,
        // fn_expr_name, class_expr_name, type_param) are not block-level. var doesn't keep
        // block scope alive.  Everything else (let/const/class_decl/function_decl/TS decls)
        // prevents scope elision for the current block.
        switch (kind) {
            .@"var", .parameter, .catch_param, .fn_expr_name, .class_expr_name, .type_param => {},
            else => {
                // In JS mode, record depth-0 declares for incremental dup detection.
                if (!self.is_ts and self.block_dup_depth == 0) {
                    const main_tok = self.node_main_token_ptr[@intFromEnum(node)];
                    const entry: u64 = (@as(u64, main_tok) << 32) | @as(u64, @intFromEnum(kind));
                    try self.block_decl_scratch.append(self.gpa, entry);
                }
                self.block_has_lexical_decl = true;
            },
        }
    }

    /// Given a `.declarator` node, emit a declare event for its binding.
    /// Handles both simple identifier bindings and destructuring patterns.
    fn emitDeclareFromDeclarator(self: *Parser, decl_node: NodeIndex, kind: BindingKindU8) !void {
        if (!self.emit_scope_events) return;
        if (decl_node == .none) return;
        const d = self.node_data_ptr[decl_node.toInt()];
        try self.emitDeclaresFromPattern(d.lhs, kind);
        // For bindings with an initializer, emit a write_init reference for each
        // leaf binding identifier.  This matches eslint-scope's behavior:
        // declaration + init is a write reference, enabling liveness analysis to
        // flag useless initial values (e.g. no-useless-assignment).
        if (d.rhs != .none and d.lhs != .none) {
            const binding_tag = self.node_tags_ptr[@intFromEnum(d.lhs)];
            if (binding_tag == .identifier) {
                try self.emitReference(.write_init, d.lhs);
            } else {
                try self.emitWriteInitsFromPattern(d.lhs);
            }
        }
    }

    /// Walk a binding pattern and emit a write_init reference for each leaf
    /// identifier binding.  Used by destructuring declarators.
    fn emitWriteInitsFromPattern(self: *Parser, node: NodeIndex) std.mem.Allocator.Error!void {
        if (node == .none) return;
        const idx = @intFromEnum(node);
        if (idx >= self.nodes.len) return;
        const tag = self.node_tags_ptr[idx];
        const data = self.node_data_ptr[idx];
        switch (tag) {
            .identifier => try self.emitReference(.write_init, node),
            .assignment_pattern => try self.emitWriteInitsFromPattern(data.lhs),
            .rest_element => try self.emitWriteInitsFromPattern(data.lhs),
            .ts_parameter_property => try self.emitWriteInitsFromPattern(data.lhs),
            .array_pattern => {
                const start = @intFromEnum(data.lhs);
                const end = @intFromEnum(data.rhs);
                if (start <= end and end <= self.extra_data.items.len) {
                    for (self.extra_data.items[start..end]) |raw| {
                        const child: NodeIndex = @enumFromInt(raw);
                        try self.emitWriteInitsFromPattern(child);
                    }
                }
            },
            .object_pattern => {
                const start = @intFromEnum(data.lhs);
                const end = @intFromEnum(data.rhs);
                if (start <= end and end <= self.extra_data.items.len) {
                    for (self.extra_data.items[start..end]) |raw| {
                        const prop_node: NodeIndex = @enumFromInt(raw);
                        if (prop_node == .none) continue;
                        const pidx = @intFromEnum(prop_node);
                        if (pidx >= self.nodes.len) continue;
                        const ptag = self.node_tags_ptr[pidx];
                        const pdata = self.node_data_ptr[pidx];
                        switch (ptag) {
                            .property, .computed_property => try self.emitWriteInitsFromPattern(pdata.rhs),
                            .shorthand_property => try self.emitWriteInitsFromPattern(pdata.lhs),
                            .rest_element => try self.emitWriteInitsFromPattern(pdata.lhs),
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }

    /// Walk a binding pattern (identifier / array_pattern / object_pattern /
    /// assignment_pattern / rest_element) and emit declare events for every
    /// leaf identifier binding.  Called from declarators, parameters, catch.
    pub fn emitDeclaresFromPattern(self: *Parser, node: NodeIndex, kind: BindingKindU8) std.mem.Allocator.Error!void {
        if (!self.emit_scope_events) return;
        try emitDeclaresFromPatternImpl(self, node, kind);
    }

    /// Emit declare events for every binding in a parameter SubRange.
    /// Used when params were already parsed into a SubRange (e.g. method
    /// bodies, arrow functions) and we now open their scope retroactively.
    pub fn emitParamDeclaresFromRange(self: *Parser, range: SubRange) std.mem.Allocator.Error!void {
        if (!self.emit_scope_events) return;
        if (range.end <= range.start) return;
        const end = range.end;
        var i: u32 = range.start;
        while (i < end) : (i += 1) {
            const raw = self.extra_data.items[i];
            const param: NodeIndex = @enumFromInt(raw);
            try emitDeclaresFromPatternImpl(self, param, .parameter);
        }
    }

    fn emitDeclaresFromPatternImpl(self: *Parser, node: NodeIndex, kind: BindingKindU8) std.mem.Allocator.Error!void {
        if (node == .none) return;
        const idx = @intFromEnum(node);
        if (idx >= self.nodes.len) return;
        const tag = self.node_tags_ptr[idx];
        const data = self.node_data_ptr[idx];
        switch (tag) {
            .identifier => {
                self.cancelReferenceForNode(node);
                try self.emitDeclare(kind, node);
            },
            // Default value: `x = 1` — lhs is the inner pattern, rhs is default expression.
            .assignment_pattern => try emitDeclaresFromPatternImpl(self, data.lhs, kind),
            // Rest: `...x` — lhs is the inner pattern.
            .rest_element => try emitDeclaresFromPatternImpl(self, data.lhs, kind),
            // TS-type-annotated binding: lhs = identifier, rhs = type annotation.
            // We don't care about the annotation, just recurse into lhs.
            // TS parameter property wraps a real param — recurse.
            .ts_parameter_property => try emitDeclaresFromPatternImpl(self, data.lhs, kind),
            // Array pattern: elements are stored in extra_data[lhs..rhs].
            .array_pattern => {
                const start = @intFromEnum(data.lhs);
                const end = @intFromEnum(data.rhs);
                if (start <= end and end <= self.extra_data.items.len) {
                    for (self.extra_data.items[start..end]) |raw| {
                        const child: NodeIndex = @enumFromInt(raw);
                        try emitDeclaresFromPatternImpl(self, child, kind);
                    }
                }
            },
            // Object pattern: properties in extra_data[lhs..rhs].  Each is a
            // `property` (or `shorthand_property` / `computed_property`) whose
            // VALUE is the binding target.
            .object_pattern => {
                const start = @intFromEnum(data.lhs);
                const end = @intFromEnum(data.rhs);
                if (start <= end and end <= self.extra_data.items.len) {
                    for (self.extra_data.items[start..end]) |raw| {
                        const prop_node: NodeIndex = @enumFromInt(raw);
                        if (prop_node == .none) continue;
                        const pidx = @intFromEnum(prop_node);
                        if (pidx >= self.nodes.len) continue;
                        const ptag = self.node_tags_ptr[pidx];
                        const pdata = self.node_data_ptr[pidx];
                        switch (ptag) {
                            .property, .computed_property => try emitDeclaresFromPatternImpl(self, pdata.rhs, kind),
                            .shorthand_property => try emitDeclaresFromPatternImpl(self, pdata.lhs, kind),
                            .rest_element => try emitDeclaresFromPatternImpl(self, pdata.lhs, kind),
                            else => {},
                        }
                    }
                }
            },
            else => {}, // unknown — skip
        }
    }

    pub inline fn emitReference(self: *Parser, kind: ReferenceKindU8, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        const event_idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .reference,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
        // Direct-array cache (no hashing). ref_event_idx is always sized to
        // nodes.capacity (kept in sync in addNode's grow path), and node indices
        // are always < nodes.len <= nodes.capacity, so the write is always in bounds.
        self.ref_event_idx[@intFromEnum(node)] = event_idx + 1;
    }

    pub const TerminatorKind = enum(u8) { @"return", @"throw", @"break", @"continue" };

    pub inline fn emitTerminator(self: *Parser, kind: TerminatorKind, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .terminator,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitBranchOpen(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .branch_open,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitBranchElse(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .branch_else,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitBranchClose(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .branch_close,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub const LoopKind = enum(u8) { @"while", do_while, @"for", for_in, for_of };

    pub inline fn emitLoopOpen(self: *Parser, kind: LoopKind, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .loop_open,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitLoopTestEnd(self: *Parser, kind: LoopKind, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .loop_test_end,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitLoopBodyEnd(self: *Parser, kind: LoopKind, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .loop_body_end,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitLoopClose(self: *Parser, kind: LoopKind, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .loop_close,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitTryOpen(self: *Parser, has_finalizer: bool, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .try_open,
            .aux = if (has_finalizer) 1 else 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitTryBodyEnd(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .try_body_end,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitTryCatchStart(self: *Parser, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .try_catch_start,
            .aux = 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitTryCatchEnd(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .try_catch_end,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitTryFinallyStart(self: *Parser, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .try_finally_start,
            .aux = 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitTryClose(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .try_close,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitSwitchOpen(self: *Parser, has_default: bool, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .switch_open,
            .aux = if (has_default) 1 else 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitSwitchCaseStart(self: *Parser, is_default: bool, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .switch_case_start,
            .aux = if (is_default) 1 else 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitSwitchCaseEnd(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .switch_case_end,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitSwitchClose(self: *Parser, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .switch_close,
            .aux = 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub const LogicalKind = enum(u8) { logical_and, logical_or, nullish_coalesce };

    pub inline fn emitLogicalOpen(self: *Parser, kind: LogicalKind, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .logical_open,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitLogicalRight(self: *Parser, kind: LogicalKind, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .logical_right,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitLogicalClose(self: *Parser, kind: LogicalKind, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .logical_close,
            .aux = @intFromEnum(kind),
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitCondOpen(self: *Parser, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .cond_open,
            .aux = 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitCondFork(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .cond_fork,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitCondAlt(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .cond_alt,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitCondClose(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .cond_close,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitIfOpen(self: *Parser, has_else: bool, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .if_open,
            .aux = if (has_else) 1 else 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitIfAlt(self: *Parser, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .if_alt,
            .aux = 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitIfClose(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .if_close,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn emitLabelOpen(self: *Parser, is_loop: bool, node: NodeIndex) !u32 {
        if (!self.emit_scope_events) return 0;
        const idx: u32 = @intCast(self.ev_len);
        try self.evPush(.{
            .kind = .label_open,
            .aux = if (is_loop) 1 else 0,
            .node = @intFromEnum(node),
        });
        return idx;
    }

    pub inline fn emitLabelClose(self: *Parser, node: NodeIndex) !void {
        if (!self.emit_scope_events) return;
        try self.evPush(.{
            .kind = .label_close,
            .aux = 0,
            .node = @intFromEnum(node),
        });
    }

    pub inline fn patchEventNode(self: *Parser, event_idx: u32, node: NodeIndex) void {
        if (!self.emit_scope_events) return;
        // Streaming: the resolver may race ahead and read the node field before
        // this patch fires. Use a release-store on the whole packed-u64 event so
        // the acquire-spin in the resolver's loop_open handler sees the real node.
        const ev_u64: *u64 = @ptrCast(&self.ev_ptr[event_idx]);
        const old = @atomicLoad(u64, ev_u64, .monotonic);
        @atomicStore(u64, ev_u64, (old & 0x00000000_FFFFFFFF) | (@as(u64, @intFromEnum(node)) << 32), .release);
    }

    /// Walk back through recently-emitted events to find the reference event
    /// for `node` and upgrade its kind — used by the assignment parser to turn
    /// a speculative `.read` into `.write` / `.read_write` once we see `=` / `+=`.
    ///
    /// Searches up to `max_back` events to handle compound expressions where
    /// the target identifier may be wrapped (e.g. `(x) = 1`).
    pub fn upgradeReferenceKind(self: *Parser, node: NodeIndex, new_kind: ReferenceKindU8) void {
        if (!self.emit_scope_events) return;
        const node_u32 = @intFromEnum(node);
        const cur_len = self.ev_len;
        const max_back: usize = 8;
        const start: usize = if (cur_len > max_back) cur_len - max_back else 0;
        var i: usize = cur_len;
        while (i > start) {
            i -= 1;
            const e = self.ev_ptr[i];
            if (e.kind == .reference and e.node == node_u32) {
                self.ev_ptr[i].aux = @intFromEnum(new_kind);
                return;
            }
        }
    }

    /// Unbounded version of upgradeReferenceKind — searches all emitted events.
    /// Returns true if a ref was found and upgraded, false if none existed.
    /// Used for destructuring assignment LHS patterns where identifiers may be
    /// many events back.
    pub fn upgradeReferenceKindUnbounded(self: *Parser, node: NodeIndex, new_kind: ReferenceKindU8) bool {
        if (!self.emit_scope_events) return false;
        const node_u32 = @intFromEnum(node);
        // ref_event_idx is always sized to nodes.capacity and node indices are always
        // < nodes.len <= nodes.capacity, so the load is always in bounds.
        const idx = self.ref_event_idx[node_u32];
        if (idx == 0) return false;
        const ev_idx = idx - 1;
        if (ev_idx < self.ev_len and self.ev_ptr[ev_idx].kind == .reference and self.ev_ptr[ev_idx].node == node_u32) {
            self.ev_ptr[ev_idx].aux = @intFromEnum(new_kind);
            return true;
        }
        return false;
    }

    /// Walk a destructuring assignment LHS pattern and upgrade all identifier
    /// ref events from read to write, emitting new write refs when no prior
    /// ref exists (e.g. for shorthand properties where parsePropertyName does
    /// not emit a ref). Called after reinterpretAsPattern for non-identifier LHS.
    pub fn upgradePatternRefsToWrite(self: *Parser, node: NodeIndex) std.mem.Allocator.Error!void {
        if (!self.emit_scope_events) return;
        if (node == .none) return;
        const idx = @intFromEnum(node);
        if (idx >= self.nodes.len) return;
        const tag = self.node_tags_ptr[idx];
        const data = self.node_data_ptr[idx];
        switch (tag) {
            .identifier => {
                // Try to upgrade existing read ref. If none (e.g. from parsePropertyName),
                // emit a fresh write ref so liveness analysis tracks this write.
                if (!self.upgradeReferenceKindUnbounded(node, .write)) {
                    try self.emitReference(.write, node);
                }
            },
            .member_expr, .optional_member_expr, .computed_member_expr, .optional_computed_member_expr => {
                // Member expressions are valid assignment targets but don't produce
                // symbol write refs — the object/property refs are reads.
            },
            .array_pattern => {
                const start = data.lhs.toInt();
                const end = data.rhs.toInt();
                var i = start;
                while (i < end) : (i += 1) {
                    if (i < self.extra_data.items.len)
                        try self.upgradePatternRefsToWrite(NodeIndex.fromInt(self.extra_data.items[i]));
                }
            },
            .object_pattern => {
                const start = data.lhs.toInt();
                const end = data.rhs.toInt();
                var i = start;
                while (i < end) : (i += 1) {
                    if (i < self.extra_data.items.len)
                        try self.upgradePatternRefsToWrite(NodeIndex.fromInt(self.extra_data.items[i]));
                }
            },
            .shorthand_property => try self.upgradePatternRefsToWrite(data.lhs),
            .property => try self.upgradePatternRefsToWrite(data.rhs),
            .computed_property => try self.upgradePatternRefsToWrite(data.rhs),
            .rest_element => try self.upgradePatternRefsToWrite(data.lhs),
            .assignment_pattern => try self.upgradePatternRefsToWrite(data.lhs),
            .grouping_expr => try self.upgradePatternRefsToWrite(data.lhs),
            else => {},
        }
    }

    /// Walk back through ALL emitted events (unbounded) to find a reference
    /// event for `node` and convert it into a declare event with the given
    /// binding kind.  Used for arrow parameters where the param identifier
    /// was speculatively parsed as an expression (emitting reference) before
    /// being reinterpreted as a binding.
    pub fn convertRefToDeclare(self: *Parser, node: NodeIndex, kind: BindingKindU8) void {
        if (!self.emit_scope_events) return;
        const node_u32 = @intFromEnum(node);
        // ref_event_idx is always sized to nodes.capacity and node indices are always
        // < nodes.len <= nodes.capacity, so the load is always in bounds.
        const idx = self.ref_event_idx[node_u32];
        if (idx == 0) return;
        const ev_idx = idx - 1;
        if (ev_idx < self.ev_len and self.ev_ptr[ev_idx].kind == .reference and self.ev_ptr[ev_idx].node == node_u32) {
            self.ev_ptr[ev_idx] = .{ .kind = .declare, .aux = @intFromEnum(kind), .node = node_u32 };
            self.ref_event_idx[node_u32] = 0;
        }
    }

    pub fn cancelReferenceForNode(self: *Parser, node: NodeIndex) void {
        if (!self.emit_scope_events) return;
        const node_u32 = @intFromEnum(node);
        // ref_event_idx is always sized to nodes.capacity and node indices are always
        // < nodes.len <= nodes.capacity, so the load is always in bounds.
        const idx = self.ref_event_idx[node_u32];
        if (idx == 0) return;
        const ev_idx = idx - 1;
        if (ev_idx < self.ev_len and self.ev_ptr[ev_idx].kind == .reference and self.ev_ptr[ev_idx].node == node_u32) {
            self.ev_ptr[ev_idx].kind = .nop;
            self.ref_event_idx[node_u32] = 0;
        }
    }

    /// Refresh cached node SoA field pointers after nodes grows.  Must be
    /// called after any `ensureTotalCapacity` that may have reallocated.
    pub fn refreshNodePtrs(self: *Parser) void {
        const s = self.nodes.slice();
        self.node_tags_ptr = s.items(.tag).ptr;
        self.node_data_ptr = s.items(.data).ptr;
        self.node_main_token_ptr = s.items(.main_token).ptr;
    }

    /// Serialize a struct to extra_data as sequential u32 fields, return the start index.
    pub inline fn addExtra(self: *Parser, comptime T: type, data: T) !ExtraIndex {
        const field_count = comptime meta_compat.fieldCount(T);
        const cur_len = self.extra_data.items.len;
        // Fast path: pre-allocated capacity covers the common case — avoid loading the allocator vtable.
        if (cur_len + field_count > self.extra_data.capacity) {
            @branchHint(.cold);
            try self.extra_data.ensureTotalCapacity(self.gpa, @max(self.extra_data.capacity * 2 + 16, cur_len + field_count));
        }
        const result: ExtraIndex = @intCast(cur_len);
        const ptr = self.extra_data.items.ptr;
        inline for (0..field_count) |i| {
            const name = comptime meta_compat.structFieldName(T, i);
            const FieldT = @FieldType(T, name);
            const val = @field(data, name);
            const as_u32: u32 = if (FieldT == NodeIndex)
                @intFromEnum(val)
            else if (FieldT == u32)
                val
            else
                @compileError("unexpected field type: " ++ @typeName(FieldT));
            ptr[cur_len + i] = as_u32;
        }
        self.extra_data.items.len = cur_len + field_count;
        return result;
    }

    /// Write items to extra_data and return a SubRange covering them.
    pub fn listToSubRange(self: *Parser, items: []const u32) !SubRange {
        const start: ExtraIndex = @intCast(self.extra_data.items.len);
        // Fast path: pre-allocated capacity covers the common case — avoid loading the allocator vtable.
        if (start + items.len > self.extra_data.capacity) {
            @branchHint(.cold);
            try self.extra_data.ensureTotalCapacity(self.gpa, @max(self.extra_data.capacity * 2 + 16, start + items.len));
        }
        self.extra_data.appendSliceAssumeCapacity(items);
        return SubRange{
            .start = start,
            .end = @intCast(self.extra_data.items.len),
        };
    }

    // ────────────────────────────────────────────────────────────
    // ASI (Automatic Semicolon Insertion)
    // ────────────────────────────────────────────────────────────

    /// Consume `;` if present. If not, check if ASI applies:
    /// (a) current token is on a new line vs. previous token,
    /// (b) current is `}`, (c) current is `eof`.
    /// If ASI doesn't apply, emit a diagnostic.
    pub inline fn expectSemicolon(self: *Parser) !void {
        if (self.eat(.semicolon)) |_| return;

        // ASI: automatic semicolon insertion
        const asi_t = self.peek();
        if (asi_t == .r_brace or asi_t == .eof) return;
        if (self.isOnNewLine()) return;

        try self.emitDiagnostic(
            self.currentSpan(),
            "expected ';'",
            .{},
        );
    }

    /// Check if there is a newline between the previous token's end and the
    /// current token's start in the source text.
    pub inline fn isOnNewLine(self: *const Parser) bool {
        if (self.tok_i == 0) return false;
        return self.newlines_ptr[self.tok_i];
    }

    // ────────────────────────────────────────────────────────────
    // Error recovery
    // ────────────────────────────────────────────────────────────

    /// Skip tokens until reaching a synchronization point:
    /// `;`, `}`, `eof`, or a statement-starting keyword.
    pub fn synchronize(self: *Parser) void {
        // If previous token was already a semicolon, we're past the boundary.
        if (self.tok_i > 0 and self.tokenTagAt(@intCast(self.tok_i - 1)) == .semicolon) return;

        // SIMD bulk-advance: skip 16 tokens at a time until a potential stop is
        // found.  The SoA tags array is a dense u8 sequence — exactly what SIMD
        // needs.  Two tests per chunk cover all synchronize() stop tokens:
        //   (1) structural: semicolon | r_brace | eof   (exact match)
        //   (2) keyword range: tag in [kw_break, kw_class] — covers all 19
        //       statement-starting keywords; false positives (kw_else, kw_new …)
        //       cause early stop, which is safe for error recovery.
        {
            const V = @Vector(16, u8);
            const raw: [*]const u8 = @ptrCast(self.tags_ptr);
            const lim = self.parsed_len;
            const v_semi:   V = @splat(@intFromEnum(TokenTag.semicolon));
            const v_rbrace: V = @splat(@intFromEnum(TokenTag.r_brace));
            const v_eof:    V = @splat(@intFromEnum(TokenTag.eof));
            const kw_lo:    V = @splat(@intFromEnum(TokenTag.kw_break));  // = 9
            const kw_hi:    V = @splat(@intFromEnum(TokenTag.kw_class));  // = 42
            var i = self.tok_i;
            while (i + 16 <= lim) {
                const chunk: V = raw[i..][0..16].*;
                const structural = (chunk == v_semi) | (chunk == v_rbrace) | (chunk == v_eof);
                const in_kw     = (chunk >= kw_lo) & (chunk <= kw_hi);
                if (@reduce(.Or, structural | in_kw)) break;
                i += 16;
            }
            self.tok_i = i;
        }

        // Scalar finish: exact semantics for each stop token.
        while (!self.isAtEnd()) {
            switch (self.peek()) {
                .semicolon => { _ = self.advance(); return; },
                .r_brace, .eof => return,
                .kw_var, .kw_let, .kw_const, .kw_function, .kw_class,
                .kw_if, .kw_while, .kw_for, .kw_do, .kw_return, .kw_throw,
                .kw_try, .kw_switch, .kw_break, .kw_continue, .kw_debugger,
                .kw_with, .kw_export, .kw_import,
                => return,
                else => _ = self.advance(),
            }
        }
    }

    /// Create an error_node at the current position.
    pub fn makeErrorNode(self: *Parser) !NodeIndex {
        return self.addNode(.{
            .tag = .error_node,
            .main_token = @intCast(self.tok_i),
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }

    /// Recovery helper: append a fresh error_node to the scratch stack.
    /// Used by statement / member-list loops after a `synchronize()` to keep
    /// a placeholder child so the surrounding list still produces a node.
    pub fn pushErrorNode(self: *Parser) !void {
        try self.scratchPush(try self.makeErrorNode());
    }

    /// Maximum recursive-descent nesting depth. Parsing pathologically nested
    /// input (e.g. thousands of nested `(`, `{`, type annotations, or JSX
    /// elements) would otherwise recurse until the native stack overflows and
    /// the process aborts. At this depth `enterRecursion` records a diagnostic
    /// and returns `error.ParseError` instead — recoverable like any other
    /// syntax error.
    ///
    /// Sized for headroom on a standard ~8 MiB stack even in unoptimized
    /// builds (~13 KiB/level measured in Debug → 400 levels ≈ 5 MiB; far more
    /// headroom in optimized builds), while staying well beyond the nesting
    /// depth of any real source.
    pub const max_recursion_depth: u16 = 400;

    /// Enter one level of recursive descent. Every successful call MUST be
    /// paired with `defer self.leaveRecursion();` at the call site. When the
    /// depth cap is reached this records a diagnostic and returns
    /// `error.ParseError` WITHOUT incrementing, so the (unpaired) error path
    /// never leaves the counter skewed.
    pub fn enterRecursion(self: *Parser) Error!void {
        if (self.recursion_depth >= max_recursion_depth) {
            try self.emitDiagnosticAtToken(self.tokIdx(), "maximum nesting depth ({d}) exceeded", .{max_recursion_depth});
            return error.ParseError;
        }
        self.recursion_depth += 1;
    }

    /// Leave one level of recursive descent. Pairs with `enterRecursion`.
    pub inline fn leaveRecursion(self: *Parser) void {
        self.recursion_depth -= 1;
    }

    // ────────────────────────────────────────────────────────────
    // Diagnostics
    // ────────────────────────────────────────────────────────────

    pub fn emitDiagnostic(
        self: *Parser,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        try self.diagnostics.append(self.gpa, .{
            .message = msg,
            .span = span,
            .severity = .@"error",
        });
    }

    pub fn emitDiagnosticAtToken(
        self: *Parser,
        token: TokenIndex,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const s = self.tokenStart(token);
        try self.emitDiagnostic(.{ .start = s, .end = s }, fmt, args);
    }

    /// Emit a `.warning`-severity diagnostic at a token. Unlike `emitDiagnostic`
    /// (which records `.@"error"`), this represents a suggestion that does NOT make
    /// the source unparseable — e.g. TS1540 (`module X {}` should use `namespace`).
    /// Consumers that gate on parse success must filter by severity; the AST is valid.
    pub fn emitWarningAtToken(
        self: *Parser,
        token: TokenIndex,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const s = self.tokenStart(token);
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        try self.diagnostics.append(self.gpa, .{
            .message = msg,
            .span = .{ .start = s, .end = s },
            .severity = .warning,
        });
    }

    // ────────────────────────────────────────────────────────────
    // Program / Top-level
    // ────────────────────────────────────────────────────────────

    /// Parse top-level statements/declarations until eof, build root node.
    pub fn parseProgram(self: *Parser) !void {
        // Root node must be index 0, matching the Zig compiler pattern.
        // Reserve the slot, fill in data after parsing.
        try self.nodes.append(self.gpa, .{
            .tag = .root,
            .main_token = 0,
            .data = .{ .lhs = .none, .rhs = .none },
        });

        // Skip hashbang if present
        if (self.peek() == .hashbang) {
            _ = self.advance();
        }

        // Detect "use strict" directive prologue
        self.checkDirectivePrologue();

        // Open module/global scope for event stream.
        //
        // ESLint's scope-manager creates two top-level scopes in two cases:
        //   • module mode: outer GLOBAL (builtins) + inner MODULE (user vars).
        //   • script mode + parserOptions.ecmaFeatures.globalReturn:
        //     outer GLOBAL (builtins) + inner FUNCTION (top-level wrapped).
        // Mirror that hierarchy so rules walking `scope.upper` (no-shadow,
        // no-redeclare with builtinGlobals, no-implicit-globals's
        // user-decl-vs-global classification) see the expected structure.
        // The wrapper holds no declarations at parse time — JS-side scope
        // building populates builtins / config globals at scope-construction.
        const needs_wrapper = self.is_module or self.global_return;
        const ScopeKind = @import("scope.zig").ScopeKind;
        const inner_kind: ScopeKind = if (self.is_module) .module
            else if (self.global_return) .function
            else .global;
        const wrapper_global_ev: u32 = if (needs_wrapper)
            try self.emitScopeOpen(.global, .root)
        else
            0;
        const program_scope_ev = try self.emitScopeOpen(inner_kind, .root);
        // Streaming: publish the initial scope_open immediately so a concurrent
        // sem thread sees the global code path before any other events.
        if (self.events_publish_to) |p| p.store(self.ev_len, .release);

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var consecutive_errors: u32 = 0;
        while (!self.isAtEnd()) {
            const before = self.tok_i;
            const stmt = self.parseStatement() catch |err| switch (err) {
                error.ParseError => {
                    consecutive_errors += 1;
                    // Bail out after too many consecutive errors to avoid OOM
                    if (consecutive_errors > 100) {
                        while (!self.isAtEnd()) _ = self.advance();
                        break;
                    }
                    self.synchronize();
                    // Guarantee forward progress — if synchronize didn't advance,
                    // skip one token to avoid infinite loop on unrecoverable input.
                    if (self.tok_i == before) _ = self.advance();
                    try self.pushErrorNode();
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            consecutive_errors = 0; // reset on successful parse
            try self.scratchPush(stmt);
            // 3-stage pipeline: publish current event count so the sem thread
            // can consume up to here. Coarse-grained (per top-level statement)
            // — the consumer's hot path doesn't pay any per-event sync cost.
            if (self.events_publish_to) |p| p.store(self.ev_len, .release);
        }

        const stmts = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(stmts);

        // Fill in root node data: lhs/rhs encode SubRange start/end.
        const root_data = Node.Data{
            .lhs = NodeIndex.fromInt(range.start),
            .rhs = NodeIndex.fromInt(range.end),
        };
        self.node_data_ptr[0] = root_data;
        self.node_end_toks[0] = if (self.tok_i > 0) @intCast(self.tok_i - 1) else 0;

        // Validate that named exports without 'from' refer to declared bindings.
        // Spec: It is a SyntaxError if any element of ExportedBindings does
        // not also occur in either VarDeclaredNames or LexicallyDeclaredNames.
        // O(N+E) vs naive O(N×E): N can be 400+ on large bundles like angular-core.mjs.
        if (self.is_module and self.pending_export_local_toks.items.len > 0 and
            self.emit_scope_events)
        {
            var decl_names = std.StringHashMapUnmanaged(void){};
            defer decl_names.deinit(self.gpa);
            {
                const evs_ee = self.ev_ptr[0..self.ev_len][program_scope_ev + 1 ..];
                var fn_stack: [128]bool = undefined;
                var stack_n: usize = 0;
                var fn_d: i32 = 0;
                for (evs_ee) |ev| {
                    switch (ev.kind) {
                        .scope_open => if (ev.aux != @intFromEnum(ScopeKindU8.elided)) {
                            const sk: ScopeKindU8 = @enumFromInt(ev.aux);
                            const is_fn = (sk == .function or sk == .class_field_initializer or sk == .static_block);
                            if (stack_n < fn_stack.len) fn_stack[stack_n] = is_fn;
                            stack_n += 1;
                            if (is_fn) fn_d += 1;
                        },
                        .scope_close => {
                            if (stack_n > 0) {
                                stack_n -= 1;
                                if (stack_n < fn_stack.len and fn_stack[stack_n]) fn_d -= 1;
                            }
                        },
                        .declare => {
                            const bk: BindingKindU8 = @enumFromInt(ev.aux);
                            const is_var_at_module = (bk == .@"var" and fn_d == 0);
                            if (stack_n == 0 or is_var_at_module) {
                                const dn_tok = self.node_main_token_ptr[@intCast(ev.node)];
                                try decl_names.put(self.gpa, self.tokenText(dn_tok), {});
                            }
                        },
                        else => {},
                    }
                }
            }
            for (self.pending_export_local_toks.items) |tok_idx| {
                const want = self.tokenText(tok_idx);
                if (!decl_names.contains(want) and !self.is_ts) {
                    const span = Span{ .start = self.tok_starts_ptr[tok_idx], .end = self.tok_starts_ptr[tok_idx] };
                    try self.emitDiagnostic(span, "Export '{s}' is not declared in the module", .{want});
                    return;
                }
            }
        }

        // Top-level lexical redeclaration check (mirror of block-scope logic).
        if (self.emit_scope_events) {
            const evs = self.ev_ptr[0..self.ev_len][program_scope_ev + 1 ..];
            var depth: i32 = 0;
            const Entry = struct { name: []const u8, kind: BindingKindU8, fn_flavor: u32 };
            var names_buf: [128]Entry = undefined;
            var names_n: usize = 0;
            var var_names_buf: [128][]const u8 = undefined;
            var var_names_n: usize = 0;
            const allow_fn_dup = !self.is_module and !self.in_strict and self.annex_b;
            for (evs) |ev| {
                // Guard against corrupt events: reading past the live event count
                // can land on uninitialized memory (an arena/GPA hands back dirty
                // reused blocks; only page_allocator zero-fills). Skip an event
                // whose kind byte isn't a valid EventKind OR whose node index is
                // out of range — the latter otherwise feeds a garbage index into
                // node_main_token_ptr[...] below → tok_starts_ptr[huge] → segfault
                // (ReleaseFast only; the value is benign zero under zeroed pages).
                const ev_kind_int = @intFromEnum(ev.kind);
                if (ev_kind_int >= meta_compat.fieldCount(ScopeEventKind)) continue;
                if (@as(usize, @intCast(ev.node)) >= self.nodes.len) continue;
                switch (ev.kind) {
                    .scope_open => if (ev.aux != @intFromEnum(ScopeKindU8.elided)) { depth += 1; },
                    .scope_close => depth -= 1,
                    .declare => if (depth == 0) {
                        const bk: BindingKindU8 = @enumFromInt(ev.aux);
                        // Collect var and function_decl names for lex-var conflict check.
                        // In modules: var bindings conflict with lex bindings.
                        // In scripts: var bindings AND function decls (which hoist as var)
                        // conflict with lex bindings (let/const/class).
                        // Annex B B.3.3 exemption: a sloppy function in an if/label body
                        // (`function_decl_annex_b`) whose hoisted name would clash with a
                        // lexical binding has that hoist suppressed and the early error
                        // skipped — so it does not contribute a conflicting var-name.
                        if (!self.is_ts and (bk == .@"var" or
                            (!self.is_module and (bk == .function_decl or
                                (bk == .function_decl_annex_b and !allow_fn_dup)))))
                        {
                            const vt = self.node_main_token_ptr[@intCast(ev.node)];
                            const vs = self.tok_starts_ptr[vt];
                            const vl = self.tok_lens_ptr[vt];
                            if (vs + vl <= self.source.len and var_names_n < var_names_buf.len) {
                                var_names_buf[var_names_n] = self.source[vs..vs + vl];
                                var_names_n += 1;
                            }
                        }
                        if (bk == .@"var" or bk == .parameter) continue;
                        // Sloppy script top-level: function decls hoist as var-bindings;
                        // any flavor pair coexists. Module: strict lexical check applies.
                        if (!self.is_module and (bk == .function_decl or bk == .function_decl_annex_b)) continue;
                        // TypeScript allows duplicate declarations (overloads, namespace merging).
                        if (self.is_ts) continue;
                        const main_tok_idx = self.node_main_token_ptr[@intCast(ev.node)];
                        const tok_start = self.tok_starts_ptr[main_tok_idx];
                        const tok_len = self.tok_lens_ptr[main_tok_idx];
                        if (tok_start + tok_len > self.source.len) continue;
                        const name = self.source[tok_start..tok_start + tok_len];
                        const is_fn_decl = bk == .function_decl or bk == .function_decl_annex_b;
                        const flavor: u32 = if (is_fn_decl) self.classifyFnDeclFlavor(main_tok_idx) else 0;
                        var dup = false;
                        for (names_buf[0..names_n]) |existing| {
                            if (!std.mem.eql(u8, existing.name, name)) continue;
                            const ex_is_fn = existing.kind == .function_decl or existing.kind == .function_decl_annex_b;
                            if (allow_fn_dup and ex_is_fn and is_fn_decl
                                and existing.fn_flavor == 0 and flavor == 0) continue;
                            dup = true;
                            break;
                        }
                        if (dup) {
                            try self.emitDiagnostic(self.currentSpan(),
                                "Identifier '{s}' has already been declared", .{name});
                        } else if (names_n < names_buf.len) {
                            names_buf[names_n] = .{ .name = name, .kind = bk, .fn_flavor = flavor };
                            names_n += 1;
                        }
                    },
                    else => {},
                }
            }
            // Lex-vs-var conflict check for both script and module top level.
            // Script: LexicallyDeclaredNames(ScriptBody) ∩ VarDeclaredNames(ScriptBody) must be empty.
            // Module: LexicallyDeclaredNames(ModuleItemList) ∩ VarDeclaredNames(ModuleItemList) must be empty.
            if (!self.is_ts and names_n > 0 and var_names_n > 0) {
                for (names_buf[0..names_n]) |lex_entry| {
                    for (var_names_buf[0..var_names_n]) |var_name| {
                        if (std.mem.eql(u8, lex_entry.name, var_name)) {
                            try self.emitDiagnostic(self.currentSpan(),
                                "Identifier '{s}' has already been declared", .{lex_entry.name});
                            break;
                        }
                    }
                }
            }
        }

        // Duplicate __proto__ in object literals (not patterns) is a SyntaxError.
        // proto_check_nodes holds only the nodes created as object_literal during
        // parsing. Nodes reinterpreted by reinterpretAsPattern will have been
        // retagged to object_pattern — the tag guard below skips those.
        for (self.proto_check_nodes.items) |ni| {
            if (self.node_tags_ptr[ni] != .object_literal) continue;
            const data = self.node_data_ptr[ni];
            const start = data.lhs.toInt();
            const end = data.rhs.toInt();
            var seen_proto = false;
            var i = start;
            while (i < end) : (i += 1) {
                const child = NodeIndex.fromInt(self.extra_data.items[i]);
                if (child == .none) continue;
                if (self.node_tags_ptr[child.toInt()] != .property) continue;
                const cd = self.node_data_ptr[child.toInt()];
                const key = cd.lhs;
                if (key == .none) continue;
                const key_tag = self.node_tags_ptr[key.toInt()];
                var is_proto = false;
                if (key_tag == .identifier) {
                    const tok = self.node_main_token_ptr[key.toInt()];
                    if (self.tokenTagAt(tok) != .hash and std.mem.eql(u8, self.tokenText(tok), "__proto__")) is_proto = true;
                } else if (key_tag == .string_literal) {
                    const tok = self.node_main_token_ptr[key.toInt()];
                    const tok_start = self.tok_starts_ptr[tok];
                    const text = self.getStringContent(tok_start);
                    if (std.mem.eql(u8, text, "__proto__")) is_proto = true;
                }
                if (is_proto) {
                    if (seen_proto) {
                        try self.emitDiagnostic(self.currentSpan(), "Duplicate __proto__ fields are not allowed in object literals", .{});
                        break;
                    }
                    seen_proto = true;
                }
            }
        }

        // Close module/global scope for event stream.
        try self.emitScopeClose(.root);
        // Close the synthetic global wrapper for module / globalReturn modes.
        if (needs_wrapper) {
            _ = wrapper_global_ev;
            try self.emitScopeClose(.root);
        }
    }

    // ────────────────────────────────────────────────────────────
    // Statement parsers
    // ────────────────────────────────────────────────────────────

    /// Dispatch to the correct statement/declaration parser based on the
    /// current token.
    pub fn parseStatement(self: *Parser) Error!NodeIndex {
        try self.enterRecursion();
        defer self.leaveRecursion();
        const tag = self.peek();

        // Fast path: identifier is the most common statement-starting token.
        // Skip the TS dispatch and main switch entirely.
        if (tag == .identifier) {
            @branchHint(.likely);
            // 'using x = ...' — Explicit Resource Management (ES2025)
            if (self.tok_lens_ptr[self.tok_i] == 5) {
                const text = self.tokenText(@intCast(self.tok_i));
                const next_using = self.peekAt(1);
                // No LineTerminator may appear between `using` and its binding list.
                const no_nl_before_binding = !self.newlines_ptr[self.tok_i + 1];
                if (std.mem.eql(u8, text, "using") and no_nl_before_binding and
                    (next_using == .identifier or next_using == .escaped_keyword or
                    next_using == .kw_await or next_using == .kw_yield or
                    next_using == .kw_of or next_using == .kw_let))
                {
                    return self.parseUsingDeclaration(false);
                }
            }
            // TypeScript `global { ... }` — global augmentation block
            if (self.is_ts and self.tok_lens_ptr[self.tok_i] == 6 and self.peekAt(1) == .l_brace) {
                const text = self.tokenText(@intCast(self.tok_i));
                if (std.mem.eql(u8, text, "global")) {
                    _ = self.advance(); // eat 'global'
                    const prev_is_module = self.is_module;
                    const prev_in_block = self.in_block;
                    const prev_ts_ns = self.in_ts_namespace;
                    self.is_module = true;
                    self.in_block = false;
                    self.in_ts_namespace = true;
                    const body = try self.parseBlockStatement();
                    self.is_module = prev_is_module;
                    self.in_block = prev_in_block;
                    self.in_ts_namespace = prev_ts_ns;
                    return body;
                }
            }
            return self.parseExprOrLabeledStatement();
        }

        // Fast paths for the most frequent non-identifier statement starters.
        // These tokens are not in the TS dispatch switch, so we can skip both
        // the is_ts check and the main switch lookup for the common cases.
        // (kw_function is the dominant statement type in deeply-nested TS files.)
        if (tag == .kw_function) return self.parseFunctionDeclaration();
        if (tag == .kw_return) return self.parseReturnStatement();
        if (tag == .kw_if) return self.parseIfStatement();

        // TypeScript declaration dispatch
        if (self.is_ts) {
            switch (tag) {
                .kw_interface => {
                    // `interface Name` is a TS declaration; standalone `interface` is an expression
                    // In TS, keywords like void/never/unknown are valid interface names
                    const iface_p1 = self.peekAt(1);
                    if (iface_p1 == .identifier or iface_p1.isKeyword()) {
                        return typescript.parseInterfaceDeclaration(self);
                    }
                },
                .kw_type => {
                    const type_p1 = self.peekAt(1);
                    // Only parse as type alias if NO newline between `type` and the name,
                    // OR if we're in an ambient/declare context (where TS1142 will be emitted).
                    // ASI: `type\nFoo` in script context is an expression statement.
                    const no_nl_before_name = !self.newlines_ptr[self.tok_i + 1];
                    if ((type_p1 == .identifier or type_p1.isKeyword()) and
                        (no_nl_before_name or self.in_ts_ambient))
                    {
                        return typescript.parseTypeAliasDeclaration(self);
                    }
                },
                .kw_namespace => {
                    const ns_p1 = self.peekAt(1);
                    if (ns_p1 == .identifier or ns_p1 == .string_literal) {
                        return typescript.parseNamespaceDeclaration(self);
                    }
                },
                .kw_module => {
                    const mod_p1 = self.peekAt(1);
                    if (mod_p1 == .identifier or mod_p1 == .string_literal) {
                        return typescript.parseModuleDeclaration(self);
                    }
                },
                .kw_enum => {
                    return typescript.parseEnumDeclaration(self);
                },
                .kw_declare => {
                    // `declare` modifies the next declaration — skip it and parse.
                    // Guard: only if followed by an actual declaration keyword.
                    const next = self.peekAt(1);
                    if (next == .kw_var or next == .kw_let or next == .kw_const or
                        next == .kw_function or next == .kw_class or next == .kw_enum or
                        next == .kw_interface or next == .kw_type or next == .kw_namespace or
                        next == .kw_module or next == .kw_abstract or
                        (next == .kw_export and self.in_ts_ambient))
                    {
                        // TS1038: TypeScript emits this when 'declare' appears in an already-ambient
                        // context. We skip this check — it is a semantic error, not a parse error.
                        // TS1184: Modifiers cannot appear here (declare inside a non-namespace block).
                        if (self.is_ts and (self.in_block or self.in_function or self.in_loop or self.in_switch) and !self.in_ts_namespace) {
                            try self.emitDiagnostic(self.currentSpan(), "Modifiers cannot appear here", .{});
                        }
                        _ = self.advance();
                        const prev_ambient = self.in_ts_ambient;
                        self.in_ts_ambient = true;
                        defer self.in_ts_ambient = prev_ambient;
                        return self.parseStatement();
                    }
                    // `declare global { ... }` — global augmentation
                    if (self.is_ts and next == .identifier and
                        std.mem.eql(u8, self.tokenText(@intCast(self.tok_i + 1)), "global"))
                    {
                        _ = self.advance(); // eat 'declare'
                        _ = self.advance(); // eat 'global'
                        const prev_is_module = self.is_module;
                        const prev_in_block = self.in_block;
                        const prev_ambient = self.in_ts_ambient;
                        const prev_ts_ns = self.in_ts_namespace;
                        self.is_module = true;
                        self.in_block = false;
                        self.in_ts_ambient = true;
                        self.in_ts_namespace = true;
                        const body = try self.parseBlockStatement();
                        self.is_module = prev_is_module;
                        self.in_block = prev_in_block;
                        self.in_ts_ambient = prev_ambient;
                        self.in_ts_namespace = prev_ts_ns;
                        return body;
                    }
                    // TS1120: `declare export = x` — export assignment cannot have modifiers.
                    if (self.is_ts and next == .kw_export and self.peekAt(2) == .equal) {
                        try self.emitDiagnostic(self.currentSpan(), "An export assignment cannot have modifiers", .{});
                        return error.ParseError;
                    }
                    // Not a valid declare target — fall through to expression statement
                },
                .kw_abstract => {
                    if (self.peekAt(1) == .kw_class) {
                        _ = self.advance(); // skip 'abstract'
                        return self.parseClassDeclaration();
                    }
                },
                else => {},
            }
        }

        switch (tag) {
            .l_brace => return self.parseBlockStatement(),
            .semicolon => return self.parseEmptyStatement(),
            .kw_if => return self.parseIfStatement(),
            .kw_while => return self.parseWhileStatement(),
            .kw_do => return self.parseDoWhileStatement(),
            .kw_for => return self.parseForStatement(),
            .kw_switch => return self.parseSwitchStatement(),
            .kw_return => return self.parseReturnStatement(),
            .kw_throw => return self.parseThrowStatement(),
            .kw_break => return self.parseBreakStatement(),
            .kw_continue => return self.parseContinueStatement(),
            .kw_try => return self.parseTryStatement(),
            .kw_debugger => return self.parseDebuggerStatement(),
            .kw_with => return self.parseWithStatement(),
            .kw_var => return self.parseVariableDeclaration(),
            .kw_const => {
                // TS `const enum` declaration
                if (self.is_ts and self.peekAt(1) == .kw_enum) {
                    _ = self.advance(); // eat 'const'
                    return typescript.parseEnumDeclaration(self);
                }
                return self.parseVariableDeclaration();
            },
            .kw_let => {
                // In non-strict mode, `let` is only a declaration keyword when followed
                // (without a newline) by an identifier, `[`, or `{`.
                // With a newline, ASI kicks in and `let` is an identifier expression.
                // In strict mode or TypeScript mode, `let` is always a declaration keyword.
                if (self.in_strict or self.is_ts) return self.parseVariableDeclaration();
                const next = self.peekAt(1);
                // Only check for binding start tokens; skip newline check for non-ambiguous tokens
                const could_be_binding = next == .l_bracket or next == .l_brace or
                    next == .identifier or next == .escaped_keyword or
                    // Contextual keywords that can be binding names, but NOT
                    // reserved words that follow `let` as operators (instanceof, in, etc.)
                    next == .kw_yield or next == .kw_await or next == .kw_async or
                    next == .kw_of or next == .kw_from or next == .kw_as or
                    next == .kw_get or next == .kw_set or next == .kw_let or
                    next == .kw_static or next == .kw_type or next == .kw_declare or
                    next == .kw_namespace or next == .kw_module or next == .kw_interface or
                    next == .kw_abstract or next == .kw_readonly or next == .kw_override or
                    next == .kw_implements or next == .kw_target or next == .kw_meta;
                if (could_be_binding) {
                    if (!self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                        return self.parseVariableDeclaration();
                    }
                    // With newline: `let\n{...} =` is still a destructuring declaration
                    // because `{...} = expr` has no valid parse as block + assignment.
                    if (next == .l_brace and self.looksLikeLetDestructuring()) {
                        return self.parseVariableDeclaration();
                    }
                    // Per spec: `let\nlet`, `let\nyield` (in generator), `let\nawait`
                    // (in async) match LexicalDeclaration; ASI does not apply. These
                    // produce SyntaxError via static-semantics early errors.
                    if (next == .kw_let) return self.parseVariableDeclaration();
                    if (next == .kw_yield and self.in_generator) return self.parseVariableDeclaration();
                    if (next == .kw_await and (self.in_async or self.is_module)) return self.parseVariableDeclaration();
                }
                return self.parseExprOrLabeledStatement();
            },
            .kw_function => return self.parseFunctionDeclaration(),
            .kw_class => return self.parseClassDeclaration(),
            .at_sign => {
                // Decorator: @expr class ...
                while (self.peek() == .at_sign) {
                    _ = self.advance(); // eat @
                    _ = try self.parseAssignmentExpression(); // decorator expression
                }
                const after_deco = self.peek();
                if (after_deco == .kw_class) {
                    return self.parseClassDeclaration();
                }
                if (after_deco == .kw_export) {
                    return self.parseExportDeclaration();
                }
                // TS1206: decorators are not valid on function declarations
                if (self.is_ts and (after_deco == .kw_function or
                    (after_deco == .kw_async and self.peekAt(1) == .kw_function)))
                {
                    try self.emitDiagnostic(self.currentSpan(), "Decorators are not valid here", .{});
                }
                if (after_deco == .kw_abstract and self.peekAt(1) == .kw_class) {
                    _ = self.advance(); // eat abstract
                    return self.parseClassDeclaration();
                }
                // A statement-level decorator must decorate a class declaration.
                // Any other follower is a grammar error in TypeScript (TS1146
                // "Declaration expected"); the `function` case already emitted the
                // more specific TS1206 just above, so exclude it here.
                if (self.is_ts and after_deco != .kw_function and
                    !(after_deco == .kw_async and self.peekAt(1) == .kw_function))
                {
                    try self.emitDiagnostic(self.currentSpan(), "Declaration expected", .{});
                }
                return self.parseExpressionStatement();
            },
            .kw_import => {
                // import.meta and import() are expressions, not declarations
                const imp_p1 = self.peekAt(1);
                if (imp_p1 == .dot or imp_p1 == .l_paren) {
                    return self.parseExpressionStatement();
                }
                if (!self.is_module) {
                    try self.emitDiagnostic(self.currentSpan(), "import declarations require module mode", .{});
                } else if (!self.is_ts and (self.in_block or self.in_function or self.in_loop or self.in_switch)) {
                    try self.emitDiagnostic(self.currentSpan(), "import declarations must be at top level", .{});
                }
                return self.parseImportDeclaration();
            },
            .kw_export => {
                if (!self.is_module) {
                    try self.emitDiagnostic(self.currentSpan(), "export declarations require module mode", .{});
                } else if (self.in_function) {
                    // export inside a function body is always invalid (TS1184)
                    try self.emitDiagnostic(self.currentSpan(), "export declarations must be at top level", .{});
                } else if (self.is_ts and (self.in_block or self.in_loop or self.in_switch) and !self.in_ts_namespace) {
                    // In TS mode, export inside a plain block (not a namespace body) is TS1184.
                    try self.emitDiagnostic(self.currentSpan(), "export declarations must be at top level", .{});
                } else if (!self.is_ts and (self.in_block or self.in_loop or self.in_switch)) {
                    // In non-TS mode, export inside any non-module context is invalid.
                    try self.emitDiagnostic(self.currentSpan(), "export declarations must be at top level", .{});
                }
                return self.parseExportDeclaration();
            },
            .kw_async => {
                // `async function` declaration
                if (self.peekAt(1) == .kw_function and !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                    return self.parseFunctionDeclaration();
                }
                // Otherwise fall through to expression statement
                return self.parseExprOrLabeledStatement();
            },
            .kw_await => {
                // `await using x = ...` — Explicit Resource Management (ES2025)
                if (self.peekAt(1) == .identifier and
                    std.mem.eql(u8, self.tokenText(@intCast(self.tok_i + 1)), "using"))
                {
                    const tok2 = self.peekAt(2);
                    if (tok2 == .identifier) {
                        return self.parseUsingDeclaration(true);
                    }
                    // `await using [...]` / `await using {...}`: fall through to expression
                    // parsing. `await using[x]` must parse as `await (using[x])` when
                    // `using` is a variable name (explicit-resource-management spec).
                }
                // Outside async/module, `await` is a regular identifier (can be label)
                if (!self.in_async and !self.is_module) {
                    return self.parseExprOrLabeledStatement();
                }
                return self.parseExpressionStatement();
            },
            // yield outside generators is a regular identifier (can be label, expression, etc.)
            .kw_yield => {
                if (!self.in_generator and !self.in_strict) {
                    return self.parseExprOrLabeledStatement();
                }
                return self.parseExpressionStatement();
            },
            // .identifier is handled by the fast path above; only .escaped_keyword
            // reaches here (contextual keywords encoded as escaped).
            .escaped_keyword => {
                return self.parseExprOrLabeledStatement();
            },
            else => return self.parseExpressionStatement(),
        }
    }

    /// Parse statements until `end_tag`, return SubRange of statement node indices.
    pub fn parseStatementList(self: *Parser, end_tag: TokenTag) Error!SubRange {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var consecutive_errors: u32 = 0;
        while (true) {
            const cur = self.peek();
            if (cur == end_tag or cur == .eof) break;
            const before = self.tok_i;
            const stmt = self.parseStatement() catch |err| switch (err) {
                error.ParseError => {
                    consecutive_errors += 1;
                    if (consecutive_errors > 100) {
                        // Skip remaining tokens in this block to avoid OOM
                        while (true) {
                            const t = self.peek();
                            if (t == end_tag or t == .eof) break;
                            _ = self.advance();
                        }
                        break;
                    }
                    self.synchronize();
                    if (self.tok_i == before) _ = self.advance();
                    try self.pushErrorNode();
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            consecutive_errors = 0;
            try self.scratchPush(stmt);
        }

        const stmts = self.scratch.items[scratch_top..];
        return self.listToSubRange(stmts);
    }

    /// Parse `{ ... }`.
    /// Classify a FunctionDeclaration's flavor by inspecting tokens around its name.
    /// Only plain (non-async, non-generator) FunctionDeclaration enjoys B.3.2 legacy semantics.
    pub fn classifyFnDeclFlavor(self: *Parser, name_tok: TokenIndex) u32 {
        // 0 = plain, 1 = async, 2 = generator, 3 = async-generator
        var t: i64 = @intCast(name_tok);
        while (t >= 0 and self.tokenTagAt(@intCast(t)) != .kw_function) : (t -= 1) {}
        if (t < 0) return 0;
        const fn_tok: TokenIndex = @intCast(t);
        const is_gen = self.tokenExists(fn_tok + 1) and self.tokenTagAt(fn_tok + 1) == .asterisk;
        const is_async = fn_tok > 0 and self.tokenTagAt(fn_tok - 1) == .kw_async;
        return (if (is_async) @as(u32, 1) else 0) | (if (is_gen) @as(u32, 2) else 0);
    }

    pub fn parseBlockStatement(self: *Parser) Error!NodeIndex {
        const lbrace = try self.expect(.l_brace);
        const prev_in_block = self.in_block;
        self.in_block = true;
        defer self.in_block = prev_in_block;
        const prev_in_case_clause = self.in_case_clause;
        self.in_case_clause = false;
        defer self.in_case_clause = prev_in_case_clause;
        // Save and reset the block declaration flag. Nested parseBlockStatement calls
        // save/restore their own copy, so this flag tracks only direct declarations in
        // THIS block. After parsing, block_has_lexical_decl = true means keep the scope.
        const prev_block_has_lexical_decl = self.block_has_lexical_decl;
        self.block_has_lexical_decl = false;
        defer self.block_has_lexical_decl = prev_block_has_lexical_decl;
        // Incremental dup-detection: save depth/scratch-top so nested blocks can
        // reuse the same buffer without interfering with this block's window.
        // Set block_dup_depth = -1 so that the imminent emitScopeOpen brings it to 0,
        // meaning only direct (depth-0) declares are recorded for THIS block.
        const use_scratch = self.emit_scope_events and !self.is_ts;
        const prev_block_dup_depth = self.block_dup_depth;
        const block_decl_top = self.block_decl_scratch.items.len;
        if (use_scratch) self.block_dup_depth = -1;
        defer if (use_scratch) { self.block_dup_depth = prev_block_dup_depth; };
        defer if (use_scratch) { self.block_decl_scratch.shrinkRetainingCapacity(block_decl_top); };
        const scope_ev = try self.emitScopeOpen(.block, .none);
        // Capture FunctionBody flag BEFORE parsing inner statements — nested
        // parseBlockStatement calls would otherwise consume it.
        const is_fn_body = self.is_fn_body_block;
        self.is_fn_body_block = false;
        const range = try self.parseStatementList(.r_brace);
        _ = try self.expect(.r_brace);

        // Always keep block scopes so reference.from === variable.scope
        // matches eslint-scope semantics. ESLint creates a block scope
        // for every BlockStatement (ES6+) regardless of declarations;
        // rules like prefer-const compare reference.from to declaration
        // scope identity to decide whether a write counts as a
        // reassignment in the same scope. Eliding empty block scopes
        // collapsed bare-block writes onto the parent scope so the
        // identity check spuriously matched.
        //
        // The duplicate-name dup check below still runs only when
        // block_has_lexical_decl is set — that's a separate validation,
        // unrelated to scope identity.
        var keep_scope: bool = true;
        if (self.emit_scope_events) {
            const has_decl = self.block_has_lexical_decl;
            if (!has_decl or self.is_ts) {
                // No dup check needed — but we still keep the scope.
                keep_scope = true;
            } else {
                // JS mode with block-level declarations: use incremental scratch
                // for dup detection. block_decl_scratch.items[block_decl_top..] holds
                // all depth-0 declares emitted during parseStatementList above —
                // no event-stream scan needed.
                keep_scope = true;
                const Entry = struct { name: []const u8, kind: BindingKindU8, fn_flavor: u32 };
                var names_buf: [64]Entry = undefined;
                var names_n: usize = 0;
                const allow_fn_dup = !self.is_module and !self.in_strict and self.annex_b;
                for (self.block_decl_scratch.items[block_decl_top..]) |scratch_entry| {
                    const main_tok_idx: TokenIndex = @truncate(scratch_entry >> 32);
                    const bk: BindingKindU8 = @enumFromInt(@as(u8, @truncate(scratch_entry)));
                    // FunctionBody: function decls skip redecl check (TopLevelLexicallyDeclaredNames).
                    if (is_fn_body and (bk == .function_decl or bk == .function_decl_annex_b)) continue;
                    const tok_start = self.tok_starts_ptr[main_tok_idx];
                    const tok_len = self.tok_lens_ptr[main_tok_idx];
                    if (tok_start + tok_len > self.source.len) continue;
                    const name = self.source[tok_start..tok_start + tok_len];
                    const flavor: u32 = if (bk == .function_decl or bk == .function_decl_annex_b) self.classifyFnDeclFlavor(main_tok_idx) else 0;
                    var dup = false;
                    for (names_buf[0..names_n]) |existing| {
                        if (!std.mem.eql(u8, existing.name, name)) continue;
                        // B.3.3: in sloppy script, only plain FunctionDeclaration pairs are allowed.
                        if (allow_fn_dup and (existing.kind == .function_decl or existing.kind == .function_decl_annex_b) and
                            (bk == .function_decl or bk == .function_decl_annex_b)
                            and existing.fn_flavor == 0 and flavor == 0) continue;
                        // AnnexB B.3.2.1: in sloppy mode, when fn-decl nested in
                        // IfStatement/LabelledStatement body conflicts with prior
                        // let/const/class at the same block scope, the AnnexB
                        // extension is "not applied" — no early error.
                        if (allow_fn_dup and bk == .function_decl_annex_b and
                            (existing.kind == .let or existing.kind == .@"const" or existing.kind == .class_decl))
                        {
                            continue;
                        }
                        if (allow_fn_dup and existing.kind == .function_decl_annex_b and
                            (bk == .let or bk == .@"const" or bk == .class_decl))
                        {
                            continue;
                        }
                        dup = true;
                        break;
                    }
                    if (dup) {
                        try self.emitDiagnostic(self.currentSpan(),
                            "Identifier '{s}' has already been declared", .{name});
                    } else if (names_n < names_buf.len) {
                        names_buf[names_n] = .{ .name = name, .kind = bk, .fn_flavor = flavor };
                        names_n += 1;
                    }
                }

                // Check lex names against var names (lex-var conflict).
                // Spec rule: "It is a Syntax Error if any element of the
                // LexicallyDeclaredNames of StatementList also occurs in the
                // VarDeclaredNames of StatementList." AnnexB has no exception to
                // this specific rule (function decls ARE lexically declared in blocks).
                if (names_n > 0 and !self.is_ts) {
                    var var_names_buf: [128][]const u8 = undefined;
                    var var_names_n: usize = 0;
                    collectVarNamesInRange(self, range.start, range.end, &var_names_buf, &var_names_n);
                    for (names_buf[0..names_n]) |lex_entry| {
                        for (var_names_buf[0..var_names_n]) |var_name| {
                            if (std.mem.eql(u8, lex_entry.name, var_name)) {
                                try self.emitDiagnostic(self.currentSpan(),
                                    "Identifier '{s}' has already been declared", .{lex_entry.name});
                                break;
                            }
                        }
                    }
                }
            }
        }

        if (keep_scope) {
            try self.emitScopeClose(.none);
        } else if (self.emit_scope_events) {
            self.ev_ptr[scope_ev].aux = @intFromEnum(ScopeKindU8.elided);
            self.elided_scope_count += 1;
        }

        const node = try self.addNode(.{
            .tag = .block_stmt,
            .main_token = lbrace,
            .data = .{
                .lhs = NodeIndex.fromInt(range.start),
                .rhs = NodeIndex.fromInt(range.end),
            },
        });
        if (keep_scope) self.patchScopeOpenNode(scope_ev, node);
        return node;
    }

    /// Parse `;`.
    pub fn parseEmptyStatement(self: *Parser) !NodeIndex {
        const semi = self.advance();
        // TS1036: Statements are not allowed in ambient contexts.
        if (self.is_ts and self.in_ts_ambient) {
            try self.emitDiagnostic(self.currentSpan(), "Statements are not allowed in ambient contexts", .{});
        }
        return self.addNode(.{
            .tag = .empty_stmt,
            .main_token = semi,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }

    /// Parse expression followed by semicolon.
    pub fn parseExpressionStatement(self: *Parser) Error!NodeIndex {
        const main_tok: u32 = self.tokIdx();
        const expr = try self.parseExpression();

        // Check for CoverInitializedName ({a = 0}) in expression context.
        // Valid only as destructuring target (LHS of =), not as expression.
        if (expr != .none) {
            const expr_tag = self.node_tags_ptr[expr.toInt()];
            if (expr_tag == .assign) {
                // LHS is destructuring target (valid), check only RHS
                const data = self.node_data_ptr[expr.toInt()];
                self.checkCoverInitializedNameFast(data.rhs);
            } else if (tagNeedsCoverCheck(expr_tag)) {
                // Use already-loaded tag to skip redundant read in checkCoverInitializedNameFast
                self.checkCoverInitializedName(expr);
            }
        }

        try self.expectSemicolon();
        return self.addNode(.{
            .tag = .expression_stmt,
            .main_token = main_tok,
            .data = .{ .lhs = expr, .rhs = .none },
        });
    }

    /// Disambiguate between labeled statement and expression statement
    /// when the current token is an identifier.
    pub fn parseExprOrLabeledStatement(self: *Parser) Error!NodeIndex {
        // Check for label: `identifier :` (includes contextual keywords used as labels)
        const is_label_start = self.peekAt(1) == .colon and switch (self.peek()) {
            .identifier, .kw_yield, .kw_await, .kw_let, .kw_static,
            .kw_get, .kw_set, .kw_of, .kw_from, .kw_as, .escaped_keyword,
            => true,
            else => false,
        };
        if (is_label_start) {
            return self.parseLabeledStatement();
        }
        return self.parseExpressionStatement();
    }

    /// Parse a statement that is NOT a function/class/generator declaration.
    /// Used for single-statement bodies of if/while/for/with where the spec
    /// forbids declarations.
    fn parseNonDeclStatement(self: *Parser) Error!NodeIndex {
        switch (self.peek()) {
            .kw_function => {
                try self.emitDiagnostic(self.currentSpan(), "function declaration not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_class => {
                try self.emitDiagnostic(self.currentSpan(), "class declaration not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_const => {
                if (self.is_ts and self.peekAt(1) == .kw_enum) return self.parseStatement();
                try self.emitDiagnostic(self.currentSpan(), "lexical declaration not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_let => {
                // `let` as a declaration is not allowed in single-statement context.
                // In non-strict, `let` followed by newline or non-binding token is an identifier.
                if (!self.in_strict) {
                    const next = self.peekAt(1);
                    // `let [` is forbidden regardless of newline: either a lex decl (not allowed
                    // here) or an ExpressionStatement starting with `let [` (also forbidden by
                    // the ExpressionStatement lookahead restriction).
                    if (next != .l_bracket) {
                        const could_be_binding = (next == .identifier or next == .l_brace or next.isKeyword());
                        if (!could_be_binding or self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                            return self.parseStatement();
                        }
                    }
                }
                try self.emitDiagnostic(self.currentSpan(), "lexical declaration not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_import => {
                // import() and import.meta are expressions, allowed in single-statement context
                const imp_p1 = self.peekAt(1);
                if (imp_p1 == .dot or imp_p1 == .l_paren) {
                    return self.parseStatement();
                }
                try self.emitDiagnostic(self.currentSpan(), "import/export not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_export => {
                try self.emitDiagnostic(self.currentSpan(), "import/export not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_async => {
                // `async function` declarations are not allowed in single-statement context
                if (self.peekAt(1) == .kw_function and !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                    try self.emitDiagnostic(self.currentSpan(), "async function declaration not allowed in single-statement context", .{});
                    return error.ParseError;
                }
                return self.parseStatement();
            },
            .identifier => {
                const id_text_nds = self.tokenText(self.tokIdx());
                if (std.mem.eql(u8, id_text_nds, "using")) {
                    const next = self.peekAt(1);
                    if (next == .identifier or next == .kw_of or next == .kw_let or next == .kw_await) {
                        try self.emitDiagnostic(self.currentSpan(), "'using' declarations can only be declared inside a block", .{});
                        return error.ParseError;
                    }
                }
                return self.parseStatement();
            },
            .kw_type => {
                // TS1156: 'type' declarations cannot appear directly as a single-statement body.
                if (self.is_ts) {
                    const type_p1 = self.peekAt(1);
                    if ((type_p1 == .identifier or type_p1.isKeyword()) and !self.newlines_ptr[self.tok_i + 1]) {
                        const stmt = try self.parseStatement();
                        if (self.nodeTag(stmt.toInt()) == .ts_type_alias_decl) {
                            try self.emitDiagnosticAtToken(self.node_main_token_ptr[stmt.toInt()], "'type' declarations can only be declared inside a block", .{});
                        }
                        return stmt;
                    }
                }
                return self.parseStatement();
            },
            .kw_await => {
                if (self.peekAt(1) == .identifier and
                    std.mem.eql(u8, self.tokenText(@intCast(self.tok_i + 1)), "using") and
                    self.peekAt(2) == .identifier)
                {
                    try self.emitDiagnostic(self.currentSpan(), "'await using' declarations can only be declared inside a block", .{});
                    return error.ParseError;
                }
                return self.parseStatement();
            },
            else => return self.parseStatement(),
        }
    }

    /// Reject lexical declarations but allow function declarations (Annex B).
    /// In strict mode, function declarations are also rejected (not in a block).
    fn parseIfBody(self: *Parser) Error!NodeIndex {
        const tok = self.peek();
        // The overwhelmingly common case — skip the full switch dispatch.
        if (tok == .l_brace) return self.parseBlockStatement();
        switch (tok) {
            .kw_const => {
                if (self.is_ts and self.peekAt(1) == .kw_enum) return self.parseStatement();
                try self.emitDiagnostic(self.currentSpan(), "lexical declaration not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_let => {
                if (!self.in_strict) {
                    const next = self.peekAt(1);
                    // `let [` is forbidden (lex decl not allowed here, and ExpressionStatement
                    // starting with `let [` is also forbidden by lookahead restriction).
                    if (next != .l_bracket) {
                        const could_be_binding = (next == .identifier or next == .l_brace or next.isKeyword());
                        if (!could_be_binding or self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                            return self.parseStatement();
                        }
                    }
                }
                try self.emitDiagnostic(self.currentSpan(), "lexical declaration not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_function => {
                if (self.in_strict or !self.annex_b) {
                    try self.emitDiagnostic(self.currentSpan(), "In non-strict mode code, functions can only be declared at top level or inside a block", .{});
                    return error.ParseError;
                }
                // Generator declarations (function*) are never allowed in if-body (even non-strict)
                if (self.peekAt(1) == .asterisk) {
                    try self.emitDiagnostic(self.currentSpan(), "generator function declaration not allowed in single-statement context", .{});
                    return error.ParseError;
                }
                // Mark this fn-decl as Annex B B.3.2.1 eligible.
                const prev = self.in_annexb_fn_position;
                self.in_annexb_fn_position = true;
                defer self.in_annexb_fn_position = prev;
                return self.parseStatement();
            },
            .kw_class => {
                try self.emitDiagnostic(self.currentSpan(), "class declaration not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_async => {
                // `async function` declarations are not allowed in if-body
                if (self.peekAt(1) == .kw_function and !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                    try self.emitDiagnostic(self.currentSpan(), "async function declaration not allowed in single-statement context", .{});
                    return error.ParseError;
                }
                return self.parseStatement();
            },
            .kw_import => {
                const imp_p1 = self.peekAt(1);
                if (imp_p1 == .dot or imp_p1 == .l_paren) return self.parseStatement();
                try self.emitDiagnostic(self.currentSpan(), "import/export not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .kw_export => {
                try self.emitDiagnostic(self.currentSpan(), "import/export not allowed in single-statement context", .{});
                return error.ParseError;
            },
            .identifier => {
                const id_text_ifb = self.tokenText(self.tokIdx());
                if (std.mem.eql(u8, id_text_ifb, "using")) {
                    const next = self.peekAt(1);
                    if (next == .identifier or next == .kw_of or next == .kw_let or next == .kw_await) {
                        try self.emitDiagnostic(self.currentSpan(), "'using' declarations can only be declared inside a block", .{});
                        return error.ParseError;
                    }
                }
                return self.parseStatement();
            },
            .kw_type => {
                // TS1156: 'type' declarations cannot appear directly as a single-statement if body.
                if (self.is_ts) {
                    const type_p1 = self.peekAt(1);
                    if ((type_p1 == .identifier or type_p1.isKeyword()) and !self.newlines_ptr[self.tok_i + 1]) {
                        const stmt = try self.parseStatement();
                        if (self.nodeTag(stmt.toInt()) == .ts_type_alias_decl) {
                            try self.emitDiagnosticAtToken(self.node_main_token_ptr[stmt.toInt()], "'type' declarations can only be declared inside a block", .{});
                        }
                        return stmt;
                    }
                }
                return self.parseStatement();
            },
            .kw_await => {
                if (self.peekAt(1) == .identifier and
                    std.mem.eql(u8, self.tokenText(@intCast(self.tok_i + 1)), "using") and
                    self.peekAt(2) == .identifier)
                {
                    try self.emitDiagnostic(self.currentSpan(), "'await using' declarations can only be declared inside a block", .{});
                    return error.ParseError;
                }
                return self.parseStatement();
            },
            else => return self.parseStatement(),
        }
    }

    /// Parse `if (cond) consequent [else alternate]`.
    pub fn parseIfStatement(self: *Parser) Error!NodeIndex {
        const if_tok = self.advance(); // eat 'if'
        _ = try self.expect(.l_paren);
        const condition = try self.parseExpression();
        _ = try self.expect(.r_paren);
        // if_open/alt/close carry the cfg_alive logic (branch_open/else/close
        // are no longer emitted for if — the resolver merges them).
        const if_ev = try self.emitIfOpen(false, .none);
        const consequent = try self.parseIfBody();
        if (!self.in_strict and isLabelledFunction(self, consequent)) {
            try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
        }
        // TS1313: The body of an 'if' statement cannot be the empty statement.
        if (self.is_ts and self.nodeTag(consequent.toInt()) == .empty_stmt) {
            try self.emitDiagnostic(self.currentSpan(), "The body of an 'if' statement cannot be the empty statement.", .{});
        }

        if (self.eat(.kw_else)) |_| {
            if (self.emit_scope_events) self.ev_ptr[if_ev].aux = 1;
            const if_alt_ev = try self.emitIfAlt(.none);
            const alternate = try self.parseIfBody();
            if (!self.in_strict and isLabelledFunction(self, alternate)) {
                try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
            }
            const extra = try self.addExtra(ast.IfData, .{
                .consequent = consequent,
                .alternate = alternate,
            });
            const if_else_node = try self.addNode(.{
                .tag = .if_else_stmt,
                .main_token = if_tok,
                .data = .{
                    .lhs = condition,
                    .rhs = NodeIndex.fromInt(extra),
                },
            });
            try self.emitIfClose(if_else_node);
            // Patch if_open with the consequent node so makeIfConsequent fires at
            // consequent.enter — after visiting the condition, before entering consequent.
            self.patchEventNode(if_ev, consequent);
            // Patch if_alt to use the alternate body — gives the else-branch segment
            // a first/last range that covers only the else body, not the entire if-else.
            self.patchEventNode(if_alt_ev, alternate);
            return if_else_node;
        }

        const if_node = try self.addNode(.{
            .tag = .if_stmt,
            .main_token = if_tok,
            .data = .{
                .lhs = condition,
                .rhs = consequent,
            },
        });
        try self.emitIfClose(if_node);
        // Patch if_open with the consequent node so makeIfConsequent fires at
        // consequent.enter — after visiting the condition, before entering consequent.
        self.patchEventNode(if_ev, consequent);
        return if_node;
    }

    /// Parse `while (cond) body`.
    pub fn parseWhileStatement(self: *Parser) Error!NodeIndex {
        const while_tok = self.advance(); // eat 'while'
        _ = try self.expect(.l_paren);
        // Emit loop_open BEFORE parsing the condition so the resolver processes
        // pushLoopContext before any CFG events from nested ternaries inside the
        // condition.  This matches DFS playback order (loop entry fires at the
        // condition's enter phase, before any intra-condition events).
        const loop_ev = try self.emitLoopOpen(.@"while", .none);
        const condition = try self.parseExpression();
        _ = try self.expect(.r_paren);

        const prev_in_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = prev_in_loop;

        try self.emitLoopTestEnd(.@"while", .none);
        // Wrap loop body in branch_open/close so that terminators inside the
        // body (return, throw, break) don't poison the post-loop alive state:
        // the loop may not execute at all, so post-loop alive == pre-loop alive.
        try self.emitBranchOpen(.none);
        const body = try self.parseNonDeclStatement();
        if (!self.in_strict and isLabelledFunction(self, body)) {
            try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
        }
        try self.emitBranchClose(.none);
        try self.emitLoopBodyEnd(.@"while", .none);
        try self.emitLoopClose(.@"while", .none);

        const while_node = try self.addNode(.{
            .tag = .while_stmt,
            .main_token = while_tok,
            .data = .{
                .lhs = condition,
                .rhs = body,
            },
        });
        self.patchEventNode(loop_ev, while_node);
        return while_node;
    }

    /// Parse `do body while (cond);`.
    pub fn parseDoWhileStatement(self: *Parser) Error!NodeIndex {
        const do_tok = self.advance(); // eat 'do'

        const prev_in_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = prev_in_loop;

        const loop_ev = try self.emitLoopOpen(.do_while, .none);
        try self.emitBranchOpen(.none);
        const body = try self.parseNonDeclStatement();
        if (!self.in_strict and isLabelledFunction(self, body)) {
            try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
        }
        try self.emitBranchClose(.none);
        try self.emitLoopBodyEnd(.do_while, .none);
        _ = try self.expect(.kw_while);
        _ = try self.expect(.l_paren);
        const condition = try self.parseExpression();
        _ = try self.expect(.r_paren);
        try self.emitLoopTestEnd(.do_while, .none);
        try self.emitLoopClose(.do_while, .none);
        // Do-while has special ASI: semicolon is always auto-inserted after `)`.
        _ = self.eat(.semicolon);

        const do_node = try self.addNode(.{
            .tag = .do_while_stmt,
            .main_token = do_tok,
            .data = .{
                .lhs = body,
                .rhs = condition,
            },
        });
        self.patchEventNode(loop_ev, do_node);
        return do_node;
    }

    /// Parse `for (...)` — disambiguate for/for-in/for-of.
    /// Parse the init with `allow_in = false`, then check for `in`/`of` keyword.
    pub fn parseForStatement(self: *Parser) Error!NodeIndex {
        const for_tok = self.advance(); // eat 'for'

        // Check for `for await (...)`
        const is_await = self.eat(.kw_await) != null;
        if (is_await and !self.in_async and !self.is_ts) {
            try self.emitDiagnostic(self.currentSpan(), "'for await' is only valid inside an async function", .{});
            return error.ParseError;
        }

        _ = try self.expect(.l_paren);

        // For-let/const creates a new block scope containing the init binding
        // and the body.  For-var does not, but emitting an empty scope is
        // harmless — keeps the parser simple and events well-nested.
        const for_scope_ev = try self.emitScopeOpen(.block, .none);
        errdefer self.emitScopeClose(.none) catch {};

        const prev_in_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = prev_in_loop;

        // Parse init with allow_in = false to disambiguate for-in.
        // Use a block scope with defer so allow_in is reliably restored
        // even on error paths, before we proceed to parse in/of/rest.
        const init: NodeIndex = init_blk: {
            const prev_allow_in = self.allow_in;
            self.allow_in = false;
            defer self.allow_in = prev_allow_in;

            // Check for empty init: `for (;`
            if (self.eat(.semicolon)) |_| {
                break :init_blk .none;
            }

            // Check for var/let/const
            const for_init_tag = self.peek();
            if (for_init_tag == .kw_var or for_init_tag == .kw_const) {
                break :init_blk try self.parseVariableDeclarationNoSemicolon();
            }
            if (for_init_tag == .kw_let) {
                // In non-strict, `let` is only a declaration when followed by binding start
                if (self.in_strict) {
                    break :init_blk try self.parseVariableDeclarationNoSemicolon();
                }
                const next = self.peekAt(1);
                // In for-loop, `let in` and `let of` usually mean `let` is an identifier LHS.
                // Exception: `for (let of of ...)` — `let of` is a declaration, second `of` is for-of.
                if (next != .kw_in and
                    (next != .kw_of or self.peekAt(2) == .kw_of) and
                    (next == .l_bracket or next == .l_brace or
                    next == .identifier or next.isKeyword()))
                {
                    break :init_blk try self.parseVariableDeclarationNoSemicolon();
                }
                // Otherwise treat `let` as identifier expression (e.g. `for (let in obj)`)
            }
            // Check for `using x` or `await using x`
            // Also allow `using of = ...` (for (using of = null;;)) — `of` is a valid binding
            // identifier; the `of` lookahead restriction only applies to for-of/for-await-of.
            if (for_init_tag == .identifier and std.mem.eql(u8, self.tokenText(self.tokIdx()), "using") and
                (self.peekAt(1) == .identifier or self.peekAt(1) == .escaped_keyword or
                self.peekAt(1) == .kw_await or self.peekAt(1) == .kw_let or
                 (self.peekAt(1) == .kw_of and self.peekAt(2) == .equal))) {
                const main_tok: u32 = self.tokIdx();
                _ = self.advance(); // eat 'using'
                break :init_blk try self.parseUsingDeclaratorList(main_tok);
            }
            // `await using x` in for-of init (explicit resource management).
            // [no LineTerminator here] between `await` and `using`.
            if (for_init_tag == .kw_await and self.peekAt(1) == .identifier and
                !self.newlines_ptr[self.tok_i + 1] and
                std.mem.eql(u8, self.tokenText(@intCast(self.tok_i + 1)), "using") and
                (self.peekAt(2) == .identifier or self.peekAt(2) == .escaped_keyword or
                self.peekAt(2) == .kw_await or self.peekAt(2) == .kw_of or self.peekAt(2) == .kw_let))
            {
                const main_tok: u32 = self.tokIdx();
                _ = self.advance(); // eat 'await'
                _ = self.advance(); // eat 'using'
                // [no LineTerminator here] between `using` and the first binding name.
                if (self.newlines_ptr[self.tok_i]) {
                    try self.emitDiagnostic(self.currentSpan(), "No line terminator allowed between 'using' and binding in 'for await'", .{});
                    return error.ParseError;
                }
                break :init_blk try self.parseUsingDeclaratorList(main_tok);
            }
            break :init_blk try self.parseExpression();
        };

        // Handle empty init (semicolon already consumed above).
        if (init == .none) {
            if (is_await) {
                try self.emitDiagnostic(self.currentSpan(), "'for await' requires 'of'", .{});
                return error.ParseError;
            }
            const result = try self.parseForRest(for_tok, .none);
            try self.emitScopeClose(.none);
            self.patchScopeOpenNode(for_scope_ev, result);
            return result;
        }

        // Check for `in` or `of`
        if (self.eat(.kw_in)) |_| {
            if (is_await) {
                try self.emitDiagnostic(self.currentSpan(), "'for await' must use 'of', not 'in'", .{});
                return error.ParseError;
            }
            try self.rejectForInOfInitializer(init, true);
            try self.validateForInOfBinding(init, false);
            try checkForBindingNamesDup(self, init);
            expressions.reinterpretAsPattern(self, init);
            try expressions.validatePattern(self, init);
            try self.upgradePatternRefsToWrite(init);
            const loop_ev = try self.emitLoopOpen(.for_in, .none);
            const right = try self.parseExpression();
            _ = try self.expect(.r_paren);
            try self.emitLoopTestEnd(.for_in, .none);
            try self.emitBranchOpen(.none);
            const body = try self.parseNonDeclStatement();
            try checkForLexVarConflict(self, init, body);
            if (!self.in_strict and isLabelledFunction(self, body)) {
                try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
            }
            try self.emitBranchClose(.none);
            try self.emitLoopBodyEnd(.for_in, .none);
            try self.emitLoopClose(.for_in, .none);
            try self.emitScopeClose(.none);

            const extra = try self.addExtra(ast.ForInOfData, .{
                .binding = init,
                .expr = right,
                .body = body,
            });
            const node = try self.addNode(.{
                .tag = .for_in_stmt,
                .main_token = for_tok,
                .data = .{
                    .lhs = NodeIndex.fromInt(extra),
                    .rhs = .none,
                },
            });
            self.patchScopeOpenNode(for_scope_ev, node);
            self.patchEventNode(loop_ev, node);
            return node;
        }

        if (self.eat(.kw_of)) |_| {
            // The left-hand side of a 'for...of' statement may not be 'async'
            // (only applies to for-of, not for-await-of).
            if (!is_await and init != .none) {
                const init_tag = self.node_tags_ptr[init.toInt()];
                const init_tok = self.node_main_token_ptr[init.toInt()];
                const is_async_id = init_tag == .identifier and
                    self.tokenTagAt(init_tok) == .kw_async;
                if (is_async_id) {
                    if (self.is_ts) {
                        try self.emitDiagnostic(self.currentSpan(), "The left-hand side of a 'for...of' statement may not be 'async'", .{});
                    } else {
                        try self.emitDiagnostic(self.currentSpan(), "'async' is not allowed as the LHS of a for-of loop", .{});
                        return error.ParseError;
                    }
                }
            }
            try self.rejectForInOfInitializer(init, false);
            try self.validateForInOfBinding(init, true);
            try checkForBindingNamesDup(self, init);
            expressions.reinterpretAsPattern(self, init);
            try expressions.validatePattern(self, init);
            try self.upgradePatternRefsToWrite(init);
            const loop_ev = try self.emitLoopOpen(.for_of, .none);
            const right = try self.parseAssignmentExpression();
            _ = try self.expect(.r_paren);
            try self.emitLoopTestEnd(.for_of, .none);
            try self.emitBranchOpen(.none);
            const body = try self.parseNonDeclStatement();
            try checkForLexVarConflict(self, init, body);
            if (!self.in_strict and isLabelledFunction(self, body)) {
                try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
            }
            try self.emitBranchClose(.none);
            try self.emitLoopBodyEnd(.for_of, .none);
            try self.emitLoopClose(.for_of, .none);
            try self.emitScopeClose(.none);

            const extra = try self.addExtra(ast.ForInOfData, .{
                .binding = init,
                .expr = right,
                .body = body,
            });
            const tag: Node.Tag = if (is_await) .for_await_of_stmt else .for_of_stmt;
            const node = try self.addNode(.{
                .tag = tag,
                .main_token = for_tok,
                .data = .{
                    .lhs = NodeIndex.fromInt(extra),
                    .rhs = .none,
                },
            });
            self.patchScopeOpenNode(for_scope_ev, node);
            self.patchEventNode(loop_ev, node);
            return node;
        }

        // `for await` requires `of` — if we reach the standard for-loop path it's invalid.
        if (is_await) {
            try self.emitDiagnostic(self.currentSpan(), "'for await' requires 'of'", .{});
            return error.ParseError;
        }

        // Standard for loop: for (init; cond; update) body
        // Check CoverInitializedName in init (not destructured)
        if (init != .none) {
            const init_tag = self.node_tags_ptr[init.toInt()];
            if (init_tag != .assign and tagNeedsCoverCheck(init_tag))
                self.checkCoverInitializedName(init);
        }
        _ = try self.expect(.semicolon);
        const result = try self.parseForRest(for_tok, init);
        try self.emitScopeClose(.none);
        self.patchScopeOpenNode(for_scope_ev, result);
        return result;
    }

    /// Check for "use strict" directive at current position (without consuming tokens).
    fn checkDirectivePrologue(self: *Parser) void {
        _ = self.checkDirectivePrologueAt(@intCast(self.tok_i));
    }

    /// Check for "use strict" starting at a specific token position.
    /// Returns true if a "use strict" directive was found (regardless of whether
    /// strict mode changed — it may have already been active).
    fn checkDirectivePrologueAt(self: *Parser, start_pos: u32) bool {
        var pos = start_pos;
        while (pos < self.parsed_len) {
            const tag = self.tags_ptr[pos];
            if (tag != .string_literal) break;

            // A string literal is only a directive if it's a complete expression statement.
            // `"use strict".foo`, `"use strict"[x]`, `"use strict"(x)`, `"use strict"`tpl``
            // are NOT directives — they're member/call/tagged-template expressions.
            if (pos + 1 < self.parsed_len) {
                const next_tag = self.tags_ptr[pos + 1];
                if (next_tag == .dot or next_tag == .l_bracket or next_tag == .l_paren or
                    next_tag == .template_head or next_tag == .template_no_sub)
                    break; // expression continuation → not a directive prologue
            }

            const start = self.tok_starts_ptr[pos];
            const text = self.getStringContent(start);
            if (std.mem.eql(u8, text, "use strict")) {
                self.in_strict = true;
                self.syncYieldLex();
                return true;
            }

            pos += 1;
            if (pos < self.parsed_len and self.tags_ptr[pos] == .semicolon) {
                pos += 1;
            }
        }
        return false;
    }

    /// Extract string content (without quotes) from a string literal at the given position.
    /// @returns borrowed_from(self)
    pub fn getStringContent(self: *const Parser, start: u32) []const u8 {
        if (start >= self.source.len) return "";
        const quote = self.source[start];
        if (quote != '\'' and quote != '"') return "";
        var end = start + 1;
        while (end < self.source.len and self.source[end] != quote) {
            if (self.source[end] == '\\') end += 1;
            end += 1;
        }
        // Cap at source.len — escape sequence at EOF can run end past it,
        // and the closing quote is missing for unterminated string literals.
        if (end > self.source.len) end = @intCast(self.source.len);
        return self.source[start + 1 .. end];
    }

    /// Whether a node tag could contain a CoverInitializedName.
    /// Used to gate calls to checkCoverInitializedName when the tag is already loaded.
    pub inline fn tagNeedsCoverCheck(tag: Node.Tag) bool {
        return switch (tag) {
            // call_expr is omitted: args are now checked inline in parseArgumentList,
            // covering call/new/optional-call contexts uniformly and earlier.
            .object_literal, .array_literal,
            .expression_stmt, .grouping_expr,
            .unary_plus, .unary_minus, .bitwise_not, .logical_not, .typeof_expr,
            .void_expr, .delete_expr, .yield_expr, .yield_delegate, .spread_element,
            .prefix_inc, .prefix_dec, .await_expr => true,
            else => false,
        };
    }

    /// Fast inline entry for checkCoverInitializedName — skips the function call
    /// entirely for the common non-container cases (identifiers, member exprs, etc.).
    pub inline fn checkCoverInitializedNameFast(self: *Parser, node: NodeIndex) void {
        if (node == .none) return;
        const tag = self.node_tags_ptr[node.toInt()];
        if (tagNeedsCoverCheck(tag)) self.checkCoverInitializedName(node);
    }

    /// Check for CoverInitializedName ({a = 0}) in expression context.
    /// Recursively checks array/object literals for assignment_pattern children.
    pub fn checkCoverInitializedName(self: *Parser, node: NodeIndex) void {
        if (node == .none) return;
        const tag = self.node_tags_ptr[node.toInt()];
        const data = self.node_data_ptr[node.toInt()];
        switch (tag) {
            .object_literal => {
                const s = @intFromEnum(data.lhs);
                const e = @intFromEnum(data.rhs);
                var i = s;
                while (i < e) : (i += 1) {
                    const prop = NodeIndex.fromInt(self.extra_data.items[i]);
                    if (prop != .none) {
                        const pt = self.node_tags_ptr[prop.toInt()];
                        if (pt == .assignment_pattern) {
                            self.emitDiagnostic(self.nodeSpan(prop), "Invalid shorthand property initializer", .{}) catch {};
                        }
                    }
                }
            },
            .array_literal => {
                const s = @intFromEnum(data.lhs);
                const e = @intFromEnum(data.rhs);
                var i = s;
                while (i < e) : (i += 1) {
                    const elem = NodeIndex.fromInt(self.extra_data.items[i]);
                    self.checkCoverInitializedNameFast(elem);
                }
            },
            .expression_stmt, .grouping_expr,
            .unary_plus, .unary_minus, .bitwise_not, .logical_not, .typeof_expr,
            .void_expr, .delete_expr, .yield_expr, .yield_delegate, .spread_element,
            .prefix_inc, .prefix_dec, .await_expr,
            => self.checkCoverInitializedName(data.lhs),
            else => {},
        }
    }

    fn nodeSpan(self: *const Parser, node: NodeIndex) @import("span.zig").Span {
        const start = self.tok_starts_ptr[self.node_main_token_ptr[node.toInt()]];
        return .{ .start = start, .end = start };
    }

    /// Validate for-in/of binding: must be assignable (not this, literals, binary exprs).
    fn validateForInOfBinding(self: *Parser, init: NodeIndex, is_for_of: bool) Error!void {
        if (init == .none) return;
        const init_tag = self.node_tags_ptr[init.toInt()];
        // Parenthesized destructuring patterns are invalid in for-in/of:
        // `for(([a]) of x)` and `for(({a}) of x)` are syntax errors.
        if (init_tag == .grouping_expr) {
            const unwrapped = expressions.unwrapGrouping(self, init);
            if (unwrapped.tag == .array_literal or unwrapped.tag == .object_literal or
                unwrapped.tag == .array_pattern or unwrapped.tag == .object_pattern)
            {
                try self.emitDiagnostic(self.currentSpan(), "Invalid destructuring assignment target", .{});
                return error.ParseError;
            }
        }
        // Unwrap parenthesized expressions: (x), ((x))
        const unwrapped = expressions.unwrapGrouping(self, init);
        switch (unwrapped.tag) {
            .identifier, .member_expr, .computed_member_expr => {
                // `for(let of ...)` and `for(let.a of ...)` are prohibited in for-of:
                // "It is a Syntax Error if the first token of LHS is `let`" (13.7.5.1)
                // Note: `for(let in ...)` IS valid — `let` as identifier in for-in.
                // The `let` prohibition only applies when `let` is the FIRST token (unparenthesized).
                // `for ((let.foo) of bar)` is valid — `(` is the first token, not `let`.
                if (is_for_of and init_tag != .grouping_expr) {
                    var check_node = unwrapped.node;
                    var check_tag = unwrapped.tag;
                    while (check_tag == .member_expr or check_tag == .computed_member_expr) {
                        check_node = self.node_data_ptr[check_node.toInt()].lhs;
                        if (check_node == .none) break;
                        check_tag = self.node_tags_ptr[check_node.toInt()];
                    }
                    if (check_tag == .identifier) {
                        const tok = self.node_main_token_ptr[check_node.toInt()];
                        if (self.tokenTagAt(tok) == .kw_let) {
                            try self.emitDiagnostic(self.currentSpan(), "'let' is not allowed as a for-of binding identifier", .{});
                            return error.ParseError;
                        }
                    }
                }
            },
            .array_pattern, .object_pattern,
            => {},
            .array_literal => {
                try self.validateAssignmentTargetArray(unwrapped.node);
            },
            .object_literal => {
                try self.validateAssignmentTargetObject(unwrapped.node);
            },
            .var_decl, .let_decl, .const_decl => {
                // using/await using not allowed on for-in LHS (spec: only for-of).
                if (!is_for_of and init_tag == .const_decl) {
                    const decl_main = self.node_main_token_ptr[init.toInt()];
                    const decl_tag = self.tokenTagAt(decl_main);
                    if (decl_tag == .identifier and std.mem.eql(u8, self.tokenText(decl_main), "using")) {
                        try self.emitDiagnostic(self.currentSpan(), "The left-hand side of a 'for...in' statement cannot be a 'using' declaration", .{});
                        return error.ParseError;
                    } else if (decl_tag == .kw_await) {
                        try self.emitDiagnostic(self.currentSpan(), "The left-hand side of a 'for...in' statement cannot be an 'await using' declaration", .{});
                        return error.ParseError;
                    }
                }
                // Must have exactly one declarator
                const d = self.node_data_ptr[init.toInt()];
                const count = @intFromEnum(d.rhs) - @intFromEnum(d.lhs);
                if (count != 1) {
                    try self.emitDiagnostic(self.currentSpan(), "for-in/of must have a single binding", .{});
                }
                // using/await-using declarations cannot bind `let`.
                if (!self.is_ts and init_tag == .const_decl) {
                    const decl_main_tok = self.node_main_token_ptr[init.toInt()];
                    const decl_main_tag = self.tokenTagAt(decl_main_tok);
                    const is_using_decl = (decl_main_tag == .identifier and
                        std.mem.eql(u8, self.tokenText(decl_main_tok), "using")) or
                        decl_main_tag == .kw_await;
                    if (is_using_decl) {
                        var names: [8][]const u8 = undefined;
                        var names_n: usize = 0;
                        collectLexNamesInNode(self, init, &names, &names_n);
                        for (names[0..names_n]) |nm| {
                            if (std.mem.eql(u8, nm, "let")) {
                                try self.emitDiagnostic(self.currentSpan(),
                                    "'let' is not allowed as a 'using' binding name", .{});
                                return error.ParseError;
                            }
                        }
                    }
                }
            },
            .call_expr => {
                // AnnexB: f() as for-in/of LHS permitted in non-strict Script.
                if (self.in_strict or !self.annex_b) {
                    if (!self.is_ts) {
                        try self.emitDiagnostic(self.currentSpan(), "Invalid left-hand side in for-in/of: function call", .{});
                        return error.ParseError;
                    }
                }
            },
            // Arrow functions are never valid as for-in/of LHS (syntax error in all modes).
            .arrow_fn, .async_arrow_fn => {
                try self.emitDiagnostic(self.currentSpan(), "Invalid left-hand side in for-in/of: arrow function", .{});
                return error.ParseError;
            },
            .this_expr, .number_literal, .string_literal, .boolean_literal,
            .null_literal, .add, .subtract, .multiply,
            .new_expr, .unary_plus, .unary_minus,
            .prefix_inc, .prefix_dec, .postfix_inc, .postfix_dec,
            .logical_not, .bitwise_not, .typeof_expr, .void_expr, .delete_expr,
            .conditional, .assign,
            .fn_expr, .class_expr, .template_literal, .tagged_template,
            .logical_or, .logical_and, .bitwise_or, .bitwise_xor, .bitwise_and,
            .strict_equal, .strict_not_equal,
            .regex_literal, .import_meta,
            => {
                // In TS mode, invalid for-in/of LHS is a type error, not syntax error
                if (!self.is_ts) {
                    try self.emitDiagnostic(self.currentSpan(), "Invalid left-hand side in for-in/of", .{});
                    return error.ParseError;
                }
            },
            else => {},
        }
    }

    /// Validate that an array literal is a valid assignment target (destructuring assignment).
    fn validateAssignmentTargetArray(self: *Parser, node: NodeIndex) Error!void {
        const data = self.node_data_ptr[node.toInt()];
        const start_idx = @intFromEnum(data.lhs);
        const end_idx = @intFromEnum(data.rhs);
        var i = start_idx;
        while (i < end_idx) : (i += 1) {
            const elem = NodeIndex.fromInt(self.extra_data.items[i]);
            if (elem == .none) continue;
            try self.validateAssignmentTarget(elem);
        }
    }

    /// Validate that an object literal is a valid assignment target (destructuring assignment).
    fn validateAssignmentTargetObject(self: *Parser, node: NodeIndex) Error!void {
        const data = self.node_data_ptr[node.toInt()];
        const start_idx = @intFromEnum(data.lhs);
        const end_idx = @intFromEnum(data.rhs);
        var i = start_idx;
        while (i < end_idx) : (i += 1) {
            const prop = NodeIndex.fromInt(self.extra_data.items[i]);
            if (prop == .none) continue;
            const prop_tag = self.node_tags_ptr[prop.toInt()];
            // Getter/setter/method definitions are not valid destructuring targets
            if (prop_tag == .getter_def or prop_tag == .setter_def or prop_tag == .method_def or
                prop_tag == .computed_method_def or prop_tag == .computed_getter_def or
                prop_tag == .computed_setter_def)
            {
                try self.emitDiagnostic(self.currentSpan(), "Invalid destructuring target: method definition in pattern", .{});
                return error.ParseError;
            }
            if (prop_tag == .property) {
                const prop_data = self.node_data_ptr[prop.toInt()];
                if (prop_data.rhs != .none) {
                    try self.validateAssignmentTarget(prop_data.rhs);
                }
            }
        }
    }

    /// Validate that a node is a valid simple assignment target.
    fn validateAssignmentTarget(self: *Parser, node: NodeIndex) Error!void {
        if (node == .none) return;
        const tag = self.node_tags_ptr[node.toInt()];
        switch (tag) {
            .identifier, .member_expr, .computed_member_expr,
            .array_pattern, .object_pattern, .assignment_pattern,
            .rest_element, .spread_element,
            => {},
            .array_literal => try self.validateAssignmentTargetArray(node),
            .object_literal => try self.validateAssignmentTargetObject(node),
            .assign => {
                // `a = default` in destructuring is valid
                const data = self.node_data_ptr[node.toInt()];
                try self.validateAssignmentTarget(data.lhs);
            },
            else => {
                if (!self.is_ts) {
                    try self.emitDiagnostic(self.currentSpan(), "Invalid destructuring assignment target", .{});
                    return error.ParseError;
                }
            },
        }
    }

    /// Reject initializers in for-in/of: `for (let x = 1 in y)` is invalid.
    /// Exception (Annex B): `for (var x = expr in y)` is allowed in non-strict mode.
    fn rejectForInOfInitializer(self: *Parser, init: NodeIndex, is_for_in: bool) Error!void {
        if (init == .none) return;
        const init_tag = self.node_tags_ptr[init.toInt()];
        // Variable declarations with initializers
        if (init_tag == .var_decl or init_tag == .let_decl or init_tag == .const_decl) {
            // Annex B: `for (var x = expr in y)` is allowed in non-strict for-in ONLY for
            // simple (identifier) bindings. Destructuring patterns are always rejected.
            if (is_for_in and init_tag == .var_decl and !self.in_strict and !self.is_ts and self.annex_b) {
                // Check that the binding is a simple identifier (not a pattern).
                const init_data = self.node_data_ptr[init.toInt()];
                if (init_data.lhs.toInt() + 1 == init_data.rhs.toInt()) {
                    const decl_node = NodeIndex.fromInt(self.extra_data.items[init_data.lhs.toInt()]);
                    if (decl_node != .none and self.node_tags_ptr[decl_node.toInt()] == .declarator) {
                        const binding = self.node_data_ptr[decl_node.toInt()].lhs;
                        if (binding != .none and self.node_tags_ptr[binding.toInt()] == .identifier) {
                            return; // Simple binding: allow via AnnexB
                        }
                    }
                }
            }
            const init_data = self.node_data_ptr[init.toInt()];
            const range = ast.SubRange{
                .start = @intFromEnum(init_data.lhs),
                .end = @intFromEnum(init_data.rhs),
            };
            const decl_indices = self.extra_data.items[range.start..range.end];
            for (decl_indices) |decl_idx| {
                const decl_data = self.node_data_ptr[@intCast(decl_idx)];
                if (decl_data.rhs != .none) {
                    try self.emitDiagnostic(self.currentSpan(), "for-in/of loop variable cannot have an initializer", .{});
                    return;
                }
            }
        }
    }

    /// Parse the condition, update, and body parts of a standard `for` loop.
    /// `init` is .none if there was no initializer.
    pub fn parseForRest(self: *Parser, for_tok: TokenIndex, init: NodeIndex) Error!NodeIndex {
        const loop_ev = try self.emitLoopOpen(.@"for", .none);
        // condition (optional)
        const condition: NodeIndex = if (self.peek() != .semicolon)
            try self.parseExpression()
        else
            .none;
        _ = try self.expect(.semicolon);
        try self.emitLoopTestEnd(.@"for", .none);

        // update (optional)
        const update: NodeIndex = if (self.peek() != .r_paren)
            try self.parseExpression()
        else
            .none;
        _ = try self.expect(.r_paren);

        try self.emitBranchOpen(.none);
        const body = try self.parseNonDeclStatement();
        try checkForLexVarConflict(self, init, body);
        if (!self.in_strict and isLabelledFunction(self, body)) {
            try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
        }
        try self.emitBranchClose(.none);
        try self.emitLoopBodyEnd(.@"for", .none);
        try self.emitLoopClose(.@"for", .none);

        const extra = try self.addExtra(ast.ForData, .{
            .init = init,
            .condition = condition,
            .update = update,
        });
        const for_node = try self.addNode(.{
            .tag = .for_stmt,
            .main_token = for_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(extra),
                .rhs = body,
            },
        });
        self.patchEventNode(loop_ev, for_node);
        return for_node;
    }

    /// Parse `switch (expr) { case/default }`.
    pub fn parseSwitchStatement(self: *Parser) Error!NodeIndex {
        const switch_tok = self.advance(); // eat 'switch'
        _ = try self.expect(.l_paren);
        const discriminant = try self.parseExpression();
        _ = try self.expect(.r_paren);
        _ = try self.expect(.l_brace);

        const prev_in_switch = self.in_switch;
        self.in_switch = true;
        defer self.in_switch = prev_in_switch;

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // Switch opens a lexical scope — let/const declared inside any case
        // is visible across all cases (matches ESLint scope model).
        const switch_scope_ev = try self.emitScopeOpen(.switch_stmt, .none);
        const switch_ev = try self.emitSwitchOpen(false, .none);
        var has_default = false;
        while (self.peek() != .r_brace and !self.isAtEnd()) {
            if (self.peek() == .kw_default) {
                if (has_default) {
                    try self.emitDiagnostic(self.currentSpan(), "Duplicate default clause in switch", .{});
                }
                has_default = true;
            }
            const case_node = try self.parseSwitchCase();
            try self.scratchPush(case_node);
        }
        if (self.emit_scope_events and has_default)
            self.ev_ptr[switch_ev].aux = 1;
        const switch_close_ev = try self.emitSwitchClose(.none);
        try self.emitScopeClose(.none);

        _ = try self.expect(.r_brace);

        const cases = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(cases);

        // Check for lex-lex and lex-var conflicts in the switch CaseBlock.
        // The spec requires that all LexicallyDeclaredNames across all cases be
        // unique, and that none conflict with VarDeclaredNames in the switch body.
        if (!self.is_ts and self.emit_scope_events) {
            // Collect all lex names from all case statement lists
            var lex_names_buf: [128][]const u8 = undefined;
            var lex_names_n: usize = 0;
            for (cases) |case_raw| {
                const case_node: NodeIndex = @enumFromInt(case_raw);
                if (case_node == .none) continue;
                const ci = case_node.toInt();
                if (ci >= self.nodes.len) continue;
                const ctag = self.node_tags_ptr[ci];
                const cdata = self.node_data_ptr[ci];
                if (ctag == .switch_case or ctag == .switch_default) {
                    // rhs = extra index to SubRange of stmts
                    const stmt_extra_idx = cdata.rhs.toInt();
                    if (stmt_extra_idx + 1 < self.extra_data.items.len) {
                        const ss = self.extra_data.items[stmt_extra_idx];
                        const se = self.extra_data.items[stmt_extra_idx + 1];
                        collectLexNamesInRange(self, ss, se, &lex_names_buf, &lex_names_n);
                    }
                }
            }

            if (lex_names_n > 0) {
                // AnnexB B.3.3.5: in non-strict mode, duplicate lex names in a
                // switch CaseBlock are allowed when ALL occurrences are from
                // plain FunctionDeclarations (not async/generator/class/let/const).
                var fn_decl_names_buf: [128][]const u8 = undefined;
                var fn_decl_names_n: usize = 0;
                if (!self.in_strict) {
                    for (cases) |case_raw| {
                        const case_node: NodeIndex = @enumFromInt(case_raw);
                        if (case_node == .none) continue;
                        const ci = case_node.toInt();
                        if (ci >= self.nodes.len) continue;
                        const ctag2 = self.node_tags_ptr[ci];
                        const cdata2 = self.node_data_ptr[ci];
                        if (ctag2 == .switch_case or ctag2 == .switch_default) {
                            const stmt_extra_idx2 = cdata2.rhs.toInt();
                            if (stmt_extra_idx2 + 1 < self.extra_data.items.len) {
                                const ss2 = self.extra_data.items[stmt_extra_idx2];
                                const se2 = self.extra_data.items[stmt_extra_idx2 + 1];
                                collectFnDeclNamesInRange(self, ss2, se2, &fn_decl_names_buf, &fn_decl_names_n);
                            }
                        }
                    }
                }

                // Check lex-lex duplicates across all cases
                var checked_buf: [128][]const u8 = undefined;
                var checked_n: usize = 0;
                for (lex_names_buf[0..lex_names_n]) |lex_name| {
                    var is_dup = false;
                    for (checked_buf[0..checked_n]) |existing| {
                        if (std.mem.eql(u8, existing, lex_name)) {
                            is_dup = true;
                            break;
                        }
                    }
                    if (is_dup) {
                        // AnnexB: allow if not strict, annex_b enabled, and all occurrences are fn_decl
                        if (!self.in_strict and self.annex_b and fn_decl_names_n > 0) {
                            var total: usize = 0;
                            var fn_count: usize = 0;
                            for (lex_names_buf[0..lex_names_n]) |n| {
                                if (std.mem.eql(u8, n, lex_name)) total += 1;
                            }
                            for (fn_decl_names_buf[0..fn_decl_names_n]) |n| {
                                if (std.mem.eql(u8, n, lex_name)) fn_count += 1;
                            }
                            if (fn_count == total) continue;
                        }
                        try self.emitDiagnostic(self.currentSpan(),
                            "Identifier '{s}' has already been declared", .{lex_name});
                    } else if (checked_n < checked_buf.len) {
                        checked_buf[checked_n] = lex_name;
                        checked_n += 1;
                    }
                }

                // Collect var names from all case statement lists (recursive)
                var var_names_buf: [128][]const u8 = undefined;
                var var_names_n: usize = 0;
                for (cases) |case_raw| {
                    const case_node: NodeIndex = @enumFromInt(case_raw);
                    if (case_node == .none) continue;
                    const ci = case_node.toInt();
                    if (ci >= self.nodes.len) continue;
                    const ctag = self.node_tags_ptr[ci];
                    const cdata = self.node_data_ptr[ci];
                    if (ctag == .switch_case or ctag == .switch_default) {
                        const stmt_extra_idx = cdata.rhs.toInt();
                        if (stmt_extra_idx + 1 < self.extra_data.items.len) {
                            const ss = self.extra_data.items[stmt_extra_idx];
                            const se = self.extra_data.items[stmt_extra_idx + 1];
                            collectVarNamesInRange(self, ss, se, &var_names_buf, &var_names_n);
                        }
                    }
                }

                // Check lex-var conflicts
                for (checked_buf[0..checked_n]) |lex_name| {
                    for (var_names_buf[0..var_names_n]) |var_name| {
                        if (std.mem.eql(u8, lex_name, var_name)) {
                            try self.emitDiagnostic(self.currentSpan(),
                                "Identifier '{s}' has already been declared", .{lex_name});
                            break;
                        }
                    }
                }
            }
        }

        const range_extra = try self.addExtra(SubRange, .{
            .start = range.start,
            .end = range.end,
        });
        const switch_node = try self.addNode(.{
            .tag = .switch_stmt,
            .main_token = switch_tok,
            .data = .{
                .lhs = discriminant,
                .rhs = NodeIndex.fromInt(range_extra),
            },
        });
        self.patchScopeOpenNode(switch_scope_ev, switch_node);
        self.patchEventNode(switch_ev, switch_node);
        self.patchEventNode(switch_close_ev, switch_node);
        return switch_node;
    }

    /// Parse a single `case expr:` or `default:` clause with its consequent statements.
    pub fn parseSwitchCase(self: *Parser) Error!NodeIndex {
        if (self.eat(.kw_default)) |default_tok| {
            _ = try self.expect(.colon);
            const case_start_ev = try self.emitSwitchCaseStart(true, .none);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            const prev_in_case_clause = self.in_case_clause;
            self.in_case_clause = true;
            defer self.in_case_clause = prev_in_case_clause;

            while (true) {
                const tsc = self.peek();
                if (tsc == .kw_case or tsc == .kw_default or tsc == .r_brace or tsc == .eof) break;
                const stmt = self.parseStatement() catch |err| switch (err) {
                    error.ParseError => {
                        self.synchronize();
                        try self.pushErrorNode();
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                try self.scratchPush(stmt);
            }

            const stmts = self.scratch.items[scratch_top..];
            const range = try self.listToSubRange(stmts);

            const range_extra = try self.addExtra(SubRange, .{
                .start = range.start,
                .end = range.end,
            });
            const default_node = try self.addNode(.{
                .tag = .switch_default,
                .main_token = default_tok,
                .data = .{
                    .lhs = .none,
                    .rhs = NodeIndex.fromInt(range_extra),
                },
            });
            self.patchEventNode(case_start_ev, default_node);
            try self.emitSwitchCaseEnd(default_node);
            return default_node;
        }

        const case_tok = try self.expect(.kw_case);
        const test_expr = try self.parseExpression();
        _ = try self.expect(.colon);
        const case_start_ev2 = try self.emitSwitchCaseStart(false, .none);

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const prev_in_case_clause2 = self.in_case_clause;
        self.in_case_clause = true;
        defer self.in_case_clause = prev_in_case_clause2;

        while (true) {
            const tsc2 = self.peek();
            if (tsc2 == .kw_case or tsc2 == .kw_default or tsc2 == .r_brace or tsc2 == .eof) break;
            const stmt = self.parseStatement() catch |err| switch (err) {
                error.ParseError => {
                    self.synchronize();
                    try self.pushErrorNode();
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            try self.scratchPush(stmt);
        }

        const stmts = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(stmts);

        const range_extra = try self.addExtra(SubRange, .{
            .start = range.start,
            .end = range.end,
        });
        const case_node = try self.addNode(.{
            .tag = .switch_case,
            .main_token = case_tok,
            .data = .{
                .lhs = test_expr,
                .rhs = NodeIndex.fromInt(range_extra),
            },
        });
        self.patchEventNode(case_start_ev2, case_node);
        try self.emitSwitchCaseEnd(case_node);
        return case_node;
    }

    /// Parse `return [expr];` (expr optional if semicolon/newline/}/eof follows).
    pub fn parseReturnStatement(self: *Parser) Error!NodeIndex {
        const ret_tok = self.advance(); // eat 'return'

        // TypeScript doesn't emit TS1108 for `return` inside a `with` body.
        if (!self.in_function and !self.in_with) {
            try self.emitDiagnosticAtToken(ret_tok, "'return' outside of function", .{});
        }

        // ASI: return with no value is allowed if followed by newline, }, or eof.
        const expr: NodeIndex = if (self.peek() == .semicolon or
            self.peek() == .r_brace or
            self.peek() == .eof or
            self.isOnNewLine())
            .none
        else
            try self.parseExpression();

        try self.expectSemicolon();
        const node = try self.addNode(.{
            .tag = .return_stmt,
            .main_token = ret_tok,
            .data = .{ .lhs = expr, .rhs = .none },
        });
        try self.emitTerminator(.@"return", node);
        return node;
    }

    /// Parse `throw expr;` (NO ASI between throw and expr).
    pub fn parseThrowStatement(self: *Parser) Error!NodeIndex {
        const throw_tok = self.advance(); // eat 'throw'

        // No line terminator allowed between `throw` and the expression.
        if (self.isOnNewLine()) {
            try self.emitDiagnosticAtToken(throw_tok, "no line break is allowed between 'throw' and its expression", .{});
        }

        const throw_next = self.peek();
        if (throw_next == .semicolon or throw_next == .r_brace or throw_next == .eof) {
            try self.emitDiagnosticAtToken(throw_tok, "'throw' must be followed by an expression", .{});
            try self.expectSemicolon();
            const node = try self.addNode(.{
                .tag = .throw_stmt,
                .main_token = throw_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            try self.emitTerminator(.@"throw", node);
            return node;
        }

        const expr = try self.parseExpression();
        try self.expectSemicolon();

        const node = try self.addNode(.{
            .tag = .throw_stmt,
            .main_token = throw_tok,
            .data = .{ .lhs = expr, .rhs = .none },
        });
        try self.emitTerminator(.@"throw", node);
        return node;
    }

    /// Compare two label names for identity, decoding `\uXXXX` / `\u{X}` escapes on
    /// both sides first. A label declared `label2:` and referenced as `label2`
    /// (or vice-versa) denote the same label per spec, so a raw byte comparison would
    /// wrongly miss the target. Mirrors the escaped-identifier comparison used for
    /// variable references (see decodeIdentForCompare callers).
    fn labelNamesEqual(a: []const u8, b: []const u8) bool {
        // Fast path: no escapes on either side → raw compare.
        if (std.mem.indexOfScalar(u8, a, '\\') == null and
            std.mem.indexOfScalar(u8, b, '\\') == null)
            return std.mem.eql(u8, a, b);
        var abuf: [256]u8 = undefined;
        var bbuf: [256]u8 = undefined;
        if (a.len > abuf.len or b.len > bbuf.len) return std.mem.eql(u8, a, b);
        const al = decodeIdentForCompare(a, &abuf);
        const bl = decodeIdentForCompare(b, &bbuf);
        return std.mem.eql(u8, abuf[0..al], bbuf[0..bl]);
    }

    /// Parse `break [label];`.
    pub fn parseBreakStatement(self: *Parser) Error!NodeIndex {
        const break_tok = self.advance(); // eat 'break'

        // Check if there's a label — `break label` is valid in any labeled block
        const has_label = self.peek() == .identifier and !self.isOnNewLine();

        // `break` without label requires loop or switch context
        if (!has_label and !self.in_loop and !self.in_switch) {
            try self.emitDiagnosticAtToken(break_tok, "'break' outside of loop or switch", .{});
        }

        // Label must be on the same line (no ASI between break and label).
        if (self.peek() == .identifier and !self.isOnNewLine()) {
            const label_tok = self.advance();
            // Create the label node BEFORE consuming `;` so its end_tok
            // records only the identifier (rules report on node.label range).
            const label_node = try self.addNode(.{
                .tag = .property_ident,
                .main_token = label_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            const label_name = self.tokenText(label_tok);
            // Validate break label target.
            {
                var found = false;
                if (self.ts_label_stack) |stack| {
                    var i: u8 = 0;
                    while (i < self.ts_label_count) : (i += 1) {
                        if (labelNamesEqual(stack[i].name, label_name)) {
                            if (self.ts_label_fn_depth > stack[i].fn_depth) {
                                if (self.is_ts) {
                                    try self.emitDiagnosticAtToken(label_tok, "Jump target cannot cross function boundary", .{});
                                } else {
                                    try self.emitDiagnosticAtToken(label_tok, "'break' target label cannot be inside a function", .{});
                                    return error.ParseError;
                                }
                            }
                            found = true;
                            break;
                        }
                    }
                }
                if (!found and !self.is_ts) {
                    try self.emitDiagnosticAtToken(label_tok, "Undefined label '{s}'", .{label_name});
                    return error.ParseError;
                } else if (!found and self.is_ts) {
                    try self.emitDiagnosticAtToken(label_tok, "A 'break' statement can only jump to a label of an enclosing statement", .{});
                }
            }
            try self.expectSemicolon();
            const node = try self.addNode(.{
                .tag = .break_label,
                .main_token = break_tok,
                .data = .{
                    .lhs = label_node,
                    .rhs = .none,
                },
            });
            try self.emitTerminator(.@"break", node);
            return node;
        }

        try self.expectSemicolon();
        const node = try self.addNode(.{
            .tag = .break_stmt,
            .main_token = break_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        try self.emitTerminator(.@"break", node);
        return node;
    }

    /// Parse `continue [label];`.
    pub fn parseContinueStatement(self: *Parser) Error!NodeIndex {
        const cont_tok = self.advance(); // eat 'continue'

        if (!self.in_loop) {
            try self.emitDiagnosticAtToken(cont_tok, "'continue' outside of loop", .{});
        }

        // Label must be on the same line (no ASI between continue and label).
        if (self.peek() == .identifier and !self.isOnNewLine()) {
            const label_tok = self.advance();
            // Create the label node BEFORE consuming `;` so its end_tok
            // records only the identifier.
            const label_node = try self.addNode(.{
                .tag = .property_ident,
                .main_token = label_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            const label_name = self.tokenText(label_tok);
            // Validate continue label target.
            {
                var found = false;
                var is_loop_target = false;
                if (self.ts_label_stack) |stack| {
                    var i: u8 = 0;
                    while (i < self.ts_label_count) : (i += 1) {
                        if (labelNamesEqual(stack[i].name, label_name)) {
                            if (self.ts_label_fn_depth > stack[i].fn_depth) {
                                if (self.is_ts) {
                                    try self.emitDiagnosticAtToken(label_tok, "Jump target cannot cross function boundary", .{});
                                } else {
                                    try self.emitDiagnosticAtToken(label_tok, "'continue' target label cannot be inside a function", .{});
                                    return error.ParseError;
                                }
                            }
                            found = true;
                            is_loop_target = stack[i].is_loop;
                            break;
                        }
                    }
                }
                if (!found and !self.is_ts) {
                    try self.emitDiagnosticAtToken(label_tok, "Undefined label '{s}'", .{label_name});
                    return error.ParseError;
                } else if (!found and self.is_ts) {
                    try self.emitDiagnosticAtToken(label_tok, "A 'continue' statement can only jump to a label of an enclosing iteration statement", .{});
                } else if (found and !is_loop_target and !self.is_ts) {
                    try self.emitDiagnosticAtToken(label_tok, "'continue' must refer to an enclosing iteration statement", .{});
                    return error.ParseError;
                }
            }
            try self.expectSemicolon();
            const node = try self.addNode(.{
                .tag = .continue_label,
                .main_token = cont_tok,
                .data = .{
                    .lhs = label_node,
                    .rhs = .none,
                },
            });
            try self.emitTerminator(.@"continue", node);
            return node;
        }

        try self.expectSemicolon();
        const node = try self.addNode(.{
            .tag = .continue_stmt,
            .main_token = cont_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        try self.emitTerminator(.@"continue", node);
        return node;
    }

    /// Parse `label: statement`.
    pub fn parseLabeledStatement(self: *Parser) Error!NodeIndex {
        const label_tok = self.advance(); // eat identifier (the label)
        // Check for contextual keyword labels that are restricted in certain contexts.
        const label_raw_tag = self.tokenTagAt(label_tok);
        if (label_raw_tag == .kw_await and !self.is_ts) {
            if (self.in_async or self.is_module or (self.in_static_block and !self.in_function)) {
                try self.emitDiagnosticAtToken(label_tok, "'await' cannot be used as a label in this context", .{});
                return error.ParseError;
            }
        }
        if (label_raw_tag == .kw_yield and !self.is_ts) {
            if (self.in_generator or self.in_strict) {
                try self.emitDiagnosticAtToken(label_tok, "'yield' cannot be used as a label in this context", .{});
                return error.ParseError;
            }
        }
        if (label_raw_tag == .escaped_keyword) {
            const text = self.tokenText(label_tok);
            var resolved_buf: [256]u8 = undefined;
            if (resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
                if (isAlwaysReservedStr(resolved) or
                    (self.in_strict and isStrictReservedStr(resolved)) or
                    (std.mem.eql(u8, resolved, "await") and
                        (self.in_async or self.is_module or (self.in_static_block and !self.in_function))) or
                    (std.mem.eql(u8, resolved, "yield") and (self.in_generator or self.in_strict)))
                {
                    try self.emitDiagnosticAtToken(label_tok, "escaped reserved word cannot be used as a label", .{});
                    return error.ParseError;
                }
            }
        }
        // Create the label node BEFORE consuming `:` so its end_tok records
        // only the identifier. Otherwise rules reporting on node.label (e.g.
        // no-unused-labels) get endColumn past the colon.
        const label_node = try self.addNode(.{
            .tag = .property_ident,
            .main_token = label_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        _ = try self.expect(.colon); // eat ':'

        const label_name = self.tokenText(label_tok);

        // Duplicate label check — always a SyntaxError per spec (not strict-only).
        {
            if (self.ts_label_stack) |stack| {
                var i: u8 = 0;
                while (i < self.ts_label_count) : (i += 1) {
                    if (std.mem.eql(u8, stack[i].name, label_name)) {
                        try self.emitDiagnostic(self.currentSpan(), "Duplicate label", .{});
                        if (!self.is_ts) return error.ParseError;
                        break;
                    }
                }
            }
        }

        // Push label onto stack for scope tracking (break/continue validation, dup detection).
        const prev_label_count = self.ts_label_count;
        // Determine if the label transitively wraps an iteration statement by looking ahead
        // through any chained labels (e.g. `a: b: c: while(...)` → a is a loop label).
        const is_loop_label_for_push = self.peeksAtIterationStmt();
        if (self.ts_label_count < 32) {
            if (self.ts_label_stack == null)
                self.ts_label_stack = try self.gpa.create([32]LabelEntry);
            self.ts_label_stack.?[self.ts_label_count] = .{
                .name = label_name,
                .fn_depth = self.ts_label_fn_depth,
                .is_loop = is_loop_label_for_push,
            };
            self.ts_label_count += 1;
        }
        defer self.ts_label_count = prev_label_count;

        // Labeled declarations are mostly forbidden
        // In TS mode, TypeScript allows labeled declarations (TS1344 is a semantic warning).
        switch (self.peek()) {
            .kw_class => {
                if (!self.is_ts) {
                    try self.emitDiagnostic(self.currentSpan(), "class declaration not allowed after label", .{});
                    return error.ParseError;
                }
            },
            .kw_const => {
                if (!self.is_ts) {
                    try self.emitDiagnostic(self.currentSpan(), "lexical declaration not allowed after label", .{});
                    return error.ParseError;
                }
            },
            .kw_var => {
                // TS1344: TypeScript considers label on var/lex declaration a semantic error.
                // We allow it at parse time (TypeScript parses it successfully).
            },
            .kw_let => {
                const next = self.peekAt(1);
                // `let [` is always forbidden after a label: either a lex decl (not allowed)
                // or an ExpressionStatement starting with `let [` (blocked by lookahead restriction).
                if (next == .l_bracket) {
                    try self.emitDiagnostic(self.currentSpan(), "lexical declaration not allowed after label", .{});
                    return error.ParseError;
                }
                const is_decl = blk: {
                    if (self.in_strict) break :blk true;
                    const could_be_binding = (next == .identifier or next == .l_brace or next.isKeyword());
                    break :blk could_be_binding and !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1));
                };
                if (is_decl and !self.is_ts) {
                    try self.emitDiagnostic(self.currentSpan(), "lexical declaration not allowed after label", .{});
                    return error.ParseError;
                }
                // `let` is an identifier expression — fall through to parseStatement
            },
            .kw_function => {
                if (!self.is_ts) {
                    if (self.peekAt(1) == .asterisk) {
                        try self.emitDiagnostic(self.currentSpan(), "generator declaration not allowed after label", .{});
                        return error.ParseError;
                    }
                    if (self.in_strict or !self.annex_b) {
                        try self.emitDiagnostic(self.currentSpan(), "In non-strict mode code, functions can only be declared at top level or inside a block", .{});
                        return error.ParseError;
                    }
                }
                // In TS mode: TypeScript allows labeled function/generator declarations
                // (emits TS1344 as a semantic warning, not a parse error).
            },
            .kw_async => {
                // `async function` and `async function*` are not allowed in labeled position.
                if (!self.is_ts and self.peekAt(1) == .kw_function and
                    !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1)))
                {
                    try self.emitDiagnostic(self.currentSpan(), "async function declaration not allowed after label", .{});
                    return error.ParseError;
                }
            },
            .kw_await => {
                // `await using x = ...` is a declaration, not allowed after label.
                if (!self.is_ts and self.peekAt(1) == .identifier and
                    std.mem.eql(u8, self.tokenText(@intCast(self.tok_i + 1)), "using") and
                    !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1)))
                {
                    try self.emitDiagnostic(self.currentSpan(), "'await using' declaration not allowed after label", .{});
                    return error.ParseError;
                }
            },
            .identifier => {
                // `using x = ...` is a declaration, not allowed after label.
                if (!self.is_ts and std.mem.eql(u8, self.tokenText(self.tokIdx()), "using")) {
                    const next = self.peekAt(1);
                    if ((next == .identifier or next == .kw_let) and
                        !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1)))
                    {
                        try self.emitDiagnostic(self.currentSpan(), "'using' declaration not allowed after label", .{});
                        return error.ParseError;
                    }
                }
            },
            .kw_import, .kw_export => {
                try self.emitDiagnostic(self.currentSpan(), "import/export not allowed after label", .{});
                return error.ParseError;
            },
            else => {},
        }

        const is_loop_label = switch (self.peek()) {
            .kw_while, .kw_for, .kw_do => true,
            else => false,
        };
        // Emit before parsing body so loop_open fires while pending_label is set.
        // We pass label_node (property_ident) — event_resolver reads label text from it.
        _ = try self.emitLabelOpen(is_loop_label, label_node);

        const stmt = try self.parseStatement();

        const node = try self.addNode(.{
            .tag = .labeled_stmt,
            .main_token = label_tok,
            .data = .{
                .lhs = stmt,
                .rhs = label_node,
            },
        });
        try self.emitLabelClose(node);
        return node;
    }

    /// Parse `try { } [catch (e) { }] [finally { }]`.
    pub fn parseTryStatement(self: *Parser) Error!NodeIndex {
        const try_tok = self.advance(); // eat 'try'
        // Look ahead for finalizer (determines has_finalizer for try_open event).
        // We don't have a single-token lookahead that can see past `catch { ... }`,
        // so we pre-count: a finalizer flag patched in after parsing.
        const try_ev = try self.emitTryOpen(false, .none);
        try self.emitBranchOpen(.none); // keep branch compatibility for node_reachable
        const block = try self.parseBlockStatement();
        try self.emitTryBodyEnd(.none);

        var catch_node: NodeIndex = .none;
        var finally_body: NodeIndex = .none;

        // Parse catch clause — emit it as a real catch_clause node so JS code
        // gets a stable NodeView (required for ESLint identity checks).
        if (self.eat(.kw_catch)) |catch_tok| {
            try self.emitBranchElse(.none);
            const try_catch_ev = try self.emitTryCatchStart(.none);
            const catch_scope_ev = try self.emitScopeOpen(.catch_clause, .none);
            var catch_param: NodeIndex = .none;
            if (self.eat(.l_paren)) |_| {
                catch_param = try self.parseBindingPattern();
                // TypeScript: catch clause can have a type annotation: `catch (e: unknown)`
                // TS1196: only `any` and `unknown` are allowed.
                if (self.is_ts and self.peek() == .colon) {
                    _ = self.advance(); // eat ':'
                    const type_tok = self.tokIdx();
                    const type_ann = try @import("typescript.zig").parseType(self);
                    _ = type_ann;
                    // Check if the type is `any` or `unknown` — only those are valid.
                    const tok_tag = self.tokenTagAt(type_tok);
                    const tok_text = if (tok_tag == .identifier) self.tokenText(type_tok) else "";
                    const is_any = tok_tag == .identifier and std.mem.eql(u8, tok_text, "any");
                    const is_unknown = tok_tag == .identifier and std.mem.eql(u8, tok_text, "unknown");
                    if (!is_any and !is_unknown) {
                        try self.emitDiagnosticAtToken(type_tok,
                            "Catch clause variable type annotation must be 'any' or 'unknown' if specified", .{});
                    }
                }
                try self.emitDeclaresFromPattern(catch_param, .catch_param);
                _ = try self.expect(.r_paren);
            }
            const catch_body = try self.parseBlockStatement();
            try checkCatchBindingConflicts(self, catch_param, catch_body);
            try self.emitScopeClose(.none);
            catch_node = try self.addNode(.{
                .tag = .catch_clause,
                .main_token = catch_tok,
                .data = .{ .lhs = catch_param, .rhs = catch_body },
            });
            self.patchScopeOpenNode(catch_scope_ev, catch_node);
            self.patchEventNode(try_catch_ev, catch_node);
            try self.emitTryCatchEnd(catch_node);
        }
        try self.emitBranchClose(.none);

        // Parse finally clause
        if (self.eat(.kw_finally)) |_| {
            const try_finally_ev = try self.emitTryFinallyStart(.none);
            // Mark has_finalizer retroactively on the try_open event.
            if (self.emit_scope_events)
                self.ev_ptr[try_ev].aux = 1;
            finally_body = try self.parseBlockStatement();
            self.patchEventNode(try_finally_ev, finally_body);
        }

        // Must have at least catch or finally.
        if (catch_node == .none and finally_body == .none) {
            try self.emitDiagnosticAtToken(try_tok, "'try' must be followed by 'catch' or 'finally'", .{});
        }

        const extra = try self.addExtra(ast.TryData, .{
            .catch_node = catch_node,
            .finally_body = finally_body,
        });

        const try_node = try self.addNode(.{
            .tag = .try_stmt,
            .main_token = try_tok,
            .data = .{
                .lhs = block,
                .rhs = NodeIndex.fromInt(extra),
            },
        });
        self.patchEventNode(try_ev, try_node);
        try self.emitTryClose(try_node);
        return try_node;
    }

    /// Parse `debugger;`.
    pub fn parseDebuggerStatement(self: *Parser) Error!NodeIndex {
        const dbg_tok = self.advance(); // eat 'debugger'
        try self.expectSemicolon();
        return self.addNode(.{
            .tag = .debugger_stmt,
            .main_token = dbg_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }

    /// Parse `with (expr) stmt`.
    pub fn parseWithStatement(self: *Parser) Error!NodeIndex {
        // In TS mode, only emit the strict-mode 'with' error when strict mode comes from
        // a top-level "use strict" directive or ES module (in_function = false).  Class
        // bodies set in_strict = true but TypeScript handles that with TS1101 semantically.
        if (self.in_strict and (!self.is_ts or !self.in_function)) {
            try self.emitDiagnostic(self.currentSpan(), "'with' statements are not allowed in strict mode", .{});
            // Continue parsing to avoid cascading failures
        } else if (self.is_ts and self.in_async and self.in_function) {
            // TS1300: 'with' is not allowed inside an explicit async function body.
            // Note: in_async is true by default for all TS files (to allow top-level await),
            // so we also require in_function to distinguish async function bodies from top-level.
            try self.emitDiagnostic(self.currentSpan(), "'with' statements are not allowed in an async function block", .{});
        }
        const with_tok = self.advance(); // eat 'with'
        _ = try self.expect(.l_paren);
        const object = try self.parseExpression();
        _ = try self.expect(.r_paren);
        const with_scope_ev = try self.emitScopeOpen(.with_stmt, .none);
        const prev_in_with = self.in_with;
        self.in_with = true;
        defer self.in_with = prev_in_with;
        const body = try self.parseNonDeclStatement();
        if (!self.in_strict and isLabelledFunction(self, body)) {
            try self.emitDiagnostic(self.currentSpan(), "Labeled function declarations are not allowed in loop or if-statement bodies", .{});
        }
        try self.emitScopeClose(.none);

        const with_node = try self.addNode(.{
            .tag = .with_stmt,
            .main_token = with_tok,
            .data = .{
                .lhs = object,
                .rhs = body,
            },
        });
        self.patchScopeOpenNode(with_scope_ev, with_node);
        return with_node;
    }

    // ────────────────────────────────────────────────────────────
    // Declaration parsers
    // ────────────────────────────────────────────────────────────

    /// Parse `var/let/const declarators` with trailing semicolon.
    pub fn parseVariableDeclaration(self: *Parser) Error!NodeIndex {
        const decl_tok = self.advance(); // eat var/let/const
        const decl_tag: TokenTag = self.tokenTagAt(decl_tok);
        const is_const = decl_tag == .kw_const;
        // In TS mode, `const x;` is valid without initializer when in an ambient context
        // (`declare const x;`, inside `declare namespace { ... }`, etc.)
        const is_ts_ambient = self.is_ts and is_const and self.in_ts_ambient;

        const tag: Node.Tag = switch (decl_tag) {
            .kw_var => .var_decl,
            .kw_let => .let_decl,
            .kw_const => .const_decl,
            else => unreachable,
        };
        const binding_kind: BindingKindU8 = switch (decl_tag) {
            .kw_var => .@"var",
            .kw_let => .let,
            .kw_const => .@"const",
            else => unreachable,
        };

        // "let" as a binding name in let/const declaration is always invalid
        if ((decl_tag == .kw_let or decl_tag == .kw_const) and self.peek() == .kw_let) {
            try self.emitDiagnostic(self.currentSpan(), "'let' is not allowed as a variable name in lexical declarations", .{});
            return error.ParseError;
        }

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const prev_lex = self.in_lexical_decl;
        self.in_lexical_decl = (decl_tag == .kw_let or decl_tag == .kw_const);
        defer self.in_lexical_decl = prev_lex;

        // Parse first declarator (required)
        const first = try self.parseDeclaratorConst(is_const, is_ts_ambient);
        try self.scratchPush(first);
        try self.emitDeclareFromDeclarator(first, binding_kind);

        // Parse additional declarators separated by commas
        while (self.eat(.comma) != null) {
            const decl = try self.parseDeclaratorConst(is_const, is_ts_ambient);
            try self.scratchPush(decl);
            try self.emitDeclareFromDeclarator(decl, binding_kind);
        }

        // Consume semicolon BEFORE creating the node so the range includes it
        try self.expectSemicolon();

        const decls = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(decls);

        return self.addNode(.{
            .tag = tag,
            .main_token = decl_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(range.start),
                .rhs = NodeIndex.fromInt(range.end),
            },
        });
    }

    /// Parse `var/let/const declarators` without consuming trailing semicolon.
    /// Used by for-loop head parsing.
    pub fn parseVariableDeclarationNoSemicolon(self: *Parser) Error!NodeIndex {
        const decl_tok = self.advance(); // eat var/let/const
        const decl_tag: TokenTag = self.tokenTagAt(decl_tok);
        const is_const = decl_tag == .kw_const;
        const is_ts_ambient = self.is_ts and is_const and self.in_ts_ambient;

        const tag: Node.Tag = switch (decl_tag) {
            .kw_var => .var_decl,
            .kw_let => .let_decl,
            .kw_const => .const_decl,
            else => unreachable,
        };
        const binding_kind: BindingKindU8 = switch (decl_tag) {
            .kw_var => .@"var",
            .kw_let => .let,
            .kw_const => .@"const",
            else => unreachable,
        };

        // "let" as a binding name in let/const declaration is always invalid
        if ((decl_tag == .kw_let or decl_tag == .kw_const) and self.peek() == .kw_let) {
            try self.emitDiagnostic(self.currentSpan(), "'let' is not allowed as a variable name in lexical declarations", .{});
            return error.ParseError;
        }

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const prev_lex = self.in_lexical_decl;
        self.in_lexical_decl = (decl_tag == .kw_let or decl_tag == .kw_const);
        defer self.in_lexical_decl = prev_lex;

        // Parse first declarator (required)
        const first = try self.parseDeclaratorConst(is_const, is_ts_ambient);
        try self.scratchPush(first);
        try self.emitDeclareFromDeclarator(first, binding_kind);

        // Parse additional declarators separated by commas
        while (self.eat(.comma) != null) {
            const decl = try self.parseDeclaratorConst(is_const, is_ts_ambient);
            try self.scratchPush(decl);
            try self.emitDeclareFromDeclarator(decl, binding_kind);
        }

        const decls = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(decls);

        return self.addNode(.{
            .tag = tag,
            .main_token = decl_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(range.start),
                .rhs = NodeIndex.fromInt(range.end),
            },
        });
    }

    /// Parse `binding [: Type] = init`, with optional const-requires-initializer check.
    fn parseDeclaratorConst(self: *Parser, is_const: bool, is_ts_ambient: bool) Error!NodeIndex {
        const main_tok: u32 = self.tokIdx();
        const binding = try self.parseBindingPattern();

        // TS definite assignment: `let x!;` or `let x!: Type;`
        const had_definite_bang = self.is_ts and self.eat(.bang) != null;
        const type_annotation = try self.parseOptionalTypeAnnotation();

        // Attach type annotation to identifier binding (structurally derivable).
        if (type_annotation != .none) {
            const binding_tag = self.node_tags_ptr[binding.toInt()];
            if (binding_tag == .identifier) {
                self.node_data_ptr[binding.toInt()].rhs = type_annotation;
                // Extend identifier range through the type annotation so rules
                // that report `node: identifier` get the full typed span.
                // (Same treatment as parameter identifiers at parseParam.)
                self.node_end_toks[binding.toInt()] = if (self.tok_i > 0) @intCast(self.tok_i - 1) else 0;
                // The annotation now lives in the identifier's data.rhs, so its
                // parent is derivable by buildParentsOnly — no fixup needed.
            }
        }

        // Optional initializer.  If the binding is a simple identifier, snapshot
        // its name so named fn/class expressions inside the init can detect the
        // matching-name case (ESLint's fn_expr_exceptions rule).
        const saved_decl_name = self.decl_name_text;
        if (self.emit_scope_events and binding != .none) {
            if (self.node_tags_ptr[binding.toInt()] == .identifier) {
                self.decl_name_text = self.tokenText(self.node_main_token_ptr[binding.toInt()]);
            }
        }
        defer self.decl_name_text = saved_decl_name;

        // TS1263: `let x! = value` — definite assignment assertion with initializer is invalid.
        if (had_definite_bang and self.peek() == .equal) {
            try self.emitDiagnostic(self.currentSpan(), "Declarations with initializers cannot also have definite assignment assertions", .{});
        }

        const init: NodeIndex = if (self.eat(.equal) != null)
            try self.parseAssignmentExpression()
        else
            .none;

        // Cover-grammar: `{x = 1}` shorthand-with-default is only valid as
        // destructuring pattern. As an initializer expression it's invalid.
        if (init != .none) try self.validateNoCoverInitName(init);

        // Destructuring patterns require an initializer — UNLESS in for-in/of context
        // where the value comes from the iterable (e.g., `for (const [a, b] of iter)`)
        const for_next = self.peek();
        if (init == .none and for_next != .kw_in and for_next != .kw_of) {
            const binding_tag = self.node_tags_ptr[binding.toInt()];
            if (binding_tag == .array_pattern or binding_tag == .object_pattern) {
                if (self.is_ts and self.in_ts_ambient) {
                    // TS1182 in ambient context is a semantic error; parser accepts it
                } else {
                    try self.emitDiagnostic(self.currentSpan(), "Missing initializer in destructuring declaration", .{});
                    if (!self.is_ts) return error.ParseError;
                }
            }
            // const declarations always require an initializer (except in TS ambient contexts)
            if (is_const and !(self.is_ts and is_ts_ambient)) {
                try self.emitDiagnostic(self.currentSpan(), "Missing initializer in const declaration", .{});
                // Soft error in TS — continue producing the declarator so
                // type-aware tools still see the binding's annotation.
                if (!self.is_ts) return error.ParseError;
            }
        }

        return self.addNode(.{
            .tag = .declarator,
            .main_token = main_tok,
            .data = .{
                .lhs = binding,
                .rhs = init,
            },
        });
    }

    /// Parse `[async] function [*] name(params) { body }`.
    /// Handle async (check if previous token was contextual 'async' on same line)
    /// and generator (*).
    pub fn parseFunctionDeclaration(self: *Parser) Error!NodeIndex {
        var is_async = false;
        var main_tok: u32 = self.tokIdx();

        // Check for `async function`
        if (self.peek() == .kw_async) {
            is_async = true;
            main_tok = self.advance(); // eat 'async'
        }

        _ = try self.expect(.kw_function);

        // Check for generator: `function*`
        const is_generator = self.eat(.asterisk) != null;
        // TS1221: Generators are not allowed in an ambient context.
        if (is_generator and self.is_ts and self.in_ts_ambient) {
            try self.emitDiagnostic(self.currentSpan(), "Generators are not allowed in an ambient context", .{});
        }

        // Function name (required unless export default) — hoist peek to avoid
        // re-reading the tag on every branch of this if-else chain.
        const fn_name_tag = self.peek();
        const name: NodeIndex = if (fn_name_tag == .identifier) blk: {
            // Check strict-mode restrictions on function name
            try self.checkStrictBinding(self.tokIdx());
            break :blk try self.parseIdentifier();
        } else if (fn_name_tag == .kw_yield and !self.in_generator and !self.in_strict and !self.is_ts) blk: {
            break :blk try self.parseIdentifier();
        } else if (fn_name_tag == .kw_await and
            !self.is_module and
            !(self.in_static_block and !self.in_function) and
            (!self.in_async or (self.is_ts and !self.in_function and !self.is_module))) blk: {
            break :blk try self.parseIdentifier();
        } else if ((fn_name_tag == .kw_let or fn_name_tag == .kw_static or
            fn_name_tag == .kw_implements or fn_name_tag == .kw_interface or
            fn_name_tag == .kw_async) and !self.in_strict and !self.is_ts)
        blk: {
            break :blk try self.parseIdentifier();
        } else if (fn_name_tag == .kw_get or fn_name_tag == .kw_set or
            fn_name_tag == .kw_of or fn_name_tag == .kw_from or fn_name_tag == .kw_as or
            fn_name_tag == .kw_target or fn_name_tag == .kw_meta)
        blk: {
            // Contextual keywords are valid binding names in any mode.
            break :blk try self.parseIdentifier();
        } else if (self.is_ts and (fn_name_tag.isTsContextualKeyword() or fn_name_tag == .kw_is))
        blk: {
            break :blk try self.parseIdentifier();
        } else .none;

        if (name == .none and !self.in_export_default) {
            try self.emitDiagnostic(self.currentSpan(), "function declaration requires a name", .{});
        }

        // Function declaration binds its name in the enclosing scope, then
        // opens a function scope for params + body.
        if (name != .none) {
            const fn_kind: BindingKindU8 = if (self.in_annexb_fn_position) .function_decl_annex_b else .function_decl;
            try self.emitDeclare(fn_kind, name);
        }
        const fn_scope_ev = try self.emitScopeOpen(.function, .none);

        // Set generator/async flags BEFORE parsing params — yield/await are
        // reserved in the parameter list of generator/async functions.
        const prev_in_function = self.in_function;
        const prev_in_async = self.in_async;
        const prev_in_generator = self.in_generator;
        const prev_in_class_field = self.in_class_field;
        const prev_nta_fd = self.new_target_allowed;
        const prev_ts_label_fn_depth = self.ts_label_fn_depth;
        const prev_in_loop_fd = self.in_loop;
        const prev_in_switch_fd = self.in_switch;
        const prev_ts_label_count_fd = self.ts_label_count;
        self.in_function = true;
        self.in_async = is_async;
        self.in_generator = is_generator;
        // Function body has its own `arguments` binding — clears class-field restriction.
        self.in_class_field = false;
        self.new_target_allowed = true;
        // Reset loop/switch/label context — they don't cross function boundaries.
        self.in_loop = false;
        self.in_switch = false;
        self.ts_label_count = 0;
        if (self.ts_label_fn_depth < std.math.maxInt(u16)) self.ts_label_fn_depth += 1;
        self.syncYieldLex();

        self.emit_fn_type_params = true;
        const fn_type_params = try self.parseOptionalTypeParameters();
        self.emit_fn_type_params = false;
        const params = try self.parseFormalParameters();
        self.in_return_type = true;
        const fn_return_type = try self.parseOptionalTypeAnnotation();
        self.in_return_type = false;
        defer {
            self.in_function = prev_in_function;
            self.in_async = prev_in_async;
            self.in_generator = prev_in_generator;
            self.in_class_field = prev_in_class_field;
            self.new_target_allowed = prev_nta_fd;
            self.ts_label_fn_depth = prev_ts_label_fn_depth;
            self.in_loop = prev_in_loop_fd;
            self.in_switch = prev_in_switch_fd;
            self.ts_label_count = prev_ts_label_count_fd;
            self.syncYieldLex();
        }

        const prev_strict = self.in_strict;
        if (self.peek() == .l_brace) _ = self.checkDirectivePrologueAt(@intCast(self.tok_i + 1));
        if (self.in_strict != prev_strict) self.syncYieldLex();
        defer { self.in_strict = prev_strict; self.syncYieldLex(); }

        if (self.in_strict and !prev_strict) {
            // Function name must not be eval/arguments or strict-reserved in strict mode
            if (name != .none) {
                const fn_name_tok = self.node_main_token_ptr[name.toInt()];
                const fn_name_text = self.tokenText(fn_name_tok);
                if (std.mem.eql(u8, fn_name_text, "eval") or std.mem.eql(u8, fn_name_text, "arguments")) {
                    try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a function name in strict mode", .{fn_name_text});
                    return error.ParseError;
                }
                if (!self.is_ts and self.isStrictReservedWord(fn_name_tok)) {
                    try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a function name in strict mode", .{fn_name_text});
                    return error.ParseError;
                }
            }
            try self.checkParamsStrictMode(params);
            // ES2016+: 'use strict' directive forbidden when params are non-simple
            // (destructuring / default values / rest). In TypeScript, this is
            // TS1346/TS1347 (target-dependent, semantic-only), so skip in TS mode.
            if (!self.is_ts and hasNonSimpleParam(self, params)) {
                try self.emitError("Illegal 'use strict' directive in function with non-simple parameter list");
            }
        }
        // Duplicate params: rejected when strict OR params are non-simple.
        if (self.in_strict or hasNonSimpleParam(self, params)) {
            try self.checkUniqueParams(params);
        }

        // TS ambient/declare functions and overload signatures have no body.
        if (self.is_ts and self.peek() != .l_brace) {
            // TS1222: An overload signature cannot be declared as a generator.
            if (is_generator and !self.in_ts_ambient) {
                try self.emitDiagnostic(self.currentSpan(), "An overload signature cannot be declared as a generator", .{});
            }
            _ = self.eat(.semicolon);
            try self.emitScopeClose(.none); // close function scope (no body)
            const decl_extra = try self.addExtra(ast.FnData, .{
                .name = name,
                .params = params.start,
                .params_end = params.end,
                .body = .none,
                .return_type = fn_return_type,
                .type_params = fn_type_params.start,
                .type_params_end = fn_type_params.end,
            });
            // If preceded by 'declare' keyword, use that as main_token so the node
            // starts at 'declare' (important for comment attachment by ESLint).
            const decl_main_tok = if (main_tok > 0 and
                self.tokenTagAt(main_tok - 1) == .kw_declare)
                main_tok - 1
            else
                main_tok;
            const decl_node = try self.addNode(.{
                .tag = .ts_declare_function,
                .main_token = decl_main_tok,
                .data = .{ .lhs = NodeIndex.fromInt(decl_extra), .rhs = .none },
            });
            self.patchScopeOpenNode(fn_scope_ev, decl_node);
            return decl_node;
        }

        // TS1183: An implementation cannot be declared in ambient contexts.
        if (self.is_ts and self.in_ts_ambient) {
            try self.emitDiagnostic(self.currentSpan(), "An implementation cannot be declared in ambient contexts", .{});
        }
        self.is_fn_body_block = true;
        const prev_fp_body = self.in_fn_params;
        self.in_fn_params = false; // body is outside params — clear for nested await/yield
        defer self.in_fn_params = prev_fp_body;
        const body = try self.parseBlockStatement();
        // Param vs lex body conflict: applies to generators, async, methods, and strict.
        if (self.in_async or self.in_generator or self.in_method or self.in_strict) {
            try self.checkParamBodyLexConflict(params, body);
        }
        try self.emitScopeClose(.none); // close function scope

        const tag: Node.Tag = if (is_async and is_generator)
            .async_generator_fn_decl
        else if (is_async)
            .async_fn_decl
        else if (is_generator)
            .generator_fn_decl
        else
            .fn_decl;

        const extra = try self.addExtra(ast.FnData, .{
            .name = name,
            .params = params.start,
            .params_end = params.end,
            .body = body,
            .return_type = fn_return_type,
            .type_params = fn_type_params.start,
            .type_params_end = fn_type_params.end,
        });

        const node = try self.addNode(.{
            .tag = tag,
            .main_token = main_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(extra),
                .rhs = .none,
            },
        });
        self.patchScopeOpenNode(fn_scope_ev, node);
        return node;
    }

    /// Parse `class name [extends expr] { body }`.
    pub fn parseClassDeclaration(self: *Parser) Error!NodeIndex {
        const class_tok = self.advance(); // eat 'class'

        // Class name (required for declarations, optional for export default class / expressions).
        // Class bodies are always strict mode — class name itself is also strict-mode-validated.
        const name: NodeIndex = blk: {
            const next = self.peek();
            if (next == .identifier or next == .escaped_keyword) {
                const tok_ix: u32 = self.tokIdx();
                const id = try self.parseIdentifier();
                // Strict reserved (let/yield/static/etc) via escape — reject.
                if (self.isStrictReservedWord(tok_ix)) {
                    try self.emitDiagnostic(self.currentSpan(),
                        "'{s}' is not a valid class name in strict mode", .{self.tokenText(tok_ix)});
                    return error.ParseError;
                }
                // `await` reserved in module / async function (escape form too).
                if (self.is_module or self.in_async) {
                    const t = self.tokenText(tok_ix);
                    if (std.mem.indexOfScalar(u8, t, '\\') != null) {
                        var rb: [256]u8 = undefined;
                        if (resolveUnicodeEscapesParser(t, &rb)) |r| {
                            if (std.mem.eql(u8, r, "await")) {
                                try self.emitDiagnostic(self.currentSpan(),
                                    "'await' cannot be used as identifier here", .{});
                                return error.ParseError;
                            }
                        }
                    }
                }
                break :blk id;
            }
            if (next == .kw_await and !self.in_async and !self.is_module and !(self.in_static_block and !self.in_function)) break :blk try self.parseIdentifier();
            // Class is always strict mode — `yield` is never a valid class name.
            if (next == .kw_yield) {
                try self.emitDiagnostic(self.currentSpan(), "'yield' is not a valid class name in strict mode", .{});
                return error.ParseError;
            }
            if (self.is_ts and next == .kw_abstract and self.peekAt(1) == .l_brace) break :blk try self.parseIdentifier();
            break :blk .none;
        };

        // class declaration requires a name (unless export default)
        if (name == .none and !self.in_export_default) {
            try self.emitDiagnostic(self.currentSpan(), "class declaration requires a name", .{});
            return error.ParseError;
        }

        // Class declaration binds its name in the enclosing scope, then opens
        // a class scope for members (plus an inner body scope, but ESLint's
        // model uses just one class scope for declarations). The name is ALSO
        // declared inside the class's own scope (per ESLint's scope-manager
        // model — the class name is a self-reference visible inside the
        // class body). Rules like unicorn/prevent-abbreviations rely on
        // seeing both copies (outer + inner) of the class name.
        if (name != .none) try self.emitDeclare(.class_decl, name);
        const class_scope_ev = try self.emitScopeOpen(.class, .none);
        if (name != .none) try self.emitDeclare(.class_decl, name);

        // TS type parameters: class Foo<T, U>
        const class_type_params = if (self.is_ts and self.peek() == .less_than) blk: {
            break :blk try typescript.parseTypeParameterList(self);
        } else ast.SubRange{ .start = 0, .end = 0 };

        // Class definitions (including extends clause and body) are always strict mode code.
        const prev_strict_class = self.in_strict;
        self.in_strict = true;
        self.syncYieldLex();
        defer { self.in_strict = prev_strict_class; self.syncYieldLex(); }

        // Optional: extends superClass (must be LeftHandSideExpression)
        const super_class: NodeIndex = if (self.eat(.kw_extends) != null) blk: {
            if (self.is_ts) {
                // Parse the first extends expression.
                // parseAssignmentExpression handles TS type arguments (A<T>) via tryParseTsTypeArguments,
                // so `class C extends React.Component<Props>` correctly produces a MemberExpression
                // for React.Component and consumes the <Props> type args.
                const expr = try self.parseAssignmentExpression();
                // TS1174: Classes can only extend a single class.
                if (self.peek() == .comma) {
                    try self.emitDiagnostic(self.currentSpan(), "Classes can only extend a single class", .{});
                    while (self.peek() == .comma) {
                        _ = self.advance();
                        _ = try typescript.parseType(self);
                    }
                }
                break :blk expr;
            }
            const expr = try self.parseAssignmentExpression();
            // Reject binary/unary expressions and arrow functions in extends
            const expr_tag = self.node_tags_ptr[expr.toInt()];
            switch (expr_tag) {
                .add, .subtract, .multiply, .divide, .modulo, .exponentiate,
                .equal, .not_equal, .strict_equal, .strict_not_equal,
                .less_than, .greater_than, .less_equal, .greater_equal,
                .logical_and, .logical_or, .nullish_coalesce,
                .bitwise_and, .bitwise_or, .bitwise_xor,
                .shift_left, .shift_right, .unsigned_shift_right,
                .logical_not, .bitwise_not, .unary_plus, .unary_minus,
                .instanceof_expr, .in_expr,
                .arrow_fn, .async_arrow_fn,
                => try self.emitDiagnostic(self.currentSpan(), "extends requires a constructor, not an expression", .{}),
                else => {},
            }
            break :blk expr;
        } else .none;

        // TS implements clause: class Foo implements Bar, Baz<T>
        // Store the main_token of each ts_type_reference (= the name identifier token).
        // JS reads these as plain token-index lookups into tokStarts/tokEnds.
        var impls_range = ast.SubRange{ .start = 0, .end = 0 };
        if (self.is_ts and self.peek() == .kw_implements) {
            _ = self.advance(); // eat 'implements'
            const scratch_top = self.scratch.items.len;
            const first_impl = try typescript.parseType(self);
            try self.scratchPush(self.node_main_token_ptr[@intFromEnum(first_impl)]);
            while (self.peek() == .comma) {
                _ = self.advance();
                const impl = try typescript.parseType(self);
                try self.scratchPush(self.node_main_token_ptr[@intFromEnum(impl)]);
            }
            impls_range = try self.listToSubRange(self.scratch.items[scratch_top..]);
            self.scratch.shrinkRetainingCapacity(scratch_top);
        }

        const l_brace_tok = try self.expect(.l_brace);
        const prev_heritage = self.class_has_heritage;
        self.class_has_heritage = (super_class != .none);
        defer self.class_has_heritage = prev_heritage;
        // Track if this is an abstract class (so parseClassMember can check TS1244).
        const is_abstract_class = self.is_ts and class_tok > 0 and
            self.tokenTagAt(class_tok - 1) == .kw_abstract;
        const prev_abstract = self.in_abstract_class;
        self.in_abstract_class = is_abstract_class;
        defer self.in_abstract_class = prev_abstract;
        const body_range = try self.parseClassBody();
        _ = try self.expect(.r_brace);
        try self.emitScopeClose(.none); // close class scope

        const class_body_node = try self.addNode(.{
            .tag = .class_body,
            .main_token = l_brace_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(body_range.start),
                .rhs = NodeIndex.fromInt(body_range.end),
            },
        });
        const extra = try self.addExtra(ast.ClassData, .{
            .name = name,
            .super_class = super_class,
            .body = class_body_node,
            .impls_start = impls_range.start,
            .impls_end = impls_range.end,
            .type_params = class_type_params.start,
            .type_params_end = class_type_params.end,
        });

        const class_node = try self.addNode(.{
            .tag = .class_decl,
            .main_token = class_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(extra),
                .rhs = .none,
            },
        });
        self.patchScopeOpenNode(class_scope_ev, class_node);
        return class_node;
    }

    /// Parse class members: methods, properties, static blocks, getters/setters,
    /// computed keys.
    pub fn parseClassBody(self: *Parser) Error!SubRange {
        const prev_in_class = self.in_class;
        const prev_strict = self.in_strict;
        const prev_in_static_block_cb = self.in_static_block;
        self.in_class = true;
        self.in_strict = true; // class bodies are always strict
        self.in_static_block = false; // nested class resets static-block context
        self.syncYieldLex();
        defer self.in_class = prev_in_class;
        defer self.in_static_block = prev_in_static_block_cb;
        defer { self.in_strict = prev_strict; self.syncYieldLex(); }

        // AllPrivateNamesValid: snapshot stack lengths to scope private decls
        // and refs to this class body. On exit, validate refs against decls.
        const private_decls_start = self.private_decls.items.len;
        const private_refs_start = self.private_refs.items.len;
        self.class_body_depth += 1;
        defer self.class_body_depth -= 1;

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (self.peek() != .r_brace and !self.isAtEnd()) {
            // Skip empty statements (semicolons) in class body
            if (self.eat(.semicolon) != null) continue;

            const before = self.tok_i;
            const member = self.parseClassMember() catch |err| switch (err) {
                error.ParseError => {
                    self.synchronize();
                    // Guarantee forward progress: if recovery consumed nothing
                    // (e.g. on a `<<<<<<<` conflict marker), advance one token so
                    // the loop can't spin and exhaust memory appending error nodes.
                    if (self.tok_i == before) _ = self.advance();
                    try self.pushErrorNode();
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            try self.scratchPush(member);
        }

        const members = self.scratch.items[scratch_top..];

        // PrivateBoundNames: duplicates are SyntaxError (getter+setter pair allowed).
        // Also collects this class's private decls into self.private_decls so
        // AllPrivateNamesValid can resolve references.
        {
            var seen = std.StringHashMap(u32).init(self.gpa);
            defer seen.deinit();
            for (members) |idx_int| {
                const m = NodeIndex.fromInt(idx_int);
                if (m == .none) continue;
                const m_tag = self.node_tags_ptr[m.toInt()];
                if (m_tag != .property_def and m_tag != .method_def and
                    m_tag != .getter_def and m_tag != .setter_def) continue;
                const m_data = self.node_data_ptr[m.toInt()];
                const key = m_data.lhs;
                if (key == .none) continue;
                const key_tag = self.node_tags_ptr[key.toInt()];
                if (key_tag != .identifier) continue;
                const key_tok = self.node_main_token_ptr[key.toInt()];
                if (self.tokenTagAt(key_tok) != .hash) continue;
                if (!self.tokenExists(key_tok + 1)) continue;
                const name_text = self.tokenText(key_tok + 1);
                // Check if this member is static.
                const extra_idx = m_data.rhs.toInt();
                const is_static_member = if (extra_idx + 4 < self.extra_data.items.len)
                    (self.extra_data.items[extra_idx + 4] & ast.ModifierBit.@"static") != 0
                else
                    false;
                // Bit encoding: non-static getter=1, non-static setter=2, static getter=4,
                // static setter=8, non-static other=16, static other=32.
                // Allowed pairs: 1|2 (non-static g+s) or 4|8 (static g+s).
                const bit: u32 = switch (m_tag) {
                    .getter_def => if (is_static_member) @as(u32, 4) else @as(u32, 1),
                    .setter_def => if (is_static_member) @as(u32, 8) else @as(u32, 2),
                    else => if (is_static_member) @as(u32, 32) else @as(u32, 16),
                };
                const gop = try seen.getOrPut(name_text);
                if (!gop.found_existing) {
                    gop.value_ptr.* = bit;
                    try self.private_decls.append(self.gpa, name_text);
                } else {
                    const combined = gop.value_ptr.* | bit;
                    // Allowed: non-static getter+setter (1|2=3) or static getter+setter (4|8=12)
                    const allowed = combined == (1 | 2) or combined == (4 | 8);
                    if (!allowed and !self.is_ts) {
                        try self.emitError("Duplicate private name in class body");
                        return error.ParseError;
                    }
                    gop.value_ptr.* = combined;
                }
            }
        }

        // AllPrivateNamesValid: refs accumulated in this class body that don't
        // match a decl in scope are propagated to the parent class's pending
        // list (a decl in an enclosing class may still resolve them). When
        // the OUTERMOST class closes (depth was 1), any unresolved refs are
        // SyntaxErrors.
        {
            const refs_slice = self.private_refs.items[private_refs_start..];
            const decls_in_scope = self.private_decls.items;
            var ref_buf: [128]u8 = undefined;
            var decl_buf: [128]u8 = undefined;
            var write: usize = private_refs_start;
            const outermost = (self.class_body_depth == 1);
            for (refs_slice) |hash_tok| {
                if (!self.tokenExists(hash_tok + 1)) continue;
                const name = self.tokenText(hash_tok + 1);
                const ref_len = decodeIdentForCompare(name, &ref_buf);
                const ref_norm = ref_buf[0..ref_len];
                var found = false;
                for (decls_in_scope) |d| {
                    const dl = decodeIdentForCompare(d, &decl_buf);
                    if (std.mem.eql(u8, decl_buf[0..dl], ref_norm)) { found = true; break; }
                }
                if (!found) {
                    if (outermost and !self.is_ts) {
                        const span = Span{
                            .start = self.tok_starts_ptr[hash_tok],
                            .end = self.tok_starts_ptr[hash_tok],
                        };
                        try self.emitDiagnostic(span, "Reference to undeclared private name '#{s}'", .{name});
                        return error.ParseError;
                    }
                    self.private_refs.items[write] = hash_tok;
                    write += 1;
                }
            }
            self.private_refs.shrinkRetainingCapacity(write);
            self.private_decls.shrinkRetainingCapacity(private_decls_start);
        }

        // Duplicate constructor check: only one non-static constructor allowed per class.
        if (!self.is_ts) {
            var ctor_count: u8 = 0;
            for (members) |idx_int| {
                const m = NodeIndex.fromInt(idx_int);
                if (m == .none) continue;
                const m_tag = self.node_tags_ptr[m.toInt()];
                if (m_tag != .method_def) continue;
                const m_data = self.node_data_ptr[m.toInt()];
                const key = m_data.lhs;
                if (key == .none) continue;
                const key_tag = self.node_tags_ptr[key.toInt()];
                const key_tok = self.node_main_token_ptr[key.toInt()];
                const is_ctor_name = (key_tag == .identifier and
                    std.mem.eql(u8, self.tokenText(key_tok), "constructor")) or
                    (key_tag == .string_literal and
                    std.mem.eql(u8, self.getStringContent(self.tokenStart(key_tok)), "constructor"));
                if (!is_ctor_name) continue;
                // Check if static (bit 6 in modifiers at extra_data[rhs + 4])
                const extra_idx = m_data.rhs.toInt();
                if (extra_idx + 4 < self.extra_data.items.len) {
                    const modifiers = self.extra_data.items[extra_idx + 4];
                    if ((modifiers & ast.ModifierBit.@"static") != 0) continue;
                }
                ctor_count += 1;
                if (ctor_count > 1) {
                    try self.emitError("A class may only have one constructor");
                    return error.ParseError;
                }
            }
        }

        return self.listToSubRange(members);
    }

    const TsModifierFlags = struct {
        has_public: bool = false,
        has_private: bool = false,
        has_protected: bool = false,
        has_abstract: bool = false,
        has_override: bool = false,
        has_readonly: bool = false,
        has_declare: bool = false,
        has_export: bool = false,
        has_accessibility: bool = false, // any of public/private/protected
        has_accessor: bool = false,

        fn merge(self: TsModifierFlags, other: TsModifierFlags) TsModifierFlags {
            return .{
                .has_public = self.has_public or other.has_public,
                .has_private = self.has_private or other.has_private,
                .has_protected = self.has_protected or other.has_protected,
                .has_abstract = self.has_abstract or other.has_abstract,
                .has_override = self.has_override or other.has_override,
                .has_readonly = self.has_readonly or other.has_readonly,
                .has_declare = self.has_declare or other.has_declare,
                .has_export = self.has_export or other.has_export,
                .has_accessibility = self.has_accessibility or other.has_accessibility,
                .has_accessor = self.has_accessor or other.has_accessor,
            };
        }
    };

    /// Parse TypeScript class member modifiers with validation.
    /// Order: declare → access(public/private/protected) → static → abstract → override → readonly
    fn parseTsModifiers(self: *Parser) Error!TsModifierFlags {
        var flags = TsModifierFlags{};
        // Track modifier order phase (higher number = later in order)
        var last_phase: u8 = 0;
        while (true) {
            const mod_tag = self.peek();
            if (mod_tag != .identifier and mod_tag != .kw_abstract and
                mod_tag != .kw_readonly and mod_tag != .kw_override and
                mod_tag != .kw_declare and mod_tag != .kw_export) break;
            // Load token text only for .identifier (public/private/protected);
            // keyword tags (abstract, override, readonly, declare, export) skip text entirely.
            const text: []const u8 = if (mod_tag == .identifier) self.tokenText(self.tokIdx()) else "";
            const mod_kind: enum { access, abstract, override, readonly, declare, @"export", not_modifier } =
                switch (mod_tag) {
                    .kw_abstract => .abstract,
                    .kw_override => .override,
                    .kw_readonly => .readonly,
                    .kw_declare  => .declare,
                    .kw_export   => .@"export",
                    .identifier  => if (std.mem.eql(u8, text, "public") or
                                       std.mem.eql(u8, text, "private") or
                                       std.mem.eql(u8, text, "protected")) .access
                                    else .not_modifier,
                    else => .not_modifier,
                };

            if (mod_kind == .not_modifier) break;

            // Only consume if followed by something that could be a member name
            const next = self.peekAt(1);
            if (next == .l_paren or next == .equal or next == .semicolon or
                next == .r_brace or next == .colon or
                // `public<T>()` — `public` is a method name with type params, not a modifier
                next == .less_than)
                break;

            // Check for duplicate modifiers
            switch (mod_kind) {
                .access => {
                    if (flags.has_accessibility) {
                        try self.emitDiagnostic(self.currentSpan(), "Accessibility modifier already seen", .{});
                    }
                    flags.has_accessibility = true;
                    if (std.mem.eql(u8, text, "public")) flags.has_public = true
                    else if (std.mem.eql(u8, text, "private")) flags.has_private = true
                    else flags.has_protected = true;
                },
                .abstract => {
                    if (flags.has_abstract) try self.emitDiagnostic(self.currentSpan(), "Duplicate modifier: 'abstract'", .{});
                    flags.has_abstract = true;
                },
                .override => {
                    if (flags.has_override) try self.emitDiagnostic(self.currentSpan(), "Duplicate modifier: 'override'", .{});
                    flags.has_override = true;
                },
                .readonly => {
                    if (flags.has_readonly) try self.emitDiagnostic(self.currentSpan(), "Duplicate modifier: 'readonly'", .{});
                    flags.has_readonly = true;
                },
                .declare => {
                    if (flags.has_declare) try self.emitDiagnostic(self.currentSpan(), "Duplicate modifier: 'declare'", .{});
                    flags.has_declare = true;
                },
                .@"export" => {
                    if (flags.has_export) try self.emitDiagnostic(self.currentSpan(), "Duplicate modifier: 'export'", .{});
                    flags.has_export = true;
                },
                .not_modifier => unreachable,
            }

            // Check modifier ordering: access(1) → abstract(2) → override(3) → readonly(4)
            // Note: 'static' is parsed separately between phases, so we don't track it here.
            const phase: u8 = switch (mod_kind) {
                .declare => 0,
                .access => 1,
                .abstract => 2,
                .override => 3,
                .readonly => 4,
                .@"export" => 0,
                .not_modifier => unreachable,
            };
            if (phase > 0 and phase < last_phase) {
                try self.emitDiagnostic(self.currentSpan(), "Modifier order is incorrect", .{});
            }
            if (phase > 0) last_phase = phase;

            _ = self.advance();
        }
        return flags;
    }

    /// Pack TsModifierFlags + is_static/is_async/is_generator into a u32 ModifierBit word.
    fn packMemberModifiers(ts: TsModifierFlags, is_static_m: bool, is_async_m: bool, is_generator_m: bool) u32 {
        var m: u32 = 0;
        if (ts.has_public) m |= ast.ModifierBit.acc_public
        else if (ts.has_private) m |= ast.ModifierBit.acc_private
        else if (ts.has_protected) m |= ast.ModifierBit.acc_protected;
        if (ts.has_readonly) m |= ast.ModifierBit.readonly;
        if (ts.has_override) m |= ast.ModifierBit.@"override";
        if (ts.has_declare) m |= ast.ModifierBit.declare;
        if (ts.has_abstract) m |= ast.ModifierBit.abstract;
        if (is_static_m) m |= ast.ModifierBit.@"static";
        if (is_async_m) m |= ast.ModifierBit.@"async";
        if (is_generator_m) m |= ast.ModifierBit.generator;
        if (ts.has_accessor) m |= ast.ModifierBit.accessor;
        return m;
    }

    /// Parse a single class member.
    pub fn parseClassMember(self: *Parser) Error!NodeIndex {
        // Skip decorators: @expr or @expr(args)
        // Parse decorator as: identifier (.identifier)* (args)?
        // Don't use parseAssignmentExpression — it's too greedy and consumes
        // computed member `[` which starts the next class member.
        var had_member_decorator = false;
        while (self.peek() == .at_sign) {
            had_member_decorator = true;
            _ = self.advance(); // eat @
            if (self.peek() == .l_paren) {
                // @(expr) — parenthesized decorator expression
                _ = self.advance(); // eat (
                _ = try self.parseAssignmentExpression();
                _ = try self.expect(.r_paren);
            } else {
                _ = try self.parseIdentifier(); // decorator name
                // TS non-null assertion: @x! or dotted: @foo.bar.baz
                while (true) {
                    if (self.peek() == .dot) {
                        _ = self.advance();
                        _ = try self.parseIdentifier();
                    } else if (self.is_ts and self.peek() == .bang) {
                        _ = self.advance(); // eat `!`
                    } else break;
                }
                // TS type args + call: @g<number>()
                if (self.is_ts and self.peek() == .less_than) {
                    const saved_tok = self.tok_i;
                    const saved_diag = self.diagnostics.items.len;
                    const saved_nodes = self.nodes.len;
                    const saved_extra = self.extra_data.items.len;
                    _ = typescript.parseTypeArguments(self) catch {
                        self.tok_i = saved_tok;
                        self.diagnostics.shrinkRetainingCapacity(saved_diag);
                        self.nodes.len = @intCast(saved_nodes);
                        self.extra_data.shrinkRetainingCapacity(saved_extra);
                    };
                }
                // call: @dec() or @dec(args)
                if (self.peek() == .l_paren) {
                    _ = self.advance(); // eat (
                    while (self.peek() != .r_paren and !self.isAtEnd()) {
                        _ = try self.parseAssignmentExpression();
                        if (self.peek() == .comma) _ = self.advance() else break;
                    }
                    _ = try self.expect(.r_paren);
                }
            }
        }

        // Handle `static { ... }` (static block)
        if (self.peek() == .kw_static and self.peekAt(1) == .l_brace) {
            // TS1206: Decorators are not valid on static blocks
            if (self.is_ts and had_member_decorator) {
                try self.emitDiagnostic(self.currentSpan(), "Decorators are not valid here", .{});
            }
            const static_tok = self.advance(); // eat 'static'
            _ = self.advance(); // eat '{'
            // Static blocks isolate break/continue/return context, async/generator
            // context. Per spec: [~Yield, +Await, ~Return] — but ContainsYield and
            // ContainsAwait are early errors, so we reset in_generator/in_async to
            // detect accidental use of yield/await from enclosing context.
            const prev_in_loop = self.in_loop;
            const prev_in_switch = self.in_switch;
            const prev_in_function = self.in_function;
            const prev_in_async_sb = self.in_async;
            const prev_in_generator_sb = self.in_generator;
            const prev_cf_sb = self.in_class_field;
            const prev_in_static_block = self.in_static_block;
            const prev_nta_sb = self.new_target_allowed;
            self.in_loop = false;
            self.in_switch = false;
            self.in_function = false;
            self.in_async = false;
            self.in_generator = false;
            self.in_class_field = true;
            self.in_static_block = true;
            self.new_target_allowed = true;
            self.syncYieldLex();
            const static_scope_ev = try self.emitScopeOpen(.static_block, .none);
            const range = try self.parseStatementList(.r_brace);
            try self.emitScopeClose(.none);

            // Detect duplicate lexical declarations and lex-vs-var conflicts in static block.
            if (self.emit_scope_events and !self.is_ts) {
                var sb_depth: i32 = 0;
                const sb_evs = self.ev_ptr[0..self.ev_len][static_scope_ev + 1 ..];
                const SbEntry = struct { name: []const u8 };
                var sb_lex: [64]SbEntry = undefined;
                var sb_lex_n: usize = 0;
                var sb_var: [64]SbEntry = undefined;
                var sb_var_n: usize = 0;
                for (sb_evs) |ev| {
                    switch (ev.kind) {
                        .scope_open => if (ev.aux != @intFromEnum(ScopeKindU8.elided)) { sb_depth += 1; },
                        .scope_close => sb_depth -= 1,
                        .declare => if (sb_depth == 0) {
                            const bk: BindingKindU8 = @enumFromInt(ev.aux);
                            const main_tok_idx = self.node_main_token_ptr[@intCast(ev.node)];
                            const tok_start = self.tok_starts_ptr[main_tok_idx];
                            const tok_len = self.tok_lens_ptr[main_tok_idx];
                            if (tok_start + tok_len > self.source.len) continue;
                            const name = self.source[tok_start..tok_start + tok_len];
                            if (bk == .@"var" or bk == .parameter) {
                                if (sb_var_n < sb_var.len) {
                                    sb_var[sb_var_n] = .{ .name = name };
                                    sb_var_n += 1;
                                }
                            } else if (bk != .function_decl and bk != .function_decl_annex_b) {
                                var dup = false;
                                for (sb_lex[0..sb_lex_n]) |existing| {
                                    if (std.mem.eql(u8, existing.name, name)) { dup = true; break; }
                                }
                                if (dup) {
                                    try self.emitDiagnostic(self.currentSpan(),
                                        "Identifier '{s}' has already been declared", .{name});
                                } else if (sb_lex_n < sb_lex.len) {
                                    sb_lex[sb_lex_n] = .{ .name = name };
                                    sb_lex_n += 1;
                                }
                            }
                        },
                        else => {},
                    }
                }
                // Check lex-vs-var conflict in static block.
                for (sb_lex[0..sb_lex_n]) |lex_entry| {
                    for (sb_var[0..sb_var_n]) |var_entry| {
                        if (std.mem.eql(u8, lex_entry.name, var_entry.name)) {
                            try self.emitDiagnostic(self.currentSpan(),
                                "Identifier '{s}' has already been declared", .{lex_entry.name});
                            break;
                        }
                    }
                }
            }
            self.in_loop = prev_in_loop;
            self.in_switch = prev_in_switch;
            self.in_function = prev_in_function;
            self.in_async = prev_in_async_sb;
            self.in_generator = prev_in_generator_sb;
            self.in_class_field = prev_cf_sb;
            self.in_static_block = prev_in_static_block;
            self.new_target_allowed = prev_nta_sb;
            self.syncYieldLex();
            _ = try self.expect(.r_brace);
            const static_node = try self.addNode(.{
                .tag = .static_block,
                .main_token = static_tok,
                .data = .{
                    .lhs = NodeIndex.fromInt(range.start),
                    .rhs = NodeIndex.fromInt(range.end),
                },
            });
            self.patchScopeOpenNode(static_scope_ev, static_node);
            return static_node;
        }

        // Parse and validate TypeScript access modifiers: private, protected, public,
        // abstract, override, readonly, declare.  These are identifiers in the
        // lexer so we match by text.  We loop because they can stack
        // (e.g. `public readonly abstract`).
        var ts_mod_flags: TsModifierFlags = .{};
        if (self.is_ts) {
            ts_mod_flags = try self.parseTsModifiers();
        }

        var is_static = false;
        var is_getter = false;
        var is_setter = false;

        // Parse modifiers: static, get, set
        // A newline between modifier and the next token means ASI applies:
        // the modifier is a field name, not a modifier.
        if (self.peek() == .kw_static) {
            const next = self.peekAt(1);
            // `static` is a modifier unless the next token shows it's being used
            // as a field/method name: `static(`, `static=`, `static;`, `static}`.
            // Newlines between `static` and the next token do NOT trigger ASI in
            // class bodies — `static\nconstructor(){}` is a valid static method.
            if (next != .l_paren and next != .equal and next != .semicolon and
                next != .colon and next != .r_brace)
            {
                is_static = true;
                _ = self.advance(); // eat 'static'
            }
        }

        // TS modifiers that may appear after static
        if (self.is_ts) {
            const extra_mods = try self.parseTsModifiers();
            // Access modifiers after 'static' is wrong order
            if (is_static and extra_mods.has_accessibility) {
                try self.emitDiagnostic(self.currentSpan(), "Accessibility modifier must precede 'static' modifier", .{});
            }
            ts_mod_flags = ts_mod_flags.merge(extra_mods);
        }

        // Validate modifiers on class elements
        if (self.is_ts and ts_mod_flags.has_export) {
            try self.emitDiagnostic(self.currentSpan(), "'export' modifier cannot appear on class elements", .{});
        }
        // TS1243: 'private' modifier cannot be used with 'abstract' modifier.
        if (self.is_ts and ts_mod_flags.has_private and ts_mod_flags.has_abstract) {
            try self.emitDiagnostic(self.currentSpan(), "'private' modifier cannot be used with 'abstract' modifier", .{});
        }
        // TS1244: Abstract methods can only appear within an abstract class.
        if (self.is_ts and ts_mod_flags.has_abstract and !self.in_abstract_class) {
            try self.emitDiagnostic(self.currentSpan(), "Abstract methods can only appear within an abstract class", .{});
        }
        // TS1206: Decorators are not valid on abstract or declare class members (ES decorators only).
        if (self.is_ts and had_member_decorator and !self.experimental_decorators and
            (ts_mod_flags.has_abstract or ts_mod_flags.has_declare))
        {
            try self.emitDiagnostic(self.currentSpan(), "Decorators are not valid here", .{});
        }

        // getter/setter detection
        // In TS, `get<T>()` is a generic method, not a getter — exclude `<`
        // Getters/setters can't be generators, so `get *` means `get` is a field name
        const gs_cur = self.peek();
        const gs_p1 = self.peekAt(1);
        if (gs_cur == .kw_get and gs_p1 != .l_paren and
            gs_p1 != .equal and gs_p1 != .semicolon and
            gs_p1 != .r_brace and gs_p1 != .asterisk and
            !(self.is_ts and gs_p1 == .less_than) and
            !(self.is_ts and gs_p1 == .colon))
        {
            is_getter = true;
            _ = self.advance(); // eat 'get'
        } else if (gs_cur == .kw_set and gs_p1 != .l_paren and
            gs_p1 != .equal and gs_p1 != .semicolon and
            gs_p1 != .r_brace and gs_p1 != .asterisk and
            !(self.is_ts and gs_p1 == .less_than) and
            !(self.is_ts and gs_p1 == .colon))
        {
            is_setter = true;
            _ = self.advance(); // eat 'set'
        }

        // `accessor` field modifier (ES2024 auto-accessors). Only treat
        // `accessor` as modifier when followed by a member-name token on
        // the SAME line (no ASI). On newline, `accessor` is the field name.
        const acc_p1 = self.peekAt(1);
        if (self.peek() == .identifier and std.mem.eql(u8, self.tokenText(self.tokIdx()), "accessor") and
            acc_p1 != .l_paren and acc_p1 != .equal and
            acc_p1 != .semicolon and acc_p1 != .r_brace and
            !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1)))
        {
            ts_mod_flags.has_accessor = true;
            _ = self.advance(); // eat 'accessor'
        }

        // Async method: async name() or async *name() (generator)
        var is_async_method = false;
        const async_p1 = self.peekAt(1);
        if (self.peek() == .kw_async and async_p1 != .l_paren and
            async_p1 != .equal and async_p1 != .semicolon and async_p1 != .r_brace and
            !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1)))
        {
            is_async_method = true;
            _ = self.advance(); // eat 'async'
        }

        // Generator method: *name() or *#name()
        var is_generator_method = false;
        if (self.peek() == .asterisk) {
            is_generator_method = true;
            _ = self.advance(); // eat '*'
            // TS1221: Generators are not allowed in an ambient context.
            if (self.is_ts and self.in_ts_ambient) {
                try self.emitDiagnostic(self.currentSpan(), "Generators are not allowed in an ambient context", .{});
            }
        }

        // TS index signature in class body: `[key: Type]: ValueType;`
        const idx_p1 = self.peekAt(1);
        if (self.is_ts and self.peek() == .l_bracket and
            (idx_p1 == .identifier or idx_p1 == .kw_readonly) and
            self.peekAt(2) == .colon)
        {
            // Modifiers like public/private/protected/export are not allowed on index signatures
            if (ts_mod_flags.has_accessibility or ts_mod_flags.has_export) {
                try self.emitDiagnostic(self.currentSpan(), "Modifier cannot appear on an index signature", .{});
            }
            return typescript.parseIndexSignature(self);
        }

        // Computed key: `[expr]` — always allow `in` in computed keys
        if (self.peek() == .l_bracket) {
            const computed_main_tok: u32 = self.tokIdx(); // '[' token — used as main_token for the method node
            _ = self.advance(); // eat '['
            const prev_allow_in = self.allow_in;
            self.allow_in = true;
            const key_expr = try self.parseAssignmentExpression();
            self.allow_in = prev_allow_in;
            _ = try self.expect(.r_bracket);

            // TS: optional marker and generic type params on computed members
            const computed_is_optional: u32 = if (self.is_ts and self.eat(.question) != null) 1 else 0;
            var computed_class_type_params = ast.SubRange{ .start = 0, .end = 0 };
            if (self.is_ts and self.peek() == .less_than) {
                computed_class_type_params = try typescript.parseTypeParameterList(self);
            }

            if (self.peek() == .l_paren) {
                // Computed method — computed keys are never "constructor"
                const prev_in_function = self.in_function;
                const prev_in_constructor = self.in_constructor;
                const prev_in_method = self.in_method;
                const prev_in_generator = self.in_generator;
                const prev_in_async = self.in_async;
                const prev_in_cf = self.in_class_field;
                self.in_function = true;
                self.in_constructor = false;
                self.in_method = true;
                const _saved_nta_x = self.new_target_allowed;
                self.new_target_allowed = true;
                defer self.new_target_allowed = _saved_nta_x;
                self.in_generator = is_generator_method;
                self.in_class_field = false;
                if (is_async_method) self.in_async = true;
                self.syncYieldLex();
                defer self.syncYieldLex();
                defer self.in_function = prev_in_function;
                defer self.in_constructor = prev_in_constructor;
                defer self.in_class_field = prev_in_cf;
                defer self.in_method = prev_in_method;
                defer self.in_generator = prev_in_generator;
                defer self.in_async = prev_in_async;
                const params = try self.parseFormalParameters();

                // TS return type annotation
                self.in_return_type = true;
                const computed_method_return_type = try self.parseOptionalTypeAnnotation();
                self.in_return_type = false;

                // TS abstract/declare computed methods may have no body
                if (self.is_ts and self.peek() != .l_brace) {
                    _ = self.eat(.semicolon);
                    const computed_no_body_extra = try self.addExtra(ast.MethodData, .{
                        .params_start = params.start,
                        .params_end = params.end,
                        .body = .none,
                        .return_type = computed_method_return_type,
                        .modifiers = packMemberModifiers(ts_mod_flags, is_static, is_async_method, is_generator_method),
                        .type_params = computed_class_type_params.start,
                        .type_params_end = computed_class_type_params.end,
                    });
                    const computed_no_body_tag: Node.Tag = if (is_getter)
                        .computed_getter_def
                    else if (is_setter)
                        .computed_setter_def
                    else
                        .computed_method_def;
                    return self.addNode(.{
                        .tag = computed_no_body_tag,
                        .main_token = computed_main_tok,
                        .data = .{ .lhs = key_expr, .rhs = NodeIndex.fromInt(computed_no_body_extra) },
                    });
                }

                self.is_fn_body_block = true;
                const body = try self.parseBlockStatement();

                const method_extra = try self.addExtra(ast.MethodData, .{
                    .params_start = params.start,
                    .params_end = params.end,
                    .body = body,
                    .return_type = computed_method_return_type,
                    .modifiers = packMemberModifiers(ts_mod_flags, is_static, is_async_method, is_generator_method),
                    .type_params = computed_class_type_params.start,
                    .type_params_end = computed_class_type_params.end,
                });

                const node_tag: Node.Tag = if (is_getter)
                    .computed_getter_def
                else if (is_setter)
                    .computed_setter_def
                else
                    .computed_method_def;

                return self.addNode(.{
                    .tag = node_tag,
                    .main_token = computed_main_tok,
                    .data = .{
                        .lhs = key_expr,
                        .rhs = NodeIndex.fromInt(method_extra),
                    },
                });
            }

            // TS1206: Decorators are not valid on computed class fields with experimental decorators.
            // (Computed methods and 'declare' computed fields are allowed decorators even in experimental mode.)
            if (self.is_ts and had_member_decorator and self.experimental_decorators and !ts_mod_flags.has_declare) {
                try self.emitDiagnostic(self.currentSpan(), "Decorators are not valid here", .{});
            }

            // TS optional marker and type annotation on computed field
            if (self.is_ts) {
                _ = self.eat(.question);
            }
            const computed_type_ann = try self.parseOptionalTypeAnnotation();

            // Computed property
            const comp_value: NodeIndex = if (self.eat(.equal) != null) blk: {
                const prev_in_class_field = self.in_class_field;
                const prev_nta_cf = self.new_target_allowed;
                const prev_in_async_cf2 = self.in_async;
                self.in_class_field = true;
                self.new_target_allowed = true;
                self.in_async = false;
                defer self.in_class_field = prev_in_class_field;
                defer self.new_target_allowed = prev_nta_cf;
                defer self.in_async = prev_in_async_cf2;
                break :blk try self.parseAssignmentExpression();
            } else .none;

            if (self.eat(.semicolon) == null and self.peek() != .r_brace and !self.isOnNewLine()) {
                try self.emitDiagnostic(self.currentSpan(), "Expected ';' after class field definition", .{});
                return error.ParseError;
            }

            const comp_prop_extra = try self.addExtra(ast.PropertyData, .{
                .value = comp_value,
                .type_annotation = computed_type_ann,
                .optional = computed_is_optional,
            });
            return self.addNode(.{
                .tag = .computed_property_def,
                .main_token = computed_main_tok,
                .data = .{
                    .lhs = key_expr,
                    .rhs = NodeIndex.fromInt(comp_prop_extra),
                },
            });
        }

        // Regular (non-computed) key
        const main_tok: u32 = self.tokIdx();
        const key = try self.parseClassPropertyKey();

        // TS1206: Decorators are not valid on private class members (#name) with experimental decorators.
        // With modern ES decorators, private member decoration is allowed.
        if (self.is_ts and had_member_decorator and self.experimental_decorators) {
            const key_main = self.node_main_token_ptr[key.toInt()];
            if (self.tokenTagAt(key_main) == .hash) {
                try self.emitDiagnostic(self.currentSpan(), "Decorators are not valid here", .{});
            }
        }

        // Skip optional `?` marker (TS optional member)
        const member_is_optional: u32 = if (self.is_ts and self.eat(.question) != null) 1 else 0;

        // TS generic method: skip type parameters before `(`
        var named_class_type_params = ast.SubRange{ .start = 0, .end = 0 };
        if (self.is_ts and self.peek() == .less_than) {
            // TS1092: Type parameters cannot appear on a constructor declaration.
            const key_tag_tp = self.node_tags_ptr[key.toInt()];
            const key_tok_tp = self.node_main_token_ptr[key.toInt()];
            const is_ctor_tp = !is_static and !is_getter and !is_setter and
                ((key_tag_tp == .identifier and std.mem.eql(u8, self.tokenText(key_tok_tp), "constructor")) or
                 (key_tag_tp == .string_literal and std.mem.eql(u8, self.getStringContent(self.tokenStart(key_tok_tp)), "constructor")));
            named_class_type_params = try typescript.parseTypeParameterList(self);
            if (is_ctor_tp) {
                try self.emitDiagnostic(self.currentSpan(), "Type parameters cannot appear on a constructor declaration", .{});
            }
            // TS1094: An accessor cannot have type parameters.
            if (is_getter or is_setter) {
                try self.emitDiagnostic(self.currentSpan(), "An accessor cannot have type parameters", .{});
            }
        }

        // Generator methods must have `(` — `*foo` without params is invalid.
        if (is_generator_method and self.peek() != .l_paren) {
            try self.emitDiagnostic(self.currentSpan(), "'(' expected", .{});
        }

        // Accessor (getter/setter) methods cannot be named "constructor" (non-static).
        // Spec: ClassElement : MethodDefinition is a SyntaxError if PropName is "constructor"
        // and SpecialMethod is true (getter, setter, generator, or async).
        if ((is_getter or is_setter) and !is_static and key != .none and !self.is_ts) {
            const kt = self.node_tags_ptr[key.toInt()];
            const kk = self.node_main_token_ptr[key.toInt()];
            const is_ctor_name = (kt == .identifier and std.mem.eql(u8, self.tokenText(kk), "constructor")) or
                (kt == .string_literal and std.mem.eql(u8, self.getStringContent(self.tokenStart(kk)), "constructor"));
            if (is_ctor_name) {
                try self.emitError("Accessor method cannot be named 'constructor'");
                return error.ParseError;
            }
        }

        // TS: `constructor` in a class must always be followed by `(` — it cannot be a field.
        if (self.is_ts and !is_static and !is_getter and !is_setter and self.peek() != .l_paren) {
            const key_tag_ck = self.node_tags_ptr[key.toInt()];
            const key_tok_ck = self.node_main_token_ptr[key.toInt()];
            const is_ctor_key = key_tag_ck == .identifier and std.mem.eql(u8, self.tokenText(key_tok_ck), "constructor");
            if (is_ctor_key) {
                try self.emitDiagnostic(self.currentSpan(), "'(' expected", .{});
            }
        }

        // Method
        if (self.peek() == .l_paren) {
            // 'accessor' is only valid on fields, not methods.
            if (ts_mod_flags.has_accessor) {
                try self.emitDiagnostic(self.currentSpan(), "Unexpected token", .{});
                return error.ParseError;
            }
            // Early constructor detection so super() is valid in default params
            const early_is_ctor = blk: {
                if (is_static or is_getter or is_setter) break :blk false;
                const key_tag_e = self.node_tags_ptr[key.toInt()];
                const key_tok_e = self.node_main_token_ptr[key.toInt()];
                if (key_tag_e == .identifier) break :blk std.mem.eql(u8, self.tokenText(key_tok_e), "constructor");
                if (key_tag_e == .string_literal) break :blk std.mem.eql(u8, self.getStringContent(self.tokenStart(key_tok_e)), "constructor");
                break :blk false;
            };
            // TS1206: Decorators are not valid on constructor
            if (self.is_ts and had_member_decorator and early_is_ctor) {
                try self.emitDiagnostic(self.currentSpan(), "Decorators are not valid here", .{});
            }
            const prev_in_constructor_early = self.in_constructor;
            if (early_is_ctor) self.in_constructor = true;
            // Set async/generator context before parsing params so await/yield are
            // correctly recognized as reserved in async/generator method params.
            const prev_async_params = self.in_async;
            const prev_gen_params = self.in_generator;
            if (is_async_method) self.in_async = true;
            if (is_generator_method) { self.in_generator = true; self.syncYieldLex(); }
            // Method params are a function scope — class-field restrictions (arguments, static-block)
            // don't apply inside method params. Temporarily clear in_class_field before params.
            const prev_cf_params = self.in_class_field;
            self.in_class_field = false;
            // Open method's function scope before params so declares land in it.
            const method_scope_ev = try self.emitScopeOpen(.function, .none);
            const params = try self.parseFormalParameters();
            self.in_class_field = prev_cf_params;
            self.in_async = prev_async_params;
            if (is_generator_method) { self.in_generator = prev_gen_params; self.syncYieldLex(); }
            self.in_constructor = prev_in_constructor_early;

            // Validate getter/setter parameter counts
            const param_count = params.end - params.start;
            // In TS mode, exclude `this` parameters from count (they're type annotations, not real params).
            const real_param_count = blk: {
                if (!self.is_ts) break :blk param_count;
                var count: usize = 0;
                var i = params.start;
                while (i < params.end) : (i += 1) {
                    const pidx = self.extra_data.items[i];
                    const ptag = self.node_tags_ptr[pidx];
                    if (ptag == .identifier) {
                        const ptok = self.node_main_token_ptr[pidx];
                        if (std.mem.eql(u8, self.tokenText(ptok), "this")) continue;
                    }
                    count += 1;
                }
                break :blk count;
            };
            if (is_getter and real_param_count > 0) {
                try self.emitDiagnostic(self.currentSpan(), "Getter must have zero parameters", .{});
                if (!self.is_ts) return error.ParseError;
            }
            if (is_setter and real_param_count != 1) {
                try self.emitDiagnostic(self.currentSpan(), "Setter must have exactly one parameter", .{});
                if (!self.is_ts) return error.ParseError;
            }
            // Setter param must not be a rest parameter
            if (is_setter and param_count == 1) {
                const param_tag = self.node_tags_ptr[@intCast(self.extra_data.items[params.start])];
                if (param_tag == .rest_element) {
                    try self.emitDiagnostic(self.currentSpan(), "Setter parameter must not be a rest parameter", .{});
                    return error.ParseError;
                }
            }
            // TS1051: A 'set' accessor cannot have an optional parameter.
            // TS1052: A 'set' accessor parameter cannot have an initializer.
            if (self.is_ts and is_setter and real_param_count == 1) {
                const pidx = blk: {
                    // Find the real (non-this) parameter
                    var i = params.start;
                    while (i < params.end) : (i += 1) {
                        const idx = self.extra_data.items[i];
                        const ptag = self.node_tags_ptr[idx];
                        if (ptag == .identifier) {
                            const ptok = self.node_main_token_ptr[idx];
                            if (std.mem.eql(u8, self.tokenText(ptok), "this")) continue;
                        }
                        break :blk idx;
                    }
                    break :blk @as(u32, 0);
                };
                if (pidx > 0) {
                    const ptag = self.node_tags_ptr[pidx];
                    if (ptag == .assignment_pattern) {
                        try self.emitDiagnostic(self.currentSpan(), "A 'set' accessor parameter cannot have an initializer", .{});
                    } else if (ptag == .identifier and self.node_data_ptr[pidx].lhs == .root) {
                        try self.emitDiagnostic(self.currentSpan(), "A 'set' accessor cannot have an optional parameter", .{});
                    }
                }
            }

            // Check for static constructor (invalid in TypeScript only)
            if (self.is_ts and is_static and !is_getter and !is_setter) {
                const key_tag = self.node_tags_ptr[key.toInt()];
                const key_tok = self.node_main_token_ptr[key.toInt()];
                const is_ctor_name = if (key_tag == .identifier)
                    std.mem.eql(u8, self.tokenText(key_tok), "constructor")
                else if (key_tag == .string_literal)
                    std.mem.eql(u8, self.getStringContent(self.tokenStart(key_tok)), "constructor")
                else
                    false;
                if (is_ctor_name) {
                    try self.emitDiagnostic(self.currentSpan(), "'static' modifier cannot appear on a constructor declaration", .{});
                }
            }
            // TS1341: Class constructor may not be an accessor.
            if (self.is_ts and (is_getter or is_setter)) {
                const key_tag = self.node_tags_ptr[key.toInt()];
                const key_tok = self.node_main_token_ptr[key.toInt()];
                const is_ctor_name = if (key_tag == .identifier)
                    std.mem.eql(u8, self.tokenText(key_tok), "constructor")
                else if (key_tag == .string_literal)
                    std.mem.eql(u8, self.getStringContent(self.tokenStart(key_tok)), "constructor")
                else
                    false;
                if (is_ctor_name) {
                    try self.emitDiagnostic(self.currentSpan(), "Class constructor may not be an accessor", .{});
                }
            }

            // Detect constructor: non-static method named "constructor" or "constructor"
            const is_ctor = blk: {
                if (is_static or is_getter or is_setter) break :blk false;
                const key_tag = self.node_tags_ptr[key.toInt()];
                const key_tok = self.node_main_token_ptr[key.toInt()];
                if (key_tag == .identifier) {
                    break :blk std.mem.eql(u8, self.tokenText(key_tok), "constructor");
                }
                // String literal key: "constructor" or 'constructor'
                if (key_tag == .string_literal) {
                    const content = self.getStringContent(self.tokenStart(key_tok));
                    break :blk std.mem.eql(u8, content, "constructor");
                }
                break :blk false;
            };

            // Validate constructor restrictions
            if (is_ctor) {
                if (is_async_method) {
                    try self.emitDiagnostic(self.currentSpan(), "'async' modifier cannot appear on a constructor declaration", .{});
                }
                if (is_generator_method) {
                    try self.emitDiagnostic(self.currentSpan(), "A constructor cannot be a generator", .{});
                }
                if (self.is_ts and ts_mod_flags.has_abstract) {
                    try self.emitDiagnostic(self.currentSpan(), "'abstract' modifier cannot appear on a constructor declaration", .{});
                }
                // TS1031: 'declare' modifier cannot appear on class elements of this kind.
                if (self.is_ts and ts_mod_flags.has_declare) {
                    try self.emitDiagnostic(self.currentSpan(), "'declare' modifier cannot appear on class elements of this kind", .{});
                }
            } else if (self.is_ts and ts_mod_flags.has_declare and self.peek() == .l_paren) {
                // TS1031: 'declare' modifier cannot appear on method declarations.
                try self.emitDiagnostic(self.currentSpan(), "'declare' modifier cannot appear on class elements of this kind", .{});
            }

            const prev_in_function = self.in_function;
            const prev_in_constructor = self.in_constructor;
            const prev_in_method = self.in_method;
            const prev_in_generator_m = self.in_generator;
            const prev_in_async_m = self.in_async;
            const prev_in_cf_m = self.in_class_field;
            const prev_in_loop_m = self.in_loop;
            const prev_in_switch_m = self.in_switch;
            const prev_ts_fn_depth_m = self.ts_label_fn_depth;
            const prev_ts_label_count_m = self.ts_label_count;
            self.in_function = true;
            self.in_constructor = is_ctor;
            self.in_method = true;
            self.in_loop = false;
            self.in_switch = false;
            self.ts_label_count = 0;
            if (self.ts_label_fn_depth < std.math.maxInt(u16)) self.ts_label_fn_depth += 1;
            const _saved_nta_x = self.new_target_allowed;
            self.new_target_allowed = true;
            defer self.new_target_allowed = _saved_nta_x;
            self.in_generator = is_generator_method;
            self.in_class_field = false;
            self.in_async = is_async_method;
            self.syncYieldLex();
            defer self.syncYieldLex();
            defer self.in_function = prev_in_function;
            defer self.in_constructor = prev_in_constructor;
            defer self.in_method = prev_in_method;
            defer self.in_generator = prev_in_generator_m;
            defer self.in_async = prev_in_async_m;
            defer self.in_class_field = prev_in_cf_m;
            defer self.in_loop = prev_in_loop_m;
            defer self.in_switch = prev_in_switch_m;
            defer self.ts_label_fn_depth = prev_ts_fn_depth_m;
            defer self.ts_label_count = prev_ts_label_count_m;

            // TS return type annotation: `): Type {`
            self.in_return_type = true;
            const method_return_type = try self.parseOptionalTypeAnnotation();
            self.in_return_type = false;
            // TS1093: Type annotation cannot appear on a constructor declaration.
            if (self.is_ts and is_ctor and method_return_type != .none) {
                try self.emitDiagnostic(self.currentSpan(), "Type annotation cannot appear on a constructor declaration", .{});
            }
            // TS1095: A 'set' accessor cannot have a return type annotation.
            if (self.is_ts and is_setter and method_return_type != .none) {
                try self.emitDiagnostic(self.currentSpan(), "A 'set' accessor cannot have a return type annotation", .{});
            }

            // TS abstract/declare methods may have no body (semicolon instead).
            // Emit as method_def / constructor_def / getter_def / setter_def with body = .none.
            if (self.is_ts and self.peek() != .l_brace) {
                // TS1222: An overload signature cannot be declared as a generator.
                if (is_generator_method and !self.in_ts_ambient) {
                    try self.emitDiagnostic(self.currentSpan(), "An overload signature cannot be declared as a generator", .{});
                }
                // TS1249: A decorator can only decorate a method implementation, not an overload.
                if (had_member_decorator and !self.in_ts_ambient) {
                    try self.emitDiagnostic(self.currentSpan(), "A decorator can only decorate a method implementation, not an overload", .{});
                }
                _ = self.eat(.semicolon);
                const no_body_extra = try self.addExtra(ast.MethodData, .{
                    .params_start = params.start,
                    .params_end = params.end,
                    .body = .none,
                    .return_type = method_return_type,
                    .modifiers = packMemberModifiers(ts_mod_flags, is_static, is_async_method, is_generator_method),
                    .type_params = named_class_type_params.start,
                    .type_params_end = named_class_type_params.end,
                });
                const no_body_tag: Node.Tag = if (is_getter)
                    .getter_def
                else if (is_setter)
                    .setter_def
                else if (is_ctor)
                    .constructor_def
                else
                    .method_def;
                try self.emitScopeClose(.none); // close method scope (no body)
                const no_body_node = try self.addNode(.{
                    .tag = no_body_tag,
                    .main_token = main_tok,
                    .data = .{ .lhs = key, .rhs = NodeIndex.fromInt(no_body_extra) },
                });
                self.patchScopeOpenNode(method_scope_ev, no_body_node);
                return no_body_node;
            }

            if (self.peek() == .l_brace) {
                // 'use strict' directive in method body with non-simple params is SyntaxError in JS.
                // In TypeScript (TS1346/TS1347), this is target-dependent and semantic-only.
                if (!self.is_ts) {
                    const peek_pos: u32 = @intCast(self.tok_i + 1);
                    if (self.tokenExists(peek_pos) and self.tokenTagAt(peek_pos) == .string_literal) {
                        const ts_pos = self.tok_starts_ptr[peek_pos];
                        const text = self.getStringContent(ts_pos);
                        if (std.mem.eql(u8, text, "use strict") and hasNonSimpleParam(self, params)) {
                            try self.emitError("Illegal 'use strict' directive in method with non-simple parameter list");
                            return error.ParseError;
                        }
                    }
                }
                // TS1183: An implementation cannot be declared in ambient contexts.
                if (self.is_ts and (self.in_ts_ambient or ts_mod_flags.has_declare)) {
                    try self.emitDiagnostic(self.currentSpan(), "An implementation cannot be declared in ambient contexts", .{});
                }
                // TS1245: An abstract method cannot have an implementation body.
                if (self.is_ts and ts_mod_flags.has_abstract) {
                    try self.emitDiagnostic(self.currentSpan(), "Method cannot have an implementation because it is marked abstract", .{});
                }
            }

            self.is_fn_body_block = true;
            const body = try self.parseBlockStatement();
            try self.emitScopeClose(.none); // close method scope

            // Methods always reject duplicate params.
            try self.checkUniqueParams(params);

            // Static method named 'prototype' is invalid (any flavor).
            if (is_static and key != .none) {
                const key_tag = self.node_tags_ptr[key.toInt()];
                const key_tok = self.node_main_token_ptr[key.toInt()];
                var name_text: []const u8 = "";
                if (key_tag == .identifier and self.tokenTagAt(key_tok) != .hash) {
                    name_text = self.tokenText(key_tok);
                } else if (key_tag == .string_literal) {
                    const tok_start = self.tok_starts_ptr[key_tok];
                    name_text = self.getStringContent(tok_start);
                }
                if (std.mem.eql(u8, name_text, "prototype") and !self.is_ts) {
                    try self.emitError("Static class method cannot be named 'prototype'");
                    return error.ParseError;
                }
            }

            const method_extra = try self.addExtra(ast.MethodData, .{
                .params_start = params.start,
                .params_end = params.end,
                .body = body,
                .return_type = method_return_type,
                .modifiers = packMemberModifiers(ts_mod_flags, is_static, is_async_method, is_generator_method),
                .type_params = named_class_type_params.start,
                .type_params_end = named_class_type_params.end,
            });

            const node_tag: Node.Tag = if (is_getter)
                .getter_def
            else if (is_setter)
                .setter_def
            else
                .method_def;

            const method_node = try self.addNode(.{
                .tag = node_tag,
                .main_token = main_tok,
                .data = .{
                    .lhs = key,
                    .rhs = NodeIndex.fromInt(method_extra),
                },
            });
            self.patchScopeOpenNode(method_scope_ev, method_node);
            return method_node;
        }

        // TS type annotation on field: `name: Type` or `name!: Type`
        // Eat definite assignment assertion `!` first (standalone or before `:`).
        const had_definite_bang_cf = self.is_ts and self.eat(.bang) != null;
        const type_ann = try self.parseOptionalTypeAnnotation();

        // TS1267: Abstract property cannot have an initializer.
        if (self.is_ts and ts_mod_flags.has_abstract and self.peek() == .equal) {
            try self.emitDiagnostic(self.currentSpan(), "Property cannot have an initializer because it is marked abstract", .{});
        }

        // TS1263: `field! = value` or `field!: Type = value` — definite assertion with initializer.
        if (had_definite_bang_cf and self.peek() == .equal) {
            try self.emitDiagnostic(self.currentSpan(), "Declarations with initializers cannot also have definite assignment assertions", .{});
        }

        // Property (field definition).  If there's an initializer, it runs in
        // its own class_field_initializer scope (ESLint model: `this`/closure).
        const field_scope_ev: u32 = if (self.peek() == .equal and self.emit_scope_events)
            try self.emitScopeOpen(.class_field_initializer, .none)
        else
            0;
        const field_has_init = self.peek() == .equal;
        const value: NodeIndex = if (self.eat(.equal) != null) blk: {
            const prev_in_class_field = self.in_class_field;
            const prev_nta_cf2 = self.new_target_allowed;
            const prev_in_async_cf = self.in_async;
            const prev_in_generator_cf = self.in_generator;
            self.in_class_field = true;
            self.new_target_allowed = true;
            // In TS mode, preserve the outer async context so `await expr` inside
            // a class field (e.g. inside an async function) parses without error.
            // TypeScript accepts this syntactically and emits TS1308 semantically.
            // In JS mode, class field initializers are not async contexts.
            self.in_async = self.is_ts and prev_in_async_cf;
            self.in_generator = false;
            self.syncYieldLex();
            defer {
                self.in_class_field = prev_in_class_field;
                self.new_target_allowed = prev_nta_cf2;
                self.in_async = prev_in_async_cf;
                self.in_generator = prev_in_generator_cf;
                self.syncYieldLex();
            }
            break :blk try self.parseAssignmentExpression();
        } else .none;
        if (field_has_init) try self.emitScopeClose(.none);

        // Require ; or ASI after field definition
        if (self.eat(.semicolon) == null and self.peek() != .r_brace and !self.isOnNewLine()) {
            try self.emitDiagnostic(self.currentSpan(), "Expected ';' after class field definition", .{});
            return error.ParseError;
        }

        // Class field name early errors: cannot be named 'constructor'; static cannot be 'prototype'.
        if (key != .none) {
            const key_tag = self.node_tags_ptr[key.toInt()];
            const key_tok = self.node_main_token_ptr[key.toInt()];
            var name_text: []const u8 = "";
            if (key_tag == .identifier) {
                // Private name (#x) starts with hash — never matches constructor/prototype directly.
                if (self.tokenTagAt(key_tok) != .hash) {
                    name_text = self.tokenText(key_tok);
                }
            } else if (key_tag == .string_literal) {
                const tok_start = self.tok_starts_ptr[key_tok];
                name_text = self.getStringContent(tok_start);
            }
            if (name_text.len > 0) {
                if (!self.is_ts and std.mem.eql(u8, name_text, "constructor")) {
                    try self.emitError("Class field cannot be named 'constructor'");
                    return error.ParseError;
                }
                if (!self.is_ts and is_static and std.mem.eql(u8, name_text, "prototype")) {
                    try self.emitError("Static class field cannot be named 'prototype'");
                    return error.ParseError;
                }
            }
        }

        const prop_extra = try self.addExtra(ast.PropertyData, .{
            .value = value,
            .type_annotation = type_ann,
            .optional = member_is_optional,
        });
        const prop_node = try self.addNode(.{
            .tag = .property_def,
            .main_token = main_tok,
            .data = .{
                .lhs = key,
                .rhs = NodeIndex.fromInt(prop_extra),
            },
        });
        // Scope.block for a class_field_initializer scope points at the VALUE
        // expression (matches tree walker: `scope_node = prop_data.value`).
        if (field_has_init and value != .none) self.patchScopeOpenNode(field_scope_ev, value);
        return prop_node;
    }

    /// Parse a class property key (identifier, string, number, keyword used as name).
    pub fn parseClassPropertyKey(self: *Parser) Error!NodeIndex {
        switch (self.peek()) {
            .identifier, .kw_static, .kw_get, .kw_set, .kw_async,
            .kw_from, .kw_as, .kw_of, .kw_let, .kw_target, .kw_meta,
            => return self.parseIdentifier(),
            .hash => {
                // Private field: #name (keywords are valid private names too: #await, #yield, etc.)
                const hash_tok = self.advance();
                const hash_start = self.tok_starts_ptr[hash_tok];
                if (self.peek() == .identifier or self.peek().isKeyword() or self.peek() == .escaped_keyword) {
                    const ident_tok: u32 = self.tokIdx();
                    const ident_start = self.tok_starts_ptr[ident_tok];
                    if (ident_start != hash_start + 1) {
                        try self.emitError("No whitespace allowed between `#` and identifier");
                    }
                    // #constructor is forbidden as private name (TS gives TS18012, not a parse error).
                    const ident_text = self.tokenText(ident_tok);
                    if (!self.is_ts and std.mem.eql(u8, ident_text, "constructor")) {
                        try self.emitError("'#constructor' is not a valid private name");
                    }
                    _ = self.advance();
                }
                return self.addNode(.{
                    .tag = .identifier,
                    .main_token = hash_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            },
            .string_literal => {
                const tok = self.advance();
                return self.addNode(.{
                    .tag = .string_literal,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            },
            .number_literal, .bigint_literal => {
                const tok = self.advance();
                const node_tag: Node.Tag = if (self.tokenTagAt(tok) == .bigint_literal) .bigint_literal else .number_literal;
                return self.addNode(.{
                    .tag = node_tag,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            },
            .escaped_keyword => return self.parseIdentifier(),
            else => {
                if (self.peek().isKeyword()) {
                    return self.parseIdentifier();
                }
                try self.emitDiagnostic(self.currentSpan(), "expected class member name", .{});
                return error.ParseError;
            },
        }
    }

    /// Parse `(param, param = default, ...rest)`.
    pub fn parseFormalParameters(self: *Parser) Error!SubRange {
        _ = try self.expect(.l_paren);

        const prev_fp = self.in_fn_params;
        self.in_fn_params = true;
        defer self.in_fn_params = prev_fp;

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        if (self.peek() != .r_paren) {
            const first = try self.parseFormalParameter();
            try self.scratchPush(first);

            // Check: rest parameter cannot have trailing comma
            const first_tag = self.node_tags_ptr[@intFromEnum(first)];
            if (first_tag == .rest_element and self.peek() == .comma) {
                try self.emitDiagnostic(self.currentSpan(), "Rest parameter must not have a trailing comma", .{});
                return error.ParseError;
            }

            while (self.eat(.comma) != null) {
                if (self.peek() == .r_paren) break; // trailing comma
                const param = try self.parseFormalParameter();
                try self.scratchPush(param);

                // Check: rest parameter cannot have trailing comma
                const ptag = self.node_tags_ptr[@intFromEnum(param)];
                if (ptag == .rest_element and self.peek() == .comma) {
                    try self.emitDiagnostic(self.currentSpan(), "Rest parameter must not have a trailing comma", .{});
                    return error.ParseError;
                }
                // TS1016: A required parameter cannot follow an optional parameter.
                // Treated as semantic/config-dependent (emitted by JSDoc checks, not purely syntactic).
            }
        }

        _ = try self.expect(.r_paren);

        const params = self.scratch.items[scratch_top..];

        // Rest parameter must be last (skip in TS — semantic error)
        if (!self.is_ts and params.len > 1) {
            for (params[0 .. params.len - 1]) |param_raw| {
                const ptag = self.node_tags_ptr[@intCast(param_raw)];
                if (ptag == .rest_element) {
                    try self.emitDiagnostic(self.currentSpan(), "Rest parameter must be last formal parameter", .{});
                    return error.ParseError;
                }
            }
        }

        return self.listToSubRange(params);
    }

    /// Parse a single formal parameter (binding, possibly with type annotation and default or rest).
    pub fn parseFormalParameter(self: *Parser) Error!NodeIndex {
        // TS parameter decorators: @dec before parameter
        var had_param_decorator = false;
        if (self.is_ts) {
            while (self.peek() == .at_sign) {
                had_param_decorator = true;
                // TS1206: parameter decorators are only valid with experimental decorators.
                if (!self.experimental_decorators) {
                    try self.emitDiagnostic(self.currentSpan(), "Decorators are not valid here.", .{});
                }
                _ = self.advance(); // skip '@'
                // Decorator arguments execute in the enclosing scope, so `await`
                // inside them is technically a TS1308 (semantic) error. TS's
                // parser accepts `@dec(await value)` syntactically and lets the
                // type-checker flag it; ez does the same by temporarily relaxing
                // `in_async` and `in_fn_params` while parsing decorator expressions.
                const _saved_in_async = self.in_async;
                const _saved_in_fn_params = self.in_fn_params;
                self.in_async = true;
                self.in_fn_params = false;
                defer self.in_async = _saved_in_async;
                defer self.in_fn_params = _saved_in_fn_params;
                if (self.peek() == .l_paren) {
                    // @(expr) — parse the expression so await/yield errors surface.
                    _ = self.advance(); // eat '('
                    _ = try self.parseAssignmentExpression();
                    _ = try self.expect(.r_paren);
                } else {
                    if (self.peek() == .identifier or self.peek().isKeyword()) _ = self.advance();
                    while (self.peek() == .dot) {
                        _ = self.advance();
                        if (self.peek() == .identifier or self.peek().isKeyword()) _ = self.advance();
                    }
                    if (self.peek() == .l_paren) {
                        // @dec(args) — parse arguments to detect await/yield in wrong context.
                        _ = self.advance(); // eat '('
                        while (self.peek() != .r_paren and !self.isAtEnd()) {
                            _ = try self.parseAssignmentExpression();
                            if (self.peek() == .comma) _ = self.advance() else break;
                        }
                        _ = try self.expect(.r_paren);
                    }
                }
            }
        }

        // TS1433: decorator/modifier not allowed on `this` parameter
        if (had_param_decorator and self.peek() == .kw_this) {
            try self.emitDiagnostic(self.currentSpan(), "Neither decorators nor modifiers may be applied to 'this' parameters", .{});
        }

        // Rest parameter: `...binding`
        if (self.eat(.ellipsis)) |ellipsis_tok| {
            const binding = try self.parseBindingPattern();
            if (!self.suppress_param_declares) try self.emitDeclaresFromPattern(binding, .parameter);
            const rest_type_annotation = try self.parseOptionalTypeAnnotation();
            return self.addNode(.{
                .tag = .rest_element,
                .main_token = ellipsis_tok,
                .data = .{
                    .lhs = binding,
                    .rhs = rest_type_annotation,
                },
            });
        }

        // TS parameter modifiers: public, private, protected, readonly, override
        // If any access/readonly modifier is present, wrap the param in ts_parameter_property.
        var param_prop_main_tok: ?TokenIndex = null;
        if (self.is_ts) {
            const saved_tok = self.tok_i;
            var first_mod_tok: ?TokenIndex = null;
            // Track modifier ordering: access(1) → override(2) → readonly(3)
            var param_mod_last_phase: u8 = 0;
            while (self.peek() == .identifier or self.peek() == .kw_readonly or
                self.peek() == .kw_override)
            {
                const text = self.tokenText(self.tokIdx());
                const is_access = std.mem.eql(u8, text, "public") or
                    std.mem.eql(u8, text, "private") or
                    std.mem.eql(u8, text, "protected");
                const is_override = self.peek() == .kw_override or std.mem.eql(u8, text, "override");
                const is_readonly = self.peek() == .kw_readonly;
                const is_mod = is_access or is_override or is_readonly;
                if (!is_mod) break;
                const next = self.peekAt(1);
                if (next == .colon or next == .comma or next == .r_paren or
                    next == .equal or next == .question)
                    break;
                if (first_mod_tok == null) first_mod_tok = self.tokIdx();
                // TS1029: check modifier ordering; TS1028: check duplicate access modifiers
                const phase: u8 = if (is_access) 1 else if (is_override) 2 else 3;
                if (phase < param_mod_last_phase) {
                    try self.emitDiagnostic(self.currentSpan(), "Modifier order is incorrect", .{});
                } else if (phase == param_mod_last_phase and is_access) {
                    try self.emitDiagnostic(self.currentSpan(), "Accessibility modifier already seen", .{});
                }
                if (phase > param_mod_last_phase) param_mod_last_phase = phase;
                _ = self.advance();
            }
            // Detect parameter property: modifier consumed AND next token is a binding identifier
            // (not just a modifier used as a variable name like `readonly name`).
            if (first_mod_tok != null and self.tok_i > saved_tok) {
                param_prop_main_tok = first_mod_tok;
            }
        }

        // TS `this` parameter: `this: Type` or `this` (contextual typing)
        if (self.is_ts and self.peek() == .kw_this) {
            const next = self.peekAt(1);
            if (next == .colon or next == .comma or next == .r_paren) {
                const this_tok = self.advance(); // eat 'this'
                const this_type_ann = try self.parseOptionalTypeAnnotation();
                return self.addNode(.{
                    .tag = .identifier,
                    .main_token = this_tok,
                    .data = .{ .lhs = .none, .rhs = this_type_ann },
                });
            }
        }

        const main_tok: u32 = self.tokIdx();
        const binding = try self.parseBindingPattern();
        if (!self.suppress_param_declares) try self.emitDeclaresFromPattern(binding, .parameter);

        const is_optional_ts = if (self.is_ts) (self.eat(.question) != null) else false;
        const param_type_annotation = try self.parseOptionalTypeAnnotation();

        // Attach type annotation and optional flag to identifier binding.
        const binding_tag = self.node_tags_ptr[binding.toInt()];
        if (binding_tag == .identifier) {
            if (param_type_annotation != .none) {
                self.node_data_ptr[binding.toInt()].rhs = param_type_annotation;
                // @typescript-eslint extends the parameter Identifier's range
                // through its typeAnnotation. Update end_tok so rules calling
                // sourceCode.getText(param) get `name: Type`, not just `name`.
                self.node_end_toks[binding.toInt()] = if (self.tok_i > 0) @intCast(self.tok_i - 1) else 0;
                // Annotation lives in the identifier's data.rhs → parent is
                // derivable by buildParentsOnly, no fixup needed.
            }
            // Encode optional `?` marker in lhs (lhs=root/0 means optional; lhs=none means not).
            if (is_optional_ts) {
                self.node_data_ptr[binding.toInt()].lhs = .root;
            }
        } else if (param_type_annotation != .none and
            (binding_tag == .object_pattern or binding_tag == .array_pattern))
        {
            // Patterns can't store the annotation inline (their data
            // slots hold a SubRange).  Wire parents[type_ann] = pattern
            // so downstream rules can discover the annotation by
            // scanning ts_type_annotation children whose parent matches.
            const ann_idx = param_type_annotation.toInt();
            try self.parent_fixups.append(self.gpa, ann_idx);
            try self.parent_fixups.append(self.gpa, @intCast(binding.toInt()));
            self.node_end_toks[binding.toInt()] = if (self.tok_i > 0) @intCast(self.tok_i - 1) else 0;
        }

        // TS1015: Parameter cannot have question mark and initializer.
        if (self.is_ts and is_optional_ts and self.peek() == .equal) {
            try self.emitDiagnostic(self.currentSpan(), "Parameter cannot have question mark and initializer", .{});
        }

        // Default value: `param = defaultExpr`
        const inner_param: NodeIndex = if (self.eat(.equal) != null) blk: {
            // Set decl_name_text so named fn/class exprs in the default get fn_expr_name binding.
            const saved_decl_name = self.decl_name_text;
            if (self.emit_scope_events and binding_tag == .identifier) {
                self.decl_name_text = self.tokenText(self.node_main_token_ptr[binding.toInt()]);
            }
            defer self.decl_name_text = saved_decl_name;
            const default_val = try self.parseAssignmentExpression();
            break :blk try self.addNode(.{
                .tag = .assignment_pattern,
                .main_token = main_tok,
                .data = .{
                    .lhs = binding,
                    .rhs = default_val,
                },
            });
        } else binding;

        // Wrap in TSParameterProperty if access/readonly modifiers were present.
        if (param_prop_main_tok) |mod_tok| {
            // TS1187: A parameter property may not be declared using a binding pattern.
            if (binding_tag == .object_pattern or binding_tag == .array_pattern) {
                try self.emitDiagnostic(self.currentSpan(), "A parameter property may not be declared using a binding pattern", .{});
            }
            return self.addNode(.{
                .tag = .ts_parameter_property,
                .main_token = mod_tok,
                .data = .{ .lhs = inner_param, .rhs = .none },
            });
        }

        return inner_param;
    }

    // ────────────────────────────────────────────────────────────
    // Module parsers
    // ────────────────────────────────────────────────────────────

    /// Parse `import ... from '...'` and `import '...'`.
    pub fn parseImportDeclaration(self: *Parser) Error!NodeIndex {
        const import_tok = self.advance(); // eat 'import'
        self.is_module = true;

        // TS import alias: `import X = Y.Z;` or `import X = require('...');`
        // Also: `import type X = Y.Z;`
        if (self.is_ts) {
            // Skip `type` keyword if present
            const start_tok = self.tok_i;
            const alias_p1 = self.peekAt(1);
            if (self.peek() == .kw_type and (alias_p1 == .identifier or alias_p1.isKeyword()) and self.peekAt(2) == .equal) {
                _ = self.advance(); // eat 'type'
            }
            const alias_cur = self.peek();
            if ((alias_cur == .identifier or alias_cur.isKeyword()) and self.peekAt(1) == .equal) {
                // TS1262: In module mode, `await` is reserved and cannot be used as an import alias name.
                // Only applies when the file is a true ES module (has top-level export statements)
                // OR when the alias uses require() (CommonJS import). Namespace aliases (`import await = ns.x`)
                // are allowed when the file has no top-level exports.
                const is_require_alias = self.peek() == .kw_await and
                    self.peekAt(2) == .identifier and
                    std.mem.eql(u8, self.tokenText(@intCast(self.tok_i + 2)), "require") and
                    self.peekAt(3) == .l_paren;
                if (self.is_module and self.peek() == .kw_await and
                    (hasEsModuleExport(self.source) or is_require_alias))
                {
                    try self.emitDiagnostic(self.currentSpan(), "Identifier expected. 'await' is a reserved word at the top-level of a module", .{});
                    return error.ParseError;
                }
                // TS1214: strict reserved words cannot be used as import alias names in strict mode.
                try self.checkStrictBinding(self.tokIdx());
                _ = self.advance(); // eat name
                _ = self.advance(); // eat '='
                // TS1202 (`import X = require("mod")` requires module: commonjs) is a
                // semantic error keyed off the compiler's `module` setting, not a parse
                // error — it depends on tsconfig that the parser doesn't see. Files
                // annotated `// @module: commonjs` (e.g. TS conformance fixtures) parse
                // fine; let downstream type-aware tooling raise TS1202 when applicable.
                // TS1005: `import X = module(...)` — old TS syntax; module cannot be called here.
                // Only `require(...)` is valid as a call in import aliases.
                if (self.peekAt(1) == .l_paren and (self.peek() == .kw_module or
                    (self.peek() == .identifier and !std.mem.eql(u8, self.tokenText(self.tokIdx()), "require"))))
                {
                    try self.emitDiagnostic(self.currentSpan(), "';' expected", .{});
                }
                // TS1141: `import X = require(nonLiteral)` — argument must be a string literal.
                if (self.peek() == .identifier and
                    std.mem.eql(u8, self.tokenText(self.tokIdx()), "require") and
                    self.peekAt(1) == .l_paren and
                    self.peekAt(2) != .string_literal)
                {
                    try self.emitDiagnostic(self.currentSpan(), "A string literal is expected", .{});
                    return error.ParseError;
                }
                // TS1003/TS1359: import alias value must be a qualified identifier or require().
                // Check that the current token is an identifier (or keyword usable as namespace).
                const cur = self.peek();
                if (cur == .kw_null or cur == .kw_true or cur == .kw_false or
                    cur == .kw_this or cur == .kw_super)
                {
                    try self.emitDiagnostic(self.currentSpan(), "Identifier expected. '{s}' is a reserved word that cannot be used here", .{self.tokenText(self.tokIdx())});
                } else if (cur != .identifier and !cur.isKeyword() and cur != .kw_from and cur != .kw_of) {
                    try self.emitDiagnostic(self.currentSpan(), "Identifier expected", .{});
                }
                // `require('...')` or qualified name `A.B.C`
                const module_ref = try self.parseAssignmentExpression();
                _ = self.eat(.semicolon);
                return self.addNode(.{
                    .tag = .import_decl,
                    .main_token = import_tok,
                    .data = .{ .lhs = .none, .rhs = module_ref },
                });
            }
            // Not an import alias — reset position
            self.tok_i = start_tok;
        }

        // Bare import: `import 'module';` or `import 'module' with { ... };`
        if (self.peek() == .string_literal) {
            const source_tok = self.advance();
            // Create source_node BEFORE consuming attributes/semicolon so its
            // end_tok records only the string literal (rules report on node.source).
            const source_node = try self.addNode(.{
                .tag = .string_literal,
                .main_token = source_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            try self.skipImportAttributes();
            try self.expectSemicolon();
            const extra = try self.addExtra(ast.ImportData, .{
                .specifiers_start = 0,
                .specifiers_end = 0,
                .source = source_node,
            });

            return self.addNode(.{
                .tag = .import_decl,
                .main_token = import_tok,
                .data = .{
                    .lhs = NodeIndex.fromInt(extra),
                    .rhs = .none,
                },
            });
        }

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // `import defer * as ns from '...'` or `import source x from '...'`
        // TS18058: `import defer X from '...'` (default) is not allowed — only namespace form.
        const ds_p1 = self.peekAt(1);
        var had_defer = false;
        if (self.peek() == .identifier and
            (std.mem.eql(u8, self.tokenText(self.tokIdx()), "defer") or
            std.mem.eql(u8, self.tokenText(self.tokIdx()), "source")) and
            (ds_p1 == .asterisk or ds_p1 == .identifier))
        {
            had_defer = std.mem.eql(u8, self.tokenText(self.tokIdx()), "defer");
            _ = self.advance(); // skip modifier (defer/source)
            // `import defer X from '...'` is invalid (TS18058): deferred imports must be namespace.
            if (had_defer and self.peek() != .asterisk) {
                try self.emitDiagnostic(self.currentSpan(), "Default imports are not allowed in a deferred import", .{});
                return error.ParseError;
            }
        }

        // TS `import type { ... }` or `import type X from '...'` or `import type * as X from '...'`.
        // The binding-name slot accepts contextual keywords too (`type`, `from`, `as`),
        // so `import type from from '...'` is type-only import of `from`. Disambiguate
        // `import type X from ...` (modifier + default) from `import type from ...`
        // (default named `type`) by peeking at the third token: if it's `from`, the
        // second token is the binding name and the first `type` is the modifier.
        var is_type_import = false;
        const type_imp_p1 = self.peekAt(1);
        if (self.is_ts and self.peek() == .kw_type and
            (type_imp_p1 == .l_brace or type_imp_p1 == .identifier or type_imp_p1 == .asterisk or
                ((type_imp_p1.isTsContextualKeyword() or type_imp_p1 == .kw_as or type_imp_p1 == .kw_from) and
                 self.peekAt(2) == .kw_from)))
        {
            _ = self.advance(); // skip 'type'
            is_type_import = true;
        }

        // Default import: `import x from '...'`. The binding name accepts
        // identifiers and TS contextual keywords — `import type from 'a';` is
        // valid (default import named `type`), distinct from the `import type
        // {...}` modifier form (handled above when followed by `{`/`*`/ident).
        const def_import_starts = (self.peek() == .identifier) or
            (self.is_ts and (self.peek().isTsContextualKeyword() or
                self.peek() == .kw_as or self.peek() == .kw_from) and
                self.peekAt(1) == .kw_from);
        if (def_import_starts) {
            const local_tok: u32 = self.tokIdx();
            // TS1214: strict reserved words cannot be used as default import binding names.
            try self.checkStrictBinding(local_tok);
            _ = self.advance();

            // Create a real identifier node for the local binding.
            // (Used as a reference target, so use .identifier not .property_ident.)
            const local_node = try self.addNode(.{
                .tag = .identifier,
                .main_token = local_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });

            const spec = try self.addNode(.{
                .tag = .import_default_specifier,
                .main_token = local_tok,
                .data = .{
                    .lhs = local_node,
                    .rhs = .none,
                },
            });
            try self.scratchPush(spec);
            try self.emitDeclare(if (is_type_import) .type_import_binding else .import_binding, local_node);

            // May be followed by `, { ... }` or `, * as ns`
            if (self.eat(.comma) != null) {
                if (self.peek() == .l_brace) {
                    try self.parseNamedImportSpecifiers(is_type_import);
                } else if (self.peek() == .asterisk) {
                    const ns_spec = try self.parseNamespaceImportSpecifier();
                    try self.scratchPush(ns_spec);
                } else {
                    try self.emitDiagnostic(self.currentSpan(), "expected '{{' or '*' after default import name and ','", .{});
                    return error.ParseError;
                }
            }
        } else if (self.peek() == .l_brace) {
            try self.parseNamedImportSpecifiers(is_type_import);
        } else if (self.peek() == .asterisk) {
            const ns_spec = try self.parseNamespaceImportSpecifier();
            try self.scratchPush(ns_spec);
        } else {
            try self.emitDiagnostic(self.currentSpan(), "expected import specifiers", .{});
            return error.ParseError;
        }

        // `from 'source'`
        _ = try self.expect(.kw_from);
        const source_tok = try self.expect(.string_literal);
        // Create source_node BEFORE consuming attributes/semicolon so its
        // end_tok records only the string literal.
        const source_node = try self.addNode(.{
            .tag = .string_literal,
            .main_token = source_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        // Optional import attributes: `with { key: "value" }` or `assert { key: "value" }`
        try self.skipImportAttributes();
        try self.expectSemicolon();

        const specs = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(specs);
        const extra = try self.addExtra(ast.ImportData, .{
            .specifiers_start = range.start,
            .specifiers_end = range.end,
            .source = source_node,
        });

        return self.addNode(.{
            .tag = .import_decl,
            .main_token = import_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(extra),
                .rhs = .none,
            },
        });
    }

    /// Parse `{ x, y as z }` import specifiers, appending to self.scratch.
    pub fn parseNamedImportSpecifiers(self: *Parser, force_type: bool) Error!void {
        _ = try self.expect(.l_brace);

        while (self.peek() != .r_brace and !self.isAtEnd()) {
            // TS inline type specifier: `import { type foo }` or `import { type foo as bar }`
            var specifier_is_type = force_type;
            if (self.is_ts and self.peek() == .kw_type) {
                const next = self.peekAt(1);
                if (next == .identifier or next.isTsContextualKeyword() or
                    next == .kw_default or next == .string_literal)
                {
                    _ = self.advance(); // skip 'type' modifier
                    specifier_is_type = true;
                }
            }
            const imported_tok: u32 = self.tokIdx();
            const imported_is_string = self.peek() == .string_literal;
            if (imported_is_string) {
                try self.validateModuleExportName(imported_tok);
                _ = self.advance();
            } else {
                _ = try self.expectIdentifierOrKeyword();
            }

            // Create imported_node BEFORE consuming `as local` so its end_tok
            // records only the imported name (matches ESTree shape).
            const imported_node = if (imported_is_string)
                try self.addNode(.{
                    .tag = .property_literal,
                    .main_token = imported_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                })
            else
                try self.addNode(.{
                    .tag = .property_ident,
                    .main_token = imported_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });

            // `as` alias — local binding can be identifier or contextual keyword
            var local_tok = imported_tok;
            var has_alias = false;
            if (self.eat(.kw_as) != null) {
                has_alias = true;
                const alias_t = self.peek();
                if (alias_t == .identifier or alias_t == .kw_as or alias_t == .kw_of or
                    alias_t == .kw_from or alias_t == .kw_let or alias_t == .kw_get or
                    alias_t == .kw_set or alias_t == .kw_static or alias_t == .kw_async or
                    alias_t == .kw_yield or alias_t == .kw_await or alias_t == .kw_default)
                {
                    local_tok = self.advance();
                } else {
                    local_tok = try self.expect(.identifier);
                }
            } else {
                // Without alias, the imported name is also the local binding —
                // must be a valid identifier, not a reserved keyword.
                const tag = self.tokenTagAt(imported_tok);
                if (tag != .identifier and !tag.isTsContextualKeyword() and tag != .kw_as and
                    tag != .kw_from and tag != .kw_of and tag != .kw_let and tag != .kw_async and
                    tag != .kw_get and tag != .kw_set and tag != .kw_static and tag != .kw_default)
                {
                    try self.emitDiagnostic(self.currentSpan(), "reserved word cannot be used as local binding in import", .{});
                    return error.ParseError;
                }
            }

            // In strict mode (modules are always strict), eval/arguments cannot be
            // used as binding identifiers (including import local bindings).
            if (self.is_module and !self.is_ts) {
                const local_text = self.tokenText(local_tok);
                if (std.mem.eql(u8, local_text, "eval") or std.mem.eql(u8, local_text, "arguments")) {
                    try self.emitDiagnostic(self.currentSpan(),
                        "'{s}' cannot be used as a binding in strict mode", .{local_text});
                    return error.ParseError;
                }
            }
            // In module mode, `await` is reserved and cannot be used as a local import binding.
            if (self.is_module and self.tokenTagAt(local_tok) == .kw_await) {
                try self.emitDiagnostic(self.currentSpan(),
                    "'await' is a reserved word at the top-level of a module", .{});
                return error.ParseError;
            }

            // local binding: if no alias and imported was an identifier, reuse imported as local.
            // Otherwise, create a fresh identifier node for the local binding.
            const local_node = if (!has_alias and !imported_is_string)
                // `import { foo }` — imported and local are the same identifier. We still
                // need a distinct node since local is a binding (reference target) while
                // imported is a property name. Create a real identifier node.
                try self.addNode(.{
                    .tag = .identifier,
                    .main_token = local_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                })
            else
                try self.addNode(.{
                    .tag = .identifier,
                    .main_token = local_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });

            const spec = try self.addNode(.{
                .tag = .import_specifier,
                .main_token = imported_tok,
                .data = .{
                    .lhs = imported_node,
                    .rhs = local_node,
                },
            });
            try self.scratchPush(spec);
            try self.emitDeclare(if (specifier_is_type) .type_import_binding else .import_binding, local_node);

            if (self.eat(.comma) == null) break;
        }

        _ = try self.expect(.r_brace);
    }

    /// Parse `* as ns`.
    pub fn parseNamespaceImportSpecifier(self: *Parser) Error!NodeIndex {
        const star_tok = try self.expect(.asterisk);
        _ = try self.expect(.kw_as);
        // The binding name accepts identifiers, TS contextual keywords (`type`,
        // `namespace`, etc.), and `as`/`from` themselves — none are reserved at
        // value position in JS or TS. Examples that must parse:
        //   `import * as type from 'x';`
        //   `import * as as from 'x';`     (binding name `as`)
        //   `import * as from from 'x';`   (binding name `from`)
        const local_tok: u32 = blk: {
            const t = self.peek();
            if (t == .identifier) break :blk self.advance();
            if (self.is_ts and t.isTsContextualKeyword()) break :blk self.advance();
            if (t == .kw_as or t == .kw_from) break :blk self.advance();
            _ = try self.expect(.identifier); // produces the standard error
            unreachable;
        };

        // TS1214: Strict reserved words cannot be used as namespace import binding names.
        try self.checkStrictBinding(local_tok);

        const local_node = try self.addNode(.{
            .tag = .identifier,
            .main_token = local_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });

        try self.emitDeclare(.import_binding, local_node);
        return self.addNode(.{
            .tag = .import_namespace_specifier,
            .main_token = star_tok,
            .data = .{
                .lhs = local_node,
                .rhs = .none,
            },
        });
    }

    /// Parse `export { ... }`, `export default ...`, `export * from '...'`,
    /// `export var/let/const/function/class`.
    pub fn parseExportDeclaration(self: *Parser) Error!NodeIndex {
        const export_tok = self.advance(); // eat 'export'
        self.is_module = true;

        switch (self.peek()) {
            .kw_default => {
                // TS1319: "A default export can only be used in an ECMAScript-style module"
                // — emitted in TS namespace bodies. Ambient module declarations
                // (`declare module 'x' { export default y; }`) are ECMAScript modules
                // and must be accepted, but they're nested inside `in_ts_namespace`
                // bookkeeping. Use `in_ts_ambient` as the carve-out: ambient module
                // bodies are real ES modules; only "real" namespaces (`namespace N {}`)
                // should reject `export default`.
                if (self.is_ts and self.in_ts_namespace and !self.in_ts_ambient) {
                    try self.emitDiagnostic(self.currentSpan(), "A default export can only be used in an ECMAScript-style module", .{});
                }
                return self.parseExportDefault(export_tok);
            },
            .l_brace => return self.parseExportNamed(export_tok),
            .asterisk => return self.parseExportAll(export_tok),
            .kw_var, .kw_let => {
                const decl = try self.parseVariableDeclaration();
                try self.registerExportBindings(decl);
                return self.addNode(.{
                    .tag = .export_named,
                    .main_token = export_tok,
                    .data = .{ .lhs = decl, .rhs = .none },
                });
            },
            .kw_const => {
                // TS `export const enum`
                if (self.is_ts and self.peekAt(1) == .kw_enum) {
                    _ = self.advance(); // eat 'const'
                    const decl = try typescript.parseEnumDeclaration(self);
                    return self.addNode(.{
                        .tag = .export_named,
                        .main_token = export_tok,
                        .data = .{ .lhs = decl, .rhs = .none },
                    });
                }
                const decl = try self.parseVariableDeclaration();
                try self.registerExportBindings(decl);
                return self.addNode(.{
                    .tag = .export_named,
                    .main_token = export_tok,
                    .data = .{ .lhs = decl, .rhs = .none },
                });
            },
            .kw_function => {
                const decl = try self.parseFunctionDeclaration();
                // fn_decl.data.lhs = extra index to FnData; FnData.name is the first field.
                if (decl != .none) {
                    const fd_idx = self.node_data_ptr[decl.toInt()].lhs.toInt();
                    if (fd_idx < self.extra_data.items.len) {
                        const name_node = NodeIndex.fromInt(self.extra_data.items[fd_idx]);
                        if (name_node != .none and self.node_tags_ptr[name_node.toInt()] == .identifier) {
                            const ntok = self.node_main_token_ptr[name_node.toInt()];
                            try self.addExportedName(self.tokenText(ntok));
                        }
                    }
                }
                return self.addNode(.{
                    .tag = .export_named,
                    .main_token = export_tok,
                    .data = .{
                        .lhs = decl,
                        .rhs = .none,
                    },
                });
            },
            .kw_class => {
                const decl = try self.parseClassDeclaration();
                // class_decl.data.lhs = extra index to ClassData; ClassData.name is the first field.
                if (decl != .none) {
                    const cd_idx = self.node_data_ptr[decl.toInt()].lhs.toInt();
                    if (cd_idx < self.extra_data.items.len) {
                        const name_node = NodeIndex.fromInt(self.extra_data.items[cd_idx]);
                        if (name_node != .none and self.node_tags_ptr[name_node.toInt()] == .identifier) {
                            const ntok = self.node_main_token_ptr[name_node.toInt()];
                            try self.addExportedName(self.tokenText(ntok));
                        }
                    }
                }
                return self.addNode(.{
                    .tag = .export_named,
                    .main_token = export_tok,
                    .data = .{
                        .lhs = decl,
                        .rhs = .none,
                    },
                });
            },
            .kw_async => {
                if (self.peekAt(1) == .kw_function and !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                    const decl = try self.parseFunctionDeclaration();
                    return self.addNode(.{
                        .tag = .export_named,
                        .main_token = export_tok,
                        .data = .{
                            .lhs = decl,
                            .rhs = .none,
                        },
                    });
                }
                try self.emitDiagnostic(self.currentSpan(), "unexpected token after 'export'", .{});
                return error.ParseError;
            },
            else => {
                if (self.is_ts) {
                    return self.parseExportTs(export_tok);
                }
                try self.emitDiagnostic(self.currentSpan(), "unexpected token after 'export'", .{});
                return error.ParseError;
            },
        }
    }

    /// Parse TypeScript-specific export forms:
    /// - `export = expr;`
    /// - `export as namespace Name;`
    /// - `export interface/type/enum/namespace/module/abstract class/declare`
    fn parseExportTs(self: *Parser, export_tok: TokenIndex) Error!NodeIndex {
        // export = expr; (TS CommonJS-style export)
        if (self.peek() == .equal) {
            // TS1063: An export assignment cannot be used in a namespace.
            if (self.in_ts_namespace and !self.in_ts_ambient) {
                try self.emitDiagnostic(self.currentSpan(), "An export assignment cannot be used in a namespace", .{});
            }
            // TS1203 (`export =` requires module: commonjs/amd/etc) is a SEMANTIC
            // error keyed off the compiler's `module` setting — same family as TS1202
            // for `import =`. The parser doesn't see tsconfig, so we can't reliably
            // raise it here; downstream type-aware tooling can.
            _ = self.advance(); // eat '='
            const expr = try self.parseAssignmentExpression();
            _ = self.eat(.semicolon);
            return self.addNode(.{
                .tag = .export_named,
                .main_token = export_tok,
                .data = .{ .lhs = expr, .rhs = .none },
            });
        }

        // export as namespace Name;
        // Only valid in declaration files (.d.ts). In regular .ts/.js files, TS1315 error.
        // Since .d.ts segments are skipped by the runner, any parsed `export as namespace`
        // is in a non-declaration file and must be rejected.
        if (self.peek() == .kw_as) {
            try self.emitDiagnostic(self.currentSpan(), "Global module exports may only appear in declaration files", .{});
            return error.ParseError;
        }

        // export declare ...
        if (self.peek() == .kw_declare) {
            // TS1120: `export declare export = x` — export assignment cannot have modifiers.
            if (self.peekAt(1) == .kw_export and self.peekAt(2) == .equal) {
                try self.emitDiagnostic(self.currentSpan(), "An export assignment cannot have modifiers", .{});
                return error.ParseError;
            }
            _ = self.advance(); // eat 'declare'
            const prev_ambient_ed = self.in_ts_ambient;
            self.in_ts_ambient = true;
            defer self.in_ts_ambient = prev_ambient_ed;
            const decl = try self.parseStatement();
            return self.addNode(.{
                .tag = .export_named,
                .main_token = export_tok,
                .data = .{ .lhs = decl, .rhs = .none },
            });
        }

        // export @dec class — decorator before class
        if (self.peek() == .at_sign) {
            while (self.peek() == .at_sign) {
                _ = self.advance();
                _ = try self.parseAssignmentExpression();
            }
            if (self.peek() == .kw_abstract) _ = self.advance();
            if (self.peek() == .kw_class) {
                const decl = try self.parseClassDeclaration();
                return self.addNode(.{
                    .tag = .export_named,
                    .main_token = export_tok,
                    .data = .{ .lhs = decl, .rhs = .none },
                });
            }
        }

        // export abstract class
        if (self.peek() == .kw_abstract and self.peekAt(1) == .kw_class) {
            _ = self.advance(); // eat 'abstract'
            const decl = try self.parseClassDeclaration();
            return self.addNode(.{
                .tag = .export_named,
                .main_token = export_tok,
                .data = .{ .lhs = decl, .rhs = .none },
            });
        }

        // export interface / type / enum / namespace / module
        if (self.peek() == .kw_interface) {
            const decl = try typescript.parseInterfaceDeclaration(self);
            return self.addNode(.{ .tag = .export_named, .main_token = export_tok, .data = .{ .lhs = decl, .rhs = .none } });
        }
        if (self.peek() == .kw_type) {
            // `export type { ... }` or `export type * ...` — type-only re-export
            if (self.peekAt(1) == .l_brace or self.peekAt(1) == .asterisk) {
                _ = self.advance(); // eat 'type'
                if (self.peek() == .l_brace) {
                    return self.parseExportNamed(export_tok);
                } else {
                    return self.parseExportAll(export_tok);
                }
            }
            const decl = try typescript.parseTypeAliasDeclaration(self);
            return self.addNode(.{ .tag = .export_named, .main_token = export_tok, .data = .{ .lhs = decl, .rhs = .none } });
        }
        if (self.peek() == .kw_enum) {
            const decl = try typescript.parseEnumDeclaration(self);
            return self.addNode(.{ .tag = .export_named, .main_token = export_tok, .data = .{ .lhs = decl, .rhs = .none } });
        }
        if (self.peek() == .kw_namespace) {
            const decl = try typescript.parseNamespaceDeclaration(self);
            return self.addNode(.{ .tag = .export_named, .main_token = export_tok, .data = .{ .lhs = decl, .rhs = .none } });
        }
        if (self.peek() == .kw_module) {
            const decl = try typescript.parseModuleDeclaration(self);
            return self.addNode(.{ .tag = .export_named, .main_token = export_tok, .data = .{ .lhs = decl, .rhs = .none } });
        }

        // `export import X = Y` — re-export alias (TS).
        // `export import A from 'mod'` is invalid (TS1191: import decl cannot have modifiers).
        if (self.peek() == .kw_import) {
            // Detect whether this is an ES import statement (not an import alias).
            // An import alias looks like: `import name =` or `import type name =`.
            // An ES import looks like: `import {`, `import *`, `import 'mod'`, `import name from`.
            const is_ts_import_alias = self.is_ts and blk: {
                var k: u32 = 1; // skip 'import'
                // skip optional 'type'
                if (self.peekAt(k) == .kw_type) k += 1;
                const cur = self.peekAt(k);
                const next = self.peekAt(k + 1);
                break :blk (cur == .identifier or cur.isKeyword()) and next == .equal;
            };
            if (!is_ts_import_alias) {
                // ES import with export modifier → TS1191
                try self.emitDiagnostic(self.currentSpan(), "An import declaration cannot have modifiers", .{});
            }
            const decl = try self.parseImportDeclaration();
            return self.addNode(.{ .tag = .export_named, .main_token = export_tok, .data = .{ .lhs = decl, .rhs = .none } });
        }

        try self.emitDiagnostic(self.currentSpan(), "unexpected token after 'export'", .{});
        return error.ParseError;
    }

    /// Parse `export default ...`.
    pub fn parseExportDefault(self: *Parser, export_tok: TokenIndex) Error!NodeIndex {
        _ = self.advance(); // eat 'default'
        try self.addExportedName("default");

        switch (self.peek()) {
            .kw_function => {
                self.in_export_default = true;
                const decl = try self.parseFunctionDeclaration();
                self.in_export_default = false;
                return self.addNode(.{
                    .tag = .export_default_fn,
                    .main_token = export_tok,
                    .data = .{
                        .lhs = decl,
                        .rhs = .none,
                    },
                });
            },
            .kw_class => {
                self.in_export_default = true;
                const decl = try self.parseClassDeclaration();
                self.in_export_default = false;
                return self.addNode(.{
                    .tag = .export_default_class,
                    .main_token = export_tok,
                    .data = .{
                        .lhs = decl,
                        .rhs = .none,
                    },
                });
            },
            .kw_async => {
                if (self.peekAt(1) == .kw_function and !self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + 1))) {
                    self.in_export_default = true;
                    const decl = try self.parseFunctionDeclaration();
                    self.in_export_default = false;
                    return self.addNode(.{
                        .tag = .export_default_fn,
                        .main_token = export_tok,
                        .data = .{
                            .lhs = decl,
                            .rhs = .none,
                        },
                    });
                }
                const expr = try self.parseAssignmentExpression();
                try self.expectSemicolon();
                return self.addNode(.{
                    .tag = .export_default_expr,
                    .main_token = export_tok,
                    .data = .{
                        .lhs = expr,
                        .rhs = .none,
                    },
                });
            },
            else => {
                if (self.is_ts) {
                    // `export default interface Foo { ... }` — TS interface as default export.
                    if (self.peek() == .kw_interface) {
                        const decl = try @import("typescript.zig").parseInterfaceDeclaration(self);
                        return self.addNode(.{
                            .tag = .export_default_expr,
                            .main_token = export_tok,
                            .data = .{ .lhs = decl, .rhs = .none },
                        });
                    }
                    // `export default enum Foo { ... }` — TS enum as default export.
                    if (self.peek() == .kw_enum) {
                        const decl = try @import("typescript.zig").parseEnumDeclaration(self);
                        return self.addNode(.{
                            .tag = .export_default_expr,
                            .main_token = export_tok,
                            .data = .{ .lhs = decl, .rhs = .none },
                        });
                    }
                    // `export default abstract class` — TS abstract class as default export.
                    if (self.peek() == .kw_abstract and self.peekAt(1) == .kw_class) {
                        _ = self.advance(); // skip 'abstract'
                        self.in_export_default = true;
                        const decl = try self.parseClassDeclaration();
                        self.in_export_default = false;
                        return self.addNode(.{
                            .tag = .export_default_class,
                            .main_token = export_tok,
                            .data = .{ .lhs = decl, .rhs = .none },
                        });
                    }
                }
                const expr = try self.parseAssignmentExpression();
                try self.expectSemicolon();
                return self.addNode(.{
                    .tag = .export_default_expr,
                    .main_token = export_tok,
                    .data = .{
                        .lhs = expr,
                        .rhs = .none,
                    },
                });
            },
        }
    }

    /// Parse `export { x, y as z } [from '...']`.
    pub fn parseExportNamed(self: *Parser, export_tok: TokenIndex) Error!NodeIndex {
        _ = try self.expect(.l_brace);

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // Track raw tokens (for the reserved-word check below) separately from
        // the spec node indices, so we can still validate without traversing nodes.
        const local_toks_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(local_toks_start);
        var local_token_list: std.ArrayList(TokenIndex) = .empty;
        defer local_token_list.deinit(self.gpa);

        while (self.peek() != .r_brace and !self.isAtEnd()) {
            // TS inline type specifier: `export { type foo }` or `export { type foo as bar }`.
            // The TS grammar lets the binding name be any identifier-like token, including
            // contextual keywords `as`/`from`. So `export { type as }` exports the binding
            // `as` type-only, and `export { type as as bar }` exports `as` aliased to `bar`.
            if (self.is_ts and self.peek() == .kw_type) {
                const next = self.peekAt(1);
                if (next == .identifier or next.isTsContextualKeyword() or
                    next == .kw_default or next == .string_literal or
                    next == .kw_as or next == .kw_from)
                {
                    // Distinguish `export { type }` (binding name `type`) from
                    // `export { type x }` (modifier + binding). The former has
                    // `type` followed by `,`/`}`/`as`+alias-name; the latter has
                    // `type` followed by another bindable token. We reach this
                    // branch only when the next token IS bindable, but for the
                    // `type as` case we still need to peek further: `type as ,`
                    // / `type as }` / `type as as <name>` → modifier; `type as <name>`
                    // (without trailing `as`) → ambiguous, prefer modifier (TS does).
                    _ = self.advance(); // skip 'type' modifier
                }
            }

            const local_tok: u32 = self.tokIdx();
            const local_is_string = self.peek() == .string_literal;
            if (local_is_string) {
                try self.validateModuleExportName(local_tok);
                _ = self.advance();
            } else {
                _ = try self.expectIdentifierOrKeyword();
            }
            try local_token_list.append(self.gpa, local_tok);

            // Create the local identifier node BEFORE consuming `as exported`
            // so its end_tok records only the local name. Otherwise rules like
            // no-useless-rename's sourceCode.getText(node.local) returns the
            // whole "foo as foo" instead of just "foo".
            const local_node = if (local_is_string)
                try self.addNode(.{
                    .tag = .property_literal,
                    .main_token = local_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                })
            else
                try self.addNode(.{
                    .tag = .property_ident,
                    .main_token = local_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });

            var exported_tok = local_tok;
            var exported_is_string = local_is_string;
            if (self.eat(.kw_as) != null) {
                exported_tok = self.tokIdx();
                exported_is_string = self.peek() == .string_literal;
                if (exported_is_string) {
                    try self.validateModuleExportName(exported_tok);
                    _ = self.advance();
                } else {
                    _ = try self.expectIdentifierOrKeyword();
                }
            }

            const exported_node = if (exported_is_string)
                try self.addNode(.{
                    .tag = .property_literal,
                    .main_token = exported_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                })
            else
                try self.addNode(.{
                    .tag = .property_ident,
                    .main_token = exported_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });

            const spec = try self.addNode(.{
                .tag = .export_specifier,
                .main_token = local_tok,
                .data = .{
                    .lhs = local_node,
                    .rhs = exported_node,
                },
            });
            try self.scratchPush(spec);

            if (self.eat(.comma) == null) break;
        }

        _ = try self.expect(.r_brace);

        // Optional `from 'source'` — if present, this is a re-export and
        // reserved keywords are allowed as specifier names.
        const has_from = self.eat(.kw_from) != null;
        var source_tok: TokenIndex = 0;
        var source_node: NodeIndex = .none;
        if (has_from) {
            source_tok = try self.expect(.string_literal);
            // Create source_node BEFORE consuming attributes/semicolon so its
            // end_tok records only the string literal.
            source_node = try self.addNode(.{
                .tag = .string_literal,
                .main_token = source_tok,
                .data = .{ .lhs = .none, .rhs = .none },
            });
            try self.skipImportAttributes();
        }

        try self.expectSemicolon();

        const specs = self.scratch.items[local_toks_start..];

        // Without `from`, local specifier names must be valid identifiers
        // (default is reserved and cannot be a binding without `from`).
        if (!has_from) {
            for (local_token_list.items) |local_token| {
                const tag = self.tokenTagAt(local_token);
                if (tag != .identifier and !tag.isTsContextualKeyword() and tag != .kw_as and
                    tag != .kw_from and tag != .kw_of and tag != .kw_let and tag != .kw_async and
                    tag != .kw_get and tag != .kw_set and tag != .kw_static)
                {
                    const span = @import("span.zig").Span{ .start = self.tok_starts_ptr[local_token], .end = self.tok_starts_ptr[local_token] };
                    try self.emitDiagnostic(span, "reserved word cannot be used as local name in export", .{});
                    return error.ParseError;
                }
                // Track for end-of-program declaration check.
                try self.pending_export_local_toks.append(self.gpa, local_token);
            }
        }

        const range = try self.listToSubRange(specs);

        if (has_from) {
            // Re-export: store via ImportData (same layout: specifiers + source).
            // source_node is already created above (before semicolon consumption).
            const extra = try self.addExtra(ast.ImportData, .{
                .specifiers_start = range.start,
                .specifiers_end = range.end,
                .source = source_node,
            });
            return self.addNode(.{
                .tag = .export_named_from,
                .main_token = export_tok,
                .data = .{
                    .lhs = NodeIndex.fromInt(extra),
                    .rhs = .none,
                },
            });
        }

        // Direct export `export { foo, bar }`: emit read references for local identifiers
        // so the scope analysis knows these names are "used" (for no-unused-vars and
        // no-useless-assignment which checks reference.identifier.parent.type === "ExportSpecifier").
        for (specs) |spec_raw| {
            const spec_lhs = self.nodeData(spec_raw).lhs;
            if (spec_lhs != .none and self.nodeTag(@intFromEnum(spec_lhs)) == .property_ident) {
                try self.emitReference(.read, spec_lhs);
            }
        }
        // Register exported names for duplicate-export detection. The exported
        // name is the spec node's rhs (the name after `as`, or the local name
        // when no alias). String-literal names are skipped (they're well-formed
        // but harder to compare with escape decoding — and re-exports use them).
        for (specs) |spec_raw| {
            const spec_data = self.nodeData(spec_raw);
            const exported_node = if (spec_data.rhs != .none) spec_data.rhs else spec_data.lhs;
            if (exported_node == .none) continue;
            const exp_tag = self.nodeTag(@intFromEnum(exported_node));
            if (exp_tag != .property_ident and exp_tag != .identifier) continue;
            const exp_tok = self.node_main_token_ptr[exported_node.toInt()];
            if (self.tokenTagAt(exp_tok) == .string_literal) continue;
            try self.addExportedName(self.tokenText(exp_tok));
        }

        return self.addNode(.{
            .tag = .export_named,
            .main_token = export_tok,
            .data = .{
                .lhs = NodeIndex.fromInt(range.start),
                .rhs = NodeIndex.fromInt(range.end),
            },
        });
    }

    /// Parse `export * from '...'` or `export * as ns from '...'`.
    pub fn parseExportAll(self: *Parser, export_tok: TokenIndex) Error!NodeIndex {
        _ = try self.expect(.asterisk);

        // Optional `as ns` or `as "string"` — store as exported node in rhs
        var exported_node: NodeIndex = .none;
        if (self.eat(.kw_as) != null) {
            const name_tok: u32 = self.tokIdx();
            if (self.peek() == .string_literal) {
                try self.validateModuleExportName(name_tok);
                _ = self.advance();
                exported_node = try self.addNode(.{
                    .tag = .property_literal,
                    .main_token = name_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            } else {
                _ = try self.expectIdentifierOrKeyword();
                exported_node = try self.addNode(.{
                    .tag = .property_ident,
                    .main_token = name_tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
                try self.addExportedName(self.tokenText(name_tok));
            }
        }

        _ = try self.expect(.kw_from);
        const source_tok = try self.expect(.string_literal);
        try self.skipImportAttributes();
        try self.expectSemicolon();

        const source_node = try self.addNode(.{
            .tag = .string_literal,
            .main_token = source_tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        return self.addNode(.{
            .tag = .export_all,
            .main_token = export_tok,
            .data = .{
                .lhs = source_node,
                .rhs = exported_node,
            },
        });
    }

    /// Parse `using x = expr` or `await using x = expr` (ES2025 Explicit Resource Management).
    fn parseUsingDeclaration(self: *Parser, is_await: bool) Error!NodeIndex {
        const main_tok: u32 = self.tokIdx();
        // Spec: in Script goal, UsingDeclaration must be contained in Block,
        // ForStatement, ForInOfStatement, FunctionBody, ClassStaticBlock, etc.
        // Note: TypeScript allows `using` at the top level even in script mode (non-module),
        // only emitting a type error (TS2853) for `await using` without module context.
        // Spec: both `using` and `await using` are disallowed at Script top-level.
        // TypeScript classifies BOTH as semantic errors (TS2852 for `await using`,
        // TS2853 for `using`) — its parser accepts them at script top level and
        // the type-checker rejects. Match TS in TS mode; keep the strict ES check
        // for plain JS where these are syntactic.
        const at_script_top_level = !self.is_module and !self.in_block and !self.in_function and !self.in_loop and !self.in_static_block;
        if (at_script_top_level and !self.is_ts) {
            const msg = if (is_await) "'await using' declaration not allowed at top level of a Script" else "'using' declaration not allowed at top level of a Script";
            try self.emitDiagnostic(self.currentSpan(), "{s}", .{msg});
            // Emit diagnostic but continue parsing so the binding is established.
            // This matches Espree's lenient behavior (error recovery without abort).
        }
        // using/await using not allowed directly in case/default clause (needs a block).
        if (self.in_case_clause) {
            if (is_await) {
                try self.emitDiagnostic(self.currentSpan(), "'await using' declarations are not allowed in 'case' or 'default' clauses unless contained within a block", .{});
            } else {
                try self.emitDiagnostic(self.currentSpan(), "'using' declarations are not allowed in 'case' or 'default' clauses unless contained within a block", .{});
            }
            if (!self.is_ts) return error.ParseError;
        }
        if (is_await) _ = self.advance(); // eat 'await'
        _ = self.advance(); // eat 'using'

        // `using` is a lexical declaration — `let` is not a valid binding name.
        const saved_lexical_decl = self.in_lexical_decl;
        self.in_lexical_decl = true;
        defer self.in_lexical_decl = saved_lexical_decl;

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            const decl_tok: u32 = self.tokIdx();
            const binding = try self.parseBindingPattern();
            // Using declarations require simple identifier binding, not destructuring.
            if (binding != .none) {
                const bt = self.node_tags_ptr[binding.toInt()];
                if (bt == .array_pattern or bt == .object_pattern) {
                    try self.emitError("'using' declaration requires an identifier binding");
                }
            }
            const using_type_annotation = try self.parseOptionalTypeAnnotation();
            if (using_type_annotation != .none) {
                if (self.node_tags_ptr[binding.toInt()] == .identifier) {
                    self.node_data_ptr[binding.toInt()].rhs = using_type_annotation;
                }
            }

            const init: NodeIndex = if (self.eat(.equal) != null)
                try self.parseAssignmentExpression()
            else .none;
            // Using declarations require an initializer.
            if (init == .none) {
                try self.emitError("'using' declaration requires an initializer");
            }

            const decl = try self.addNode(.{
                .tag = .declarator,
                .main_token = decl_tok,
                .data = .{ .lhs = binding, .rhs = init },
            });
            try self.scratchPush(decl);
            try self.emitDeclareFromDeclarator(decl, .@"const");
            if (self.eat(.comma) == null) break;
        }

        try self.expectSemicolon();
        const decls = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(decls);

        return self.addNode(.{
            .tag = .const_decl,
            .main_token = main_tok,
            .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) },
        });
    }

    /// Parse `using` declarator list without trailing semicolon (for for-loop init).
    fn parseUsingDeclaratorList(self: *Parser, main_tok: TokenIndex) Error!NodeIndex {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            const binding = try self.parseBindingPattern();
            const using_list_type_annotation = try self.parseOptionalTypeAnnotation();
            if (using_list_type_annotation != .none) {
                if (self.node_tags_ptr[binding.toInt()] == .identifier) {
                    self.node_data_ptr[binding.toInt()].rhs = using_list_type_annotation;
                }
            }
            const init: NodeIndex = if (self.eat(.equal) != null) try self.parseAssignmentExpression() else .none;
            const decl = try self.addNode(.{ .tag = .declarator, .main_token = main_tok, .data = .{ .lhs = binding, .rhs = init } });
            try self.scratchPush(decl);
            try self.emitDeclareFromDeclarator(decl, .@"const");
            if (self.eat(.comma) == null) break;
        }

        const decls = self.scratch.items[scratch_top..];
        const range = try self.listToSubRange(decls);
        return self.addNode(.{ .tag = .const_decl, .main_token = main_tok, .data = .{ .lhs = NodeIndex.fromInt(range.start), .rhs = NodeIndex.fromInt(range.end) } });
    }

    /// Fixed-capacity buffer used for decoding import-attribute keys.
    const KeyBuf = struct {
        data: [4096]u8 = undefined,
        len: usize = 0,
        fn append(self: *KeyBuf, b: u8) !void {
            if (self.len >= self.data.len) return error.OutOfMemory;
            self.data[self.len] = b;
            self.len += 1;
        }
        fn appendSlice(self: *KeyBuf, s: []const u8) !void {
            if (self.len + s.len > self.data.len) return error.OutOfMemory;
            @memcpy(self.data[self.len..][0..s.len], s);
            self.len += s.len;
        }
    };

    /// Decode a string literal body (without surrounding quotes) into out, resolving
    /// common JS escape sequences (\u, \uXXXX, \u{X}, \x, \n, \t, \r, etc.).
    fn decodeStringLiteralKey(out: *KeyBuf, body: []const u8) !void {
        var i: usize = 0;
        while (i < body.len) {
            const c = body[i];
            if (c != '\\') {
                try out.append(c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= body.len) break;
            const esc = body[i];
            i += 1;
            switch (esc) {
                'n' => try out.append('\n'),
                't' => try out.append('\t'),
                'r' => try out.append('\r'),
                'b' => try out.append(0x08),
                'f' => try out.append(0x0C),
                'v' => try out.append(0x0B),
                '0' => try out.append(0),
                '\'', '"', '\\', '/' => try out.append(esc),
                'x' => {
                    if (i + 2 <= body.len) {
                        const v = std.fmt.parseInt(u8, body[i .. i + 2], 16) catch 0;
                        try out.append(v);
                        i += 2;
                    }
                },
                'u' => {
                    if (i < body.len and body[i] == '{') {
                        i += 1;
                        const start = i;
                        while (i < body.len and body[i] != '}') : (i += 1) {}
                        const cp = std.fmt.parseInt(u21, body[start..i], 16) catch 0;
                        if (i < body.len) i += 1; // }
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                        try out.appendSlice(buf[0..n]);
                    } else if (i + 4 <= body.len) {
                        const cp = std.fmt.parseInt(u21, body[i .. i + 4], 16) catch 0;
                        i += 4;
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                        try out.appendSlice(buf[0..n]);
                    }
                },
                else => try out.append(esc),
            }
        }
    }

    /// Decode identifier text, resolving \uXXXX / \u{X} escapes.
    fn decodeIdentifierKey(out: *KeyBuf, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c != '\\') {
                try out.append(c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= text.len or text[i] != 'u') {
                try out.append('\\');
                continue;
            }
            i += 1;
            if (i < text.len and text[i] == '{') {
                i += 1;
                const start = i;
                while (i < text.len and text[i] != '}') : (i += 1) {}
                const cp = std.fmt.parseInt(u21, text[start..i], 16) catch 0;
                if (i < text.len) i += 1;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                try out.appendSlice(buf[0..n]);
            } else if (i + 4 <= text.len) {
                const cp = std.fmt.parseInt(u21, text[i .. i + 4], 16) catch 0;
                i += 4;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                try out.appendSlice(buf[0..n]);
            }
        }
    }

    /// Walk an expression tree and emit error if any object_literal or
    /// array_literal contains a CoverInitName (assignment_pattern shorthand).
    /// Such forms are only valid as destructuring patterns.
    fn validateNoCoverInitName(self: *Parser, node: NodeIndex) Error!void {
        if (node == .none) return;
        const tag = self.node_tags_ptr[node.toInt()];
        const data = self.node_data_ptr[node.toInt()];
        switch (tag) {
            .object_literal => {
                var i = data.lhs.toInt();
                while (i < data.rhs.toInt()) : (i += 1) {
                    const child = NodeIndex.fromInt(self.extra_data.items[i]);
                    if (child == .none) continue;
                    const ct = self.node_tags_ptr[child.toInt()];
                    if (ct == .assignment_pattern) {
                        try self.emitDiagnostic(self.currentSpan(), "Shorthand property with default is only allowed in destructuring patterns", .{});
                        return error.ParseError;
                    }
                    try self.validateNoCoverInitName(child);
                }
            },
            .array_literal => {
                var i = data.lhs.toInt();
                while (i < data.rhs.toInt()) : (i += 1) {
                    const child = NodeIndex.fromInt(self.extra_data.items[i]);
                    try self.validateNoCoverInitName(child);
                }
            },
            .property, .computed_property => try self.validateNoCoverInitName(data.rhs),
            .spread_element => try self.validateNoCoverInitName(data.lhs),
            .grouping_expr => try self.validateNoCoverInitName(data.lhs),
            else => {},
        }
    }

    /// Decode \\uHHHH / \\u{N} escapes in an identifier-text byte sequence into
    /// the provided buffer. Returns the decoded length. Used to canonicalize
    /// private-name identifiers (`#\\u0061` and `#a` must compare equal).
    pub fn decodeIdentForCompare(text: []const u8, out: []u8) usize {
        var i: usize = 0;
        var w: usize = 0;
        while (i < text.len and w < out.len) {
            if (text[i] != '\\' or i + 1 >= text.len or text[i + 1] != 'u') {
                out[w] = text[i];
                w += 1;
                i += 1;
                continue;
            }
            i += 2; // past \u
            var cp: u32 = 0;
            if (i < text.len and text[i] == '{') {
                i += 1;
                while (i < text.len and text[i] != '}') : (i += 1) {
                    const c = text[i];
                    const d: u32 = if (c >= '0' and c <= '9') c - '0'
                        else if (c >= 'a' and c <= 'f') c - 'a' + 10
                        else if (c >= 'A' and c <= 'F') c - 'A' + 10
                        else 0;
                    cp = cp * 16 + d;
                }
                if (i < text.len) i += 1;
            } else if (i + 4 <= text.len) {
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    const c = text[i + k];
                    const d: u32 = if (c >= '0' and c <= '9') c - '0'
                        else if (c >= 'a' and c <= 'f') c - 'a' + 10
                        else if (c >= 'A' and c <= 'F') c - 'A' + 10
                        else 0;
                    cp = cp * 16 + d;
                }
                i += 4;
            } else {
                continue;
            }
            // UTF-8 encode the codepoint into out.
            if (cp < 0x80) {
                if (w < out.len) { out[w] = @intCast(cp); w += 1; }
            } else if (cp < 0x800) {
                if (w + 2 <= out.len) {
                    out[w] = @intCast(0xC0 | (cp >> 6));
                    out[w + 1] = @intCast(0x80 | (cp & 0x3F));
                    w += 2;
                }
            } else if (cp < 0x10000) {
                if (w + 3 <= out.len) {
                    out[w] = @intCast(0xE0 | (cp >> 12));
                    out[w + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                    out[w + 2] = @intCast(0x80 | (cp & 0x3F));
                    w += 3;
                }
            } else {
                if (w + 4 <= out.len) {
                    out[w] = @intCast(0xF0 | (cp >> 18));
                    out[w + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                    out[w + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                    out[w + 3] = @intCast(0x80 | (cp & 0x3F));
                    w += 4;
                }
            }
        }
        return w;
    }

    /// Add `name` to the list of exported names; emit error and return on dup.
    fn addExportedName(self: *Parser, name: []const u8) !void {
        for (self.exported_names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                // TypeScript allows duplicate exports (e.g. function overloads, namespace merging)
                if (self.is_ts) return;
                try self.emitDiagnostic(self.currentSpan(), "Duplicate export '{s}'", .{name});
                return error.ParseError;
            }
        }
        try self.exported_names.append(self.gpa, name);
    }

    /// Walk a binding pattern (identifier / array_pattern / object_pattern /
    /// rest_element / assignment_pattern / property / shorthand_property) and
    /// register every binding identifier as an exported name.
    fn registerExportBindings(self: *Parser, node: NodeIndex) !void {
        if (node == .none) return;
        const tag = self.node_tags_ptr[node.toInt()];
        const data = self.node_data_ptr[node.toInt()];
        switch (tag) {
            .identifier => {
                const tok = self.node_main_token_ptr[node.toInt()];
                try self.addExportedName(self.tokenText(tok));
            },
            .declarator => try self.registerExportBindings(data.lhs),
            .var_decl, .let_decl, .const_decl => {
                var i = data.lhs.toInt();
                while (i < data.rhs.toInt()) : (i += 1) {
                    const child = NodeIndex.fromInt(self.extra_data.items[i]);
                    try self.registerExportBindings(child);
                }
            },
            .assignment_pattern => try self.registerExportBindings(data.lhs),
            .rest_element => try self.registerExportBindings(data.lhs),
            .array_pattern => {
                var i = data.lhs.toInt();
                while (i < data.rhs.toInt()) : (i += 1) {
                    const child = NodeIndex.fromInt(self.extra_data.items[i]);
                    try self.registerExportBindings(child);
                }
            },
            .object_pattern => {
                var i = data.lhs.toInt();
                while (i < data.rhs.toInt()) : (i += 1) {
                    const child = NodeIndex.fromInt(self.extra_data.items[i]);
                    try self.registerExportBindings(child);
                }
            },
            .property, .computed_property => try self.registerExportBindings(data.rhs),
            .shorthand_property => try self.registerExportBindings(data.lhs),
            else => {},
        }
    }

    /// Validate that a string literal used as ModuleExportName has well-formed
    /// Unicode (no unpaired surrogates after escape resolution). Spec: it is a
    /// SyntaxError if IsStringWellFormedUnicode of StringValue is false.
    fn validateModuleExportName(self: *Parser, tok: TokenIndex) !void {
        const text = self.tokenText(tok);
        if (text.len < 2) return;
        const body = text[1 .. text.len - 1];
        var i: usize = 0;
        var pending_high: ?u21 = null;
        while (i < body.len) {
            var cp: u21 = 0;
            if (body[i] == '\\') {
                i += 1;
                if (i >= body.len) break;
                const esc = body[i];
                i += 1;
                switch (esc) {
                    'u' => {
                        if (i < body.len and body[i] == '{') {
                            i += 1;
                            const start = i;
                            while (i < body.len and body[i] != '}') : (i += 1) {}
                            cp = std.fmt.parseInt(u21, body[start..i], 16) catch 0;
                            if (i < body.len) i += 1;
                        } else if (i + 4 <= body.len) {
                            cp = std.fmt.parseInt(u21, body[i .. i + 4], 16) catch 0;
                            i += 4;
                        } else continue;
                    },
                    'x' => {
                        if (i + 2 <= body.len) {
                            cp = std.fmt.parseInt(u21, body[i .. i + 2], 16) catch 0;
                            i += 2;
                        } else continue;
                    },
                    else => continue,
                }
            } else {
                // UTF-8 byte → codepoint. UTF-8 cannot encode surrogates, so safe.
                const b = body[i];
                if (b < 0x80) {
                    cp = b;
                    i += 1;
                } else {
                    const len = std.unicode.utf8ByteSequenceLength(b) catch {
                        i += 1;
                        continue;
                    };
                    if (i + len > body.len) break;
                    cp = std.unicode.utf8Decode(body[i .. i + len]) catch 0;
                    i += len;
                }
            }
            if (cp >= 0xD800 and cp <= 0xDBFF) {
                if (pending_high != null) {
                    try self.emitDiagnostic(self.currentSpan(), "Module export name has unpaired surrogate", .{});
                    return error.ParseError;
                }
                pending_high = cp;
            } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                if (pending_high == null) {
                    try self.emitDiagnostic(self.currentSpan(), "Module export name has unpaired surrogate", .{});
                    return error.ParseError;
                }
                pending_high = null;
            } else {
                if (pending_high != null) {
                    try self.emitDiagnostic(self.currentSpan(), "Module export name has unpaired surrogate", .{});
                    return error.ParseError;
                }
            }
        }
        if (pending_high != null) {
            try self.emitDiagnostic(self.currentSpan(), "Module export name has unpaired surrogate", .{});
            return error.ParseError;
        }
    }

    /// Skip import attributes: `with { key: "value", ... }` or `assert { ... }`.
    /// ES2025 import attributes proposal. Just skip the tokens without building AST.
    fn skipImportAttributes(self: *Parser) !void {
        // `with` or `assert` keyword followed by `{`
        if ((self.peek() == .kw_with or
            (self.peek() == .identifier and std.mem.eql(u8, self.tokenText(self.tokIdx()), "with")) or
            (self.peek() == .identifier and std.mem.eql(u8, self.tokenText(self.tokIdx()), "assert"))) and
            self.peekAt(1) == .l_brace)
        {
            _ = self.advance(); // eat 'with' / 'assert'
            _ = self.advance(); // eat '{'
            // Track decoded keys to detect duplicates. Spec: WithClause may not have
            // duplicate keys. String keys decode escapes (e.g. 'type' == 'type').
            var key_storage: KeyBuf = .{};
            var key_offsets: [32]struct { start: u32, len: u32 } = undefined;
            var keys_len: usize = 0;
            while (self.peek() != .r_brace and !self.isAtEnd()) {
                const key_tok: u32 = self.tokIdx();
                const key_tag = self.peek();
                const key_span_start = self.tok_starts_ptr[key_tok];
                if (key_tag == .string_literal or key_tag == .identifier or key_tag.isKeyword()) {
                    _ = self.advance();
                } else {
                    break;
                }
                const key_text = self.tokenText(key_tok);
                const ks = key_storage.len;
                if (key_tag == .string_literal and key_text.len >= 2) {
                    decodeStringLiteralKey(&key_storage, key_text[1 .. key_text.len - 1]) catch {};
                } else {
                    decodeIdentifierKey(&key_storage, key_text) catch {};
                }
                const kl = key_storage.len - ks;
                const decoded = key_storage.data[ks..][0..kl];
                var i: usize = 0;
                while (i < keys_len) : (i += 1) {
                    const prev = key_storage.data[key_offsets[i].start..][0..key_offsets[i].len];
                    if (std.mem.eql(u8, prev, decoded)) {
                        try self.emitDiagnostic(.{ .start = key_span_start, .end = key_span_start }, "Duplicate import attribute key", .{});
                        return error.ParseError;
                    }
                }
                if (keys_len < key_offsets.len) {
                    key_offsets[keys_len] = .{ .start = @intCast(ks), .len = @intCast(kl) };
                    keys_len += 1;
                }
                if (self.eat(.colon) == null) break;
                // Per ES spec, attribute values must be string literals — but TS
                // (and the conformance corpus) accepts arbitrary expressions for
                // attribute values. Be permissive: parse any AssignmentExpression.
                // Type-aware tooling can still flag non-string values where required.
                if (self.peek() == .string_literal) {
                    _ = self.advance();
                } else if (self.is_ts) {
                    _ = self.parseAssignmentExpression() catch break;
                } else {
                    break;
                }
                if (self.eat(.comma) == null) break;
            }
            _ = try self.expect(.r_brace);
        }
    }

    // ────────────────────────────────────────────────────────────
    // Expression parsing (delegated to parser/expressions.zig)
    // ────────────────────────────────────────────────────────────

    // Internal sibling modules. Kept private — sibling files reach typescript/
    // jsx via their own `@import`, and these are implementation detail, not part
    // of the parser's public surface.
    const expressions = @import("expressions.zig");
    const typescript = @import("typescript.zig");

    pub fn parseExpression(self: *Parser) Error!NodeIndex {
        return expressions.parseExpression(self);
    }

    pub fn parseAssignmentExpression(self: *Parser) Error!NodeIndex {
        return expressions.parseAssignmentExpression(self);
    }

    /// Parse a binding pattern. For now, just parse identifiers, plus
    /// basic array/object destructuring.
    pub fn parseBindingPattern(self: *Parser) Error!NodeIndex {
        try self.enterRecursion();
        defer self.leaveRecursion();
        switch (self.peek()) {
            .identifier => {
                try self.checkStrictBinding(self.tokIdx());
                if (self.in_lexical_decl and std.mem.eql(u8, self.tokenText(self.tokIdx()), "let")) {
                    try self.emitDiagnostic(self.currentSpan(), "'let' is not allowed as a variable name in lexical declarations", .{});
                    return error.ParseError;
                }
                return self.parseIdentifier();
            },
            // await is reserved in async/module/static-block contexts.
            // In TypeScript: same rule, but allow in ambient declarations (declare namespace etc.).
            // At the top level of a TS script file, `in_async` is set to enable
            // top-level await expressions, but `await` is still valid as a binding name
            // (TypeScript only reserves it inside async functions and in modules).
            .kw_await => {
                // `await` is reserved inside async functions (body and params),
                // everywhere in modules, and in static blocks. In TypeScript script
                // mode the top-level `in_async` flag enables top-level await
                // expressions but does NOT reserve `await` as a binding name —
                // only entering an actual async function body or its params does.
                const in_async_fn = self.in_async and (self.in_function or self.in_fn_params);
                const await_reserved = in_async_fn or
                    self.is_module or
                    (self.in_static_block and !self.in_function);
                if (!self.in_ts_ambient and await_reserved) {
                    try self.emitDiagnostic(self.currentSpan(), "'await' cannot be used as binding name in this context", .{});
                    return error.ParseError;
                }
                return self.parseIdentifier();
            },
            .escaped_keyword => {
                const text = self.tokenText(self.tokIdx());
                var resolved_buf: [256]u8 = undefined;
                if (resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
                    if (isAlwaysReservedStr(resolved)) {
                        try self.emitDiagnostic(self.currentSpan(), "escaped reserved word cannot be used as a binding name", .{});
                        return error.ParseError;
                    }
                    if (std.mem.eql(u8, resolved, "yield") and (self.in_generator or self.in_strict)) {
                        try self.emitDiagnostic(self.currentSpan(), "'yield' cannot be used as a binding name in this context", .{});
                        return error.ParseError;
                    }
                    if (std.mem.eql(u8, resolved, "await") and
                        !self.in_ts_ambient)
                    {
                        const in_async_fn2 = self.in_async and (self.in_function or self.in_fn_params);
                        const await_res2 = in_async_fn2 or
                            self.is_module or
                            (self.in_static_block and !self.in_function);
                        if (await_res2) {
                            try self.emitDiagnostic(self.currentSpan(), "'await' cannot be used as a binding name in this context", .{});
                            return error.ParseError;
                        }
                    }
                    if (self.in_strict and isStrictReservedStr(resolved)) {
                        try self.emitDiagnostic(self.currentSpan(), "escaped reserved word cannot be used as binding name in strict mode", .{});
                        return error.ParseError;
                    }
                }
                return self.parseIdentifier();
            },
            .l_bracket => {
                // Array destructuring pattern: [ ... ]
                const lbracket = self.advance();
                // `in` is always allowed inside `[...]` (even in for-in init)
                const saved_allow_in_bp = self.allow_in;
                self.allow_in = true;
                defer self.allow_in = saved_allow_in_bp;
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);

                while (self.peek() != .r_bracket and !self.isAtEnd()) {
                    if (self.eat(.comma) != null) {
                        // Elision (hole)
                        try self.scratchPush(NodeIndex.none);
                        continue;
                    }
                    if (self.eat(.ellipsis)) |rest_tok| {
                        const rest_binding = try self.parseBindingPattern();
                        const rest = try self.addNode(.{
                            .tag = .rest_element,
                            .main_token = rest_tok,
                            .data = .{ .lhs = rest_binding, .rhs = .none },
                        });
                        try self.scratchPush(rest);
                        if (!self.is_ts) break;
                        if (self.peek() == .comma) {
                            _ = self.advance();
                            // TS1013: trailing comma after rest element is invalid.
                            // Only emit when truly trailing (next is `]`, not another element).
                            if (self.peek() == .r_bracket) {
                                try self.emitError("A rest element may not have a trailing comma");
                            }
                        } else break;
                        continue;
                    }
                    const elem = try self.parseBindingElement();
                    try self.scratchPush(elem);
                    if (self.peek() != .r_bracket) {
                        _ = try self.expect(.comma);
                    }
                }

                _ = try self.expect(.r_bracket);
                const elements = self.scratch.items[scratch_top..];
                const range = try self.listToSubRange(elements);

                return self.addNode(.{
                    .tag = .array_pattern,
                    .main_token = lbracket,
                    .data = .{
                        .lhs = NodeIndex.fromInt(range.start),
                        .rhs = NodeIndex.fromInt(range.end),
                    },
                });
            },
            .l_brace => {
                // Object destructuring pattern: { ... }
                const lbrace = self.advance();
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);

                // Allow `in` inside object binding patterns
                const saved_allow_in_ob = self.allow_in;
                self.allow_in = true;
                defer self.allow_in = saved_allow_in_ob;

                while (self.peek() != .r_brace and !self.isAtEnd()) {
                    if (self.eat(.ellipsis)) |rest_tok| {
                        const rest_binding = try self.parseBindingPattern();
                        // Object binding rest target must be a single identifier (BindingIdentifier).
                        if (rest_binding != .none and !self.is_ts) {
                            const rb_tag = self.node_tags_ptr[rest_binding.toInt()];
                            if (rb_tag != .identifier) {
                                try self.emitError("Object rest binding must be a simple identifier");
                                return error.ParseError;
                            }
                        }
                        // TS accepts `...a: b` (rest with property name) syntactically — TS2566
                        // is the semantic error. Consume `: binding` so we don't error.
                        const rest_value: NodeIndex = if (self.is_ts and self.eat(.colon) != null)
                            try self.parseBindingElement()
                        else
                            .none;
                        _ = rest_value;
                        const rest = try self.addNode(.{
                            .tag = .rest_element,
                            .main_token = rest_tok,
                            .data = .{ .lhs = rest_binding, .rhs = .none },
                        });
                        try self.scratchPush(rest);
                        if (!self.is_ts) break;
                        if (self.peek() == .comma) {
                            _ = self.advance();
                            // TS1013: trailing comma after rest element is invalid.
                            // Only emit when truly trailing (next is `}`, not another property).
                            if (self.peek() == .r_brace) {
                                try self.emitError("A rest element may not have a trailing comma");
                            }
                        } else break;
                        continue;
                    }

                    const key_tok: u32 = self.tokIdx();

                    // Computed property: [expr]: binding
                    if (self.peek() == .l_bracket) {
                        _ = self.advance(); // eat [
                        const key_expr = try self.parseAssignmentExpression();
                        _ = try self.expect(.r_bracket);
                        _ = try self.expect(.colon);
                        const value = try self.parseBindingElement();
                        const prop = try self.addNode(.{
                            .tag = .computed_property,
                            .main_token = key_tok,
                            .data = .{ .lhs = key_expr, .rhs = value },
                        });
                        try self.scratchPush(prop);
                        if (self.eat(.comma) == null) break;
                        continue;
                    }

                    const key = try self.parsePropertyKey();

                    if (self.eat(.colon) != null) {
                        // key: binding
                        const value = try self.parseBindingElement();
                        const prop = try self.addNode(.{
                            .tag = .property,
                            .main_token = key_tok,
                            .data = .{ .lhs = key, .rhs = value },
                        });
                        try self.scratchPush(prop);
                    } else {
                        // Shorthand: { x } or { x = default }
                        // In shorthand form, the key IS the binding — apply strict-mode checks.
                        if (self.tokenTag(key_tok) == .identifier) {
                            try self.checkStrictBinding(key_tok);
                        }
                        // yield/await can't be binding names in generator/async/module context
                        const key_tag = self.tokenTag(key_tok);
                        if (key_tag == .kw_yield and self.in_generator) {
                            try self.emitDiagnostic(self.currentSpan(), "'yield' is not allowed as a binding name in generator", .{});
                        }
                        if (key_tag == .kw_await) {
                            const in_async_fn3 = self.in_async and (self.in_function or self.in_fn_params);
                            if (!self.in_ts_ambient and (in_async_fn3 or self.is_module or (self.in_static_block and !self.in_function))) {
                                try self.emitDiagnostic(self.currentSpan(), "'await' is not allowed as a binding name in async/module", .{});
                                return error.ParseError;
                            }
                        }
                        // 'enum' is a future-reserved word in any mode — never valid as a binding.
                        if (key_tag == .kw_enum) {
                            try self.emitDiagnostic(self.currentSpan(), "'enum' is not allowed as a binding name", .{});
                            return error.ParseError;
                        }
                        // 'let' is forbidden as binding name in let/const decl patterns.
                        if (self.in_lexical_decl and key_tag == .kw_let) {
                            try self.emitDiagnostic(self.currentSpan(), "'let' is not allowed as a variable name in lexical declarations", .{});
                            return error.ParseError;
                        }
                        // Strict reserved words rejected in strict-mode bindings.
                        if (self.in_strict and self.isStrictReservedWord(key_tok)) {
                            try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a binding name in strict mode", .{self.tokenText(key_tok)});
                            return error.ParseError;
                        }
                        // String/number literals and always-reserved keywords cannot be
                        // shorthand binding names — a `:` rename is required.
                        // e.g. `var { "while" }` or `var { while }` are errors;
                        // the correct form is `var { while: w }` or `var { "while": w }`.
                        if (key_tag == .string_literal or key_tag == .number_literal or key_tag == .bigint_literal or
                            self.isAlwaysReservedKeyword(key_tag))
                        {
                            try self.emitDiagnostic(self.currentSpan(), "expected ':'", .{});
                        }
                        if (self.eat(.equal) != null) {
                            // Set decl_name_text so named fn/class expressions in the
                            // default get fn_expr_name binding (ESLint fn_expr_exceptions).
                            const saved_decl_name = self.decl_name_text;
                            if (self.emit_scope_events) self.decl_name_text = self.tokenText(key_tok);
                            defer self.decl_name_text = saved_decl_name;
                            const default_val = try self.parseAssignmentExpression();
                            const pattern = try self.addNode(.{
                                .tag = .assignment_pattern,
                                .main_token = key_tok,
                                .data = .{ .lhs = key, .rhs = default_val },
                            });
                            const prop = try self.addNode(.{
                                .tag = .shorthand_property,
                                .main_token = key_tok,
                                .data = .{ .lhs = pattern, .rhs = .none },
                            });
                            try self.scratchPush(prop);
                        } else {
                            const prop = try self.addNode(.{
                                .tag = .shorthand_property,
                                .main_token = key_tok,
                                .data = .{ .lhs = key, .rhs = .none },
                            });
                            try self.scratchPush(prop);
                        }
                    }

                    if (self.eat(.comma) == null) break;
                }

                _ = try self.expect(.r_brace);
                const props = self.scratch.items[scratch_top..];
                const range = try self.listToSubRange(props);

                return self.addNode(.{
                    .tag = .object_pattern,
                    .main_token = lbrace,
                    .data = .{
                        .lhs = NodeIndex.fromInt(range.start),
                        .rhs = NodeIndex.fromInt(range.end),
                    },
                });
            },
            // Contextual keywords that are valid binding identifiers
            .kw_async, .kw_from, .kw_as, .kw_of, .kw_get, .kw_set,
            .kw_target, .kw_meta,
            => return self.parseIdentifier(),
            // TS contextual keywords that can be used as binding names
            .kw_type, .kw_declare, .kw_namespace, .kw_module,
            .kw_abstract, .kw_readonly, .kw_override,
            .kw_keyof, .kw_infer, .kw_is, .kw_asserts, .kw_satisfies,
            .kw_unique,
            => {
                if (self.is_ts) return self.parseIdentifier();
                try self.emitDiagnostic(self.currentSpan(), "expected binding name or pattern", .{});
                return error.ParseError;
            },
            .kw_static => {
                if ((self.in_strict or self.is_ts) and !(self.is_ts and self.in_ts_ambient)) {
                    try self.emitDiagnostic(self.currentSpan(), "'static' is not allowed as a binding name in strict mode", .{});
                    return error.ParseError;
                }
                return self.parseIdentifier();
            },
            .kw_let => {
                if (self.in_strict or self.is_ts) {
                    try self.emitDiagnostic(self.currentSpan(), "'let' is not allowed as a binding name in strict mode", .{});
                    return error.ParseError;
                }
                if (self.in_lexical_decl) {
                    try self.emitDiagnostic(self.currentSpan(), "'let' is not allowed as a variable name in lexical declarations", .{});
                    return error.ParseError;
                }
                return self.parseIdentifier();
            },
            .kw_yield => {
                if (self.in_strict or self.in_generator or self.is_ts) {
                    try self.emitDiagnostic(self.currentSpan(), "'yield' is not allowed as a binding name in this context", .{});
                    return error.ParseError;
                }
                return self.parseIdentifier();
            },
            .kw_implements, .kw_interface => {
                // In TS mode, `interface` is always reserved (TypeScript keyword).
                // In JS strict mode, `implements`/`interface` are future reserved words.
                if (self.is_ts or self.in_strict) {
                    try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a binding name in strict mode", .{self.tokenText(self.tokIdx())});
                    return error.ParseError;
                }
                return self.parseIdentifier();
            },
            .hash => {
                // TypeScript allows private names (#foo) in binding positions (param, const, etc.)
                // These are semantic errors (TS18002 etc.), not parse errors.
                if (self.is_ts) {
                    const hash_tok = self.advance(); // consume '#'
                    if (self.peek() == .identifier or self.peek().isKeyword() or self.peek() == .escaped_keyword) {
                        _ = self.advance(); // consume identifier
                    }
                    return self.addNode(.{
                        .tag = .identifier,
                        .main_token = hash_tok,
                        .data = .{ .lhs = .none, .rhs = .none },
                    });
                }
                try self.emitDiagnostic(self.currentSpan(), "expected binding name or pattern", .{});
                return error.ParseError;
            },
            else => {
                if (self.peek().isTsContextualKeyword()) {
                    return self.parseIdentifier();
                }
                try self.emitDiagnostic(self.currentSpan(), "expected binding name or pattern", .{});
                return error.ParseError;
            },
        }
    }

    /// Parse a binding element: binding pattern with optional default.
    pub fn parseBindingElement(self: *Parser) Error!NodeIndex {
        const main_tok: u32 = self.tokIdx();
        const binding = try self.parseBindingPattern();

        if (self.eat(.equal) != null) {
            const default_val = try self.parseAssignmentExpression();
            return self.addNode(.{
                .tag = .assignment_pattern,
                .main_token = main_tok,
                .data = .{ .lhs = binding, .rhs = default_val },
            });
        }

        return binding;
    }

    /// Parse a property key (identifier, keyword-as-identifier, string literal, number literal, bigint).
    pub fn parsePropertyKey(self: *Parser) Error!NodeIndex {
        switch (self.peek()) {
            .identifier => return self.parseIdentifier(),
            .string_literal => {
                const tok = self.advance();
                return self.addNode(.{
                    .tag = .string_literal,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            },
            .number_literal, .bigint_literal => {
                const tok = self.advance();
                const node_tag: Node.Tag = if (self.tokenTagAt(tok) == .bigint_literal) .bigint_literal else .number_literal;
                return self.addNode(.{
                    .tag = node_tag,
                    .main_token = tok,
                    .data = .{ .lhs = .none, .rhs = .none },
                });
            },
            else => {
                if (self.peek().isKeyword()) {
                    return self.parseIdentifier();
                }
                try self.emitDiagnostic(self.currentSpan(), "expected property name", .{});
                return error.ParseError;
            },
        }
    }

    // ────────────────────────────────────────────────────────────
    // Shared helpers
    // ────────────────────────────────────────────────────────────

    /// Parse an identifier token (or keyword usable as identifier) into an
    /// identifier node.
    /// Create an `.identifier` AST node WITHOUT emitting a semantic event.
    /// Used when the caller knows the identifier is a declaration name or
    /// will emit the event itself.
    pub fn parseIdentifier(self: *Parser) !NodeIndex {
        const tok = self.advance();
        return self.addNode(.{
            .tag = .identifier,
            .main_token = tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
    }

    /// Expression-position identifier: produces the AST node AND emits a
    /// `reference(.read)` semantic event.
    pub fn parseIdentifierRef(self: *Parser) !NodeIndex {
        const tok = self.advance();
        // Spec: an IdentifierName that decodes (via \u escape) to a
        // ReservedWord is a SyntaxError when used as IdentifierReference.
        // The Lexer emits these as .identifier (since the surface form
        // isn't the keyword); we validate decoded form here.
        const tag = self.tokenTagAt(tok);
        if (tag == .identifier) {
            const text = self.tokenText(tok);
            if (std.mem.indexOf(u8, text, "\\u")) |_| {
                var resolved_buf: [256]u8 = undefined;
                if (resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
                    if (isAlwaysReservedStr(resolved)) {
                        try self.emitDiagnostic(self.currentSpan(),
                            "'{s}' is a reserved word and cannot be used as an identifier", .{resolved});
                        return error.ParseError;
                    }
                }
            }
        }
        const node = try self.addNode(.{
            .tag = .identifier,
            .main_token = tok,
            .data = .{ .lhs = .none, .rhs = .none },
        });
        try self.emitReference(.read, node);
        return node;
    }


    /// Check if a keyword tag is one of the "always reserved" keywords in JavaScript —
    /// words that can never be used as identifiers regardless of strict mode.
    /// These require an explicit `:` rename when used as keys in object binding patterns.
    pub fn isAlwaysReservedKeyword(self: *const Parser, tag: TokenTag) bool {
        _ = self;
        return switch (tag) {
            .kw_break, .kw_case, .kw_catch, .kw_continue, .kw_debugger,
            .kw_default, .kw_delete, .kw_do, .kw_else, .kw_export,
            .kw_extends, .kw_finally, .kw_for, .kw_function, .kw_if,
            .kw_import, .kw_in, .kw_instanceof, .kw_new, .kw_return,
            .kw_super, .kw_switch, .kw_this, .kw_throw, .kw_try,
            .kw_typeof, .kw_var, .kw_void, .kw_while, .kw_with,
            .kw_class, .kw_const,
            .kw_null, .kw_true, .kw_false,
            => true,
            else => false,
        };
    }

    /// Check if the identifier at `tok` is a strict-mode future reserved word.
    /// Returns true if it IS a strict reserved word (and thus invalid in strict mode).
    /// Strict reserved: implements, interface, let, package, private, protected, public, static, yield
    /// Also handles unicode-escaped forms like `pu\u0062lic`.
    pub fn isStrictReservedWord(self: *const Parser, tok: TokenIndex) bool {
        const tag = self.tokenTagAt(tok);
        // Some of these are already separate keyword tokens
        if (tag == .kw_yield or tag == .kw_let or tag == .kw_static or
            tag == .kw_interface or tag == .kw_implements)
        {
            return true;
        }
        if (tag == .identifier) {
            const text = self.tokenText(tok);
            // In JS mode (is_ts = false), `interface` and `implements` are lexed as .identifier
            // (they are only keyword tokens in TypeScript mode). Check them explicitly.
            if (text.len >= 6) {
                if (text[0] == 'p' and isStrictReservedAccessModifier(text)) return true;
                if (!self.is_ts and text[0] == 'i') {
                    if (text.len == 9 and std.mem.eql(u8, text, "interface")) return true;
                    if (text.len == 10 and std.mem.eql(u8, text, "implements")) return true;
                }
            }
            // Plain .identifier with \u escapes: decoded text might be a strict reserved word
            // not in Token.keywords. The lexer sets has_unicode_escape for identifiers that
            // contain backslash sequences — skip the O(n) indexOfScalar scan for plain identifiers.
            if (text.len >= 10 and self.has_escape_ptr[tok]) {
                const c0 = text[0];
                if (c0 == 'p' or c0 == '\\' or (!self.is_ts and c0 == 'i')) {
                    var resolved_buf: [256]u8 = undefined;
                    if (resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
                        return isStrictReservedStr(resolved);
                    }
                }
            }
            return false;
        }
        if (tag == .escaped_keyword) {
            // .escaped_keyword always has \u escapes; raw text always fails isStrictReservedStr
            // so skip the raw check and go directly to resolution.
            const text = self.tokenText(tok);
            var resolved_buf: [256]u8 = undefined;
            if (resolveUnicodeEscapesParser(text, &resolved_buf)) |resolved| {
                return isStrictReservedStr(resolved);
            }
        }
        return false;
    }

    /// Subset of strict-reserved words that appear as .identifier tokens (not keyword-tagged):
    /// public, package, private, protected. All start with 'p' — callers must gate on that.
    pub inline fn isStrictReservedAccessModifier(text: []const u8) bool {
        return switch (text.len) {
            6 => std.mem.eql(u8, text, "public"),
            7 => std.mem.eql(u8, text, "package") or std.mem.eql(u8, text, "private"),
            9 => std.mem.eql(u8, text, "protected"),
            else => false,
        };
    }

    pub fn isStrictReservedStr(text: []const u8) bool {
        return switch (text.len) {
            3 => std.mem.eql(u8, text, "let"),
            5 => std.mem.eql(u8, text, "yield"),
            6 => std.mem.eql(u8, text, "public") or std.mem.eql(u8, text, "static"),
            7 => std.mem.eql(u8, text, "package") or std.mem.eql(u8, text, "private"),
            9 => std.mem.eql(u8, text, "interface") or std.mem.eql(u8, text, "protected"),
            10 => std.mem.eql(u8, text, "implements"),
            else => false,
        };
    }

    /// Check strict-mode binding restrictions: no eval/arguments as binding names,
    /// and no future reserved words as binding names.
    pub inline fn checkStrictBinding(self: *Parser, tok: TokenIndex) !void {
        if (!self.in_strict) return;
        // In TypeScript ambient declaration contexts, keywords like `static` are
        // allowed as binding names (TypeScript permits `declare var static: any`).
        if (self.is_ts and self.in_ts_ambient) return;
        // Future reserved words are invalid as binding names in strict mode.
        // TypeScript still enforces this (TS1212) for public/private/protected/etc.
        if (self.isStrictReservedWord(tok)) {
            try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a binding name in strict mode", .{self.tokenText(tok)});
            return error.ParseError;
        }
        // eval and arguments — invalid in strict mode
        const tag = self.tokenTagAt(tok);
        if (tag == .identifier) {
            const text = self.tokenText(tok);
            if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "arguments")) {
                try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a binding name in strict mode", .{text});
                return error.ParseError;
            }
        }
    }

    /// Check strict-mode assignment target: no eval/arguments as assignment targets.
    /// TS does NOT make this restriction stricter than ES — TS1100 fires only in
    /// strict mode (per `"use strict"` directive, module file, class body, or
    /// `alwaysStrict` config). Earlier code treated all TS as strict here, which
    /// rejected legitimate non-strict TS like a bare `eval++;` statement.
    pub fn checkStrictAssignTarget(self: *Parser, tok: TokenIndex) !void {
        if (!self.in_strict) return;
        const tag = self.tokenTagAt(tok);
        if (tag == .identifier) {
            const text = self.tokenText(tok);
            if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "arguments")) {
                try self.emitDiagnostic(self.currentSpan(), "'{s}' cannot be assigned to in strict mode", .{text});
                return error.ParseError;
            }
        }
    }

    /// Expect an identifier or a keyword that can serve as an identifier
    /// (for import/export specifiers where keywords are legal names).
    pub fn expectIdentifierOrKeyword(self: *Parser) Error!TokenIndex {
        if (self.peek() == .identifier or self.peek().isKeyword() or self.peek() == .string_literal) {
            return self.advance();
        }
        try self.emitDiagnostic(self.currentSpan(), "expected identifier", .{});
        return error.ParseError;
    }

    /// Check whether there is a line terminator between two token positions.
    /// Uses the has_newline_before flag stored per token at lex time — O(1) for
    /// adjacent tokens, O(k) for non-adjacent (k = tokens between a and b).
    pub fn hasNewLineBetween(self: *const Parser, tok_a: u32, tok_b: u32) bool {
        if (tok_a >= self.parsed_len or tok_b >= self.parsed_len) return false;
        const nl = self.newlines_ptr;
        // Common case: adjacent tokens — single array read.
        if (tok_b == tok_a + 1) return nl[tok_b];
        // General case: any token in (tok_a, tok_b] has a preceding newline.
        for (nl[tok_a + 1 .. tok_b + 1]) |f| {
            if (f) return true;
        }
        return false;
    }

    /// Check if `let\n{...}` is followed by `=` (destructuring declaration, not block).
    /// Scans from tok_i+1 (`{`) forward, counting braces to find the matching `}`,
    /// then checks if `=` follows.
    fn looksLikeLetDestructuring(self: *const Parser) bool {
        var i: u32 = @intCast(self.tok_i + 1); // should be `{`
        if (i >= self.parsed_len or self.tokenTagAt(i) != .l_brace) return false;
        i += 1;
        var depth: u32 = 1;
        while (i < self.parsed_len and depth > 0) : (i += 1) {
            const tag = self.tokenTagAt(i);
            if (tag == .l_brace) depth += 1 else if (tag == .r_brace) depth -= 1;
        }
        // i now points to the token after the matching `}`
        return i < self.parsed_len and self.tokenTagAt(i) == .equal;
    }

    // ────────────────────────────────────────────────────────────
    // Strict mode helpers for function declarations
    // ────────────────────────────────────────────────────────────

    /// Check if a single formal parameter node is optional (has the TS `?` marker).
    /// An optional parameter has its binding identifier's lhs set to `.root`.
    fn tsParamIsOptional(self: *Parser, param: NodeIndex) bool {
        if (param == .none) return false;
        const tag = self.node_tags_ptr[param.toInt()];
        // assignment_pattern means it has a default value — treated as optional-like but not `?`
        if (tag == .assignment_pattern) return false;
        if (tag == .identifier) {
            // Optional `?` is encoded as lhs = .root
            return self.node_data_ptr[param.toInt()].lhs == .root;
        }
        return false;
    }

    /// Check if a parameter list contains non-simple parameters
    /// (destructuring, default values, rest elements).
    pub fn hasNonSimpleParams(self: *const Parser, params: SubRange) bool {
        var i = params.start;
        while (i < params.end) : (i += 1) {
            const param = NodeIndex.fromInt(self.extra_data.items[i]);
            if (param == .none) continue;
            const param_tag = self.node_tags_ptr[param.toInt()];
            switch (param_tag) {
                .identifier => {},
                else => return true, // destructuring, default, rest, etc.
            }
        }
        return false;
    }

    /// Check parameters for strict-mode eval/arguments restrictions.
    /// Returns true if any parameter is non-simple (destructuring, default
    /// value, rest). Used to gate ES2016+ 'use strict' directive validation.
    pub fn hasNonSimpleParam(self: *Parser, params: SubRange) bool {
        var i = params.start;
        while (i < params.end) : (i += 1) {
            const param = NodeIndex.fromInt(self.extra_data.items[i]);
            if (param == .none) continue;
            const param_tag = self.node_tags_ptr[param.toInt()];
            switch (param_tag) {
                .identifier => {},
                else => return true,
            }
        }
        return false;
    }

    /// Check no duplicate identifier names in top-level simple params.
    /// Spec: methods, arrows, strict, or non-simple params reject duplicates.
    /// Recursively collect binding identifier names from a parameter node
    /// (handles patterns: object_pattern/array_pattern, defaults via assignment_pattern,
    /// rest_element, property/shorthand_property, grouping_expr).
    fn collectParamNames(self: *Parser, node: NodeIndex, names: *std.ArrayListUnmanaged([]const u8)) !void {
        if (node == .none) return;
        const tag = self.node_tags_ptr[node.toInt()];
        const data = self.node_data_ptr[node.toInt()];
        switch (tag) {
            .identifier => {
                const tok = self.node_main_token_ptr[node.toInt()];
                try names.append(self.gpa, self.tokenText(tok));
            },
            .assignment_pattern, .assign => try self.collectParamNames(data.lhs, names),
            .rest_element => try self.collectParamNames(data.lhs, names),
            .grouping_expr => try self.collectParamNames(data.lhs, names),
            .array_pattern, .array_literal => {
                var i = data.lhs.toInt();
                while (i < data.rhs.toInt()) : (i += 1) {
                    const child = NodeIndex.fromInt(self.extra_data.items[i]);
                    try self.collectParamNames(child, names);
                }
            },
            .object_pattern, .object_literal => {
                var i = data.lhs.toInt();
                while (i < data.rhs.toInt()) : (i += 1) {
                    const child = NodeIndex.fromInt(self.extra_data.items[i]);
                    try self.collectParamNames(child, names);
                }
            },
            .property, .computed_property => try self.collectParamNames(data.rhs, names),
            .shorthand_property => try self.collectParamNames(data.lhs, names),
            else => {},
        }
    }

    pub fn checkUniqueParams(self: *Parser, params: SubRange) !void {
        // TypeScript reports duplicate params as type errors (TS2440), not parse errors.
        if (self.is_ts) return;
        // Reuse parser-level scratch buffer to avoid a malloc/free per function call.
        const names = &self.param_names_scratch;
        names.clearRetainingCapacity();
        var i = params.start;
        while (i < params.end) : (i += 1) {
            const p = NodeIndex.fromInt(self.extra_data.items[i]);
            try self.collectParamNames(p, names);
        }
        var a: usize = 0;
        while (a < names.items.len) : (a += 1) {
            var b: usize = a + 1;
            while (b < names.items.len) : (b += 1) {
                if (std.mem.eql(u8, names.items[a], names.items[b])) {
                    try self.emitError("Duplicate parameter name not allowed in this context");
                    return error.ParseError;
                }
            }
        }
    }

    /// Check that no formal parameter name also appears as a lex-declared name
    /// in the function body block (top-level only). Applies to methods, generators,
    /// async functions, and strict-mode functions.
    pub fn checkParamBodyLexConflict(self: *Parser, params: SubRange, body: NodeIndex) !void {
        if (self.is_ts) return;
        if (body == .none) return;
        const body_idx = body.toInt();
        if (body_idx >= self.nodes.len) return;
        if (self.node_tags_ptr[body_idx] != .block_stmt) return;
        const body_data = self.node_data_ptr[body_idx];
        // Collect lex names from top-level of body.
        var lex_buf: [64][]const u8 = undefined;
        var lex_n: usize = 0;
        collectLexNamesInRange(self, body_data.lhs.toInt(), body_data.rhs.toInt(), &lex_buf, &lex_n);
        if (lex_n == 0) return;
        // Collect param names.
        const names = &self.param_names_scratch;
        names.clearRetainingCapacity();
        var i = params.start;
        while (i < params.end) : (i += 1) {
            const pnode = NodeIndex.fromInt(self.extra_data.items[i]);
            try self.collectParamNames(pnode, names);
        }
        for (names.items) |pname| {
            for (lex_buf[0..lex_n]) |lname| {
                if (std.mem.eql(u8, pname, lname)) {
                    try self.emitDiagnostic(self.currentSpan(),
                        "Identifier '{s}' has already been declared", .{pname});
                    return error.ParseError;
                }
            }
        }
    }

    pub fn checkParamsStrictMode(self: *Parser, params: SubRange) !void {
        var i = params.start;
        while (i < params.end) : (i += 1) {
            const param = NodeIndex.fromInt(self.extra_data.items[i]);
            if (param == .none) continue;
            const param_tag = self.node_tags_ptr[param.toInt()];
            if (param_tag == .identifier) {
                const ptok = self.node_main_token_ptr[param.toInt()];
                const ptext = self.tokenText(ptok);
                if (std.mem.eql(u8, ptext, "eval") or std.mem.eql(u8, ptext, "arguments")) {
                    try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a parameter name in strict mode", .{ptext});
                    return error.ParseError;
                }
                if (!self.is_ts and self.isStrictReservedWord(ptok)) {
                    try self.emitDiagnostic(self.currentSpan(), "'{s}' is not allowed as a parameter name in strict mode", .{ptext});
                    return error.ParseError;
                }
            }
        }
    }

    // ────────────────────────────────────────────────────────────
    // Convenience methods for expressions.zig
    // ────────────────────────────────────────────────────────────

    /// Alias for tokenTagAt — used by expressions.zig as `p.tokenTag(idx)`.
    pub fn tokenTag(self: *const Parser, index: TokenIndex) TokenTag {
        return self.tokenTagAt(index);
    }

    /// Check if there is a newline between tok_i and tok_i + offset.
    pub fn isOnNewLineAt(self: *const Parser, offset: u32) bool {
        return self.hasNewLineBetween(self.tokIdx(), @intCast(self.tok_i + offset));
    }

    /// Put a token back by rewinding tok_i to the given position.
    pub fn putBack(self: *Parser, tok: TokenIndex) void {
        self.tok_i = tok;
    }

    /// Emit a simple error diagnostic at the current position (no format args).
    pub fn emitError(self: *Parser, message: []const u8) !void {
        try self.emitDiagnostic(self.currentSpan(), "{s}", .{message});
    }

    /// Record the current (tag, start) of token `idx` before an in-place
    /// rewrite, so a backtracking speculative type-argument parse can undo it.
    /// No-op unless `record_tok_muts` is set (i.e. inside speculation).
    pub fn recordTokMut(self: *Parser, idx: usize) void {
        if (!self.record_tok_muts) return;
        self.tok_mut_log.append(self.gpa, .{
            .idx = @intCast(idx),
            .tag = self.tags_ptr[idx],
            .start = self.tok_starts_ptr[idx],
        }) catch {};
    }

    /// Undo all token rewrites recorded at or after `log_top` (in reverse),
    /// then truncate the journal back to `log_top`.
    pub fn undoTokMuts(self: *Parser, log_top: usize) void {
        var i = self.tok_mut_log.items.len;
        while (i > log_top) {
            i -= 1;
            const m = self.tok_mut_log.items[i];
            self.tags_ptr[m.idx] = m.tag;
            self.tok_starts_ptr[m.idx] = m.start;
        }
        self.tok_mut_log.shrinkRetainingCapacity(log_top);
    }

    /// Return the current length of the scratch buffer.
    pub fn scratchLen(self: *const Parser) usize {
        return self.scratch.items.len;
    }

    /// Push a node index into the scratch buffer.
    pub inline fn scratchPush(self: *Parser, node: anytype) !void {
        const val: u32 = switch (@TypeOf(node)) {
            NodeIndex => @intFromEnum(node),
            u32 => node,
            else => @compileError("scratchPush: expected NodeIndex or u32"),
        };
        if (self.scratch.items.len >= self.scratch.capacity) {
            @branchHint(.cold);
            try self.scratch.ensureTotalCapacity(self.gpa, self.scratch.capacity * 2 + 16);
        }
        self.scratch.appendAssumeCapacity(val);
    }

    /// Return a slice of the scratch buffer from `top` to the current end.
    /// @returns borrowed_from(self)
    pub fn scratchSlice(self: *const Parser, top: usize) []const u32 {
        return self.scratch.items[top..];
    }

    /// Shrink the scratch buffer back to `top`.
    pub fn scratchPop(self: *Parser, top: usize) void {
        self.scratch.shrinkRetainingCapacity(top);
    }

    /// Write a slice of u32 values to extra_data and return a SubRange.
    pub fn addSlice(self: *Parser, items: []const u32) !SubRange {
        return self.listToSubRange(items);
    }

    /// Get the AST node tag at a given raw u32 index.
    pub inline fn nodeTag(self: *const Parser, idx: u32) Node.Tag {
        return self.node_tags_ptr[idx];
    }

    /// Set the AST node tag at a given raw u32 index.
    pub inline fn setNodeTag(self: *Parser, idx: u32, tag: Node.Tag) void {
        self.node_tags_ptr[idx] = tag;
    }

    /// Get the AST node data at a given raw u32 index.
    pub inline fn nodeData(self: *const Parser, idx: u32) Node.Data {
        return self.node_data_ptr[idx];
    }

    /// Get a single u32 from extra_data at the given index.
    pub fn getExtraData(self: *const Parser, idx: u32) u32 {
        return self.extra_data.items[idx];
    }

    /// Parse a block statement (alias for parseBlockStatement).
    /// Used by expressions.zig for function/arrow/class bodies.
    pub fn parseBlock(self: *Parser) Error!NodeIndex {
        return self.parseBlockStatement();
    }

    // ────────────────────────────────────────────────────────────
    // TypeScript helpers
    // ────────────────────────────────────────────────────────────

    /// Parse an optional type annotation `: Type` in TS mode.
    /// Returns the type annotation node, or .none if no annotation present.
    pub fn parseOptionalTypeAnnotation(self: *Parser) Error!NodeIndex {
        if (!self.is_ts) return .none;
        // TS definite assignment assertion: `x!: Type` — only eat `!` if followed by `:`
        // Not valid on function parameters (TS1005), only on class fields and variable declarations.
        if (self.peek() == .bang and self.peekAt(1) == .colon) {
            if (self.in_fn_params) {
                try self.emitDiagnostic(self.currentSpan(), "A definite assignment assertion '!' is not allowed in this context", .{});
            }
            _ = self.advance();
        }
        if (self.peek() != .colon) return .none;
        const colon_tok = self.advance(); // eat ':'
        const type_node = try typescript.parseType(self);
        // JSDoc postfix `?` or `!` after type (e.g. `number?`, `string!`).
        // These are semantic errors in TS but should parse without failing.
        _ = self.eat(.question);
        _ = self.eat(.bang);
        return self.addNode(.{
            .tag = .ts_type_annotation,
            .main_token = colon_tok,
            .data = .{ .lhs = type_node, .rhs = .none },
        });
    }

    /// Parse optional type parameters <T, U> in TS mode.
    pub fn parseOptionalTypeParameters(self: *Parser) Error!ast.SubRange {
        if (!self.is_ts) return .{ .start = 0, .end = 0 };
        if (self.peek() != .less_than) return .{ .start = 0, .end = 0 };
        return typescript.parseTypeParameterList(self);
    }

    /// Checkpoint: save current parser position for speculative parsing.
    pub fn checkpoint(self: *const Parser) u32 {
        return self.tokIdx();
    }

    /// Snapshot of the mutable parse state that speculative parsing must be
    /// able to undo: token cursor plus the high-water marks of the diagnostic,
    /// node, and extra_data buffers. Restoring rewinds the cursor and discards
    /// anything appended since the snapshot. Used by TS type parsing to
    /// backtrack a trial parse (e.g. conditional-type `extends`, JSDoc `?`/`!`).
    pub const SpeculativeState = struct {
        tok_i: usize,
        diag_len: usize,
        nodes_len: usize,
        extra_len: usize,
    };

    pub fn saveSpeculative(self: *const Parser) SpeculativeState {
        return .{
            .tok_i = self.tok_i,
            .diag_len = self.diagnostics.items.len,
            .nodes_len = self.nodes.len,
            .extra_len = self.extra_data.items.len,
        };
    }

    pub fn restoreSpeculative(self: *Parser, s: SpeculativeState) void {
        self.tok_i = s.tok_i;
        self.diagnostics.shrinkRetainingCapacity(s.diag_len);
        self.nodes.len = @intCast(s.nodes_len);
        self.extra_data.shrinkRetainingCapacity(s.extra_len);
    }

    /// Restore parser position from a checkpoint.
    pub fn restore(self: *Parser, saved: u32) void {
        self.tok_i = saved;
    }

    /// Check if an identifier-like token can be treated as an identifier.
    /// Includes TS contextual keywords that can be used as identifiers.
    pub fn isIdentifierLike(self: *Parser) bool {
        const tag = self.peek();
        if (tag == .identifier) return true;
        if (tag.isKeyword()) return true;
        return false;
    }

    // ────────────────────────────────────────────────────────────
    // Character classification helpers
    // ────────────────────────────────────────────────────────────

    const isIdentChar = Token.isIdentChar;
    const isNumericChar = Token.isNumericChar;
};

/// Check whether the source file has a top-level ES module export (e.g., `export {}`)
/// which makes it a true ES module, as opposed to a file with only namespace aliases.
/// Used to distinguish `import await = ...` (TS1262) in real modules vs non-modules.
fn hasEsModuleExport(source: []const u8) bool {
    var i: usize = 0;
    while (i < source.len) {
        // Skip to start of line
        if (i == 0 or source[i - 1] == '\n') {
            // Skip whitespace at line start
            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
            if (i + 6 < source.len and std.mem.eql(u8, source[i..][0..6], "export")) {
                const next = source[i + 6];
                if (next == ' ' or next == '\t' or next == '{' or next == '*' or next == '\n') return true;
            }
        }
        while (i < source.len and source[i] != '\n') i += 1;
        if (i < source.len) i += 1;
    }
    return false;
}

// ────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse empty program" {
    const allocator = testing.allocator;
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .eof, .start = 0 });
    var result = try Parser.parse(allocator, "", list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(Node.Tag.root, result.nodeTag(.root));
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "parse empty statement" {
    const allocator = testing.allocator;
    const source = ";";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .semicolon, .start = 0 });
    try list.append(allocator, .{ .tag = .eof, .start = 1 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(Node.Tag.root, result.nodeTag(.root));
    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // root + empty_stmt = 2 nodes
    try testing.expectEqual(@as(usize, 2), result.nodes.len);
    try testing.expectEqual(Node.Tag.empty_stmt, result.nodeTag(NodeIndex.fromInt(1)));
}

test "parse debugger statement" {
    const allocator = testing.allocator;
    const source = "debugger;";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .kw_debugger, .start = 0 });
    try list.append(allocator, .{ .tag = .semicolon, .start = 8 });
    try list.append(allocator, .{ .tag = .eof, .start = 9 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(usize, 2), result.nodes.len);
    try testing.expectEqual(Node.Tag.debugger_stmt, result.nodeTag(NodeIndex.fromInt(1)));
}

test "parse variable declaration" {
    const allocator = testing.allocator;
    const source = "let x;";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .kw_let, .start = 0 });
    try list.append(allocator, .{ .tag = .identifier, .start = 4 });
    try list.append(allocator, .{ .tag = .semicolon, .start = 5 });
    try list.append(allocator, .{ .tag = .eof, .start = 6 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // root + identifier + declarator + let_decl = 4 nodes
    try testing.expectEqual(@as(usize, 4), result.nodes.len);
    try testing.expectEqual(Node.Tag.identifier, result.nodeTag(NodeIndex.fromInt(1)));
    try testing.expectEqual(Node.Tag.declarator, result.nodeTag(NodeIndex.fromInt(2)));
    try testing.expectEqual(Node.Tag.let_decl, result.nodeTag(NodeIndex.fromInt(3)));
}

test "parse if statement" {
    const allocator = testing.allocator;
    const source = "if (x) ;";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .kw_if, .start = 0 });
    try list.append(allocator, .{ .tag = .l_paren, .start = 3 });
    try list.append(allocator, .{ .tag = .identifier, .start = 4 });
    try list.append(allocator, .{ .tag = .r_paren, .start = 5 });
    try list.append(allocator, .{ .tag = .semicolon, .start = 7 });
    try list.append(allocator, .{ .tag = .eof, .start = 8 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // root + identifier(cond) + empty_stmt(consequent) + if_stmt = 4 nodes
    try testing.expectEqual(@as(usize, 4), result.nodes.len);
    try testing.expectEqual(Node.Tag.if_stmt, result.nodeTag(NodeIndex.fromInt(3)));
}

test "parse return statement with ASI" {
    const allocator = testing.allocator;
    // "return\n42" — ASI should insert semicolon after return
    const source = "return\n42";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .kw_return, .start = 0 });
    try list.append(allocator, .{ .tag = .number_literal, .start = 7, .has_newline_before = true });
    try list.append(allocator, .{ .tag = .eof, .start = 9 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    // return with no value due to ASI, then 42 as expression statement.
    // We get a diagnostic about return outside function.
    // root + return_stmt + number_literal + expression_stmt = 4 nodes
    try testing.expectEqual(@as(usize, 4), result.nodes.len);
    try testing.expectEqual(Node.Tag.return_stmt, result.nodeTag(NodeIndex.fromInt(1)));
    // return_stmt lhs should be .none (no value due to ASI)
    try testing.expectEqual(NodeIndex.none, result.nodeData(NodeIndex.fromInt(1)).lhs);
}

test "parse block statement" {
    const allocator = testing.allocator;
    const source = "{ ; }";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .l_brace, .start = 0 });
    try list.append(allocator, .{ .tag = .semicolon, .start = 2 });
    try list.append(allocator, .{ .tag = .r_brace, .start = 4 });
    try list.append(allocator, .{ .tag = .eof, .start = 5 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // root + empty_stmt + block_stmt = 3 nodes
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqual(Node.Tag.block_stmt, result.nodeTag(NodeIndex.fromInt(2)));
}

test "parse while statement" {
    const allocator = testing.allocator;
    const source = "while (x) ;";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .kw_while, .start = 0 });
    try list.append(allocator, .{ .tag = .l_paren, .start = 6 });
    try list.append(allocator, .{ .tag = .identifier, .start = 7 });
    try list.append(allocator, .{ .tag = .r_paren, .start = 8 });
    try list.append(allocator, .{ .tag = .semicolon, .start = 10 });
    try list.append(allocator, .{ .tag = .eof, .start = 11 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // root + identifier + empty_stmt + while_stmt = 4 nodes
    try testing.expectEqual(@as(usize, 4), result.nodes.len);
    try testing.expectEqual(Node.Tag.while_stmt, result.nodeTag(NodeIndex.fromInt(3)));
}

test "parse labeled statement" {
    const allocator = testing.allocator;
    const source = "loop: ;";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .identifier, .start = 0 });
    try list.append(allocator, .{ .tag = .colon, .start = 4 });
    try list.append(allocator, .{ .tag = .semicolon, .start = 6 });
    try list.append(allocator, .{ .tag = .eof, .start = 7 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // root + property_ident (label) + empty_stmt + labeled_stmt = 4 nodes
    try testing.expectEqual(@as(usize, 4), result.nodes.len);
    try testing.expectEqual(Node.Tag.labeled_stmt, result.nodeTag(NodeIndex.fromInt(3)));
}

test "parse expression statement" {
    const allocator = testing.allocator;
    const source = "42;";
    var list = TokenList{};
    defer list.deinit(allocator);
    try list.append(allocator, .{ .tag = .number_literal, .start = 0 });
    try list.append(allocator, .{ .tag = .semicolon, .start = 2 });
    try list.append(allocator, .{ .tag = .eof, .start = 3 });

    var result = try Parser.parse(allocator, source, list.slice());
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // root + number_literal + expression_stmt = 3 nodes
    try testing.expectEqual(@as(usize, 3), result.nodes.len);
    try testing.expectEqual(Node.Tag.expression_stmt, result.nodeTag(NodeIndex.fromInt(2)));
    try testing.expectEqual(Node.Tag.number_literal, result.nodeTag(NodeIndex.fromInt(1)));
}
