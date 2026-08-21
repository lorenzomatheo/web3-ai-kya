# Group 3 — completion note

**Status:** COMPLETE · **Date:** 2026-08-19 · **Branch:** `feat/g3-vault` → `wish/agent-mandate-vault-gate`

Gate exited **0**. Command run verbatim from WISH.md group 3 Validation.

**Re-run on 2026-08-20 after PR #3's re-review**, with raw forge output rather than
the hand-written paraphrase this note previously carried — and with the count
corrected. `forge fmt --check` ok; then:

```
Ran 14 tests for test/AllowlistedERC4626.t.sol:AllowlistedERC4626Test
[PASS] test_AssetIsSixDecimalsAndSharesMatch() (gas: 32761)
[PASS] test_DeAllowlistedHolderCanStillRedeem() (gas: 127478)
[PASS] test_DeAllowlistingClosesTheGate() (gas: 40984)
[PASS] test_DepositToAgentRevertsNotAllowlisted() (gas: 33612)
[PASS] test_DepositToPrincipalFromOutsiderSucceeds() (gas: 128504)
[PASS] test_GateKeysOnReceiverNotCaller() (gas: 93543)
[PASS] test_MaxDepositAndMaxMintOpenForAllowlistedReceiver() (gas: 39838)
[PASS] test_MintIsGatedIdenticallyAndRevertIsOurs() (gas: 35486)
[PASS] test_MintToAllowlistedReceiverSucceeds() (gas: 120808)
[PASS] test_RenounceOwnershipIsDisabledEvenForTheOwner() (gas: 61092)
[PASS] test_RevertIsOursEvenThoughMaxDepositReturnsZero() (gas: 35533)
[PASS] test_SetAllowlistedEmitsAndOpensTheGate() (gas: 151322)
[PASS] test_SetAllowlistedIsOwnerOnly() (gas: 32591)
[PASS] test_VaultHoldsAssetsIdle() (gas: 124418)
Suite result: ok. 14 passed; 0 failed; 0 skipped; finished in 9.45ms (20.53ms CPU time)

Ran 1 test suite in 16.67ms (9.45ms CPU time): 14 tests passed, 0 failed, 0 skipped (14 total tests)
```

The reported count is **14, not zero** — checked explicitly, because
`forge test` exits 0 on a zero-match run and the contract name is what
`--match-contract` selects on. A rename would have turned this gate green while
running nothing.

**Correction from PR #3's re-review.** This note said 13 in four places. `1466833`
added `test_RenounceOwnershipIsDisabledEvenForTheOwner` and the note was not
refreshed, so every figure here disagreed with a static count of the tree it
describes. The count above is the run, not arithmetic.

Full suite on this branch also green:

```
Suite result: ok. 14 passed; 0 failed; 0 skipped; finished in 1.37ms (2.14ms CPU time)
Suite result: ok. 12 passed; 0 failed; 0 skipped; finished in 1.60ms (4.46ms CPU time)
Ran 2 test suites in 6.08ms (2.97ms CPU time): 26 tests passed, 0 failed, 0 skipped (26 total tests)
```

**26 = 12 group 1 + 14 group 3.** Group 1's figure moved too: PR #1's re-review found
the `containment` modifier armed on 2 of its 4 legs, and the two tests that close that
gap land in `test/doubles/Doubles.t.sol`.

Branched off `wish/agent-mandate-vault-gate`, not off group 2 — group 3
`depends-on: 1` only. `src/` contained nothing at branch time, so the isolation
the WISH's gate calls for is structural here rather than a promise.

## Branch recorded: the escape hatch was TAKEN

**Idle USDC. Morpho not integrated.**

The trigger was "evaluated by end of 2026-08-18". That date passed unevaluated,
and the WISH's rule is explicit — an unevaluated trigger means the hatch is
**taken by default, not failed**: "the clock exists to force the safe branch, not
to fail the group." Morpho exposure stays confined to group 4's mainnet fork
suite, where `mwUSDC` is already verified live (`MORPHO()` returns Blue,
~$7.75M TVL).

Consequences, all of them subtractive:

- **No `sepolia-fork` profile**, no sentinel `no_match_path` override for it, and
  group 1 deliverable 1's exclusion glob stays `test/fork/**` — it does **not**
  widen to `test/{fork,sepolia-fork}/**`.
- **No `test/sepolia-fork/MorphoSupplyWithdraw.t.sol`** — the conditional entry
  in the WISH's file manifest is not created.
- **No hand-written supply/withdraw accounting**, which was the whole reason the
  hatch exists.
- The group's validation command is used **as-is**; the extra Morpho leg with its
  `set -o pipefail` and suite-named grep is not appended.

Holding idle turned out to require **no code at all**: OZ 5.0.2's
`ERC4626.totalAssets()` already returns `_asset.balanceOf(address(this))`.
`test_VaultHoldsAssetsIdle` pins it so the property is asserted rather than
inherited silently.

