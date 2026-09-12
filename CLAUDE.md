# CLAUDE.md - Kynator (the Kyte-native orchestrator)

## What this is

Kynator is a native, container-free orchestration stack: a Kubernetes-style control plane that runs
workloads as native binaries, not containers. It is written in Kyte itself (every entrypoint under `bin/`
and every module under `src/` is a `.ky` file) and is built with the `kyte` compiler. It is an application
package built on the Kyte language and runtime, not part of the language standard library, and it ships as
part of the Kyte release (its daemons arrive as `kynator-<version>-linux-<arch>.tar.gz` beside the
toolchain). See [README.md](README.md) for the full overview, and [STABILITY.md](STABILITY.md) and
[STABILITY.md](STABILITY.md) for the compatibility stance and scope. This repo is Kyte code only: it
consumes the language, it does not contain a compiler.

The stack is four binaries split along the Kubernetes data-plane / control-plane line; each `bin/`
entrypoint pulls only its slice of the package through the import graph, so dead-code elimination keeps
them genuinely separate:

- `service` (data plane): L7 reverse proxy, load balancing, health-checked membership, service VIPs.
- `kynatord` (control plane): manifest reconcile, replica supervision, restart policy, isolation, leader
  lease, config store, `/metrics` and alerts.
- `kynatorctl` (operator CLI): offline operator surface over a config-store backup dump.
- `artifactd` (data plane): content-addressed blob origin that stores native deploy binaries by their
  sha256 and serves them by hash to each `kynatord` node before a replica spawns.

## Build

