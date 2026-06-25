const std = @import("std");
const testing = std.testing;
const es_parser = @import("es_parser");
const Lexer = es_parser.Lexer;
const Parser = es_parser.Parser;
const semantic = es_parser.semantic;
const scope_mod = es_parser.scope;
const symbol_mod = es_parser.symbol;
const ref_mod = es_parser.reference;
const ScopeKind = scope_mod.ScopeKind;
const ScopeId = scope_mod.ScopeId;
const SymbolId = symbol_mod.SymbolId;
const BindingKind = symbol_mod.BindingKind;
const ReferenceKind = ref_mod.ReferenceKind;
const ReferenceId = ref_mod.ReferenceId;

fn analyzeSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenize(allocator, source);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parse(allocator, source, tokens.slice());
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyze(allocator, &tree);
}

fn analyzeModuleSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithOptions(allocator, source, .js, true);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, true);
}

fn analyzeTsSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithLanguage(allocator, source, .ts);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .language = .ts, .emit_events = true });
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyze(allocator, &tree);
}

fn analyzeTsModuleSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithLanguage(allocator, source, .ts);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .language = .ts, .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, true);
}

test "analyze without scope-event emission errors instead of returning empty" {
    const allocator = testing.allocator;
    const source = "let x = 1; x;";
    var _lr = try Lexer.tokenize(allocator, source);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    // emit_events defaults to false here, so no scope events are produced.
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{});
    defer tree.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), tree.scope_events.len);
    try testing.expectError(
        semantic.SemanticAnalyzer.Error.MissingScopeEvents,
        semantic.SemanticAnalyzer.analyze(allocator, &tree),
    );
}

test "deeply nested shadowing scopes do not produce spurious redeclare diagnostics (#18)" {
    const allocator = testing.allocator;
    // Build `depth` nested blocks, each with its own `let x` (legal shadowing).
    // depth > the resolver's old fixed 256 scope-stack cap, but < the parser's
    // max_recursion_depth (400). The pre-fix resolver dropped scope_opens past
    // 256 while still honoring their scope_close, collapsing distinct block
    // scopes into one and reporting the shadowed `let x`s as duplicate bindings.
    const depth = 300;
    var buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(allocator, "{ let x = 1; x;");
    i = 0;
    while (i < depth) : (i += 1) try buf.append(allocator, '}');
    const source = buf.items;

    var _lr = try Lexer.tokenize(allocator, source);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parse(allocator, source, tokens.slice());
    defer tree.deinit(allocator);

    // Premise: the parser accepts this depth (it is below max_recursion_depth).
    var parse_errors: usize = 0;
    for (tree.errors) |d| {
        if (d.severity == .@"error") parse_errors += 1;
    }
    try testing.expectEqual(@as(usize, 0), parse_errors);

    // diagnose_redeclare runs the CFG build, which assumes zeroed buffers — use
    // the documented zeroing-allocator wrapper.
    var za = semantic.ZeroingAllocator.init(allocator);
    const za_alloc = za.allocator();
    var result = try semantic.SemanticAnalyzer.analyzeWithOptions(za_alloc, &tree, .{
        .is_module = false,
        .diagnose_redeclare = true,
    });
    defer result.deinit(za_alloc);

    // Every `let x` lives in its own block scope, so there are no duplicate
    // bindings: zero error-severity diagnostics.
    var redeclare_errors: usize = 0;
    for (result.diagnostics) |d| {
        if (d.severity == .@"error") redeclare_errors += 1;
    }
    try testing.expectEqual(@as(usize, 0), redeclare_errors);
    // Sanity: every `let x` produced its own symbol.
    try testing.expect(result.symbols.count() >= depth);
}

// Deeply nested control flow (try/catch/finally + loops + switch) whose CFG has
// enough predecessor edges to outgrow the code-path builder's `all_prev_targets`
// pre-size, forcing it to reallocate mid-build. The pre-fix builder handed
// `createSegment` a predecessor slice that *aliased* `all_prev_targets` (via
// flattenUnused's single-unused fast path); the reallocation dangled that alias,
// so the append loop read freed memory — a layout-dependent OOB / heap corruption
// (#17). It surfaced only when the freed buffer changed under the reader: a tight
// or poisoning allocator. This regression therefore needs a safety build (freed
// memory is poisoned) — which the test build is — to bite; under ReleaseFast over
// an arena the stale buffer survives and masks it.
//
// The fixture is a generator-found seed (error-recovered AST is in scope per #17);
// the trigger is edge-density-sensitive, so it is kept byte-exact. The structure-
// aware fuzz target in fuzz_test.zig is the durable, non-fragile guard for the class.
test "deeply nested CFG does not read a dangling predecessor slice (#17)" {
    const source = @embedFile("fixtures/cfg_deep_nesting_17.js");
    const allocator = testing.allocator;

    var _lr = try Lexer.tokenizeWithOptions(allocator, source, .js, false);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .emit_events = true });
    defer tree.deinit(allocator);

    // need_cfg drives the code-path builder where the dangling read lived. Use the
    // documented zeroing-allocator wrapper so any *uninitialized-read* class is
    // satisfied and only the (now-fixed) dangling-alias write could trip.
    var za = semantic.ZeroingAllocator.init(allocator);
    const za_alloc = za.allocator();
    var result = try semantic.SemanticAnalyzer.analyzeWithOptions(za_alloc, &tree, .{
        .need_cfg = true,
        .diagnose_redeclare = true,
        .build_parents = true,
    });
    defer result.deinit(za_alloc);

    // Reaching here without a safety trip is the assertion. Sanity-check that the
    // pipeline actually ran the CFG-bearing analysis rather than bailing early.
    try testing.expect(result.symbols.count() > 0);
}

// 70 levels of nested functions — exceeds the old fn_alive_stack[64] cap.
// Before the fix the 65th scope_open silently dropped its save, misaligning
// all subsequent fn_alive_stack pops.  The stack now grows via sa.realloc so
// no push is ever dropped.  A crash or safety trip is the failure signal.
test "fn_alive_stack grows past 64 with deeply nested functions (#25)" {
    const source = @embedFile("fixtures/deep_fn_nesting_70.js");
    const allocator = testing.allocator;

    var _lr = try Lexer.tokenizeWithOptions(allocator, source, .js, false);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .emit_events = true });
    defer tree.deinit(allocator);

    var result = try semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &tree, .{
        .need_cfg = true,
    });
    defer result.deinit(allocator);

    try testing.expect(result.symbols.count() > 0);
}

// 70 levels of nested if-branches — exceeds the old branch_save/cons[64] cap.
// Before the fix the 65th branch_open silently dropped its save; the pop still
// ran, misaligning all subsequent alive-state restorations.  The stacks now
// grow via sa.realloc so no push is ever dropped.
test "branch_save/cons stacks grow past 64 with deeply nested branches (#25)" {
    const source = @embedFile("fixtures/deep_branch_nesting_70.js");
    const allocator = testing.allocator;

    var _lr = try Lexer.tokenizeWithOptions(allocator, source, .js, false);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .emit_events = true });
    defer tree.deinit(allocator);

    var result = try semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &tree, .{
        .need_cfg = true,
    });
    defer result.deinit(allocator);

    try testing.expect(result.symbols.count() > 0);
}

