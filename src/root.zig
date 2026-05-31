//! tlb — TON Blockchain TL-B primitives.
const cell = @import("cell.zig");

pub const cell_size_bits_max = cell.cell_size_bits_max;
pub const cell_size_bytes_max = cell.cell_size_bytes_max;
pub const cell_depth_max = cell.cell_depth_max;
pub const cell_serialized_bytes_max = cell.cell_serialized_bytes_max;
pub const CellT = cell.CellT;
pub const ErrCell = cell.ErrCell;
pub const Cell = cell.Cell;

const boc = @import("boc.zig");

pub const boc_cells_max = boc.boc_cells_max;
pub const ErrBoC = boc.ErrBoC;
pub const BoC = boc.BoC;

const slice = @import("slice.zig");

pub const ErrSlice = slice.ErrSlice;
pub const CellSlice = slice.CellSlice;
pub const CellBuilder = slice.CellBuilder;

const tlb = @import("tlb.zig");

pub const ErrTlb = tlb.ErrTlb;
pub const TlbType = tlb.TlbType;
pub const BitsVal = tlb.BitsVal;
pub const TlbValue = tlb.TlbValue;
pub const store = tlb.store;
pub const load = tlb.load;
pub const storeSchema = tlb.storeSchema;
pub const loadSchema = tlb.loadSchema;

const tl = @import("tl.zig");

pub const tl_bool_true = tl.tl_bool_true;
pub const tl_bool_false = tl.tl_bool_false;
pub const ErrTl = tl.ErrTl;
pub const TlType = tl.TlType;
pub const TlValue = tl.TlValue;
pub const TlReader = tl.TlReader;
pub const tlEncode = tl.encode;
pub const encodeSchema = tl.encodeSchema;
pub const decodeSchema = tl.decodeSchema;

const tl_parser = @import("tl_parser.zig");

pub const ErrTlParser = tl_parser.ErrTlParser;
pub const TlFieldType = tl_parser.TlFieldType;
pub const TlField = tl_parser.TlField;
pub const TlConstructor = tl_parser.TlConstructor;
pub const tlParse = tl_parser.parse;
pub const tlParserDeinit = tl_parser.deinit;
pub const tlComputeTag = tl_parser.computeTag;
