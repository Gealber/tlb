//! TL (Type Language) codec — encode/decode ADNL/Liteserver protocol primitives.
const std = @import("std");

pub const tl_bool_true: u32 = 0x997275b5;
pub const tl_bool_false: u32 = 0xbc799737;

pub const ErrTl = error{
    NotEnoughData,
    InvalidBoolTag,
    TypeValueMismatch,
    SchemaLengthMismatch,
    OutOfMemory,
};

/// A TL primitive type descriptor.
pub const TlType = enum {
    int, // i32, 4 bytes little-endian
    long, // i64, 8 bytes little-endian
    int128, // 16 raw bytes
    int256, // 32 raw bytes
    bytes, // length-prefixed, 4-byte-aligned
    bool, // 4-byte CRC32 tag (boolTrue / boolFalse)
};

pub const TlValue = union(enum) {
    int: i32,
    long: i64,
    int128: [16]u8,
    int256: [32]u8,
    bytes: []const u8,
    bool: bool,
};

/// Decodes TL primitives from a byte slice, advancing the cursor on each call.
pub const TlReader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) TlReader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn decode(self: *TlReader, typ: TlType) ErrTl!TlValue {
        switch (typ) {
            .int => {
                if (self.pos + 4 > self.data.len) return error.NotEnoughData;
                const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
                self.pos += 4;
                return .{ .int = val };
            },
            .long => {
                if (self.pos + 8 > self.data.len) return error.NotEnoughData;
                const val = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
                self.pos += 8;
                return .{ .long = val };
            },
            .int128 => {
                if (self.pos + 16 > self.data.len) return error.NotEnoughData;
                var val: [16]u8 = undefined;
                @memcpy(&val, self.data[self.pos..][0..16]);
                self.pos += 16;
                return .{ .int128 = val };
            },
            .int256 => {
                if (self.pos + 32 > self.data.len) return error.NotEnoughData;
                var val: [32]u8 = undefined;
                @memcpy(&val, self.data[self.pos..][0..32]);
                self.pos += 32;
                return .{ .int256 = val };
            },
            .bytes => {
                if (self.pos >= self.data.len) return error.NotEnoughData;
                const first = self.data[self.pos];
                var byte_count: usize = undefined;
                var header_size: usize = undefined;
                if (first == 0xFE) {
                    if (self.pos + 4 > self.data.len) return error.NotEnoughData;
                    byte_count = std.mem.readInt(u24, self.data[self.pos + 1 ..][0..3], .little);
                    header_size = 4;
                } else {
                    byte_count = first;
                    header_size = 1;
                }
                const pad = (4 - (header_size + byte_count) % 4) % 4;
                const total = header_size + byte_count + pad;
                if (self.pos + total > self.data.len) return error.NotEnoughData;
                const slice = self.data[self.pos + header_size .. self.pos + header_size + byte_count];
                self.pos += total;
                return .{ .bytes = slice };
            },
            .bool => {
                if (self.pos + 4 > self.data.len) return error.NotEnoughData;
                const tag = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
                self.pos += 4;
                return switch (tag) {
                    tl_bool_true => .{ .bool = true },
                    tl_bool_false => .{ .bool = false },
                    else => error.InvalidBoolTag,
                };
            },
        }
    }
};

/// Encodes a TL primitive value, appending bytes to `list`.
pub fn encode(allocator: std.mem.Allocator, list: *std.ArrayList(u8), typ: TlType, val: TlValue) ErrTl!void {
    switch (typ) {
        .int => {
            const int_val = switch (val) {
                .int => |v| v,
                else => return error.TypeValueMismatch,
            };
            var buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &buf, int_val, .little);
            try list.appendSlice(allocator, &buf);
        },
        .long => {
            const long_val = switch (val) {
                .long => |v| v,
                else => return error.TypeValueMismatch,
            };
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, long_val, .little);
            try list.appendSlice(allocator, &buf);
        },
        .int128 => {
            const int128_val = switch (val) {
                .int128 => |v| v,
                else => return error.TypeValueMismatch,
            };
            try list.appendSlice(allocator, &int128_val);
        },
        .int256 => {
            const int256_val = switch (val) {
                .int256 => |v| v,
                else => return error.TypeValueMismatch,
            };
            try list.appendSlice(allocator, &int256_val);
        },
        .bytes => {
            const bytes_val = switch (val) {
                .bytes => |v| v,
                else => return error.TypeValueMismatch,
            };
            const byte_count = bytes_val.len;
            var header_size: usize = undefined;
            if (byte_count < 254) {
                try list.append(allocator, @intCast(byte_count));
                header_size = 1;
            } else {
                try list.append(allocator, 0xFE);
                var len_buf: [3]u8 = undefined;
                std.mem.writeInt(u24, &len_buf, @intCast(byte_count), .little);
                try list.appendSlice(allocator, &len_buf);
                header_size = 4;
            }
            try list.appendSlice(allocator, bytes_val);
            const pad = (4 - (header_size + byte_count) % 4) % 4;
            try list.appendNTimes(allocator, 0, pad);
        },
        .bool => {
            const bool_val = switch (val) {
                .bool => |v| v,
                else => return error.TypeValueMismatch,
            };
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, if (bool_val) tl_bool_true else tl_bool_false, .little);
            try list.appendSlice(allocator, &buf);
        },
    }
}

