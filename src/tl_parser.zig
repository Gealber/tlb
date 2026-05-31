//! Parser for TL (Type Language) schema files used by ADNL/Liteserver.
const std = @import("std");
const tl_mod = @import("tl.zig");

pub const TlType = tl_mod.TlType;

pub const ErrTlParser = error{
    InvalidSyntax,
    OutOfMemory,
};

/// Returned by `parseLine` for valid-TL-but-unsupported constructs (compound types,
/// array syntax, opaque `?` fields). `parse` skips these silently.
const ErrParseLine = ErrTlParser || error{UnsupportedSyntax};

/// A field type: a primitive we can codec directly, or a named constructor reference.
pub const TlFieldType = union(enum) {
    primitive: TlType,
    named: []const u8,
};

pub const TlField = struct {
    name: []const u8,
    typ: TlFieldType,
};

pub const TlConstructor = struct {
    name: []const u8,
    tag: u32,
    result: []const u8,
    fields: []TlField,
};

/// Parse a `.tl` source string into an owned slice of constructors.
/// All string slices point into `source`; keep `source` alive as long as the result is in use.
/// Multi-line declarations (lines not ending with `;`) are silently skipped.
/// Call `deinit` to free allocated memory.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ErrTlParser![]TlConstructor {
    var constructors = std.ArrayList(TlConstructor).empty;
    errdefer {
        for (constructors.items) |c| allocator.free(c.fields);
        constructors.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "---")) continue;
        if (!std.mem.endsWith(u8, line, ";")) continue;
        if (std.mem.startsWith(u8, line, "=")) continue;

        const constructor = parseLine(allocator, line) catch |err| switch (err) {
            error.UnsupportedSyntax => continue,
            else => |e| return e,
        };
        try constructors.append(allocator, constructor);
    }

    return constructors.toOwnedSlice(allocator);
}

/// Free all memory allocated by `parse`.
pub fn deinit(allocator: std.mem.Allocator, constructors: []TlConstructor) void {
    for (constructors) |c| allocator.free(c.fields);
    allocator.free(constructors);
}

/// Returns the 4-byte constructor tag for a TL declaration line.
/// If the declaration has an explicit `#xxxxxxxx` tag it is returned directly.
/// Otherwise the CRC32 over the canonical form is computed:
///   "name field:type ... = Result"  (space-normalised, no `#tag`, no `;`)
/// The trailing semicolon is optional.
pub fn computeTag(schema: []const u8) u32 {
    const s = std.mem.trimEnd(u8, schema, " \t\r\n");
    const body = if (std.mem.endsWith(u8, s, ";")) s[0 .. s.len - 1] else s;

    var toks = std.mem.tokenizeScalar(u8, body, ' ');
    const name_tag = toks.next() orelse return 0;

    const name: []const u8 = if (std.mem.indexOfScalar(u8, name_tag, '#')) |h| blk: {
        const tag_str = name_tag[h + 1 ..];
        if (tag_str.len > 0)
            return std.fmt.parseInt(u32, tag_str, 16) catch 0;
        break :blk name_tag[0..h];
    } else name_tag;

    var crc = std.hash.crc.Crc32.init();
    crc.update(name);
    while (toks.next()) |tok| {
        crc.update(" ");
        crc.update(tok);
    }
    return crc.final();
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) ErrParseLine!TlConstructor {
    const body = std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");

    const eq_pos = std.mem.lastIndexOfScalar(u8, body, '=') orelse return error.InvalidSyntax;
    const fields_part = std.mem.trimEnd(u8, body[0..eq_pos], " \t");
    const result = std.mem.trim(u8, body[eq_pos + 1 ..], " \t");
    if (result.len == 0) return error.InvalidSyntax;

    var tokens = std.mem.tokenizeScalar(u8, fields_part, ' ');
    const name_tag = tokens.next() orelse return error.InvalidSyntax;

    var name: []const u8 = undefined;
    var tag: u32 = 0;
    if (std.mem.indexOfScalar(u8, name_tag, '#')) |hash_pos| {
        name = name_tag[0..hash_pos];
        const tag_str = name_tag[hash_pos + 1 ..];
        if (tag_str.len > 0)
            tag = std.fmt.parseInt(u32, tag_str, 16) catch return error.InvalidSyntax;
    } else {
        name = name_tag;
    }
    if (name.len == 0) return error.InvalidSyntax;

    if (tag == 0) tag = computeTag(line);

    var fields = std.ArrayList(TlField).empty;
    errdefer fields.deinit(allocator);

    while (tokens.next()) |token| {
        const colon_pos = std.mem.indexOfScalar(u8, token, ':') orelse return error.UnsupportedSyntax;
        const field_name = token[0..colon_pos];
        const type_str = token[colon_pos + 1 ..];
        if (field_name.len == 0 or type_str.len == 0) return error.InvalidSyntax;
        try fields.append(allocator, .{ .name = field_name, .typ = mapType(type_str) });
    }

    return .{
        .name = name,
        .tag = tag,
        .result = result,
        .fields = try fields.toOwnedSlice(allocator),
    };
}

