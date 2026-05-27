//! Bag of Cells — container format for transmitting cell DAGs over the wire.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const crc32c = std.hash.crc.Crc32Iscsi.hash;

const cell_mod = @import("cell.zig");
pub const Cell = cell_mod.Cell;

pub const boc_cells_max: usize = 1 << 13;

pub const ErrBoC = error{ TooManyCells, EmptyRoots, BufferTooSmall, InvalidMagic, InvalidChecksum };

const boc_magic: u32 = 0xb5ee9c72;

// Minimum number of bytes needed to represent any value in [0, n].
fn bytesFor(n: usize) u8 {
    if (n < (1 << 8)) return 1;
    if (n < (1 << 16)) return 2;
    if (n < (1 << 24)) return 3;
    return 4;
}

// Write val into dst as big-endian using exactly dst.len bytes.
fn writeUintBE(dst: []u8, val: usize) void {
    for (0..dst.len) |i| {
        const shift: u6 = @intCast(i * 8);
        dst[dst.len - 1 - i] = @truncate(val >> shift);
    }
}

// Read a big-endian unsigned integer from src (any length up to 8 bytes).
fn readUintBE(src: []const u8) usize {
    var val: usize = 0;
    for (src) |byte| val = (val << 8) | byte;
    return val;
}

pub const BoC = struct {
    allocator: Allocator,
    cells: []*Cell,
    roots: []usize,
    // Non-null only when fromBytes owns the cell storage.
    cell_buf: ?[]Cell = null,
    data_buf: ?[]u8 = null,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.roots);
        if (self.cell_buf) |buf| self.allocator.free(buf);
        if (self.data_buf) |buf| self.allocator.free(buf);
    }

    pub fn fromCells(allocator: Allocator, roots: []*Cell) !Self {
        if (roots.len == 0) return ErrBoC.EmptyRoots;

        var visited = std.AutoHashMap(*Cell, usize).init(allocator);
        defer visited.deinit();

        var list = try std.ArrayList(*Cell).initCapacity(allocator, roots.len);
        defer list.deinit(allocator);

        for (roots) |r| {
            try visitCell(allocator, r, &visited, &list);
        }

        if (list.items.len > boc_cells_max) return ErrBoC.TooManyCells;

        const cells_out = try allocator.alloc(*Cell, list.items.len);
        errdefer allocator.free(cells_out);
        @memcpy(cells_out, list.items);

        const roots_out = try allocator.alloc(usize, roots.len);
        errdefer allocator.free(roots_out);
        for (roots, 0..) |r, i| {
            roots_out[i] = visited.get(r).?;
        }

        return Self{
            .allocator = allocator,
            .cells = cells_out,
            .roots = roots_out,
        };
    }

    // Total bytes occupied by all cells in the flat array when serialized with
    // cell_index_bytes-byte reference indices (BoC format, not standalone Cell.serialize).
    fn totCellsSize(self: *const Self, cell_index_bytes: usize) usize {
        var total: usize = 0;
        for (self.cells) |c| {
            const data_bytes = (c.data_bit_len + 7) / 8;
            total += 2 + data_bytes + c.refCount() * cell_index_bytes;
        }
        return total;
    }

    // Bytes needed to hold the serialized BoC (no index table, no CRC32C trailer).
    pub fn serializedSize(self: *const Self) usize {
        const cell_index_bytes: usize = bytesFor(self.cells.len);
        const total_cells_size = self.totCellsSize(cell_index_bytes);
        const offset_bytes: usize = bytesFor(total_cells_size);
        // magic(4) + flags(1) + off_bytes(1) + cells_count(cell_index_bytes) + roots_count(cell_index_bytes)
        // + absent(cell_index_bytes) + tot_cells_size(offset_bytes) + root_list(cell_index_bytes*roots.len) + cell_data(total_cells_size)
        return 4 + 1 + 1 + cell_index_bytes * 3 + offset_bytes + cell_index_bytes * self.roots.len + total_cells_size;
    }

    // Bytes needed to hold the serialized BoC with an index table (has_idx=1).
    pub fn serializedSizeIndexed(self: *const Self) usize {
        const cell_index_bytes: usize = bytesFor(self.cells.len);
        const total_cells_size = self.totCellsSize(cell_index_bytes);
        const offset_bytes: usize = bytesFor(total_cells_size);
        // Same as serializedSize plus n*offset_bytes bytes for the index table.
        return 4 + 1 + 1 + cell_index_bytes * 3 + offset_bytes + cell_index_bytes * self.roots.len + self.cells.len * offset_bytes + total_cells_size;
    }

    // Bytes needed for a CRC32C-annotated BoC (append 4 to the base size).
    pub fn serializedSizeCrc(self: *const Self) usize {
        return self.serializedSize() + 4;
    }

    // Bytes needed for an indexed, CRC32C-annotated BoC.
    pub fn serializedSizeIndexedCrc(self: *const Self) usize {
        return self.serializedSizeIndexed() + 4;
    }

    // Core serializer shared by all public serialize* variants.
    //
    // Wire format (has_idx = indexed, has_crc32c always 0 here):
    //   [4]  magic 0xb5ee9c72
    //   [1]  flags: bit7=has_idx, bit6=has_crc32c(0), bits2-0=cell_index_bytes
    //   [1]  off_bytes = offset_bytes
    //   [cell_index_bytes]  cells_count
    //   [cell_index_bytes]  roots_count
    //   [cell_index_bytes]  absent_count (always 0)
    //   [offset_bytes]  tot_cells_size
    //   [cell_index_bytes * roots.len]  root_list
    //   [n*offset_bytes] index table (only when indexed): entry i = cumulative byte offset
    //          to the end of cell i's data within the cell data section
    //   [tot_cells_size] cell data (children before parents)
    //
    // Cell data references are cell_index_bytes-byte big-endian flat-array indices,
    // not the (depth + hash) pairs used by Cell.serialize.
    fn serializeInner(self: *const Self, dst: []u8, indexed: bool) !usize {
        var index_map = std.AutoHashMap(*Cell, usize).init(self.allocator);
        defer index_map.deinit();
        for (self.cells, 0..) |c, i| {
            try index_map.put(c, i);
        }

        const cell_index_bytes: usize = bytesFor(self.cells.len);
        const total_cells_size = self.totCellsSize(cell_index_bytes);
        const offset_bytes: usize = bytesFor(total_cells_size);
        const total: usize = if (indexed) self.serializedSizeIndexed() else self.serializedSize();

        if (dst.len < total) return ErrBoC.BufferTooSmall;

        var offset: usize = 0;

        std.mem.writeInt(u32, dst[offset..][0..4], boc_magic, .big);
        offset += 4;

        dst[offset] = @intCast(cell_index_bytes & 0x07);
        if (indexed) dst[offset] |= 0x80;
        offset += 1;

        dst[offset] = @intCast(offset_bytes);
        offset += 1;

        writeUintBE(dst[offset .. offset + cell_index_bytes], self.cells.len);
        offset += cell_index_bytes;
        writeUintBE(dst[offset .. offset + cell_index_bytes], self.roots.len);
        offset += cell_index_bytes;
        writeUintBE(dst[offset .. offset + cell_index_bytes], 0);
        offset += cell_index_bytes;

        writeUintBE(dst[offset .. offset + offset_bytes], total_cells_size);
        offset += offset_bytes;

        for (self.roots) |r| {
            writeUintBE(dst[offset .. offset + cell_index_bytes], r);
            offset += cell_index_bytes;
        }

        // Index table: entry i = cumulative size of cells 0..i in the cell data section.
        if (indexed) {
            var cumulative_size: usize = 0;
            for (self.cells) |c| {
                cumulative_size += 2 + (c.data_bit_len + 7) / 8 + c.refCount() * cell_index_bytes;
                writeUintBE(dst[offset .. offset + offset_bytes], cumulative_size);
                offset += offset_bytes;
            }
        }

        for (self.cells) |c| {
            const ref_count: usize = c.refCount();
            const is_special: u8 = @intFromBool(c.T != .Ordinary);

            dst[offset] = @intCast(ref_count + @as(usize, is_special) * 8 + @as(usize, c.level) * 32);
            offset += 1;

            const bit_len = c.data_bit_len;
            dst[offset] = @intCast(bit_len / 8 + (bit_len + 7) / 8);
            offset += 1;

            const data_bytes = (bit_len + 7) / 8;
            if (data_bytes > 0) {
                @memcpy(dst[offset .. offset + data_bytes], c.Data[0..data_bytes]);
                offset += data_bytes;
                if (bit_len % 8 != 0) {
                    dst[offset - 1] |= @as(u8, 1) << @intCast(7 - (bit_len % 8));
                }
            }

            for (0..ref_count) |ref_i| {
                const ref_idx = index_map.get(c.References[ref_i].?).?;
                writeUintBE(dst[offset .. offset + cell_index_bytes], ref_idx);
                offset += cell_index_bytes;
            }
        }

        assert(offset == total);
        return offset;
    }

    // Serialize this BoC into dst (has_idx=0, has_crc32c=0).
    pub fn serialize(self: *const Self, dst: []u8) !usize {
        return self.serializeInner(dst, false);
    }

    // Serialize with has_idx=1: appends an n*offset_bytes-byte index table after the root list.
    pub fn serializeIndexed(self: *const Self, dst: []u8) !usize {
        return self.serializeInner(dst, true);
    }

    // Serialize with has_crc32c=1: sets the flag bit and appends a 4-byte LE CRC32C.
    pub fn serializeCrc(self: *const Self, dst: []u8) !usize {
        const base_size = self.serializedSize();
        if (dst.len < base_size + 4) return ErrBoC.BufferTooSmall;
        const written = try self.serializeInner(dst[0..base_size], false);
        dst[4] |= 0x40;
        std.mem.writeInt(u32, dst[written..][0..4], crc32c(dst[0..written]), .little);
        return written + 4;
    }

    // Serialize with both has_idx=1 and has_crc32c=1.
    pub fn serializeIndexedCrc(self: *const Self, dst: []u8) !usize {
        const base_size = self.serializedSizeIndexed();
        if (dst.len < base_size + 4) return ErrBoC.BufferTooSmall;
        const written = try self.serializeInner(dst[0..base_size], true);
        dst[4] |= 0x40;
        std.mem.writeInt(u32, dst[written..][0..4], crc32c(dst[0..written]), .little);
        return written + 4;
    }

    // Deserialize a BoC from src.  The returned BoC owns all allocated memory;
    // call deinit() when done.
    //
    // Handles standard and indexed BoC variants (has_idx flag).
    // When has_crc32c is set the last 4 bytes are a little-endian CRC32C of all preceding bytes.
    pub fn fromBytes(allocator: Allocator, src: []const u8) !Self {
        // Minimum header: 4 magic + 1 flags + 1 off_bytes.
        if (src.len < 6) return ErrBoC.BufferTooSmall;

        if (std.mem.readInt(u32, src[0..4], .big) != boc_magic)
            return ErrBoC.InvalidMagic;

        const flags_byte = src[4];
        const has_idx = (flags_byte & 0x80) != 0;
        const has_crc32c = (flags_byte & 0x40) != 0;
        const cell_index_bytes: usize = flags_byte & 0x07;
        const offset_bytes: usize = src[5];

        // Full variable-length header: 6 fixed + 3*cell_index_bytes counts + offset_bytes tot_cells_size.
        if (src.len < 6 + cell_index_bytes * 3 + offset_bytes) return ErrBoC.BufferTooSmall;

        var offset: usize = 6;
        const cell_count = readUintBE(src[offset .. offset + cell_index_bytes]);
        offset += cell_index_bytes;
        const roots_count = readUintBE(src[offset .. offset + cell_index_bytes]);
        offset += cell_index_bytes;
        offset += cell_index_bytes; // absent_count — not used
        const total_cells_size = readUintBE(src[offset .. offset + offset_bytes]);
        offset += offset_bytes;

        if (cell_count == 0 or roots_count == 0) return ErrBoC.EmptyRoots;
        if (cell_count > boc_cells_max) return ErrBoC.TooManyCells;

        const idx_table_size: usize = if (has_idx) cell_count * offset_bytes else 0;
        const crc_size: usize = if (has_crc32c) 4 else 0;
        const needed = offset + roots_count * cell_index_bytes + idx_table_size + total_cells_size + crc_size;
        if (src.len < needed) return ErrBoC.BufferTooSmall;

        if (has_crc32c) {
            const payload_end = needed - 4;
            const stored = std.mem.readInt(u32, src[payload_end..][0..4], .little);
            if (crc32c(src[0..payload_end]) != stored) return ErrBoC.InvalidChecksum;
        }

        // Root list.
        const roots_out = try allocator.alloc(usize, roots_count);
        errdefer allocator.free(roots_out);
        for (roots_out) |*r| {
            r.* = readUintBE(src[offset .. offset + cell_index_bytes]);
            offset += cell_index_bytes;
        }

        // Skip index table if present.
        if (has_idx) offset += cell_count * offset_bytes;

        // Allocate cell structs and a single data buffer (total_cells_size is an
        // upper bound on the total raw data bytes across all cells).
        const cell_buf = try allocator.alloc(Cell, cell_count);
        errdefer allocator.free(cell_buf);
        const data_buf = try allocator.alloc(u8, total_cells_size);
        errdefer allocator.free(data_buf);

        // Temporary per-cell ref-count and ref-index storage, freed before return.
        const ref_count_buf = try allocator.alloc(u8, cell_count);
        defer allocator.free(ref_count_buf);
        const ref_idx_buf = try allocator.alloc(usize, cell_count * 4);
        defer allocator.free(ref_idx_buf);

        var data_offset: usize = 0;

        // Parse cell data.
        for (0..cell_count) |cell_i| {
            if (offset + 2 > src.len) return ErrBoC.BufferTooSmall;
            const d1 = src[offset];
            offset += 1;
            const d2 = src[offset];
            offset += 1;

            const ref_count: u8 = d1 & 0x07;
            if (ref_count > 4) return cell_mod.ErrCell.InvalidCellDescriptor;
            const is_special = (d1 & 0x08) != 0;
            const level: u8 = d1 >> 5;

            const data_bytes: usize = (d2 + 1) / 2;
            if (data_bytes > cell_mod.cell_size_bytes_max) return cell_mod.ErrCell.CellDataTooBig;
            if (offset + data_bytes + ref_count * cell_index_bytes > src.len) return ErrBoC.BufferTooSmall;

            // Slice this cell's data out of the shared data_buf.
            const cell_data = data_buf[data_offset .. data_offset + data_bytes];
            @memcpy(cell_data, src[offset .. offset + data_bytes]);
            offset += data_bytes;
            data_offset += data_bytes;

            // Determine bit length and strip completion tag (same as Cell.deserialize).
            var bit_len: usize = undefined;
            if (d2 % 2 == 0) {
                bit_len = data_bytes * 8;
            } else {
                if (data_bytes == 0) return cell_mod.ErrCell.InvalidCompletionTag;
                const last_byte = cell_data[data_bytes - 1];
                if (last_byte == 0) return cell_mod.ErrCell.InvalidCompletionTag;
                const trailing: u8 = @intCast(@ctz(last_byte));
                cell_data[data_bytes - 1] &= ~(@as(u8, 1) << @as(u3, @intCast(trailing)));
                bit_len = (data_bytes - 1) * 8 + 7 - trailing;
            }

            // Infer cell type from first data byte when is_special.
            const cell_type: cell_mod.CellT = if (is_special) blk: {
                if (data_bytes < 1) return cell_mod.ErrCell.InvalidCellDescriptor;
                break :blk switch (cell_data[0]) {
                    1 => .PrunedBranch,
                    2 => .LibraryReference,
                    3 => .MerkleProof,
                    4 => .MerkleUpdate,
                    else => return cell_mod.ErrCell.InvalidCellDescriptor,
                };
            } else .Ordinary;

            // Read reference indices.  Each must point to an earlier cell
            // (topological order invariant: children always have lower indices).
            ref_count_buf[cell_i] = ref_count;
            for (0..ref_count) |ref_i| {
                const ref_idx = readUintBE(src[offset .. offset + cell_index_bytes]);
                if (ref_idx >= cell_i) return cell_mod.ErrCell.InvalidCellDescriptor;
                ref_idx_buf[cell_i * 4 + ref_i] = ref_idx;
                offset += cell_index_bytes;
            }

            cell_buf[cell_i] = .{
                .T = cell_type,
                .Data = cell_data,
                .data_bit_len = bit_len,
                .References = .{ null, null, null, null },
                .level = level,
            };
        }

        // Wire up references now that all Cell structs are in their final locations.
        for (0..cell_count) |cell_i| {
            for (0..ref_count_buf[cell_i]) |ref_i| {
                cell_buf[cell_i].References[ref_i] = &cell_buf[ref_idx_buf[cell_i * 4 + ref_i]];
            }
        }

        // Build the pointer array that BoC.cells exposes.
        const cells_out = try allocator.alloc(*Cell, cell_count);
        errdefer allocator.free(cells_out);
        for (0..cell_count) |cell_i| cells_out[cell_i] = &cell_buf[cell_i];

        return Self{
            .allocator = allocator,
            .cells = cells_out,
            .roots = roots_out,
            .cell_buf = cell_buf,
            .data_buf = data_buf,
        };
    }
};

