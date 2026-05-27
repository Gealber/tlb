//! TVM Cell primitives — serialization, deserialization, and hashing.
const std = @import("std");
const log = std.log.scoped(.tlb);
const assert = std.debug.assert;
const sha256 = std.crypto.hash.sha2.Sha256;

pub const cell_size_bits_max = 1023;
pub const cell_size_bytes_max = 128;
pub const cell_depth_max = 1024;
pub const cell_serialized_bytes_max = 2 + cell_size_bytes_max + 4 * (32 + 2); // 266

pub const CellT = enum(u8) { Ordinary, PrunedBranch, LibraryReference, MerkleProof, MerkleUpdate };

pub const ErrCell = error{
    CellDataTooBig,
    MaxDepthExceeded,
    BufferTooSmall,
    InvalidCellDescriptor,
    InvalidCompletionTag,
};

const D1RefCountMask: u8 = 0x07;
const D1IsSpecialBit: u8 = 0x08;
const D1IsSpecialShift: u8 = 3;
const D1LevelShift: u8 = 5;
const D1LevelMultiplier: u8 = 32;
const D1IsSpecialMultiplier: u8 = 8;
const RefDepthBytes: usize = 2;
const RefHashBytes: usize = 32;

const ExoticType = enum(u8) {
    PrunedBranch = 1,
    LibraryReference = 2,
    MerkleProof = 3,
    MerkleUpdate = 4,
};

inline fn serializedLen(data_bytes: usize, reference_cnt: u8) usize {
    return 2 + data_bytes + @as(usize, reference_cnt) * (RefDepthBytes + RefHashBytes);
}