## Judgment call: the admin surface

The WISH asks for "the minimal admin surface that puts an address on the
allowlist in the first place" and **nothing anywhere pins its shape** — DESIGN
names no function, role, or `Ownable` for this contract. Its "no owner", "no
admin surface" and "no pause" lines are all explicitly about the **router**
(decision 11, and the Simplicity Case's "a contract that holds user allowances").

**Chosen: `Ownable`, owner set in the constructor, `setAllowlisted(address
account, bool allowed)`, emitting `AllowlistUpdated`.**

Rationale: the contract exists to stand in for an operator's KYC'd vault, so an
unpermissioned allowlist would make the gate — and demo transaction 11 — prove
nothing. Both downstream consumers are satisfied: group 4 allowlists owner B in a
local test, group 5's deploy script allowlists the principal before transaction 1.
Raising it here rather than treating it as transcribed spec.

De-allowlisting is supported and gates **entry only** — an existing holder can
still redeem (`test_DeAllowlistedHolderCanStillRedeem`). Confiscation was never
asked for and would contradict the non-custody framing.

## Decision 6's ordering proven load-bearing by mutation

Decision 6 predicts a specific silent failure: expressing the allowlist *through*
`maxDeposit` — the spec-compliant way — makes `NotAllowlisted` unreachable and
"silently kills the demo's closing transaction". So it was checked by causing it.

| Mutation | Result |
|---|---|
| Drop the explicit check; let `maxDeposit`-returning-0 be the mechanism | **5 fail**, and the failure text is decision 6's prediction verbatim: `ERC4626ExceededMaxDeposit(0x5fA5…, 500000000, 0) != NotAllowlisted(0x5fA5…)`. Demo transaction 11 would have printed an OZ error. |
| Gate on `msg.sender` instead of `receiver` | **7 fail**, including the positive cases — the gate would key on who submits rather than who holds. |

`maxDeposit` / `maxMint` **do** return 0 for a non-allowlisted receiver, for
ERC-4626 conformance, so an integrator reading the limit sees the gate. They are
just never the mechanism producing the revert reason — which is exactly the
combination the WISH's criterion asks be tested, and mutation 1 is what proves
the pairing rather than only the outcome.

## Acceptance criteria

| Criterion | Evidence |
|---|---|
| `deposit(assets, agent)` from any caller reverts `NotAllowlisted(agent)` | `test_DepositToAgentRevertsNotAllowlisted` (called by the funded `outsider`) |
| `deposit(assets, principal)` from a funded neutral `outsider` succeeds | `test_DepositToPrincipalFromOutsiderSucceeds`. **Not** called from the `agent` slot — OZ's `_deposit` pulls via `safeTransferFrom(asset, caller, …)`, so an agent-called success would require dealing the agent USDC, which containment asserts never happens. The WISH marks this a deliberate deviation from DESIGN's Vault-mechanics wording; not re-litigated |
| Together they prove the gate keys on `receiver`, not `caller` | Plus `test_GateKeysOnReceiverNotCaller`: an allowlisted **caller** is still refused an unallowlisted receiver |
| The revert is ours, not `ERC4626ExceededMaxDeposit`, with `maxDeposit` also returning 0 | `test_RevertIsOursEvenThoughMaxDepositReturnsZero` asserts the selector both is ours and is not OZ's; `test_MintIsGatedIdenticallyAndRevertIsOurs` for the `mint` side |
| `asset()` is 6-decimal and `decimals()` returns 6 | `test_AssetIsSixDecimalsAndSharesMatch` — offset 0, so shares are 6dp here, unlike `mwUSDC`'s 18 |
| Escape hatch evaluated | Taken, recorded above |

All 14 tests apply the `containment` modifier (verified by grep).
`containedRouter` is left unset — the fixture's one legitimate skip-on-unset
case, since group 3 deploys no router.

## Wave 2 is complete — wave 3 is fully unblocked

Both remaining groups can now start, and **Aug 22 is three days out**.

- **Group 4** — `test/fork/MandateRouterFork.t.sol` against pinned `mwUSDC`, plus
  the local `test/OwnershipIsolation.t.sol` and the suite-wide containment audit.
  If the schedule slips, the WISH says the trimmable subset is the **mainnet-fork
  half only**; the ownership-isolation, containment and risk-12 tests are local,
  cost no RPC, and must not be trimmed — they carry the only proof of decision
  17's cross-owner half, which group 2's single-owner tests cannot reach.
- **Group 5** — deploy to Base Sepolia and the eleven-transaction demo. Needs
  funded `DEPLOYER_/PRINCIPAL_/AGENT_PRIVATE_KEY` and a `BASESCAN_API_KEY` in
  `.env`, none of which are set yet. That provisioning is the long pole, not the
  code.

Note for group 4: it will need to allowlist owner B via `setAllowlisted`, and for
group 5: the deploy script allowlists the principal the same way.
