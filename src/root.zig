//! es-parser public API.
//!
//! ── Stable API ───────────────────────────────────────────────────────
//! The entry points and data types below are the supported surface:
//!   • Pipeline:  `Lexer.tokenize*` → `Parser.parse*` → `semantic.SemanticAnalyzer.analyze*`
//!   • Data:      `ast.Ast`, `diagnostic.Diagnostic`, `token.Language`,
//!                `scope`, `symbol`, `reference`
//! See README.md for usage.
//!
//! ── Advanced exports ─────────────────────────────────────────────────
//! The modules under "Advanced" expose semantic-analysis internals (CFG,
//! event stream, parent indices, memory layout). They are consumed by
//! downstream tooling built on this parser and are re-exported for that
//! reason, but they are lower-level and less stable than the API above —
//! prefer the `semantic` facade where it covers your need.

// ── Stable API ───────────────────────────────────────────────────────
pub const ast = @import("ast.zig");
pub const token = @import("token.zig");
pub const span = @import("span.zig");
pub const diagnostic = @import("diagnostic.zig");

pub const Lexer = @import("lexer.zig");
pub const Parser = @import("parser.zig").Parser;
pub const scope = @import("scope.zig");
pub const symbol = @import("symbol.zig");
pub const reference = @import("reference.zig");
pub const semantic = @import("semantic.zig");

// ── Advanced — lower-level internals, prefer `semantic` above ─────────
pub const debug = @import("debug.zig");
pub const code_path = @import("code_path.zig");
pub const layout = @import("layout.zig");
pub const parent_builder = @import("parent_builder.zig");
pub const scope_events = @import("scope_events.zig");
pub const event_resolver = @import("event_resolver.zig");
pub const scalar_lexer = @import("scalar_lexer.zig");

test {
    _ = @import("ast.zig");
    _ = @import("token.zig");
    _ = @import("span.zig");
    _ = @import("diagnostic.zig");
    _ = @import("debug.zig");
    _ = @import("parser.zig");
    _ = @import("scope.zig");
    _ = @import("symbol.zig");
    _ = @import("reference.zig");
    _ = @import("semantic.zig");
    _ = @import("layout.zig");
    _ = @import("lexer.zig");
    _ = @import("meta_compat.zig");
}
