# Security Scanning

What the pipeline scans for, what blocks a merge, and how to handle a finding.

---

## Coverage

| Layer | Tool | Blocking | Runs |
| --- | --- | --- | --- |
| Secrets (staged) | `scan-secrets.sh` | ✅ | pre-commit hook |
| Secrets (PR diff) | `scan-secrets.sh` | ✅ | every PR |
| Secrets (full history) | gitleaks | ✅ | PR, push, weekly |
| Rust advisories | `cargo audit` | ✅ | PR, push, weekly |
| npm advisories | `npm audit` | ✅ high+ | PR, push, weekly |
| New dependencies | `dependency-review-action` | ✅ high+ | PR |
| Licences | `check-licenses.mjs` | ✅ | PR, push, weekly |
| SAST | Semgrep | ⚠️ advisory | PR, push, weekly |
| SAST | CodeQL (TS, Actions) | ✅ | PR, push, weekly |
| SAST | CodeQL (Rust) | ⚠️ advisory | PR, push, weekly |
| Lint-level SAST | ESLint rules, clippy | ✅ | every PR |
| Inlined secrets | `validate-frontend-build.sh` | ✅ | every build |

---

## Secret scanning

Two independent implementations, deliberately:

**`scripts/ci/scan-secrets.sh`** — offline, no dependencies, runs identically in
the pre-commit hook and CI. Fast enough to run before every commit.

**gitleaks** — broader rule set, scans the whole commit history. A secret that
was committed and later deleted is still leaked; only a history scan finds it.

Both use the same custom rules for this project's highest-value credential
shapes:

| Pattern | Why it matters |
| --- | --- |
| `S[A-Z2-7]{55}` | Stellar secret seed — full control of the account |
| `[TX][A-Z2-7]{55}` | Pre-auth / hash-x signer secrets |
| `VITE_*SECRET=…` | Vite inlines it into the public client bundle |
| PEM / OpenSSH private keys | Generic, high severity |
| AWS, GitHub, Slack, Google tokens | Standard credential shapes |

Findings are **redacted** before printing — a CI log that echoes the secret it
found is a second copy of the leak.

### Allowlisting

For a reviewed, non-sensitive match (a documented example key in prose), append
the marker on that line:

```
GABC...XYZ  # allowlist-secret-scan: documented public key, not a credential
```

Prefer fixing over allowlisting. Every allowlist entry is a permanent hole.

### False positives

`circuits/keys/` is excluded in both scanners: Groth16 proving and verifying
keys are *public parameters* — publishing them is the point of a trusted setup —
and their hex payloads trip entropy rules. Lockfiles are excluded for the same
reason (integrity hashes look like high-entropy secrets).

---

## Dependency advisories

**Rust** — `cargo audit` against every lockfile in the repo, including the
standalone `tools/e2e` and `keepers` trees. `--deny warnings` means an
unmaintained crate fails too, not just a CVE.

**npm** — `npm audit --audit-level=high`. High and critical block; moderate and
low are reported in the job summary.

That threshold is a judgement call: a wallet-connecting dApp cannot ship a known
high-severity flaw, but failing on every transitive `low` in the npm ecosystem
produces noise rather than safety, and noise gets ignored.

**New dependencies** — `dependency-review-action` blocks a PR that *adds* a
vulnerable or badly-licensed dependency even when the rest of the tree is clean.

---

## Licence compliance

This repository is Apache-2.0 ([LICENSE](../../LICENSE)), so dependency licences
must be compatible with distributing it.

Policy is data, in [`scripts/ci/license-policy.json`](../../scripts/ci/license-policy.json):

- **allowed** — permissive and weak-copyleft SPDX identifiers
- **denied** — AGPL, GPL, SSPL, BUSL, Commons Clause, CC-BY-NC
- **exceptions** — denied licences waived with a written reason and a review date
- **reviewed** — packages whose metadata is non-SPDX but has been read

Unrecognised licence expressions are reported but do not fail: the npm ecosystem
carries enough `"SEE LICENSE IN LICENSE.md"` that failing on it would be noise.
Denied licences always fail.

### ⚠️ Two open exceptions

Both are transitive dependencies of `@creit.tech/stellar-wallets-kit` and both
**need a decision**:

| Package | Licence | Path |
| --- | --- | --- |
| `@lobstrco/signer-extension-api` | GPL-3.0 | wallets-kit → direct |
| `ua-parser-js` 2.x | AGPL-3.0-or-later | wallets-kit → @trezor/connect → @trezor/env-utils |

