# Artifact blob store: dev origin and bring-your-own

kynatord deploys a workload's `artifact: sha256:<hex>` by pulling the blob by hash into a per-node cache
before it spawns a replica: `GET <artifactOrigin>/artifacts/<sha>`, bearer-guarded, then it re-verifies the
bytes hash to `<sha>` (a corrupt or tampered download can never become a runnable file). The origin is
configurable, so the same reconcile path serves both a zero-dependency dev setup and a production object
store.

## Two modes

### All-in-one dev origin (artifactd)

`artifactd` is the bundled origin: a content-addressed blob store plus the control-plane config store, over
plain HTTP behind a single bearer token (`KYTE_ARTIFACT_TOKEN`). Blobs are stored **on disk** under
`<KYTE_ARTIFACT_ROOT>/blobs/<sha[0:2]>/<sha[2:4]>/<sha>` via an atomic write-and-rename, so they are
**durable across a restart** (verified: `GET /artifacts/<sha>/exists` returns 200 before and after an
artifactd restart). This is the right choice for a laptop, a demo, or a single small cluster.

Its limits are deliberate and documented: plain HTTP (no TLS of its own), a single shared bearer token, and
a `PUT /artifacts/<sha>` upload path bounded by the web server's fixed request buffer (multi-MB uploads
through artifactd's own PUT drop the connection). For anything beyond dev, use a real object store.

### Bring your own object store (production)

Point kynatord at any HTTP(S) object store (S3, MinIO, GCS, a CDN, or an nginx in front of a bucket) with
`artifactOrigin` in the kynatord config. This is independent of the control-plane config store, so the two
can live on different backends:

```json
{
  "nodeId": "node-a",
  "manifestsDir": "/etc/kyn/manifests",
  "artifactCacheDir": "/var/lib/kyn/blobs",
  "artifactOrigin": "https://artifacts.example.com",
  "artifactToken": "…optional bearer…",
  "store": { "enabled": true, "addr": "cfg.internal:8135", "token": "…", "tls": true }
}
```

- **Durable + TLS for free.** The object store owns durability and TLS; because kynatord's pull client
  speaks TLS, an `https://` origin gives an encrypted pull with no extra wiring. (Verified live: kynatord
  pulled a blob from a standalone object store with no config-store involved, cached it, and ran the
  replicas.)
- **Large uploads bypass the dev PUT limit.** CI uploads blobs straight to the object store (`aws s3 cp`,
  `mc cp`, a signed PUT), never through artifactd's `PUT`, so there is no multi-MB ceiling on the deploy path.
- **Key layout.** kynatord fetches `GET <artifactOrigin>/artifacts/<sha>`. Upload each blob to the key
  `artifacts/<sha>` (the sha256 of the binary, lower-case hex) under the origin's base URL. So a blob for
  `sha256:ab12…` lives at `s3://<bucket>/artifacts/ab12…` (served as `https://<origin>/artifacts/ab12…`).

## Auth against a raw bucket

kynatord authenticates the pull with `Authorization: Bearer <artifactToken>` (omitted when the token is
empty). A raw S3/GCS bucket expects its own signing scheme (SigV4), not a bearer, so pick one of:

- **public-read objects** under `artifacts/` (simplest; the blobs are content-addressed and immutable, and
  carry no secrets), with `artifactToken` empty; or
- a **bearer-aware front** (MinIO with a matching policy, an nginx/CDN that checks the bearer, or a small
  auth proxy) so `artifactToken` is honoured.

Either way the deploy contract is unchanged: publish `artifacts/<sha>`, reference `artifact: sha256:<sha>`
in the manifest, and kynatord pulls + verifies + runs it. The bundled artifactd remains the supported
zero-config dev origin.
