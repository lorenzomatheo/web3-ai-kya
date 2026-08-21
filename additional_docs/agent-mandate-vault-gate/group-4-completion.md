# Group 4 — completion note

**Status:** COMPLETE · **Date:** 2026-08-20 · **Branch:** `feat/g4-fork-suite` → `wish/agent-mandate-vault-gate`

Gate exited **0**. Command run verbatim from WISH.md group 4 Validation.

**Re-run on 2026-08-20 after PR #4's re-review**, with raw forge output rather than
the hand-written paraphrase this note previously carried. `forge` 1.7.1, live
`BASE_RPC_URL`, so the fork leg genuinely executed against pinned Base block
50,000,000.

```
Ran 1 test for test/fork/ProfileGuard.t.sol:ProfileGuardTest
[PASS] test_RunsOnlyUnderForkProfile() (gas: 4459)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 6.88ms (1.79ms CPU time)

Ran 3 tests for test/fork/MandateRouterFork.t.sol:MandateRouterForkTest
[PASS] test_RoundTripReturnsAssetsWithinTolerance() (gas: 531018)
Logs:
  round-trip loss (USDC wei): 1

[PASS] test_RoundTripStillConsumesBudgetOnRealVault() (gas: 524411)
[PASS] test_RouterDepositsIntoRealMwUSDC() (gas: 474341)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 12.26ms (10.55ms CPU time)

Ran 2 test suites in 204.62ms (19.14ms CPU time): 4 tests passed, 0 failed, 0 skipped (4 total tests)
```

The suite-named grep matched `Ran 3 tests for test/fork/MandateRouterFork.t.sol:`.
Then the full local suite:

```
Ran 14 tests for test/AllowlistedERC4626.t.sol:AllowlistedERC4626Test
Suite result: ok. 14 passed; 0 failed; 0 skipped; finished in 3.63ms (1.00ms CPU time)
Ran 4 tests for test/OwnershipIsolation.t.sol:OwnershipIsolationTest
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 3.63ms (5.78ms CPU time)
Ran 38 tests for test/MandateRouter.t.sol:MandateRouterTest
Suite result: ok. 38 passed; 0 failed; 0 skipped; finished in 4.03ms (14.50ms CPU time)
Ran 12 tests for test/doubles/Doubles.t.sol:DoublesTest
Suite result: ok. 12 passed; 0 failed; 0 skipped; finished in 4.04ms (6.68ms CPU time)

Ran 4 test suites in 6.40ms (15.33ms CPU time): 68 tests passed, 0 failed, 0 skipped (68 total tests)
```

Both guards in that command did real work and neither is decoration:
`set -o pipefail`, because `tee` would otherwise supply the pipeline's exit
status and a failing fork suite would report green; and the grep naming
`MandateRouterFork.t.sol` specifically, because `ProfileGuard` also lives under
`test/fork/` and a bare count would be satisfied by the guard alone while the
mwUSDC suite was renamed, misplaced, or never selected.

Local total **68 = 12 doubles + 38 router + 14 vault + 4 ownership isolation**.

**Correction from PR #4's re-review.** This note said 62, and 13 in the audit table
below. Both were stale: `1466833` added a 14th vault test without the note being
refreshed. Three further figures moved after that review — the router gained a
`Panic(0x11)` regression test and two reentrancy tests, and the doubles gained the two
containment legs that were unarmed. Every figure above is now read off the run
rather than recomputed.

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
| `test/MandateRouter.t.sol` | 38 | 38/38 | assigned | assigned (deploys one) |
| `test/AllowlistedERC4626.t.sol` | 14 | 14/14 | assigned | **unset — correct**, deploys no router |
| `test/OwnershipIsolation.t.sol` | 4 | 4/4 | assigned | assigned (deploys one) |
| `test/fork/MandateRouterFork.t.sol` | 3 | 3/3 | assigned | assigned (deploys one) |

Out of scope by the WISH's own carve-outs: `test/doubles/Doubles.t.sol`, whose
fixtures leak the asset **on purpose** inside a reverting sub-call to prove the
assertion fires; and `test/fork/ProfileGuard.t.sol`, which deploys nothing.

`containedRouter` is the one slot checked **by inspection** rather than by a
negative test, precisely because it is skip-on-unset by design and therefore the
only slot that cannot fail loudly — a file that applies the modifier but forgets
it would pass the router half of the invariant while checking nobody.

### Correction from PR #4's re-review: this audit certified "armed" and could not

The application count above was right. **"Armed" was not.** `BaseTest.sol:45-51`
asserts 2 holders × 2 tokens, and `ContainmentHarness` exposed only the diagonal —
`leakAssetToAgent` and `leakShareToRouter`. Deleting `BaseTest.sol:49`, the
router-holds-no-USDC assertion and the non-custody invariant itself, left the entire
suite green.

**The audit's method is what missed it.** Counting applications of the modifier
measures reach, not strength; it cannot distinguish a modifier asserting four things
from one asserting two, because both are applied identically at every call site. The
gap only surfaces by reading `BaseTest.sol` against the negative tests in
`test/doubles/Doubles.t.sol` — the one file this audit scopes out.

Fixed in group 1, since that is where both files live: `ContainmentHarness` gains
`leakAssetToRouter` and `leakShareToAgent`, and removing any one of `BaseTest.sol:45`,
`:46`, `:49`, `:50` now turns exactly one test red. The property was never
unprotected in practice — `test_DepositSucceedsAndCreditsPrincipal`,
`test_RouterAndAgentHoldNothingAfterRoundTrip` and both fork tests assert it directly
— but that is precisely the "proven rather than illustrated" distinction the wish was
written to eliminate.

**Method note for any future audit of this kind:** an invariant fixture must be
audited by mutating the fixture, not by counting its call sites.

## Acceptance criteria

| Criterion | Evidence |
|---|---|
| Router deposits into `mwUSDC` on the fork, shares credited to the principal | `test_RouterDepositsIntoRealMwUSDC` — shares match the vault's own `previewDeposit`, router holds zero of both |
| Round trip within an explicit stated tolerance | `test_RoundTripReturnsAssetsWithinTolerance` — 10 wei bound, 1 wei actual, logged |
| A spends 800 of 1,000; `agentId` → B; B's byte-identical mandate deposits 1,000: accepted | `test_OwnerASpendingDoesNotChargeOwnerB` |
| A revokes; `agentId` → B; B's byte-identical struct accepted | `test_OwnerARevocationDoesNotBlacklistOwnerB` |
| Agent and router hold zero across **every** router- or vault-deploying test | The audit table above; **59** in-scope tests, all applying the modifier — and the modifier is now armed on all four of its legs (see below) |
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
  **The `register()` must be broadcast under `PRINCIPAL_PRIVATE_KEY`, not the
  deployer's** — or registered by the deployer and transferred to the principal in
  the same script. `register()` mints to `msg.sender`, so a deployer-only broadcast
  makes `ownerOf(agentId)` the deployer and every principal-signed mandate then dies
  at step 5 with `InvalidSignature`. Do not read this list as a to-do without that
  attribution; the full constraint, including the closing `require`, is in
  [`group-5-constraints.md`](group-5-constraints.md).
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