const testing = std.testing;

test "fromCells empty roots" {
    var roots: [0]*Cell = .{};
    try testing.expectError(ErrBoC.EmptyRoots, BoC.fromCells(testing.allocator, &roots));
}

test "fromCells single leaf" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots = [_]*Cell{&leaf};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    try testing.expectEqual(@as(usize, 1), boc.cells.len);
    try testing.expectEqual(@as(usize, 1), boc.roots.len);
    try testing.expectEqual(@as(usize, 0), boc.roots[0]);
    try testing.expectEqual(&leaf, boc.cells[0]);
}

test "fromCells chain" {
    // leaf -> mid -> root; post-order: leaf(0), mid(1), root(2)
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var mid = Cell.init(.Ordinary, &.{}, 0, .{ &leaf, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &mid, null, null, null });
    var roots = [_]*Cell{&root};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    try testing.expectEqual(@as(usize, 3), boc.cells.len);
    try testing.expectEqual(&leaf, boc.cells[0]);
    try testing.expectEqual(&mid, boc.cells[1]);
    try testing.expectEqual(&root, boc.cells[2]);
    try testing.expectEqual(@as(usize, 2), boc.roots[0]);
}

test "fromCells shared child" {
    // left and right both point to the shared leaf; root points to both
    // post-order: leaf(0), left(1), right(2), root(3)
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var left = Cell.init(.Ordinary, &.{}, 0, .{ &leaf, null, null, null });
    var right = Cell.init(.Ordinary, &.{}, 0, .{ &leaf, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &left, &right, null, null });
    var roots = [_]*Cell{&root};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    try testing.expectEqual(@as(usize, 4), boc.cells.len);
    try testing.expectEqual(&leaf, boc.cells[0]);
    try testing.expectEqual(&left, boc.cells[1]);
    try testing.expectEqual(&right, boc.cells[2]);
    try testing.expectEqual(&root, boc.cells[3]);
    try testing.expectEqual(@as(usize, 3), boc.roots[0]);
}