// ── export type { X } reference emission (#33) ──────────────

test "export type { X } emits type_read reference (#33)" {
    // Before the fix, parseExportNamed always emitted .read regardless of the
    // `export type` prefix.  type_read is required so symbolIsTypeOnly() returns
    // true for consistent-type-imports checking.
    var r = try analyzeTsModuleSource("const Type = 1; export type { Type };");
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "Type") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var found_type_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .type_read) found_type_read = true;
    }
    try testing.expect(found_type_read);
}

test "export { type X } inline modifier emits type_read reference (#33)" {
    var r = try analyzeTsModuleSource("const Type = 1; export { type Type };");
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "Type") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var found_type_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .type_read) found_type_read = true;
    }
    try testing.expect(found_type_read);
}

test "export { X } (non-type) still emits read reference (#33)" {
    var r = try analyzeTsModuleSource("const Type = 1; export { Type };");
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "Type") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var found_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) found_read = true;
    }
    try testing.expect(found_read);
}

test "export { type A, B } mixed: A gets type_read, B gets read (#33)" {
    // Catches sticky this_spec_is_type across iterations or off-by-one in
    // the parallel specifier_is_type index.
    var r = try analyzeTsModuleSource("const A = 1; const B = 2; export { type A, B };");
    defer r.deinit(testing.allocator);

    const sym_a = findSymbol(&r, "A") orelse return error.SymbolNotFound;
    const range_a = r.symbols.getRefRange(sym_a);
    try testing.expect(!range_a.isEmpty());
    var a_has_type_read = false;
    for (r.ref_by_sym[range_a.start..range_a.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .type_read) a_has_type_read = true;
    }
    try testing.expect(a_has_type_read);

    const sym_b = findSymbol(&r, "B") orelse return error.SymbolNotFound;
    const range_b = r.symbols.getRefRange(sym_b);
    try testing.expect(!range_b.isEmpty());
    var b_has_read = false;
    for (r.ref_by_sym[range_b.start..range_b.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) b_has_read = true;
    }
    try testing.expect(b_has_read);
}

test "export type { X as Y } alias: reference on local name (#33)" {
    // Confirms spec_lhs (local X) is the ref target, not the exported alias Y.
    var r = try analyzeTsModuleSource("const X = 1; export type { X as Y };");
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "X") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var found_type_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .type_read) found_type_read = true;
    }
    try testing.expect(found_type_read);
}

test "export { type X as Y } inline type + alias emits type_read on local (#33)" {
    var r = try analyzeTsModuleSource("const X = 1; export { type X as Y };");
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "X") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var found_type_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .type_read) found_type_read = true;
    }
    try testing.expect(found_type_read);
}

// ── Enum member symbols (#31) ────────────────────────────────

test "enum members are declared as enum_member symbols (#31)" {
    var r = try analyzeTsSource("enum Dir { Up, Down, Left, Right }");
    defer r.deinit(testing.allocator);

    for (&[_][]const u8{ "Up", "Down", "Left", "Right" }) |name| {
        const sym = findSymbol(&r, name) orelse return error.SymbolNotFound;
        try testing.expectEqual(BindingKind.enum_member, r.symbols.getBindingKind(sym));
    }
}

test "enum name is declared as enum_decl in outer scope (#31)" {
    var r = try analyzeTsSource("enum Dir { Up }");
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "Dir") orelse return error.SymbolNotFound;
    try testing.expectEqual(BindingKind.enum_decl, r.symbols.getBindingKind(sym));
}

test "enum member shadows outer variable — both symbols exist (#31)" {
    // Regression for no-shadow: enum member `A` must be a symbol so
    // no-shadow can detect that it shadows the outer `const A`.
    var r = try analyzeTsSource("const A = 2; enum Test { A = 1, B = 2 }");
    defer r.deinit(testing.allocator);

    // Both the outer `A` and the enum member `A` must be in the symbol table.
    var a_count: u32 = 0;
    var i: u32 = 0;
    while (i < r.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, r.symbols.getName(id), "A")) a_count += 1;
    }
    try testing.expect(a_count >= 2);
}

test "string-keyed enum members are NOT declared as symbols (#31)" {
    // `enum E { "key" = 1 }` — string keys can't shadow identifiers.
    var r = try analyzeTsSource("enum E { \"key\" = 1 }");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?SymbolId, null), findSymbol(&r, "key"));
}

test "intra-enum cross-reference B = A resolves to enum member A (#31)" {
    // Core ordering guarantee: A is declared before B's initializer is parsed,
    // so the reference in B = A must resolve to the enum-member A symbol.
    var r = try analyzeTsSource("const A = 2; enum E { A = 1, B = A }");
    defer r.deinit(testing.allocator);

    // Find the enum-member A (not the outer const A).
    const enum_a: SymbolId = blk: {
        var i: u32 = 0;
        while (i < r.symbols.count()) : (i += 1) {
            const id = SymbolId.fromInt(i);
            if (std.mem.eql(u8, r.symbols.getName(id), "A") and
                r.symbols.getBindingKind(id) == .enum_member) break :blk id;
        }
        return error.EnumMemberANotFound;
    };
    // The enum member A must have at least one read reference (from B = A).
    const range = r.symbols.getRefRange(enum_a);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "const enum members are declared as enum_member symbols (#31)" {
    var r = try analyzeTsSource("const enum Dir { Up, Down, Left, Right }");
    defer r.deinit(testing.allocator);

    for (&[_][]const u8{ "Up", "Down", "Left", "Right" }) |name| {
        const sym = findSymbol(&r, name) orelse return error.SymbolNotFound;
        try testing.expectEqual(BindingKind.enum_member, r.symbols.getBindingKind(sym));
    }
}

test "contextual-keyword enum members are declared as symbols (#31)" {
    // `type`, `from`, `as` are valid TS enum member names.
    var r = try analyzeTsSource("enum E { type, from, as }");
    defer r.deinit(testing.allocator);

    for (&[_][]const u8{ "type", "from", "as" }) |name| {
        const sym = findSymbol(&r, name) orelse return error.SymbolNotFound;
        try testing.expectEqual(BindingKind.enum_member, r.symbols.getBindingKind(sym));
    }
}

test "empty enum does not crash and declares enum name (#31)" {
    var r = try analyzeTsSource("enum E {}");
    defer r.deinit(testing.allocator);
    const sym = findSymbol(&r, "E") orelse return error.SymbolNotFound;
    try testing.expectEqual(BindingKind.enum_decl, r.symbols.getBindingKind(sym));
}

// ── JSX factory read reference (#34) ────────────────────────

fn analyzeTsxModuleSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithLanguage(allocator, source, .tsx);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .language = .tsx, .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, true);
}

