//! tlb — TON Blockchain TL-B primitives.
const cell = @import("cell.zig");

pub const MaxCellSizeBits = cell.MaxCellSizeBits;
pub const MaxCellSizeBytes = cell.MaxCellSizeBytes;
pub const MaxCellDepth = cell.MaxCellDepth;
pub const MaxCellSerializedBytes = cell.MaxCellSerializedBytes;
pub const CellT = cell.CellT;
pub const ErrCell = cell.ErrCell;
pub const Cell = cell.Cell;

const boc = @import("boc.zig");

pub const MaxBoCCells = boc.MaxBoCCells;
pub const ErrBoC = boc.ErrBoC;
pub const BoC = boc.BoC;

const slice = @import("slice.zig");

pub const ErrSlice = slice.ErrSlice;
pub const CellSlice = slice.CellSlice;
pub const CellBuilder = slice.CellBuilder;
