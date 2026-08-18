# Findings — external dependencies verified live

**Date:** 2026-08-18 · **Verified by:** Victor / Claude Code · **Against:** WISH.md (plan review SHIP, round 7)

Every external dependency the WISH depends on, re-checked against live RPC. All
commands below are reproducible — run them yourself.

---

## 1. The WISH's one carried risk is closed: ERC-8004 registration is permissionless

The plan review recorded this as the single unhedged external dependency:

> **Carried risk (accepted, not closed):** the ERC-8004 registration *write* path
> on Base Sepolia is unverified — only reads were checked during design.

**It is now verified, and it works.** No fallback needed.

```bash
R=https://sepolia.base.org
A=0x8004A818BFB912233c491871b3d84c89A494BD9e

cast call $A "name()(string)"   --rpc-url $R   # "AgentIdentity"
cast call $A "symbol()(string)" --rpc-url $R   # "AGENT"
cast call $A "ownerOf(uint256)(address)" 1 --rpc-url $R
#   0x21fdEd74C901129977B8e28C2588595163E1e235

# The write path, simulated from a real EOA:
cast call $A "register()(uint256)" --from 0x21fdEd74C901129977B8e28C2588595163E1e235 --rpc-url $R
#   8991
cast call $A "register(string)(uint256)" "ipfs://demo" --from 0x21fdEd74C901129977B8e28C2588595163E1e235 --rpc-url $R
#   8991
```

Both `register()` and `register(string)` overloads exist and simulate green,
returning the next token id.

**How we know it is not permissioned.** Calling `register()` with no `--from`
(i.e. as `address(0)`) reverts with selector `0x64a0ae92` =
`ERC721InvalidReceiver(address)`. It fails on the *receiver being zero*, not on a
permission gate — and the same call from a funded EOA succeeds. The contract does
expose `owner()` (`0x547289319C3e6aedB179C0b8e8aF0B5ACd062603`), so it is
`Ownable`, but registration is not behind it.

**Consequence for group 1:** acceptance criterion 7's branch is the **real
registry**. `MinimalIdentityRegistry` stays test-only; it does not need deploying
to Base Sepolia. DESIGN decision 7 keeps the registry a constructor parameter, so
the fallback remains available if this ever changes.

Incidental: the registry is a minimal proxy (~130 bytes of code) and serves a
base64 data-URI `tokenURI` typed
`https://eips.ethereum.org/EIPS/eip-8004#registration-v1`.

---

## 2. `mwUSDC` is good for the group 4 fork pin

```bash
M=https://mainnet.base.org
V=0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca

cast call $V "symbol()(string)"      --rpc-url $M   # "mwUSDC"
cast call $V "decimals()(uint8)"     --rpc-url $M   # 18
cast call $V "asset()(address)"      --rpc-url $M   # 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC, 6dp)
cast call $V "MORPHO()(address)"     --rpc-url $M   # 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
cast call $V "totalAssets()(uint256)" --rpc-url $M  # ~7.746e12 == ~7.75M USDC
```

Confirms DESIGN's claim: 18-decimal shares over a 6-decimal asset. Group 4's
round-trip tolerance is stated in **asset** units (USDC, 6dp) and no share-side
epsilon is implied — the 18/6 asymmetry here is exactly why.

---

## 3. RPC endpoints

| Endpoint | Status |
|---|---|
| `https://mainnet.base.org` | reachable, block 50145795 at time of check |
| `https://sepolia.base.org` | reachable; USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e` responds `symbol() == "USDC"` |

Public endpoints are enough for `test/fork/ProfileGuard.t.sol`, which makes no
RPC calls. **Group 4 will want a keyed provider** — public Base RPC is
rate-limited and a fork suite hammers `eth_getStorageAt`.

---

## 4. `no_match_path` is a real `foundry.toml` key

WISH group 1 deliverable 1 asserts this parenthetically ("verified to be a real
config key, not a CLI-only flag"). Confirmed on the installed Foundry **1.7.1**:

```bash
forge config --json | python3 -c "import json,sys; print([k for k in json.load(sys.stdin) if 'match' in k])"
# ['match_test', 'no_match_test', 'match_contract', 'no_match_contract',
#  'match_path', 'no_match_path', 'no_match_coverage']
```

Note it does *not* appear in plain `forge config` output when unset — only
`--json` lists it. That is presumably why it read as doubtful.

---

## 5. Group 3's Morpho escape hatch fires **today**

Not a finding so much as a clock. The trigger is "end of 2026-08-18", which is
today, and the WISH's own rule is unambiguous:

> If the date passes unevaluated — which it can, since this group sits in wave 2
> behind group 1 — the hatch is **taken by default**, not failed: the clock exists
> to force the safe branch, not to fail the group.

**So `AllowlistedERC4626` ships holding USDC idle**, and Morpho exposure stays
confined to group 4's mainnet fork suite (where `mwUSDC` is verified above, so
that half is already covered). Whoever takes group 3 should record the hatched
branch in its completion note rather than re-deciding.

---

## 6. Minor inconsistencies in WISH.md (cosmetic, flagged not fixed)

Raising rather than editing, since `.genie/` is Lorenzo's:

1. **`Repos touched: web3-kyc`** in the WISH header — this repo is `web3-ai-kya`.
2. **`.gitmodules` is missing** from *Files to Create/Modify*, though group 1
   deliverable 4 requires committed submodules. It is created by `forge install`.
3. **`pnpm install --frozen-lockfile`** in group 1's own validation block is
   chicken-and-egg: no `pnpm-lock.yaml` exists on a first run. Resolved by running
   plain `pnpm install` once to generate it; the gate then works unmodified.
4. **`git ls-files --error-unmatch .env.example`** requires the file to be
   *tracked*, so group 1's gate can only pass **after** a commit. Undocumented
   ordering constraint.
5. **`script/` vs `scripts/`** — `script/Deploy.s.sol` (Foundry) and
   `scripts/demo.ts` (TypeScript) differ by one character. Deliberate, since
   `forge script` requires `script/`, but a live typo hazard for group 5.
