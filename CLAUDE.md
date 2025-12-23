# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BitBarrel is a high-performance Bitcask-style key-value storage engine written in Nim. It provides:
- Append-only log files with O(1) reads via in-memory hash index
- CRC32 data integrity verification
- Crash recovery with hint files for fast startup (40K+ keys/sec)
- Background compaction with threading
- Configurable durability (immediate, buffered, batched, time-based sync modes)
- Write buffering and read-ahead caching

**Current Status**: Core implementation complete with advanced features - ready for production use.

## Build Commands

```bash
nimble install           # Install dependencies
nimble build             # Build the bitbarrel binary
nimble test              # Run all tests (25 test files)
nimble clean             # Remove generated data files and binaries

# Specific test suites
nimble testStorage       # Storage layer tests
nimble testKeydir        # KeyDir index tests
nimble testIntegration   # Integration tests
nimble testRecovery      # Recovery system tests

# Demos
nimble demoBasic         # Basic CRUD operations
nimble demoSample        # Detailed key-value demo
nimble demoTuning        # Performance tuning demo

# Benchmarks
nimble bench             # Default benchmark
nimble benchQuick        # Quick benchmark (1K ops)
nimble benchComprehensive # Extended benchmark (100K ops)
nimble stress            # Stress testing
```

## Testing

Tests use Nim's `unittest` module. Located in `tests/`:

| Test File | Coverage |
|-----------|----------|
| `test_storage.nim` | Data file format, header, append/read |
| `test_record.nim` | Record encoding/decoding, CRC32, tombstones |
| `test_keydir.nim` | KeyDir operations, threading |
| `test_integration.nim` | GET/SET/DELETE workflow, persistence |
| `test_error_handling.nim` | Corruption detection, boundary conditions |
| `test_recovery.nim` | Recovery engine, checkpoints, hint files |
| `test_compact.nim` | Compaction system tests |
| `test_writebuffer.nim` | Write buffer sync modes |
| `test_readbuffer.nim` | Read buffering/caching |
| `test_hintfile.nim` | Hint file I/O |

Run individual tests directly: `nim c -r tests/test_storage.nim`

## Architecture

### Layered Design

```
┌─────────────────────────────────────────────┐
│  Barrel API (src/bitbarrel/barrel.nim)          │  High-level: open/get/set/delete
├─────────────────────────────────────────────┤
│  LowLevelAPI (src/bitbarrel/lowlevelapi.nim)      │  Direct storage access
├─────────────────────────────────────────────┤
│  Storage Engine (src/storage/)              │  Bitcask implementation
└─────────────────────────────────────────────┘
```

### Storage Engine Components

| Module | Purpose |
|--------|---------|
| `keydir.nim` | In-memory hash index (key → file position) |
| `datafile.nim` | Append-only file I/O with headers |
| `record.nim` | Binary record format: `[CRC32][timestamp][keyLen][key][valLen][value]` |
| `compact.nim` | Single-file compaction system |
| `recovery.nim` | Crash recovery, KeyDir reconstruction |
| `hintfile.nim` | Fast recovery metadata (key positions only) |
| `writebuffer.nim` | Write batching with 4 sync modes |
| `checkpoint.nim` | KeyDir snapshots (full/incremental) |

### Bitcask Model

1. **Writes**: Append to active data file, update KeyDir in memory
2. **Reads**: KeyDir lookup (O(1)) → single disk seek + read
3. **Deletes**: Write tombstone record (empty value)
4. **Compaction**: Background process eliminates tombstones and expired records

### Index Modes

BitBarrel supports three indexing modes, each optimized for different use cases:

#### bmHash (Default)
- Hash table index with O(1) lookups
- ~50 bytes memory per key
- Keys not ordered
- Fastest for simple get/set operations
- **Limitation**: No range query support

#### bmCritBit (Ordered)
- CritBit tree with O(k) lookup where k = key length
- Keys stored in lexicographic sorted order
- **Supports range queries and prefix searches**
- Ideal for ordered traversal and pagination
- Use when you need: range queries, prefix searches, ordered iteration

