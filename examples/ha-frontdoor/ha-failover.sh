#!/usr/bin/env bash
# ha-failover.sh -- live multi-node HA failover proof (ROADMAP-1.0 Tier 1 #3).
#
# What it shows: three kynatord nodes run in store-backed HA mode against ONE artifactd config store. A
# foreign workload (replicas: 2) is seeded into the store's workloads/ prefix. Exactly one node holds the
# leader lease and reconciles the workload to its desired count; the others stand by. Kill the leader and a
# survivor takes over, restoring the workload to desired -- with never more than one LIVE leader at a time
# (no split brain). RTO is about the lease TTL (a few reconcile periods, floored at 15s).
#
# Runs on a Linux host with systemd. Point BIN at any foreign HTTP server that honours $PORT.
set +e
BINDIR="${BINDIR:-$(cd "$(dirname "$0")/../../build/debug/bin" && pwd)}"
BIN="${BIN:-/tmp/foreignsvc}"
A="${A:-/tmp/kyn-hasoak}"
TOK="${TOK:-hatok123}"
STORE="${STORE:-127.0.0.1:8135}"

for u in kha-store kha1 kha2 kha3; do systemctl stop "$u" 2>/dev/null; systemctl reset-failed "$u" 2>/dev/null; done
pkill -9 -f "$BIN" 2>/dev/null; sleep 1; rm -rf "$A"; mkdir -p "$A"

# 1. config store (artifactd hosts the control-plane KV: specs, leases, membership).
systemd-run --quiet --unit=kha-store --setenv=KYTE_PORT=8135 --setenv=KYTE_ARTIFACT_ROOT="$A/store" --setenv=KYTE_ARTIFACT_TOKEN="$TOK" "$BINDIR/artifactd"
sleep 2
put() { curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOK" -H "x-cfg-key: $1" --data-binary "$2" "http://$STORE/cfg/put"; }

# 2. register 3 members + seed one foreign workload (replicas 2) into the store.
for n in ha1 ha2 ha3; do put "members/$n" "$n"; done
printf 'apiVersion: kyte/v1\nkind: App\nmetadata:\n  name: frontsvc\nworkload:\n  workloadType: foreign\n  binary: %s\n  restartPolicy: always\n  portEnv: PORT\nreplicas:\n  min: 2\n  max: 2\nnetwork:\n  expose: gateway-only\n  portBase: 18490\nhealth:\n  probeType: tcp\n' "$BIN" > "$A/mani.yaml"
curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOK" -H "x-cfg-key: workloads/frontsvc" --data-binary @"$A/mani.yaml" "http://$STORE/cfg/put"

# 3. start 3 kynatord nodes in store-backed HA mode.
for n in 1 2 3; do
  printf '{ "manifestsDir": "%s/unused", "reconcileMs": 1000, "nodeId": "ha%s", "metricsFile": "%s/m%s.prom", "crashLoopRestarts": 5, "store": { "enabled": true, "addr": "%s", "token": "%s", "tls": false } }' "$A" "$n" "$A" "$n" "$STORE" "$TOK" > "$A/kyn$n.json"
  systemd-run --quiet --unit=kha$n --setenv=ORCHD_CONFIG="$A/kyn$n.json" "$BINDIR/kynatord"
done

mget() { grep "^$2 " "$A/m$1.prom" 2>/dev/null | awk '{print $2}'; }
# count only LIVE (active-unit) leaders: a killed node's last-written metrics file lingers with its old epoch.
leadcnt() { local c=0; for n in 1 2 3; do [ "$(systemctl is-active kha$n 2>/dev/null)" = active ] || continue; e=$(mget $n orch_leader_epoch); [ -n "$e" ] && [ "$e" -gt 0 ] 2>/dev/null && c=$((c+1)); done; echo $c; }
dump() { for n in 1 2 3; do echo "   ha$n[$(systemctl is-active kha$n 2>/dev/null)] epoch=$(mget $n orch_leader_epoch) running=$(mget $n orch_running_total)"; done; echo "   replica procs=$(pgrep -c -f "$BIN")"; }

echo "--- settle 10s ---"; sleep 10; dump; echo "live leaders: $(leadcnt)"
LN=""; for n in 1 2 3; do e=$(mget $n orch_leader_epoch); [ -n "$e" ] && [ "$e" -gt 0 ] 2>/dev/null && LN=$n; done
echo "=== KILL leader ha$LN ==="; systemctl stop kha$LN; systemctl reset-failed kha$LN 2>/dev/null
SBMAX=0
for i in $(seq 1 9); do sleep 3; c=$(leadcnt); [ "$c" -gt "$SBMAX" ] && SBMAX=$c; echo "t=+$((i*3))s live_leaders=$c"; dump; done
echo "max simultaneous LIVE leaders during failover: $SBMAX (1 = no split brain)"

for u in kha-store kha1 kha2 kha3; do systemctl stop "$u" 2>/dev/null; systemctl reset-failed "$u" 2>/dev/null; done
pkill -9 -f "$BIN" 2>/dev/null
echo done
