const std = @import("std");

/// A byte range in the source text.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn text(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    pub const EMPTY: Span = .{ .start = 0, .end = 0 };
};

/// A source location with line and column information.
pub const Location = struct {
    line: u32,
    column: u32,
    line_start: u32,
    line_end: u32,

    /// O(log n) location lookup using the lexer's precomputed line-start table.
    /// line_starts[i] is the byte offset of the first character on line i.
    /// line_starts must be non-empty; line_starts[0] must be 0.
    /// Prefer this over fromOffset whenever line_starts is available.
    pub fn fromLineStarts(line_starts: []const u32, source: []const u8, offset: u32) Location {
        // Binary search: find the last index where line_starts[i] <= offset.
        // Invariant: line_starts[lo] <= offset (holds at lo=0 since line_starts[0]=0).
        var lo: usize = 0;
        var hi: usize = line_starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (line_starts[mid] <= offset) lo = mid else hi = mid;
        }
        const line_start = line_starts[lo];
        var line_end: u32 = offset;
        while (line_end < source.len and source[line_end] != '\n') line_end += 1;
        return .{
            .line = @intCast(lo),
            .column = offset - line_start,
            .line_start = line_start,
            .line_end = line_end,
        };
    }

    /// O(n) fallback — scans source byte-by-byte. Use only when line_starts
    /// is not available (e.g. standalone Span formatting without a lexer result).
    pub fn fromOffset(source: []const u8, offset: u32) Location {
        var line: u32 = 0;
        var line_start: u32 = 0;
        var i: u32 = 0;
        while (i < offset and i < source.len) : (i += 1) {
            if (source[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        var line_end: u32 = offset;
        while (line_end < source.len and source[line_end] != '\n') line_end += 1;
        return .{ .line = line, .column = offset - line_start, .line_start = line_start, .line_end = line_end };
    }

    /// Compute a Location from a Span (uses the start offset).
    pub fn fromSpan(source: []const u8, span: Span) Location {
        return fromOffset(source, span.start);
    }
};

/// A byte offset into source text.
pub const ByteOffset = u32;