#### bmHugeCritBit (Two-tier for massive datasets)
- Designed for massive datasets with range queries
- Two-tier architecture with range partitioning
- **Status**: Not yet implemented

### Range Queries and Cursor-Based Pagination

**Important**: BitBarrel currently has **no users**, so we do not need to maintain backward compatibility for any API changes. We can freely evolve the API without breaking existing code.

Range queries and pagination are only available in **bmCritBit mode**. This requires configuring the barrel with the ordered index:

```nim
var config = defaultBarrelConfig()
config.mode = bmCritBit
let barrel = openBarrel("data.db", config)
```

#### Range Query Methods

**Get key-value pairs in a range**:
```nim
# Get items with keys in range [startKey, endKey)
let items = barrel.itemsInRange("user:1000", "user:2000", limit=100, cursor="")
# Returns: seq[(string, string)] = @[("user:1001", "Alice"), ...]

# Get next page using cursor
let (page2, nextCursor, hasMore) = barrel.itemsInRange("user:1000", "user:2000", limit=100, cursor="user:1050")
```

**Get key-value pairs with prefix**:
```nim
# Get all users (keys starting with "user:")
let users = barrel.itemsWithPrefix("user:", limit=50, cursor="")
for (key, value) in users:
  echo key, " => ", value
```

#### Cursor-Based Pagination

**Why Cursor-Based?**
- **Efficient**: O(1) operation (no scanning/skipping like offset-based)
- **Scalable**: Works well for large datasets
- **Simple**: Use last key from previous page as cursor

**Pagination Flow**:
1. First page: `itemsWithPrefix("user:", limit=100, cursor="")`
2. Get response: `(items, nextCursor, hasMore)`
3. Next page: `itemsWithPrefix("user:", limit=100, cursor=nextCursor)`
4. Repeat until `hasMore = false`

**Example - Paginate through all users**:
```nim
var allUsers: seq[(string, string)]
var cursor = ""
while true:
  let (items, nextCursor, hasMore) = barrel.itemsWithPrefix("user:", 100, cursor)
  if items.len == 0:
    break
  allUsers.add(items)
  if not hasMore:
    break
  cursor = nextCursor
```

**Response Format**:
All range query methods return a tuple:
```nim
(items: seq[(string, string)], nextCursor: string, hasMore: bool)
```

- `items`: Key-value pairs in the range
- `nextCursor`: Cursor for next page (empty string if last page)
- `hasMore`: True if more items available

**Iterator Support** (memory-efficient):
```nim
# Iterate over all items in range (loads one page at a time)
for (key, value) in barrel.itemsWithPrefix("user:"):
  echo key, " => ", value
```

## Project Structure

```
src/
├── bitbarrel.nim              # Main library entry point
├── bitbarrel/
│   ├── barrel.nim       # High-level Barrel API
│   ├── lowlevelapi.nim  # Low-level API
│   ├── config.nim       # Configuration types
│   ├── config_parser.nim # YAML/ENV config parsing
│   └── types.nim        # Core type definitions
├── storage/
│   ├── keydir.nim       # In-memory hash index
│   ├── datafile.nim     # Data file management
│   ├── record.nim       # Record serialization
│   ├── compact.nim       # Compaction system
│   ├── recovery.nim     # Crash recovery
│   ├── writebuffer.nim  # Write buffering
│   ├── hintfile.nim     # Hint files
│   └── checkpoint.nim   # KeyDir checkpoints
└── cli/
    └── main.nim         # CLI interface
tests/                   # Test suite (14 files)
bench/                   # Benchmarks and stress tests
examples/                # Demo programs
```

## Code Quality and Testing

### Maintaining Clean Code
Always check for and remove compiler warnings:
- **Unused imports**: Remove imports that are not used (e.g., `Warning: imported and not used`)
- **Unused variables**: Remove variables declared but never used (e.g., `Hint: 'foo' is declared but not used`)
- **Unused parameters**: Use `_` prefix or `_` to indicate intentionally unused variables
- Run tests frequently to catch warnings early