test "intrinsic JSX <div> emits read ref for default React import (#34)" {
    // Classic transform: React.createElement('div',...) — React must be read.
    var r = try analyzeTsxModuleSource(
        \\import React from 'react';
        \\const C: React.FC = () => <div />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "intrinsic JSX emits read ref for namespace React import (#34)" {
    var r = try analyzeTsxModuleSource(
        \\import * as React from 'react';
        \\const C = () => <span />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "@jsx pragma overrides default factory name (#34)" {
    // /* @jsx h */ pragma → factory is `h`, not `React`.
    var r = try analyzeTsxModuleSource(
        \\/* @jsx h */
        \\import h from 'preact';
        \\const C = () => <div />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "h") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "import type * as React does NOT set factory node — no spurious read ref (#34)" {
    // `import type * as React` is type-erased. Using it as factory would be
    // a runtime error. The !is_type_import guard in parseNamespaceImportSpecifier
    // must prevent jsx_factory_node from being set.
    var r = try analyzeTsxModuleSource(
        \\import type * as React from 'react';
        \\const C: React.FC = () => <div />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        try testing.expect(r.references.getKind(ref_id) != .read);
    }
}

test "@jsx React.createElement dotted pragma extracts root identifier (#34)" {
    var r = try analyzeTsxModuleSource(
        \\/* @jsx React.createElement */
        \\import React from 'react';
        \\const C = () => <div />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "combined import React + named specifiers records factory node (#34)" {
    var r = try analyzeTsxModuleSource(
        \\import React, { useState } from 'react';
        \\const C = () => <div />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "fragment-only JSX emits read ref for factory (#40)" {
    // Classic transform: <>{children}</> → React.createElement(React.Fragment, null, children).
    // Factory must have a read ref even when no intrinsic or component element is present.
    var r = try analyzeTsxModuleSource(
        \\import React from 'react';
        \\const W: React.FC<{children: React.ReactNode}> = ({children}) => <>{children}</>;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "nested fragment emits read ref for factory (#40)" {
    var r = try analyzeTsxModuleSource(
        \\import React from 'react';
        \\const C = () => <><div /><span /></>;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

// ── JSX factory ref for component-only files (#41) ──────────

test "component-only JSX emits read ref for factory (#41)" {
    // Classic transform: React.createElement(Foo, …) — factory must be read even
    // when no intrinsic element is present in the file.
    var r = try analyzeTsxModuleSource(
        \\import React from 'react';
        \\function Foo() { return null; }
        \\const C: React.FC = () => <Foo />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "member-expression JSX <foo.Bar /> emits read ref for factory (#41)" {
    var r = try analyzeTsxModuleSource(
        \\import React from 'react';
        \\const ui = { Button: () => null };
        \\const C = () => <ui.Button />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "React") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

test "component JSX <Foo> still emits read ref (not affected by #34)" {
    var r = try analyzeTsxModuleSource(
        \\import React from 'react';
        \\function Foo() { return <div />; }
        \\const C = () => <Foo />;
    );
    defer r.deinit(testing.allocator);

    const sym = findSymbol(&r, "Foo") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(sym);
    try testing.expect(!range.isEmpty());
    var has_read = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id) == .read) has_read = true;
    }
    try testing.expect(has_read);
}

// ── Structural test helpers ─────────────────────────────────
//
// Unlike count-based smoke checks (`symbols.count() > 0`), these assert the
// actual shape of the semantic graph: which symbol exists, its binding kind,
// the scope kind it lives in, and how many references resolve to it.

/// Find the first symbol with the given name. Returns its SymbolId or null.
fn findSymbol(result: *const semantic.SemanticResult, name: []const u8) ?SymbolId {
    var i: u32 = 0;
    while (i < result.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, result.symbols.getName(id), name)) return id;
    }
    return null;
}

/// Find a symbol by name AND binding kind (disambiguates same-named bindings,
/// e.g. an outer import vs. an inner parameter of the same name).
fn findSymbolByKind(result: *const semantic.SemanticResult, name: []const u8, binding: BindingKind) ?SymbolId {
    var i: u32 = 0;
    while (i < result.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (result.symbols.getBindingKind(id) == binding and
            std.mem.eql(u8, result.symbols.getName(id), name)) return id;
    }
    return null;
}

test "parameter type annotation resolves in the enclosing scope, not the param scope (#53)" {
    // A parameter is not in scope for its OWN type annotation, so `foo` in
    // `foo: foo.Foo` must resolve to the outer namespace import (a type_read),
    // leaving the same-named parameter unused. The first six cases are genuine
    // regression guards (pre-fix the parameter captured the reference); the arrow
    // and function-type paths already resolved correctly and are pinned here as
    // invariants so a future change can't regress them.
    const cases = [_][]const u8{
        "import * as foo from 'foo';\nclass A { constructor(foo: foo.Foo) {} }", // class constructor
        "import * as foo from 'foo';\nfunction g(foo: foo.Foo) {}", // function declaration
        "import * as foo from 'foo';\nclass A { m(foo: foo.Foo) {} }", // method
        "import * as foo from 'foo';\nfunction g(...foo: foo.Foo[]) {}", // rest parameter
        "import * as foo from 'foo';\nclass A { set p(foo: foo.Foo) {} }", // setter
        "import * as foo from 'foo';\nclass A { constructor(private foo: foo.Foo) {} }", // parameter property
        "import * as foo from 'foo';\nconst f = (foo: foo.Foo) => {};", // arrow (already correct — invariant)
        "import * as foo from 'foo';\nlet h: (foo: foo.Foo) => void;", // function type (already correct — invariant)
    };
    for (cases) |src| {
        var r = try analyzeTsModuleSource(src);
        defer r.deinit(testing.allocator);
        const import_sym = findSymbolByKind(&r, "foo", .import_binding) orelse return error.ImportNotFound;
        // Every one of these contexts emits a `foo` parameter symbol, so assert its
        // absence of references unconditionally (a future path that stops emitting it
        // should fail loudly here, not silently skip the check).
        const param_sym = findSymbolByKind(&r, "foo", .parameter) orelse return error.ParamNotFound;
        // The type reference in `foo.Foo` resolves to the import...
        try testing.expect(r.symbols.getRefRange(import_sym).len() >= 1);
        // ...and the same-named parameter is left with zero references.
        try testing.expectEqual(@as(u32, 0), r.symbols.getRefRange(param_sym).len());
    }
}

test "param annotation resolves outward while the body resolves to the param (#53)" {
    // Strongest single-source guard: the SAME name `foo` must resolve to the import
    // in the annotation `foo.Foo` but to the parameter in the body `foo;`.
    var r = try analyzeTsModuleSource(
        \\import * as foo from 'foo';
        \\function f(foo: foo.Foo) { foo; }
    );
    defer r.deinit(testing.allocator);
    const import_sym = findSymbolByKind(&r, "foo", .import_binding) orelse return error.ImportNotFound;
    const param_sym = findSymbolByKind(&r, "foo", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(import_sym).len()); // the `foo.Foo` annotation
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(param_sym).len()); // the body `foo;`
}

test "parameter default value still resolves in the parameter scope (#53)" {
    // The declare moves after the TYPE annotation but stays before the DEFAULT, so
    // a default initializer still sees the (now-declared) parameters.
    {
        // Sibling reference: `b = a` reads the parameter `a`.
        var r = try analyzeTsModuleSource("function g(a: number, b = a) { b; }");
        defer r.deinit(testing.allocator);
        const param_a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
        try testing.expect(r.symbols.getRefRange(param_a).len() >= 1);
    }
    {
        // Self reference: `x = x` reads the parameter `x` (TDZ at runtime, but it
        // resolves to the param, not an outer binding).
        var r = try analyzeTsModuleSource("let x = 0;\nfunction g(x = x) { return x; }");
        defer r.deinit(testing.allocator);
        const param_x = findSymbolByKind(&r, "x", .parameter) orelse return error.ParamNotFound;
        // 2 reads: the default `x` and the `return x`.
        try testing.expectEqual(@as(u32, 2), r.symbols.getRefRange(param_x).len());
    }
    {
        // The needle this fix threads: the SAME name `foo` appears in the annotation
        // (resolves to the import) AND the default (resolves to the param), proving
        // the declare sits exactly between them.
        var r = try analyzeTsModuleSource(
            \\import * as foo from 'foo';
            \\function g(foo: foo.Foo = foo.bar) {}
        );
        defer r.deinit(testing.allocator);
        const import_sym = findSymbolByKind(&r, "foo", .import_binding) orelse return error.ImportNotFound;
        const param_sym = findSymbolByKind(&r, "foo", .parameter) orelse return error.ParamNotFound;
        try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(import_sym).len()); // annotation `foo.Foo`
        try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(param_sym).len()); // default `foo.bar`
    }
}

test "arrow parameter default initializer resolves to a sibling parameter (#56)" {
    // A parameter default is evaluated in the parameter scope, so `b = a` reads the
    // parameter `a`. Arrow params are parsed via the cover grammar before the arrow
    // scope exists, so the default's reference is re-homed into the arrow scope.
    const cases = [_][]const u8{
        "const f = (a, b = a) => b;", // plain arrow
        "const f = (a: number, b = a) => b;", // typed (non-generic) arrow
        "const f = async (a, b = a) => b;", // async arrow
        "const f = <T>(a: T, b = a) => b;", // generic arrow
        "const f = ({a} = {}, b = a) => b;", // destructured sibling
    };
    for (cases) |src| {
        var r = try analyzeTsModuleSource(src);
        defer r.deinit(testing.allocator);
        const a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
        // Exactly one read — the `a` in `b = a` (not double-emitted by the re-home).
        try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(a).len());
    }
}

test "arrow default and body both reference the same parameter (#56)" {
    // The re-homed default ref is additive, not a replacement: `a` is read by both
    // the default `b = a` and the body `a + b`, on the single param symbol.
    var r = try analyzeTsModuleSource("const f = (a, b = a) => a + b;");
    defer r.deinit(testing.allocator);
    const a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 2), r.symbols.getRefRange(a).len());
}

test "a write inside an arrow default re-homes to the parameter and marks it written (#56)" {
    // The re-home must preserve the reference KIND: `(a = 1)` writes the parameter.
    var r = try analyzeTsModuleSource("const f = (a, b = (a = 1)) => b;");
    defer r.deinit(testing.allocator);
    const a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(a).len());
    try testing.expect(r.symbols.getFlags(a).is_written);
}

test "arrow parameter self-default resolves to the parameter, not an outer binding (#56)" {
    // `(x = x) => x`: BOTH the default `x` and the body `x` read the PARAMETER x
    // (TDZ at runtime), not the outer `let x`.
    var r = try analyzeTsModuleSource("let x = 0;\nconst f = (x = x) => x;");
    defer r.deinit(testing.allocator);
    const param_x = findSymbolByKind(&r, "x", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 2), r.symbols.getRefRange(param_x).len());
}

test "arrow annotation stays outer while the default is re-homed to the param (#56)" {
    // Combined guard with #53: in `(foo: foo.Foo = foo.bar) => {}` the SAME name
    // `foo` resolves to the import in the annotation `foo.Foo` but to the parameter
    // in the default `foo.bar`.
    var r = try analyzeTsModuleSource(
        \\import * as foo from 'foo';
        \\const f = (foo: foo.Foo = foo.bar) => {};
    );
    defer r.deinit(testing.allocator);
    const import_sym = findSymbolByKind(&r, "foo", .import_binding) orelse return error.ImportNotFound;
    const param_sym = findSymbolByKind(&r, "foo", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(import_sym).len()); // annotation foo.Foo
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(param_sym).len()); // default foo.bar
}

test "reference nested in an arrow default keeps resolving to the outer binding (#56)" {
    // Safety: a reference inside a default's OWN nested function/arrow belongs to
    // that inner scope and must NOT be re-homed — `c` inside `() => c` still
    // resolves to the outer `let c` (depth tracking skips nested scopes).
    var r = try analyzeTsModuleSource("let c = 0;\nconst f = (b = () => c) => b;");
    defer r.deinit(testing.allocator);
    // The nested `c` must NOT be re-homed: no phantom `c` parameter is created...
    try testing.expectEqual(@as(?SymbolId, null), findSymbolByKind(&r, "c", .parameter));
    // ...and it still resolves to the outer `let c`.
    const outer_c = findSymbolByKind(&r, "c", .let) orelse return error.OuterNotFound;
    try testing.expect(r.symbols.getRefRange(outer_c).len() >= 1);
}

/// Analyze `source` as a `js_ts` module (JS file with TypeScript annotations).
fn analyzeJsTsModuleSource(source: []const u8) !semantic.SemanticResult {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithLanguage(allocator, source, .js_ts);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .language = .js_ts, .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    return semantic.SemanticAnalyzer.analyzeModule(allocator, &tree, true);
}

test "typed-return concise arrow opens a scope and declares its parameters (#60)" {
    // `(params): T => body` (untyped params + explicit return type) must open an
    // arrow scope and declare its parameters — previously it declared none.
    var r = try analyzeTsModuleSource("const f = (a, b): number => a + b;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "a", .parameter, .arrow_function);
    try expectSymbol(&r, "b", .parameter, .arrow_function);
    // The body `a + b` resolves to the params (one read each).
    const a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
    const b = findSymbolByKind(&r, "b", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(a).len());
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(b).len());
}

test "typed-return concise arrow default resolves to the parameter (#60/#56)" {
    // The param scope + default re-homing both apply on this path too.
    var r = try analyzeTsModuleSource("const g = (a, b = a): string => b;");
    defer r.deinit(testing.allocator);
    const a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
    const b = findSymbolByKind(&r, "b", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(a).len()); // default `b = a`
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(b).len()); // body `b`
}

test "typed-return concise arrow declares params in js_ts mode too (#60)" {
    var r = try analyzeJsTsModuleSource("const f = (a, b): number => a + b;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "a", .parameter, .arrow_function);
    try expectSymbol(&r, "b", .parameter, .arrow_function);
    // The body parses inside the new scope in js_ts mode too.
    const a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(a).len());
}

test "typed-return concise arrow declares unused params independent of use (#60)" {
    // Declaration must happen even when the param is never referenced — guards
    // against a regression that only created the symbol lazily on a reference.
    var r = try analyzeTsModuleSource("const f = (a, b): number => 0;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "a", .parameter, .arrow_function);
    try expectSymbol(&r, "b", .parameter, .arrow_function);
    const a = findSymbolByKind(&r, "a", .parameter) orelse return error.ParamNotFound;
    try testing.expectEqual(@as(u32, 0), r.symbols.getRefRange(a).len());
}

test "typed-return concise arrow declares rest and destructured params (#60)" {
    {
        // Rest param.
        var r = try analyzeTsModuleSource("const f = (a, ...r): number => r.length;");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "a", .parameter, .arrow_function);
        const rest = findSymbolByKind(&r, "r", .parameter) orelse return error.ParamNotFound;
        try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(rest).len());
    }
    {
        // Destructured param.
        var r = try analyzeTsModuleSource("const f = ({x}): number => x;");
        defer r.deinit(testing.allocator);
        const x = findSymbolByKind(&r, "x", .parameter) orelse return error.ParamNotFound;
        try testing.expectEqual(ScopeKind.arrow_function, r.scopes.kind(r.symbols.getScope(x)));
        try testing.expectEqual(@as(u32, 1), r.symbols.getRefRange(x).len());
    }
}

