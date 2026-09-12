#!/usr/bin/env bash
# Live end-to-end handoff deployment (the shape kynatord drives from a manifest): from ONE workload name it
# derives the rendezvous /tmp/kyte-<name>.sock, starts the SERVICE (gateway) with KYTE_HANDOFF_SOCK +
# KYTE_PORT, starts N APP replicas with KYTE_HANDOFF_SOCK, and curls the front port. The Kyte equivalent
# - via supervisors + manifest.serviceSpecFor/toSpec - is in deploy.ky (what kynatord runs); it sets the
# same env. (The app's connect-backoff means launch ordering no longer matters.)
set -u
export PATH="$HOME/.kyte/bin:$PATH"
REPO=/Users/kamlesh/kyte-lang
SVC="$REPO/packages/kyte-orchestrator/build/debug/bin/service"
APP="$REPO/lang/docs/guide/examples/webapp/build/debug/bin/webapp"
NAME=shop; SOCK="/tmp/kyte-$NAME.sock"; PORT=8140
cleanup(){ pkill -9 -x service 2>/dev/null; pkill -9 -x webapp 2>/dev/null; rm -f "$SOCK"; }
trap cleanup EXIT
cleanup; sleep 0.3
[ -x "$SVC" ] || { echo "build service: (cd packages/kyte-orchestrator && ./build.sh)"; exit 1; }
[ -x "$APP" ] || { echo "build the webapp first"; exit 1; }

echo "deploying '$NAME': service on :$PORT (handoff $SOCK) + 2 app replicas"
KYTE_HANDOFF_SOCK="$SOCK" KYTE_PORT="$PORT" "$SVC" >/tmp/nd_svc.log 2>&1 &
KYTE_HANDOFF_SOCK="$SOCK" "$APP" >/tmp/nd_a1.log 2>&1 &
KYTE_HANDOFF_SOCK="$SOCK" "$APP" >/tmp/nd_a2.log 2>&1 &
sleep 2
echo "--- curl the front port :$PORT (client -> service -> handoff -> app) ---"
for i in 1 2 3 4; do curl -s -m 3 -o /dev/null -w "  req$i: HTTP %{http_code}\n" "http://127.0.0.1:$PORT/api/products/1"; done
echo "backends connected to the service: $(grep -c 'backend app connected' /tmp/nd_svc.log)"
echo "done."