/// Encode a sequence of typed fields into `list`. `schema` and `values` must be the same length.
pub fn encodeSchema(allocator: std.mem.Allocator, list: *std.ArrayList(u8), schema: []const TlType, values: []const TlValue) ErrTl!void {
    if (schema.len != values.len) return error.SchemaLengthMismatch;
    for (schema, values) |typ, val| try encode(allocator, list, typ, val);
}

/// Decode a sequence of typed fields from `reader` into `out`. `schema` and `out` must be the same length.
pub fn decodeSchema(reader: *TlReader, schema: []const TlType, out: []TlValue) ErrTl!void {
    if (schema.len != out.len) return error.SchemaLengthMismatch;
    for (schema, out) |typ, *val| val.* = try reader.decode(typ);
}

// ── Allocator-free encode ──────────────────────────────────────────────────────

/// Returns the wire size in bytes for a TL primitive type known at comptime.
/// `.bytes` has no static size — calling this with it is a compile error.
pub fn typeSize(comptime typ: TlType) comptime_int {
    return switch (typ) {
        .int, .bool => 4,
        .long => 8,
        .int128 => 16,
        .int256 => 32,
        .bytes => @compileError("bytes has no static size; compute it from the value"),
    };
}

/// Returns the total wire size in bytes for a fixed schema known at comptime.
/// The schema must not contain `.bytes`.
pub fn schemaSize(comptime schema: []const TlType) comptime_int {
    var n: comptime_int = 0;
    for (schema) |t| n += typeSize(t);
    return n;
}

/// Encodes a single TL value into `out[pos..*]`, advancing `pos`.
/// Returns `error.NotEnoughData` if `out` is too small.
pub fn encodeToBuf(out: []u8, pos: *usize, typ: TlType, val: TlValue) ErrTl!void {
    switch (typ) {
        .int => {
            const v = switch (val) {
                .int => |v| v,
                else => return error.TypeValueMismatch,
            };
            if (pos.* + 4 > out.len) return error.NotEnoughData;
            std.mem.writeInt(i32, out[pos.*..][0..4], v, .little);
            pos.* += 4;
        },
        .long => {
            const v = switch (val) {
                .long => |v| v,
                else => return error.TypeValueMismatch,
            };
            if (pos.* + 8 > out.len) return error.NotEnoughData;
            std.mem.writeInt(i64, out[pos.*..][0..8], v, .little);
            pos.* += 8;
        },
        .int128 => {
            const v = switch (val) {
                .int128 => |v| v,
                else => return error.TypeValueMismatch,
            };
            if (pos.* + 16 > out.len) return error.NotEnoughData;
            @memcpy(out[pos.*..][0..16], &v);
            pos.* += 16;
        },
        .int256 => {
            const v = switch (val) {
                .int256 => |v| v,
                else => return error.TypeValueMismatch,
            };
            if (pos.* + 32 > out.len) return error.NotEnoughData;
            @memcpy(out[pos.*..][0..32], &v);
            pos.* += 32;
        },
        .bytes => {
            const v = switch (val) {
                .bytes => |v| v,
                else => return error.TypeValueMismatch,
            };
            const byte_count = v.len;
            const header_size: usize = if (byte_count < 254) 1 else 4;
            const pad = (4 - (header_size + byte_count) % 4) % 4;
            if (pos.* + header_size + byte_count + pad > out.len) return error.NotEnoughData;
            if (byte_count < 254) {
                out[pos.*] = @intCast(byte_count);
                pos.* += 1;
            } else {
                out[pos.*] = 0xFE;
                std.mem.writeInt(u24, out[pos.* + 1 ..][0..3], @intCast(byte_count), .little);
                pos.* += 4;
            }
            @memcpy(out[pos.*..][0..byte_count], v);
            pos.* += byte_count;
            @memset(out[pos.*..][0..pad], 0);
            pos.* += pad;
        },
        .bool => {
            const v = switch (val) {
                .bool => |v| v,
                else => return error.TypeValueMismatch,
            };
            if (pos.* + 4 > out.len) return error.NotEnoughData;
            std.mem.writeInt(u32, out[pos.*..][0..4], if (v) tl_bool_true else tl_bool_false, .little);
            pos.* += 4;
        },
    }
}

