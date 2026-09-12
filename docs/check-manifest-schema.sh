#!/usr/bin/env bash
# Drift lint: every @serializable manifest struct field in src/orch/manifest.ky must appear in
# docs/MANIFEST.md, so the schema reference cannot silently fall out of date. Run from gate.sh.
# Exits non-zero (listing the missing fields) if any YAML-bearing field has no reference entry.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/src/orch/manifest.ky"
doc="$here/docs/MANIFEST.md"
[ -f "$src" ] || { echo "manifest-schema lint: $src not found"; exit 1; }
[ -f "$doc" ] || { echo "manifest-schema lint: $doc not found"; exit 1; }

# `bindError` is an internal parser field, not a YAML key -> excluded (documented as internal in MANIFEST.md).
EXCLUDE="bindError"

missing=0
# Field names are the `pub <name>:` lines inside the structs.
for f in $(grep -oE '^[[:space:]]+pub [a-zA-Z][a-zA-Z0-9]*:' "$src" | sed -E 's/.*pub ([a-zA-Z0-9]+):/\1/' | sort -u); do
    case " $EXCLUDE " in *" $f "*) continue;; esac
    # A field is documented if its name appears as `\`field\`` anywhere in the reference.
    if ! grep -q "\`$f\`" "$doc"; then
        echo "manifest-schema lint: field '$f' has no entry in docs/MANIFEST.md"
        missing=$((missing+1))
    fi
done

if [ "$missing" -gt 0 ]; then
    echo "manifest-schema lint: FAIL ($missing undocumented field(s)) -- update docs/MANIFEST.md"
    exit 1
fi
echo "manifest-schema lint: OK (every manifest field is documented)"
