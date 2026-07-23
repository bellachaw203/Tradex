<p align="center">
  <img src="tradex.png" width="96" alt="Tradex" />
</p>

<h1 align="center">Tradex</h1>

<p align="center"><em>A real-world asset (RWA) trading protocol.</em></p>

<p align="center">
  <a href="../../actions/workflows/ci.yml"><img src="../../actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="../../actions/workflows/security.yml"><img src="../../actions/workflows/security.yml/badge.svg" alt="Security" /></a>
  <a href="../../actions/workflows/codeql.yml"><img src="../../actions/workflows/codeql.yml/badge.svg" alt="CodeQL" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache 2.0" /></a>
</p>

---

## Overview

Tradex is an RWA project: an on-chain protocol for trading tokenized real-world
assets alongside crypto markets, with position privacy enforced by zero-knowledge
proofs and a trusted execution environment.

This repository contains the full stack — smart contracts, ZK circuits, the
matching engine, keeper services, and the web client.

## Repository Structure

| Path         | Contents                                                        |
| ------------ | --------------------------------------------------------------- |
| `contracts/` | Soroban smart contracts (perp engine, orderbook, collateral, verifiers) |
| `circuits/`  | Circuit definitions and proving/verifying keys                   |
| `crates/`    | Shared Rust crates                                               |
| `tools/`     | Matching engine, circuit prover, end-to-end harness, utilities    |
| `keepers/`   | Oracle, market maker, and liquidator services                     |
| `app/`       | Web client (React / React Router / Vite)                          |
| `infra/`     | Container build and local TEE test tooling                        |
| `audit/`     | Security notes                                                    |
| `deploy/`    | Environment-driven deployment, rollback, and per-environment config |
| `scripts/ci/`| Pipeline scripts — every CI check is a script you can run locally  |
| `.github/`   | Workflows, composite actions, and repository policy                |

## Getting Started

Prerequisites: Rust (see `rust-toolchain.toml`), Node 20+, Docker, the `stellar`
CLI, and a Stellar browser wallet.

```bash
# Build circuits, contracts, and tools
make all

# Install the pre-commit hook (secret scan, fmt, clippy, lint)
make hooks

# Run the web client
cd app && cp .env.example .env && npm ci && npm run dev
```

Fill in `app/.env` with your own contract IDs and endpoints before running
against a network. Every value is optional — the app ships with a working
testnet deployment.

### Before you push

```bash
make ci              # everything a pull request must pass
make ci-contracts    # fmt, clippy, tests, wasm build, artifact validation
make ci-frontend     # lint, format, types, tests, build, bundle validation
```

`make ci` runs the same scripts the pipeline runs, so a green run locally means
a green run in CI.

## Documentation

- [`DOCS.md`](DOCS.md) — protocol walkthrough, ZK circuits, TEE design, contracts
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — system architecture
- [`EXPLANATION.md`](EXPLANATION.md) — implementation notes
- [`RESEARCH.md`](RESEARCH.md) — background research
- [`ROADMAP.md`](ROADMAP.md) — planned work

### CI/CD

- [`docs/ci-cd/README.md`](docs/ci-cd/README.md) — pipeline architecture and required repository settings
- [`docs/ci-cd/DEPLOYMENT.md`](docs/ci-cd/DEPLOYMENT.md) — deploying, approving, rolling back
- [`docs/ci-cd/RELEASE.md`](docs/ci-cd/RELEASE.md) — versioning and releases
- [`docs/ci-cd/SECRETS.md`](docs/ci-cd/SECRETS.md) — required secrets and variables
- [`docs/ci-cd/SECURITY.md`](docs/ci-cd/SECURITY.md) — scanning and licence policy
- [`docs/ci-cd/TROUBLESHOOTING.md`](docs/ci-cd/TROUBLESHOOTING.md) — when something fails

## Contributing

Pull request titles follow [Conventional Commits](https://www.conventionalcommits.org/)
— the release version and changelog are derived from them, and CI rejects a
title that does not parse:

```
feat(perp-engine): support cross-margin liquidations
fix(app): stop the order book flickering on reconnect
feat(contracts)!: change the register_asset signature     ← breaking
```

## Status

Testnet only. Not audited. Not financial advice.

## License

See [`LICENSE`](LICENSE).
