//! Reflection helpers that work across the Zig `@typeInfo` API change.
//!
//! Up to ~dev.305 `@typeInfo(T).@"struct"`/`.@"enum"` exposed a single `fields`
//! array (`StructField`/`EnumField` with `.name`/`.type`/`.value`). After that
//! the shape split into parallel `field_names` / `field_types` / `field_values`
//! slices and `fields` became `@compileError`. These helpers detect which shape
//! is present with `@hasField` (comptime-known, so the unused branch is never
//! analyzed) and present one stable interface to the rest of the codebase.

const std = @import("std");

/// Number of declared fields in a struct or enum.
pub fn fieldCount(comptime T: type) comptime_int {
    switch (@typeInfo(T)) {
        .@"struct" => |s| return if (@hasField(@TypeOf(s), "field_names")) s.field_names.len else s.fields.len,
        .@"enum" => |e| return if (@hasField(@TypeOf(e), "field_names")) e.field_names.len else e.fields.len,
        else => @compileError("fieldCount: expected a struct or enum, got " ++ @typeName(T)),
    }
}

/// Name of the `i`-th field of a struct (use with `@FieldType(T, name)` for the
/// field type — `@FieldType` is stable across both API shapes).
pub fn structFieldName(comptime T: type, comptime i: usize) [:0]const u8 {
    const s = @typeInfo(T).@"struct";
    return if (@hasField(@TypeOf(s), "field_names")) s.field_names[i] else s.fields[i].name;
}

/// The `i`-th enum value (in declaration order).
pub fn enumValue(comptime E: type, comptime i: usize) E {
    const e = @typeInfo(E).@"enum";
    const v = if (@hasField(@TypeOf(e), "field_names")) e.field_values[i] else e.fields[i].value;
    return @enumFromInt(v);
}

test "fieldCount / structFieldName / enumValue" {
    const E = enum { a, b, c };
    const S = struct { x: u32, y: E, z: u32 };

    try std.testing.expectEqual(@as(comptime_int, 3), fieldCount(E));
    try std.testing.expectEqual(@as(comptime_int, 3), fieldCount(S));

    comptime var sum: usize = 0;
    inline for (0..fieldCount(S)) |i| {
        const name = comptime structFieldName(S, i);
        sum += @sizeOf(@FieldType(S, name));
    }
    try std.testing.expect(sum > 0);

    try std.testing.expectEqual(E.a, enumValue(E, 0));
    try std.testing.expectEqual(E.c, enumValue(E, 2));
}
