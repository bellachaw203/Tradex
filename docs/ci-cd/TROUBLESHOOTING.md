# Troubleshooting

Failures you will actually hit, what causes them, and how to fix them.

**First move for any CI failure:** reproduce it locally. Every check is a script
that runs the same way on your machine.

```bash
make ci              # the whole pipeline
make ci-hygiene      # lockfiles, env, secrets
make ci-contracts    # fmt, clippy, tests, wasm
make ci-frontend     # lint, format, types, tests, build
```

---

## Contents

- [Contract build failures](#contract-build-failures)
- [Frontend failures](#frontend-failures)
- [Hygiene failures](#hygiene-failures)
- [Security failures](#security-failures)
- [Deployment failures](#deployment-failures)
- [Release failures](#release-failures)
- [Workflow-level problems](#workflow-level-problems)

---

## Contract build failures

### `environment variable VK_COMMIT_JSON not defined`

The contracts embed the Groth16 verifying keys at compile time via `build.rs`,
so the `VK_*` variables must be set before cargo runs.

```bash
eval "$(./scripts/ci/circuit-keys.sh --print)"
cargo build --target wasm32v1-none --release -p orderbook
```

In CI this is the `circuit-keys` composite action. If it failed, a key file is
missing or malformed — the action names which one.

### `orderbook.wasm is 32245 bytes (153% of its 20500-byte budget)`

Almost always: **`wasm-opt` did not run**. It roughly halves these contracts, so
the raw cargo output blows every budget. The budgets are measured on the
optimized artifact, because that is what deploys.

```bash
sudo apt-get install binaryen        # or: brew install binaryen
make ci-contracts                    # runs wasm-opt then validates
```

If wasm-opt *did* run and the contract is genuinely over budget, the contract
grew. Raise the budget in `scripts/ci/wasm-budgets.json` **in the same PR**, and
say why in the commit message.

> Before raising a budget past ~64 KiB, check the target network's
> `contractMaxSizeBytes` setting. The budgets are regression guards; the network
> limit is a hard ceiling, and exceeding it fails at upload time.

### `has no contractspecv0 section`

The wasm compiled but is not a Soroban contract — usually a missing
`#[contract]` attribute, or the wrong crate built. Check `crate-type = ["cdylib"]`
in the crate's `Cargo.toml`.

### clippy passes locally, fails in CI

Two usual causes:

1. **Stale local artifacts.** Concurrent cargo invocations sharing `target/` can
   leave partial output. `cargo clean -p <crate>` and retry.
2. **Different feature unification.** Building one contract alone resolves
   features differently than building all five together. Always reproduce with
   the full command:

```bash
cargo build --locked --target wasm32v1-none --release \
  -p orderbook -p perp-engine -p shielded-pool -p collateral -p verifier-groth16
```

### Tests fail only in CI

CI uses `--locked`. If your local `Cargo.lock` drifted, you are testing
different dependency versions:

```bash
cargo test --locked -p perp-engine
```

---

## Frontend failures

### `npm ci` fails: `Missing: <package> from lock file`

`package.json` and `package-lock.json` disagree. `npm ci` refuses to guess —
that is the point.

```bash
cd app && npm install     # regenerates the lockfile
git add package-lock.json && git commit -m "chore(deps): sync lockfile"
```

### ESLint fails with 0 errors and N warnings

CI runs `eslint . --max-warnings=0`. A warning is a failure.

```bash
cd app && npm run lint:fix    # fixes what is auto-fixable
```

For `unused-imports/no-unused-vars`, either delete the binding or prefix it with
`_` if it is intentionally kept.

### `Unexpected console statement`

`console.log` is banned — it runs in the user's browser and echoes commitments
and note material. Use the dev-only helper:

```ts
import { debug } from '~/lib/debug'
debug('step: calling tee.commitProof…')   // compiles to a no-op in production
```

`console.warn` and `console.error` are allowed.

### Prettier: `Code style issues found`

```bash
cd app && npm run format
```

### `index.html references a missing asset`

The bundle references a file that was not emitted. Usually a file in `public/`
that was renamed or deleted while a reference remained. Check the path — the
validator strips `?v=3` query strings, so a cache-busted reference resolves
normally.

### `credential-shaped string found in the built bundle`

A `VITE_*` secret was set at build time and Vite inlined it into shipped
JavaScript. **The secret is now public — rotate it.** Then remove it from the
build environment; see [SECRETS.md](SECRETS.md).

---

## Hygiene failures

### `a non-npm lockfile exists in app/`

The repository installs with `npm ci`. A second package manager's lockfile
drifts silently and produces a different dependency tree than CI installs.

```bash
git rm app/bun.lock        # npm is authoritative
```

If you would rather standardise on bun, change the composite action and the
scripts together — not just the lockfile.

### `Cargo.lock is out of date`

```bash
cargo update --workspace
git add Cargo.lock
```

### `read in code but absent from app/.env.example`

A new `VITE_*` variable was used without documenting it. Add it to
`app/.env.example` with an empty value and a comment.

The reverse — documented but never read — means the variable was removed from
the code and the example drifted.

### `not marked executable`

Git tracks the executable bit; a script added on Windows often lacks it.

```bash
git update-index --chmod=+x scripts/ci/your-script.sh
```

---

## Security failures

### Secret scan flags something that is not a secret

If it is genuinely public (a documented example key), mark the line:

```
GABC...XYZ   # allowlist-secret-scan: public network address
```

If it is a real credential: rotate it first, then remove it.

### `npm audit` fails on a transitive dependency

```bash
cd app && npm audit fix
```

If the fix requires a breaking major bump, use an override:

```json
{ "overrides": { "vulnerable-package": "^2.0.0" } }
```

### Licence check fails

A dependency introduced a denied licence. See
[SECURITY.md § Licence compliance](SECURITY.md#licence-compliance) — the options
are remove it, override to a compatible version, or add a justified exception.

### `exception expired 2026-10-01`

A licence exception passed its review date, deliberately. Make the decision it
was recording, then either resolve the dependency or extend the date with a note
saying why.

---

## Deployment failures

### `no deployer key: set STELLAR_DEPLOYER_SECRET`

Mainnet has no friendbot. Add the secret to the environment
([SECRETS.md](SECRETS.md)).

### `branch 'feature/x' may not deploy to production`

Production deploys from `main` or a `v*` tag only. Merge first, or deploy from
the release tag:

```bash
gh workflow run cd.yml --ref v1.2.0 -f environment=production
```

### `working tree is dirty`

Staging and production require the checkout to match the commit being deployed
exactly, so the manifest's commit hash means something. Commit or stash.

### Deploy job never starts

It is waiting for environment approval. Actions → the run → **Review
deployments**. If no reviewer is configured, the job waits indefinitely — check
Settings → Environments → production.

### `X deploy did not return a contract id`

The `stellar contract deploy` call failed. The full CLI output is in the run's
log file, uploaded as the `deployment-<env>-<run_id>` artifact. Common causes:
underfunded deployer, RPC rate limiting, or a contract over the network's size
limit.

### Rollback: `only one deployment recorded`

There is no previous deployment to return to — either this is the first, or the
manifest history was not restored. Check the `restore-manifests` step; artifacts
expire after 90 days. For permanent history, commit `deploy/manifests/`.

### Rollback: `contracts are not readable on <network>`

The target deployment is not live on-chain, so rolling back to it would point
the environment at nothing. Pick a different manifest with `--list` and `--to`.

---

## Release failures

### `No release-worthy commits`

No `feat`, `fix`, `perf` or breaking-change commit since the last tag. Check for
a mis-typed PR title:

```bash
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```

Force one if needed: `gh workflow run release.yml -f level=patch`.

### `tag v1.2.0 already exists`

The version was already released. Delete the tag if it was a mistake
(`git push --delete origin v1.2.0`), or pick another version with `--set`.

### Tag pushed, no release published

The build or publish job failed after tagging. Re-run from the tag — the
`push: tags` trigger publishes without re-bumping.

### Tag pushed, no downstream workflow ran

Expected. Pushes made with `GITHUB_TOKEN` do not trigger workflows, to prevent
recursion. Configure `RELEASE_TOKEN` if you need it.

---

## Workflow-level problems

### The `CI` check never appears on a PR

`ci.yml` triggers on PRs targeting `main`. A PR into another branch does not run
it. If `CI` is a required check, either open the PR against `main` or add the
branch to the trigger.

### A job was skipped but the PR is blocked

Only the aggregated `CI` job should be a required status check. Individual jobs
(`contracts`, `frontend`) are path-filtered and legitimately skip — a required
check that never runs blocks the PR forever. Fix in Settings → Branches.

### Path filtering skipped something it should not have

`changed-paths.sh` forces everything to run when `.github/`, `scripts/`,
`deploy/`, `Cargo.toml`, `Makefile` or `rust-toolchain.toml` changes. Debug it
locally:

```bash
./scripts/ci/changed-paths.sh origin/main
```

### Cache misses on every run

Only the run on `main` writes the shared cargo cache (`cache-save`). PR runs read
it. If `main` has not run since the last dependency change, PRs build cold —
push to `main` or dispatch `ci.yml` on it to warm the cache.

### Cache quota exhausted

`maintenance.yml` prunes caches for closed branches weekly. Run it early:

```bash
gh workflow run maintenance.yml -f job=caches
```

### `bad interpreter: /bin/bash^M`

A script was committed with CRLF line endings. `.gitattributes` forces LF for
`*.sh`, but a file committed before that needs renormalising:

```bash
git add --renormalize .
```

---

## Getting more detail

```bash
gh run list --workflow=ci.yml --limit 5
gh run view <run-id> --log-failed        # only the failing steps
gh run view <run-id> --job <job-id> --log
gh run download <run-id>                 # artifacts, incl. deployment logs
gh run rerun <run-id> --failed           # re-run only failed jobs
```

Enable step debugging by setting the repository secret `ACTIONS_STEP_DEBUG` to
`true`.
