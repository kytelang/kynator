# Observability runbook

kynatord publishes Prometheus-format metrics for the node and every workload it supervises. This page
lists the series, the supported scrape path, and a starter set of alert rules an operator can act on.

## Where the metrics come from

Set `metricsFile` in the kynatord config to a path a Prometheus **node_exporter textfile collector** reads
(the conventional `--collector.textfile.directory`). kynatord rewrites that file every reconcile tick with
the current node + per-workload state, so the collector picks it up on its next scrape. There is no listen
port on kynatord itself (it is the control plane, not a server); the textfile collector is the supported
scrape path.

```json
{ "nodeId": "node-a", "manifestsDir": "/etc/kyn/manifests", "reconcileMs": 1000,
  "metricsFile": "/var/lib/node_exporter/textfile/kynatord.prom",
  "store": { "enabled": true, "addr": "cfg.internal:8135", "token": "…", "tls": true } }
```

## Series

Node-level (one sample each):

| Series | Meaning |
|---|---|
| `orch_up` | 1 when the node's own health is OK |
| `orch_ready` | 1 when this node may take its role's traffic (reachable and a valid, unfenced role) |
| `orch_store_reachable` | 1 when the config store round-trips (0 = degraded; a leader steps down) |
| `orch_leader_epoch` | the fencing epoch this node holds (0 when not the leader) |
| `orch_workloads_total` | number of workloads reconciled on this node |
| `orch_running_total` | total replicas running across all workloads |
| `orch_under_provisioned` | number of workloads currently below their desired replica count (0 = converged) |
| `orch_reconcile_latency_ms` | wall-clock of the last reconcile tick |
| `orch_replication_lag_frames` | leader WAL LSN minus this follower's confirmed seq (0 on the leader) |

Per-workload (labelled `{workload="<name>"}`):

| Series | Meaning |
|---|---|
| `orch_workload_desired` | desired replica count (the manifest's `replicas`) |
| `orch_workload_running` | replicas currently running |
| `orch_workload_restarts` | cumulative replica restarts (crash-loop signal) |
| `orch_workload_probe_failures` | consecutive failed heal probes right now (0 = healthy) |
| `orch_workload_rolling` | 1 while a rolling upgrade of this workload is in progress |

Alert series (`orch_alert{...}`) are also emitted when thresholds are crossed; see `orch/alerts.ky`.

## Starter alert rules

```yaml
groups:
  - name: kynator
    rules:
      - alert: KynatorStoreUnreachable
        expr: orch_store_reachable == 0
        for: 1m
        annotations: { summary: "kynatord {{ $labels.instance }} cannot reach the config store" }

      - alert: KynatorUnderProvisioned
        expr: orch_under_provisioned > 0
        for: 5m
        annotations: { summary: "A workload has been below its desired replica count for 5m" }

      - alert: KynatorNoLeader
        # across the cluster, exactly one node should hold a non-zero epoch
        expr: max(orch_leader_epoch) == 0
        for: 1m
        annotations: { summary: "No kynatord node holds the leader lease" }

      - alert: KynatorSplitBrain
        expr: count(orch_leader_epoch > 0) > 1
        for: 30s
        annotations: { summary: "More than one kynatord node claims leadership" }

      - alert: KynatorCrashLoop
        # a workload accumulating restarts fast
        expr: increase(orch_workload_restarts[5m]) > 5
        annotations: { summary: "Workload {{ $labels.workload }} is crash-looping" }

      - alert: KynatorProbeFailing
        expr: orch_workload_probe_failures >= 2
        for: 1m
        annotations: { summary: "Workload {{ $labels.workload }} is failing its heal probe" }

      - alert: KynatorRollingStuck
        expr: orch_workload_rolling == 1
        for: 10m
        annotations: { summary: "Workload {{ $labels.workload }} has been rolling for 10m" }
```

The per-workload `desired` vs `running` pair is the primary "is the fleet at desired state?" view; the
`restarts`, `probe_failures`, and `rolling` series explain *why* a workload is not, so an on-call operator
can act (roll back a bad deploy, fix a failing dependency, add capacity) without shelling into the node.
