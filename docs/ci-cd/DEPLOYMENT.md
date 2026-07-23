# Deployment

How code reaches an environment, who approves it, and what to do when it goes
wrong.

---

## Environments

| Environment | Network | Trigger | Approval | Branch |
| --- | --- | --- | --- | --- |
| `development` | Testnet | Automatic, after CI succeeds on `main` | None | `main` |
| `staging` | Testnet | Manual dispatch | None | `main` |
| `production` | **Mainnet** | Manual dispatch | **Required reviewer** | `main` or a `v*` tag |

Configuration lives in [`deploy/environments/`](../../deploy/environments/) —
one file per environment, non-secret values only. The differences between
environments are data in those files, not branching logic in the scripts.

---

## One-time setup

### 1. Create the GitHub Environments

Settings → Environments:

| Environment | Settings |
| --- | --- |
| `development` | No protection rules |
| `staging` | Deployment branches: **Selected** → `main` |
| `production` | **Required reviewers**: at least one person or team.<br>Deployment branches: **Selected** → `main`, `v*`.<br>Wait timer: optional (a few minutes gives a chance to cancel a mistake). |

Required reviewers on `production` is what makes approval real. The job pauses
*before it starts*, and the environment's secrets are unreadable until someone
approves — so an unapproved run cannot touch mainnet even if the workflow were
compromised.

### 2. Add the deployer secret

Per environment, add `STELLAR_DEPLOYER_SECRET`. See [SECRETS.md](SECRETS.md).

### 3. Verify without deploying

```bash
gh workflow run cd.yml -f environment=staging -f dry_run=true
```

A dry run builds and validates everything, prints the exact plan, and submits
no transaction.

---

## Deploying

### Automatic — development

Merging to `main` runs CI; if CI succeeds, `cd.yml` deploys to `development`.
Nothing to do.

The guard job checks `github.event.workflow_run.conclusion == 'success'` before
anything else runs. A red CI never deploys.

### Manual — staging or production

```bash
gh workflow run cd.yml -f environment=staging
gh workflow run cd.yml -f environment=production
```

Or: Actions → CD → Run workflow.

For production, the run pauses at the `deploy` job until a required reviewer
approves it in the Actions UI.

### From a release tag

```bash
gh workflow run cd.yml --ref v1.2.0 -f environment=production
```

`production.env` sets `REQUIRE_TAG=true`, so a tag ref satisfies the branch
restriction.

---

## What a deployment does

```
guard            check the trigger, resolve environment / dry-run / commit
  ↓
build-contracts  cargo build → wasm-opt → validate → upload artifact
build-frontend   lint, types, tests, build → validate bundle → upload artifact
  ↓
deploy           ← environment protection evaluated here (approval waits)
  ├─ download the artifacts built above
  ├─ install the pinned stellar CLI
  ├─ restore previous manifests (so rollback has history)
  ├─ deploy.sh: guard rails → deploy → initialize → register markets
  ├─ frontend.sh: publish the bundle to the configured target
  └─ upload the deployment record (90-day retention)
  ↓
rollback         only if deploy failed — restores the previous manifest
```

### Guard rails in `deploy.sh`

Checked before a single transaction is submitted:

| Guard | Enforces |
| --- | --- |
| `REQUIRE_CLEAN_TREE` | The deployed commit matches the checkout exactly |
| `ALLOWED_BRANCHES` | staging and production deploy from `main` only |
| `REQUIRE_TAG` | Production accepts a `v*` tag ref |
| stellar CLI present | Fail early, not halfway through |
| `validate-wasm.sh` | Every contract carries Soroban metadata and fits its budget |
| `ALLOW_FRIENDBOT_FUNDING` | Mainnet never silently creates an unfunded deployer |

### The deployment manifest

Every run writes `deploy/manifests/<env>/<timestamp>.json`:

```json
{
  "environment": "staging",
  "network": "testnet",
  "timestamp": "20260723T160729Z",
  "commit": "aaf515fdd7ea922fbbdc6aad47ea0c525e45e59d",
  "actor": "someone",
  "admin": "GAJ7S6…",
  "collateral_token": "CD2QON…",
  "contracts": [
    { "name": "orderbook", "id": "CD53AG…", "sha256": "…" }
  ]
}
```

