ROOT := $(PWD)
CIRCUIT_KEYS := $(ROOT)/circuits/keys
CONTRACT_TARGET := $(ROOT)/contracts/target/wasm32v1-none/release

.PHONY: all clean \
	circuit-setup \
	build-contracts build-orderbook build-perp-engine build-shielded-pool \
	build-tools \
	deploy deploy-orderbook deploy-perp-engine \
	e2e ci-check hooks

all: circuit-setup build-contracts build-tools

# ======== Circuits ========
circuit-setup:
	$(MAKE) -C circuits setup-all

# ======== Contracts ========
build-orderbook:
	VK_COMMIT_JSON=$(CIRCUIT_KEYS)/order_commitment_vk.json \
	VK_CANCEL_JSON=$(CIRCUIT_KEYS)/order_cancel_vk.json \
	  cargo build --target wasm32v1-none --release -p orderbook
	wasm-opt -Oz --strip-debug --strip-producers --strip-target-features \
	  $(ROOT)/target/wasm32v1-none/release/orderbook.wasm \
	  -o $(ROOT)/target/wasm32v1-none/release/orderbook.wasm
	ls -la $(ROOT)/target/wasm32v1-none/release/orderbook.wasm

build-perp-engine:
	VK_COMMIT_JSON=$(CIRCUIT_KEYS)/order_commitment_vk.json \
	VK_CANCEL_JSON=$(CIRCUIT_KEYS)/order_cancel_vk.json \
	VK_MATCH_JSON=$(CIRCUIT_KEYS)/order_match_vk.json \
	VK_NOTE_SPEND_JSON=$(CIRCUIT_KEYS)/note_spend_vk.json \
	  cargo build --target wasm32v1-none --release -p perp-engine
	wasm-opt -Oz --strip-debug --strip-producers \
	  $(ROOT)/target/wasm32v1-none/release/perp_engine.wasm \
	  -o $(ROOT)/target/wasm32v1-none/release/perp_engine.wasm
	ls -la $(ROOT)/target/wasm32v1-none/release/perp_engine.wasm

build-shielded-pool:
	VK_POOL_INSERT_JSON=$(CIRCUIT_KEYS)/shielded_insert_vk.json \
	VK_POOL_WITHDRAW_JSON=$(CIRCUIT_KEYS)/shielded_withdraw_vk.json \
	  cargo build --target wasm32v1-none --release -p shielded-pool
	wasm-opt -Oz --strip-debug --strip-producers \
	  $(ROOT)/target/wasm32v1-none/release/shielded_pool.wasm \
	  -o $(ROOT)/target/wasm32v1-none/release/shielded_pool.wasm
	ls -la $(ROOT)/target/wasm32v1-none/release/shielded_pool.wasm

build-contracts: build-orderbook build-perp-engine build-shielded-pool

# ======== Tools ========
build-tools:
	cargo build --release --manifest-path tools/rust-circuits/Cargo.toml
	cargo build --release --manifest-path tools/e2e/Cargo.toml

# ======== Deploy ========
deploy-orderbook: build-orderbook
	cargo run --release -p e2e -- deploy

deploy-perp-engine: build-perp-engine
	stellar contract deploy \
	  --wasm $(ROOT)/target/wasm32v1-none/release/perp_engine.wasm \
	  --source e2e \
	  --network testnet

deploy: deploy-orderbook deploy-perp-engine

# ======== E2E ========
e2e: build-contracts build-tools
	cargo run --release --manifest-path tools/e2e/Cargo.toml -- --keys-dir circuits/keys --wasm-dir target/wasm32v1-none/release full

