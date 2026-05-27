//! TL-B primitive codecs — store/load typed values to/from CellBuilder/CellSlice.
const std = @import("std");
const cell_mod = @import("cell.zig");
const slice_mod = @import("slice.zig");

pub const Cell = cell_mod.Cell;
const cell_size_bytes_max = cell_mod.cell_size_bytes_max;
pub const CellSlice = slice_mod.CellSlice;
pub const CellBuilder = slice_mod.CellBuilder;
const ErrSlice = slice_mod.ErrSlice;

pub const ErrTlb = ErrSlice || error{
    TypeValueMismatch,
    InvalidBitWidth,
    SchemaLengthMismatch,
};

/// A TL-B primitive type descriptor.
pub const TlbType = union(enum) {
    /// Unsigned integer of bit width n (1..64).
    uint: u7,
    /// Signed integer of bit width n (1..64).
    int: u7,
    /// Raw bit string of length n (1..1023).
    bits: u10,
    /// Single-bit boolean: true=1, false=0.
    bool,
    /// One cell reference (^T).
    ref,
};

pub const BitsVal = struct {
    data: [cell_size_bytes_max]u8,
    bit_count: u10,
};

pub const TlbValue = union(enum) {
    uint: u64,
    int: i64,
    bits: BitsVal,
    bool: bool,
    ref: *Cell,
};

pub fn store(builder: *CellBuilder, typ: TlbType, val: TlbValue) ErrTlb!void {
    switch (typ) {
        .uint => |bit_count| {
            if (bit_count == 0 or bit_count > 64) return ErrTlb.InvalidBitWidth;
            const uint_val = switch (val) {
                .uint => |u| u,
                else => return ErrTlb.TypeValueMismatch,
            };
            try builder.storeUint(uint_val, bit_count);
        },
        .int => |bit_count| {
            if (bit_count == 0 or bit_count > 64) return ErrTlb.InvalidBitWidth;
            const int_val = switch (val) {
                .int => |i| i,
                else => return ErrTlb.TypeValueMismatch,
            };
            try builder.storeInt(int_val, bit_count);
        },
        .bits => |bit_count| {
            if (bit_count == 0) return ErrTlb.InvalidBitWidth;
            const bits_val = switch (val) {
                .bits => |b| b,
                else => return ErrTlb.TypeValueMismatch,
            };
            if (bits_val.bit_count != bit_count) return ErrTlb.TypeValueMismatch;
            try builder.storeBits(&bits_val.data, bit_count);
        },
        .bool => {
            const bool_val = switch (val) {
                .bool => |b| b,
                else => return ErrTlb.TypeValueMismatch,
            };
            try builder.storeBit(@intFromBool(bool_val));
        },
        .ref => {
            const ref_val = switch (val) {
                .ref => |r| r,
                else => return ErrTlb.TypeValueMismatch,
            };
            try builder.storeRef(ref_val);
        },
    }
}

pub fn load(slice: *CellSlice, typ: TlbType) ErrTlb!TlbValue {
    switch (typ) {
        .uint => |bit_count| {
            if (bit_count == 0 or bit_count > 64) return ErrTlb.InvalidBitWidth;
            return .{ .uint = try slice.loadUint(bit_count) };
        },
        .int => |bit_count| {
            if (bit_count == 0 or bit_count > 64) return ErrTlb.InvalidBitWidth;
            return .{ .int = try slice.loadInt(bit_count) };
        },
        .bits => |bit_count| {
            if (bit_count == 0) return ErrTlb.InvalidBitWidth;
            var bits_val = BitsVal{ .data = [_]u8{0} ** cell_size_bytes_max, .bit_count = bit_count };
            try slice.loadBits(&bits_val.data, bit_count);
            return .{ .bits = bits_val };
        },
        .bool => {
            return .{ .bool = try slice.loadBit() == 1 };
        },
        .ref => {
            return .{ .ref = try slice.loadRef() };
        },
    }
}

/// Encode a sequence of typed fields into `builder`. `schema` and `values` must be the same length.
pub fn storeSchema(builder: *CellBuilder, schema: []const TlbType, values: []const TlbValue) ErrTlb!void {
    if (schema.len != values.len) return ErrTlb.SchemaLengthMismatch;
    for (schema, values) |typ, val| try store(builder, typ, val);
}

