# Operator runbooks

One page per incident: the **symptom** (what you observe), the **commands** (real `kynatorctl`, `curl`
against the config store's `/cfg/*` API, `systemctl`, and manifest edits - not pseudocode), and the
**expected result**. They assume the install in `docs/INSTALL.md`, metrics per `docs/OBSERVABILITY.md`, and
the config-store HTTP contract in `STABILITY.md`.

Conventions used below:

```sh
STORE=https://cfg.internal:8135      # the config store base URL (artifactd or your store)
TOK=…                                # KYTE_ARTIFACT_TOKEN / store token
cfg() { curl -s -H "Authorization: Bearer $TOK" "$@"; }   # helper
```

| Scenario | Page |
|---|---|
| The leader is gone / not reconciling | [leader-loss.md](leader-loss.md) |
| Two nodes both claim leadership | [split-brain.md](split-brain.md) |
| The config store is unreachable | [store-outage.md](store-outage.md) |
| Add or remove a cluster node | [node-add-remove.md](node-add-remove.md) |
| Roll a bad deploy back | [rollback.md](rollback.md) |
