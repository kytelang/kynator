# Runbook: suspected split brain (two leaders)

**Symptom.** More than one node reports `orch_leader_epoch > 0` at the same time (the `KynatorSplitBrain`
alert fires: `count(orch_leader_epoch > 0) > 1`). You worry two nodes are both driving the fleet.

## What is actually happening

kynator's lease is a compare-and-set with a monotone fencing epoch: only one node can hold the store's
`leases/kynatord` row at a given epoch, and the config store rejects any stamped write below the current
high-water. So **two nodes cannot both perform accepting writes** - the fenced old leader's writes get a
`412` and it steps itself down. A momentary "two non-zero epochs" reading is almost always a **stale
metrics file** from a node that already lost the lease but whose last-written `.prom` still shows its old
epoch (the file is only rewritten each tick).

## Diagnose

```sh
# The store is the single source of truth for who holds the lease RIGHT NOW:
cfg "$STORE/cfg/get" -H "x-cfg-key: leases/kynatord"     # body encodes holder + epoch

# Compare each LIVE node's epoch to the store's. Only count nodes whose unit is active:
for n in node-1 node-2 node-3; do
  ssh $n 'echo -n "$(hostname) active=$(systemctl is-active kynatord) "; grep orch_leader_epoch /var/lib/node_exporter/textfile/kynatord.prom'
done
```

If the store shows a single holder at the highest epoch, there is no split brain - the extra reading is a
dead or fenced node's stale file.

## Act

- **A fenced/old node still `active` but not the holder:** it is harmless (its writes are rejected), but to
  clear the alert restart it so it re-reads the lease and reconciles as a standby:
  `sudo systemctl restart kynatord`.
- **A partitioned node that cannot reach the store:** it has already cleared its own `isLeader`
  (a leader that loses the store steps down) and reconciles nothing; heal the network or stop the node.
- **Genuinely two holders at the same epoch:** this must not happen with a single config store; it would
  mean two DIFFERENT stores are in play. Confirm every node's `store.addr` points at the SAME store and the
  same `/cfg/version` (`cfg "$STORE/cfg/version"` -> `kyte-cfg/1`), and remove the rogue store.

## Expected result

The store shows exactly one holder; every live node's `orch_leader_epoch` agrees (one non-zero, the rest 0);
the `KynatorSplitBrain` alert clears. Workloads were never double-driven - the fence guaranteed it.
