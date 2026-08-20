# Group 4 — completion note

**Status:** COMPLETE · **Date:** 2026-08-20 · **Branch:** `feat/g4-fork-suite` → `wish/agent-mandate-vault-gate`

Gate exited **0**. Command run verbatim from WISH.md group 4 Validation.

```
forge fmt --check                                       ok
FOUNDRY_PROFILE=fork forge test --match-path test/fork/**   4 passed
  grep 'Ran [1-9]+ tests for .../MandateRouterFork.t.sol'   matched
forge test (full local suite)                          62 passed
```

Both guards in that command did real work and neither is decoration:
`set -o pipefail`, because `tee` would otherwise supply the pipeline's exit
status and a failing fork suite would report green; and the grep naming
`MandateRouterFork.t.sol` specifically, because `ProfileGuard` also lives under
`test/fork/` and a bare count would be satisfied by the guard alone while the
mwUSDC suite was renamed, misplaced, or never selected.

Local total 62 = 10 doubles + 35 router + 13 vault + **4 ownership isolation**.

## Branch shape

Group 4 `depends-on: 2, 3`, which are on two unmerged branches, so
`feat/g4-fork-suite` was cut from `wish/agent-mandate-vault-gate` and both
siblings merged **into it** — not into `wish/`. Pushing `wish/` with those
commits would have made GitHub auto-close PRs #2 and #3 without review. PR #4's
diff therefore shows groups 2+3 until those land, then collapses to group 4 alone.

## Three numbers the docs delegated, now measured

Neither DESIGN nor the WISH names a fork block, a funding mechanism, or a
tolerance figure — all three say "pinned"/"stated" and leave the value to the
implementer.

| Item | Value | Basis |
|---|---|---|
| Fork block | **50000000** (already in `[profile.fork]` from group 1) | Verified healthy at that block: `mwUSDC` totalAssets ≈ 9.91M USDC, totalSupply 9.13e24 shares, rate 1.0847 assets/share |
| Round-trip tolerance | **10 wei of USDC** (asset units, 6dp) | Measured loss is **exactly 1 wei**, identical at 100 / 1,000 / 10,000 USDC — two truncating rounding layers. 10 gives an order of magnitude of headroom; DESIGN warns a one-wei bound would be flaky. **No share-side epsilon** — mwUSDC shares are 18dp |
| Fork USDC funding | `deal`, with a live-whale fallback | Base USDC is the older zeppelinos `FiatTokenProxy` (EIP-1967 impl slot empty; impl at `0x2ce6311d…`), an awkward `stdstore` target. Fallback pranks **Morpho Blue** `0xBBBB…FFCb`, holding ~252.3M USDC at the pinned block |

The test asserts the tolerance **and logs the actual gap**
(`round-trip loss (USDC wei): 1`), so a future regression that widens it becomes
visible rather than silently absorbed inside the bound.

## Decision 17's cross-owner half proven by mutation

This is the half group 2 could not reach. Checked by re-keying both mappings on
the digest alone — the exact counterfactual DESIGN describes — and confirming the
predicted failures appear:

| Test | Failure under hash-only keying |
|---|---|
| `test_OwnerASpendingDoesNotChargeOwnerB` | **`ExceedsMandate(200000000, 1000000000)`** — DESIGN's prediction verbatim: "under a hash-only key this reverts `ExceedsMandate(remaining: 200, …)`, charging B for A's spending" |
| `test_OwnerARevocationDoesNotBlacklistOwnerB` | **`MandateRevoked()`** — A's revocation blacklisting B's byte-identical struct, which it must not |

The first test's assertions were deliberately **reordered** during
implementation. Originally an intermediate `spent` bookkeeping check ran between
A's deposit and B's, and under the mutation that check tripped first — so the
test caught the bug, but for a weaker reason than the one DESIGN names. Moving
the bookkeeping after B's deposit makes **the deposit itself** the assertion, so
the mutation now surfaces as the predicted `ExceedsMandate` revert. Worth
recording: a test that fails for the wrong reason is only accidentally a test.

