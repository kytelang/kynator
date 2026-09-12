# Kynator (the Kyte-native orchestrator)

A native, container-free orchestration stack written in **Kyte**, a Kubernetes-style control plane that
runs workloads as **native binaries, not containers**. This is an _application package_ built on the Kyte
language + runtime; it is **not** part of the language standard library.

It bundles the whole I1-I4 infrastructure tier:

| Module            | What it is                                                                                                                                                                                                                                               |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `net.proxy`       | L7 reverse proxy + backend `Pool` with pluggable LB (round-robin / weighted / least-conn / consistent-hash), HAProxy-style per-reactor connection pooling, and active health-checked membership. Share-nothing multi-core (SO_REUSEPORT accept fan-out). |
| `net.autoscale`   | A PID controller + a proxy autoscaler that spawns/kills backend processes from a live in-flight metric.                                                                                                                                                  |
| `net.service`     | k8s-Service-style virtual endpoints: a stable front address load-balancing to replicas on ephemeral ports, with a name→endpoint registry + discovery file.                                                                                               |
| `orch.spec`       | Workload manifest (`Spec`) + JSON parsing, change detection, restart-policy logic.                                                                                                                                                                       |
| `orch.supervisor` | Keeps one workload's replica set running: spawn N, restart-on-crash per policy, graceful SIGTERM→SIGKILL.                                                                                                                                                |
| `orch.nativelet`  | The node agent: watches a manifest dir and reconciles desired vs actual; async HTTP health probes.                                                                                                                                                       |
| `orch.isolation`  | cgroups-v2 resource limits (cpu/mem/pids) + a CPU-utilisation metric.                                                                                                                                                                                    |
| `orch.autoscaler` | PID-driven replica autoscaling for a workload.                                                                                                                                                                                                           |
| `os.sandbox`      | Container-grade isolation dial (levels 0/1/3): Linux namespaces + private rootfs + dropped caps + seccomp.                                                                                                                                               |

## Four binaries: data plane, control plane, and the operator surfaces

The stack ships as **separate binaries** along the same data-plane / control-plane line Kubernetes draws
between `kube-proxy` and the controller manager. Each entrypoint lives in `bin/` and pulls only its slice
of the package through the import graph, so dead-code elimination keeps them genuinely separate. The four
`bin/` entrypoints are `service`, `kynatord`, `kynatorctl`, and `artifactd`:

| Binary           | Plane   | Owns                                                                                                                                                                                                          | Modules                                                                   |
| ---------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| **`service`**    | data    | traffic: L7 reverse proxy, load balancing, health-checked membership, service VIPs                                                                                                                            | `net.proxy`, `net.service`, `net.autoscale`                               |
| **`kynatord`**   | control | desired state: manifest reconcile, replica supervision, restart policy, isolation, leader lease, config store, `/metrics` + alerts                                                                            | `orch.*`, `store.*`, `os.sandbox`                                         |
| **`kynatorctl`** | ops     | an OFFLINE operator CLI over a config-store backup dump: inspect, edit cluster membership, print a rolling-upgrade plan                                                                                       | `orch.membership`, `orch.backup`, `orch.rollout`                          |
| **`artifactd`**  | data    | the content-addressed blob daemon: a deploy-artifact origin that stores native binaries keyed by their sha256 (idempotent, verified) and serves them by hash to each kynatord node before it spawns a replica | `artifacts.blobstore`, `artifacts.registry`, `artifacts.service`, `web.*` |

The operator surface for 1.0 is the CLI (`kynatorctl`), the declarative YAML manifests, and the config-store
HTTP API plus Prometheus metrics (see `docs/OBSERVABILITY.md`). A browser control-plane UI was prototyped
but **dropped for 1.0** rather than shipped half-built; the reusable server-side read models (the
node -> service -> replica tree and the per-app status parsed from a manifest) live on in
`orch.controlplane` for a future UI. Any surface that mutates desired state does so by writing a canonical
YAML manifest to the config store under `workloads/<name>`; the leader `kynatord`'s reconcile loop
(`asynclease.haReconcileTick` -> `nativelet.reconcileFromEntries`) reads those keys and converges the fleet.

### Security: artifactd is plain HTTP behind a bearer token

