# Memory Management in BitBarrel

This guide covers Nim's memory management patterns and best practices specific to BitBarrel development.

## Nim Memory Management Basics

### Key Concepts

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

## Common Anti-Patterns

### NEVER Take Address of Temporary Copies

```nim
# DANGEROUS - undefined behavior!
proc badExample(): ptr int =
  var x = 42
  var table = {"key": x}
  result = addr table["key"]  # Points to temporary copy!
```

### Safe Patterns

```nim
# Store refs directly in containers when sharing is needed
type
  MyStruct = ref object
    data: int

proc safeExample(): Table[string, MyStruct] =
  result = {"key": MyStruct(data: 42)}  # Store ref, not value
```

## Memory Management Patterns Used in BitBarrel

### 1. Thread-Safe Shared Objects

BitBarrel uses locks to protect shared state with the GC-safe pattern:

```nim
type
  KeyDir = object
    entries: Table[string, KeyDirEntry]
    lock: Lock

proc addEntry(keydir: var KeyDir, key: string, entry: KeyDirEntry) =
  withLock(keydir.lock):
    keydir.entries[key] = entry
```

### 2. Reference Object Design Pattern

For objects frequently shared, define them as `ref object` from the start:

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

Benefits:
- No need to wrap value types in `ref` everywhere
- Cleaner API without constant `[]` dereferencing
- Natural shared ownership semantics
- Less error-prone than manual `ref` wrapping

### 3. Safe Reference Wrapping

When retrofitting existing value types:

```nim
# Correct pattern for safe ref creation
type
  HugeBarrel = ref object
    barrel2Files: Table[uint32, ref DataFile]  # Store refs
    lock: Lock

proc getOrCreateDataFile(hb: var HugeBarrel, fileId: uint32): ref DataFile =
  withLock(hb.barrel2Lock):
    if fileId in hb.barrel2Files:
      return hb.barrel2Files[fileId]

    # Create DataFile and wrap in ref properly
    var dataFile = open(...)
    let dataFileRef = new(ref DataFile)
    dataFileRef[] = dataFile

    hb.barrel2Files[fileId] = dataFileRef
    return dataFileRef
```

## Memory Management Guidelines

### Rule of Thumb

- Use `var` for stack-local and simple values
- Use `ref object` for types intended to be shared (data structures, files, network connections)
- Use `ref` wrapping only when retrofitting existing value types
- Use `ptr` only for FFI or when you specifically need manual memory management
- Never use `addr` and `cast` to create refs from value types in containers

### Performance Considerations

#### When to Use Value Types

- Small objects (<= 16-32 bytes)
- Objects frequently copied but rarely shared
- Performance-critical inner loops
- Stack-allocated temporary objects

```nim
type
  Point = object  # Value type - efficient
    x, y: float64

proc addPoints(a, b: Point): Point =
  result = Point(x: a.x + b.x, y: a.y + b.y)
```

#### When to Use Reference Types

- Large objects (> ~100 bytes)
- Objects shared between multiple parts of code
- Objects with independent lifetimes
- Network/file handles, buffers

```nim
type
  Buffer = ref object  # Reference type - avoids copying
    data: seq[byte]
    size: int
```

### Memory Leak Prevention

#### GC Safety in Threaded Code

```nim
# Mark thread-safe code blocks
proc threadSafeOperation(shared: SharedObject) {.gcsafe.} =
  {.gcsafe.}:
    # Access to shared state that is thread-safe
    # but can't be proven by the compiler
    withLock(shared.lock):
      shared.data = someValue
```

#### Proper Resource Cleanup

```nim
type
  ManagedResource = ref object of RootObj

proc cleanup(resource: ManagedResource) =
  # Custom cleanup logic
  resource.handle.close()

# Ensure cleanup happens
proc useResource() =
  var resource = ManagedResource(handle: open(...))
  try:
    # Use resource
    echo resource.data
  finally:
    cleanup(resource)
```

## BitBarrel-Specific Patterns

### 1. Write Buffer Management

```nim
type
  WriteBuffer = ref object
    entries: seq[BufferedEntry]
    lock: Lock
    cond: ConditionVariable

proc addEntry(buffer: WriteBuffer, key, value: string): bool =
  withLock buffer.lock:
    # Thread-safe buffer management
    buffer.entries.add(BufferedEntry(key: key, value: value))
    signal(buffer.cond)
```

### 2. RangeKeyDir Cache Management

```nim
type
  RangeKeyDirCache = object
    cache: Table[string, RangeKeyDir]
    lruList: seq[string]
    maxSize: int
    lock: Lock

proc cachePut(cache: var RangeKeyDirCache, key: string, rkd: RangeKeyDir) =
  withLock cache.lock:
    cache.cache[key] = rkd
    # LRU management
    cache.lruList.add(key)
    if cache.lruList.len > cache.maxSize:
      let evicted = cache.lruList[0]
      cache.lruList.delete(0)
      cache.cache.del(evicted)
```

### 3. DataFile Reference Handling

The recent fix for HugeBarrel demonstrates proper reference handling:

```nim
# Before (unsafe):
var df = addr hb.barrel2Files[fileId]  # Takes address of copy!
return cast[ref DataFile](df)

# After (safe):
if fileId in hb.barrel2Files:
  return hb.barrel2Files[fileId]  # Return stored ref

let dataFileRef = new(ref DataFile)  # Proper allocation
dataFileRef[] = dataFile
hb.barrel2Files[fileId] = dataFileRef
```

## Debugging Memory Issues

### Common Symptoms

1. **Random crashes** - Dangling pointers
2. **Memory growth** - Leaked references
3. **Data corruption** - Multiple ownership

### Debugging Tools

```nim
# Enable GC statistics
gcFullCollect()
echo "GC statistics: ", getGCStatistics()

# Track object allocations
when defined(debug):
  echo "Allocated: ", getTotalMem()

# Valgrind integration
# Compile with: nim -d:debug -d:useMalloc c yourcode.nim
# Run: valgrind --tool=memcheck ./yourcode
```

### Best Practices for Debugging

1. **Start small** - Test with minimal data first
2. **Use assertions** - Verify invariants especially around shared state
3. **Thread sanitization** - Use thread sanitizer when compiling
4. **Memory profiling** - Track allocation patterns

## Migration Checklist

When converting from value types to reference types:

1. **Update type definitions** to use `ref object`
2. **Fix all construction** to use `new()` instead of values
3. **Update all access** to use `ref.field` instead of `ref[].field`
4. **Review threading code** for new GC considerations
5. **Add assertions** to catch null references
6. **Run tests** under memory profiling

## References

- [Nim Manual: Memory Management](https://nim-lang.org/docs/manual.html#memory-management)
- [Nim Manual: References and Pointers](https://nim-lang.org/docs/manual.html#references-and-pointer-types)
- [CLAUDE.md](../../CLAUDE.md) - Project-specific memory management guidelines