/// Decode a sequence of typed fields from `slice` into `out`. `schema` and `out` must be the same length.
pub fn loadSchema(slice: *CellSlice, schema: []const TlbType, out: []TlbValue) ErrTlb!void {
    if (schema.len != out.len) return ErrTlb.SchemaLengthMismatch;
    for (schema, out) |typ, *val| val.* = try load(slice, typ);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

fn makeCell(data: []u8, bit_len: usize) cell_mod.Cell {
    return cell_mod.Cell.init(.Ordinary, data, bit_len, .{ null, null, null, null });
}

test "store/load uint round-trip" {
    var builder = CellBuilder.init();
    try store(&builder, .{ .uint = 8 }, .{ .uint = 0xA5 });

    var data: [cell_size_bytes_max]u8 = undefined;
    @memcpy(data[0..1], builder.data[0..1]);
    var cell = makeCell(&data, 8);
    var cs = CellSlice.init(&cell);

    const val = try load(&cs, .{ .uint = 8 });
    try std.testing.expectEqual(@as(u64, 0xA5), val.uint);
}

test "store/load int positive round-trip" {
    var builder = CellBuilder.init();
    try store(&builder, .{ .int = 8 }, .{ .int = 42 });

    var data: [cell_size_bytes_max]u8 = undefined;
    @memcpy(data[0..1], builder.data[0..1]);
    var cell = makeCell(&data, 8);
    var cs = CellSlice.init(&cell);

    const val = try load(&cs, .{ .int = 8 });
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

test "store/load int negative round-trip" {
    var builder = CellBuilder.init();
    try store(&builder, .{ .int = 8 }, .{ .int = -1 });

    var data: [cell_size_bytes_max]u8 = undefined;
    @memcpy(data[0..1], builder.data[0..1]);
    var cell = makeCell(&data, 8);
    var cs = CellSlice.init(&cell);

    const val = try load(&cs, .{ .int = 8 });
    try std.testing.expectEqual(@as(i64, -1), val.int);
}

test "store/load bool true and false" {
    for ([_]bool{ true, false }) |bool_val| {
        var builder = CellBuilder.init();
        try store(&builder, .bool, .{ .bool = bool_val });

        var data: [cell_size_bytes_max]u8 = undefined;
        @memcpy(data[0..1], builder.data[0..1]);
        var cell = makeCell(&data, 1);
        var cs = CellSlice.init(&cell);

        const val = try load(&cs, .bool);
        try std.testing.expectEqual(bool_val, val.bool);
    }
}

test "store/load bits round-trip" {
    const src = [_]u8{ 0xDE, 0xAD };
    var bits_val = BitsVal{ .data = [_]u8{0} ** cell_size_bytes_max, .bit_count = 16 };
    @memcpy(bits_val.data[0..2], &src);

    var builder = CellBuilder.init();
    try store(&builder, .{ .bits = 16 }, .{ .bits = bits_val });

    var data: [cell_size_bytes_max]u8 = undefined;
    @memcpy(data[0..2], builder.data[0..2]);
    var cell = makeCell(&data, 16);
    var cs = CellSlice.init(&cell);

    const val = try load(&cs, .{ .bits = 16 });
    try std.testing.expectEqual(@as(u10, 16), val.bits.bit_count);
    try std.testing.expectEqual(@as(u8, 0xDE), val.bits.data[0]);
    try std.testing.expectEqual(@as(u8, 0xAD), val.bits.data[1]);
}

test "store/load ref round-trip" {
    var child = cell_mod.Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var builder = CellBuilder.init();
    try store(&builder, .ref, .{ .ref = &child });

    var data: [cell_size_bytes_max]u8 = undefined;
    var cell = cell_mod.Cell.init(.Ordinary, &data, 0, builder.refs);
    var cs = CellSlice.init(&cell);

    const val = try load(&cs, .ref);
    try std.testing.expectEqual(&child, val.ref);
}

test "store returns TypeValueMismatch on tag mismatch" {
    var builder = CellBuilder.init();
    try std.testing.expectError(ErrTlb.TypeValueMismatch, store(&builder, .{ .uint = 8 }, .{ .int = 1 }));
    try std.testing.expectError(ErrTlb.TypeValueMismatch, store(&builder, .{ .int = 8 }, .{ .uint = 1 }));
    try std.testing.expectError(ErrTlb.TypeValueMismatch, store(&builder, .bool, .{ .uint = 1 }));
    try std.testing.expectError(ErrTlb.TypeValueMismatch, store(&builder, .ref, .{ .uint = 1 }));
}

test "store/load uint InvalidBitWidth on n=0 and n=65" {
    var builder = CellBuilder.init();
    try std.testing.expectError(ErrTlb.InvalidBitWidth, store(&builder, .{ .uint = 0 }, .{ .uint = 0 }));
    try std.testing.expectError(ErrTlb.InvalidBitWidth, store(&builder, .{ .uint = 65 }, .{ .uint = 0 }));

    var data: [cell_size_bytes_max]u8 = [_]u8{0} ** cell_size_bytes_max;
    var cell = makeCell(&data, 64);
    var cs = CellSlice.init(&cell);
    try std.testing.expectError(ErrTlb.InvalidBitWidth, load(&cs, .{ .uint = 0 }));
    try std.testing.expectError(ErrTlb.InvalidBitWidth, load(&cs, .{ .uint = 65 }));
}

test "store/load bits InvalidBitWidth on n=0" {
    var builder = CellBuilder.init();
    const bits_val = BitsVal{ .data = [_]u8{0} ** cell_size_bytes_max, .bit_count = 0 };
    try std.testing.expectError(ErrTlb.InvalidBitWidth, store(&builder, .{ .bits = 0 }, .{ .bits = bits_val }));

    var data: [cell_size_bytes_max]u8 = [_]u8{0} ** cell_size_bytes_max;
    var cell = makeCell(&data, 8);
    var cs = CellSlice.init(&cell);
    try std.testing.expectError(ErrTlb.InvalidBitWidth, load(&cs, .{ .bits = 0 }));
}

test "store bits TypeValueMismatch when bits_val.bit_count != typ bit_count" {
    const bits_val = BitsVal{ .data = [_]u8{0} ** cell_size_bytes_max, .bit_count = 8 };
    var builder = CellBuilder.init();
    try std.testing.expectError(ErrTlb.TypeValueMismatch, store(&builder, .{ .bits = 16 }, .{ .bits = bits_val }));
}

test "load uint NotEnoughBits when cell is too small" {
    var data = [_]u8{0xFF};
    var cell = makeCell(&data, 4);
    var cs = CellSlice.init(&cell);
    try std.testing.expectError(ErrTlb.NotEnoughBits, load(&cs, .{ .uint = 8 }));
}

test "store uint CellFull when builder is full" {
    var builder = CellBuilder.init();
    // fill to 1023 bits
    for (0..127) |_| try builder.storeUint(0, 8);
    try builder.storeUint(0, 7);
    try std.testing.expectError(ErrTlb.CellFull, store(&builder, .{ .uint = 8 }, .{ .uint = 0 }));
}

test "multiple primitives in sequence" {
    var builder = CellBuilder.init();
    try store(&builder, .{ .uint = 4 }, .{ .uint = 0xA });
    try store(&builder, .bool, .{ .bool = true });
    try store(&builder, .{ .int = 4 }, .{ .int = -2 });

    var data: [cell_size_bytes_max]u8 = undefined;
    @memcpy(data[0..2], builder.data[0..2]);
    var cell = makeCell(&data, 9);
    var cs = CellSlice.init(&cell);

    try std.testing.expectEqual(@as(u64, 0xA), (try load(&cs, .{ .uint = 4 })).uint);
    try std.testing.expectEqual(true, (try load(&cs, .bool)).bool);
    try std.testing.expectEqual(@as(i64, -2), (try load(&cs, .{ .int = 4 })).int);
}

test "storeSchema/loadSchema round-trip" {
    const schema = [_]TlbType{ .{ .uint = 8 }, .bool, .{ .int = 4 } };
    const vals_in = [_]TlbValue{ .{ .uint = 0xFF }, .{ .bool = false }, .{ .int = -3 } };

    var builder = CellBuilder.init();
    try storeSchema(&builder, &schema, &vals_in);

    var data: [cell_size_bytes_max]u8 = undefined;
    @memcpy(data[0..2], builder.data[0..2]);
    var cell = makeCell(&data, 13);
    var cs = CellSlice.init(&cell);

    var vals_out: [3]TlbValue = undefined;
    try loadSchema(&cs, &schema, &vals_out);

    try std.testing.expectEqual(@as(u64, 0xFF), vals_out[0].uint);
    try std.testing.expectEqual(false, vals_out[1].bool);
    try std.testing.expectEqual(@as(i64, -3), vals_out[2].int);
}

test "storeSchema SchemaLengthMismatch" {
    const schema = [_]TlbType{.{ .uint = 8 }};
    const vals = [_]TlbValue{ .{ .uint = 1 }, .{ .uint = 2 } };
    var builder = CellBuilder.init();
    try std.testing.expectError(ErrTlb.SchemaLengthMismatch, storeSchema(&builder, &schema, &vals));
}

test "loadSchema SchemaLengthMismatch" {
    var data = [_]u8{0xFF};
    var cell = makeCell(&data, 8);
    var cs = CellSlice.init(&cell);
    const schema = [_]TlbType{ .{ .uint = 4 }, .{ .uint = 4 } };
    var out: [1]TlbValue = undefined;
    try std.testing.expectError(ErrTlb.SchemaLengthMismatch, loadSchema(&cs, &schema, &out));
}