/// Encodes a sequence of TL fields into `out`. `schema` and `values` must be the same length.
pub fn encodeSchemaToBuf(out: []u8, schema: []const TlType, values: []const TlValue) ErrTl!void {
    if (schema.len != values.len) return error.SchemaLengthMismatch;
    var pos: usize = 0;
    for (schema, values) |typ, val| try encodeToBuf(out, &pos, typ, val);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "encode/decode int round-trip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .int, .{ .int = -42 });
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.int);
    try std.testing.expectEqual(@as(i32, -42), val.int);
}

test "encode/decode long round-trip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .long, .{ .long = 0x1234567890ABCDEF });
    try std.testing.expectEqual(@as(usize, 8), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.long);
    try std.testing.expectEqual(@as(i64, 0x1234567890ABCDEF), val.long);
}

test "encode/decode int128 round-trip" {
    const src = [_]u8{0xAB} ** 16;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .int128, .{ .int128 = src });
    try std.testing.expectEqual(@as(usize, 16), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.int128);
    try std.testing.expectEqualSlices(u8, &src, &val.int128);
}

test "encode/decode int256 round-trip" {
    var src: [32]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .int256, .{ .int256 = src });
    try std.testing.expectEqual(@as(usize, 32), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.int256);
    try std.testing.expectEqualSlices(u8, &src, &val.int256);
}

test "encode/decode bytes short round-trip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .bytes, .{ .bytes = "hello" });
    // 1 (len) + 5 (data) + 2 (pad) = 8
    try std.testing.expectEqual(@as(usize, 8), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.bytes);
    try std.testing.expectEqualSlices(u8, "hello", val.bytes);
}

test "encode/decode bytes empty round-trip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .bytes, .{ .bytes = "" });
    // 1 (len=0) + 3 (pad) = 4
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.bytes);
    try std.testing.expectEqualSlices(u8, "", val.bytes);
}

test "encode/decode bytes exactly 4-aligned round-trip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .bytes, .{ .bytes = "abc" });
    // 1 (len=3) + 3 (data) + 0 (pad) = 4
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.bytes);
    try std.testing.expectEqualSlices(u8, "abc", val.bytes);
}

test "encode/decode bytes long form round-trip" {
    const src = [_]u8{0xAB} ** 254;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .bytes, .{ .bytes = &src });
    // 4 (header) + 254 (data) + 2 (pad) = 260
    try std.testing.expectEqual(@as(usize, 260), list.items.len);
    var reader = TlReader.init(list.items);
    const val = try reader.decode(.bytes);
    try std.testing.expectEqualSlices(u8, &src, val.bytes);
}

test "encode/decode bool true and false" {
    for ([_]bool{ true, false }) |bool_val| {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(std.testing.allocator);
        try encode(std.testing.allocator, &list, .bool, .{ .bool = bool_val });
        try std.testing.expectEqual(@as(usize, 4), list.items.len);
        var reader = TlReader.init(list.items);
        const val = try reader.decode(.bool);
        try std.testing.expectEqual(bool_val, val.bool);
    }
}

test "decode bool InvalidBoolTag" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var reader = TlReader.init(&data);
    try std.testing.expectError(error.InvalidBoolTag, reader.decode(.bool));
}

