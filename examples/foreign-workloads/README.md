# Foreign workloads: supervising any binary

These examples show Kynator supervising a **foreign** (non-Kyte) binary: a Go service, a Rust daemon,
a C server, and an ASP.NET Web API built with **Native AOT**. Each is a plain HTTP server that reads its
port from an environment variable and echoes a `FOO` value, so you can watch the orchestrator deliver the
port and environment, own the exec bit, and keep replicas alive, without any of it being written in Kyte.

Every workload sets `workloadType: foreign` in its manifest. That makes Kynator drop the Kyte-only
conventions the binary cannot speak:

- the assigned port is delivered through the env var named by `portEnv` (Go/Rust/C read `PORT`; ASP.NET
  Core reads `ASPNETCORE_HTTP_PORTS`),
- `env` entries and an optional `workdir` are applied per child at spawn,
- the workload is placed on a real listening port (`network.portBase`) that the `service` gateway
  byte-forwards to (foreign workloads never use Kyte fd-handoff),
- the heal probe is `health.probeType: tcp` (a foreign binary need not expose `/healthz`),
- Kynator makes the binary executable (`chmod 0o755`) before the first spawn.

See the guide chapter "Deploying with Kynator", sections "Foreign workloads" and "Operator quick
reference", for the full explanation.

## Layout

```
foreign-workloads/
  build.sh            build all four apps into <lang>/app
  c/      server.c      checkout.yaml     # gcc,   portEnv=PORT
  go/     main.go       checkout.yaml     # go,    portEnv=PORT (static binary)
  rust/   main.rs       checkout.yaml     # rustc, portEnv=PORT
  aspnet/ Program.cs aspnetaot.csproj checkout.yaml  # dotnet Native AOT, portEnv=ASPNETCORE_HTTP_PORTS
```

## Build

`build.sh` builds whichever toolchains you have installed (it skips the rest):

```sh
cd examples/foreign-workloads
./build.sh            # produces c/app, go/app, rust/app, aspnet/app
```

Prerequisites, per app: `gcc` (C), `go` (Go), `rustc` (Rust), `dotnet` SDK 8+ with a C toolchain and
`zlib1g-dev` (ASP.NET Native AOT). None are needed to read the example; install only the ones you want
to run.

## Run under Kynator (standalone)

Point `kynatord` at a manifest directory containing one of the `checkout.yaml` files. The simplest way
is a per-app manifests dir:

```sh
mkdir -p /tmp/kyn/manifests
cp go/checkout.yaml /tmp/kyn/manifests/           # or c/ rust/ aspnet/
cat > /tmp/kyn/kynatord.json <<JSON
{ "manifestsDir": "/tmp/kyn/manifests", "reconcileMs": 1000, "nodeId": "node-1" }
JSON
ORCHD_CONFIG=/tmp/kyn/kynatord.json kynatord
```

Kynator reconciles the manifest, spawns two replicas on `portBase` / `portBase+1`, and keeps them at the
desired count. In another shell:

```sh
curl 127.0.0.1:18190/     # GO-OK   port=18190 FOO=go-env    (go example; ports differ per app)
```

Each app uses a distinct `portBase` so you can run several at once: C 18090, Go 18190, Rust 18290,
ASP.NET 18390.

> Note on absolute paths: a manifest's `binary:` must resolve at spawn time. The example manifests use a
> path relative to where you run `kynatord`; for a real deployment give an absolute path (or a
> content-addressed `artifact:`; see the blob-store chapter).
