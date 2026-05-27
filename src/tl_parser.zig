//! Parser for TL (Type Language) schema files used by ADNL/Liteserver.
const std = @import("std");
const tl_mod = @import("tl.zig");

pub const TlType = tl_mod.TlType;

pub const ErrTlParser = error{
    InvalidSyntax,
    OutOfMemory,
};

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
    var constructors = std.ArrayList(TlConstructor).init(allocator);
    errdefer {
        for (constructors.items) |c| allocator.free(c.fields);
        constructors.deinit();
    }

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "---")) continue;
        if (!std.mem.endsWith(u8, line, ";")) continue;

        const constructor = try parseLine(allocator, line);
        try constructors.append(constructor);
    }

    return constructors.toOwnedSlice();
}

/// Free all memory allocated by `parse`.
pub fn deinit(allocator: std.mem.Allocator, constructors: []TlConstructor) void {
    for (constructors) |c| allocator.free(c.fields);
    allocator.free(constructors);
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) ErrTlParser!TlConstructor {
    const body = std.mem.trimRight(u8, line[0 .. line.len - 1], " \t");

    const eq_pos = std.mem.lastIndexOfScalar(u8, body, '=') orelse return error.InvalidSyntax;
    const fields_part = std.mem.trimRight(u8, body[0..eq_pos], " \t");
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

    var fields = std.ArrayList(TlField).init(allocator);
    errdefer fields.deinit();

    while (tokens.next()) |token| {
        const colon_pos = std.mem.indexOfScalar(u8, token, ':') orelse return error.InvalidSyntax;
        const field_name = token[0..colon_pos];
        const type_str = token[colon_pos + 1 ..];
        if (field_name.len == 0 or type_str.len == 0) return error.InvalidSyntax;
        try fields.append(.{ .name = field_name, .typ = mapType(type_str) });
    }

    return .{
        .name = name,
        .tag = tag,
        .result = result,
        .fields = try fields.toOwnedSlice(),
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
