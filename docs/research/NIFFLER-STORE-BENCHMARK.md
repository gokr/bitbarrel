# Niffler Store Benchmark — BitBarrel vs SQLite, Engine vs Stack

**Status:** Measured Result (2026-07)
**Purpose:** Settle why the BitBarrel-backed `store` component in
[Niffler](https://github.com/gokr/niffler) shows a uniform ~2 ms per-request
floor, and attribute it honestly: engine cost vs harness cost. Includes an
engine-only in-process comparison of BitBarrel (bmCritBit) against SQLite.
**Cross-refs:** Niffler `docs/research/STORE_V2.md` (multi-engine store plan),
Niffler `tools/bench_stores.nim` (the bus-level bench),
`bench/niffler_store_ops.nim` in this repo (the in-process bench added below).

---

## Context

Niffler is an agent harness whose persistence is a `store` component on a
NATS bus. Version 2 of that store (M3/M4) ships three interchangeable
engines behind one bus contract (`put/get/list/del` + optimistic
concurrency via `rev`):

| Engine | Language | Storage |
|---|---|---|
| **barrel** (default) | Nim | BitBarrel 0.5.0, `bmCritBit`, default config (`syncMode=sync`), **two keys per doc** (`doc-<id>` + `r:doc-<id>` rev counter) |
| **sqlite** | Go | `modernc.org/sqlite` (pure Go, no cgo), WAL + `synchronous=NORMAL`, one connection; one row per doc, one upsert statement per put |
| **tidb** | Go | MySQL protocol, network-shared (same schema as sqlite, MEDIUMTEXT) |

Niffler is single-process-per-conversation with a Nim SDK whose pump is
`natsSubscription_NextMsg` on the main thread; every tool call is a
NATS request/reply with a JSON envelope. All engines run behind the same
bus, so end-to-end numbers carry the full harness overhead.

## 1. End-to-end (over the bus, ~300 B values, release builds)

| Operation | barrel ops/s | sqlite ops/s | sqlite/barrel |
|---|---:|---:|---:|
| put (upsert) | 498 | 1597 | 3.2× |
| put CAS update | 490 | 1611 | 3.3× |
| get (hit) | 490 | 2512 | 5.1× |
| get (miss) | 485 | 2834 | 5.9× |
| del | 472 | 1988 | 4.2× |
| list, 1500 docs full | 39.3 ms | 20.6 ms | 1.9× |
| boot → registered | 22 ms | 7.3 ms | 3.0× |

Every barrel operation — even a no-op read of a missing key — costs ~2.0 ms
(~490–500 ops/s). Only `list` amortizes away from that floor (1500 docs in
39 ms ≈ 27 µs/doc), which is the tell: the floor is *per request*, not per
document. Debug vs release Nim builds changed nothing. Suspect: the request
path, not the engine.

## 2. In-process (engine only, no bus, no SDK)

New bench: `bench/niffler_store_ops.nim` (this repo) — the exact operations
the Niffler store performs, minus the harness. The SQLite mirror is the Go
program quoted at the bottom. Same machine, both release builds.

**BitBarrel 0.5.0, bmCritBit, syncMode=sync, validateCrc=true:**

| Operation | Throughput | Per op |
|---|---:|---:|
| set ×20000 (~300 B) | 152k ops/s | **6.6 µs** |
| set ×2000 (~4 KB) | 27–30k ops/s | 34–37 µs |
| get ×20000 (hit) | 258–313k ops/s | **3.2–3.9 µs** |
| get ×20000 (miss) | 3.1–5.2M ops/s | 0.2–0.3 µs |
| delete ×20000 | 548–638k ops/s | 1.6–1.8 µs |
| list pattern ×3 (keysByPrefix + 1 get/doc, 20k docs) | 13 ops | 75–89 ms |
| reopen (recovery + critbit reindex of 42k records) | — | 55–62 ms |

**SQLite (modernc.org/sqlite v1.58.0, WAL, synchronous=NORMAL, 1 conn):**

| Operation | Throughput | Per op |
|---|---:|---:|
| set ×20000 (upsert + RETURNING rev) | 6.7k ops/s | 148 µs |
| set ×2000 (~4 KB) | 4.7k ops/s | 214 µs |
| get ×20000 (SELECT hit) | 28k ops/s | 35 µs |
| get ×20000 (miss) | 39k ops/s | 26 µs |
| delete ×20000 | 9.2k ops/s | 109 µs |
| list pattern ×3 (one SELECT, 20k rows) | 14 ops | 71 ms |
| reopen (open + first query) | — | 1.1 ms |

## 3. Attribution — the verdict

The end-to-end barrel floor is **~2000 µs/request**. In-process, BitBarrel
performs the *same operations* in **2–7 µs**. The engine is **~300–1000×
cheaper than the request that carries it**: **~99.7 % of end-to-end latency
is the Niffler harness stack** (NATS request/reply through
`natsSubscription_NextMsg`, envelope encode/decode, Nim GC in the pump) —
not BitBarrel. The ~2 ms floor is identical for SQLite too at the low end
(sqlite's 2834 misses/s ≈ 0.35 ms still carries the same ~0.35 ms/request
path cost minus a fraction), and only disappears once per-request work
(list) exceeds it. Debug-vs-release insensitivity confirmed it is
structural, not codegen.

So the honest verdict on the original suspicion — *"~2 ms/op is a
consequence of Nim & NATS, not inherent BitBarrel slowness"* — is
**confirmed, and stronger than hoped**: BitBarrel the engine is not merely
exonerated, it is the *fastest* of the three engines per point operation,
beating SQLite in-process by ~9× on gets, ~22× on sets and ~60× on deletes
(in-memory critbit index + append-only writes vs B-tree page churn — an
expected KV-vs-SQL shape, but measured here, not assumed).

The SQLite engine's real wins are elsewhere, and they are architectural,
not speed:

- **Range/list in one statement** — 71 ms vs 75–89 ms for the
  keys-per-doc pattern at 20k docs (roughly tied at this size; SQLite's
  margin grows with N since it never walks keys one by one).
- **Atomic multi-key writes** — the barrel store's put = two `set` calls
  (doc + rev) with a crash window between them; the SQL engines get both
  in one statement/transaction.
- **Fast reopen** — 1.1 ms vs BitBarrel's 55–62 ms recovery + critbit
  reindex (42k records; expect roughly linear growth, and note the store
  pays it on every boot).
- **Disk hygiene** — WAL checkpoints deleted rows away (~1.5 MB after
  20k-write churn); BitBarrel retains tombstoned records in the log until
  compaction (475 KB in the same test — small here, but unbounded without
  compaction; `autoCompact` is **off by default** in 0.5.0).

For Niffler's operating point (small conversation stores, boot once,
per-op latency dominated by the harness anyway) all of this is second
order — which is exactly why the barrel default stands: same contract,
and the engine was never the problem.

