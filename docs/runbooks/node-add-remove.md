# Runbook: add or remove a cluster node

**Symptom / trigger.** You are scaling the control plane in or out: a new host should join the HA cluster,
or a decommissioned host should leave it. Membership is what the quorum gate counts (a leader must be a
registered member, and it needs a majority of members reachable), so it must be kept accurate.

Members live under the `members/<id>` prefix in the config store. There are two ways to edit them: live
(a `POST /cfg/put` against the running store) or offline (`kynatorctl` on a backup dump, then restore).

## Add a node

1. **Install and configure** the new host per `docs/INSTALL.md`, HA mode: `store.enabled: true`, the shared
   `store.addr`/token, a UNIQUE `nodeId` (e.g. `node-4`), and (recommended) a `metricsFile`.

2. **Register it as a member** so quorum counts it and it may hold the lease:

```sh
# live:
cfg -X POST -H "x-cfg-key: members/node-4" --data-binary "node-4" "$STORE/cfg/put"
# or offline, editing a backup dump then restoring it:
kynatorctl member add cluster.dump node-4 10.0.0.4:8135
kynatorctl members cluster.dump                     # verify it is listed
# (then push the dump back to the store via your restore procedure)
```

3. **Start it:** `sudo systemctl enable --now kynatord`. It joins as a standby (it will not win the lease
   unless the current leader lapses).

## Remove a node

1. **Drain / stop** the node's kynatord so it stops contending and its replicas are released:
   `sudo systemctl disable --now kynatord` on that host. If it was the leader, a survivor takes over within
   one lease TTL (see [leader-loss.md](leader-loss.md)).

2. **Deregister it** so quorum no longer expects it (leaving a dead member inflates the majority threshold):

```sh
cfg -X POST -H "x-cfg-key: members/node-4" --data-binary "" "$STORE/cfg/put"   # tombstone the row
# or offline:
kynatorctl member remove cluster.dump node-4
```

## Expected result

```sh
cfg "$STORE/cfg/list" -H "x-cfg-prefix: members/"   # the member set matches the live hosts
```

The `members/` set matches the running hosts; quorum is a majority of that set. After an add, the new node
appears with `orch_up == 1` and reconciles as a standby; after a remove, the remaining nodes still elect a
single leader and workloads stay at desired count. Keep the member count ODD (3, 5) so a clean majority
always exists.
