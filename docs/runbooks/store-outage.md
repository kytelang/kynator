# Runbook: config-store outage

**Symptom.** `orch_store_reachable` is 0 on one or more nodes (the `KynatorStoreUnreachable` alert fires).
Deploys and scale changes do not apply. `orch_ready` drops (a node that cannot reach the store is not
ready to hold leadership).

## What kynator does on its own

A store outage is handled defensively, not catastrophically:

- A node that cannot reach the store **steps down** (clears `isLeader`) and reconciles NOTHING new - it
  does not read an empty store and mistake it for "no workloads desired", so it never tears the fleet down.
- **Already-running replicas keep running.** Discovery publication and health probes continue every tick,
  so a node keeps its existing replicas healthy (restarting a crashed one) even while the store is down.

So an outage freezes desired-state changes; it does not drop running workloads.

## Diagnose

```sh
cfg -o /dev/null -w '%{http_code}\n' "$STORE/cfg/ping"     # not 200 -> store is down or unreachable
systemctl is-active kyn-artd 2>/dev/null || systemctl is-active artifactd   # if artifactd hosts the store
grep -H orch_store_reachable /var/lib/node_exporter/textfile/kynatord.prom  # which nodes lost it
```

Distinguish "store process down" from "network partition to the store" - the fix differs.

## Act

- **Store process down** (artifactd or your object/config store): restart it.
  `sudo systemctl restart artifactd` (or your store's unit). Its state is durable
  (`<KYTE_ARTIFACT_ROOT>/config.snap` for artifactd), so it comes back with the last committed desired
  state.
- **Network partition:** restore connectivity; no kynator action is needed - nodes reconnect on their next
  tick.
- **Do NOT** delete the manifests directory or push an empty desired state while debugging; a healthy leader
  would then legitimately tear workloads down.

## Expected result

`cfg "$STORE/cfg/ping"` returns 200; `orch_store_reachable` returns to 1 on every node; a node wins the
lease (`orch_leader_epoch > 0`) and resumes reconciling; queued deploys/scale changes apply. Running
workloads that were up throughout stay up. Confirm the store round-trips and its wire version is unchanged:

```sh
cfg "$STORE/cfg/version"                                   # -> kyte-cfg/1
cfg "$STORE/cfg/get" -H "x-cfg-key: leases/kynatord"       # a live holder again
```
