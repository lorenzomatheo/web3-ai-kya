#!/usr/bin/env bash
#
# Runs the whole of group 5 -- deploy plus all eleven demo transactions -- against a
# local anvil fork of Base Sepolia, before any faucet ETH is spent.
#
# `scripts/demo.ts` and `script/Deploy.s.sol` run BYTE-IDENTICAL here and against real
# Sepolia. Only the RPC and the keys differ, and both come from the environment. No
# test-only branch exists inside either file; if it did, this rehearsal would be
# rehearsing something other than the thing that ships.
#
# `set -o pipefail` is not decoration: without it a `| tee` supplies the pipeline's
# exit status and a failing demo reads green.
set -euo pipefail

cd "$(dirname "$0")/.."

set -a && . ./.env && set +a
: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL must be set in .env}"

# This rehearsal forks Base Sepolia specifically, so its two external addresses are
# known rather than configurable. Defaulted here so a .env predating group 5 still
# works; a value already in .env wins, which is what lets the same script rehearse
# against a different registry deployment.
: "${REGISTRY_ADDRESS:=0x8004A818BFB912233c491871b3d84c89A494BD9e}"
: "${USDC_ADDRESS:=0x036CbD53842c5426634e7929541eC2318f3dCF7e}"
export REGISTRY_ADDRESS USDC_ADDRESS

PORT="${DRYRUN_PORT:-8545}"
LOCAL_RPC="http://127.0.0.1:${PORT}"
LOG=/tmp/g5-dryrun-anvil.log

# Freshly generated keys, NOT anvil's deterministic accounts 0/1/2.
#
# Those well-known accounts are unusable as the principal on a Base Sepolia fork.
# Their private keys are public, so somebody has EIP-7702-delegated all three on the
# live chain -- `cast code` returns 0xef0100..91128fa0.. for each. On a fork they
# therefore HAVE CODE, which makes ERC-721 `_safeMint` take its
# `onERC721Received` branch; the delegate does not implement it, and `register()`
# reverts `ERC721InvalidReceiver`. Fresh addresses have no delegation and no code.
#
# The same hazard applies in production: a principal EOA carrying a 7702 delegation
# cannot receive the agent NFT. Recorded in group-5-constraints.md.
DEPLOYER_PRIVATE_KEY=0x$(openssl rand -hex 32)
PRINCIPAL_PRIVATE_KEY=0x$(openssl rand -hex 32)
AGENT_PRIVATE_KEY=0x$(openssl rand -hex 32)
export DEPLOYER_PRIVATE_KEY PRINCIPAL_PRIVATE_KEY AGENT_PRIVATE_KEY

PRINCIPAL=$(cast wallet address "$PRINCIPAL_PRIVATE_KEY")
DEPLOYER=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
AGENT=$(cast wallet address "$AGENT_PRIVATE_KEY")

cleanup() { [[ -n "${ANVIL_PID:-}" ]] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "=== booting anvil, forking Base Sepolia ==="
# --chain-id is mandatory, not tidiness: anvil defaults to 31337 even when forking,
# and `chainId` sits inside the EIP-712 domain. A rehearsal on 31337 would sign
# under a different domain separator than production and prove nothing about the
# signatures that matter.
anvil --fork-url "$BASE_SEPOLIA_RPC_URL" --port "$PORT" --chain-id 84532 --silent >"$LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 40); do
  cast chain-id --rpc-url "$LOCAL_RPC" >/dev/null 2>&1 && break
  sleep 0.5
done
CHAIN_ID=$(cast chain-id --rpc-url "$LOCAL_RPC")
echo "    up on $LOCAL_RPC, chain $CHAIN_ID"
[[ "$CHAIN_ID" == "84532" ]] || { echo "expected chain 84532, got $CHAIN_ID"; exit 1; }

# Funding the principal with USDC is the only part of this rehearsal that a real run
# does at a faucet. Base Sepolia USDC is a Circle FiatToken, so the mint path is
# deterministic: impersonate the masterMinter, authorise ourselves, mint.
#
# NOT a storage-slot poke. USDC here is a proxy, so the balance slot is a guess that
# breaks on any upgrade -- the same awkwardness group 4 hit on mainnet and recorded
# at group-4-completion.md:41. And NOT a whale impersonation, because testnet whales
# go empty without warning.
echo "=== funding gas for the three fresh accounts ==="
for who in "$DEPLOYER" "$PRINCIPAL" "$AGENT"; do
  cast rpc anvil_setBalance "$who" 0x8ac7230489e80000 --rpc-url "$LOCAL_RPC" >/dev/null
done

# Belt and braces on the finding above: assert the three accounts really are
# codeless before relying on it, so a future 7702 delegation on a generated address
# fails here with a legible message rather than inside an ERC-721 mint.
for who in "$DEPLOYER" "$PRINCIPAL" "$AGENT"; do
  [[ "$(cast code "$who" --rpc-url "$LOCAL_RPC")" == "0x" ]] \
    || { echo "$who has code; ERC-721 _safeMint will take its onERC721Received branch"; exit 1; }
done

echo "=== funding the principal with test USDC ==="
MASTER_MINTER=$(cast call "$USDC_ADDRESS" 'masterMinter()(address)' --rpc-url "$LOCAL_RPC")
for who in "$MASTER_MINTER" "$DEPLOYER"; do
  cast rpc anvil_impersonateAccount "$who" --rpc-url "$LOCAL_RPC" >/dev/null
  cast rpc anvil_setBalance "$who" 0xde0b6b3a7640000 --rpc-url "$LOCAL_RPC" >/dev/null
done
cast send "$USDC_ADDRESS" 'configureMinter(address,uint256)' "$DEPLOYER" 1000000000000 \
  --from "$MASTER_MINTER" --unlocked --rpc-url "$LOCAL_RPC" >/dev/null
cast send "$USDC_ADDRESS" 'mint(address,uint256)' "$PRINCIPAL" 10000000000 \
  --from "$DEPLOYER" --unlocked --rpc-url "$LOCAL_RPC" >/dev/null
echo "    principal holds $(cast call "$USDC_ADDRESS" 'balanceOf(address)(uint256)' "$PRINCIPAL" --rpc-url "$LOCAL_RPC")"

echo "=== deploying ==="
forge script script/Deploy.s.sol --rpc-url "$LOCAL_RPC" \
  --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast | tee /tmp/g5-dryrun-deploy.log

# Read back from the same broadcast artifact `pnpm demo` falls back to, so the
# deploy -> demo handoff is rehearsed rather than short-circuited here.
AGENT_ID=$(awk '/^  AGENT_ID /{print $2}' /tmp/g5-dryrun-deploy.log | tail -1)
[[ -n "$AGENT_ID" ]] || { echo "could not read AGENT_ID out of the deploy log"; exit 1; }
export AGENT_ID CHAIN_ID
export BASE_SEPOLIA_RPC_URL="$LOCAL_RPC"
unset VAULT_ADDRESS ROUTER_ADDRESS || true

echo "=== running the demo ==="
pnpm demo
