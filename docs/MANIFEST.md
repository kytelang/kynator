# Manifest schema reference

A kynator workload is a single YAML manifest. This page is the authoritative list of every field, its type,
its default, and what it does. It is kept in sync with `src/orch/manifest.ky` by a drift lint
(`docs/check-manifest-schema.sh`, run from `gate.sh`): if a struct field is added without a reference entry,
the gate fails.

A minimal manifest:

```yaml
apiVersion: kyte/v1
kind: App
metadata:
  name: web
workload:
  binary: ./bin/web        # or: artifact: sha256:<hex>
replicas:
  min: 2
  max: 2
network:
  expose: gateway-only
  portBase: 8080
```

## Top level

| Field | Type | Default | Meaning |
|---|---|---|---|
| `apiVersion` | string | `kyte/v1` | Schema version. Stable surface; a breaking change bumps this (see `STABILITY.md`). |
| `kind` | string | `App` | Manifest kind. Only `App` is defined at 1.0. |
| `metadata` | object | | Workload identity (below). |
| `workload` | object | | What to run (below). |
| `replicas` | object | | Replica band (below). |
| `autoscale` | object | | Autoscaler settings (below). |
| `lb` | object | | Load-balancing / data path (below). |
| `health` | object | | Health probing (below). |
| `network` | object | | Exposure + ports (below). |
| `resources` | object | | cgroups-v2 limits (below). |
| `migrate` | object | | Pre-rollout migration gate (below). |
| `routes` | list\<string\> | `[]` | Optional route hints (reserved; not required for foreign workloads). |

The application's own `config:` section is intentionally NOT part of this schema: it is read by the app
itself (via the framework config loader), and kynatord ignores it when binding a manifest.

## `metadata`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | `""` (**required**) | Unique workload key. Used as the config-store `workloads/<name>` key and the discovery service name. |

