//! Bit-level I/O for TVM cells — CellSlice (read) and CellBuilder (write).
//!
//! Bits are stored MSB-first: bit 0 of a cell is the most-significant bit of
//! the first data byte (byte 0, bit 7 in hardware terms).
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cell_mod = @import("cell.zig");
pub const Cell = cell_mod.Cell;
const cell_size_bits_max = cell_mod.cell_size_bits_max;
const cell_size_bytes_max = cell_mod.cell_size_bytes_max;

pub const ErrSlice = error{
    NotEnoughBits,
    NotEnoughRefs,
    CellFull,
    TooManyRefs,
};

// Read n bits (n in 1..64) starting at bit_offset in data (MSB-first).
// Caller must ensure bit_offset + n <= data.len * 8.
fn readUintAt(data: []const u8, bit_offset: usize, n: u7) u64 {
    var result: u64 = 0;
    var remaining: usize = n;
    var off: usize = bit_offset;

    while (remaining > 0) {
        const bit_in_byte = off % 8;
        const avail = 8 - bit_in_byte; // bits left in the current byte (1..8)
        const take = @min(avail, remaining); // bits to consume this iteration (1..8)
        const byte = data[off / 8];
        const shift: u3 = @intCast(avail - take); // right-shift to right-align chosen bits
        const mask: u8 = @intCast((@as(usize, 1) << @intCast(take)) - 1);

        result = (result << @as(u6, @intCast(take))) | ((byte >> shift) & mask);
        off += take;
        remaining -= take;
    }

    return result;
}

// Write n bits (n in 1..64) from val (MSB-first) into data starting at bit_offset.
// Caller must ensure bit_offset + n <= data.len * 8 and data is zeroed in that range.
fn writeUintAt(data: []u8, bit_offset: usize, val: u64, n: u7) void {
    var remaining: usize = n;
    var off: usize = bit_offset;
    while (remaining > 0) {
        const bit_in_byte = off % 8;
        const avail = 8 - bit_in_byte;
        const take = @min(avail, remaining);
        const val_shift: u6 = @intCast(remaining - take);
        const mask: u64 = (@as(u64, 1) << @intCast(take)) - 1;
        const bits: u8 = @intCast((val >> val_shift) & mask);
        const byte_shift: u3 = @intCast(avail - take);

        data[off / 8] |= bits << byte_shift;
        off += take;
        remaining -= take;
    }
}

// ── CellSlice ──────────────────────────────────────────────────────────────────

