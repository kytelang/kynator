# Install and upgrade

kynator ships as four small static binaries. This is how to install them on a fresh Linux host, run
`kynatord` as a systemd service supervising a workload, and upgrade in place.

## The four binaries

| Binary | Role | Runs as |
|---|---|---|
| `kynatord` | control plane: reconcile + supervise replicas | a long-running service on every node |
| `service` | data plane: L7 proxy / load balancer | a service on nodes that front traffic |
| `artifactd` | artifact origin + config store (dev/all-in-one) | one service (or use a BYO object store) |
| `kynatorctl` | offline operator CLI over a config-store dump | run on demand, not a service |

They come with the Kyte release; copy them to `/usr/local/bin` (or build with `./build.sh` and copy from
`build/release/bin`).

```sh
sudo install -m 0755 kynatord service artifactd kynatorctl /usr/local/bin/
```

## Minimal single-node install

1. **Lay out directories.**

```sh
sudo useradd --system --home /var/lib/kyn --shell /usr/sbin/nologin kyn 2>/dev/null || true
sudo mkdir -p /etc/kyn/manifests /var/lib/kyn/blobs /var/lib/node_exporter/textfile
sudo chown -R kyn:kyn /var/lib/kyn
```

2. **Write a workload manifest** (`/etc/kyn/manifests/hello.yaml`) - see `docs/MANIFEST.md`:

```yaml
apiVersion: kyte/v1
kind: App
metadata: { name: hello }
workload: { workloadType: foreign, binary: /usr/local/bin/hello, restartPolicy: always, portEnv: PORT }
replicas: { min: 2, max: 2 }
network: { expose: gateway-only, portBase: 18490 }
health: { probeType: tcp }
```

3. **Write the kynatord config** (`/etc/kyn/kynatord.json`):

```json
{ "manifestsDir": "/etc/kyn/manifests", "reconcileMs": 1000, "nodeId": "node-1",
  "artifactCacheDir": "/var/lib/kyn/blobs",
  "metricsFile": "/var/lib/node_exporter/textfile/kynatord.prom",
  "store": { "enabled": false, "addr": "", "token": "", "tls": false } }
```

(This standalone mode reconciles from the local manifests directory. For a cluster, set `store.enabled`
true and point it at artifactd or a shared config store; see the HA runbook.)

4. **systemd unit** (`/etc/systemd/system/kynatord.service`):

```ini
[Unit]
Description=kynator control plane
After=network-online.target
Wants=network-online.target

[Service]
# root is required for cgroups-v2 resource limits and namespace isolation; drop to a user only if you do
# not use resources:/isolation in any manifest.
ExecStart=/usr/local/bin/kynatord
Environment=ORCHD_CONFIG=/etc/kyn/kynatord.json
Restart=always
RestartSec=1
# systemd owns the cgroup that the replicas run under; Delegate lets kynatord create the kyte sub-tree.
Delegate=yes

[Install]
WantedBy=multi-user.target
```

5. **Start it.**

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now kynatord
systemctl status kynatord            # active
pgrep -af /usr/local/bin/hello       # two replicas supervised
```

Validate config without serving at any time: `service service.json --check`, `kynatord --check`.

## Upgrade

The binaries are self-contained, so an upgrade is a copy plus a restart.

### Single node (brief gap)

```sh
sudo install -m 0755 kynatord service artifactd kynatorctl /usr/local/bin/
sudo systemctl restart kynatord
```

On restart, kynatord reconciles from the manifests/store and re-spawns the workload. On a single node the
replicas it supervised are restarted with it, so there is a brief gap - acceptable for a dev or
single-instance deployment.

### Cluster (zero downtime)

Run three (or more) nodes in HA (`store.enabled: true`, shared config store, distinct `nodeId`, members
registered - see `docs/runbooks/node-add-remove.md`). Only the leader reconciles; standbys keep their
already-running replicas healthy. Upgrade one node at a time:

```sh
# on each node in turn:
sudo install -m 0755 kynatord /usr/local/bin/
sudo systemctl restart kynatord
# wait for it to rejoin (orch_up == 1, and for the old leader, a clean re-election) before the next node
```

Because at most one node is restarting at a time and the others keep serving, workloads stay at desired
count throughout. Watch `orch_leader_epoch` (exactly one non-zero across the cluster) and
`orch_under_provisioned` (0) during the roll; see `docs/OBSERVABILITY.md`.

## Verifying the config-store wire version

A node talking to a config store can confirm it speaks the same wire contract:

```sh
curl -s -H "Authorization: Bearer $TOKEN" http://<store>/cfg/version   # -> kyte-cfg/1
```

A mismatch means the store and the client are from incompatible major versions (see `STABILITY.md`).
