#!/usr/bin/env bash
# Build the binaries of the split orchestrator stack:
#   service  -- the data plane   (L7 reverse proxy / load balancer)
#   kynatord    -- the control plane (nativelet reconcile loop)
#   kynatorctl  -- the operator CLI  (writes desired state, offline ops)
#   artifactd-- the artifact origin (content-addressed blob store for deploy binaries; CI pushes, kynatord pulls)
#
# The operator surface for 1.0 is the CLI (kynatorctl), the declarative manifests, and the config-store
# HTTP API + Prometheus metrics (see docs/OBSERVABILITY.md). A browser control-plane UI was prototyped
# (webui/) but dropped for 1.0 rather than shipped half-built; the reusable server-side read models live on
# in src/orch/controlplane.ky for a future UI.
#
# Each entrypoint lives in bin/ and pulls only its slice of the package via the import graph, so the
# binaries are naturally separated (dead-code elimination drops the unreferenced tier). Run from a
# checkout beside the `lang` toolchain (kyte on PATH). Pass --release for an optimised build.
#
# CROSS-COMPILING (host build matrix): pass --target <triple> to build for another OS/arch. The kyte
# toolchain cross-compiles from any host (macOS, Windows, WSL/Linux). Supported triples:
#   --target linux-x86_64     Linux x86_64
#   --target linux-arm64      Linux aarch64
#   --target macos-x86_64     macOS x86_64 (intel)
#   --target macos-arm64      macOS aarch64 (arm64)
#   --target windows-x86_64   Windows x86_64  (produces .exe)
#   --target windows-arm64    Windows aarch64 (produces .exe)
# Cross binaries land in build/<profile>/<triple>/bin/. Example: ./build.sh --release --target linux-arm64
#
# Native builds use `kyte build` (the fast per-file object cache under build/<profile>/obj). Cross builds
# use kyte's single-file compile mode instead: the build-mode object cache is not target-aware, so mixing
# a native build and a cross build in the same profile dir collides (duplicate symbols at link time).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

profile_flag=""
profile="debug"
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release|-r) profile_flag="--release"; profile="release" ;;
    --target|-t)
      shift
      target="${1:-}"
      if [ -z "$target" ]; then echo "error: --target needs a triple (e.g. linux-arm64)" >&2; exit 2; fi
      ;;
    --target=*) target="${1#--target=}" ;;
    *) echo "warning: ignoring unknown argument '$1'" >&2 ;;
  esac
  shift
done

# Per-binary build. Native = `kyte build --file` (cached); cross = single-file compile with --target.
ext=""
if [ -n "$target" ]; then
  case "$target" in
    windows-x86_64|windows-arm64) ext=".exe" ;;
    linux-x86_64|linux-arm64|macos-x86_64|macos-arm64) ext="" ;;
    *) echo "error: unknown --target '$target'. Supported: linux-x86_64 linux-arm64 macos-x86_64 macos-arm64 windows-x86_64 windows-arm64" >&2; exit 2 ;;
  esac
  outdir="build/$profile/$target/bin"
else
  outdir="build/$profile/bin"
fi

build_one() { # $1 = name, $2 = source .ky
  local name="$1" src="$2"
  if [ -n "$target" ]; then
    kyte "$src" -o "$outdir/$name$ext" $profile_flag --target "$target" >/dev/null
  else
    kyte build --file "$src" -o "$outdir/$name" $profile_flag >/dev/null
  fi
}

mkdir -p "$outdir"
echo "Building service (data plane)...${target:+ [target=$target]}"
build_one service bin/service.ky
echo "Building kynatord (control plane)...${target:+ [target=$target]}"
build_one kynatord bin/kynatord.ky
echo "Building kynatorctl (operator CLI)...${target:+ [target=$target]}"
build_one kynatorctl bin/kynatorctl.ky
echo "Building artifactd (blob origin)...${target:+ [target=$target]}"
build_one artifactd bin/artifactd.ky
echo "Built:"
echo "  $outdir/service$ext"
echo "  $outdir/kynatord$ext"
echo "  $outdir/kynatorctl$ext"
echo "  $outdir/artifactd$ext"
echo
echo "Validate a config without serving:  $outdir/service$ext service.json --check"
