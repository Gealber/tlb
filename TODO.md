# tlb — Implementation Roadmap

## 1. Cell (done)

- [x] `Cell.serialize` — standard cell representation (d1/d2 descriptors, data, reference depths, reference hashes)
- [x] `Cell.deserialize` — parses descriptor bytes, strips completion tag, detects exotic cell type via `data[0]`
- [x] `Cell.computeHash` — SHA-256 over serialized form
- [x] `Cell.depth` — recursive depth with cycle detection and `MaxCellDepth` guard

**Known limitations:**
- `deserialize` leaves `References` as null; a BoC deserializer is needed to wire up cross-references by hash.
- `level` field for exotic cells (PrunedBranch, MerkleProof, MerkleUpdate) is always 0; level mask derivation from references is not yet implemented.

## 2. Bag of Cells (done)

A BoC is the standard container for transmitting one or more cells over the wire (transactions, blocks, messages).

- [x] `BoC.fromCells` — post-order DFS, deduplicates shared cells, resolves root indices
- [x] `BoC.serialize` — writes magic, flags, variable-width header, root list, flat cell array with index-based references
- [x] `BoC.fromBytes` — parses header, deserializes flat cell array, wires `*Cell` references by index, validates topological order
- [x] Support indexed BoC variant: `serializeIndexed` / `serializeIndexedCrc` emit `has_idx=1` with a cumulative-offset index table; `fromBytes` parses and skips it
- [x] CRC32C: `serializeCrc` emits `has_crc32c=1` with a 4-byte LE trailer; `fromBytes` verifies it

## 3. TL-B primitives (done)

TL-B is TON's bit-packed cell encoding schema language.

- [x] `store` / `load` — single primitive codec (`TlbType`: uint/int/bits/bool/ref)
- [x] `storeSchema` / `loadSchema` — encode/decode a flat sequence of typed fields

**Known limitations:**
- No `.tlb` file parser — schema is constructed manually in Zig
- No support for conditional fields (`?`), type variables, or combinators

## 4. TL codec (done)

TL (Type Language) is the byte-aligned RPC encoding used by ADNL and Liteserver.

- [x] `encode` / `TlReader.decode` — single primitive codec (`TlType`: int/long/int128/int256/bytes/bool)
- [x] `encodeSchema` / `decodeSchema` — encode/decode a flat sequence of typed fields
- [x] `bytes` encoding: short form (<254 bytes) and long form (≥254 bytes, `0xFE` prefix), 4-byte-aligned
- [x] `bool` encoding: 4-byte CRC32 tags (`tl_bool_true = 0x997275b5`, `tl_bool_false = 0xbc799737`)

## 5. TL parser (done)

- [x] Parse `.tl` schema files into `[]TlConstructor` (name, CRC32 tag, result type, `[]TlField`)
- [x] Map primitive type strings to `TlType`; unrecognized types stored as `.named` references
- [x] Skip blank lines, `//` comments, `---` section separators, and multi-line declarations

**Known limitations:**
- Conditional fields (`flags.N?Type`) not implemented — needed for `runMethodResult`, `adnl.packetContents`
- Multi-line `.tl` declarations silently skipped (affects complex flag-using types only)
- No type resolver: `.named` references in parsed constructors not auto-expanded to flat `[]TlType`
