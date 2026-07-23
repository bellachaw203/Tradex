# Secrets and Configuration

Every secret and variable the pipeline reads, where it lives, and what breaks
without it.

**The pipeline works with none of these configured.** CI, security scanning and
release all run on `GITHUB_TOKEN` alone. Secrets are needed only to *deploy*.

---

## Secrets vs. variables

GitHub offers two stores, and the distinction matters here:

| | Secrets | Variables |
| --- | --- | --- |
| Where | Settings → Secrets and variables → Actions → **Secrets** | → **Variables** |
| Visible after saving | No | Yes |
| Redacted in logs | Yes | No |
| Use for | Keys, tokens, seeds | Contract IDs, URLs, network names |

The `VITE_*` values are **variables, not secrets**. Vite inlines them into the
client bundle at build time, so every one of them is published the moment the
frontend deploys. Storing a real secret there does not protect it — it just
hides it from you while publishing it to users.

---

## Repository secrets

Settings → Secrets and variables → Actions → Secrets → **Repository secrets**

| Secret | Required | Used by | Without it |
| --- | --- | --- | --- |
| `GITHUB_TOKEN` | automatic | everything | — (provided by Actions) |
| `RELEASE_TOKEN` | optional | `release.yml` | Releases still work, but the tag push does not trigger downstream workflows |

### `RELEASE_TOKEN`

A fine-grained PAT with **Contents: read and write**. Only needed if you want
pushing a release tag to automatically trigger `cd.yml` or another workflow —
GitHub deliberately does not fire workflows for pushes made with
`GITHUB_TOKEN`, to prevent recursion.

Without it, `release.yml` falls back to `GITHUB_TOKEN`, the release is created
correctly, and any follow-on deployment is triggered manually.

---

## Environment secrets

Settings → Environments → *(environment)* → Environment secrets

Scoping to an environment is what makes production credentials safe: a workflow
run can only read them after the environment's protection rules — including
required reviewers — have been satisfied.

| Secret | Environments | Used by | Without it |
| --- | --- | --- | --- |
| `STELLAR_DEPLOYER_SECRET` | development, staging, production | `deploy/deploy.sh` | Testnet: falls back to friendbot funding. **Mainnet: the deploy fails.** |

### `STELLAR_DEPLOYER_SECRET`

The secret seed (`S...`, 56 characters) of the account that deploys the
contracts and becomes the protocol admin.

```bash
# Testnet: generate and fund a fresh identity
stellar keys generate tradex-deployer-dev --network testnet --fund
stellar keys show tradex-deployer-dev      # → the value to store
```

The script imports it over stdin, so it never appears in a process listing or a
log line:

```sh
printf '%s' "$STELLAR_DEPLOYER_SECRET" | stellar keys add "$SOURCE" --secret-key
```

> **Production.** This account controls the deployed protocol. Use a dedicated
> account, never a personal one; fund it with only what deployment costs; and
> rotate it if it is ever exposed to a log, a screenshot, or a third-party
> service.

---

## Environment variables

Settings → Environments → *(environment)* → Environment variables

These configure the frontend build for each environment. All are optional — the
app ships with a working testnet deployment baked into
`app/app/lib/contracts.ts`, so an unset variable falls back to that.

| Variable | Example | Meaning |
| --- | --- | --- |
| `VITE_PERP_ENGINE_ID` | `CC6KUX…` | Deployed perp-engine contract |
| `VITE_ORDERBOOK_ID` | `CD53AG…` | Deployed orderbook contract |
| `VITE_COLLATERAL_TOKEN_ID` | `CD2QON…` | USDC collateral SAC |
| `VITE_SOROBAN_RPC_URL` | `https://soroban-testnet.stellar.org` | Soroban RPC endpoint |
| `VITE_NETWORK_PASSPHRASE` | `Test SDF Network ; September 2015` | Network identifier |
| `VITE_TEE_URL` | `https://tee.example.org` | TEE match server |
| `VITE_SIMULATION_SOURCE` | `GAJ7S6…` | Funded account used only as the source for read-only simulation |
| `DEPLOYMENT_URL` | `https://app.example.org` | Shown as the deployment URL on the environment |

`deploy/deploy.sh` prints the correct values for these at the end of every
deployment.

### `VITE_MINTER_SECRET` — deliberately not wired up

`app/.env.example` documents it for local development, where minting test USDC
from a throwaway issuer is convenient. **No workflow sets it**, and
`validate-frontend-build.sh` fails the build if a Stellar seed appears anywhere
in the bundle.

If you set it in a build environment, you publish that issuer's signing key to
every visitor.

---

## Optional: frontend publishing

Needed only if `FRONTEND_DEPLOY_TARGET` in an environment file is not `none`.

| Target | Secrets | Variables |
| --- | --- | --- |
| `s3` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `S3_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID` |
| `rsync` | `SSH_PRIVATE_KEY` | `RSYNC_TARGET` |
| `pages` | — | — (uses the Pages OIDC token) |

For AWS, prefer OIDC role assumption (`aws-actions/configure-aws-credentials`)
over long-lived keys — no stored credential to leak or rotate.

---

## Verifying the configuration

```bash
gh secret list                              # repository secrets
gh secret list --env production             # environment secrets
gh variable list                            # repository variables
gh variable list --env production           # environment variables

# Rehearse a deployment without submitting anything
gh workflow run cd.yml -f environment=staging -f dry_run=true
```

---

## Rotation

| Credential | When | How |
| --- | --- | --- |
| `STELLAR_DEPLOYER_SECRET` | On exposure; quarterly for production | Generate a new account, transfer admin rights on-chain, update the secret, redeploy |
| `RELEASE_TOKEN` | On expiry or when the holder leaves | Reissue the PAT, update the secret |
| Frontend publishing creds | On exposure; quarterly | Provider-specific |

### If a secret leaks

1. **Rotate first.** Revoking is faster than assessing. Do it before anything else.
2. **Assume it is public.** Rewriting git history does not un-publish anything
   already cloned, forked, or indexed.
3. **Check for use.** For a Stellar key, review the account's transaction
   history on the relevant network explorer.
4. **Then find the hole.** Add a rule to `.gitleaks.toml` and
   `scripts/ci/scan-secrets.sh` so the same shape cannot be committed again.

---

## What already blocks a leak

| Layer | Catches |
| --- | --- |
| `.githooks/pre-commit` | Secrets in staged changes, before the commit exists |
| `ci.yml` → hygiene | Secrets in the PR diff, in seconds |
| `security.yml` → gitleaks | Secrets anywhere in the commit history |
| `validate-env.sh` | A populated secret in `.env.example`; any tracked `.env` |
| `validate-frontend-build.sh` | A credential inlined into the built bundle |
| GitHub push protection | A recognised credential, before the push lands |

Six layers, and the two that matter most are the first and the last — the ones
that act before the secret is durably published.