test "fromCells multiple roots" {
    // two independent leaves; each is a root
    var a = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var b_cell = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots = [_]*Cell{ &a, &b_cell };
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    try testing.expectEqual(@as(usize, 2), boc.cells.len);
    try testing.expectEqual(@as(usize, 0), boc.roots[0]);
    try testing.expectEqual(@as(usize, 1), boc.roots[1]);
}

test "fromCells too many cells" {
    const cell_count = boc_cells_max + 1;
    const cells = try testing.allocator.alloc(Cell, cell_count);
    defer testing.allocator.free(cells);

    cells[0] = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    for (1..cell_count) |i| {
        cells[i] = Cell.init(.Ordinary, &.{}, 0, .{ &cells[i - 1], null, null, null });
    }
    var roots = [_]*Cell{&cells[cell_count - 1]};
    try testing.expectError(ErrBoC.TooManyCells, BoC.fromCells(testing.allocator, &roots));
}

// serializedSize ---------------------------------------------------------------

test "serializedSize single leaf" {
    // cell_index_bytes=1, tot_cells=2 (d1+d2, no data, no refs), offset_bytes=1
    // 4 + 1 + 1 + 3*1 + 1 + 1*1 + 2 = 13
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots = [_]*Cell{&leaf};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();
    try testing.expectEqual(@as(usize, 13), boc.serializedSize());
}