# ======== CI ========
ci-check:
	cargo fmt --all -- --check
	VK_COMMIT_JSON=$(CIRCUIT_KEYS)/order_commitment_vk.json \
	VK_CANCEL_JSON=$(CIRCUIT_KEYS)/order_cancel_vk.json \
	VK_MATCH_JSON=$(CIRCUIT_KEYS)/order_match_vk.json \
	VK_NOTE_SPEND_JSON=$(CIRCUIT_KEYS)/note_spend_vk.json \
	VK_POOL_INSERT_JSON=$(CIRCUIT_KEYS)/shielded_insert_vk.json \
	VK_POOL_WITHDRAW_JSON=$(CIRCUIT_KEYS)/shielded_withdraw_vk.json \
	  cargo clippy --all-targets -- -D warnings
	VK_COMMIT_JSON=$(CIRCUIT_KEYS)/order_commitment_vk.json \
	VK_CANCEL_JSON=$(CIRCUIT_KEYS)/order_cancel_vk.json \
	VK_MATCH_JSON=$(CIRCUIT_KEYS)/order_match_vk.json \
	VK_NOTE_SPEND_JSON=$(CIRCUIT_KEYS)/note_spend_vk.json \
	VK_POOL_INSERT_JSON=$(CIRCUIT_KEYS)/shielded_insert_vk.json \
	VK_POOL_WITHDRAW_JSON=$(CIRCUIT_KEYS)/shielded_withdraw_vk.json \
	  cargo test -p perp-engine -p orderbook -p types -p collateral
	cargo test -p shielded-pool
	cargo test -p rust-circuits

# ======== CI parity ========
# These targets run exactly what .github/workflows/ci.yml runs, so a green
# `make ci` locally means a green pipeline. Each delegates to the same script
# CI calls — there is no second implementation to drift.

VK_ENV = $(shell ./scripts/ci/circuit-keys.sh --print | sed 's/^export //' | tr '\n' ' ')

.PHONY: ci ci-hygiene ci-contracts ci-frontend ci-security \
	verify-keys verify-lockfiles verify-env verify-wasm scan-secrets \
	deploy-dry-run

## Run the full pipeline locally (everything a PR must pass).
ci: ci-hygiene ci-contracts ci-frontend
	@echo "\n✓ local CI passed — this is what the pipeline will run"

## Lockfiles, environment config and secret scanning.
ci-hygiene: verify-lockfiles verify-env scan-secrets

## Contracts: format, lint, test, build, validate artifacts.
ci-contracts: verify-keys
	cargo fmt --all -- --check
	env $(VK_ENV) cargo clippy --workspace --all-targets -- -D warnings
	env $(VK_ENV) cargo test --locked -p types -p collateral -p orderbook -p perp-engine
	cargo test --locked -p shielded-pool
	cargo test --locked -p rust-circuits
	env $(VK_ENV) cargo build --locked --target wasm32v1-none --release \
	  -p orderbook -p perp-engine -p shielded-pool -p collateral -p verifier-groth16
	@command -v wasm-opt >/dev/null 2>&1 && \
	  for w in orderbook perp_engine shielded_pool collateral verifier_groth16; do \
	    wasm-opt -Oz --strip-debug --strip-producers --strip-target-features \
	      $(ROOT)/target/wasm32v1-none/release/$$w.wasm \
	      -o $(ROOT)/target/wasm32v1-none/release/$$w.wasm; \
	  done || echo "⚠ wasm-opt not installed — sizes will exceed their budgets"
	./scripts/ci/validate-wasm.sh

## Frontend: lint, format, types, tests, build, validate bundle.
ci-frontend:
	cd app && npm ci --no-audit --no-fund
	cd app && npm run lint
	cd app && npm run format:check
	cd app && npm run typecheck
	cd app && npm run test
	cd app && npm run build
	./scripts/ci/validate-frontend-build.sh

## Security checks that do not need CI credentials.
ci-security: scan-secrets
	node scripts/ci/check-licenses.mjs --ecosystem all
	cd app && npm audit --audit-level=high

verify-keys:
	./scripts/ci/circuit-keys.sh

verify-lockfiles:
	./scripts/ci/verify-lockfiles.sh

verify-env:
	./scripts/ci/validate-env.sh

verify-wasm:
	./scripts/ci/validate-wasm.sh

scan-secrets:
	./scripts/ci/scan-secrets.sh

## Rehearse a deployment without submitting anything.
deploy-dry-run:
	./deploy/deploy.sh $(or $(ENV),development) --dry-run

# ======== Git hooks ========
hooks:
	cp .githooks/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	git config core.hooksPath .githooks
	@echo "Installed pre-commit hook (.githooks/pre-commit → .git/hooks/pre-commit)"

# ======== Clean ========
clean:
	$(MAKE) -C circuits clean
	cargo clean
	rm -rf deployments