pub const Cell = struct {
    T: CellT,
    Data: []u8,
    data_bit_len: usize,
    References: [4]?*Cell,
    level: u8,
    hash: [32]u8 = undefined,
    visiting: bool = false,

    const Self = @This();

    pub fn init(T: CellT, data: []u8, data_bit_len: usize, references: [4]?*Self) Self {
        return .{
            .T = T,
            .Data = data,
            .data_bit_len = data_bit_len,
            .References = references,
            .level = 0, // TODO: derive level_mask for exotic cells from references
        };
    }

    // serialize a TVM Cell according to documentation:
    // https://docs.ton.org/blockchain-basics/primitives/serialization/cells#standard-cell-representation-and-its-hash
    pub fn serialize(self: Self, dst: *[cell_serialized_bytes_max]u8) ErrCell!usize {
        @memset(dst, 0);

        var ref_index: u8 = 0;
        while (ref_index < 4 and self.References[ref_index] != null) : (ref_index += 1) {}
        const reference_cnt: u8 = ref_index;

        const bit_len = self.data_bit_len;
        if (bit_len > cell_size_bits_max) return ErrCell.CellDataTooBig;

        const is_special: u8 = @intFromBool(self.T != CellT.Ordinary);

        var byte_count: usize = 0;
        dst[0] = reference_cnt + D1IsSpecialMultiplier * is_special + D1LevelMultiplier * self.level;
        dst[1] = @intCast(bit_len / 8 + (bit_len + 7) / 8);
        byte_count += 2;

        const data_bytes = (bit_len + 7) / 8;
        @memcpy(dst[byte_count .. byte_count + data_bytes], self.Data[0..data_bytes]);
        byte_count += data_bytes;
        if (bit_len % 8 != 0) {
            dst[byte_count - 1] |= @as(u8, 1) << @intCast(7 - (bit_len % 8));
        }

        for (0..reference_cnt) |ref_i| {
            const ref = self.References[ref_i].?;
            const ref_depth = try ref.depth();
            std.mem.writeInt(u16, dst[byte_count..][0..RefDepthBytes], ref_depth, .big);
            byte_count += RefDepthBytes;
        }

        for (0..reference_cnt) |ref_i| {
            const ref = self.References[ref_i].?;
            const ref_hash = try ref.computeHash();
            @memcpy(dst[byte_count..][0..RefHashBytes], &ref_hash);
            byte_count += RefHashBytes;
        }

        return byte_count;
    }

    pub fn deserialize(self: *Self, src: []u8) ErrCell!void {
        if (src.len < 2) return ErrCell.BufferTooSmall;

        // decode reference counts and data bytes size
        const d1 = src[0];
        const d2 = src[1];

        const reference_cnt: u8 = d1 & D1RefCountMask;
        if (reference_cnt > 4) return ErrCell.InvalidCellDescriptor;
        const is_special = (d1 & D1IsSpecialBit) != 0;

        self.level = d1 >> D1LevelShift;
        self.References = .{ null, null, null, null };

        const data_bytes: usize = (d2 + 1) / 2;

        // sanity check on data_bytes decoded
        if (data_bytes > cell_size_bytes_max) return ErrCell.CellDataTooBig;
        if (src.len < serializedLen(data_bytes, reference_cnt)) return ErrCell.BufferTooSmall;
        if (self.Data.len < data_bytes) return ErrCell.BufferTooSmall;

        // copy data
        @memcpy(self.Data[0..data_bytes], src[2..][0..data_bytes]);

        // set data bits len
        if (d2 % 2 == 0) {
            self.data_bit_len = data_bytes * 8;
        } else {
            const last_byte = self.Data[data_bytes - 1];
            if (last_byte == 0) return ErrCell.InvalidCompletionTag;
            const trailing: u8 = @intCast(@ctz(last_byte));
            self.Data[data_bytes - 1] &= ~(@as(u8, 1) << @as(u3, @intCast(trailing)));
            self.data_bit_len = (data_bytes - 1) * 8 + 7 - trailing;
        }

        // infer cell type
        if (is_special) {
            if (data_bytes < 1) return ErrCell.InvalidCellDescriptor;
            self.T = switch (self.Data[0]) {
                @intFromEnum(ExoticType.PrunedBranch) => .PrunedBranch,
                @intFromEnum(ExoticType.LibraryReference) => .LibraryReference,
                @intFromEnum(ExoticType.MerkleProof) => .MerkleProof,
                @intFromEnum(ExoticType.MerkleUpdate) => .MerkleUpdate,
                else => return ErrCell.InvalidCellDescriptor,
            };
        } else {
            self.T = .Ordinary;
        }
    }

    pub fn computeHash(self: *Self) ErrCell![32]u8 {
        assert(!self.visiting); // cyclic reference detected
        self.visiting = true;
        defer self.visiting = false;

        var buf: [cell_serialized_bytes_max]u8 = undefined;
        const byte_count = try self.serialize(&buf);
        sha256.hash(buf[0..byte_count], &self.hash, .{});

        return self.hash;
    }

    pub fn depth(self: *Self) ErrCell!u16 {
        assert(!self.visiting); // cyclic reference detected
        self.visiting = true;
        defer self.visiting = false;

        var max_child: u16 = 0;
        for (self.References) |ref| {
            const ref_cell = ref orelse break;
            const child_depth = try ref_cell.depth();
            if (child_depth > max_child) max_child = child_depth;
        }

        const result: u16 = if (max_child == 0 and self.References[0] == null) 0 else max_child + 1;

        if (result > cell_depth_max) return ErrCell.MaxDepthExceeded;

        return result;
    }

    pub fn refCount(self: *Self) usize {
        var ref_index: usize = 0;
        while (ref_index < 4 and self.References[ref_index] != null) : (ref_index += 1) {}
        return ref_index;
    }
};

fn makeLeaf() Cell {
    return Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
}

test "leaf cell has depth 0" {
    var cell = makeLeaf();
    try std.testing.expectEqual(0, try cell.depth());
}

test "single reference has depth 1" {
    var child = makeLeaf();
    var cell = Cell.init(.Ordinary, &.{}, 0, .{ &child, null, null, null });
    try std.testing.expectEqual(1, try cell.depth());
}

test "depth is max of all references plus 1" {
    var shallow = makeLeaf();
    var deep_child = makeLeaf();
    var deep = Cell.init(.Ordinary, &.{}, 0, .{ &deep_child, null, null, null });
    var cell = Cell.init(.Ordinary, &.{}, 0, .{ &shallow, &deep, null, null });
    try std.testing.expectEqual(2, try cell.depth());
}

test "linear chain depth" {
    var a = makeLeaf();
    var b = Cell.init(.Ordinary, &.{}, 0, .{ &a, null, null, null });
    var c = Cell.init(.Ordinary, &.{}, 0, .{ &b, null, null, null });
    var d = Cell.init(.Ordinary, &.{}, 0, .{ &c, null, null, null });
    try std.testing.expectEqual(3, try d.depth());
}

test "depth exceeding max returns error" {
    var cells: [cell_depth_max + 2]Cell = undefined;
    cells[0] = makeLeaf();
    for (1..cell_depth_max + 2) |i| {
        cells[i] = Cell.init(.Ordinary, &.{}, 0, .{ &cells[i - 1], null, null, null });
    }
    try std.testing.expectError(error.MaxDepthExceeded, cells[cell_depth_max + 1].depth());
}

