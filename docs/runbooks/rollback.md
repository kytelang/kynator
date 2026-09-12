# Runbook: roll back a bad deploy

**Symptom.** A deploy made things worse: the new version crash-loops (`orch_workload_restarts` climbing,
`KynatorCrashLoop` alert), fails its probe (`orch_workload_probe_failures >= 2`), or serves errors. The
workload may be stuck mid-roll (`orch_workload_rolling == 1` for a long time).

## Principle

Desired state is a single manifest in the config store under `workloads/<name>`. A deploy REPLACED that
value; a rollback is putting the previous value back. kynatord's reconcile loop then rolls the workload
back to it exactly as it rolled forward - one replica at a time, keeping `replicas-1` serving (see the
graceful-drain result in `ROADMAP-1.0.md`).

Always keep the previous manifest. If you deploy from a git-tracked manifests directory, the previous
version is in git; if you deploy straight to the store, snapshot the old value first:

```sh
cfg "$STORE/cfg/get" -H "x-cfg-key: workloads/web" > web.prev   # BEFORE any deploy
```

## Diagnose

```sh
# Which workload is unhealthy, and how?
grep -E 'orch_workload_(restarts|probe_failures|rolling)\{workload="web"\}' /var/lib/node_exporter/textfile/kynatord.prom
```

Confirm it is the new version at fault (not a dependency/store outage - see the other runbooks).

## Act

Put the previous manifest back under the same key. The value is the FULL YAML manifest (see
`docs/MANIFEST.md`); a rollback is byte-for-byte the old manifest.

```sh
# from a snapshot taken before the deploy:
cfg -X POST -H "x-cfg-key: workloads/web" --data-binary @web.prev "$STORE/cfg/put"
# or from a git-tracked manifests dir (standalone/manifest mode): git checkout the file, and either
#   - restore it into the manifests directory kynatord watches, or
#   - re-put it to the store as above.
git -C /etc/kyn checkout HEAD~1 -- manifests/web.yaml
cfg -X POST -H "x-cfg-key: workloads/web" --data-binary @/etc/kyn/manifests/web.yaml "$STORE/cfg/put"
```

For a workload with a pre-rollout `migrate` step, remember migrations must be expand-only, so the previous
version tolerates the new schema - a code rollback does not require a schema rollback.

## Expected result

The leader detects the changed (reverted) spec and rolls the workload back to the previous version. Within
a few reconcile + roll-grace ticks: `orch_workload_rolling` returns to 0, `orch_workload_restarts` stops
climbing, `orch_workload_probe_failures` returns to 0, and requests succeed again. Confirm the running
version:

```sh
curl -s http://<front-port>/            # serves the previous version again
```