fn mapType(type_str: []const u8) TlFieldType {
    if (std.mem.eql(u8, type_str, "int")) return .{ .primitive = .int };
    if (std.mem.eql(u8, type_str, "long")) return .{ .primitive = .long };
    if (std.mem.eql(u8, type_str, "int128")) return .{ .primitive = .int128 };
    if (std.mem.eql(u8, type_str, "int256")) return .{ .primitive = .int256 };
    if (std.mem.eql(u8, type_str, "bytes")) return .{ .primitive = .bytes };
    if (std.mem.eql(u8, type_str, "string")) return .{ .primitive = .bytes };
    if (std.mem.eql(u8, type_str, "Bool")) return .{ .primitive = .bool };
    if (std.mem.eql(u8, type_str, "#")) return .{ .primitive = .int };
    return .{ .named = type_str };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "parse blockIdExt declaration" {
    const src =
        \\tonNode.blockIdExt#b399d6db workchain:int shard:long seqno:int root_hash:int256 file_hash:int256 = tonNode.BlockIdExt;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const c = result[0];
    try std.testing.expectEqualStrings("tonNode.blockIdExt", c.name);
    try std.testing.expectEqual(@as(u32, 0xb399d6db), c.tag);
    try std.testing.expectEqualStrings("tonNode.BlockIdExt", c.result);
    try std.testing.expectEqual(@as(usize, 5), c.fields.len);

    try std.testing.expectEqualStrings("workchain", c.fields[0].name);
    try std.testing.expectEqual(TlType.int, c.fields[0].typ.primitive);
    try std.testing.expectEqualStrings("shard", c.fields[1].name);
    try std.testing.expectEqual(TlType.long, c.fields[1].typ.primitive);
    try std.testing.expectEqualStrings("seqno", c.fields[2].name);
    try std.testing.expectEqual(TlType.int, c.fields[2].typ.primitive);
    try std.testing.expectEqual(TlType.int256, c.fields[3].typ.primitive);
    try std.testing.expectEqual(TlType.int256, c.fields[4].typ.primitive);
}

test "parse named field type" {
    const src =
        \\liteServer.blockData#1684ac0f id:tonNode.blockIdExt data:bytes = liteServer.BlockData;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const c = result[0];
    try std.testing.expectEqualStrings("liteServer.blockData", c.name);
    try std.testing.expectEqual(@as(u32, 0x1684ac0f), c.tag);
    try std.testing.expectEqual(@as(usize, 2), c.fields.len);

    try std.testing.expectEqualStrings("tonNode.blockIdExt", c.fields[0].typ.named);
    try std.testing.expectEqual(TlType.bytes, c.fields[1].typ.primitive);
}

test "parse string maps to bytes" {
    const src =
        \\liteServer.error#bba9a764 code:int message:string = liteServer.Error;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(TlType.bytes, result[0].fields[1].typ.primitive);
}

test "parse multiple declarations with comments and blank lines" {
    const src =
        \\// This is a comment
        \\
        \\tonNode.blockIdExt#b399d6db workchain:int shard:long seqno:int root_hash:int256 file_hash:int256 = tonNode.BlockIdExt;
        \\
        \\// Another comment
        \\liteServer.error#bba9a764 code:int message:string = liteServer.Error;
        \\liteServer.masterchainInfo#7ee0c901 last:tonNode.blockIdExt state_root_hash:int256 init:tonNode.zeroStateIdExt = liteServer.MasterchainInfo;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("tonNode.blockIdExt", result[0].name);
    try std.testing.expectEqualStrings("liteServer.error", result[1].name);
    try std.testing.expectEqualStrings("liteServer.masterchainInfo", result[2].name);
}

test "parse skips section separators" {
    const src =
        \\---types---
        \\liteServer.error#bba9a764 code:int message:string = liteServer.Error;
        \\---functions---
        \\liteServer.getTime#8a12b9a7 = liteServer.CurrentTime;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("liteServer.error", result[0].name);
    try std.testing.expectEqualStrings("liteServer.getTime", result[1].name);
}

test "parse no-field declaration" {
    const src =
        \\liteServer.getTime#8a12b9a7 = liteServer.CurrentTime;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 0), result[0].fields.len);
    try std.testing.expectEqualStrings("liteServer.CurrentTime", result[0].result);
}

test "parse InvalidSyntax on missing equals" {
    const src = "bad line no equals;\n";
    const result = parse(std.testing.allocator, src);
    try std.testing.expectError(error.InvalidSyntax, result);
}

test "parse skips multi-line declarations silently" {
    const src =
        \\liteServer.error#bba9a764 code:int message:string = liteServer.Error;
        \\liteServer.runMethodResult mode:#
        \\  id:tonNode.blockIdExt exit_code:int
        \\  = liteServer.RunMethodResult;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);

    // Only the single-line declaration is parsed
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("liteServer.error", result[0].name);
}

