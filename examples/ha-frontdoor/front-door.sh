#!/usr/bin/env bash
# front-door.sh -- live proof of the data-plane front door tracking the control plane.
#
# What it shows (ROADMAP-1.0 Tier 1 #4): kynatord supervises a foreign workload and publishes each replica's
# endpoint to a discovery file; `service` load-balances across that live set through ONE front port and
# re-reads the discovery file on its own tick. Scale the workload up and down and the traffic set follows,
# with zero manual reconfig.
#
# Runs on a Linux host with systemd (uses systemd-run so a killed daemon's child replicas die with it, and
# so daemon stdout is not swallowed). Point BIN at any foreign HTTP server that honours $PORT and answers
# GET / with a body containing "port=<n>"; the examples/foreign-workloads C/Go/Rust/ASP.NET apps all do.
set +e
BINDIR="${BINDIR:-$(cd "$(dirname "$0")/../../build/debug/bin" && pwd)}"   # kynatord + service live here
BIN="${BIN:-/tmp/foreignsvc}"                                             # the foreign workload binary
A="${A:-/tmp/kyn-frontdoor}"                                              # scratch root
FRONT="${FRONT:-18000}"                                                   # public front port

for u in kfd-orch kfd-svc; do systemctl stop "$u" 2>/dev/null; systemctl reset-failed "$u" 2>/dev/null; done
pkill -9 -f "$BIN" 2>/dev/null; sleep 1
rm -rf "$A"; mkdir -p "$A/manifests"
DISCO="$A/discovery.txt"

writeManifest() {   # $1 = replica count
  cat > "$A/manifests/frontsvc.yaml" <<YAML
apiVersion: kyte/v1
kind: App
metadata:
  name: frontsvc
workload:
  workloadType: foreign
  binary: $BIN
  restartPolicy: always
  portEnv: PORT
replicas:
  min: $1
  max: $1
network:
  expose: gateway-only
  portBase: 18490
health:
  probeType: tcp
YAML
}
writeManifest 2

cat > "$A/kynatord.json" <<JSON
{ "manifestsDir": "$A/manifests", "reconcileMs": 1000, "nodeId": "node-fd",
  "discoveryFile": "$DISCO", "advertiseHost": "127.0.0.1",
  "store": { "enabled": false, "addr": "", "token": "", "tls": false } }
JSON
cat > "$A/service.json" <<JSON
{ "listenPort": $FRONT, "strategy": "roundrobin", "timeoutMs": 5000,
  "discoveryFile": "$DISCO", "discoveryService": "frontsvc", "discoveryRefreshMs": 500,
  "health": { "enabled": true, "path": "/", "intervalMs": 500, "timeoutMs": 800, "rise": 1, "fall": 2 } }
JSON

systemd-run --quiet --unit=kfd-orch --setenv=ORCHD_CONFIG="$A/kynatord.json" "$BINDIR/kynatord"
sleep 5
systemd-run --quiet --unit=kfd-svc --setenv=SERVICE_CONFIG="$A/service.json" "$BINDIR/service"
sleep 3

sample() {   # $1 label, $2 count -- print the distribution of replica ports the front port served
  declare -A seen; local ok=0
  for i in $(seq 1 "$2"); do
    p=$(curl -s --max-time 2 "http://127.0.0.1:$FRONT/" | grep -oE "port=[0-9]+" | cut -d= -f2)
    [ -n "$p" ] && { seen[$p]=$(( ${seen[$p]:-0} + 1 )); ok=$((ok+1)); }
  done
  echo "$1: $ok/$2 OK, ports -> $(for k in $(echo "${!seen[@]}" | tr ' ' '\n' | sort); do echo -n "$k(${seen[$k]}) "; done)"
}

echo "--- scale=2 ---"; sample "front :$FRONT" 12
echo "--- scale UP to 3 ---"; writeManifest 3; sleep 9; sample "front :$FRONT" 12
echo "--- scale DOWN to 1 ---"; writeManifest 1; sleep 9; sample "front :$FRONT" 12

for u in kfd-orch kfd-svc; do systemctl stop "$u" 2>/dev/null; systemctl reset-failed "$u" 2>/dev/null; done
pkill -9 -f "$BIN" 2>/dev/null
echo done