test "serializedSize chain two cells" {
    // cell_index_bytes=1, leaf=2B, root=2+1=3B, tot=5, offset_bytes=1
    // 4+1+1+3+1+1+5 = 16
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &leaf, null, null, null });
    var roots = [_]*Cell{&root};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();
    try testing.expectEqual(@as(usize, 16), boc.serializedSize());
}

// serialize --------------------------------------------------------------------

test "serialize single leaf header and cell data" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots = [_]*Cell{&leaf};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    var buf: [64]u8 = undefined;
    const byte_count = try boc.serialize(&buf);
    try testing.expectEqual(boc.serializedSize(), byte_count);

    // magic
    try testing.expectEqualSlices(u8, &.{ 0xb5, 0xee, 0x9c, 0x72 }, buf[0..4]);
    try testing.expectEqual(@as(u8, 0x01), buf[4]); // flags: cell_index_bytes=1
    try testing.expectEqual(@as(u8, 0x01), buf[5]); // off_bytes: offset_bytes=1
    try testing.expectEqual(@as(u8, 0x01), buf[6]); // cells_count=1
    try testing.expectEqual(@as(u8, 0x01), buf[7]); // roots_count=1
    try testing.expectEqual(@as(u8, 0x00), buf[8]); // absent=0
    try testing.expectEqual(@as(u8, 0x02), buf[9]); // tot_cells_size=2
    try testing.expectEqual(@as(u8, 0x00), buf[10]); // root_list[0]=0
    try testing.expectEqual(@as(u8, 0x00), buf[11]); // cell d1: 0 refs
    try testing.expectEqual(@as(u8, 0x00), buf[12]); // cell d2: 0 bits
}