Requires `kyte` on `PATH` (from the language gate's `zig build`) and the `lang`/`kyte` toolchain checkout
beside this repo (the `../packages` resolver finds this package's modules; a sibling toolchain source
checkout lets the resolver pick up an in-tree stdlib during development).

```sh
./build.sh                 # debug:   build/debug/bin/{service,kynatord,kynatorctl,artifactd}
./build.sh --release       # release: build/release/bin/...  (optimised; use for anything you run)
./build.sh --release --target linux-x86_64   # cross-compile; lands in build/<profile>/<triple>/bin/
```

Native builds use `kyte build --file` (the cached per-file object path); cross builds use single-file
compile with `--target` (the build-mode object cache is not target-aware, so do not mix a native and a
cross build in the same profile dir, the symbols collide at link). Supported triples: `linux-x86_64`,
`linux-arm64`, `macos-x86_64`, `macos-arm64`, `windows-x86_64`, `windows-arm64`.

## Tests and the gate (run before AND after any change)

```sh
./run-tests.sh       # offline deterministic suite: every tests/*.ky via `kyte test`. This is the gate body.
./gate.sh            # full host gate: build all four binaries, run-tests.sh, then the manifest-schema lint.
```

`gate.sh` is the authoritative host gate (build + `run-tests.sh` + `docs/check-manifest-schema.sh`, which
lints `docs/MANIFEST.md` against `src/orch/manifest.ky`). It exits non-zero on any failure. CI is per-host
because the native toolchain cannot build on hosted runners (see [docs/CI-CD.md](docs/CI-CD.md)).

The live tests are opt-in and NOT part of the default merge gate: `./run-live-tests.sh` (or `gate.sh` with
`KYTE_LIVE=1`) runs `tests/live/*.ky` against a real NovaDB server on `127.0.0.1:3009`, so it needs the
`novadb` repo built beside the toolchain (`novadb/zig-out/bin/novadb`). They are timing-sensitive and have
deterministic equivalents in the offline suite (for example `188_leader_lease`, `198_ha_cluster`).

## Working in this repo (how to make a change)

1. **Understand, then plan.** Read the relevant `src/` module and the `tests/*.ky` case that exercises it
   before editing. Keep the change minimal and match the surrounding Kyte style and module patterns; do not
   reformat or restructure unrelated code.
2. **Verify real behaviour, not just compilation.** Build `--release` and drive the actual path: run the
   affected binary against a real config or manifest (for example `service service.json --check`, or a
   `kynatord` reconcile against a manifests dir), and confirm the observed behaviour. "It compiles" is not
   done.
3. **Run the gate before and after.** At minimum `./run-tests.sh`; run `./gate.sh` before you consider a
   change finished. If your change touches the store or HA paths, also run the live tests against a fresh
   NovaDB (`KYTE_LIVE=1 ./gate.sh` or `./run-live-tests.sh`).
4. **Add a test for every behaviour change.** Tests are `tests/NNN_name.ky` run through `kyte test`; a new
   number extends the offline suite, which is the executable spec the gate enforces.
5. **Keep the manifest schema in sync.** If you change the workload `Spec` in `src/orch/manifest.ky`, update
   `docs/MANIFEST.md` so `docs/check-manifest-schema.sh` stays green.
6. **Commit only when asked**; if you are on `main`, branch first.
7. **Other kytelang repos are separate.** The compiler (`kyte`), the LSP (`kynalyzer`), the drivers, and
   `kynator-deploy-action` live in their own repos. A change to any of those does not belong here; this repo
   only consumes the toolchain they provide.

## Layout map

- `bin/` - the four entrypoints: `service.ky`, `kynatord.ky`, `kynatorctl.ky`, `artifactd.ky`.
- `src/net/` - data plane: `proxy.ky` (L7 proxy + pool + LB), `service.ky` (service VIPs + discovery),
  `autoscale.ky` (PID + proxy autoscaler), `netns.ky`.
- `src/orch/` - control plane: `spec.ky` / `manifest.ky` (workload manifest + parsing), `supervisor.ky`,
  `nativelet.ky` (node agent reconcile loop), `isolation.ky` (cgroups-v2), `autoscaler.ky`, `lease.ky` /
  `asynclease.ky` (leader lease + HA reconcile), `membership.ky`, `backup.ky`, `rollout.ky`, `health.ky`,
  `alerts.ky`, `secrets.ky`, `controlplane.ky` (read models kept for a future UI).
- `src/artifacts/` - `blobstore.ky`, `registry.ky`, `service.ky`, `cfgstore.ky` (the artifactd surface).
- `src/store/` - config store client/transport: `config.ky`, `httpconfig.ky`, `wire.ky`.
- `src/os/` - `sandbox.ky` (Linux namespaces / rootfs / seccomp isolation dial).
- `src/cfg/` - `config.ky` (validated JSON config loading).
- `tests/` - offline `kyte test` suite (`NNN_*.ky`); `tests/live/` - opt-in NovaDB integration tests.
- `examples/` - worked setups: `control-plane/`, `foreign-workloads/`, `ha-frontdoor/`, `handoff-deploy/`,
  `manifests/`, `netns-demo.sh`.
- `docs/` - `MANIFEST.md`, `OBSERVABILITY.md`, `CI-CD.md`, `BLOB-STORE.md`, `INSTALL.md`, `runbooks/`.
- `webui/` - a browser control-plane UI that was prototyped then dropped for 1.0; only `node_modules/` and
  `build/` leftovers remain (there is no live UI source), and the reusable server-side read models live on
  in `src/orch/controlplane.ky`.

## Conventions and gotchas

- Build `--release` for anything you actually run; a debug `kyte` compiler is far slower (this is the same
  ReleaseFast lesson as the language repo). On macOS, re-sign a binary with `codesign --force --sign -` if
  it gets SIGKILLed on launch.
- Each daemon reads a validated JSON config: a missing file falls back to documented defaults, but a present
  file with a bad value fails loudly at startup and never silently defaults. Use the `--check` mode
  (`service service.json --check`) to validate a config and exit 0/1 without serving.
- Linux-only in production: cgroups-v2 limits, cgroup-CPU autoscaling, and `os.sandbox` isolation need a
  Linux host (root / `CAP_SYS_ADMIN`). On macOS they degrade cleanly to plain process supervision, so the
  stack still runs for local development.
- `artifactd` serves the blob origin over plain HTTP (no TLS of its own) and authenticates writes with a
  single bearer token from `KYTE_ARTIFACT_TOKEN`. It MUST sit behind TLS termination on any untrusted
  network. An empty token disables auth entirely (`auth=OFF (dev)`): local development only, because the
  endpoint runs uploaded binaries.
- The only coupling between `service` and `kynatord` is a service-discovery file: `kynatord` publishes one
  `name=host:port` line per replica each reconcile tick, and `service` resolves its pool from that file. The
  two share no process and can be restarted independently.
- Kynator supervises foreign (non-Kyte) binaries too: `workloadType: foreign` in the manifest drops the
  Kyte-only conventions (fd-handoff, companion service, the `migrate` step) and uses `portEnv` + a
  `tcp|http|exec` probe instead. See [FOREIGN-WORKLOADS.md](FOREIGN-WORKLOADS.md).
- Prose follows Indian English with British spellings (behaviour, colour, initialise) and no em dashes;
  never change code identifiers or API names (`serialize`, `color`, `initialize`) to match.

## Ecosystem context

The repos live together under `/Users/kamlesh/kytelang/`. The ecosystem centre is kyte, the language
(1.0.0 stable, native-only, Zig 0.16 / LLVM 22 / C++20 runtime); Kynator is one of the packages that
consumes it. Related sibling repos:

- `kyte` - the language and toolchain (the compiler this repo builds against).
- `kynalyzer` - the language server (LSP).
- `kynator-deploy-action` - the GitHub Action that builds an app and deploys it through `artifactd` and the
  config store (the CI side of the deploy path described in `docs/CI-CD.md`).
- the database drivers and the web/hypermedia packages (`kyte-postgres`, `kyte-datastar`, and so on).