test "typed-return concise arrow with a type-predicate return declares its param (#60)" {
    // `a is string` is a TYPE position; the param is still declared, no crash.
    var r = try analyzeTsModuleSource("const f = (a): a is string => true;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "a", .parameter, .arrow_function);
}

test "typed-return arrow in a conditional consequent still parses cleanly (#60)" {
    // Regression pin for the `cond ? (a): T => body : alt` ambiguity the fix gates
    // on (`!saved_cc`): this case intentionally keeps its prior no-scope behavior,
    // but must still analyze without diagnostics.
    var r = try analyzeTsModuleSource("const cc = c ? (a): number => a : 0;");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

/// Count scopes of a given kind in the tree.
fn countScopesOfKind(result: *const semantic.SemanticResult, want: ScopeKind) u32 {
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < result.scopes.len()) : (i += 1) {
        if (result.scopes.kind(ScopeId.fromInt(i)) == want) n += 1;
    }
    return n;
}

/// Assert a symbol named `name` exists, with the given binding kind, declared in
/// a scope of `scope_kind`.
fn expectSymbol(
    result: *const semantic.SemanticResult,
    name: []const u8,
    binding: BindingKind,
    scope_kind: ScopeKind,
) !void {
    const id = findSymbol(result, name) orelse {
        std.debug.print("expected symbol '{s}' not found\n", .{name});
        return error.SymbolNotFound;
    };
    try testing.expectEqual(binding, result.symbols.getBindingKind(id));
    const sid = result.symbols.getScope(id);
    try testing.expectEqual(scope_kind, result.scopes.kind(sid));
}

// ── Scope structure ─────────────────────────────────────────

test "empty program: single global scope, no symbols" {
    var r = try analyzeSource("");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.scopes.len());
    try testing.expectEqual(ScopeKind.global, r.scopes.kind(ScopeId.fromInt(0)));
    try testing.expectEqual(@as(u32, 0), r.symbols.count());
}

