#!/usr/bin/env bash
#
# Boots a fresh local chain and serves the local-demo page against it.
#
# No fork, no RPC, no faucet, no network of any kind: the page deploys all four
# contracts onto an empty chain and drives the whole flow itself. That is the point --
# a demo that depends on nothing external cannot fail in front of an audience, and
# starting from an empty chain is what makes "link the agent to the principal" a step
# you can watch rather than a precondition that already happened.
#
# Written for bash 3.2, which is what macOS ships.
set -uo pipefail
cd "$(dirname "$0")/.."

ANVIL_PORT="${ANVIL_PORT:-8545}"
WEB_PORT="${WEB_PORT:-8081}"
RPC="http://127.0.0.1:${ANVIL_PORT}"

cleanup() {
  [ -n "${ANVIL_PID:-}" ] && kill "$ANVIL_PID" 2>/dev/null
  [ -n "${WEB_PID:-}" ] && kill "$WEB_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

echo "=== building contracts ==="
forge build || { echo "forge build failed"; exit 1; }

# The page deploys from creation bytecode, so it needs the artifacts. Regenerated on
# every run rather than committed: a stale copy would silently deploy yesterday's
# contracts while the page claimed to be showing today's.
echo "=== extracting artifacts ==="
python3 - <<'PY' || exit 1
import glob, io, json, sys

WANT = ["MockUSDC", "MinimalIdentityRegistry", "AllowlistedERC4626", "MandateRouter"]
out = {}
for name in WANT:
    hits = glob.glob(f"out/{name}.sol/{name}.json")
    if not hits:
        sys.exit(f"no artifact for {name} -- did forge build succeed?")
    a = json.load(io.open(hits[0]))
    out[name] = {
        # `bytecode` is what you deploy; `deployedBytecode` is what ends up on chain
        # and is what the verification harness compares eth_getCode against.
        "bytecode": a["bytecode"]["object"],
        "deployedBytecode": a["deployedBytecode"]["object"],
    }
    print(f"  {name}: {len(out[name]['bytecode']) // 2} bytes")

io.open("local-demo/artifacts.json", "w").write(json.dumps(out))
PY

echo "=== booting anvil (fresh chain, no fork) ==="
anvil --port "$ANVIL_PORT" --silent >/tmp/local-demo-anvil.log 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 40); do
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 0.25
done
CHAIN=$(cast chain-id --rpc-url "$RPC" 2>/dev/null)
[ -n "$CHAIN" ] || { echo "anvil did not come up; see /tmp/local-demo-anvil.log"; exit 1; }
echo "  up on $RPC, chain $CHAIN"

# Serving local-demo/ specifically, NOT the repo root: python's http.server serves
# everything beneath its directory, and the repo root contains .env.
echo "=== serving ==="
python3 -m http.server "$WEB_PORT" --directory local-demo >/tmp/local-demo-web.log 2>&1 &
WEB_PID=$!
sleep 1

cat <<EOF

  ┌──────────────────────────────────────────────┐
     open  http://localhost:${WEB_PORT}
     chain  ${RPC}  (id ${CHAIN}, fresh)
  └──────────────────────────────────────────────┘

  Press Start on the page. Ctrl-C here to stop both.

EOF

wait "$ANVIL_PID"
