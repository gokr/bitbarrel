# Advanced Key-Value Store Features

Research on protocol commands and features suitable for BitBarrel, based on analysis of Redis, TiKV, etcd, RocksDB, and FoundationDB.

## 1. Atomic Operations (High Priority)

### Compare-And-Swap (CAS)
- **Redis approach**: `WATCH/MULTI/EXEC` pattern for optimistic locking
- **Alternative**: Version-based CAS - store version counter with each key
- **Use cases**: Distributed locks, preventing race conditions, concurrent updates

### Atomic Increment/Decrement
- `INCR key` / `DECR key` - atomic increment/decrement
- `INCRBY key delta` / `DECRBY key delta` - increment by amount
- **Important**: Should preserve TTL on the key
- **Use cases**: Counters, rate limiters, inventory management, analytics

### Atomic Get-and-Set
- `GETSET key value` - atomically set new value and return old value
- **Use cases**: Atomic swaps, cache invalidation patterns

## 2. Conditional Operations

### Conditional Set
- `SET key value NX` - set only if key does NOT exist (create-only)
- `SET key value XX` - set only if key DOES exist (update-only)
- **Use cases**: Distributed locks, cache miss handling

### Conditional Delete
- `DELETE key IF version=X` - delete only if version matches
- **Use cases**: Avoiding ABA problems, safe cleanup

## 3. TTL and Expiration (Very Useful)

### Per-Key TTL
- `EXPIRE key seconds` - set expiration time
- `PERSIST key` - remove expiration
- `TTL key` - get remaining time to live
- `SETEX key seconds value` - set with expiration in one operation

### Automatic Cleanup
- Background expiration processing (BitBarrel compaction could handle this)
- **Use cases**: Session storage, caching, temporary data

## 4. Batch Operations

### Multi-Get/Multi-Set
- `MGET key1 key2 key3` - get multiple values in one operation
- `MSET key1 val1 key2 val2` - set multiple key-value pairs atomically
- **Performance**: Reduces round-trip latency significantly

### Scan Operations
- `SCAN cursor [MATCH pattern] [COUNT limit]` - iterate keys efficiently
- Better than `KEYS *` for production use
- **Use cases**: Key discovery, maintenance operations

## 5. Transaction Support

### etcd-Style Transactions
```
IF <conditions>
  THEN <success_ops>
  ELSE <failure_ops>
```
- Check multiple conditions atomically
- Execute different operations based on result
- **Guarantees**: Strict serializability (from etcd model)

### TiKV-Style Transactions
- `BEGIN` - start transaction
- `GET/SET/DELETE` - transaction operations
- `COMMIT` - atomically apply all changes
- **Features**: Snapshot isolation, MVCC support

## 6. Versioning and MVCC

### Revision Tracking
- Each modification gets monotonically increasing revision number
- `GET key REVISION=X` - get specific version
- **Use cases**: Time-travel queries, audit trails, conflict detection

### Multi-Version Support
- Store multiple versions of same key
- Enables snapshot isolation for transactions
- **TiKV API v2**: Native MVCC with CDC (Change Data Capture)

## 7. Range Query Enhancements (Since BitBarrel supports bmCritBit)

### Reverse Range Queries
- `RANGE start end REVERSE=true` - iterate backwards
- **Use cases**: Recent items first, pagination in reverse

### Count Operations
- `COUNT start end` - count keys in range without fetching values
- **Performance**: Much faster than fetching and counting

### Range Delete
- `DELRANGE start end` - delete all keys in range atomically
- **Use cases**: Bulk cleanup, tenant data removal

## 8. Metadata Operations

### Key Existence
- `EXISTS key` - check if key exists (boolean)
- `MEXISTS key1 key2 key3` - check multiple keys
- **Performance**: Faster than GET when you only need existence

### Key Type/Info
- `INFO key` - get metadata (size, version, timestamp, TTL)
- Useful for debugging and monitoring