### Test Quality Standards
- **All tests must pass**: Green tests are non-negotiable
- **No warnings in test compilation**: Test code should compile without warnings
- **Tests should run quickly**: Keep tests focused and fast
- **Test names should be descriptive**: Clearly state what is being tested
- **Clean up test data**: Tests should remove temporary files/directories
- **Avoid flaky tests**: Tests should be deterministic and reliable

### When to Ignore Warnings
- Some warnings from dependencies (like Mummy) are unavoidable
- ORC-related crashes during thread shutdown are a known Nim issue
- Document known issues in code comments or CLAUDE.md

### Known Issues
**test_client.nim ORC Crash**: This test shows ORC crash during thread cleanup due to Nim issue #25253. The tests complete successfully before the crash. This is NOT a BitBarrel code issue - it's a confirmed Nim compiler bug with these characteristics:

**Root Cause**: Nim's ORC garbage collector crashes when cleaning up objects with circular references across thread boundaries. The crash happens in `orc.nim:unregisterCycle()` during thread shutdown, after all tests have completed successfully.

**Evidence this is a Nim bug, not BitBarrel code issue**:
1. Crash location: `nim/orc.nim:unregisterCycle()` - deep inside Nim's GC, not our code
2. Stack trace shows: mummy→destroy→ORC cycle detector→SIGSEGV
3. Tests all pass before the crash occurs
4. Non-threaded tests work perfectly (test_session, test_integration, etc.)
5. Simple objects without circular references work fine across threads
6. This matches exactly Nim issue #25253 pattern

**Workarounds Attempted (all failed)**:
- ✅ Changed `BitBarrelServer` from `object` to `ref` to `ptr` - still crashes
- ✅ Added manual destructor to break circular references - still crashes
- ✅ Manually nilled circular references before thread exit - still crashes
- ✅ Used global variables instead of thread parameters - still crashes
- ✅ Tried different thread creation patterns - still crashes
- ✅ Removed all closure captures - not possible (mummy requires closures)

**Why other tests don't crash**:
- `test_session`, `test_integration`: Don't use threads with circular references
- `test_storage`, `test_keydir`: Pure unit tests, no threading
- `test_client`: Uses threads + objects with circular refs → triggers Nim bug

**Status**: Actively being investigated by Nim team. There's an "araq-orc-hotfix" branch in Nim repo suggesting active work on this.

To run tests without this issue:
```bash
nimble testStorage   # Storage layer tests - all pass
nimble testKeydir    # KeyDir index tests - all pass
nimble testIntegration # Integration tests - all pass
nimble testSession    # Session/Registry tests - all pass
```

## Nim Coding Guidelines

### Code Style and Conventions
- Use camelCase, not snake_case (avoid `_` in naming)
- Do not shadow the local `result` variable (Nim built-in)
- Doc comments: `##` below proc signature
- Prefer generics or object variants over methods and type inheritance
- Use `return expression` for early exits
- Prefer direct field access over getters/setters
- **NO `asyncdispatch`** - use threads or taskpools for concurrency
- Remove old code during refactoring
- Import full modules, not selected symbols
- Use `*` to export fields that should be publicly accessible
- When using fmt **ALWAYS** write it as `fmt("...")` not `fmt"..."` (escaped characters)

### Memory Management: var, ref, and ptr

**Nim is Value-Based**: Understanding Nim's value semantics is critical for memory safety.

#### var (Value Types)
- Creates stack-allocated values with copy-on-assignment semantics
- `var x = y` creates a copy of `y` (except for ref/ptr types)
- Use for objects that don't need shared ownership or heap allocation
- Default for most types - safer and more efficient

#### ref (Traced References)
- Garbage-collected heap references (preferred for shared objects)
- Use `new()` to allocate: `var obj = new(MyType)`
- Assignment copies the reference, not the object
- Automatically managed by Nim's garbage collector
- Use when you need shared ownership or want to avoid copying

