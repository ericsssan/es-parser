const std = @import("std");
const Span = @import("span.zig").Span;
const Location = @import("span.zig").Location;

pub const Severity = enum {
    @"error",
    warning,
    info,
    hint,

    pub fn symbol(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .info => "info",
            .hint => "hint",
        };
    }
};

pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
    severity: Severity,

    /// Format as "file:line:col: severity: message"
    pub fn format(
        self: *const Diagnostic,
        line_starts: []const u32,
        source: []const u8,
        file_path: []const u8,
        writer: anytype,
    ) !void {
        const loc = Location.fromLineStarts(line_starts, source, self.span.start);
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
            file_path,
            loc.line + 1,
            loc.column + 1,
            self.severity.symbol(),
            self.message,
        });
    }

    /// Format the source context with caret pointer.
    pub fn formatContext(
        self: *const Diagnostic,
        line_starts: []const u32,
        source: []const u8,
        writer: anytype,
    ) !void {
        const loc = Location.fromLineStarts(line_starts, source, self.span.start);
        const line_text = source[loc.line_start..loc.line_end];

        // Print the source line
        try writer.print(" {s}\n", .{line_text});

        // Print the caret
        try writer.writeByteNTimes(' ', loc.column + 1);
        try writer.writeAll("^\n");
    }
};

/// Format diagnostics as JSON array.
pub fn formatJson(
    diagnostics: []const Diagnostic,
    line_starts: []const u32,
    source: []const u8,
    file_path: []const u8,
    writer: anytype,
) !void {
    try writer.writeAll("[");
    for (diagnostics, 0..) |diag, i| {
        if (i > 0) try writer.writeAll(",");
        const loc = Location.fromLineStarts(line_starts, source, diag.span.start);
        try writer.print(
            \\{{"severity":"{s}","message":"{s}","file":"{s}","line":{d},"column":{d},"offset":{d}}}
        , .{
            diag.severity.symbol(),
            diag.message,
            file_path,
            loc.line + 1,
            loc.column + 1,
            diag.span.start,
        });
    }
    try writer.writeAll("]\n");
}
