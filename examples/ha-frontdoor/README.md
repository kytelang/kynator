# HA failover and the data-plane front door

Two live, multi-process reproducers for the Tier 1 platform claims. Both run on a Linux host with systemd
(the scripts use `systemd-run` so a killed daemon's child replicas die with it, and so daemon output is not
swallowed). They are the exact scenarios used to close ROADMAP-1.0 Tier 1 items #3 and #4.

## Prerequisites

- A release build of kynator: `KYTE_LLVM_PREFIX=/usr/lib/llvm-21 ./build.sh` (or a debug build; the scripts
  default to `build/debug/bin`). Override with `BINDIR=/path/to/bin`.
- A foreign HTTP server binary that honours the `PORT` environment variable and answers `GET /` with a body
  containing `port=<n>`. Any of the apps in `examples/foreign-workloads` (C, Go, Rust, ASP.NET AOT) work.
  Build one and point the scripts at it with `BIN=/path/to/server`.

## front-door.sh (Tier 1 #4)

kynatord supervises a foreign workload and publishes each replica's endpoint to a discovery file; `service`
load-balances across that live set through one front port and re-reads the discovery file on its own tick.

```sh
BIN=/tmp/foreignsvc ./front-door.sh
```

Expected: at `replicas: 2` the front port spreads evenly across both ports; scaling to 3 adds the new
replica to the rotation; scaling to 1 drains the pool to the survivor. All requests succeed at every step,
with no manual reconfiguration.

## ha-failover.sh (Tier 1 #3)

Three kynatord nodes run in store-backed HA mode against one artifactd config store. A foreign workload is
seeded into the store. Exactly one node leads and reconciles it to desired; kill the leader and a survivor
takes over, restoring desired, with never more than one live leader (no split brain).

```sh
BIN=/tmp/foreignsvc ./ha-failover.sh
```

Expected: one leader (`epoch=1`) runs two replicas; the others stand by (`epoch=0`). After the leader is
killed there is a brief no-leader gap while the lease TTL expires, then exactly one survivor takes over
(`epoch=2`) and restores two replicas. `max simultaneous LIVE leaders during failover: 1`. RTO is about the
lease TTL (a few reconcile periods, floored at 15s).

The deterministic, in-process counterpart (RPO=0 and measured RTO under injected partitions) is the CI gate
`tests/198_ha_cluster.ky`; this script is the honest multi-process cluster proof on top of it.