test "serialize chain reference index" {
    // cells: [leaf(0), root(1)]; root.refs[0] -> leaf -> index 0
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &leaf, null, null, null });
    var roots = [_]*Cell{&root};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    var buf: [32]u8 = undefined;
    const byte_count = try boc.serialize(&buf);
    try testing.expectEqual(@as(usize, 16), byte_count);

    try testing.expectEqual(@as(u8, 0x01), buf[10]); // root_list[0]=1
    // leaf (index 0): d1=0x00 (0 refs), d2=0x00
    try testing.expectEqual(@as(u8, 0x00), buf[11]);
    try testing.expectEqual(@as(u8, 0x00), buf[12]);
    // root (index 1): d1=0x01 (1 ref), d2=0x00, ref_idx=0
    try testing.expectEqual(@as(u8, 0x01), buf[13]);
    try testing.expectEqual(@as(u8, 0x00), buf[14]);
    try testing.expectEqual(@as(u8, 0x00), buf[15]);
}

test "serialize cell with byte-aligned data" {
    var data = [_]u8{0xAB};
    var cell = Cell.init(.Ordinary, &data, 8, .{ null, null, null, null });
    var roots = [_]*Cell{&cell};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    var buf: [64]u8 = undefined;
    const byte_count = try boc.serialize(&buf);
    try testing.expectEqual(boc.serializedSize(), byte_count);

    // cell data starts at offset 11 (4+1+1+1+1+1+1+1)
    try testing.expectEqual(@as(u8, 0x00), buf[11]); // d1: 0 refs
    try testing.expectEqual(@as(u8, 0x02), buf[12]); // d2: floor(8/8)+ceil(8/8)=2
    try testing.expectEqual(@as(u8, 0xAB), buf[13]); // data
}