test "encode TypeValueMismatch" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try std.testing.expectError(error.TypeValueMismatch, encode(std.testing.allocator, &list, .int, .{ .long = 1 }));
    try std.testing.expectError(error.TypeValueMismatch, encode(std.testing.allocator, &list, .long, .{ .int = 1 }));
    try std.testing.expectError(error.TypeValueMismatch, encode(std.testing.allocator, &list, .bool, .{ .int = 1 }));
    try std.testing.expectError(error.TypeValueMismatch, encode(std.testing.allocator, &list, .bytes, .{ .int = 1 }));
}

test "decode NotEnoughData" {
    const short = [_]u8{ 0x01, 0x02 };
    var reader = TlReader.init(&short);
    try std.testing.expectError(error.NotEnoughData, reader.decode(.int));

    var reader2 = TlReader.init(&short);
    try std.testing.expectError(error.NotEnoughData, reader2.decode(.long));
}

test "multiple fields in sequence" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &list, .int, .{ .int = 7 });
    try encode(std.testing.allocator, &list, .bool, .{ .bool = true });
    try encode(std.testing.allocator, &list, .bytes, .{ .bytes = "hi" });

    var reader = TlReader.init(list.items);
    try std.testing.expectEqual(@as(i32, 7), (try reader.decode(.int)).int);
    try std.testing.expectEqual(true, (try reader.decode(.bool)).bool);
    try std.testing.expectEqualSlices(u8, "hi", (try reader.decode(.bytes)).bytes);
}

// tonNode.blockIdExt workchain:int shard:long seqno:int root_hash:int256 file_hash:int256
const block_id_ext_schema = [_]TlType{ .int, .long, .int, .int256, .int256 };

test "encodeSchema/decodeSchema round-trip (blockIdExt-shaped)" {
    var root_hash: [32]u8 = undefined;
    var file_hash: [32]u8 = undefined;
    for (&root_hash, 0..) |*b, i| b.* = @intCast(i);
    for (&file_hash, 0..) |*b, i| b.* = @intCast(i + 32);

    const vals_in = [_]TlValue{
        .{ .int = -1 },
        .{ .long = @as(i64, @bitCast(@as(u64, 0x8000000000000000))) },
        .{ .int = 42 },
        .{ .int256 = root_hash },
        .{ .int256 = file_hash },
    };

    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encodeSchema(std.testing.allocator, &list, &block_id_ext_schema, &vals_in);
    // 4 + 8 + 4 + 32 + 32 = 80 bytes
    try std.testing.expectEqual(@as(usize, 80), list.items.len);

    var reader = TlReader.init(list.items);
    var vals_out: [5]TlValue = undefined;
    try decodeSchema(&reader, &block_id_ext_schema, &vals_out);

    try std.testing.expectEqual(@as(i32, -1), vals_out[0].int);
    try std.testing.expectEqual(@as(i64, @bitCast(@as(u64, 0x8000000000000000))), vals_out[1].long);
    try std.testing.expectEqual(@as(i32, 42), vals_out[2].int);
    try std.testing.expectEqualSlices(u8, &root_hash, &vals_out[3].int256);
    try std.testing.expectEqualSlices(u8, &file_hash, &vals_out[4].int256);
}

test "encodeSchema SchemaLengthMismatch" {
    const schema = [_]TlType{.int};
    const vals = [_]TlValue{ .{ .int = 1 }, .{ .int = 2 } };
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try std.testing.expectError(error.SchemaLengthMismatch, encodeSchema(std.testing.allocator, &list, &schema, &vals));
}

test "decodeSchema SchemaLengthMismatch" {
    const data = [_]u8{0} ** 8;
    var reader = TlReader.init(&data);
    const schema = [_]TlType{ .int, .int };
    var out: [1]TlValue = undefined;
    try std.testing.expectError(error.SchemaLengthMismatch, decodeSchema(&reader, &schema, &out));
}

// ── Allocator-free encode tests ────────────────────────────────────────────────

test "typeSize comptime values" {
    try std.testing.expectEqual(4, typeSize(.int));
    try std.testing.expectEqual(8, typeSize(.long));
    try std.testing.expectEqual(16, typeSize(.int128));
    try std.testing.expectEqual(32, typeSize(.int256));
    try std.testing.expectEqual(4, typeSize(.bool));
}

test "schemaSize comptime sum" {
    // adnl.id.short: tag (int) + id (int256) = 4 + 32 = 36
    const schema = [_]TlType{ .int, .int256 };
    try std.testing.expectEqual(36, schemaSize(&schema));
}

