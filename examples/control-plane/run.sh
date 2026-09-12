#!/usr/bin/env bash
# Kyte control plane - a live Datastar dashboard over the orchestrator app registry.
# Builds and serves it; the browser page loads Datastar from the CDN and patches the apps table.
set -u
export PATH="$HOME/.kyte/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE/../.."   # package root
pkill -9 -x controld 2>/dev/null; sleep 0.3
echo "building control plane ..."
kyte build --file examples/control-plane/main.ky -o /tmp/controld >/dev/null || { echo "build failed"; exit 1; }
echo "serving on http://127.0.0.1:8130  (Ctrl-C to stop) ..."
/tmp/controld &
srv=$!; sleep 1.2
echo "--- GET / (dashboard shell) ---";      curl -s -i http://127.0.0.1:8130/        | grep -iE "Content-Type|data-on-load|datastar@"
echo "--- GET /api/apps (Datastar SSE) ---"; curl -s -i http://127.0.0.1:8130/api/apps | grep -iE "Content-Type|event: datastar|data: elements" | head -3
echo "open http://127.0.0.1:8130/ in a browser to see the live-refreshing table."
wait $srv