test "function declaration creates a function scope under global" {
    var r = try analyzeSource("function foo() {}");
    defer r.deinit(testing.allocator);
    // Exactly one function scope, parented to the global scope.
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .function));
    var fn_scope: ?ScopeId = null;
    var i: u32 = 0;
    while (i < r.scopes.len()) : (i += 1) {
        const id = ScopeId.fromInt(i);
        if (r.scopes.kind(id) == .function) fn_scope = id;
    }
    const fs = fn_scope.?;
    try testing.expectEqual(ScopeKind.global, r.scopes.kind(r.scopes.parent(fs)));
    // `foo` is a function_decl bound in the global scope, not the function scope.
    try expectSymbol(&r, "foo", .function_decl, .global);
}

test "block scope holds let, not the enclosing scope" {
    var r = try analyzeSource("{ let x = 1; }");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .block));
    try expectSymbol(&r, "x", .let, .block);
}

test "module source produces a module scope" {
    var r = try analyzeModuleSource("export const y = 1;");
    defer r.deinit(testing.allocator);
    // A module source has a module scope nested under the global wrapper scope.
    // (Top-level module bindings attach to the global wrapper, eslint-scope style,
    // so we assert the const binding exists rather than pinning its exact scope.)
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .module));
    const y = findSymbol(&r, "y") orelse return error.SymbolNotFound;
    try testing.expectEqual(BindingKind.@"const", r.symbols.getBindingKind(y));
}

// ── Binding kinds ───────────────────────────────────────────

test "var/let/const get distinct binding kinds" {
    var r = try analyzeSource("var a = 1; let b = 2; const c = 3;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "a", .@"var", .global);
    try expectSymbol(&r, "b", .let, .global);
    try expectSymbol(&r, "c", .@"const", .global);
}

test "class declaration binding kind" {
    var r = try analyzeSource("class C {}");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "C", .class_decl, .global);
}

test "namespace declaration emits namespace_decl symbol in enclosing scope (TS)" {
    {
        var r = try analyzeTsSource("namespace Foo {}");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "Foo", .namespace_decl, .global);
    }
    {
        var r = try analyzeTsSource("module Foo {}");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "Foo", .namespace_decl, .global);
    }
    // Dotted: only the root segment is declared; B and C are property names.
    {
        var r = try analyzeTsSource("namespace A.B.C {}");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "A", .namespace_decl, .global);
        try testing.expectEqual(@as(?SymbolId, null), findSymbol(&r, "B"));
        try testing.expectEqual(@as(?SymbolId, null), findSymbol(&r, "C"));
    }
    // String-literal ambient modules do NOT get a namespace_decl symbol.
    // tokenText includes the quote chars, so check both the bare name and the
    // quoted form to be sure nothing slipped through.
    {
        var r = try analyzeTsSource("declare module 'foo' {}");
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(?SymbolId, null), findSymbol(&r, "foo"));
        try testing.expectEqual(@as(?SymbolId, null), findSymbol(&r, "'foo'"));
    }
}

