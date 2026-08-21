#!/usr/bin/env bash
#
# Checks everything the live Base Sepolia run needs, BEFORE it needs it.
#
# The deploy broadcasts in two sections and the demo sends five transactions, so a
# missing prerequisite otherwise surfaces halfway through with gas already spent --
# and the worst of them, a 7702-delegated principal, surfaces as
# `ERC721InvalidReceiver` from inside an ERC-721 mint, which reads like a registry
# problem rather than an address problem.
#
# Read-only. Sends nothing, signs nothing, and never prints a private key.
# Safe to re-run after every faucet claim.
#
# Written for bash 3.2, which is what macOS ships: no associative arrays, no
# `declare -A`, no `${var,,}`.
set -uo pipefail
cd "$(dirname "$0")/.."

set -a && . ./.env && set +a

PASS=0; FAIL=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
note() { printf "      %s\n" "$1"; }

# Amounts demo-2 needs. demo.ts needs 50x these and is fork-only.
NEED_USDC=10000000        # 10 USDC, 6dp -- demo-2's FIRST_DEPOSIT
NEED_WEI=100000000000000  # 0.0001 ETH; the deploy estimates ~0.00003

# The target chain is selectable. Defaults keep Base Sepolia so an unchanged .env
# behaves exactly as before.
RPC="${TARGET_RPC_URL:-${BASE_SEPOLIA_RPC_URL:-}}"
WANT_CHAIN="${TARGET_CHAIN_ID:-84532}"

case "$WANT_CHAIN" in
  84532)    CHAIN_NAME="Base Sepolia"
            EXPLORER="https://sepolia.basescan.org"
            GAS_FAUCETS="https://basefaucet.com/ (Base-only, no network dropdown)|https://portal.cdp.coinbase.com/products/faucet   0.1 ETH / 24h" ;;
  11155111) CHAIN_NAME="Ethereum Sepolia"
            EXPLORER="https://sepolia.etherscan.io"
            GAS_FAUCETS="https://www.alchemy.com/faucets/ethereum-sepolia|https://sepoliafaucet.com/" ;;
  *)        CHAIN_NAME="chain $WANT_CHAIN"
            EXPLORER=""
            GAS_FAUCETS="" ;;
esac