test "serialize cell with non-byte-aligned data sets completion tag" {
    var data = [_]u8{0xF0}; // top 4 bits are data
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var roots = [_]*Cell{&cell};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    var buf: [64]u8 = undefined;
    _ = try boc.serialize(&buf);

    // d2 = ceil(4/8) = 1 (non-byte-aligned: floor+ceil = 0+1 = 1)
    try testing.expectEqual(@as(u8, 0x01), buf[12]);
    // data byte: 0xF0 with completion tag at bit 3 => 0xF0 | 0x08 = 0xF8
    try testing.expectEqual(@as(u8, 0xF8), buf[13]);
}

test "serialize multiple roots" {
    var a = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var c = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots = [_]*Cell{ &a, &c };
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    var buf: [64]u8 = undefined;
    const byte_count = try boc.serialize(&buf);
    try testing.expectEqual(boc.serializedSize(), byte_count);

    // roots_count=2
    try testing.expectEqual(@as(u8, 0x02), buf[7]);
    // root_list[0]=0, root_list[1]=1
    try testing.expectEqual(@as(u8, 0x00), buf[10]);
    try testing.expectEqual(@as(u8, 0x01), buf[11]);
}

test "serialize serializedSize matches actual output" {
    // diamond DAG: two parents sharing one child
    var shared = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var left = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var right = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &left, &right, null, null });
    var roots = [_]*Cell{&root};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    const expected = boc.serializedSize();
    const buf = try testing.allocator.alloc(u8, expected);
    defer testing.allocator.free(buf);
    const actual = try boc.serialize(buf);
    try testing.expectEqual(expected, actual);
}

test "serialize buffer too small returns error" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots = [_]*Cell{&leaf};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    var buf: [5]u8 = undefined;
    try testing.expectError(ErrBoC.BufferTooSmall, boc.serialize(&buf));
}

// fromBytes --------------------------------------------------------------------

fn serializeToHeap(allocator: Allocator, boc: *const BoC) ![]u8 {
    const buf = try allocator.alloc(u8, boc.serializedSize());
    errdefer allocator.free(buf);
    _ = try boc.serialize(buf);
    return buf;
}