This is the deployment record and the input to rollback: which contract IDs,
built from which commit, with which wasm checksums. `latest.json` points at the
current deployment.

Manifests are uploaded as workflow artifacts with 90-day retention and restored
at the start of the next deployment. For permanent history, commit
`deploy/manifests/` to `main` after each deployment.

---

## Rollback

### What rollback means here

A deployed Soroban contract is **immutable**, and its address is permanent.
Rollback therefore does not undo anything on-chain. It re-points the clients —
frontend, keepers, docs — at the previous, known-good set of contract IDs, and
restores that manifest as the environment's current state.

The alternative, deploying a fresh copy of the old code, produces a *third*
address with empty state. That is not a rollback; it is a new deployment that
has lost every position.

### Automatic

If the `deploy` job fails, the `rollback` job runs: it restores the previous
manifest and uploads the record. It does not run for a dry run.

### Manual

```bash
./deploy/rollback.sh staging --list                    # show history
./deploy/rollback.sh staging                           # back one deployment
./deploy/rollback.sh production --to 20260101T120000Z  # to a specific one
```

Before switching, `rollback.sh` reads each target contract on-chain and refuses
to proceed if any is unreadable — rolling back to a deployment that is not
actually live would leave the environment pointing at nothing.

### After a rollback

Three steps remain, and they are what actually moves traffic:

1. Redeploy the frontend with the restored contract IDs
2. Restart the keepers against the restored perp-engine
3. Update the environment's `VITE_*` variables

The rollback script prints these, and writes `ROLLBACK.md` next to the manifests
recording what changed, when, and by whom.

---

## Deploying by hand

The scripts are not workflow-only:

```bash
# Build what you are going to deploy
make ci-contracts

# Rehearse
./deploy/deploy.sh development --dry-run

# Deploy
export STELLAR_DEPLOYER_SECRET="S..."
./deploy/deploy.sh development

# Deploy a downloaded release artifact instead of a local build
gh release download v1.2.0 -p 'tradex-contracts-*.tar.gz'
mkdir -p artifacts && tar -xzf tradex-contracts-1.2.0.tar.gz -C artifacts
./deploy/deploy.sh staging --wasm-dir artifacts
```

---

## Frontend publishing

`FRONTEND_DEPLOY_TARGET` in the environment file selects the target:

| Target | Behaviour |
| --- | --- |
| `none` *(default)* | Validate the bundle and upload it as an artifact. Nothing is published. |
| `pages` | Stage for GitHub Pages, adding the SPA `404.html` fallback |
| `s3` | Sync to `S3_BUCKET`, optionally invalidating CloudFront |
| `rsync` | rsync over SSH to `RSYNC_TARGET` |

`none` is the default deliberately: publishing to a host nobody configured
would be a silent no-op reported as a success.

Caching is set correctly for `s3`: hashed assets are immutable and cached for a
year, `index.html` is `must-revalidate`. Reversing those means users keep
loading the previous deployment.

---

## Post-deployment checklist

- [ ] Deployment job succeeded, and the manifest lists every expected contract
- [ ] Contract IDs read correctly on-chain (`stellar contract info interface --id <id>`)
- [ ] Environment `VITE_*` variables updated to the new IDs
- [ ] Frontend redeployed against the new IDs
- [ ] Keepers restarted and processing
- [ ] Markets registered (`REGISTER_MARKETS`; **off by default on mainnet** —
      it seeds oracle prices, and a wrong price mis-prices a live market)
- [ ] A test trade completes end to end

---

## Adding an environment

1. `cp deploy/environments/staging.env deploy/environments/<name>.env` and edit it
2. Create the GitHub Environment with matching protection rules
3. Add `<name>` to the `environment` choice options in `.github/workflows/cd.yml`
4. Add `STELLAR_DEPLOYER_SECRET` to the new environment
5. Verify with `gh workflow run cd.yml -f environment=<name> -f dry_run=true`