test "depth with four references takes the max" {
    var a = makeLeaf();
    var b = Cell.init(.Ordinary, &.{}, 0, .{ &a, null, null, null });
    var c = Cell.init(.Ordinary, &.{}, 0, .{ &a, &b, null, null });
    var leaf = makeLeaf();
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &a, &leaf, &b, &c });
    try std.testing.expectEqual(3, try root.depth());
}

test "dag shared reference does not trigger cycle detection" {
    // Diamond: root -> left -> shared, root -> right -> shared
    var shared = makeLeaf();
    var left = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var right = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &left, &right, null, null });
    try std.testing.expectEqual(2, try root.depth());
}

test "serialize empty leaf" {
    var cell = makeLeaf();
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    const byte_count = try cell.serialize(&buf);
    try std.testing.expectEqual(2, byte_count);
    try std.testing.expectEqual(0x00, buf[0]); // d1: 0 refs, ordinary, level 0
    try std.testing.expectEqual(0x00, buf[1]); // d2: 0 bits
}

test "serialize byte-aligned data" {
    var data = [_]u8{0xAB};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    const byte_count = try cell.serialize(&buf);
    try std.testing.expectEqual(3, byte_count);
    try std.testing.expectEqual(0x00, buf[0]); // d1
    try std.testing.expectEqual(0x02, buf[1]); // d2: floor(8/8) + ceil(8/8) = 2
    try std.testing.expectEqual(0xAB, buf[2]);
}

test "serialize non-byte-aligned data sets completion tag" {
    var data = [_]u8{0x00};
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    const byte_count = try cell.serialize(&buf);
    try std.testing.expectEqual(3, byte_count);
    try std.testing.expectEqual(0x01, buf[1]); // d2: ceil(4/8) = 1
    try std.testing.expectEqual(0x08, buf[2]); // completion tag at bit 3 (1 << (7-4))
}

test "serialize exotic cell sets is_special bit in d1" {
    var cell = Cell.init(.PrunedBranch, &.{}, 0, .{ null, null, null, null });
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    _ = try cell.serialize(&buf);
    try std.testing.expectEqual(8, buf[0] & 0x08);
}

test "serialize data too big returns error" {
    var data: [cell_size_bytes_max]u8 = undefined;
    var cell = Cell.init(.Ordinary, &data, cell_size_bits_max + 1, .{ null, null, null, null });
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    try std.testing.expectError(error.CellDataTooBig, cell.serialize(&buf));
}

test "serialize with references writes depths then hashes" {
    var child = makeLeaf();
    var cell = Cell.init(.Ordinary, &.{}, 0, .{ &child, null, null, null });
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    const byte_count = try cell.serialize(&buf);
    // 2 descriptor + 0 data + 1*2 depth + 1*32 hash = 36
    try std.testing.expectEqual(36, byte_count);
    // depth of leaf = 0, written as big-endian u16 at offset 2
    try std.testing.expectEqual(0x00, buf[2]);
    try std.testing.expectEqual(0x00, buf[3]);
    // hash occupies bytes 4..36 — just verify it's non-zero (sha256 of a real cell)
    const hash_slice = buf[4..36];
    const all_zero = std.mem.allEqual(u8, hash_slice, 0);
    try std.testing.expect(!all_zero);
}