test "serializeIndexed has_idx bit and index table" {
    // single leaf: cell_index_bytes=1, tot=2, offset_bytes=1
    // serializedSizeIndexed = 13 (base) + 1 (index table) = 14
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots = [_]*Cell{&leaf};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    try testing.expectEqual(@as(usize, 14), boc.serializedSizeIndexed());

    var buf: [64]u8 = undefined;
    const byte_count = try boc.serializeIndexed(&buf);
    try testing.expectEqual(@as(usize, 14), byte_count);

    // flags byte: has_idx (bit7) | cell_index_bytes=1 → 0x81
    try testing.expectEqual(@as(u8, 0x81), buf[4]);
    // index table is after root_list (offset 11): single entry = 2 (leaf takes 2 bytes)
    try testing.expectEqual(@as(u8, 0x02), buf[11]);
    // cell data starts at offset 12
    try testing.expectEqual(@as(u8, 0x00), buf[12]); // d1
    try testing.expectEqual(@as(u8, 0x00), buf[13]); // d2
}

test "serializeIndexed chain index table entries" {
    // chain: leaf(0) + root(1); cell_index_bytes=1, leaf=2B, root=3B, tot=5, offset_bytes=1
    // index table: [2, 5]  (cumulative offsets)
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &leaf, null, null, null });
    var roots = [_]*Cell{&root};
    var boc = try BoC.fromCells(testing.allocator, &roots);
    defer boc.deinit();

    var buf: [64]u8 = undefined;
    _ = try boc.serializeIndexed(&buf);

    // root_list ends at offset 11; index table starts there
    try testing.expectEqual(@as(u8, 0x02), buf[11]); // end of cell[0]: 2
    try testing.expectEqual(@as(u8, 0x05), buf[12]); // end of cell[1]: 2+3=5
}

test "serializeIndexed round-trip via fromBytes" {
    var shared = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var left = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var right = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &left, &right, null, null });
    var roots_in = [_]*Cell{&root};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try testing.allocator.alloc(u8, boc1.serializedSizeIndexed());
    defer testing.allocator.free(buf);
    _ = try boc1.serializeIndexed(buf);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();

    try testing.expectEqual(@as(usize, 4), boc2.cells.len);
    const r = boc2.cells[3];
    try testing.expectEqual(r.References[0].?.References[0].?, r.References[1].?.References[0].?);
}

test "serializeIndexedCrc round-trip via fromBytes" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots_in = [_]*Cell{&leaf};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try testing.allocator.alloc(u8, boc1.serializedSizeIndexedCrc());
    defer testing.allocator.free(buf);
    _ = try boc1.serializeIndexedCrc(buf);

    // flags byte must have both has_idx (bit7) and has_crc32c (bit6) set
    try testing.expectEqual(@as(u8, 0x81 | 0x40), buf[4]);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();
    try testing.expectEqual(@as(usize, 1), boc2.cells.len);
    try testing.expectEqual(@as(usize, 0), boc2.roots[0]);
}

test "fromBytes round-trip single leaf" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots_in = [_]*Cell{&leaf};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try serializeToHeap(testing.allocator, &boc1);
    defer testing.allocator.free(buf);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();

    try testing.expectEqual(@as(usize, 1), boc2.cells.len);
    try testing.expectEqual(@as(usize, 0), boc2.roots[0]);
    try testing.expectEqual(@as(usize, 0), boc2.cells[0].data_bit_len);
    try testing.expect(boc2.cells[0].References[0] == null);
}

test "fromBytes round-trip chain wires references" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &leaf, null, null, null });
    var roots_in = [_]*Cell{&root};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try serializeToHeap(testing.allocator, &boc1);
    defer testing.allocator.free(buf);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();

    try testing.expectEqual(@as(usize, 2), boc2.cells.len);
    // root is at index 1, its first reference should point to leaf at index 0
    const deserialized_root = boc2.cells[1];
    try testing.expect(deserialized_root.References[0] != null);
    try testing.expectEqual(boc2.cells[0], deserialized_root.References[0].?);
    try testing.expect(deserialized_root.References[1] == null);
}

test "fromBytes round-trip with byte-aligned data" {
    var data = [_]u8{ 0xDE, 0xAD };
    var cell = Cell.init(.Ordinary, &data, 16, .{ null, null, null, null });
    var roots_in = [_]*Cell{&cell};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try serializeToHeap(testing.allocator, &boc1);
    defer testing.allocator.free(buf);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();

    try testing.expectEqual(@as(usize, 16), boc2.cells[0].data_bit_len);
    try testing.expectEqual(@as(u8, 0xDE), boc2.cells[0].Data[0]);
    try testing.expectEqual(@as(u8, 0xAD), boc2.cells[0].Data[1]);
}

