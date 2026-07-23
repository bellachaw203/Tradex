# CI/CD Architecture

How change reaches production in this repository, and what stops it when it
shouldn't.

- [Architecture](#architecture)
- [Workflows](#workflows)
- [Reusable components](#reusable-components)
- [Scripts](#scripts)
- [Required repository settings](#required-repository-settings)
- [Running the pipeline locally](#running-the-pipeline-locally)
- [Performance](#performance)
- [Extending the pipeline](#extending-the-pipeline)

Related documents:

| Document | Covers |
| --- | --- |
| [SECRETS.md](SECRETS.md) | Every secret and variable, and what breaks without it |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Deploying, approving, and rolling back |
| [RELEASE.md](RELEASE.md) | Versioning, changelog, and cutting a release |
| [SECURITY.md](SECURITY.md) | Scanning, licence policy, and handling findings |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Failures, causes, and fixes |

---

## Architecture

```
                        ┌──────────────────────┐
   pull request ───────►│        CI            │  ci.yml
   push to main         │  ┌────────────────┐  │
                        │  │ changes        │  │  which areas were touched
                        │  │ hygiene        │  │  lockfiles · env · secrets
                        │  │ contracts ─────┼──┼─► reusable-contracts.yml
                        │  │ frontend  ─────┼──┼─► reusable-frontend.yml
                        │  │ CI (gate)      │  │  ← branch protection points here
                        │  └────────────────┘  │
                        └──────────┬───────────┘
                                   │ on success (main only)
                                   ▼
                        ┌──────────────────────┐
                        │        CD            │  cd.yml
                        │  guard → build →     │
                        │  deploy → rollback   │
                        └──────────┬───────────┘
                                   │
                development ───────┴─── staging ─── production
                 (automatic)            (manual)     (manual + approval)

   in parallel with CI, on the same triggers:
     security.yml    secrets · advisories · licences · SAST
     codeql.yml      CodeQL for TypeScript, Actions and Rust
     pr-quality.yml  PR title, size, draft state

   on a schedule:
     maintenance.yml weekly health check, cache pruning, artifact inventory

   on demand:
     release.yml     version bump → changelog → tag → GitHub Release
```

### Principles

**One gate, many jobs.** Branch protection requires a single check — the `CI`
job in `ci.yml`. It aggregates every other job's result. Adding a job to the
pipeline therefore does not require touching repository settings, and a new job
cannot be forgotten in branch protection.

**Skipped is not failed, but failed is never skipped.** Path filtering skips
work for areas a change does not touch. Any change to `.github/`, `scripts/`,
`deploy/`, `Cargo.toml` or `rust-toolchain.toml` disables filtering entirely —
a filter must never be the reason a broken change goes green.

**Build once, deploy that.** The contracts are built with `wasm-opt` applied,
validated, checksummed, and uploaded. The same artifact is what deploys. CI
never validates something different from what ships.

**Local parity.** `make ci` runs the same scripts the workflows run. There is
one implementation of each check, called from both places.

---

## Workflows

| Workflow | Triggers | Purpose |
| --- | --- | --- |
| [`ci.yml`](../../.github/workflows/ci.yml) | PR, push to `main`, manual | The merge gate: hygiene, contracts, frontend |
| [`security.yml`](../../.github/workflows/security.yml) | PR, push, weekly | Secrets, advisories, licences, SAST |
| [`codeql.yml`](../../.github/workflows/codeql.yml) | PR, push, weekly | CodeQL for TypeScript, Actions, Rust |
| [`pr-quality.yml`](../../.github/workflows/pr-quality.yml) | PR events | Conventional-commit title, size, draft state |
| [`cd.yml`](../../.github/workflows/cd.yml) | After CI on `main`, manual | Environment deployments and rollback |
| [`release.yml`](../../.github/workflows/release.yml) | Manual, `v*` tag | Version bump, changelog, GitHub Release |
| [`maintenance.yml`](../../.github/workflows/maintenance.yml) | Weekly, manual | Health check, cache pruning, artifact inventory |

### What each CI job proves

| Job | Proves |
| --- | --- |
| `changes` | Which areas the diff touches |
| `hygiene` | Lockfiles are in sync; env config matches the code; no secrets; scripts are executable |
| `contracts / quality` | `cargo fmt` clean, clippy clean at `-D warnings` |
| `contracts / test` | Three test suites pass in parallel (core, shielded pool, circuit tooling) |
| `contracts / build` | All five contracts compile to wasm, carry Soroban metadata, and fit their size budgets |
| `frontend / quality` | ESLint at zero warnings, Prettier clean, TypeScript clean |
| `frontend / test` | Vitest passes, with coverage uploaded |
| `frontend / build` | Production bundle builds, every referenced asset resolves, no credential inlined |
| `CI` | Every one of the above passed or was legitimately skipped |

---

## Reusable components

### Composite actions

| Action | Does |
| --- | --- |
| [`setup-rust`](../../.github/actions/setup-rust/action.yml) | Installs the toolchain from `rust-toolchain.toml`, restores the cargo cache, optionally installs binaryen |
| [`setup-node`](../../.github/actions/setup-node/action.yml) | Installs Node with npm caching, runs `npm ci` |
| [`circuit-keys`](../../.github/actions/circuit-keys/action.yml) | Validates the six Groth16 verifying keys and exports the `VK_*` variables |

`setup-rust` deliberately does **not** set `RUSTFLAGS=-D warnings`: that applies
to third-party crates and changes the fingerprint of every cached artifact.
Warning denial belongs on the clippy invocation, where it covers this workspace
only.

### Reusable workflows

`reusable-contracts.yml` and `reusable-frontend.yml` are called by `ci.yml`,
`cd.yml` and `release.yml`. Each accepts `upload-artifacts`, `artifact-name` and
a few tuning inputs, and emits the artifact name and checksums as outputs. The
contracts are built exactly one way regardless of which workflow asked.

---

## Scripts

Everything the workflows do beyond orchestration lives in `scripts/ci/`, so it
can be run and debugged locally.

| Script | Purpose |
| --- | --- |
| `circuit-keys.sh` | Validates the Groth16 verifying keys, exports `VK_*` |
| `changed-paths.sh` | Path filtering (replaces a third-party action) |
| `verify-lockfiles.sh` | Every lockfile present, committed and in sync |
| `validate-env.sh` | `.env.example` matches the `VITE_*` variables the code reads |
| `scan-secrets.sh` | Offline credential scan; used by the hook and CI |
| `check-licenses.mjs` | Licence policy for npm and cargo dependencies |
| `validate-wasm.sh` | Contract metadata sections and size budgets |
| `validate-frontend-build.sh` | Bundle integrity and inlined-secret check |
| `check-pr-title.sh` | Conventional Commits enforcement |
| `bump-version.sh` | Derives and applies the semantic version bump |
| `changelog.sh` | Generates the changelog from commit messages |
| `install-tool.sh` | Installs pinned gitleaks / stellar CLI binaries |
| `restore-manifests.sh` | Restores deployment history so rollback works |

Deployment scripts live in `deploy/`:

| Script | Purpose |
| --- | --- |
| `deploy.sh` | Environment-driven contract deployment, writes a manifest |
| `rollback.sh` | Re-points an environment at a previous deployment |
| `frontend.sh` | Publishes the static bundle to the configured target |
| `environments/*.env` | Per-environment non-secret configuration |

### Policy files

| File | Controls |
| --- | --- |
| `scripts/ci/wasm-budgets.json` | Per-contract wasm size budgets |
| `scripts/ci/license-policy.json` | Allowed and denied licences, tracked exceptions |
| `.gitleaks.toml` | Secret-scanning rules and allowlist |

These are data, not code, so a policy change is reviewable without reading a
script.

---

## Required repository settings

The workflows enforce what they can. These four settings are what make the
pipeline binding — without them, every gate is advisory.

### 1. Branch protection on `main`

Settings → Branches → Add rule for `main`:

- ✅ **Require a pull request before merging** (1 approval)
- ✅ **Require status checks to pass** → add **`CI`** as required
  - optionally also `Security` and `Analyze javascript-typescript`
- ✅ **Require branches to be up to date before merging**
- ✅ **Require conversation resolution before merging**
- ✅ **Do not allow bypassing the above settings**
- ❌ Allow force pushes / deletions

> Add only the `CI` job as a required check, not the individual jobs. Path
> filtering means `contracts` or `frontend` may legitimately not run, and a
> required check that never runs blocks the PR forever.

### 2. GitHub Environments

Settings → Environments. Create three:

| Environment | Protection |
| --- | --- |
| `development` | None — deploys automatically after CI on `main` |
| `staging` | Deployment branches: `main` only |
| `production` | **Required reviewers** (at least one), branches: `main` and `v*` tags, wait timer optional |

Required reviewers on `production` is what makes deployment approval real: the
job pauses before it starts, and the environment's secrets stay unreadable
until someone approves.

### 3. Actions permissions

Settings → Actions → General:

- Workflow permissions: **Read repository contents and packages permissions**
  (workflows that need more request it per-job)
- ✅ Require approval for all outside collaborators

### 4. Security features

Settings → Code security:

- ✅ Dependency graph
- ✅ Dependabot alerts and security updates
- ✅ Secret scanning **and push protection**
- ✅ Code scanning (CodeQL results arrive from `codeql.yml`)

Push protection is the one gate this repository cannot implement itself: it
rejects a push containing a recognised credential before it reaches the remote.

Also update [`.github/CODEOWNERS`](../../.github/CODEOWNERS) — it ships with
placeholder `@tradex/*` teams that do not exist.

---

## Running the pipeline locally

```bash
make ci              # everything a PR must pass
make ci-hygiene      # lockfiles, env config, secrets
make ci-contracts    # fmt, clippy, tests, wasm build, artifact validation
make ci-frontend     # lint, format, types, tests, build, bundle validation
make ci-security     # licences and advisories
make deploy-dry-run  # rehearse a deployment, submit nothing
make hooks           # install the pre-commit hook
```

The pre-commit hook runs the secret scan always, and the Rust or frontend checks
only when files in those areas are staged.

---

## Performance

| Technique | Where |
| --- | --- |
| Cargo registry + target caching | `setup-rust` via `Swatinem/rust-cache` |
| npm cache | `setup-node` via `actions/setup-node` |
| Path filtering | `changes` job — skips untouched areas entirely |
| Parallel jobs | Contracts and frontend run concurrently; both split into quality / test / build |
| Test matrix | Three contract suites in parallel; Node 20 + 22 on `main` |
| Single install per job | `npm ci` runs once in the composite action |
| Concurrency cancellation | Superseded PR runs are cancelled; `main` and deploys are not |

Only the run on `main` writes the shared cargo cache (`cache-save`), so parallel
PR runs cannot race for the same key.

**Typical durations** (cold cache → warm):

| Job | Cold | Warm |
| --- | --- | --- |
| hygiene | ~1 min | ~1 min |
| contracts / quality | ~8 min | ~2 min |
| contracts / test | ~7 min | ~2 min |
| contracts / build | ~6 min | ~2 min |
| frontend (all) | ~4 min | ~2 min |
| **Wall clock** | **~10 min** | **~4 min** |

---

## Extending the pipeline

**Adding a check to CI.** Write the logic as a script in `scripts/ci/`, add a
step that calls it, and add the job to the `ci` aggregator's `needs:` list. No
branch-protection change is needed.

**Adding a deployment environment.** Create `deploy/environments/<name>.env`,
create the GitHub Environment with matching protection rules, and add the name
to the `environment` choice list in `cd.yml`.

**Making an advisory check blocking.** Three checks are deliberately advisory
today, each with a comment saying so:

- clippy on `tools/e2e` and `keepers` (~90 pre-existing warnings)
- Semgrep findings (`|| true` in `security.yml`)
- CodeQL for Rust (`experimental: true` in `codeql.yml`)

Clear the backlog, then remove the escape hatch in the same PR.

**Adding a supported language or package.** Add it to the matrix in the
relevant reusable workflow, and to `changed-paths.sh` so it is filtered
correctly.