test "namespace body opens a ts_namespace scope, not a plain block (#52)" {
    // `namespace`, `module`, and ambient string `module "x"` bodies all open a
    // ts_namespace scope (a var-scope) rather than the plain `.block` that
    // parseBlockStatement would otherwise emit.
    const cases = [_][]const u8{
        "namespace N { }",
        "module N { }",
        "declare module 'foo' { }",
    };
    for (cases) |src| {
        var r = try analyzeTsSource(src);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .ts_namespace));
        try testing.expectEqual(@as(u32, 0), countScopesOfKind(&r, .block));
    }
}

test "ts_namespace scope is a var-scope flagged as a namespace body (#52)" {
    var r = try analyzeTsSource("namespace N { var x = 1; }");
    defer r.deinit(testing.allocator);
    // Locate the ts_namespace scope and assert its flags were wired up.
    var ns: ?ScopeId = null;
    var i: u32 = 0;
    while (i < r.scopes.len()) : (i += 1) {
        const id = ScopeId.fromInt(i);
        if (r.scopes.kind(id) == .ts_namespace) ns = id;
    }
    const nsid = ns orelse return error.NamespaceScopeNotFound;
    const flags = r.scopes.getFlags(nsid);
    try testing.expect(flags.is_var_scope);
    try testing.expect(flags.is_namespace_body);
}

test "var stops at the namespace boundary instead of hoisting out (#52)" {
    // TS compiles a namespace to an IIFE, so a `var` inside it is namespace-local
    // — it must NOT hoist to the enclosing global scope.
    {
        // var declared directly in the namespace body.
        var r = try analyzeTsSource("namespace N { var x = 1; }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "x", .@"var", .ts_namespace);
    }
    {
        // var declared in a nested block still hoists only as far as the namespace.
        var r = try analyzeTsSource("namespace N { { var y = 1; } }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "y", .@"var", .ts_namespace);
    }
}

test "forward var-ref inside a namespace resolves to the namespace-scoped var (#52)" {
    // A read that appears BEFORE the `var` declaration is left unresolved on the
    // main pass and patched up by the retry walk (which uses the precomputed
    // var_scope field). This exercises a different code path than the in-order
    // case and confirms both paths agree on the ts_namespace scope.
    var r = try analyzeTsSource("namespace N { x; var x = 1; }");
    defer r.deinit(testing.allocator);
    const x = findSymbol(&r, "x") orelse return error.SymbolNotFound;
    // The `var x` is namespace-scoped...
    try testing.expectEqual(ScopeKind.ts_namespace, r.scopes.kind(r.symbols.getScope(x)));
    // ...and the forward `x;` reference resolved to it.
    try testing.expect(r.symbols.getRefRange(x).len() >= 1);
}

test "module / ambient-module bodies also trap var (#52)" {
    // The `module N` keyword path and the ambient string `module "x"` path both go
    // through parseNamespaceOrModule, so their `var`s are namespace-scoped too.
    {
        var r = try analyzeTsSource("module N { var z = 1; }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "z", .@"var", .ts_namespace);
    }
    {
        var r = try analyzeTsSource("declare module 'foo' { var w = 1; }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "w", .@"var", .ts_namespace);
    }
}

test "let/const in a namespace bind to the ts_namespace scope (#52)" {
    // Guards against a regression that reverts the body to `.block` (where let/const
    // would still bind, but the scope kind would be wrong) or mis-hoists them.
    var r = try analyzeTsSource("namespace N { let q = 1; const c = 2; }");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "q", .let, .ts_namespace);
    try expectSymbol(&r, "c", .@"const", .ts_namespace);
}

test "top-level var is not trapped by the namespace change (#52)" {
    // Negative control: the new var-scope must not over-reach. A `var` at module
    // top level still belongs to the global scope.
    var r = try analyzeTsSource("var top = 1;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "top", .@"var", .global);
}

test "named class expression: name bound inside class scope" {
    var r = try analyzeSource("(class Foo {})");
    defer r.deinit(testing.allocator);
    // Foo is a class_expr_name declared in the class's own scope.
    try expectSymbol(&r, "Foo", .class_expr_name, .class);
}

test "named class expression: name has TDZ" {
    var r = try analyzeSource("(class Foo {})");
    defer r.deinit(testing.allocator);
    const sym = findSymbol(&r, "Foo") orelse return error.SymbolNotFound;
    try testing.expect(r.symbols.isInTDZ(sym));
}

test "named class expression: name not visible in outer scope" {
    // The class-expr name lives only in the class scope, not in the enclosing scope.
    // There is exactly one class scope and one global scope.
    var r = try analyzeSource("(class Bar {})");
    defer r.deinit(testing.allocator);
    const sym = findSymbol(&r, "Bar") orelse return error.SymbolNotFound;
    const sym_scope = r.symbols.getScope(sym);
    try testing.expectEqual(ScopeKind.class, r.scopes.kind(sym_scope));
    // The parent of the class scope is global — Bar must NOT be in global scope.
    const parent = r.scopes.parent(sym_scope);
    try testing.expectEqual(ScopeKind.global, r.scopes.kind(parent));
}

test "anonymous class expression: no name symbol emitted" {
    var r = try analyzeSource("(class {})");
    defer r.deinit(testing.allocator);
    // No class_expr_name symbol when the class expression is anonymous.
    try testing.expectEqual(@as(?SymbolId, null), findSymbol(&r, ""));
    try testing.expectEqual(@as(u32, 0), r.symbols.count());
}

test "named class expression: name is immutable (CreateImmutableBinding)" {
    // ES §15.7.2.7 step 7.b: class expression name uses CreateImmutableBinding.
    var r = try analyzeSource("(class Foo {})");
    defer r.deinit(testing.allocator);
    const sym = findSymbol(&r, "Foo") orelse return error.SymbolNotFound;
    try testing.expect(r.symbols.isImmutable(sym));
}

test "named class expression: self-reference in extends is in class scope" {
    // (class C extends C {}) — the inner C reference resolves to the class_expr_name
    // binding declared inside the class scope, not to any outer binding.
    var r = try analyzeSource("(class C extends C {})");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "C", .class_expr_name, .class);
}

test "type parameters are emitted as scope symbols (TS)" {
    // Class type parameter → bound in the class scope.
    {
        var r = try analyzeTsSource("class Foo<T> { m(x: T): T { return x; } }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "T", .type_param, .class);
    }
    // Generic function type → T shares the function type's scope with the params.
    {
        var r = try analyzeTsSource("type F = <T>(x: T) => T;");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "T", .type_param, .function);
    }
    // Interface call signature → bound in the enclosing (here global) scope.
    {
        var r = try analyzeTsSource("interface I { <T>(x: T): T; }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "T", .type_param, .global);
    }
    // Interface method signature → bound in the enclosing (here global) scope.
    {
        var r = try analyzeTsSource("interface I { m<T>(x: T): T; }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "T", .type_param, .global);
    }
    // Baseline: function declaration type parameter → function scope.
    {
        var r = try analyzeTsSource("function f<T>(x: T): T { return x; }");
        defer r.deinit(testing.allocator);
        try expectSymbol(&r, "T", .type_param, .function);
    }
}

test "function parameters are parameter bindings in the function scope" {
    var r = try analyzeSource("function f(p, q) { return p; }");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "p", .parameter, .function);
    try expectSymbol(&r, "q", .parameter, .function);
}

test "catch parameter is bound in the catch scope" {
    var r = try analyzeSource("try { } catch (e) { e; }");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), countScopesOfKind(&r, .catch_clause));
    try expectSymbol(&r, "e", .catch_param, .catch_clause);
}

// ── References ──────────────────────────────────────────────

test "reference resolves to its declaration" {
    var r = try analyzeSource("let x = 1; x; x;");
    defer r.deinit(testing.allocator);
    const x = findSymbol(&r, "x") orelse return error.SymbolNotFound;
    // Two read references to x (the declaration initializer is not a reference).
    const range = r.symbols.getRefRange(x);
    try testing.expect(range.len() >= 2);
    // Every reference in the range resolves to x.
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        try testing.expectEqual(x, r.references.getSymbol(ref_id));
    }
}

test "write reference is recorded for assignment" {
    var r = try analyzeSource("let x; x = 1;");
    defer r.deinit(testing.allocator);
    const x = findSymbol(&r, "x") orelse return error.SymbolNotFound;
    const range = r.symbols.getRefRange(x);
    var saw_write = false;
    for (r.ref_by_sym[range.start..range.end]) |ref_id| {
        if (r.references.getKind(ref_id).isWrite()) saw_write = true;
    }
    try testing.expect(saw_write);
}

// ── Scoping rules ───────────────────────────────────────────

test "var hoists to the function scope, not the inner block" {
    var r = try analyzeSource(
        \\function foo() {
        \\    { var x = 1; }
        \\    return x;
        \\}
    );
    defer r.deinit(testing.allocator);
    // `x` is a var; despite being written inside a block, it hoists to the
    // enclosing function scope.
    try expectSymbol(&r, "x", .@"var", .function);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "nested functions: inner symbol lives in inner scope" {
    var r = try analyzeSource(
        \\function outer() {
        \\    let a = 1;
        \\    function inner() { return a; }
        \\}
    );
    defer r.deinit(testing.allocator);
    // Two function scopes (outer, inner).
    try testing.expectEqual(@as(u32, 2), countScopesOfKind(&r, .function));
    // `a` is a let declared in the function body block — `let` binds to the
    // immediately enclosing block (the function body `{ ... }`), not the
    // function scope itself (only `var` and params hoist to the function scope).
    try expectSymbol(&r, "a", .let, .block);
    // `inner` is a function_decl declared inside outer's body block.
    try expectSymbol(&r, "inner", .function_decl, .block);
    // `outer` is a function_decl at the top level.
    try expectSymbol(&r, "outer", .function_decl, .global);
}

test "for-loop let is scoped to the loop block" {
    var r = try analyzeSource("for (let i = 0; i < 10; i++) { i; }");
    defer r.deinit(testing.allocator);
    const i_sym = findSymbol(&r, "i") orelse return error.SymbolNotFound;
    try testing.expectEqual(BindingKind.let, r.symbols.getBindingKind(i_sym));
    // The for-loop's `let` lives in a block scope, not the global scope.
    try testing.expect(r.scopes.kind(r.symbols.getScope(i_sym)) != .global);
}

// ── Fixtures: build without crashing and produce a non-trivial graph ──

test "analyze scoping fixture produces scopes and symbols" {
    const source = @embedFile("fixtures/semantic/scoping.js");
    var r = try analyzeSource(source);
    defer r.deinit(testing.allocator);
    try testing.expect(r.scopes.len() > 1);
    try testing.expect(r.symbols.count() > 0);
}

test "analyze hoisting fixture produces scopes and symbols" {
    const source = @embedFile("fixtures/semantic/hoisting.js");
    var r = try analyzeSource(source);
    defer r.deinit(testing.allocator);
    try testing.expect(r.scopes.len() > 1);
    try testing.expect(r.symbols.count() > 0);
}

test "analyze closures fixture produces scopes and symbols" {
    const source = @embedFile("fixtures/semantic/closures.js");
    var r = try analyzeSource(source);
    defer r.deinit(testing.allocator);
    try testing.expect(r.scopes.len() > 1);
    try testing.expect(r.symbols.count() > 0);
}

// ── Duplicate-binding early errors (opt-in diagnose_redeclare) ──────────────

/// Parse `source` (module or script) and return the number of redeclaration
/// diagnostics produced with `diagnose_redeclare` enabled.
fn redeclareDiagCount(source: []const u8, is_module: bool) !usize {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithOptions(allocator, source, .js, is_module);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .is_module = is_module, .emit_events = true });
    defer tree.deinit(allocator);
    // Skip cases the parser already rejects (e.g. `let x; let x;`): the early
    // error we test for is the semantic one, isolated from parser diagnostics.
    var r = try semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &tree, .{ .is_module = is_module, .diagnose_redeclare = true });
    defer r.deinit(allocator);
    return r.diagnostics.len;
}