test "fromBytes round-trip non-byte-aligned data" {
    var data = [_]u8{0xF0}; // top 4 bits are the payload
    var cell = Cell.init(.Ordinary, &data, 4, .{ null, null, null, null });
    var roots_in = [_]*Cell{&cell};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try serializeToHeap(testing.allocator, &boc1);
    defer testing.allocator.free(buf);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();

    try testing.expectEqual(@as(usize, 4), boc2.cells[0].data_bit_len);
    try testing.expectEqual(@as(u8, 0xF0), boc2.cells[0].Data[0]);
}

test "fromBytes round-trip diamond DAG" {
    var shared = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var left = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var right = Cell.init(.Ordinary, &.{}, 0, .{ &shared, null, null, null });
    var root = Cell.init(.Ordinary, &.{}, 0, .{ &left, &right, null, null });
    var roots_in = [_]*Cell{&root};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try serializeToHeap(testing.allocator, &boc1);
    defer testing.allocator.free(buf);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();

    // cells: shared(0), left(1), right(2), root(3)
    try testing.expectEqual(@as(usize, 4), boc2.cells.len);
    const r = boc2.cells[3];
    const l = r.References[0].?;
    const ri = r.References[1].?;
    // both left and right must reference the same shared cell
    try testing.expectEqual(l.References[0].?, ri.References[0].?);
}

test "fromBytes error invalid magic" {
    var buf = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00 };
    try testing.expectError(ErrBoC.InvalidMagic, BoC.fromBytes(testing.allocator, &buf));
}

test "fromBytes error buffer too small" {
    const buf = [_]u8{ 0xb5, 0xee };
    try testing.expectError(ErrBoC.BufferTooSmall, BoC.fromBytes(testing.allocator, &buf));
}

test "fromBytes crc32c round-trip" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots_in = [_]*Cell{&leaf};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try testing.allocator.alloc(u8, boc1.serializedSizeCrc());
    defer testing.allocator.free(buf);
    _ = try boc1.serializeCrc(buf);

    var boc2 = try BoC.fromBytes(testing.allocator, buf);
    defer boc2.deinit();
    try testing.expectEqual(@as(usize, 1), boc2.cells.len);
    try testing.expectEqual(@as(usize, 0), boc2.roots[0]);
}

test "fromBytes error invalid checksum" {
    var leaf = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    var roots_in = [_]*Cell{&leaf};
    var boc1 = try BoC.fromCells(testing.allocator, &roots_in);
    defer boc1.deinit();

    const buf = try testing.allocator.alloc(u8, boc1.serializedSizeCrc());
    defer testing.allocator.free(buf);
    _ = try boc1.serializeCrc(buf);
    buf[buf.len - 1] ^= 0xFF; // corrupt the checksum
    try testing.expectError(ErrBoC.InvalidChecksum, BoC.fromBytes(testing.allocator, &buf));
}

test "fromBytes error forward reference" {
    // Craft a minimal 2-cell BoC where cell[0] claims to reference cell[1],
    // violating the topological order invariant (children must come first).
    // Hand-build the bytes: cell_index_bytes=1, offset_bytes=1, n=2, roots=1, root_list=[1]
    // cell[0]: d1=0x01 (1 ref), d2=0x00, ref_idx=1  <- forward ref, invalid
    // cell[1]: d1=0x00, d2=0x00
    const buf = [_]u8{
        0xb5, 0xee, 0x9c, 0x72, // magic
        0x01, // flags (cell_index_bytes=1)
        0x01, // off_bytes (offset_bytes=1)
        0x02, // cells_count=2
        0x01, // roots_count=1
        0x00, // absent=0
        0x05, // tot_cells_size=5 (cell0: 2+1=3, cell1: 2)
        0x01, // root_list[0]=1
        0x01, 0x00, 0x01, // cell[0]: d1=1ref, d2=0, ref_idx=1 (forward!)
        0x00, 0x00, // cell[1]: d1=0, d2=0
    };
    try testing.expectError(cell_mod.ErrCell.InvalidCellDescriptor, BoC.fromBytes(testing.allocator, &buf));
}

fn visitCell(allocator: Allocator, c: *Cell, visited: *std.AutoHashMap(*Cell, usize), list: *std.ArrayList(*Cell)) !void {
    if (visited.contains(c)) return;

    assert(!c.visiting);
    c.visiting = true;
    defer c.visiting = false;

    for (c.References) |ref| {
        const child = ref orelse break;
        try visitCell(allocator, child, visited, list);
    }

    try list.append(allocator, c);
    if (list.items.len > boc_cells_max) return ErrBoC.TooManyCells;

    try visited.put(c, list.items.len - 1);
}