test "encodeToBuf/decode int round-trip" {
    var buf: [4]u8 = undefined;
    var pos: usize = 0;
    try encodeToBuf(&buf, &pos, .int, .{ .int = -99 });
    try std.testing.expectEqual(@as(usize, 4), pos);
    var reader = TlReader.init(&buf);
    try std.testing.expectEqual(@as(i32, -99), (try reader.decode(.int)).int);
}

test "encodeToBuf/decode long round-trip" {
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    try encodeToBuf(&buf, &pos, .long, .{ .long = 0x0EADBEEFDEADBEEF });
    try std.testing.expectEqual(@as(usize, 8), pos);
    var reader = TlReader.init(&buf);
    try std.testing.expectEqual(@as(i64, 0x0EADBEEFDEADBEEF), (try reader.decode(.long)).long);
}

test "encodeToBuf/decode int128 round-trip" {
    const src = [_]u8{0xCD} ** 16;
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    try encodeToBuf(&buf, &pos, .int128, .{ .int128 = src });
    try std.testing.expectEqual(@as(usize, 16), pos);
    var reader = TlReader.init(&buf);
    try std.testing.expectEqualSlices(u8, &src, &(try reader.decode(.int128)).int128);
}

test "encodeToBuf/decode int256 round-trip" {
    var src: [32]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var buf: [32]u8 = undefined;
    var pos: usize = 0;
    try encodeToBuf(&buf, &pos, .int256, .{ .int256 = src });
    try std.testing.expectEqual(@as(usize, 32), pos);
    var reader = TlReader.init(&buf);
    try std.testing.expectEqualSlices(u8, &src, &(try reader.decode(.int256)).int256);
}

test "encodeToBuf/decode bool round-trip" {
    for ([_]bool{ true, false }) |b| {
        var buf: [4]u8 = undefined;
        var pos: usize = 0;
        try encodeToBuf(&buf, &pos, .bool, .{ .bool = b });
        try std.testing.expectEqual(@as(usize, 4), pos);
        var reader = TlReader.init(&buf);
        try std.testing.expectEqual(b, (try reader.decode(.bool)).bool);
    }
}

test "encodeToBuf/decode bytes round-trip" {
    // 1 (len) + 5 (data) + 2 (pad) = 8
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    try encodeToBuf(&buf, &pos, .bytes, .{ .bytes = "hello" });
    try std.testing.expectEqual(@as(usize, 8), pos);
    var reader = TlReader.init(&buf);
    try std.testing.expectEqualSlices(u8, "hello", (try reader.decode(.bytes)).bytes);
}

test "encodeToBuf NotEnoughData" {
    var buf: [3]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expectError(error.NotEnoughData, encodeToBuf(&buf, &pos, .int, .{ .int = 1 }));
}

test "encodeToBuf TypeValueMismatch" {
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expectError(error.TypeValueMismatch, encodeToBuf(&buf, &pos, .int, .{ .long = 1 }));
    try std.testing.expectError(error.TypeValueMismatch, encodeToBuf(&buf, &pos, .bool, .{ .int = 1 }));
}

test "encodeSchemaToBuf/decodeSchema round-trip (adnl.id.short-shaped)" {
    var id: [32]u8 = undefined;
    for (&id, 0..) |*b, i| b.* = @intCast(i);

    const schema = [_]TlType{ .int, .int256 };
    var buf: [schemaSize(&schema)]u8 = undefined;
    try encodeSchemaToBuf(&buf, &schema, &.{
        .{ .int = @bitCast(@as(u32, 0x3e3f654f)) },
        .{ .int256 = id },
    });

    var reader = TlReader.init(&buf);
    var out: [2]TlValue = undefined;
    try decodeSchema(&reader, &schema, &out);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x3e3f654f))), out[0].int);
    try std.testing.expectEqualSlices(u8, &id, &out[1].int256);
}

test "encodeSchemaToBuf SchemaLengthMismatch" {
    var buf: [4]u8 = undefined;
    const schema = [_]TlType{.int};
    const vals = [_]TlValue{ .{ .int = 1 }, .{ .int = 2 } };
    try std.testing.expectError(error.SchemaLengthMismatch, encodeSchemaToBuf(&buf, &schema, &vals));
}
