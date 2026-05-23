//! Benchmarks for BoC.fromCells across different DAG shapes.
const std = @import("std");
const zbench = @import("zbench");
const boc = @import("boc");

const Cell = boc.Cell;
const BoC = boc.BoC;

fn buildChain(cells: []Cell, len: usize) void {
    cells[0] = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    for (1..len) |i| {
        cells[i] = Cell.init(.Ordinary, &.{}, 0, .{ &cells[i - 1], null, null, null });
    }
}

fn buildDiamond(cells: []Cell, width: usize) void {
    cells[0] = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    for (1..width + 1) |i| {
        cells[i] = Cell.init(.Ordinary, &.{}, 0, .{ &cells[0], null, null, null });
    }
    cells[width + 1] = Cell.init(.Ordinary, &.{}, 0, .{
        if (width >= 1) &cells[1] else null,
        if (width >= 2) &cells[2] else null,
        if (width >= 3) &cells[3] else null,
        if (width >= 4) &cells[4] else null,
    });
}

fn benchChain(allocator: std.mem.Allocator) void {
    const len = 512;
    var cells: [len]Cell = undefined;
    buildChain(&cells, len);
    var root_cells = [_]*Cell{&cells[len - 1]};
    var b = BoC.fromCells(allocator, &root_cells) catch return;
    b.deinit();
}

fn benchWide(allocator: std.mem.Allocator) void {
    const width = 512;
    var cells: [width]Cell = undefined;
    for (0..width) |i| {
        cells[i] = Cell.init(.Ordinary, &.{}, 0, .{ null, null, null, null });
    }
    var roots: [width]*Cell = undefined;
    for (0..width) |i| roots[i] = &cells[i];
    var b = BoC.fromCells(allocator, &roots) catch return;
    b.deinit();
}

fn benchDiamond(allocator: std.mem.Allocator) void {
    const width = 4;
    var cells: [width + 2]Cell = undefined;

    buildDiamond(&cells, width);
    var root_cells = [_]*Cell{&cells[width + 1]};
    var b = BoC.fromCells(allocator, &root_cells) catch return;
    b.deinit();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout: std.Io.File = .stdout();

    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("chain/512", benchChain, .{});
    try bench.add("wide/512 ", benchWide, .{});
    try bench.add("diamond/4", benchDiamond, .{});

    try bench.run(io, stdout);
}
