#!/usr/bin/env bash
# LIVE netns + veth isolation demo -- LINUX ONLY (needs `ip` from iproute2 + root/CAP_NET_ADMIN).
# Mirrors net/netns.setupCommands: create a namespace, a veth pair, address both ends, run a tiny HTTP
# server INSIDE the namespace, and prove it is reachable ONLY through the host veth address -- not on any
# host interface. This is the Linux implementation of `network.expose: gateway-only`.
set -u
NS=kyte-demo
HOSTIF=nvh0
APPIF=nva0
HOSTIP=10.66.0.1
APPIP=10.66.0.2
PORT=8080

if [ "$(uname -s)" != "Linux" ]; then
  echo "This demo is Linux-only (netns/veth do not exist on $(uname -s)). Run it on Linux/WSL."
  exit 0
fi
if [ "$(id -u)" != "0" ]; then echo "Run as root (CAP_NET_ADMIN needed for netns/veth)."; exit 1; fi
command -v ip >/dev/null || { echo "iproute2 (ip) not found."; exit 1; }

cleanup(){ ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null; ip link del "$HOSTIF" 2>/dev/null; ip netns del "$NS" 2>/dev/null; }
trap cleanup EXIT
cleanup 2>/dev/null

echo "=== setup (the net/netns recipe) ==="
ip netns add "$NS"
ip link add "$HOSTIF" type veth peer name "$APPIF"
ip link set "$APPIF" netns "$NS"
ip addr add "$HOSTIP/30" dev "$HOSTIF"; ip link set "$HOSTIF" up
ip -n "$NS" addr add "$APPIP/30" dev "$APPIF"
ip -n "$NS" link set "$APPIF" up; ip -n "$NS" link set lo up
ip -n "$NS" route add default via "$HOSTIP"

echo "=== start a server INSIDE the namespace, bound to the private address ==="
ip netns exec "$NS" python3 -m http.server "$PORT" --bind "$APPIP" >/tmp/netns_demo_srv.log 2>&1 &
sleep 1

echo "--- reachable THROUGH the gateway link (host -> $APPIP): expect 200 ---"
curl -s -o /dev/null -w "  gateway path: HTTP %{http_code}\n" "http://$APPIP:$PORT/" || echo "  (failed)"
echo "--- NOT reachable on the host's own loopback (127.0.0.1): expect connection refused ---"
curl -s -m 2 -o /dev/null -w "  host loopback: HTTP %{http_code}\n" "http://127.0.0.1:$PORT/" 2>/dev/null || echo "  host loopback: refused (correct - the app is isolated)"
echo "done."
