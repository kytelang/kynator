# Continuous deployment

Deploying to Kynator by hand (upload the binary to `artifactd`, bind a version, write `workloads/<app>`,
let `kynatord` reconcile) is four HTTP calls. The [`kynator-deploy-action`](https://github.com/kytelang/kynator-deploy-action)
runs those four calls from a GitHub workflow, so a merge or a tag ships your app with no SSH, no container
registry, and no database in the loop. This page is the orchestrator-side view; the action's README is the
full input reference, and Kyte guide chapter 25 is the app-author walkthrough.

## The deploy path

```
GitHub event (push to main / tag / release / manual)
        |
   GitHub runner:  kyte build  ->  sha256(binary)
        |  Authorization: Bearer $KYTE_ARTIFACT_TOKEN
        v
   artifactd:  PUT /artifacts/<sha>        (blob, verified, idempotent)
               PUT /apps/<app>/<version>   = sha256:<hex>   (registry bind, immutable)
               POST /cfg/put  workloads/<app> = manifest     (desired state)
        |
        v
   kynatord:  observes workloads/<app>, pulls sha256:<hex> from artifactd,
              verifies the hash, and reconciles the replicas to it
```

The runner only needs to reach `artifactd` over HTTP(S). `kynatord` does the rest from the config store,
exactly as if you had written the manifest by hand.

## What the server must provide

1. **`artifactd` reachable from the runner.** Public behind an HTTPS ingress for GitHub-hosted runners, or
   on a private network reached by a self-hosted runner or a tunnel. Always use `https` for a publicly
   reachable orchestrator: the endpoint accepts a binary `kynatord` will execute.

2. **A deploy token.** `artifactd` guards every route with a single shared secret read from the
   `KYTE_ARTIFACT_TOKEN` environment variable, compared against the request's `Authorization: Bearer`
   header in constant time. This is not OAuth or OIDC and there is no token endpoint: you choose the
   secret, set it on the server, and store the same string as the CI secret.

   ```sh
   openssl rand -hex 32          # generate once
   ```

   Set it in `artifactd`'s environment (for example the systemd unit from `docs/INSTALL.md`):

   ```ini
   [Service]
   Environment=KYTE_ARTIFACT_TOKEN=<the value>
   ```

   `artifactd` logs `auth=on` when a token is set. An empty token logs `auth=OFF (dev)` and accepts every
   request, which is for local development only, never a reachable host. Rotate by changing the value on the
   server and the CI secret together; the server trusts one token at a time. Treat it like an SSH deploy
   key: whoever holds it can ship an executable binary.

## The workflow (app repo)

Add `.github/workflows/deploy.yml` in the Kyte app's repository. Deploy on a merge to `main`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch: {}
jobs:
  deploy:
    runs-on: ubuntu-latest
    concurrency: deploy-webapp        # never let two deploys race
    steps:
      - uses: actions/checkout@v4
      - uses: kytelang/setup-kyte@v1  # kyte on PATH
      - uses: kytelang/kynator-deploy-action@v1
        with:
          orch-url:      ${{ vars.ORCH_URL }}      # artifactd base URL
          token:         ${{ secrets.ORCH_TOKEN }} # = KYTE_ARTIFACT_TOKEN on the server
          app:           webapp
          app-src:       src/main.ky
          version:       ${{ github.sha }}         # immutable per commit
          target:        linux-x86_64              # the server's OS/arch
          spec-template: deploy/workload.yaml      # the manifest below (optional)
```

`ORCH_URL` is a repository variable; `ORCH_TOKEN` is a repository secret. Choose the trigger in `on:` to
taste: `push` to `main` (a merged PR is a push to the base branch), a version tag (`tags: ["v*"]`), a
published Release (`release: { types: [published] }`), or `workflow_dispatch` for manual promotions.
Because the registry bind is immutable, use a unique `version:` per deploy (the commit SHA works well); a
rollback is simply re-deploying a version you already shipped.

## The manifest is the source of truth

`spec-template` points at a committed manifest carrying the orchestrator settings, the binary by hash (a
`sha256:__ARTIFACT__` placeholder the action fills in), and the app's own configuration under `config:`
(injected into every replica as environment variables). This is the same schema documented in
`docs/MANIFEST.md` and guide chapter 23; the action never invents state, it only substitutes the digest.

```yaml
apiVersion: kyte/v1
kind: App
metadata:
  name: webapp
workload:
  artifact: sha256:__ARTIFACT__
  restartPolicy: always
replicas:
  min: 2
  max: 6
network:
  expose: public
  portBase: 8080
  portFlag: --port
config:
  - LOG_LEVEL=info
```

## See also

- The [`kynator-deploy-action` README](https://github.com/kytelang/kynator-deploy-action): every input, the
  four HTTP calls it makes, and the full "Getting a deploy token" walkthrough.
- Kyte guide chapter 25 (Continuous deployment) for the app-author perspective, and chapter 23 for the
  manifest and the manual deploy this automates.
- `docs/INSTALL.md` for standing up `artifactd`/`kynatord`, and `docs/runbooks/` for rollback and recovery.