/// Same as `redeclareDiagCount` but parses as TypeScript (module mode).
fn redeclareDiagCountTs(source: []const u8) !usize {
    const allocator = testing.allocator;
    var _lr = try Lexer.tokenizeWithLanguage(allocator, source, .ts);
    defer _lr.deinit(allocator);
    var tokens = _lr.tokens;
    var tree = try Parser.parseWithOptions(allocator, source, tokens.slice(), .{ .language = .ts, .is_module = true, .emit_events = true });
    defer tree.deinit(allocator);
    var r = try semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &tree, .{ .is_module = true, .diagnose_redeclare = true });
    defer r.deinit(allocator);
    return r.diagnostics.len;
}

test "redeclare: the duplicate-binding check is JavaScript-only" {
    // `diagnose_redeclare` models a JS early error. TypeScript has declaration
    // merging (function overloads, namespace/interface/class merges), so the JS
    // rule does not apply and is skipped for TS — no redeclaration diagnostics,
    // even for what looks like a duplicate in JS terms.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCountTs(
        "function f(x: number): void;\nfunction f(x: string): void;\nfunction f(x: any): void {}\nexport { f };\n",
    ));
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCountTs("class C {}\nclass C {}\nexport { C };\n"));
    // The JS path still flags genuine duplicate lexical bindings.
    try testing.expect(try redeclareDiagCount("class D {}\nclass D {}\n", false) >= 1);
}

test "redeclare: lexical duplicate bindings are flagged" {
    // class + class, class + var, class + let — all duplicate lexical bindings.
    try testing.expect(try redeclareDiagCount("class A {}\nclass A {}\n", false) >= 1);
    try testing.expect(try redeclareDiagCount("class C {}\nvar C;\n", false) >= 1);
    try testing.expect(try redeclareDiagCount("class C {}\nlet C = 1;\n", false) >= 1);
}

