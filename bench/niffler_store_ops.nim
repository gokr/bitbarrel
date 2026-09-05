## In-process bitbarrel microbenchmark — the ops the Niffler store performs,
## with no bus and no SDK in the way. Settles whether the ~2 ms/request floor
## seen end-to-end in Niffler's store benchmark is bitbarrel's own cost or
## the Nim SDK / NATS request path.
##
## Run with: nim c -d:release --run bench/niffler_store_ops.nim
## (from the bitbarrel repo root; results feed
## docs/research/NIFFLER-STORE-BENCHMARK.md)

import std/[os, strformat, strutils, tempfiles, times]
import ../src/bitbarrel/barrel

const
  docs = 20_000          # point documents, ~300 B values
  bigDocs = 2_000        # ~4 KB values
  lists = 3              # full-store list pattern iterations

proc timed(name: string, ops: int, body: proc()) =
  let t0 = epochTime()
  body()
  let ms = (epochTime() - t0) * 1000
  if ops > 0:
    echo &"  {name:<44} {ms:>10.1f} ms  {ops.float/ms*1000:>10.0f} ops/s  ({ms/ops.float*1000:>7.1f} µs/op)"
  else:
    echo &"  {name:<44} {ms:>10.1f} ms"

proc payload(n: int, size: int): string =
  "{\"n\":" & $n & ",\"payload\":\"" & repeat("x", size) & "\"}"

proc main() =
  let dir = createTempDir("bb-inproc-", "")
  defer: removeDir(dir)
  let path = dir / "bench.db"

  var config = defaultBarrelConfig()
  config.mode = bmCritBit            # exactly what the Niffler store uses
  echo "config: ", $config.mode, ", syncMode=", $config.syncMode,
       ", autoCompact=", $config.autoCompact, ", validateCrc=", $config.validateCrc

  var db = openBarrel(path, config)

  # --- writes (the store does TWO sets per put: doc key + rev key) -------
  timed(&"set x{docs} (~300 B)", docs, proc() =
    for i in 1 .. docs:
      doAssert db.set("doc-" & $i, payload(i, 240)))
  timed(&"set x{bigDocs} (~4 KB)", bigDocs, proc() =
    for i in 1 .. bigDocs:
      doAssert db.set("big-" & $i, payload(i, 3900)))

  # --- reads -------------------------------------------------------------
  timed(&"get x{docs}", docs, proc() =
    for i in 1 .. docs:
      doAssert db.get("doc-" & $i).len > 0)
  timed("get missing x20000", 20_000, proc() =
    for i in 1 .. 20_000:
      doAssert db.get("nope-" & $i).len == 0)

  # --- the store's list pattern: prefix keys, then get per key ------------
  var listed = 0
  timed(&"list pattern x{lists} (keysByPrefix + 2 gets/doc)", lists, proc() =
    for i in 1 .. lists:
      let (keys, _, _) = db.keysByPrefix("doc-", docs)
      listed = keys.len
      for k in keys:
        doAssert db.get(k).len > 0
        doAssert db.get("r:" & k).len == 0)  # rev key: empty here, real store has it
  doAssert listed == docs

  # --- delete ------------------------------------------------------------
  timed(&"delete x{docs}", docs, proc() =
    for i in 1 .. docs:
      discard db.delete("doc-" & $i))

  # --- restart: close, reopen, time the recovery/reindex ------------------
  db.close()
  let t0 = epochTime()
  db = openBarrel(path, config)
  echo &"  reopen (recovery + critbit reindex){44} {(epochTime()-t0)*1000:>10.1f} ms"
  doAssert db.get("big-1").len > 0
  db.close()

main()
