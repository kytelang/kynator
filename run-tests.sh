#!/usr/bin/env bash
# Run every package test via `kyte test`. Stdlib now resolves from the installed toolchain (~/.kyte/std),
# so CWD no longer needs to be the toolchain source dir. We still cd into the toolchain checkout when one
# is found beside this repo (monorepo: `../kyte`; legacy sibling: `../../lang`), because a source checkout
# lets the resolver pick up an in-tree stdlib during development; if neither exists we run from this repo
# and rely on the install. The `../packages` resolver finds this package's own modules either way.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$here/../kyte/src" ]; then
  cd "$here/../kyte"
elif [ -d "$here/../../lang/src" ]; then
  cd "$here/../../lang"
else
  cd "$here"   # no toolchain source checkout; stdlib comes from ~/.kyte/std
fi
pass=0; fail=0
# nullglob: a directory with no .ky files must expand to NOTHING, not to the literal pattern, so an
# empty glob never hands the compiler a literal `*.ky` (which would report a phantom FAIL).
shopt -s nullglob
for t in "$here"/tests/*.ky; do
  if kyte test "$t" >/tmp/kyteorch.log 2>&1 && grep -q "0 failed" /tmp/kyteorch.log; then
    echo "PASS  $(basename "$t")"; pass=$((pass+1))
  else
    echo "FAIL  $(basename "$t")"; tail -6 /tmp/kyteorch.log; fail=$((fail+1))
  fi
done
rm -f /tmp/kyteorch.log
echo "----------------------------------------"
echo "kyte-orchestrator: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