pub const CellSlice = struct {
    cell: *const Cell,
    bit_offset: usize, // index of the next unread bit
    bit_end: usize, // one past the last valid bit
    ref_offset: u3, // index of the next unread reference
    ref_end: u3, // one past the last valid reference

    const Self = @This();

    // Wrap the entire cell.
    pub fn init(cell: *const Cell) Self {
        return .{
            .cell = cell,
            .bit_offset = 0,
            .bit_end = cell.data_bit_len,
            .ref_offset = 0,
            .ref_end = @intCast(cell.refCount()),
        };
    }

    pub fn bitsLeft(self: Self) usize {
        return self.bit_end - self.bit_offset;
    }

    pub fn refsLeft(self: Self) usize {
        return @as(usize, self.ref_end) - self.ref_offset;
    }

    pub fn isEmpty(self: Self) bool {
        return self.bitsLeft() == 0 and self.refsLeft() == 0;
    }

    // Consume 1 bit and return it.
    pub fn loadBit(self: *Self) ErrSlice!u1 {
        if (self.bitsLeft() == 0) return ErrSlice.NotEnoughBits;
        const off = self.bit_offset;
        self.bit_offset += 1;
        const shift: u3 = @intCast(7 - (off % 8));
        return @intCast((self.cell.Data[off / 8] >> shift) & 1);
    }

    // Peek 1 bit without advancing.
    pub fn preloadBit(self: Self) ErrSlice!u1 {
        if (self.bitsLeft() == 0) return ErrSlice.NotEnoughBits;

        const shift: u3 = @intCast(7 - (self.bit_offset % 8));
        return @intCast((self.cell.Data[self.bit_offset / 8] >> shift) & 1);
    }

    // Consume n bits (n <= 64) and return them as an unsigned integer.
    pub fn loadUint(self: *Self, n: u7) ErrSlice!u64 {
        if (n == 0) return 0;
        if (self.bitsLeft() < n) return ErrSlice.NotEnoughBits;

        const val = readUintAt(self.cell.Data, self.bit_offset, n);
        self.bit_offset += n;

        return val;
    }

    // Peek n bits without advancing.
    pub fn preloadUint(self: Self, n: u7) ErrSlice!u64 {
        if (n == 0) return 0;
        if (self.bitsLeft() < n) return ErrSlice.NotEnoughBits;

        return readUintAt(self.cell.Data, self.bit_offset, n);
    }

    // Consume n bits (n <= 64) and return them as a signed two's-complement integer.
    pub fn loadInt(self: *Self, n: u7) ErrSlice!i64 {
        if (n == 0) return 0;
        const u = try self.loadUint(n);

        if (n == 64) return @bitCast(u);
        const sign_bit: u64 = @as(u64, 1) << @intCast(n - 1);

        if (u & sign_bit != 0) {
            // Negative: sign-extend to 64 bits.
            return @bitCast(u | (~@as(u64, 0) << @as(u6, @intCast(n))));
        }

        return @intCast(u);
    }

    // Consume n bits and write them MSB-first into dst (dst must be zeroed for partial bytes).
    pub fn loadBits(self: *Self, dst: []u8, n: usize) ErrSlice!void {
        if (n == 0) return;
        if (self.bitsLeft() < n) return ErrSlice.NotEnoughBits;
        @memset(dst[0 .. (n + 7) / 8], 0);

        var remaining = n;
        var dst_off: usize = 0;
        while (remaining > 0) {
            const take: u7 = @intCast(@min(remaining, 64));
            const val = readUintAt(self.cell.Data, self.bit_offset + (n - remaining), take);

            writeUintAt(dst, dst_off, val, take);
            dst_off += take;
            remaining -= take;
        }

        self.bit_offset += n;
    }

    // Consume the next child reference.
    pub fn loadRef(self: *Self) ErrSlice!*Cell {
        if (self.refsLeft() == 0) return ErrSlice.NotEnoughRefs;
        const ref = self.cell.References[self.ref_offset].?;
        self.ref_offset += 1;

        return ref;
    }

    // Peek the next child reference without consuming it.
    pub fn preloadRef(self: Self) ErrSlice!*Cell {
        if (self.refsLeft() == 0) return ErrSlice.NotEnoughRefs;

        return self.cell.References[self.ref_offset].?;
    }

    // Advance the bit cursor by n bits without reading them.
    pub fn skipBits(self: *Self, n: usize) ErrSlice!void {
        if (self.bitsLeft() < n) return ErrSlice.NotEnoughBits;
        self.bit_offset += n;
    }

    // Discard the next child reference.
    pub fn skipRef(self: *Self) ErrSlice!void {
        if (self.refsLeft() == 0) return ErrSlice.NotEnoughRefs;
        self.ref_offset += 1;
    }
};

// ── CellBuilder ────────────────────────────────────────────────────────────────