#### ptr (Untraced Pointers)
- Manually managed memory (unsafe)
- Use with `alloc()`/`dealloc()`: must manage lifetime yourself
- Required for FFI or low-level system programming
- Must call `reset()` on GC objects before deallocating to prevent leaks
- Avoid unless absolutely necessary

#### Common Pitfalls

**NEVER take address of temporary copies:**
```nim
# DANGEROUS - undefined behavior!
proc badExample(): ptr int =
  var x = 42
  var table = {"key": x}
  result = addr table["key"]  # Points to temporary copy!
```

**SAFE patterns:**
```nim
# Store refs directly in containers when sharing is needed
type
  MyStruct = ref object
    data: int

proc safeExample(): Table[string, MyStruct] =
  result = {"key": MyStruct(data: 42)}  # Store ref, not value
```

#### ref Objects Design Pattern

For objects that will frequently be shared or passed around, consider defining them as `ref object` from the start:

```nim
# Good: Natural reference semantics
type
  DataFile = ref object
    handle: File
    size: uint64
    lock: Lock

  # Usage: no wrapping needed
  proc createDataFile(): DataFile =
    result = DataFile(handle: open(...), size: 0)
```

This provides a more Java-esque mental model where objects are naturally heap-allocated and shared via references. Benefits:
- No need to wrap value types in `ref` everywhere
- Cleaner API without constant `[]` dereferencing
- Natural shared ownership semantics
- Less error-prone than manual `ref` wrapping

**Rule of Thumb:**
- Use `var` for stack-local and simple values
- Use `ref object` for types intended to be shared (data structures, files, network connections)
- Use `ref` wrapping only when retrofitting existing value types
- Use `ptr` only for FFI or when you specifically need manual memory management
- Never use `addr` and `cast` to create refs from value types in containers

### Function and Return Style
- **Single-line functions**: Use direct expression without `result =` or `return`
- **Multi-line functions**: Use `result =` assignment and `return` for clarity
- **Early exits**: Use `return value` instead of `result = value; return`
- **Exception handlers**: Use `return expression` for error cases

### Comments and Documentation
- Do not add comments talking about how good something is
- Do not add comments that reflect what has changed (use git)
- Do not add unnecessary commentary or explain self-explanatory code

### Refactoring
- Remove old unused code during refactoring
- Delete deprecated methods, unused types, and obsolete code paths immediately
- Keep the codebase lean and focused

## Thread Safety

The BitBarrel uses threading for background operations (compaction). Key patterns:

### Lock-Protected Data Structures
- **KeyDir**: Uses `Lock` for concurrent access to the hash index
- **DataFile**: Lock-protected file I/O operations
- **WriteBuffer**: Lock + condition variable for worker coordination

### GC Safety Pattern
For threaded code that accesses shared state, use `{.gcsafe.}` blocks:

```nim
proc someThreadedProc*() {.gcsafe.} =
  {.gcsafe.}:
    # Access to shared state that is actually thread-safe
    # but can't be proven so by the compiler
    withLock(keydir.lock):
      keydir.entries[key] = entry
```

Use `{.gcsafe.}:` blocks only when certain the code is actually thread-safe (e.g., lock-protected access).

### Compaction Worker Threading
The compaction system uses atomic flags for shutdown signaling. See `src/storage/compact.nim` for the background worker pattern.

## Documentation Guidelines

### Writing Style
- Use neutral, factual language
- Avoid superlatives and hype words
- Describe features without marketing language
- Focus on implementation details and behavior

### Nim Doc Comment Guidelines

#### Basic Syntax

**Documentation comments** use double hash (`##`):
```nim
## This is a documentation comment - will appear in generated docs
```

**Regular comments** use single hash (`#`):
```nim
# This is a regular comment - will NOT appear in generated docs
```

#### Placement

- **Module docs**: At the top of the file, before imports
- **Type docs**: After the type definition
- **Proc docs**: After the proc signature
- **Field docs**: Using `##` after each field in type definitions

#### Important Rule: Exports