## `workload`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `binary` | string | `""` | Native executable to run per replica (a LOCAL path on the node). Used when `artifact` is empty. |
| `artifact` | string | `""` | Content-addressed artifact `sha256:<hex>`; kynatord pulls it by hash into the node cache before spawning (see `docs/BLOB-STORE.md`). Exactly one of `binary`/`artifact` is required. |
| `args` | list\<string\> | `[]` | argv passed to the binary (excluding the binary itself and the injected port). |
| `restartPolicy` | string | `always` | `always` \| `on-failure` \| `never`. |
| `workloadType` | string | `kyte` | `kyte` (default) or `foreign`. A foreign workload is any self-contained binary (Go, Rust, C#-AOT, ...); it gets no migrate step and no companion Kyte gateway, and is steered off fd-handoff onto a listening port. |
| `env` | list\<string\> | `[]` | Extra environment as `"KEY=VALUE"` entries applied to every replica. This is the LOCKED shape: a YAML map is rejected (see the env note below). |
| `secrets` | list\<string\> | `[]` | File-mounted secret HANDLES, each `"ENVVAR=/abs/path"` (absolute path). Only the PATH lives in the manifest and the store; kynatord reads the file on the node at spawn and delivers its content as `ENVVAR` to the child, so the value never appears in the manifest, the config store, or `/metrics`. |
| `workdir` | string | `""` | Working directory the child spawns in (`""` = inherit kynatord's cwd). Set automatically to the extraction directory for a tarball artifact. |
| `portEnv` | string | `KYTE_PORT` | Environment variable the assigned port is delivered through. A foreign binary that reads `$PORT` sets `portEnv: PORT`. Empty disables env port delivery (the binary gets its port via `network.portFlag`). |
| `artifactKind` | string | `single` | `single` (the artifact blob IS the executable) or `tarball` (the blob is a `.tar` extracted into the per-workload `workdir`; `binary` is then relative to it). |

**env is an array, not a map.** `env: [ "PORT=8080", "LOG=info" ]` (or the block `- "PORT=8080"` form). A
YAML map (`env: { PORT: 8080 }`) is rejected with a clear error, because the binder would otherwise bind it
to an empty list and silently drop the variables. Each entry must be `KEY=VALUE` with a non-empty key.

## `replicas`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `min` | int | `1` | Minimum replica count (must be >= 1). A fixed count is `min == max`. |
| `max` | int | `1` | Maximum replica count (must be >= `min`). The autoscaler operates within `[min, max]`. |

## `autoscale`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `false` | Turn the autoscaler on. When off, the rest of the block is ignored and the count stays at `replicas.min`. |
| `metric` | string | `inflight` | `inflight` (in-flight requests per replica, the gateway's load) or `cpu` (per-replica CPU utilisation, Linux). |
| `target` | double | `0.0` | Target value of the metric per replica (must be > 0 when autoscaling). `inflight`: in-flight requests (e.g. `8`). `cpu`: percent of one core (e.g. `70`). The autoscaler adds or removes replicas to keep the metric near this value, like a Kubernetes HPA target. |
| `intervalMs` | int | `2000` | Control-loop period. Optional. |

The convergence controller is a PID with fixed, conservative internal gains; those gains are intentionally
not part of the manifest. You tune scaling behaviour with `target` and the `replicas` band, not with
control-theory constants.

## `lb`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `strategy` | string | `roundrobin` | `roundrobin` \| `weighted` \| `leastconn` \| `consistenthash`. |
| `handoff` | bool | `true` | fd-passing data path (out-of-path), the default for Kyte apps; set `false` for classic byte-forwarding L7. Foreign workloads are steered off handoff regardless. |

## `health`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `path` | string | `/healthz` | HTTP probe path. Empty means a bare TCP-connect probe. |
| `intervalMs` | int | `2000` | Probe period. |
| `timeoutMs` | int | `1000` | Per-probe timeout. |
| `rise` | int | `2` | Consecutive OK probes to return a backend to the load-balancer rotation (data-plane pool). |
| `fall` | int | `3` | Consecutive failed probes: at the data-plane pool, drains the backend; at the kynatord heal loop, RESTARTS the workload (a liveness threshold - any single success resets the streak). |
| `probeType` | string | `http` | kynatord heal-probe type: `http` (GET `path` on the probe port), `tcp` (bare connect), or `exec` (run `probeCmd`; exit 0 = healthy). |
| `probeCmd` | list\<string\> | `[]` | argv for an `exec` probe (the binary is `probeCmd[0]`). Empty for `http`/`tcp`. |

## `network`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `expose` | string | `gateway-only` | `gateway-only` (reached only through the service front door) or `public`. |
| `portBase` | int | `0` | When > 0, replica *i* listens on `portBase + i` and that endpoint is advertised for the service to load-balance across. `0` = not directly exposed. |
| `portFlag` | string | `""` | CLI flag the assigned port is passed as (e.g. `--port`); an alternative/complement to `workload.portEnv`. |
| `servicePort` | int | `8080` | The front port the workload's SERVICE gateway listens on (Kyte handoff apps). |

## `resources`

Linux cgroups-v2 limits; `0` = unset. Enforced only on a privileged host (see the resource-limit section of
the deploy guide); off-Linux or unprivileged, kynatord reports that limits are NOT applied rather than
claiming them.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `cpuMilli` | int | `0` | CPU quota in milli-CPU (500 = 0.5 core), written to `cpu.max`. |
| `memMaxBytes` | long | `0` | Memory hard cap in bytes, written to `memory.max`. |
| `pidsMax` | int | `0` | Max PIDs (fork-bomb guard), written to `pids.max`. |

## `migrate`

Pre-rollout schema-migration gate; Kyte workloads only (a foreign binary never gets it).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `args` | list\<string\> | `[]` | When non-empty, kynatord runs the workload's own binary once with these args (conventionally `["--migrate"]`) to SUCCESS before it starts or rolls the replicas. A non-zero exit aborts the rollout and keeps the last-good replicas serving. |
| `timeoutMs` | int | `0` | Bounds the one-shot migration (`0` = wait indefinitely). |

## Internal (not a YAML field)

`Manifest.bindError` is set by the parser when a raw-text precheck fails (currently the env-shape lint); it
is surfaced by `validateManifest` and is never read from or written to YAML.