# Public Base endpoints return intermittent 503 ("no backend is currently healthy").
# Retry rather than reporting a funded address as empty -- a false negative here
# sends you back to a rate-limited faucet for tokens you already hold.
retry() {
  local n=0 out
  while [ $n -lt 4 ]; do
    if out=$("$@" 2>/dev/null) && [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    n=$((n+1)); sleep 1
  done
  return 1
}

# bash arithmetic is 64-bit signed and wei balances can exceed it; compare via awk.
gte() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

echo "=== 1. environment ==="
if [ -n "$RPC" ]; then ok "RPC set (TARGET_RPC_URL or BASE_SEPOLIA_RPC_URL)"; else bad "no RPC URL set"; fi
for v in REGISTRY_ADDRESS USDC_ADDRESS; do
  eval "val=\${$v:-}"
  if [ -n "$val" ]; then ok "$v set"; else bad "$v is empty"; fi
done
ok "target: $CHAIN_NAME (chain $WANT_CHAIN)"
if [ -n "${BASESCAN_API_KEY:-}" ]; then
  ok "BASESCAN_API_KEY set"
else
  bad "BASESCAN_API_KEY is empty -- --verify will fail"
  note "Get it from https://etherscan.io/myapikey (NOT basescan.org: under"
  note "Etherscan V2 only Etherscan keys work; the var name here is historical)"
fi

echo
echo "=== 2. keys ==="
KEYS_OK=1
for role in DEPLOYER PRINCIPAL AGENT; do
  eval "key=\${${role}_PRIVATE_KEY:-}"
  if [ -z "$key" ]; then
    bad "${role}_PRIVATE_KEY is empty"; KEYS_OK=0; continue
  fi
  if ! addr=$(cast wallet address "$key" 2>/dev/null); then
    bad "${role}_PRIVATE_KEY is not a valid key (want 0x + 64 hex chars)"; KEYS_OK=0; continue
  fi
  eval "ADDR_${role}=\$addr"
  ok "$role  $addr"
done

if [ "$KEYS_OK" -eq 0 ]; then
  echo
  echo "Fill the missing keys in .env, then re-run. Generate one with:"
  echo '  k=0x$(openssl rand -hex 32); echo "$k  # $(cast wallet address $k)"'
  exit 1
fi

if [ "$(printf '%s\n%s\n%s\n' "$ADDR_DEPLOYER" "$ADDR_PRINCIPAL" "$ADDR_AGENT" | sort -u | wc -l | tr -d ' ')" = "3" ]; then
  ok "all three addresses are distinct"
else
  bad "the three keys do not give three distinct addresses"
  note "principal and agent MUST differ, or demo tx 4 (NotAgent) cannot fire"
fi

echo
echo "=== 3. chain ==="
if ! CHAIN=$(retry cast chain-id --rpc-url "$RPC"); then
  bad "cannot reach BASE_SEPOLIA_RPC_URL after 4 tries"
  note "Public endpoints are rate-limited and flaky; a keyed provider is worth it."
  exit 1
fi
if [ "$CHAIN" = "$WANT_CHAIN" ]; then
  ok "chain $CHAIN ($CHAIN_NAME)"
else
  bad "the RPC is on chain $CHAIN but TARGET_CHAIN_ID says $WANT_CHAIN"
  note "Addresses look identical on every EVM chain, so this mismatch is silent."
  note "Point TARGET_RPC_URL at $CHAIN_NAME, or change TARGET_CHAIN_ID to $CHAIN."
fi

# A degraded endpoint can still answer eth_chainId and eth_blockNumber while 503ing
# every STATE read -- https://sepolia.base.org does exactly this. Probe a state read
# up front, because otherwise every balance below grinds through four retries at ~8s
# each and the script looks hung rather than broken.
if ! retry cast code "$USDC_ADDRESS" --rpc-url "$RPC" >/dev/null; then
  bad "the RPC answers eth_chainId but 503s on state reads (eth_getCode/eth_getBalance)"
  note "This endpoint cannot deploy or run the demo. Known-good alternatives:"
  if [ "$WANT_CHAIN" = "84532" ]; then
    note "  https://base-sepolia-rpc.publicnode.com"
    note "  https://base-sepolia.drpc.org"
    note "  https://base-sepolia.gateway.tenderly.co"
  else
    note "  https://ethereum-sepolia-rpc.publicnode.com"
    note "  https://sepolia.drpc.org"
  fi
  note "Set TARGET_RPC_URL to one of them in .env and re-run."
  echo
  echo "========================================"
  echo "NOT READY — the RPC is unusable; later checks would report false zeros."
  exit 1
fi

# "Has code" is NOT sufficient to identify a contract across chains, and assuming it
# was would have let a real mistake through: Base Sepolia's USDC address
# (0x036CbD53...) holds an unrelated Truffle `Migrations` contract on Ethereum
# Sepolia. A stale USDC_ADDRESS after a chain switch would therefore have passed a
# code check and then failed obscurely inside balanceOf. Identify by interface.
REG_NAME=$(retry cast call "$REGISTRY_ADDRESS" 'name()(string)' --rpc-url "$RPC")
case "$REG_NAME" in
  *AgentIdentity*) ok "registry is the ERC-8004 AgentIdentity" ;;
  "")              bad "registry ($REGISTRY_ADDRESS) has no name() -- wrong address for this chain?" ;;
  *)               bad "registry ($REGISTRY_ADDRESS) reports name()=$REG_NAME, expected AgentIdentity" ;;
esac

USDC_SYM=$(retry cast call "$USDC_ADDRESS" 'symbol()(string)' --rpc-url "$RPC")
USDC_DEC=$(retry cast call "$USDC_ADDRESS" 'decimals()(uint8)' --rpc-url "$RPC")
if [ "$USDC_SYM" = '"USDC"' ] && [ "$USDC_DEC" = "6" ]; then
  ok "USDC is USDC, 6 decimals"
else
  bad "USDC_ADDRESS ($USDC_ADDRESS) reports symbol=${USDC_SYM:-none} decimals=${USDC_DEC:-none}"
  note "That is not Circle USDC on $CHAIN_NAME. The right address there is:"
  case "$WANT_CHAIN" in
    84532)    note "  0x036CbD53842c5426634e7929541eC2318f3dCF7e" ;;
    11155111) note "  0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" ;;
  esac
  note "An address that exists on one chain usually holds something unrelated on another."
