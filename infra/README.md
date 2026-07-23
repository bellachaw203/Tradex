# TEE Match Server

`tee-match` runs the CLOB matching engine and the Groth16 prover inside a
confidential-computing enclave (AMD SEV-SNP). This directory holds the
container build and a local test harness.

## Quick Start (Local Docker)

```bash
# 1. Build
docker build -f infra/Dockerfile -t tee-match .

# 2. Generate a DEK (32 random bytes, hex-encoded)
export CER_DEK=$(openssl rand -hex 32)

# 3. Run with proving keys mounted
docker run -p 9721:9721 \
  -e CER_DEK \
  -v $(pwd)/circuits/keys:/keys \
  tee-match

# 4. Test
./infra/test-tee-local.sh
```

## Architecture

```
Client                    Reverse Proxy          TEE Server (Confidential VM)
  │                            │                         │
  │  1. GET /attestation       │                         │
  │─────────────────────────►  │─────────────────────►   │
  │                            │                         │
  │  2. verify SEV-SNP         │   { token, hwmodel }    │
  │     derive session key     │◄───────────────────────  │
  │                            │                         │
  │  3. POST /place            │                         │
  │     AES-GCM(session,       │                         │
  │       {cmd:"place",...})   │                         │
  │─────────────────────────►  │─────────────────────►   │
  │                            │   decrypt with DEK      │
  │                            │   CLOB match            │
  │                            │   generate ZK proof     │
  │   { fills: [...], ok }     │   submit on-chain       │
  │◄─────────────────────────  │◄──────────────────────  │
```

## Security Model

- **Proving keys**: Inside SEV-SNP encrypted memory. No host access.
- **DEK**: Wrapped by a KMS, unwrapped by the confidential-VM launcher at boot.
  Set as the `CER_DEK` env var.
- **Order secrets**: AES-256-GCM encrypted in-flight. Decrypted only in the enclave.
- **On-chain verification**: ZK proofs independently verifiable — no trust in the
  TEE required.

## Local TEE Simulation

For development without confidential-computing hardware:

```bash
# Terminal 1: start server with mock DEK
CER_DEK=$(openssl rand -hex 32) \
  cargo run --manifest-path tools/tee-match/Cargo.toml --features secure \
  -- ServeSecure --addr 127.0.0.1:9721 --db /tmp/tee-local-db

# Terminal 2: run the test harness
./infra/test-tee-local.sh
```

What works locally:

- All secure endpoints (place, cancel, match, market, init)
- Encrypted order flow (AES-GCM with DEK)
- CLOB matching + ZK proof generation
- On-chain submission (if testnet RPC accessible)

What requires real hardware:

- SEV-SNP attestation (locally returns a stub)
- KMS unwrap (locally uses the env var)

## Deployment

No hosting configuration is committed to this repository. Build the image from
`infra/Dockerfile` and deploy it to a confidential-computing platform of your
choice, supplying `CER_DEK` from your own key-management service.
