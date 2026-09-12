#!/usr/bin/env bash
# PORTED (2026-08-25): the tests/live/*.ky files were stuck on `import net.reactor` after the lang stdlib
# split reactor into net/poller + net/aio + net/eventedio. They now import `net.poller` and pump the same
# manual reactor surface (poller.Reactor/setCurrent/batchBegin/completedToken), and all three PASS against
# a live NovaDB (187 sqlconfig, 189 lease fence dance, 190 store-driven reconcile) -- the live proof of the
# split-brain CAS fix + server-side FENCE that the offline suite can only model. Run this in CI wherever a
# NovaDB build is available (opt-in from gate.sh via KYTE_LIVE=1); it still is NOT part of the default
# offline merge gate, since it needs a running server and is timing-sensitive.
#
# Run the LIVE integration tests (tests/live/*.ky) against a fresh NovaDB
# server. Unlike run-tests.sh (offline, deterministic, the GATE), these connect to a real btree on
# 127.0.0.1:3009 and are timing-sensitive; they confirm behaviour but never gate a merge. Their guarantees
# have deterministic equivalents in run-tests.sh (188 lease, O2 198_ha_cluster) -- see ../../TEST-STRATEGY.md.
# Requires the btree repo built beside the lang toolchain (btree/zig-out/bin/btree) and `kyte` on PATH.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lang="$here/../../lang"
btree="$here/../../novadb"
server="$btree/zig-out/bin/novadb"

[ -x "$server" ] || { echo "build NovaDB first: (cd $btree && zig build)"; exit 1; }

# Each live test gets its OWN fresh server: the persisted FENCE high-water (max_epoch_seen, in the WAL dir)
# is global to a server, so a test that promotes a lease would poison the next test's low-epoch election.
# Every test's header promises a fresh server; honor it per file, not per suite.
livepid=""
start_server() {
  ( cd "$btree" && rm -rf data/kyte.db data/wal kyte.db wal test_wal_recovery ) 2>/dev/null
  # The orchestrator config store is the "config workload" (P0): run it sync-commit so every acked lease/CAS
  # or workload-spec write is fsync-durable across a crash (RPO=0). Config is tiny; the fsync is not the cost.
  ( cd "$btree" && SYNCHRONOUS_COMMIT=true "$server" >/tmp/btree_live_server.log 2>&1 & echo $! >/tmp/btree_live.pid )
  sleep 3
  livepid="$(cat /tmp/btree_live.pid)"
}
stop_server() { [ -n "$livepid" ] && kill "$livepid" 2>/dev/null; livepid=""; }
trap 'stop_server' EXIT

cd "$lang" || { echo "expected the Kyte toolchain at $lang"; exit 1; }
pass=0; fail=0
for t in "$here"/tests/live/*.ky; do
  start_server
  if kyte test "$t" >/tmp/kyteorch_live.log 2>&1 && grep -q "0 failed" /tmp/kyteorch_live.log; then
    echo "PASS  $(basename "$t")"; pass=$((pass+1))
  else
    echo "FAIL  $(basename "$t")"; tail -8 /tmp/kyteorch_live.log; fail=$((fail+1))
  fi
  stop_server
done
rm -f /tmp/kyteorch_live.log
echo "----------------------------------------"
echo "kyte-orchestrator LIVE: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
