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

## 3. TL-B (TODO)

TL-B is TON's schema language; types are encoded as bit-packed structures inside cells.

- [ ] Parse TL-B schema definitions (`.tlb` files)
- [ ] Typed serialization: write a Zig value into a cell's bit stream according to a TL-B constructor
- [ ] Typed deserialization: read a cell's bit stream into a Zig value
- [ ] Handle built-in TL-B primitives (`#`, `##n`, `^`, `~`, `bits`, `uint`, etc.)
- [ ] Handle references (`^T`) and conditional fields (`?`)
