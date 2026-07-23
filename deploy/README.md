# deploy/

Deployment tooling. Used by [`.github/workflows/cd.yml`](../.github/workflows/cd.yml)
and equally runnable by hand — the workflow is orchestration, these scripts are
the deployment.

```
deploy/
├── deploy.sh            environment-driven contract deployment
├── rollback.sh          re-point an environment at a previous deployment
├── frontend.sh          publish the static bundle
├── environments/        per-environment configuration (non-secret)
│   ├── development.env  testnet, automatic after CI on main
│   ├── staging.env      testnet, manual, main only
│   └── production.env   mainnet, manual, requires approval
└── manifests/           deployment records, created at deploy time
    └── <env>/
        ├── <timestamp>.json   what was deployed, from which commit
        ├── <timestamp>.log    full CLI output
        └── latest.json        the environment's current deployment
```

## Quick reference

```bash
./deploy/deploy.sh development --dry-run     # rehearse; submits nothing
./deploy/deploy.sh development               # deploy
./deploy/deploy.sh staging --wasm-dir ./artifacts   # deploy a prebuilt artifact

./deploy/rollback.sh staging --list          # show deployment history
./deploy/rollback.sh staging                 # back one deployment
```

Full documentation: [`docs/ci-cd/DEPLOYMENT.md`](../docs/ci-cd/DEPLOYMENT.md).

## Design notes

**Configuration is data.** The three environments differ only in their `.env`
file. There is no per-environment branching in the scripts, so "what does
production do differently" is answered by reading one file.

**Guard rails run before anything is submitted.** Clean tree, allowed branch,
stellar CLI present, and artifact validation all happen before the first
transaction. A deploy that is going to fail should fail before it half-applies.

**Every deployment writes a manifest.** Contract IDs, wasm checksums, source
commit, actor. It is the deployment record and the input to rollback — without
it, "roll back" has nothing to name.

**Dry runs leave nothing behind.** They write to a temp directory, because a
manifest full of placeholder IDs sitting in `manifests/` would be offered to
`rollback.sh` as a real target.

**Rollback re-points, it does not revert.** Soroban contracts are immutable and
their addresses permanent, so rollback restores the previous contract IDs for
clients to use. Redeploying old code would create a third address with empty
state — which is not a rollback. See the header of `rollback.sh`.

## Secrets

Only one is required: `STELLAR_DEPLOYER_SECRET`, supplied per environment via
GitHub Environment secrets. Never put a key in `environments/*.env` — those
files are committed. See [`docs/ci-cd/SECRETS.md`](../docs/ci-cd/SECRETS.md).
