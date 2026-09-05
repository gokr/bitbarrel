# Research & Design Documents

This directory contains documentation for **historic**, **experimental**, and **future** features of BitBarrel. These documents are preserved for reference but do **not** describe the current, production-ready implementation.

## Files in This Directory

### NIFFLER-STORE-BENCHMARK.md
**Status:** Measured Result (2026-07)
**Purpose:** Benchmark report from Niffler's multi-engine store work — end-to-end
(NATS bus) and in-process (`bench/niffler_store_ops.nim`) numbers for BitBarrel
(bmCritBit) vs SQLite, attributing Niffler's ~2 ms/request floor to the harness
stack (~99.7 %) rather than the engine.

**Context:** Niffler uses BitBarrel as its default store engine and wanted an
honest attribution of a uniform ~2 ms per-request cost. The in-process bench
shows BitBarrel performing the same operations in 2–7 µs — the fastest engine
per point op measured — so the floor is the Nim SDK/NATS request path. Also
documents where SQL engines genuinely win (atomic multi-key writes, one-statement
range scans, fast reopen, WAL disk hygiene).

**Implementation Status:** Bench committed as `bench/niffler_store_ops.nim`

---

### HUGECRITBIT.md
**Status:** Future Design (Proposed)
**Purpose:** Design document for `bmHugeCritBit` mode - a two-barrel approach for scaling to billions of keys while maintaining range query support.

**Context:** This is a forward-looking design for handling extremely large datasets. The proposed `bmHugeCritBit` mode would use two independent barrels with serialized RangeKeyDirs to enable range queries at massive scale.

**Implementation Status:** Not yet implemented

---

### PARTIAL.md
**Status:** Implementation Plan (Proposed)
**Purpose:** Design document for front-truncation compaction using Linux's `FALLOC_FL_COLLAPSE_RANGE` to incrementally reclaim space from large files.

**Context:** This optimization would reduce compaction I/O by truncating empty space from the front of data files without full rewrite. Currently, BitBarrel uses full-file compaction.

**Implementation Status:** Planned enhancement, not yet implemented

---

### REFERENCES.md
**Status:** Advanced Feature (Functional but Specialized)
**Purpose:** Documents the "Reference Model" for graph-like traversal capabilities using JSON-stored references.

**Context:** This feature enables efficient server-side path traversal across stored references (e.g., `friends->team->matches`). It's fully functional but represents an advanced, specialized use case.

**Implementation Status:** Implemented in `/src/bitbarrel/refs.nim` but not prominently featured in core documentation

---

## Why These Files Are Here

These files have been moved from the main `docs/` directory to:

1. **Maintain clarity** about what features are currently implemented and stable
2. **Preserve valuable design work** and historical context
3. **Distinguish** between production features and experimental/future designs
4. **Reduce clutter** in the main documentation set

For information about current, production-ready features, see the main `docs/` directory:

- **TUTORIAL.md** - Complete user guide with practical examples
- **DESIGN.md** - Technical architecture reference (updated with current implementation)
- **ARTICLE.md** - High-level introduction and overview
- **COMPRESSION.md** - Compression implementation details
- **CRC.md** - Data integrity documentation
- **NETWORK_IMPLEMENTATION.md** - Network protocol specification

---

## Access Patterns

- **For new users:** Start with `../TUTORIAL.md`
- **For developers:** Read `../DESIGN.md` for architecture details
- **For feature development:** Review files in this directory for historical context and design ideas
- **For production deployments:** Focus on `../` directory only

---

## Contributing

When working on new features or improvements:

1. **Document in main docs/ if** the feature is production-ready and stable
2. **Document in research/ if** the feature is experimental, planned, or a future design
3. **Update this README** when adding new files to explain their status

---

*Last updated: December 2025*