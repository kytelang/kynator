#!/usr/bin/env bash
# rolling-drain.sh -- measure that a rolling upgrade drains with ZERO dropped requests
# (ROADMAP-1.0 Tier 2 graceful drain). kynatord rolls one replica at a time (keeping replicas-1 serving),
# `service` load-balances with active health checks, and the proxy retries a failed forward onto a healthy
# backend -- so a request that lands on a mid-swap replica is transparently re-served. Runs on a Linux host
# with systemd. Point BIN at a foreign HTTP server that honours $PORT and echoes a version from an env var.
#
# Zero-drop holds when the surviving replicas can absorb the traffic during a swap (the operator's capacity
# concern, same as Kubernetes maxUnavailable). Use >=3 replicas, or a concurrent server, under saturation.
set +e
BINDIR="${BINDIR:-$(cd "$(dirname "$0")/../../build/debug/bin" && pwd)}"
BIN="${BIN:-/tmp/foreignsvc}"; A="${A:-/tmp/kyn-drain}"; FRONT="${FRONT:-18000}"; REPLICAS="${REPLICAS:-3}"
for u in kdr-orch kdr-svc; do systemctl stop "$u" 2>/dev/null; systemctl reset-failed "$u" 2>/dev/null; done
pkill -9 -f "$BIN" 2>/dev/null; sleep 1; rm -rf "$A"; mkdir -p "$A/manifests"; DISCO="$A/disco.txt"
wm() {  # $1 = version env value; a real spec change triggers the rolling upgrade
cat > "$A/manifests/frontsvc.yaml" <<YAML
apiVersion: kyte/v1
kind: App
metadata: { name: frontsvc }
workload: { workloadType: foreign, binary: $BIN, restartPolicy: always, portEnv: PORT, env: [ "FOO=$1" ] }
replicas: { min: $REPLICAS, max: $REPLICAS }
network: { expose: gateway-only, portBase: 18490 }
health: { probeType: tcp, fall: 2 }
YAML
}
wm v1
printf '{ "manifestsDir": "%s/manifests", "reconcileMs": 1000, "nodeId": "dr", "discoveryFile": "%s", "advertiseHost": "127.0.0.1", "store": { "enabled": false, "addr": "", "token": "", "tls": false } }' "$A" "$DISCO" > "$A/kyn.json"
printf '{ "listenPort": %s, "strategy": "roundrobin", "timeoutMs": 5000, "discoveryFile": "%s", "discoveryService": "frontsvc", "discoveryRefreshMs": 400, "health": { "enabled": true, "path": "/", "intervalMs": 400, "timeoutMs": 800, "rise": 1, "fall": 2 } }' "$FRONT" "$DISCO" > "$A/svc.json"
systemd-run --quiet --unit=kdr-orch --setenv=ORCHD_CONFIG="$A/kyn.json" "$BINDIR/kynatord"; sleep 5
systemd-run --quiet --unit=kdr-svc --setenv=SERVICE_CONFIG="$A/svc.json" "$BINDIR/service"; sleep 3
( for i in $(seq 1 1500); do curl -s --max-time 2 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:$FRONT/ >> "$A/codes.txt"; done ) &
LOAD=$!; sleep 3; echo "=== rolling upgrade v1 -> v2 mid-stream ==="; wm v2; wait $LOAD
TOTAL=$(wc -l < "$A/codes.txt"); OK=$(grep -c '^200$' "$A/codes.txt"); BAD=$(grep -vc '^200$' "$A/codes.txt")
echo "requests total=$TOTAL  200=$OK  dropped(non-200)=$BAD"
for u in kdr-orch kdr-svc; do systemctl stop "$u" 2>/dev/null; systemctl reset-failed "$u" 2>/dev/null; done; pkill -9 -f "$BIN" 2>/dev/null
echo done