test "computeHash is deterministic" {
    var data = [_]u8{ 0xDE, 0xAD };
    var cell1 = Cell.init(.Ordinary, &data, 16, .{ null, null, null, null });
    var cell2 = Cell.init(.Ordinary, &data, 16, .{ null, null, null, null });
    const h1 = try cell1.computeHash();
    const h2 = try cell2.computeHash();
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

fn cellWithBuffer(buf: []u8) Cell {
    return .{
        .T = .Ordinary,
        .Data = buf,
        .data_bit_len = 0,
        .References = .{ null, null, null, null },
        .level = 0,
    };
}

test "deserialize empty leaf" {
    var cell = makeLeaf();
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    const byte_count = try cell.serialize(&buf);

    var out_data: [cell_size_bytes_max]u8 = undefined;
    var out = cellWithBuffer(&out_data);
    try out.deserialize(buf[0..byte_count]);

    try std.testing.expectEqual(CellT.Ordinary, out.T);
    try std.testing.expectEqual(@as(usize, 0), out.data_bit_len);
    try std.testing.expectEqual(@as(u8, 0), out.level);
}

test "deserialize byte-aligned data round-trip" {
    var data = [_]u8{0xAB};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    const byte_count = try cell.serialize(&buf);

    var out_data: [cell_size_bytes_max]u8 = undefined;
    var out = cellWithBuffer(&out_data);
    try out.deserialize(buf[0..byte_count]);

    try std.testing.expectEqual(CellT.Ordinary, out.T);
    try std.testing.expectEqual(@as(usize, 8), out.data_bit_len);
    try std.testing.expectEqual(@as(u8, 0xAB), out.Data[0]);
}

test "deserialize non-byte-aligned data strips completion tag" {
    var data = [_]u8{0xF0}; // top 4 bits are data
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var buf: [cell_serialized_bytes_max]u8 = undefined;
    const byte_count = try cell.serialize(&buf);

    var out_data: [cell_size_bytes_max]u8 = undefined;
    var out = cellWithBuffer(&out_data);
    try out.deserialize(buf[0..byte_count]);

    try std.testing.expectEqual(@as(usize, 4), out.data_bit_len);
    try std.testing.expectEqual(@as(u8, 0xF0), out.Data[0]);
}

test "deserialize exotic cell recognizes all types" {
    const cases = [_]struct { ct: CellT, tb: u8 }{
        .{ .ct = .PrunedBranch, .tb = @intFromEnum(ExoticType.PrunedBranch) },
        .{ .ct = .LibraryReference, .tb = @intFromEnum(ExoticType.LibraryReference) },
        .{ .ct = .MerkleProof, .tb = @intFromEnum(ExoticType.MerkleProof) },
        .{ .ct = .MerkleUpdate, .tb = @intFromEnum(ExoticType.MerkleUpdate) },
    };
    for (cases) |c| {
        var data = [_]u8{c.tb};
        var cell = Cell.init(c.ct, &data, 8, .{ null, null, null, null });
        var buf: [cell_serialized_bytes_max]u8 = undefined;
        const byte_count = try cell.serialize(&buf);

        var out_data: [cell_size_bytes_max]u8 = undefined;
        var out = cellWithBuffer(&out_data);
        try out.deserialize(buf[0..byte_count]);

        try std.testing.expectEqual(c.ct, out.T);
        try std.testing.expectEqual(@as(u8, c.tb), out.Data[0]);
    }
}

test "deserialize error: buffer too small" {
    var buf = [_]u8{0x00};
    var out_data: [cell_size_bytes_max]u8 = undefined;
    var out = cellWithBuffer(&out_data);
    try std.testing.expectError(error.BufferTooSmall, out.deserialize(&buf));
}

test "deserialize error: reference count too high" {
    var buf = [_]u8{ 0x05, 0x00 }; // d1: ref_cnt = 5
    var out_data: [cell_size_bytes_max]u8 = undefined;
    var out = cellWithBuffer(&out_data);
    try std.testing.expectError(error.InvalidCellDescriptor, out.deserialize(&buf));
}

test "deserialize error: invalid completion tag" {
    var buf = [_]u8{ 0x00, 0x01, 0x00 }; // d2=1 non-byte-aligned, but data byte is 0
    var out_data: [cell_size_bytes_max]u8 = undefined;
    var out = cellWithBuffer(&out_data);
    try std.testing.expectError(error.InvalidCompletionTag, out.deserialize(&buf));
}

test "deserialize error: unknown exotic type byte" {
    // d1: is_special=1, d2=2 (1 byte), data[0]=0xFF
    var buf = [_]u8{ 0x08, 0x02, 0xFF };
    var out_data: [cell_size_bytes_max]u8 = undefined;
    var out = cellWithBuffer(&out_data);
    try std.testing.expectError(error.InvalidCellDescriptor, out.deserialize(&buf));
}

test "fuzz serialize does not panic on arbitrary input" {
    const S = struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const bit_len = smith.valueWithHash(u16, 0);
            const data_bytes = @min((bit_len + 7) / 8, cell_size_bytes_max);
            var data: [cell_size_bytes_max]u8 = undefined;
            smith.bytesWithHash(data[0..data_bytes], 1);
            var cell = Cell.init(.Ordinary, data[0..data_bytes], bit_len, .{ null, null, null, null });
            var buf: [cell_serialized_bytes_max]u8 = undefined;
            _ = cell.serialize(&buf) catch |err| switch (err) {
                error.CellDataTooBig => {},
                else => return err,
            };
        }
    };
    try std.testing.fuzz({}, S.run, .{});
}
