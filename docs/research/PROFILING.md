# HugeBarrel Performance Profiling Guide

## Current Performance Issues

From running `nimble stressHugeQuick`:

| Metric | Observed | Target | Status |
|--------|----------|--------|--------|
| Write Rate | 750-2800 ops/sec | 200,000 ops/sec | ❌ 100x slower |
| Memory Usage | 370MB for 90K keys (4KB/key) | 50 bytes/key | ❌ 80x higher |
| Performance Trend | Degrading over time | Stable | ❌ Degrading |
| ETA for 1M keys | ~20 minutes | ~30 seconds | ❌ 40x slower |

## Identified Problems

### 1. Memory Bloat
- **Symptom**: 370MB for 90K keys = ~4KB per key
- **Expected**: ~50 bytes per key = ~4.5MB total
- **Likely Cause**: RangeKeyDir serialization overhead or cache inefficiency

### 2. Performance Degradation
- **Symptom**: Rate drops from 2800 to 750 ops/sec
- **Pattern**: Worsens as more keys are written
- **Likely Cause**: O(n) operations becoming expensive

### 3. Barrel1 Size Issue (Fixed)
- **Problem**: Previously grew to 4.7GB with old test data
- **Root Cause**: Not cleaning up between test runs
- **Solution**: `cleanup_stress_test.sh` script created

## Recommended Profiling Approach

### Option 1: Nim's Built-in Profiler
```bash
# Compile and run with Nim's profiler
nim c --profiler:on -d:release bench/hugebarrel_stress.nim
./bench/hugebarrel_stress quick

# View profile data
trace2html hugebarrel_stress.profile
cp nimcache/hugebarrel_stress.trace/*.html results/
```

### Option 2: gprof (GNU Profiler)
```bash
# Compile with gprof support
nim c --profiler:on -d:release --passC:-pg --passL:-pg \
  bench/hugebarrel_stress.nim

# Run test
./bench/hugebarrel_stress quick

# Generate report
gprof ./bench/hugebarrel_stress > profile_report.txt

# View hotspots
gprof ./bench/hugebarrel_stress | head -50
```

### Option 3: perf (Linux Performance Analyzer)
```bash
# Install perf if not available
sudo apt-get install linux-tools-common linux-tools-generic

# Run with perf profiling
perf record -g ./bench/hugebarrel_stress quick

# Analyze results
perf report
perf script | head -100  # See call stacks

# Flame graph (requires FlameGraph tools)
perf script | ./FlameGraph/stackcollapse-perf.pl | ./FlameGraph/flamegraph.pl > flame.svg
```

### Option 4: Valgrind + Callgrind
```bash
# For detailed analysis of memory and CPU
valgrind --tool=callgrind --dump-instr=yes \
  ./bench/hugebarrel_stress quick

# Visualize results (requires kcachegrind)
callgrind_annotate callgrind.out.* | head -100
kcachegrind callgrind.out.*
```

## Quick Profiling Commands

### Profile SET Operations
```bash
# Profile 1000 set operations
nim c -r bench/profile_hugebarrel.nim

# Then run gprof
gprof bench/profile_hugebarrel > set_profile.txt
```

### Profile Compact Operations
```bash
# Run test in background with timing
nim c -d:release bench/hugebarrel_stress.nim
time ./bench/hugebarrel_stress quick > stress.log 2>&1 &

# Monitor in real-time
watch -n 5 "ps aux | grep hugebarrel | grep -v grep"

# Check file growth
watch -n 10 "ls -lh stress_test_db/barrel1/ && echo '---' && ls stress_test_db/barrel2/ | wc -l"
```

## What to Look For

### Memory Issues
- Check `hb.rangeKeyCache.cache` size (should be capped at 50 entries)
- Monitor per-key overhead (RangeKeyDirEntry size)
- Watch for unnecessary RangeKeyDir serialization

### CPU Hotspots
- Look for O(n) operations in RangeKeyDir.update()
- Check serialization/deserialization costs
- Profile CritBit operations on Barrel1

### File I/O
- Monitor fsync() calls (sync mode)
- Check for excessive file opens/closes
- Verify write buffer efficiency

## Expected vs Actual Sizes

```
RangeKeyDirEntry: 32 bytes (expected)
  - keyPos: 8 bytes
  - fileId: 4 bytes
  - valueSize: 4 bytes
  - recordSize: 4 bytes
  - keyLen: 4 bytes
  - key: variable

At 1M keys: 32MB (expected) vs 4000MB (actual)
Overhead: 125x more than expected!
```

## Next Steps

1. **Run gprof** on the stress test:
   ```bash
   nim c --profiler:on -d:release --passC:-pg --passL:-pg \
     -r bench/hugebarrel_stress.nim quick
   gprof bench/hugebarrel_stress > profile.txt
   ```

2. **Analyze top 10 functions** by CPU time

3. **Identify memory allocations** with Valgrind Massif
   ```bash
   valgrind --tool=massif --time-unit=ms \
     ./bench/hugebarrel_stress quick
   ms_print massif.out.* > memory_profile.txt
   ```

4. **Optimize based on findings**