fi

echo
echo "=== 4. the principal must be codeless ==="
# ERC-721 _safeMint calls onERC721Received whenever the receiver HAS CODE. An EOA
# carrying an EIP-7702 delegation has code (0xef0100<delegate>), the delegate does
# not implement the hook, and register() reverts ERC721InvalidReceiver.
PCODE=$(retry cast code "$ADDR_PRINCIPAL" --rpc-url "$RPC")
if [ "$PCODE" = "0x" ]; then
  ok "principal is codeless"
else
  bad "principal HAS CODE: $PCODE"
  note "register() will revert ERC721InvalidReceiver and the deploy will abort."
  case "$PCODE" in 0xef0100*) note "That prefix is an EIP-7702 delegation." ;; esac
  note "Generate a fresh principal key rather than trying to clear it."
fi

echo
echo "=== 5. gas ==="
GAS_SHORT=0
for role in DEPLOYER PRINCIPAL AGENT; do
  eval "a=\$ADDR_${role}"
  bal=$(retry cast balance "$a" --rpc-url "$RPC") || bal=""
  if [ -z "$bal" ]; then bad "$role  could not read balance"; GAS_SHORT=1; continue; fi
  eth=$(cast to-unit "$bal" ether)
  if gte "$bal" "$NEED_WEI"; then ok "$role  $eth ETH"; else bad "$role  $eth ETH -- needs gas"; GAS_SHORT=1; fi
done
if [ "$GAS_SHORT" -eq 1 ] && [ -n "$GAS_FAUCETS" ]; then
  note "Faucets for $CHAIN_NAME -- check the network selector, it is the usual mistake:"
  echo "$GAS_FAUCETS" | tr '|' '\n' | while read -r f; do note "  $f"; done
fi

echo
echo "=== 6. USDC ==="
PUSDC=$(retry cast call "$USDC_ADDRESS" 'balanceOf(address)(uint256)' "$ADDR_PRINCIPAL" --rpc-url "$RPC" | awk '{print $1}')
if [ -n "$PUSDC" ] && gte "$PUSDC" "$NEED_USDC"; then
  ok "principal holds $(cast to-unit "$PUSDC" mwei) USDC (demo-2 needs 10)"
else
  bad "principal holds ${PUSDC:-?} units -- demo-2 needs $NEED_USDC (10 USDC)"
  note "https://faucet.circle.com/  ->  $CHAIN_NAME  ->  $ADDR_PRINCIPAL"
  note "20 USDC per claim, every 2 hours. One claim is enough."
fi

# Not a funding check -- an invariant. The agent is never funded; demo tx 2 asserts
# it holds zero of both, and the whole containment claim rests on it.
AUSDC=$(retry cast call "$USDC_ADDRESS" 'balanceOf(address)(uint256)' "$ADDR_AGENT" --rpc-url "$RPC" | awk '{print $1}')
if [ "${AUSDC:-0}" = "0" ]; then
  ok "agent holds no USDC (containment invariant)"
else
  bad "agent holds $(cast to-unit "$AUSDC" mwei) USDC -- it must never be funded"
  note "demo tx 2 asserts the agent ends holding zero of both."
fi

echo
if [ -n "$EXPLORER" ]; then
  echo "Explorer ($CHAIN_NAME) -- the domain is how you tell the chains apart:"
  for role in DEPLOYER PRINCIPAL AGENT; do
    eval "a=\$ADDR_${role}"
    printf "  %-10s %s/address/%s\n" "$role" "$EXPLORER" "$a"
  done
  echo
fi

echo "========================================"
if [ "$FAIL" -eq 0 ]; then
  echo "READY — $PASS checks passed. Next:"
  echo
  echo '  set -a && . ./.env && set +a'
  echo '  forge fmt --check && forge test \'
  echo '    && forge script script/Deploy.s.sol --rpc-url "$TARGET_RPC_URL" \'
  echo '         --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --verify'
  exit 0
fi
echo "NOT READY — $FAIL check(s) failed, $PASS passed. Fix the ✗ lines and re-run."
exit 1