test "CRC32 tag: explicit tag is preserved as-is" {
    // tonNode.blockIdExt has explicit #b399d6db — use it, don't recompute
    const src =
        \\tonNode.blockIdExt#b399d6db workchain:int shard:long seqno:int root_hash:int256 file_hash:int256 = tonNode.BlockIdExt;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);
    try std.testing.expectEqual(@as(u32, 0xb399d6db), result[0].tag);
}

test "CRC32 tag: Telegram base types match known CRC32 values" {
    // These are ground-truth values from Telegram's TL spec
    const src =
        \\boolFalse = Bool;
        \\boolTrue = Bool;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 0xbc799737), result[0].tag);
    try std.testing.expectEqual(@as(u32, 0x997275b5), result[1].tag);
}

test "CRC32 tag: untagged constructor gets CRC32 computed" {
    // adnl.id.short id:int256 = adnl.id.Short  (no explicit tag)
    const src =
        \\adnl.id.short id:int256 = adnl.id.Short;
        \\adnl.address.udp ip:int port:int = adnl.Address;
        \\tcp.pong random_id:long = tcp.Pong;
    ;
    const result = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u32, 0x3e3f654f), result[0].tag);
    try std.testing.expectEqual(@as(u32, 0x670da6e7), result[1].tag);
    try std.testing.expectEqual(@as(u32, 0xdc69fb03), result[2].tag);
}

// ── computeTag tests ───────────────────────────────────────────────────────────

test "computeTag: explicit tag is returned as-is" {
    try std.testing.expectEqual(
        @as(u32, 0xb399d6db),
        computeTag("tonNode.blockIdExt#b399d6db workchain:int shard:long seqno:int root_hash:int256 file_hash:int256 = tonNode.BlockIdExt;"),
    );
}

test "computeTag: CRC32 computed for untagged declaration" {
    try std.testing.expectEqual(@as(u32, 0x3e3f654f), computeTag("adnl.id.short id:int256 = adnl.id.Short;"));
    try std.testing.expectEqual(@as(u32, 0x670da6e7), computeTag("adnl.address.udp ip:int port:int = adnl.Address;"));
    try std.testing.expectEqual(@as(u32, 0xdc69fb03), computeTag("tcp.pong random_id:long = tcp.Pong;"));
}

test "computeTag: trailing semicolon is optional" {
    const with = computeTag("adnl.id.short id:int256 = adnl.id.Short;");
    const without = computeTag("adnl.id.short id:int256 = adnl.id.Short");
    try std.testing.expectEqual(with, without);
}

test "computeTag: Telegram base types match known CRC32 values" {
    try std.testing.expectEqual(@as(u32, 0xbc799737), computeTag("boolFalse = Bool;"));
    try std.testing.expectEqual(@as(u32, 0x997275b5), computeTag("boolTrue = Bool;"));
}

test "computeTag: result matches tag produced by parse" {
    const src = "adnl.id.short id:int256 = adnl.id.Short;";
    const constructors = try parse(std.testing.allocator, src);
    defer deinit(std.testing.allocator, constructors);
    try std.testing.expectEqual(constructors[0].tag, computeTag(src));
}
