# Runbook: leader loss

**Symptom.** No node is reconciling desired state: a deploy or scale change does not take effect, and
`orch_leader_epoch` is 0 on every node (or the previous leader's host is down). `orch_under_provisioned`
may climb as crashed replicas are not replaced.

## Diagnose

```sh
# On each node, read the metrics file (docs/OBSERVABILITY.md). Exactly one node should have epoch > 0.
grep -H orch_leader_epoch /var/lib/node_exporter/textfile/kynatord.prom   # per node
# Or from a monitoring host: which node holds the lease?
cfg "$STORE/cfg/get" -H "x-cfg-key: leases/kynatord"     # 200 + body = current lease; 404 = no leader
```

If the store shows no live lease and all nodes report epoch 0, leadership genuinely lapsed (the old leader
died and its lease TTL expired without a survivor taking over yet).

## Act

The lease is self-healing: a healthy standby takes over within one lease TTL (a few reconcile periods,
floored at 15s). So first, **confirm the survivors are up and can reach the store**:

```sh
systemctl is-active kynatord            # on each surviving node -> active
cfg -o /dev/null -w '%{http_code}\n' "$STORE/cfg/ping"   # 200 = store reachable
```

- If a survivor is `inactive`/`failed`, restart it: `sudo systemctl restart kynatord`. It will contend for
  the lease and, if it wins, begin reconciling.
- If the store itself is unreachable, no node can take the lease - follow
  [store-outage.md](store-outage.md) first; leadership returns once the store is back.

## Expected result

Within one lease TTL, exactly one surviving node shows `orch_leader_epoch > 0` (a value HIGHER than the old
leader's, because each takeover bumps the fencing epoch), it begins reconciling, and
`orch_under_provisioned` returns to 0 as it restores every workload to desired count. Verify:

```sh
# exactly one non-zero epoch across the cluster, and it increased vs the previous leader's:
for n in node-1 node-2 node-3; do ssh $n "grep orch_leader_epoch /var/lib/node_exporter/textfile/kynatord.prom"; done
```
