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

/// Byte offset of each line start: index 0 is 0, then the offset just past every
/// line terminator (`\n`, lone `\r`, `\r\n` coalesced as one, U+2028/U+2029).
/// Counts every terminator in the source — including those inside block comments,
/// strings, and templates — so it matches `Location.fromLineStarts` semantics.
/// Built on demand by the diagnostic/location layer (the lexer no longer
/// produces it); a clean file that reports no diagnostics never pays for it.
pub fn computeLineStarts(alloc: std.mem.Allocator, src: []const u8) ![]u32 {
    var ls: std.ArrayListUnmanaged(u32) = .empty;
    errdefer ls.deinit(alloc);
    const n: u32 = @intCast(src.len);
    try ls.ensureTotalCapacity(alloc, n / 24 + 8);
    ls.appendAssumeCapacity(0);
    const V = @Vector(16, u8);
    var i: u32 = 0;
    while (i < n) {
        // SIMD-skip 16-byte runs containing no line-terminator candidate
        // (`\n`, `\r`, or a `0xE2` lead). The common case — long terminator-free
        // spans — advances 16 bytes per branch; terminator-bearing windows fall
        // to the scalar handling below (which owns the \r\n / LS-PS semantics).
        if (i + 16 <= n) {
            const chunk: V = src[i..][0..16].*;
            const hits: u16 = @bitCast((chunk == @as(V, @splat(@as(u8, '\n')))) |
                (chunk == @as(V, @splat(@as(u8, '\r')))) |
                (chunk == @as(V, @splat(@as(u8, 0xE2)))));
            if (hits == 0) {
                i += 16;
                continue;
            }
            i += @ctz(hits); // jump straight to the first candidate
        }
        const c = src[i];
        if (c == '\n') {
            try ls.append(alloc, i + 1);
            i += 1;
        } else if (c == '\r') {
            if (i + 1 < n and src[i + 1] == '\n') {
                try ls.append(alloc, i + 2);
                i += 2;
            } else {
                try ls.append(alloc, i + 1);
                i += 1;
            }
        } else if (c == 0xE2 and i + 2 < n and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) {
            try ls.append(alloc, i + 3);
            i += 3;
        } else {
            // 0xE2 that isn't LS/PS, or a candidate at the tail — just advance.
            i += 1;
        }
    }
    return ls.toOwnedSlice(alloc);
}

/// Lazily-built line index over a source buffer. The `line_starts` table is
/// computed once on first use (`ensure`/`locate`) and cached, so callers that
/// never format a diagnostic — the common clean-file case — never build it.
/// Holds its allocator so location lookups need no extra arguments.
pub const LineIndex = struct {
    source: []const u8,
    alloc: std.mem.Allocator,
    starts: ?[]u32 = null,

    pub fn init(alloc: std.mem.Allocator, source: []const u8) LineIndex {
        return .{ .source = source, .alloc = alloc };
    }

    /// The line-start table, built and cached on first call. Returns null only
    /// if the one-time allocation fails (callers fall back to `Location.fromOffset`).
    pub fn ensure(self: *LineIndex) ?[]const u32 {
        if (self.starts == null) {
            self.starts = computeLineStarts(self.alloc, self.source) catch null;
        }
        return self.starts;
    }

    /// Map a byte offset to a `Location`, building the table on first use.
    pub fn locate(self: *LineIndex, offset: u32) Location {
        if (self.ensure()) |ls| return Location.fromLineStarts(ls, self.source, offset);
        return Location.fromOffset(self.source, offset);
    }

    pub fn deinit(self: *LineIndex) void {
        if (self.starts) |s| if (s.len > 0) self.alloc.free(s);
        self.starts = null;
    }
};

/// A byte offset into source text.
pub const ByteOffset = u32;

test "LineIndex.locate maps offsets to line/col, counting all terminators" {
    const testing = std.testing;
    // `\r\n` (one line), a newline inside a template, and a trailing line.
    const src = "let a = 1;\nlet b = 2;\r\nconst c = `multi\nline`;\nx";
    var li = LineIndex.init(testing.allocator, src);
    defer li.deinit();

    try testing.expectEqual(@as(u32, 0), li.locate(0).line);
    try testing.expectEqual(@as(u32, 4), li.locate(4).column);
    try testing.expectEqual(@as(u32, 1), li.locate(11).line);
    try testing.expectEqual(@as(u32, 2), li.locate(23).line);
    // The `\n` inside the template counts, so the final `x` is on line 4.
    try testing.expectEqual(@as(u32, 4), li.locate(@intCast(src.len - 1)).line);

    // The table is built once and cached across calls.
    try testing.expect(li.starts != null);
    const first = li.ensure().?.ptr;
    try testing.expectEqual(first, li.ensure().?.ptr);
}

test "computeLineStarts coalesces \\r\\n and records LS/PS" {
    const testing = std.testing;
    const ls = try computeLineStarts(testing.allocator, "a\r\nb\nc\u{2028}d");
    defer testing.allocator.free(ls);
    // byte 0='a', \r\n=1,2, 'b'=3, \n=4, 'c'=5, LS(U+2028)=6,7,8, 'd'=9.
    // line starts: 0, past \r\n (3), past \n (5), past LS (9).
    try testing.expectEqualSlices(u32, &.{ 0, 3, 5, 9 }, ls);
}
