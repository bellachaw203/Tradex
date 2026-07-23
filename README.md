<p align="center">
  <img src="tradex.png" width="96" alt="Tradex" />
</p>

<h1 align="center">Tradex</h1>

<p align="center"><em>A real-world asset (RWA) trading protocol.</em></p>

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

## Getting Started

Prerequisites: Rust (see `rust-toolchain.toml`), Node 20+, Docker, the `stellar`
CLI, and a Stellar browser wallet.

```bash
# Build circuits, contracts, and tools
make all

# Run the web client
cd app && cp .env.example .env && npm install && npm run dev
```

Fill in `app/.env` with your own contract IDs and endpoints before running
against a network.

## Documentation

- [`DOCS.md`](DOCS.md) — protocol walkthrough, ZK circuits, TEE design, contracts
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — system architecture
- [`EXPLANATION.md`](EXPLANATION.md) — implementation notes
- [`RESEARCH.md`](RESEARCH.md) — background research
- [`ROADMAP.md`](ROADMAP.md) — planned work

## Status

Testnet only. Not audited. Not financial advice.

## License

See [`LICENSE`](LICENSE).