GPL-3.0 and AGPL-3.0 are not compatible with distributing an Apache-2.0 licensed
bundle that links them. The options:

- **`ua-parser-js`** — pin back to 1.x (MIT) with an npm `overrides` entry, buy
  the commercial licence, or drop Trezor support.
- **`@lobstrco/signer-extension-api`** — confirm the LOBSTR connector is
  tree-shaken out of the production bundle, obtain an exception, or drop that
  wallet module.

They are recorded as exceptions with a `review_by` date so CI passes today while
the issue stays visible. **When the date passes, the exception expires and CI
fails** — deliberately, so this cannot be quietly forgotten.

Check strictly at any time:

```bash
node scripts/ci/check-licenses.mjs --ecosystem all --strict
```

---

## SAST

**CodeQL** (`codeql.yml`) — `security-extended` queries for:

- `javascript-typescript` — the frontend (blocking)
- `actions` — the workflows themselves, for injection-prone `${{ }}`
  interpolation and over-broad permissions (blocking)
- `rust` — the contracts (advisory; the Rust pack is newer than the others, and
  a pack-side regression should not wedge the merge queue)

**Semgrep** (`security.yml`) — `p/ci`, `p/javascript`, `p/typescript`, `p/rust`,
`p/secrets`. Results are uploaded as SARIF and appear in the Security tab.
Currently advisory (`|| true`); remove that once the backlog is triaged.

**Lint-level rules** — ESLint bans `eval`, `new Function`, `javascript:` URLs,
and raw `console` (which leaks order-flow data in a browser); clippy runs at
`-D warnings` across the workspace.

---

## Workflow security

The pipeline is itself an attack surface. What is done about it:

**No untrusted interpolation into shell.** A PR title is attacker-controlled.
`pr-quality.yml` passes it through the environment, never `${{ }}` inside a
`run:` block:

```yaml
env:
  PR_TITLE: ${{ github.event.pull_request.title }}
run: ./scripts/ci/check-pr-title.sh "$PR_TITLE"
```

CodeQL's `actions` pack checks this across every workflow.

**Least privilege.** Every workflow declares `permissions: contents: read` at the
top level; jobs that need more request it individually (`security-events: write`
for SARIF upload, `contents: write` only in the release publish job).

**Environment-scoped deploy credentials.** `STELLAR_DEPLOYER_SECRET` lives in
GitHub Environments, so a run cannot read the production key until the
environment's required reviewers have approved it.

**Pinned tool versions.** `install-tool.sh` pins gitleaks and the stellar CLI to
known versions rather than tracking `latest`.

> **Hardening not yet applied:** third-party actions are pinned to major version
> tags (`@v4`), not commit SHAs. SHA pinning defends against a tag being moved
> to malicious code. Dependabot's `github-actions` ecosystem is configured, so
> switching to SHAs keeps working — it is a deliberate trade against the
> maintenance cost, and worth revisiting before mainnet launch.

---

## Handling a finding

### A secret was committed

1. **Rotate immediately** — before assessing, before cleaning history. Anything
   pushed must be assumed public.
2. Remove it from the code and use a secret store instead.
3. Check the account's on-chain activity for a Stellar key.
4. Add the pattern to both scanners so the shape cannot recur.

History rewriting is optional and mostly cosmetic: forks, clones and caches
already have it.

### A vulnerable dependency

1. `npm audit fix` / `cargo update -p <crate>` if a patched version exists.
2. If it is transitive and unfixable, use an npm `overrides` entry or a cargo
   `[patch]`.
3. If neither works, assess exploitability in *this* application — a
   server-side ReDoS in a build-time-only dependency is not the same risk as one
   in shipped client code — and document the decision.

### A SAST finding

Triage in the Security tab. Real issues get fixed; false positives are dismissed
with a reason (which becomes the audit trail).

---

## Deliberately advisory

Three checks do not block today. Each is marked in the workflow with a comment
saying why and how to promote it:

| Check | Why | To promote |
| --- | --- | --- |
| clippy on `tools/e2e`, `keepers` | ~90 pre-existing warnings | Clear them, move into the blocking clippy step |
| Semgrep | Backlog not triaged | Remove `\|\| true` in `security.yml` |
| CodeQL Rust | Newer query pack | Remove `experimental: true` in `codeql.yml` |

They are advisory rather than deleted so the signal exists while the debt is
paid down. Advisory-forever is how a gate becomes decoration — each one has an
owner in `CODEOWNERS` and an explicit path to blocking.
