# Group 5 — completion note

**Status:** AUTHORED AND REHEARSED · **broadcast is PENDING PROVISIONING** ·
**Date:** 2026-08-20 · **Branch:** `feat/g5-deploy-demo` → `wish/agent-mandate-vault-gate`

Everything in this group is written and every one of the eleven transactions has been
run end to end. What has **not** happened is the live Base Sepolia broadcast, because
`DEPLOYER_PRIVATE_KEY`, `PRINCIPAL_PRIVATE_KEY`, `AGENT_PRIVATE_KEY` and
`BASESCAN_API_KEY` are all empty in `.env` and the addresses hold no faucet ETH or test
USDC. That is provisioning, not code.

So this note reports a **rehearsal, and says so**. The two acceptance criteria that can
only be satisfied by a broadcast — verified contracts on Basescan, and the deployed
addresses pinned here — are open and marked open below.

## Branch shape

Cut from `feat/g4-fork-suite`, not from `wish/`. Group 5 `depends-on: 2, 3`, but
WISH.md:325's ordering constraint is separate from the dependency edge: the final
gate-and-broadcast run must execute on a tree that already contains group 4's
containment audit, and `feat/g4-fork-suite` is the only branch carrying 1+2+3+4. The
four open PRs are untouched.

## The rehearsal — `scripts/dryrun.sh`, exit 0

`anvil --fork-url $BASE_SEPOLIA_RPC_URL --chain-id 84532`, then the real
`script/Deploy.s.sol` and the real `pnpm demo` against it. **Both run byte-identical
here and against live Sepolia** — only the RPC and the keys differ, and both come from
the environment. There is no test-only branch inside either file; if there were, the
rehearsal would be rehearsing something other than the thing that ships.

`--chain-id 84532` is mandatory rather than tidy: anvil defaults to 31337 **even when
forking**, and `chainId` sits inside the EIP-712 domain. A rehearsal on 31337 signs
under a different domain separator than production and proves nothing about the
signatures that matter.

```
[1] agent deposits 500.00 USDC for the principal → Deposited
      SUCCEEDED (this transaction is meant to succeed)
      minted 500000000 shares to the principal; spent = 500.00 USDC
[2] agent redeems the position → Redeemed, assets to the PRINCIPAL
      SUCCEEDED (this transaction is meant to succeed)
      spent is UNCHANGED at 500.00 USDC — redemption never decreases it
      agent holds 0 USDC and 0 shares (containment)
[3] agent deposits 600.00 USDC against a remaining 500.00 USDC → ExceedsMandate
      reverted: ExceedsMandate(500000000, 600000000)
[4] the PRINCIPAL calls depositFor, but the mandate names the agent → NotAgent
      reverted: NotAgent()
[5] mandate targets a different vault → WrongVault
      reverted: WrongVault()
[6] mandate expired an hour ago → MandateExpired
      reverted: MandateExpired()
[7] agentId was never minted → AgentNotRegistered
      reverted: AgentNotRegistered()
[8] one byte flipped in the signature → InvalidSignature
      reverted: InvalidSignature()
[9] the PRINCIPAL revokes the mandate → Revoked, and does NOT revert
      SUCCEEDED (this transaction is meant to succeed)
[10] agent replays the previously valid mandate → MandateRevoked
      reverted: MandateRevoked()
[11] agent deposits into the vault directly, to ITSELF → NotAllowlisted(agent)
      reverted: NotAllowlisted(0xcEDc78C7356eF32888eDfa922721E8A6560C86D0)

OK — 11 transactions: 8 custom errors decoded with operands, 3 succeeded as intended.
```

Repository gate on this branch, unchanged: `forge fmt --check && forge build &&
forge test` exit **0**. `tsc --noEmit` exit **0**.

## Two findings the rehearsal produced, which reading the code would not have

### 1. A 7702-delegated principal cannot receive the `agentId` — HIGH

ERC-721 `_safeMint` calls `onERC721Received` **whenever the receiver has code**, and an
EOA carrying an EIP-7702 delegation has code (`0xef0100<delegate>`). The delegate does
not implement the hook, so `register()` reverts `ERC721InvalidReceiver` and the deploy
aborts.

Found because the first rehearsal used anvil's default accounts — whose private keys
are public, so somebody has delegated all three on live Base Sepolia:

```
cast code 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
#   0xef010091128fa0c92671265263548853eb875feded35b4
```

Same failure site and same symptom class as Lorenzo's original HIGH, and equally
invisible from source. `scripts/dryrun.sh` now generates fresh keys and asserts they
are codeless before relying on it. **Before provisioning, check the real principal
address the same way** — recorded as §1b of
[`group-5-constraints.md`](group-5-constraints.md).

### 2. `console2.log("AGENT_ID", id)` prints on one line