**Documentation will only be generated for exported types/procedures/etc.**

Use `*` following the name to export:
```nim
type Record* = object    ## Will generate docs for Record (exported)
type Person = object     ## Will NOT generate docs for Person (not exported)

proc open*(path: string): DataFile =  ## Will generate docs (exported)
proc close(path: string) =            ## Will NOT generate docs (not exported)
```

#### Standard Sections

**Description**: First line or first paragraph
```nim
proc len*(keyDir: var KeyDir): int =
  ## Get the number of entries in the KeyDir
```

**Parameters**: Inline format (Nim stdlib style)
```nim
## limit: Maximum number of items to return (default: 1000)
## cursor: Last key from previous page (empty string for first page)
```

**Returns**: Inline description
```nim
## Returns the number of records recovered
```

**Or explicit Returns section**:
```nim
## Returns: (live_records, total_records, fragmentation_ratio)
```

**Code Examples**: Using `**Example:**` with code blocks
```nim
## **Example:**
## ```nim
## var t = {"name": "John", "city": "Monaco"}.newStringTable
## doAssert t.len == 2
## ```
```

**Raises**: Can be inline or in pragmas
```nim
## If key is not in t, the KeyError exception is raised
```

**See also**: For related documentation
```nim
## See also:
## *   `hasKey proc`
## *   `items proc`
```

**Deprecated**: Using pragma
```nim
proc oldApi*() {.deprecated: "Use newApi instead".} = ...
```

#### Formatting

**Backticks for code identifiers**:
```nim
## Use `open` to create a new data file
```

**Double backticks for format specs**:
```nim
## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
## Format: ``[timestamp:8][keyLen:4][key][valLen:4][flags:1][algorithm:1][value]``
```

#### Best Practices

1. **Add exactly one space after `##`**:
```nim
## Good: One space after hash marks
##Bad: No space after hash marks
```

2. **Always include code examples for key public APIs**:
```nim
proc set*(barrel: Barrel, key, value: string): bool =
  ## Store a key-value pair
  ##
  ## **Example:**
  ## ```nim
  ## let barrel = openBarrel("data.db")
  ## barrel.set("user:1", "Alice")
  ## barrel.close()
  ## ```
```

3. **Document all export parameters**:
```nim
proc itemsInRange*(barrel: Barrel, startKey: string, endKey: string,
                   limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  ## Get key-value pairs in range [startKey, endKey)
  ## limit: Maximum number of items to return (default: 1000)
  ## cursor: Last key from previous page (empty string for first page)
```

4. **Document return types**:
```nim
## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
```

5. **Use enum inline comments for clarity**:
```nim
type
  SyncMode* = enum
    None = "none"       # No sync (fastest, risk of data loss)
    Sync = "sync"       # Sync to OS buffer
    Fsync = "fsync"     # Sync to disk (safest)
```

#### What NOT to Do

- **Don't use `#` for documentation** - it won't appear in generated docs
- **Don't omit exports** - non-exported items won't generate documentation
- **Don't skip parameter docs** - users need to know what each parameter does
- **Don't forget code examples** - they're the most helpful part of documentation

### Do's and Don'ts
- Do: "Fast recovery"
- Don't: "Ultra-fast recovery"
- Do: "Provides good performance"
- Don't: "Optimal performance", "Maximum performance"
- Do: "Buffer size 64KB-256KB (recommended)"
- Don't: "Optimal buffer size", "Perfect for X"

### Performance
- Use "~" for approximate values: "~250K ops/sec"
- Include measurement context implicitly or explicitly
- Use "fast" sparingly, only when justified
- Avoid "extremely", "incredibly", "amazingly"

### General Tone
- Professional but understated
- Technical, not promotional
- Helpful without exaggeration
- Clear and direct

## Tutorial

See [docs/TUTORIAL.md](docs/TUTORIAL.md) for comprehensive documentation on using BitBarrel, including:
- API usage examples
- Performance benchmarks
- Configuration options
- Best practices
- Troubleshooting guide
