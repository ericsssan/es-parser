//! Parser module public API — re-exports all parser types.

pub const ast = @import("ast.zig");
pub const token = @import("token.zig");
pub const span = @import("span.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const debug = @import("debug.zig");

pub const Lexer = @import("lexer.zig");
pub const Parser = @import("parser.zig").Parser;
pub const scope = @import("scope.zig");
pub const symbol = @import("symbol.zig");
pub const reference = @import("reference.zig");
pub const semantic = @import("semantic.zig");

pub const layout = @import("layout.zig");
pub const parent_builder = @import("parent_builder.zig");
pub const scope_events = @import("scope_events.zig");
pub const event_resolver = @import("event_resolver.zig");

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
}
