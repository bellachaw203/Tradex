<!--
The PR title must follow Conventional Commits — release.yml derives the version
bump and the changelog from it, and pr-quality.yml will reject a title that
does not parse.

    <type>(<scope>): <description>
    feat(perp-engine): support cross-margin liquidations
    fix(app): stop the order book flickering on reconnect
    feat(contracts)!: change the register_asset signature   ← breaking
-->

## What changed

<!-- The change in a few sentences. What behaviour is different afterwards? -->

## Why

<!-- The problem this solves. Link the issue if there is one: Closes #123 -->

## How it was verified

<!-- What you actually ran or observed. "CI is green" is not verification of
     behaviour — CI proves it compiles and the tests that exist still pass. -->

- [ ] Tested locally
- [ ] Added or updated tests
- [ ] Verified against testnet

---

## Areas touched

- [ ] Smart contracts (`contracts/`, `crates/`)
- [ ] Circuits (`circuits/`) — **note:** verifying keys are compiled into the contracts
- [ ] Frontend (`app/`)
- [ ] Keepers / TEE (`keepers/`, `tools/`)
- [ ] CI/CD (`.github/`, `scripts/`, `deploy/`)
- [ ] Documentation only

## Risk

- [ ] **Breaking change** — title carries `!`, and the migration is described below
- [ ] Changes a deployed contract's interface
- [ ] Changes how funds or collateral move
- [ ] Changes an on-chain authorization or admin path
- [ ] Adds a dependency
- [ ] None of the above

<!-- If any risk box is ticked, explain the blast radius and the rollback plan. -->

## Deployment notes

<!-- Anything that must happen around the merge: a redeploy, a market
     re-registration, a repository variable to update, an ordering constraint
     with another PR. Write "none" if there is nothing. -->

---

<!--
Before requesting review:
  - [ ] `make ci-check` passes locally, or CI is green
  - [ ] no secrets, seeds or private keys in the diff (the hook checks, but look)
  - [ ] contract size budgets updated if a contract grew (scripts/ci/wasm-budgets.json)
-->