Neither isolation test calls `vm.warp` — a byte-identical struct fixes the
expiry, so warping between A's activity and B's would fail them for an unrelated
reason.

## Containment audit — deliverable 3

An audit, not a new test. No backfilling was needed: every in-scope file already
assigned all three mandatory slots, and `containedRouter` in exactly the files
that deploy a router.

| File | Tests | All carry `containment` | `agent` / `containedAsset` / `containedShare` | `containedRouter` |
|---|---|---|---|---|
| `test/MandateRouter.t.sol` | 35 | 35/35 | assigned | assigned (deploys one) |
| `test/AllowlistedERC4626.t.sol` | 13 | 13/13 | assigned | **unset — correct**, deploys no router |
| `test/OwnershipIsolation.t.sol` | 4 | 4/4 | assigned | assigned (deploys one) |
| `test/fork/MandateRouterFork.t.sol` | 3 | 3/3 | assigned | assigned (deploys one) |

Out of scope by the WISH's own carve-outs: `test/doubles/Doubles.t.sol`, whose
fixtures leak the asset **on purpose** inside a reverting sub-call to prove the
assertion fires; and `test/fork/ProfileGuard.t.sol`, which deploys nothing.

`containedRouter` is the one slot checked **by inspection** rather than by a
negative test, precisely because it is skip-on-unset by design and therefore the
only slot that cannot fail loudly — a file that applies the modifier but forgets
it would pass the router half of the invariant while checking nobody.

## Acceptance criteria

| Criterion | Evidence |
|---|---|
| Router deposits into `mwUSDC` on the fork, shares credited to the principal | `test_RouterDepositsIntoRealMwUSDC` — shares match the vault's own `previewDeposit`, router holds zero of both |
| Round trip within an explicit stated tolerance | `test_RoundTripReturnsAssetsWithinTolerance` — 10 wei bound, 1 wei actual, logged |
| A spends 800 of 1,000; `agentId` → B; B's byte-identical mandate deposits 1,000: accepted | `test_OwnerASpendingDoesNotChargeOwnerB` |
| A revokes; `agentId` → B; B's byte-identical struct accepted | `test_OwnerARevocationDoesNotBlacklistOwnerB` |
| Agent and router hold zero across **every** router- or vault-deploying test | The audit table above; 55 in-scope tests, all applying an armed modifier |
| Prior owner still redeems directly after transfer | `test_PriorOwnerStillRedeemsDirectlyAfterTransfer` |
| Risk-12 test passes | `test_Risk12_MandateReachesSharesItDidNotCreate` — principal deposits directly, agent redeems under a same-principal different-`nonce` mandate through which nothing was routed. **Written to pass**, so a later `sharesMinted` bound has a test to invert rather than a paragraph to reinterpret |

## What remains: group 5 only

Wave 3's code half is done. Group 5 is the last item, and **Aug 22 is two days
out**.

Its blocker is provisioning, not code — `.env` still has
`DEPLOYER_PRIVATE_KEY`, `PRINCIPAL_PRIVATE_KEY`, `AGENT_PRIVATE_KEY` and
`BASESCAN_API_KEY` all empty. None of it costs money; all of it costs wall-clock,
and faucets rate-limit:

- **Gas ETH** on Base Sepolia for ~20 transactions (two deployments, a registry
  `register()`, approvals, and the eleven demo transactions).
- **Test USDC** (`0x036CbD53…CF7e`) for demo transaction 1's 500-USDC deposit.
- **`BASESCAN_API_KEY`** — not funding at all, but `--verify` reads it through
  the `[etherscan]` table, and "deployed **and verified**" is one of the wish's
  eight top-level criteria.

Two constraints that are correctness, not funding. The three keys must be
**distinct**: `revoke` writes at `msg.sender`, so a revoke from the agent's key
would leave demo transaction 10 quietly succeeding and the demo asserting
nothing. And the **agent key must never hold USDC** — gas only. That is the
containment invariant this group just proved suite-wide.

Also carried forward from the WISH: group 5's final gate-and-broadcast run must
execute on a tree that already contains this group's containment audit, since
group 4 has now landed. Do not race them on the shared branch.
