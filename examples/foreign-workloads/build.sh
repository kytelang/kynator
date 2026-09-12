#!/usr/bin/env bash
# Build the foreign example apps into <lang>/app. Each language is optional: the script builds the ones
# whose toolchain is installed and skips (with a note) the ones that are not. Run from this directory.
set -u
cd "$(cd "$(dirname "$0")" && pwd)"
built=0

if command -v gcc >/dev/null 2>&1; then
  gcc -O2 -o c/app c/server.c && echo "built c/app (gcc)" && built=$((built+1))
else
  echo "skip C: gcc not installed"
fi

if command -v go >/dev/null 2>&1; then
  ( cd go && CGO_ENABLED=0 go build -o app main.go ) && echo "built go/app (static)" && built=$((built+1))
else
  echo "skip Go: go not installed"
fi

if command -v rustc >/dev/null 2>&1; then
  rustc -O -o rust/app rust/main.rs && echo "built rust/app" && built=$((built+1))
else
  echo "skip Rust: rustc not installed"
fi

if command -v dotnet >/dev/null 2>&1; then
  # Native AOT needs a C toolchain + zlib1g-dev; the publish links a self-contained native ELF.
  # Use the PORTABLE runtime id (linux-arm64 / linux-x64), which the AOT compiler packages target.
  case "$(uname -m)" in
    aarch64|arm64) rid=linux-arm64 ;;
    x86_64|amd64)  rid=linux-x64 ;;
    *)             rid="linux-$(uname -m)" ;;
  esac
  ( cd aspnet && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
      dotnet publish aspnetaot.csproj -c Release -r "$rid" -o out ) \
    && cp aspnet/out/aspnetaot aspnet/app && echo "built aspnet/app (Native AOT, $rid)" && built=$((built+1))
else
  echo "skip ASP.NET: dotnet SDK not installed"
fi

echo "----"
echo "built $built app(s). Point kynatord at one of the checkout.yaml manifests (see README.md)."
[ "$built" -gt 0 ]