### Key Length
- `STRLEN key` - get value length without fetching full value
- **Use cases**: Size validation, pagination hints

## 9. Advanced Features to Consider

### Checksum Validation
- `GET key VERIFY=true` - return value with CRC verification
- Optional for performance-critical paths
- **BitBarrel already has CRC32** - expose in protocol

### Prefix-Based Operations
- `DELPREFIX prefix` - delete all keys with prefix
- `COUNTPREFIX prefix` - count keys with prefix
- **Works well with bmCritBit** ordered index

### Watch/Subscribe
- `WATCH key` - get notified of changes
- **etcd pattern**: Long-polling or streaming
- **Use cases**: Cache invalidation, reactive systems

## 10. Durability Controls

### Per-Operation Sync
- `SET key value SYNC=fsync` - override default sync mode
- `SET key value SYNC=none` - fast, unsafe write
- **BitBarrel already has sync modes** - expose per-operation

## Priority Recommendations

### Tier 1 - Essential
1. CAS (Compare-And-Swap) with version numbers
2. INCR/DECR atomic operations
3. Conditional SET (NX/XX flags)
4. TTL/EXPIRE support
5. MGET/MSET batch operations

### Tier 2 - Very Useful
6. EXISTS metadata operation
7. Transaction support (BEGIN/COMMIT style)
8. Range DELETE for bmCritBit mode
9. COUNT operations for ranges
10. GETSET atomic swap

### Tier 3 - Advanced
11. MVCC/versioning for time-travel queries
12. WATCH/Subscribe for change notifications
13. Reverse range queries
14. Per-operation durability control

## Implementation Notes

- **Version storage**: Add `version: uint64` field to KeyDirEntry
- **TTL storage**: Add `expiresAt: int64` field (0 = no expiration)
- **Compaction integration**: Handle expired keys during compaction
- **Protocol design**: Consider msgpack or protobuf for efficient encoding
- **Backward compatibility**: Not a concern (no users yet per CLAUDE.md)

## References