test "redeclare: top-level function duplicate is module-only" {
    // Two top-level functions: legal in a Script (var-like), an error in a Module.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("function x() {}\nfunction x() {}\n", false));
    try testing.expect(try redeclareDiagCount("function x() {}\nfunction x() {}\n", true) >= 1);
}

test "redeclare: legal redeclarations are not flagged" {
    // var + var, var + function, function + function (script) are all allowed.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("var a;\nvar a;\n", false));
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("var b;\nfunction b() {}\n", false));
    // Annex B: a sloppy function nested in `if` does not conflict with an outer let.
    try testing.expectEqual(@as(usize, 0), try redeclareDiagCount("let f = 1;\nif (false) function _f() {} else function f() {}\n", false));
}

test "regression: analyze does not index past the node array on error-recovered TSX" {
    // Malformed TSX that the parser error-recovers into a tree whose scope-event
    // stream references a node index one past the end of the node array (an event
    // for a node the recovery never created). event_resolver's declare/reference/
    // label handlers must skip such events rather than indexing ast.nodes out of
    // bounds (previously: a silent OOB read in ReleaseFast, a bounds panic in
    // ReleaseSafe — "index 7, len 7"). Reaching the end without a panic is the
    // assertion; the linter runs semantic analysis even when tree.errors.len > 0.
    const allocator = testing.allocator;
    const source = "(functi<{ () {\n    f'nction a() {\n        var b = 1;\n        return `;\n    }\n<())";
    var _lr = try Lexer.tokenizeWithLanguage(allocator, source, .tsx);
    defer _lr.deinit(allocator);
    var tree = try Parser.parseWithLanguage(allocator, source, _lr.tokens.slice(), .tsx, false);
    defer tree.deinit(allocator);
    var sem = try semantic.SemanticAnalyzer.analyzeWithOptions(allocator, &tree, .{
        .need_cfg = true,
        .build_ref_ranges = true,
        .build_parents = true,
        .diagnose_redeclare = true,
    });
    defer sem.deinit(allocator);
}

// ── Issue #30: interface/call-signature parameters bound as symbols ──────────

test "interface method signature params are declared as parameter symbols (#30)" {
    var r = try analyzeTsSource("const arg = 0; interface I { m(arg: string): void; }");
    defer r.deinit(testing.allocator);
    // There must be TWO symbols named `arg`: one `let`-like const and one parameter.
    var param_found = false;
    var i: u32 = 0;
    while (i < r.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, r.symbols.getName(id), "arg") and
            r.symbols.getBindingKind(id) == .parameter)
        {
            param_found = true;
            try testing.expectEqual(ScopeKind.function, r.scopes.kind(r.symbols.getScope(id)));
        }
    }
    try testing.expect(param_found);
}

test "interface call signature params are declared as parameter symbols (#30)" {
    var r = try analyzeTsSource("const x = 0; interface Fn { (x: string): void; }");
    defer r.deinit(testing.allocator);
    var param_found = false;
    var i: u32 = 0;
    while (i < r.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, r.symbols.getName(id), "x") and
            r.symbols.getBindingKind(id) == .parameter)
        {
            param_found = true;
            try testing.expectEqual(ScopeKind.function, r.scopes.kind(r.symbols.getScope(id)));
        }
    }
    try testing.expect(param_found);
}

test "interface construct signature params are declared as parameter symbols (#30)" {
    var r = try analyzeTsSource("const n = 0; interface Ctor { new(n: number): object; }");
    defer r.deinit(testing.allocator);
    var param_found = false;
    var i: u32 = 0;
    while (i < r.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, r.symbols.getName(id), "n") and
            r.symbols.getBindingKind(id) == .parameter)
        {
            param_found = true;
            try testing.expectEqual(ScopeKind.function, r.scopes.kind(r.symbols.getScope(id)));
        }
    }
    try testing.expect(param_found);
}

test "constructor type params are declared as parameter symbols (#30)" {
    var r = try analyzeTsSource("const arg = 0; type Bar = new (arg: number) => object;");
    defer r.deinit(testing.allocator);
    var param_found = false;
    var i: u32 = 0;
    while (i < r.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, r.symbols.getName(id), "arg") and
            r.symbols.getBindingKind(id) == .parameter)
        {
            param_found = true;
            try testing.expectEqual(ScopeKind.function, r.scopes.kind(r.symbols.getScope(id)));
        }
    }
    try testing.expect(param_found);
}

test "function type params already declared as parameter symbols — no regression (#30)" {
    // TSFunctionType was already wired; verify it still works after the changes.
    var r = try analyzeTsSource("type Fn = (arg: string) => void;");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "arg", .parameter, .function);
}

test "interface method signature rest param is declared as parameter symbol (#30)" {
    var r = try analyzeTsSource("interface I { m(...args: string[]): void; }");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "args", .parameter, .function);
}

test "multiple interface method params all declared (#30)" {
    var r = try analyzeTsSource("interface I { add(a: number, b: number): number; }");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "a", .parameter, .function);
    try expectSymbol(&r, "b", .parameter, .function);
}

test "this pseudo-parameter is NOT declared as a symbol (#30)" {
    // `this: void` is a type-only annotation, not a real parameter.
    var r = try analyzeTsSource("interface I { m(this: void, x: number): void; }");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?SymbolId, null), findSymbol(&r, "this"));
    try expectSymbol(&r, "x", .parameter, .function);
}

test "optional param in interface method is declared as symbol (#30)" {
    // `arg?:` — optional marker does not change the node tag.
    var r = try analyzeTsSource("interface I { m(arg?: string): void; }");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "arg", .parameter, .function);
}

test "generic method type-param lands in interface scope, value param in function scope (#30)" {
    // Type params are intentionally emitted into the enclosing interface scope
    // (for no-unnecessary-type-parameters); value params go in the function scope.
    var r = try analyzeTsSource("interface I { m<T>(arg: T): T; }");
    defer r.deinit(testing.allocator);
    try expectSymbol(&r, "arg", .parameter, .function);
    // T must exist as a type_param symbol (in the enclosing interface block scope).
    const t_sym = findSymbol(&r, "T") orelse return error.TypeParamNotFound;
    try testing.expectEqual(BindingKind.type_param, r.symbols.getBindingKind(t_sym));
}

test "overloaded interface method creates independent scopes per overload (#30)" {
    var r = try analyzeTsSource("interface I { m(a: number): void; m(a: string): void; }");
    defer r.deinit(testing.allocator);
    // Two parameter symbols named `a`, each in their own function scope.
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < r.symbols.count()) : (i += 1) {
        const id = SymbolId.fromInt(i);
        if (std.mem.eql(u8, r.symbols.getName(id), "a") and
            r.symbols.getBindingKind(id) == .parameter) count += 1;
    }
    try testing.expectEqual(@as(u32, 2), count);
}