pub const CellBuilder = struct {
    data: [cell_size_bytes_max]u8,
    bit_len: usize,
    refs: [4]?*Cell,
    ref_count: u3,

    const Self = @This();

    pub fn init() Self {
        return .{
            .data = [_]u8{0} ** cell_size_bytes_max,
            .bit_len = 0,
            .refs = .{ null, null, null, null },
            .ref_count = 0,
        };
    }

    pub fn bitsUsed(self: Self) usize {
        return self.bit_len;
    }

    pub fn refsUsed(self: Self) usize {
        return self.ref_count;
    }

    pub fn bitsLeft(self: Self) usize {
        return cell_size_bits_max - self.bit_len;
    }

    pub fn refsLeft(self: Self) usize {
        return 4 - @as(usize, self.ref_count);
    }

    // Append 1 bit.
    pub fn storeBit(self: *Self, val: u1) ErrSlice!void {
        return self.storeUint(val, 1);
    }

    // Append n bits (n <= 64) from val, MSB-first.
    pub fn storeUint(self: *Self, val: u64, n: u7) ErrSlice!void {
        if (n == 0) return;

        if (self.bit_len + n > cell_size_bits_max) return ErrSlice.CellFull;

        writeUintAt(&self.data, self.bit_len, val, n);
        self.bit_len += n;
    }

    // Append n bits (n <= 64) from val as a signed two's-complement integer.
    pub fn storeInt(self: *Self, val: i64, n: u7) ErrSlice!void {
        if (n == 0) return;

        const bits: u64 = @bitCast(val);
        const mask: u64 = if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;

        return self.storeUint(bits & mask, n);
    }

    // Append n bits from src, MSB-first (src bits packed from src[0] bit 7 downward).
    pub fn storeBits(self: *Self, src: []const u8, n: usize) ErrSlice!void {
        if (n == 0) return;
        if (self.bit_len + n > cell_size_bits_max) return ErrSlice.CellFull;

        var remaining = n;
        var src_off: usize = 0;
        while (remaining > 0) {
            const take: u7 = @intCast(@min(remaining, 64));
            const val = readUintAt(src, src_off, take);

            writeUintAt(&self.data, self.bit_len, val, take);
            self.bit_len += take;

            src_off += take;
            remaining -= take;
        }
    }

    // Append a child reference.
    pub fn storeRef(self: *Self, cell: *Cell) ErrSlice!void {
        if (self.ref_count >= 4) return ErrSlice.TooManyRefs;

        self.refs[self.ref_count] = cell;
        self.ref_count += 1;
    }

    // Append all remaining bits and references from cs into this builder.
    pub fn storeSlice(self: *Self, cs_in: CellSlice) ErrSlice!void {
        var cs = cs_in;
        if (self.bit_len + cs.bitsLeft() > cell_size_bits_max) return ErrSlice.CellFull;
        if (self.refsLeft() < cs.refsLeft()) return ErrSlice.TooManyRefs;

        while (cs.bitsLeft() > 0) {
            const take: u7 = @intCast(@min(cs.bitsLeft(), 64));
            const val = try cs.loadUint(take);
            try self.storeUint(val, take);
        }

        while (cs.refsLeft() > 0) {
            try self.storeRef(try cs.loadRef());
        }
    }

    // Allocate and return a new ordinary Cell from the current builder state.
    // The caller owns both the returned *Cell and cell.Data; use an arena to simplify cleanup.
    pub fn build(self: *const Self, allocator: Allocator) !*Cell {
        const data_bytes = (self.bit_len + 7) / 8;
        const cell = try allocator.create(Cell);
        errdefer allocator.destroy(cell);
        const data = try allocator.alloc(u8, data_bytes);
        errdefer allocator.free(data);
        if (data_bytes > 0) @memcpy(data, self.data[0..data_bytes]);
        cell.* = Cell.init(.Ordinary, data, self.bit_len, self.refs);
        return cell;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

test "CellSlice loadBit reads each bit" {
    var data = [_]u8{0b10110000};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);

    try std.testing.expectEqual(@as(u1, 1), try cs.loadBit());
    try std.testing.expectEqual(@as(u1, 0), try cs.loadBit());
    try std.testing.expectEqual(@as(u1, 1), try cs.loadBit());
    try std.testing.expectEqual(@as(u1, 1), cs.bitsLeft());
    _ = try cs.loadBit();
    _ = try cs.loadBit();
    _ = try cs.loadBit();
    _ = try cs.loadBit();
    _ = try cs.loadBit();
    try std.testing.expectEqual(@as(usize, 0), cs.bitsLeft());
}

test "CellSlice loadBit returns NotEnoughBits when empty" {
    var data = [_]u8{0xFF};
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    _ = try cs.loadUint(4);
    try std.testing.expectError(ErrSlice.NotEnoughBits, cs.loadBit());
}

test "CellSlice loadUint reads byte-aligned value" {
    var data = [_]u8{0xA5};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(@as(u64, 0xA5), try cs.loadUint(8));
}

test "CellSlice loadUint reads across byte boundary" {
    // 16 bits: 0xA5C3 stored in two bytes
    var data = [_]u8{ 0xA5, 0xC3 };
    var cell = Cell.init(.Ordinary, &data, 16, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    // Skip first 4 bits (0xA = 1010), then read 8 bits across the boundary
    _ = try cs.loadUint(4); // consumes 0xA
    try std.testing.expectEqual(@as(u64, 0x5C), try cs.loadUint(8)); // 0101 1100
}

test "CellSlice loadUint 0 bits returns 0" {
    var data = [_]u8{0xFF};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(@as(u64, 0), try cs.loadUint(0));
    try std.testing.expectEqual(@as(usize, 8), cs.bitsLeft()); // cursor unchanged
}

test "CellSlice loadUint returns NotEnoughBits" {
    var data = [_]u8{0xFF};
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectError(ErrSlice.NotEnoughBits, cs.loadUint(5));
}

test "CellSlice preloadUint does not advance cursor" {
    var data = [_]u8{0xA5};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(@as(u64, 0xA5), try cs.preloadUint(8));
    try std.testing.expectEqual(@as(u64, 0xA5), try cs.preloadUint(8));
    try std.testing.expectEqual(@as(usize, 8), cs.bitsLeft());
}

test "CellSlice loadInt positive value" {
    var data = [_]u8{0x03}; // 0000 0011
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(@as(i64, 3), try cs.loadInt(8));
}

test "CellSlice loadInt negative value sign-extends" {
    // 4-bit two's complement: 1110 = -2
    var data = [_]u8{0xE0}; // top 4 bits = 1110
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(@as(i64, -2), try cs.loadInt(4));
}

test "CellSlice loadInt 64-bit value" {
    var data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var cell = Cell.init(.Ordinary, &data, 64, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(@as(i64, -1), try cs.loadInt(64));
}

test "CellSlice loadBits copies n bits to dst" {
    var data = [_]u8{ 0xAB, 0xCD };
    var cell = Cell.init(.Ordinary, &data, 16, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    var dst = [_]u8{ 0, 0 };
    try cs.loadBits(&dst, 16);
    try std.testing.expectEqual(@as(u8, 0xAB), dst[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), dst[1]);
}

test "CellSlice loadBits partial copy" {
    var data = [_]u8{0xA5}; // 10100101
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    var dst = [_]u8{0};
    try cs.loadBits(&dst, 4); // top 4 bits: 1010
    try std.testing.expectEqual(@as(u8, 0xA0), dst[0]);
}

test "CellSlice loadRef returns child cell" {
    var child = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var cell = Cell.init(.Ordinary, &.{}, 0, .{ &child, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(&child, try cs.loadRef());
    try std.testing.expectError(ErrSlice.NotEnoughRefs, cs.loadRef());
}

test "CellSlice preloadRef does not consume reference" {
    var child = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var cell = Cell.init(.Ordinary, &.{}, 0, .{ &child, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectEqual(&child, try cs.preloadRef());
    try std.testing.expectEqual(@as(usize, 1), cs.refsLeft());
}

test "CellSlice skipBits advances cursor" {
    var data = [_]u8{0xFF};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try cs.skipBits(4);
    try std.testing.expectEqual(@as(usize, 4), cs.bitsLeft());
    try std.testing.expectEqual(@as(u64, 0xF), try cs.loadUint(4));
}

test "CellSlice skipBits returns NotEnoughBits" {
    var data = [_]u8{0xFF};
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expectError(ErrSlice.NotEnoughBits, cs.skipBits(5));
}

test "CellSlice isEmpty when all bits and refs consumed" {
    var child = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var data = [_]u8{0xFF};
    var cell = Cell.init(.Ordinary, &data, 8, .{ &child, null, null, null });
    var cs = CellSlice.init(&cell);
    try std.testing.expect(!cs.isEmpty());
    _ = try cs.loadUint(8);
    try std.testing.expect(!cs.isEmpty());
    _ = try cs.loadRef();
    try std.testing.expect(cs.isEmpty());
}

test "CellBuilder storeUint produces correct bytes" {
    var b = CellBuilder.init();
    try b.storeUint(0xA5, 8);
    try std.testing.expectEqual(@as(usize, 8), b.bitsUsed());
    try std.testing.expectEqual(@as(u8, 0xA5), b.data[0]);
}

test "CellBuilder storeUint writes across byte boundary" {
    var b = CellBuilder.init();
    try b.storeUint(0xF, 4); // 1111 -> top nibble of byte 0
    try b.storeUint(0xA, 4); // 1010 -> bottom nibble of byte 0
    try b.storeUint(0x5, 4); // 0101 -> top nibble of byte 1
    try std.testing.expectEqual(@as(u8, 0xFA), b.data[0]);
    try std.testing.expectEqual(@as(u8, 0x50), b.data[1]);
}

test "CellBuilder storeBit appends individual bits" {
    var b = CellBuilder.init();
    try b.storeBit(1);
    try b.storeBit(0);
    try b.storeBit(1);
    try std.testing.expectEqual(@as(usize, 3), b.bitsUsed());
    // Top 3 bits of byte 0: 101 -> 10100000 = 0xA0
    try std.testing.expectEqual(@as(u8, 0xA0), b.data[0]);
}

test "CellBuilder storeInt stores two's complement" {
    var b = CellBuilder.init();
    try b.storeInt(-1, 8); // 0xFF in 8-bit two's complement
    try std.testing.expectEqual(@as(u8, 0xFF), b.data[0]);
}

test "CellBuilder storeInt positive value" {
    var b = CellBuilder.init();
    try b.storeInt(3, 4); // 0011 -> stored in top nibble
    try std.testing.expectEqual(@as(u8, 0x30), b.data[0]);
}

test "CellBuilder storeRef adds reference" {
    var child = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var b = CellBuilder.init();
    try b.storeRef(&child);
    try std.testing.expectEqual(@as(usize, 1), b.refsUsed());
    try std.testing.expectEqual(@as(usize, 3), b.refsLeft());
    try std.testing.expectEqual(&child, b.refs[0]);
}

test "CellBuilder TooManyRefs error after 4 refs" {
    var child = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var b = CellBuilder.init();
    try b.storeRef(&child);
    try b.storeRef(&child);
    try b.storeRef(&child);
    try b.storeRef(&child);
    try std.testing.expectError(ErrSlice.TooManyRefs, b.storeRef(&child));
}

test "CellBuilder CellFull error when exceeding 1023 bits" {
    var b = CellBuilder.init();
    // Store 1016 bits (127 bytes)
    for (0..127) |_| try b.storeUint(0, 8);
    try std.testing.expectEqual(@as(usize, 1016), b.bitsUsed());
    try b.storeUint(0, 7); // 7 more -> 1023 total, OK
    try std.testing.expectError(ErrSlice.CellFull, b.storeUint(0, 1)); // would be 1024
}

test "CellBuilder storeBits copies bit sequence" {
    const src = [_]u8{ 0xAB, 0xCD };
    var b = CellBuilder.init();
    try b.storeBits(&src, 16);
    try std.testing.expectEqual(@as(u8, 0xAB), b.data[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), b.data[1]);
}

test "CellBuilder storeSlice copies all bits and refs" {
    var child = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var data = [_]u8{0xBE};
    var src_cell = Cell.init(.Ordinary, &data, 8, .{ &child, null, null, null });
    const cs = CellSlice.init(&src_cell);

    var b = CellBuilder.init();
    try b.storeSlice(cs);

    try std.testing.expectEqual(@as(usize, 8), b.bitsUsed());
    try std.testing.expectEqual(@as(u8, 0xBE), b.data[0]);
    try std.testing.expectEqual(@as(usize, 1), b.refsUsed());
    try std.testing.expectEqual(&child, b.refs[0]);
}

test "CellBuilder build allocates a valid Cell" {
    const allocator = std.testing.allocator;

    var b = CellBuilder.init();
    try b.storeUint(0xDEAD, 16);

    const cell = try b.build(allocator);
    defer {
        allocator.free(cell.Data);
        allocator.destroy(cell);
    }

    try std.testing.expectEqual(@as(usize, 16), cell.data_bit_len);
    try std.testing.expectEqual(@as(u8, 0xDE), cell.Data[0]);
    try std.testing.expectEqual(@as(u8, 0xAD), cell.Data[1]);
}

test "CellBuilder build empty cell" {
    const allocator = std.testing.allocator;
    var b = CellBuilder.init();
    const cell = try b.build(allocator);
    defer {
        allocator.free(cell.Data);
        allocator.destroy(cell);
    }
    try std.testing.expectEqual(@as(usize, 0), cell.data_bit_len);
    try std.testing.expectEqual(@as(usize, 0), cell.Data.len);
}

test "round-trip: build then slice" {
    const allocator = std.testing.allocator;

    var child = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var b = CellBuilder.init();
    try b.storeUint(0xFF, 8);
    try b.storeInt(-1, 8);
    try b.storeRef(&child);

    const cell = try b.build(allocator);
    defer {
        allocator.free(cell.Data);
        allocator.destroy(cell);
    }

    var cs = CellSlice.init(cell);
    try std.testing.expectEqual(@as(u64, 0xFF), try cs.loadUint(8));
    try std.testing.expectEqual(@as(i64, -1), try cs.loadInt(8));
    try std.testing.expectEqual(&child, try cs.loadRef());
    try std.testing.expect(cs.isEmpty());
}

test "round-trip: storeBits then loadBits" {
    const allocator = std.testing.allocator;

    const src = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var b = CellBuilder.init();
    try b.storeBits(&src, 32);

    const cell = try b.build(allocator);
    defer {
        allocator.free(cell.Data);
        allocator.destroy(cell);
    }

    var cs = CellSlice.init(cell);
    var dst = [_]u8{0} ** 4;
    try cs.loadBits(&dst, 32);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}