- [Redis Transactions](https://redis.io/docs/latest/develop/using-commands/transactions/)
- [Redis CAS Operations](https://olivernguyen.io/w/redis.cas/)
- [TiKV Features](https://tikv.org/docs/dev/concepts/explore-tikv-features/api-v2/)
- [TiKV API Reference](https://tikv.org/docs/6.5/concepts/explore-tikv-features/overview/)
- [etcd API Guarantees](https://etcd.io/docs/v3.5/learning/api_guarantees/)
- [etcd Transactions](https://etcd.io/docs/v3.5/tutorials/how-to-transactional-write/)
- [Redis INCR Command](https://redis.io/docs/latest/commands/incr/)
- [RocksDB Documentation](https://rocksdb.org/)
- [FoundationDB Key-Value Store](https://www.foundationdb.org/key-value-store/documentation/2.0/api-c.html)

---

## Server-Side Scripting: Extensibility Through Code Execution

Many of the advanced features listed above could be implemented as **server-side scripts** rather than being hard-coded into the BitBarrel protocol. This approach, pioneered by Redis with Lua scripting, provides significant advantages in flexibility and extensibility.

### What Can Be Implemented as Scripts

**Atomic Operations** (Perfect fit):
- CAS: Read value, compare version, conditionally write
- INCR/DECR: Read current value, increment, write back
- GETSET: Read old value, write new value, return old
- Conditional SET (NX/XX): Check existence, conditionally write

**Complex Transactions**:
- Multi-step conditional logic
- Custom validation before writes
- Computed values based on multiple keys
- Business rule enforcement

**Custom Data Structures**:
- Counters with auto-reset
- Rate limiters (token bucket, sliding window)
- Leaderboards
- Bloom filters
- Custom indexes

**Business Logic**:
- Inventory management (decrement only if > 0)
- Account balances (prevent negative)
- Session validation
- Access control checks

### What Still Needs Core Support

**Storage-Level Features**:
- TTL/Expiration: Needs background compaction integration
- MVCC: Requires storage format changes
- Versioning: Needs to be stored in KeyDirEntry

**Performance-Critical Operations**:
- Range queries: Need efficient index (bmCritBit)
- Batch MGET/MSET: Benefit from optimized native code
- Prefix scans: Need proper index structure

**System-Level Features**:
- Watch/Subscribe: Needs event notification system
- Replication: Core storage concern
- Backup/Restore: Direct file access

### Language Options for Embedded Scripting

#### 1. Lua (Redis Model)

**Pros**:
- Proven in Redis (handles millions of ops/sec)
- Small footprint (~280KB)
- Fast JIT with LuaJIT
- Simple embedding API
- Atomic execution guarantees

**Cons**:
- Another language for users to learn
- Limited type safety
- Foreign runtime dependency

**Nim Libraries**:
- `nlua` - Nim wrapper for Lua C API
- Could use LuaJIT for performance

**Example**:
```nim
import nlua

proc executeLuaScript(barrel: Barrel, script: string,
                      keys: seq[string], args: seq[string]): string =
  var L = luaL_newstate()
  defer: lua_close(L)

  # Expose barrel operations to Lua
  # barrel.get(key), barrel.set(key, val), etc.

  luaL_dostring(L, script)
```

**Redis Lua Example**:
```lua
-- INCR with max value
local current = redis.call('GET', KEYS[1])
if current == false then
  current = 0
else
  current = tonumber(current)
end

if current >= tonumber(ARGV[1]) then
  return current  -- Already at max
end

current = current + 1
redis.call('SET', KEYS[1], current)
return current
```

#### 2. JavaScript (V8 or QuickJS)

**Pros**:
- Familiar to many developers
- QuickJS is lightweight (~700KB)
- V8 is very fast but large

**Cons**:
- Larger footprint than Lua
- More complex embedding
- V8 requires significant resources

**Nim Libraries**:
- Could wrap QuickJS C API
- More complex than Lua integration

#### 3. WebAssembly (WASM)

**Pros**:
- Sandboxed by design
- Multi-language support (Rust, C, AssemblyScript, etc.)
- Good performance
- Future-proof

**Cons**:
- More complex runtime
- Requires compilation step for users
- Larger footprint

**Nim Libraries**:
- `wasm3` - WASM interpreter in C (can wrap)
- `wasmer` - WASM runtime (Rust, could use via FFI)

#### 4. Nim with Hot-Reload (.so plugins)

**Concept**: Users write scripts in Nim, BitBarrel compiles them to shared libraries (.so on Linux, .dylib on macOS, .dll on Windows), then hot-loads them at runtime.

**Architecture**:
```
User submits Nim script
    ↓
BitBarrel validates syntax
    ↓
Call Nim compiler: nim c --app:lib --noMain script.nim
    ↓
Load resulting .so with dynlib
    ↓
Execute function via FFI
    ↓
Unload when done (or cache)
```

**Implementation Example**:

```nim
# User script (saved as user_script_123.nim)
import bitbarrel_api  # Provided by BitBarrel

proc execute(barrel: ptr Barrel, keys: seq[string], args: seq[string]): string {.exportc, dynlib.} =
  # User's custom logic
  let current = barrel.get(keys[0])
  if current.len == 0:
    barrel.set(keys[0], args[0])
    return args[0]

  # Increment logic
  let val = parseInt(current)
  let newVal = val + 1
  barrel.set(keys[0], $newVal)
  return $newVal
```

```nim
# BitBarrel server-side
import dynlib, os, osproc

type
  ScriptProc = proc(barrel: ptr Barrel, keys: seq[string],
                   args: seq[string]): string {.cdecl.}

proc compileScript(scriptCode: string, scriptId: string): string =
  ## Compile Nim script to .so file
  let scriptPath = fmt("scripts/{scriptId}.nim")
  let soPath = fmt("scripts/{scriptId}.so")

  writeFile(scriptPath, scriptCode)

  let cmd = fmt("nim c --app:lib --noMain --out:{soPath} {scriptPath}")
  let (output, exitCode) = execCmdEx(cmd)

  if exitCode != 0:
    raise newException(ValueError, fmt("Compilation failed: {output}"))

  return soPath

proc executeCompiledScript(barrel: Barrel, soPath: string,
                          keys: seq[string], args: seq[string]): string =
  ## Load and execute compiled script
  let lib = loadLib(soPath)
  if lib == nil:
    raise newException(ValueError, "Failed to load library")

  defer: unloadLib(lib)

  let execProc = cast[ScriptProc](lib.symAddr("execute"))
  if execProc == nil:
    raise newException(ValueError, "Failed to find execute symbol")

  var barrelPtr = addr barrel
  return execProc(barrelPtr, keys, args)

# API endpoint
proc evalScript*(barrel: Barrel, script: string,
                keys: seq[string] = @[],
                args: seq[string] = @[]): string =
  ## Compile and execute user Nim script
  let scriptId = genScriptId()  # Generate unique ID

  # Compile script (could cache compiled .so files)
  let soPath = compileScript(script, scriptId)

  # Execute
  return executeCompiledScript(barrel, soPath, keys, args)
```

### Nim Hot-Reload: Deep Dive

#### Pros

**1. Native Performance**
- No interpreter overhead
- Full Nim compiler optimizations
- Same performance as hand-written BitBarrel code
- Can inline and optimize across script/core boundary

**2. Type Safety**
- Full Nim type system
- Compile-time checks catch errors before execution
- No runtime type errors from scripts

**3. No Foreign Runtime**
- No Lua/JS/WASM runtime to embed
- Smaller BitBarrel binary
- One less dependency to manage

**4. Familiar Language**
- BitBarrel developers already know Nim
- Users can read BitBarrel source for examples
- Same idioms, patterns, and libraries

**5. Full Language Access**
- Access to entire Nim stdlib (can be restricted)
- Can use Nim's macro system
- Generic programming support

**6. Debugging**
- Can use GDB/LLDB on compiled scripts
- Stack traces show actual Nim code
- Can attach debugger to running script

**7. Code Reuse**
- Scripts can import shared Nim modules
- Can package common patterns as libraries
- Version control scripts as regular code

#### Cons

**1. Compilation Latency**
- Nim compilation takes time (seconds)
- Not suitable for real-time script execution
- Redis Lua scripts execute in microseconds

**Mitigation**:
- Cache compiled .so files (hash script content)
- Pre-compile scripts at startup
- Use background compilation queue

**2. Security Concerns**
- Scripts have full system access by default
- Can import dangerous modules (os, osproc)
- Can call any C function via FFI
- File system access during compilation

**Mitigation**:
- Parse script AST, whitelist safe imports
- Use chroot/container for compilation
- Restrict available symbols in bitbarrel_api
- Run scripts with limited permissions
- Consider AppArmor/SELinux policies

**3. Resource Management**
- Each script loads as separate library
- Memory overhead for .so files
- Need to manage .so lifecycle (load/unload)
- Potential memory leaks if not careful

**Mitigation**:
- Implement .so caching and reuse
- Periodic cleanup of unused scripts
- Reference counting for loaded libraries
- Memory limits per script execution

**4. Versioning Challenges**
- Script compiled against BitBarrel v1.0 may break with v2.0
- ABI compatibility concerns
- Need to recompile scripts on BitBarrel upgrade

**Mitigation**:
- Stable API versioning (bitbarrel_api v1, v2, etc.)
- Store BitBarrel version with compiled script
- Auto-recompile on version mismatch

**5. Cross-Platform Complexity**
- Need Nim compiler on server
- Different .so/.dylib/.dll for each platform
- Compilation environment must match runtime

**Mitigation**:
- Bundle Nim compiler with BitBarrel
- Detect platform at runtime
- Provide pre-compiled common scripts

**6. Hot-Reload Race Conditions**
- Loading/unloading .so while in use is dangerous
- Need proper synchronization
- Potential crashes if script unloaded during execution

**Mitigation**:
- Reference counting on script handles
- Wait for all executions to complete before unload
- Use RCU-like pattern for script updates

**7. Error Handling**
- Segfaults in script can crash BitBarrel
- No sandboxing by default
- Need to catch and handle script errors

**Mitigation**:
- Wrap script calls in signal handlers
- Use separate process for script execution
- Implement timeout mechanism

#### Compilation Strategy

**Option A: Synchronous (Simple)**
```
User calls EVAL script → Compile → Load → Execute → Return result
```
- Simple implementation
- High latency (seconds)
- Blocks other operations

**Option B: Cached (Practical)**
```
Hash script → Check cache → If cached: Load → Execute
                         → If not: Compile → Cache → Load → Execute
```
- Amortizes compilation cost
- Fast for repeated scripts
- Needs cache eviction policy

**Option C: Pre-compilation (Production)**
```
User uploads script → Background compile → Store as "function name"
User calls EVALFUNC name → Load cached .so → Execute
```
- Separates compilation from execution
- Predictable latency
- Supports script management

**Option D: JIT-like (Advanced)**
```
First call: Interpret or run in VM (slow but instant)
Background: Compile to .so
Future calls: Use compiled version (fast)
```
- Best of both worlds
- Complex implementation
- Requires interpreter anyway

#### Recommended Hybrid Approach

**For Development/Testing**: Use Lua
- Fast iteration
- Instant execution
- Easy debugging
- Proven in production (Redis)

**For Performance-Critical Custom Logic**: Use Nim hot-reload
- Pre-compile scripts
- Use EVALFUNC (not EVAL)
- Cache compiled .so files
- Treat as "plugins" not "scripts"

**For Maximum Flexibility**: Support both
- Lua for ad-hoc scripts
- Nim for performance-critical extensions
- Users choose based on needs

### Comparison Matrix

| Feature | Lua | JavaScript | WASM | Nim Hot-Reload |
|---------|-----|------------|------|----------------|
| Performance | Fast (JIT) | Fast (V8) / Medium (QuickJS) | Fast | Native (Fastest) |
| Startup Time | Instant | Instant | Instant | Slow (compilation) |
| Memory Footprint | Small (~280KB) | Medium (700KB) / Large (V8) | Medium | Small (runtime) |
| Security | Sandboxable | Sandboxable | Sandboxed | Needs work |
| Type Safety | No | Medium | Yes | Yes (compile-time) |
| Debugging | Limited | Good (V8) | Limited | Excellent (GDB) |
| Learning Curve | Low-Medium | Low | Medium | Medium (if know Nim) |
| Nim Integration | FFI wrapper | FFI wrapper | FFI wrapper | Native |
| Production Ready | Yes (Redis) | Yes (many) | Emerging | Experimental |

### Recommendation

**Primary Choice: Lua with LuaJIT**
- Proven at scale (Redis)
- Instant execution
- Small footprint
- Easy to sandbox
- Good performance

**Future Addition: Nim Hot-Reload for Plugins**
- Pre-compiled extensions
- Performance-critical custom logic
- Treat as "compiled plugins" not "scripts"
- EVALFUNC API (named, pre-compiled functions)

**Benefits of Scripting (General)**:
1. Reduces protocol complexity
2. User extensibility without forking
3. Atomic execution guarantees
4. Network efficiency (one round-trip)
5. Future-proof (new features without protocol changes)

This approach allows BitBarrel to support both ad-hoc scripting (Lua) and high-performance extensions (Nim), giving users the best of both worlds.
