const Span = @import("span.zig").Span;

pub const Severity = enum {
    @"error",
    warning,
    info,
    hint,
};

pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
    severity: Severity,
};
