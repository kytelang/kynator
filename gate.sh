#!/usr/bin/env bash
# Host gate for the orchestrator stack (service data plane + kynatord control plane + kynatorctl operator
# surfaces). Builds all binaries and runs the full Kyte test suite on THIS host OS, exiting non-zero on any
# failure. Needs `kyte`
# on PATH (from the lang gate's `zig build`) and the lang toolchain beside this repo. See CI-POLICY.md.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.kyte/bin:$PATH"
OS="$(uname -s)-$(uname -m)"
fail=0
step() { echo; echo ">>> $* [$OS]"; }

step "build service + kynatord + kynatorctl + artifactd"
./build.sh || fail=1

if [ $fail -eq 0 ]; then
  step "kyte test (offline deterministic suite: config, discovery, alerts, lifecycle, HA cluster, operability)"
  ./run-tests.sh || fail=1
fi

if [ $fail -eq 0 ]; then
  step "manifest-schema drift lint (docs/MANIFEST.md in sync with manifest.ky)"
  ./docs/check-manifest-schema.sh || fail=1
fi

# Opt-in LIVE gate: with KYTE_LIVE=1 and a built NovaDB beside the toolchain, also run the live HA tests
# (real store round-trips: split-brain CAS + server-side FENCE). Off by default so the merge gate stays
# offline and server-free; CI that has a NovaDB build sets KYTE_LIVE=1 to prove the live path too.
if [ $fail -eq 0 ] && [ "${KYTE_LIVE:-0}" = "1" ]; then
  step "live HA tests vs a fresh NovaDB (opt-in: KYTE_LIVE=1)"
  ./run-live-tests.sh || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  orchestrator (service/kynatord/kynatorctl/artifactd)  [$OS]"; else echo "GATE FAIL  orchestrator  [$OS]"; fi
exit $fail