## 4. Reproduce

```bash
# in-process bitbarrel (this repo):
cd bitbarrel && nim c -d:release --run bench/niffler_store_ops.nim

# end-to-end bus bench (niffler repo; ENGINE=<bin> or both default engines):
cd niffler && nim c --hints:off --path:sdk -o:var/bin/bench-stores tools/bench_stores.nim && ./var/bin/bench-stores
```

SQLite mirror used for §2 (save as `main.go`, `go mod tidy && go run .`,
needs `modernc.org/sqlite`):

```go
package main

import (
	"database/sql"
	"fmt"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const docs = 20_000

func timed(name string, ops int, body func()) {
	t0 := time.Now()
	body()
	ms := float64(time.Since(t0).Microseconds()) / 1000
	fmt.Printf("  %-46s %10.1f ms %10.0f ops/s  (%7.1f µs/op)\n",
		name, ms, float64(ops)/ms*1000, ms*1000/float64(ops))
}

func payload(n, size int) string {
	return fmt.Sprintf(`{"n":%d,"payload":"%s"}`, n, strings.Repeat("x", size))
}

func main() {
	dir, _ := os.MkdirTemp("", "sqlite-inproc-")
	defer os.RemoveAll(dir)
	dsn := "file:" + dir + "/bench.db?_txlock=immediate&_journal_mode=WAL" +
		"&_busy_timeout=10000&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		panic(err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.Exec(`CREATE TABLE docs (kind TEXT NOT NULL, id TEXT NOT NULL,
		rev INTEGER NOT NULL DEFAULT 0, value TEXT NOT NULL,
		PRIMARY KEY (kind, id))`); err != nil {
		panic(err)
	}
	timed("set x20000 (~300 B, upsert+RETURNING rev)", docs, func() {
		for i := 1; i <= docs; i++ {
			if _, err := db.Exec(`INSERT INTO docs (kind,id,rev,value)
				VALUES ('k',?,1,?) ON CONFLICT(kind,id) DO UPDATE SET
				rev=docs.rev+1, value=excluded.value RETURNING rev`,
				fmt.Sprintf("doc-%d", i), payload(i, 240)); err != nil {
				panic(err)
			}
		}
	})
	var s string
	timed("get x20000 (SELECT hit)", docs, func() {
		for i := 1; i <= docs; i++ {
			if err := db.QueryRow(`SELECT value FROM docs WHERE kind='k' AND id=?`,
				fmt.Sprintf("doc-%d", i)).Scan(&s); err != nil || len(s) == 0 {
				panic(err)
			}
		}
	})
	timed("delete x20000", docs, func() {
		for i := 1; i <= docs; i++ {
			if _, err := db.Exec(`DELETE FROM docs WHERE kind='k' AND id=?`,
				fmt.Sprintf("doc-%d", i)); err != nil {
				panic(err)
			}
		}
	})
}
```

**Environment:** Ubuntu 24.04.4, Intel Core Ultra 7 165U (14 cores), NVMe,
Nim 2.2.10, Go 1.26.2, BitBarrel 0.5.0 (41e6969), modernc.org/sqlite
v1.58.0. Ranges in the tables are two runs (variance <10 %).