`artifactd` serves the blob origin over **plain HTTP** (no TLS of its own) and authenticates writes with a
single bearer token read from `KYTE_ARTIFACT_TOKEN`. This is a deliberate stopgap, so be honest about what
it means in production:

- **It MUST sit behind TLS termination** (a reverse proxy or the platform's own `service` with TLS) on any
  network you do not fully trust. Uploaded artifacts and the bearer token itself cross the wire in the
  clear otherwise.
- **An empty `KYTE_ARTIFACT_TOKEN` disables auth entirely** (the daemon logs `auth=OFF (dev)` at startup).
  That is for local development only. In production, always set a strong token, and terminate TLS in front
  of it.

They share no process and forward nothing to each other directly. The **only** coupling is a
service-discovery file, and it is fully wired:

- `kynatord` publishes, every reconcile tick, one `name=host:port` line per replica of each workload it
  manages (`Nativelet.publishDiscovery`). A workload exposes replica endpoints by setting
  `"service": { "basePort": 9000, "portFlag": "--port" }` in its manifest: replica _i_ is spawned on
  `basePort + i` (the port passed via `portFlag`) and advertised on `advertiseHost`. A workload with no
  `basePort` advertises its single shared `probe.port` instead.
- `service` resolves **all** endpoints for its `discoveryService` from that file
  (`net.service.resolveAllFrom`) into its backend pool, and its active health checks prune any advertised
  endpoint that is not actually serving yet. So the control plane advertises the desired topology and the
  data plane owns liveness.

Either can run and be restarted independently. End to end: `kynatord` writes
`web=127.0.0.1:9000` / `web=127.0.0.1:9001`; a `service` whose config sets `discoveryService: "web"` then
load-balances across both replicas.

Each reads a **validated JSON config** (a missing file falls back to documented defaults; a present file
with a bad value fails loudly at startup, never silently defaults):

```sh
./build.sh                      # builds build/debug/bin/{service,kynatord}  (--release for optimised)

service service.json              # serve; or `service` (defaults to ./service.json), or SERVICE_CONFIG=...
service service.json --check      # validate the config and exit 0/1 WITHOUT serving (CI / operator lint)
kynatord  kynatord.json               # reconcile loop; ORCHD_CONFIG=... ; kynatord --check to lint
```

### Cross-compiling (host build matrix)

The kyte toolchain cross-compiles from any host (macOS, Windows, WSL/Linux). Pass `--target <triple>` to
`build.sh`; the cross binaries land under `build/<profile>/<triple>/bin/`:

```sh
./build.sh --target linux-x86_64        # Linux x86_64
./build.sh --target linux-arm64         # Linux aarch64
./build.sh --target macos-x86_64        # macOS x86_64 (intel)
./build.sh --target macos-arm64         # macOS aarch64 (arm64)
./build.sh --release --target windows-x86_64   # Windows x86_64 (produces .exe)
```

Windows aarch64 is the one target of the six-way matrix we cannot produce today: the kyte compiler does
not accept `windows-arm64` as a `--target` yet (only the five triples above are wired in the compiler), so
`./build.sh --target windows-arm64` fails fast with a clear message. Adding the triple to the compiler
(`lang/src/main.zig`) is what unblocks it.

`service.json`:

```json
{
  "listenPort": 8080,
  "timeoutMs": 15000,
  "strategy": "roundrobin",
  "health": {
    "enabled": true,
    "path": "/healthz",
    "intervalMs": 2000,
    "rise": 2,
    "fall": 3
  },
  "backends": [
    { "host": "127.0.0.1", "port": 9001, "weight": 1 },
    { "host": "127.0.0.1", "port": 9002, "weight": 2 }
  ],
  "discoveryFile": "",
  "discoveryService": ""
}
```

`kynatord.json`:

```json
{
  "manifestsDir": "manifests",
  "reconcileMs": 2000,
  "nodeId": "node-1",
  "discoveryFile": ""
}
```

`strategy` is one of `roundrobin | weighted | leastconn | consistenthash`. `KYTE_PORT` overrides
`service`'s listen port so many proxy replicas can run on one host. When `discoveryFile` +
`discoveryService` are set on `service`, its backend is resolved from that file instead of (or in addition
to) the static `backends` list.

## Foreign workloads (supervise any binary)

Kynator supervises any self-contained native binary (Go, Rust, C# AOT, or anything that runs as a
process), not only Kyte apps. Set `workloadType: foreign` in the manifest and the supervisor drops the
Kyte-specific conventions the binary cannot speak:

- `portEnv` (default `KYTE_PORT`) names the env var the assigned port is delivered through, for example
  `PORT`; `env` (a list of `"KEY=VALUE"` entries) and `workdir` are applied per child at spawn via
  `process.spawnEx`, race-free across concurrent replica spawns.
- fd-handoff and the companion Kyte service are Kyte-only, so a foreign workload is steered onto a real
  listening port (`network.portBase`) that the `service` gateway byte-forwards to; the pre-rollout
  `migrate` step is skipped.
- the heal probe becomes `health.probeType: tcp | http | exec` (a foreign binary need not expose
  `/healthz`); an `exec` probe runs `health.probeCmd`, exit 0 = healthy.
- kynatord owns the exec bit: a foreign binary is `chmod 0o755`'d before the first spawn. A
  content-addressed artifact may be a tarball (`artifactKind: tarball`), extracted into `workdir`.

Full design, gap list, and status: [FOREIGN-WORKLOADS.md](FOREIGN-WORKLOADS.md). Operator-facing guide with
worked manifests: Kyte guide chapter 23 (`docs/guide/23-deploying-with-the-orchestrator.md`), sections
"Foreign workloads" and "Operator quick reference".

## Continuous deployment

Ship apps on a GitHub event (merge, tag, release, or a manual button) with the
[`kynator-deploy-action`](https://github.com/kytelang/kynator-deploy-action): it builds the app, uploads
the binary to `artifactd`, binds a version, and writes the workload manifest, then `kynatord` pulls by hash
and rolls the replicas. No SSH, no registry, no database in the loop. See [docs/CI-CD.md](docs/CI-CD.md)
for the deploy path, the shared-secret deploy token, and a ready workflow, and Kyte guide chapter 25 for the
app-author walkthrough.

## Requirements

Built against the Kyte toolchain (`kyte`) and its runtime, which provide the hooks this package calls:
`kyte_process_spawn` / `_spawn_ex` (foreign-workload env+cwd) / `_try_wait` / `_pid` / `_spawn_isolated`, `kyte_aserver_listen_addr`, the async
socket/timer primitives (`net.aio`), `process`, `io.file`, `io.dir`, `serde.json`, `collections`.

**Linux-only features:** cgroups-v2 limits, cgroup-CPU autoscaling, and `os.sandbox` isolation
(namespaces/rootfs/seccomp) require a Linux host (root / CAP_SYS_ADMIN). On macOS they degrade cleanly to
plain process supervision, so the orchestrator still runs.

## Build

Kynator is built and published as part of the **Kyte release**: its four daemons ship as
`kynator-<version>-linux-<arch>.tar.gz` alongside the toolchain, so there is nothing to install
separately. To build the binaries from a source checkout while developing, use `./build.sh --release`
(they land in `build/release/bin/`). Kynator is Linux-only in production; see Requirements above.

## Usage (programmatic)

The two binaries above are the normal entrypoints. To embed a tier directly, this is exactly what
`bin/kynatord.ky` does (`net.aio` is the async runtime module, formerly `net.asyncio`):

```kyte
import orch.nativelet;
import net.aio;

fn main(): int {
    aio.holdReactors();
    let n = nativelet.Nativelet("manifests");   // watch dir of *.json workload manifests
    let _ = nativelet.run(n, 2000);             // reconcile every 2s, forever
    return 0;
}
```

A workload manifest (`manifests/web.json`):

```json
{
  "name": "web",
  "binaryPath": "/opt/app",
  "args": ["--port", "8080"],
  "restartPolicy": "always",
  "replicas": 3,
  "cpuMilli": 500,
  "memMaxBytes": 268435456,
  "pidsMax": 128,
  "isolationLevel": 1,
  "rootfs": "/var/lib/kyte/rootfs/web",
  "probe": { "port": 8080, "path": "/healthz", "periodMs": 2000 }
}
```

## Tests

```sh
./run-tests.sh          # runs every tests/*.ky via `kyte test`
```

Run from a checkout that sits alongside the `lang` toolchain (the resolver finds this package via
`../packages`). Requires `kyte` on `PATH`.