Trivial, but it silently fed the string `PRINCIPAL0xbeCc…` into `BigInt()`. Noted only
because the deploy → demo handoff reads the id back out of the log, and the rehearsal
is what caught it rather than the live run.

## The registration key — Lorenzo's HIGH, implemented and proven

`script/Deploy.s.sol` broadcasts steps 1–4 under the deployer and brackets
`register()` in its own `vm.startBroadcast(PRINCIPAL_PRIVATE_KEY)`, then closes with

```solidity
require(IERC721(registry).ownerOf(agentId) == principal, "Deploy: agentId is not owned by the principal");
```

Verified by mutation — switching that one broadcast to the deployer's key gives:

```
└─ ← [Revert] Deploy: agentId is not owned by the principal
Error: script failed: Deploy: agentId is not owned by the principal
```

It fails **during simulation**, so nothing is broadcast and nothing is spent. That is
the whole value of the assertion: without it the deploy succeeds, and the failure
resurfaces nine transactions later as `InvalidSignature`.

## The demo asserts; it does not merely print

Every case asserts its outcome and the script exits non-zero on any mismatch. A demo
that only prints is a demo that passes when the contract is broken — the same failure
class as the vacuous loop test PR #2 removed. Verified by mutation:

| Mutation | Result |
|---|---|
| `register()` under the deployer's key | deploy aborts at the `ownerOf` require, nothing broadcast |
| Allowlist the agent as well as the principal | `tx 11: expected NotAllowlisted, got Error` — exit 1 |
| `revoke` from the **agent's** key instead of the principal's | `tx 10: expected MandateRevoked, but the call SUCCEEDED` — exit 1 |

The third reproduces DESIGN's own warning verbatim: revoking from the agent's key
leaves transaction 10 "quietly succeeding". `revoke` writes at `(digest, msg.sender)`
and the deposit path reads at `(digest, principal)`, so the demo would have printed ten
green lines while asserting nothing about the kill switch.

## One reading of the spec, stated rather than assumed

DESIGN says "eleven transactions" and eight of them revert. **Those eight are
demonstrated with `simulateContract`, not broadcast.** viem returns
`ContractFunctionRevertedError` carrying `errorName` and `args`, which is exactly the
"decoded custom error with operands" the criterion asks for. The three that succeed
(1, 2, 9) are broadcast for real, alongside the two setup approvals.

Broadcasting the reverting eight is the other reading. It is more literally
"transactions" and would leave Basescan evidence, but gas estimation reverts first so
each needs a hand-set `gas`, it costs faucet ETH eight times over, and a receipt does
not carry the revert reason anyway — recovering it needs the same `eth_call` this
already does. Flagged here so the choice is reviewable rather than inferred; it is a
small change if the other reading is preferred.

## Allowances — deliverable 4, both legs from the principal's key

- **USDC**: approved **equal to the cap** (1,000 USDC), before transaction 1, and
  asserted equal before proceeding. Larger would still be bound by the mandate — that
  is the loop-until-rejection criterion — but the demo should show intended practice
  (DESIGN risk 3).
- **Shares**: approved **after** transaction 1, for exactly the amount that
  transaction minted, read off the `Deposited` log. The position does not exist until
  transaction 1 creates it. Never `type(uint256).max`: the share leg is bounded by
  nothing inside the mandate (risks 11 and 12), so its only limits are expiry,
  revocation, and this number.

## Acceptance criteria

| Criterion | Status |
|---|---|
| All eleven transactions run in order, script exits 0 | **Met on the fork.** Re-run live before claiming it outright |
| Eight distinct errors, three non-reverting | Met — the eight are distinct and named above |
| Transaction 9 from the principal's key | Met, and proven load-bearing by mutation |
| Transaction 2 does not revert `ERC20InsufficientAllowance` | Met — the share approval lands between 1 and 2 |
| Every revert decoded with operands, never a raw selector or an OZ name | Met — `expectRevert` fails the run on any undecodable revert |
| The script says out loud that 1, 2 and 9 succeed | Met — "SUCCEEDED (this transaction is meant to succeed)" |
| **Contracts deployed and verified on Basescan, addresses + `agentId` recorded here** | **OPEN — blocked on provisioning** |

## What Victor needs to do to close this

1. Fill `DEPLOYER_PRIVATE_KEY`, `PRINCIPAL_PRIVATE_KEY`, `AGENT_PRIVATE_KEY`,
   `BASESCAN_API_KEY` in `.env`. `REGISTRY_ADDRESS` and `USDC_ADDRESS` are already
   there.
2. `cast code "$PRINCIPAL_ADDRESS"` must return `0x` — see finding 1 above.
3. Faucet Sepolia gas ETH for all three addresses, and test USDC
   (`0x036CbD53…CF7e`) for the principal — at least 1,000 for the cap.
4. Run the WISH's Validation block verbatim (WISH.md:316-320), then paste the raw
   output and the two addresses plus the `agentId` into this note.
