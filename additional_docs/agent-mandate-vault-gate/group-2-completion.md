# Group 2 — completion note

**Status:** COMPLETE · **Date:** 2026-08-19 · **Branch:** `feat/g2-router` → `wish/agent-mandate-vault-gate`

Gate exited **0**. Command run verbatim from WISH.md group 2 Validation — the
repository full gate, deliberately not narrowed.

**Re-run on 2026-08-20 after PR #2's re-review**, with raw forge output rather than
the hand-written paraphrase this note previously carried. `forge` 1.7.1, live `.env`.

```
forge fmt --check   ok
forge build         Compiler run successful! (Solc 0.8.28)
```

```
Suite result: ok. 12 passed; 0 failed; 0 skipped; finished in 2.54ms (4.33ms CPU time)
Suite result: ok. 38 passed; 0 failed; 0 skipped; finished in 2.65ms (13.46ms CPU time)

Ran 2 test suites in 5.34ms (5.19ms CPU time): 50 tests passed, 0 failed, 0 skipped (50 total tests)
```

**50 = 12 group 1 + 38 group 2.** Both figures moved since the original note:
group 1 gained the two containment legs PR #1's re-review found unarmed, and group 2
gained the three tests below.

Fork profile re-checked separately and still green (`ProfileGuardTest`, 1 passed),
so group 1's profile exclusion survives the new `src/` contents.

Worktree isolation was **not** required: nobody is concurrently on group 3, and
`feat/g2-router` already provides the isolation the WISH's gate calls for.

## What shipped

- **`src/MandateRouter.sol`** — `struct Mandate`, `MANDATE_TYPEHASH`,
  `EIP712("MandateRouter", "1")`, one shared internal `_verify` for steps 1–6,
  `depositFor` / `redeemFor` / `revoke`, `nonReentrant` on both value paths, seven
  custom errors, three events, and the two `public` mappings.
- **`test/MandateRouter.t.sol`** — 35 tests, **all 35 applying `containment`**
  (verified by grep, not by assumption). Covers DESIGN's Authorization,
  Revocation, Events and "the cap actually binds" sections.

Two small conveniences beyond the deliverable list, both `view`/`pure` and
neither on a value path: `mandateDigest(m)` and `mandateKey(digest, account)`.
They exist so the group 5 demo and any indexer can reproduce the storage key
off-chain without re-implementing the domain separator — the WISH's QA criterion
asks a third party to do exactly that from a `Deposited` log.

## Decision 17 proven load-bearing by mutation

The keying asymmetry is the invariant the plan review says is easiest to get
subtly wrong, so it was checked by **breaking it in both directions** rather than
by reading a green suite.

| Mutation | Result |
|---|---|
| `revoked` **read** moved to `msg.sender` | 3 fail — `PrincipalRevokeBlocksDeposit`, `PrincipalRevokeBlocksRedeem`, `SignerRevokesAfterTransferAndMandateStaysDead`. The kill switch goes inert, exactly as DESIGN predicts, because step 1 has already forced `msg.sender == m.agent`. |
| `revoked` **write** moved to the derived principal | 5 fail — including `AttackerRevokeEmitsRealDigestYetOwnerDepositSucceeds` and `ThirdPartyRevokeDoesNotBlockTheOwner`, both with `MandateRevoked()`. That is the attacker successfully revoking the victim's mandate: the precise vulnerability decision 12 exists to prevent. |

The second mutation also made `revoke` leak `ERC721NonexistentToken`, which
independently confirms the other half of decision 12 — keying on the caller is
what keeps `registry.ownerOf` off the emergency path, so revocation still works
when the registry proxy is bricked or the agent NFT has been burned.

## Acceptance criteria

| Criterion | Evidence |
|---|---|
| Every verification step reverts with our error, never OZ's | `tryRecover` 3-tuple with `err` checked; `ownerOf` in try/catch. `InvalidSignatureIsOurErrorNotOZs`, `MalformedSignatureLengthIsOurError`, `UnmintedAgentIdIsOurErrorOnDeposit`/`OnRedeem` |
| `NotAgent`, `WrongVault`, `MandateExpired`, `AgentNotRegistered` sited on **both** paths | Eight tests, each error asserted exactly twice — the redeem-sited half is what proves `_verify` is genuinely shared |
| Malleable high-`s` rejected | `MalleableHighSSignatureRejected` — `s' = n - s` with `v` flipped; `tryRecover` returns `RecoverError.InvalidSignatureS` |
| Registry returning `address(0)` yields `AgentNotRegistered` | `ZeroOwnerRegistryYieldsAgentNotRegistered` against a second router built on `ZeroOwnerRegistry` |
| `ExceedsMandate` reports `remaining`/`attempted`; whole-cap and remainder cases identical | `ExceedsMandateReportsRemainingAndAttempted` (500, 600), `DepositExceedingWholeCapRevertsIdentically` (1000, 5000) |
| `cap - Deposited.spentTotal` reproduces `remaining` | `SpentTotalReproducesExceedsMandateRemaining` — decodes `spentTotal` from the actual log, then asserts the next revert's `remaining` |
| `revoke` writes at `msg.sender` with no ownership gate | `RevokeHasNoOwnershipGate` — asserts the entry lands at `(digest, caller)` and **not** at `(digest, principal)` |
| Revocation kills deposit **and** redeem | `PrincipalRevokeBlocksDeposit`, `PrincipalRevokeBlocksRedeem` |
| Signer can revoke after transferring the `agentId`; mandate stays dead when it returns | `SignerRevokesAfterTransferAndMandateStaysDead` |
| Attacker with the real mandate emits an identical digest; owner's deposit still succeeds | `AttackerRevokeEmitsRealDigestYetOwnerDepositSucceeds` — the digest is the live one, so the deposit can only survive via the key binding |
| All three events emit an independently computed `_hashTypedDataV4(hashStruct(m))` | The suite builds the domain separator from the literal strings rather than reading it off the contract |
| `Deposited`/`Redeemed` carry the derived `principal` and `agentId` indexed | `DepositedEventCarriesDigestPrincipalAndAgentId`, `RedeemedEventCarriesDigestPrincipalAndAgentId` |
| `Revoked` carries the caller, and echoes `agentId` unvalidated | `RevokedEventCarriesCallerNotDerivedPrincipal`, `RevokedEchoesUnvalidatedAgentId` (uses an unminted id 123456) |
| `transferFrom` pulls from the principal; `redeemFor` passes no other `owner` — asserted directly | `vm.expectCall` on `transferFrom(principal, router, assets)` and `redeem(shares, principal, principal)` — not inferred from where assets landed |
| `agentId` transfer makes a valid mandate revert `InvalidSignature` | `AgentIdTransferInvalidatesExistingMandate` |
| 10,000 allowance vs 1,000 cap: loop never pulls more than 1,000 | `LoopUntilRejectionNeverPullsMoreThanCap` — asserts the terminating revert is `ExceedsMandate` and not another reason, then `succeeded == 3` and `pulled == 900e6`. **Exact figures, not bounds:** `assertLe(pulled, CAP)` alone is satisfied by `pulled == 0`, which is how the original version passed vacuously |
| `ExceedsMandate` survives an unbounded `assets` | `ExceedsMandateSurvivesUnboundedAssets` — `type(uint256).max` against a partly-spent mandate returns the error, not `Panic(0x11)` |
| `nonReentrant` is load-bearing on both value paths | `ReentrantVaultOnDepositTripsTheGuard`, `…OnRedeemTripsTheGuard` — a hostile vault re-enters through `deposit`/`redeem`; both verified by deleting the modifier |
| No decimals conversion | `RouterPerformsNoDecimalsConversion` — `cap`/`assets` 6dp end to end, `shares` passed through untouched |
| Router holds zero of both after every call | The `containment` modifier, on all 35 tests, plus an explicit round-trip assertion |

## Deviations

1. **Constructor code checks.** The constructor `require`s that `registry` and
   `vault` have code. DESIGN wants this verified at deploy and group 5's script
   does too, but in the constructor it is unconditional. Uses plain `require`
   strings, **not** custom errors, so the product's error surface stays exactly
   eight. It is also the only place the check can live: a codeless registry
   reverts on `extcodesize` inside our own frame, which `_verify`'s try/catch
   cannot catch. Covered by `ConstructorRejectsCodelessAddresses`.
2. **`ExpiryIsInclusive`** — an extra test pinning step 3 as `<=` rather than
   `<`. DESIGN writes `block.timestamp <= m.expiry`; nothing asserted the
   boundary.
3. A `forge-lint` suppression on the `block.timestamp` comparison, with the
   reason inline: validator drift is seconds against expiries measured in hours
   or days, and decision 14 wants expiry to mean "authority ended", not a precise
   instant.

## The error surface, enumerated rather than characterised

Two rounds of PR review corrected this section. The original note claimed a flat
"exactly eight custom errors". The first correction narrowed that to "eight for a
legitimate caller", which the re-review showed is still wrong as written: a
good-faith caller passing unlucky arguments can reach several non-custom reverts.

The **decision** stands — no ninth custom error — but the claim now enumerates every
reachable non-custom revert on the value paths instead of naming only the one the
first review happened to find.

| Reachable revert | Where from | Status |
|---|---|---|
| `ReentrancyGuardReentrantCall()` | OZ `ReentrancyGuard.sol:42`, via `nonReentrant` on both value paths | Reachable only by a caller actively re-entering. When it fires, the defence worked. **Now tested** — see below |
| `ERC4626ExceededMaxRedeem` | OZ 5.x `redeem` checks `maxRedeem(owner)` **before** `_spendAllowance`, so an agent redeeming more shares than the principal holds gets OZ's error, not ours | Good-faith reachable. Accepted: the cap is a deposit-side instrument (decision 3), and the exit side has no quantity bound of ours to report |
| `ERC20InsufficientAllowance` | The share leg, if the principal has not approved the router on the vault token | Good-faith reachable. DESIGN risk 3 already names it |
| `ERC20InsufficientBalance` | The asset leg, if the principal's USDC balance is short of a within-cap `assets` | Good-faith reachable. The cap bounds authority, not solvency |
| `Panic(0x11)` (`0x4e487b71`) | `depositFor`'s step-7 cap check | **Was** good-faith reachable. **Fixed** — see below |

Two `require` strings in the constructor are also outside the eight, deliberately, and
were already recorded under Deviations.

### Fixed: `Panic(0x11)` reached the caller instead of `ExceedsMandate`

`assets` is agent-supplied and unbounded. Written as

```solidity
if (alreadySpent + assets > m.cap) {
```

the addition overflows under 0.8 checked arithmetic **inside the check itself**, so a
caller holding a valid mandate got `0x4e487b71` rather than
`ExceedsMandate(remaining, attempted)`. An integrator doing "deposit max" is the
obvious trigger, and it lands directly against the design's claim that the revert
reason is the product — a merchant debugging a raw panic selector learns nothing.

Now written with the subtraction on the left:

```solidity
uint256 remaining = m.cap - alreadySpent;
if (assets > remaining) {
    revert ExceedsMandate(remaining, assets);
}
```

Exactly equivalent, and the subtraction cannot underflow: `spent[key]` is only ever
written as a value this same check has already bounded by `m.cap`, and `m.cap` is
fixed for a given `key` because the key is the EIP-712 digest, which commits to `cap`.

Covered by `test_ExceedsMandateSurvivesUnboundedAssets`. **The prior deposit in that
test is load-bearing, not scene-setting.** With `alreadySpent == 0` there is nothing
to overflow — `0 + max` fits — and the buggy form returns `ExceedsMandate` too, so a
test that skipped straight to `type(uint256).max` would have passed against the
defect. Verified by mutation: restoring the addition form gives

```
[FAIL: Error != expected error: panic: arithmetic underflow or overflow (0x11)
 != ExceedsMandate(700000000, 115792089237316195423570985008687907853269984665640564039457584007913129639935)]
```

### Fixed: the reentrancy guard had no test at all

The first review's error-surface argument was accepted and is actually stronger than
stated: `registry.ownerOf` is called from `_verify`, which is `internal view`, and
`IERC721.ownerOf` is itself `view` — so it compiles to **STATICCALL**. A malicious
registry re-entering trips the guard inside its own frame, where the revert is caught
by `_verify`'s try/catch and converted to `AgentNotRegistered`. The registry vector is
closed by STATICCALL, not by the guard. That leaves the vault and its asset, both
immutable from construction.

But that argument was about the **error surface**, and it left the second half of the
finding open: there was no reentrancy test, and deleting both `nonReentrant` modifiers
left the suite 100% green. DESIGN risk 6 says the guard is "load-bearing here, not
belt-and-braces — do not drop it"; decisions 17 and 6 were proven load-bearing by
mutation and this one was not.

`test/doubles/ReenteringVault.sol` is a hostile vault implementing exactly the three
functions the router calls — `asset()` (needed at construction), `deposit`, `redeem` —
each of which calls straight back into a router scoped to it.

**One detail decides whether the test proves anything.** The re-entrant mandate names
the hostile vault *itself* as `agent`. Re-entering under the outer mandate would be
turned away at step 1 by `msg.sender != m.agent`, so the test would go green on step 1
and **stay green with `nonReentrant` deleted**. Naming the vault as the agent clears
step 1 and every later step, leaving the guard as the only thing in the way.

Verified by deleting each modifier independently:

| Mutation | Result |
|---|---|
| `nonReentrant` off `depositFor` | `[FAIL: … ExceedsMandate(0, 100000000) != ReentrancyGuardReentrantCall()]` — the inner frame verified cleanly and consumed **the entire cap**, so the outer frame died with zero headroom. Budget spent twice in one transaction |
| `nonReentrant` off `redeemFor` | `[FAIL: call reverted as expected, but without data]` at 4.5M gas — unbounded recursion to out-of-gas |
| Both present | Both tests pass |

The deposit result is the concrete answer to "is the guard belt-and-braces here": it
is not. Without it the cap stops binding per transaction.

No demo transaction can reach any of this: the router is bound to one vault at
construction, and reaching the guard requires that vault or its asset to call back in.

## Handover

**Group 3 (`AllowlistedERC4626`) is UNCLAIMED.** Flagging it explicitly so it is
not silently dropped — it is the last wave-2 item, groups 4 and 5 both depend on
it, and the Aug 22 deadline is three days out. Its Morpho escape hatch already
fired on 2026-08-18, so it ships the simpler idle-USDC variant by the WISH's own
default rule.

Notes for whoever takes it:

- The eighth error, `NotAllowlisted(receiver)`, belongs to the vault. The router
  ships seven and does not know about the allowlist.
- The gate must revert **before** delegating to the inherited implementation. OZ
  5.x `ERC4626.deposit` checks `maxDeposit` first, so expressing the allowlist by
  returning 0 from `maxDeposit` makes `NotAllowlisted` unreachable and silently
  kills demo transaction 11.
- Its test contract must be named `AllowlistedERC4626Test` — group 3's validation
  selects on it with `--match-contract`, and `forge test` exits 0 on a zero-match
  run, so a renamed contract turns the whole gate green while running nothing.

Group 4 can also start: `MandateRouter` is stable, and group 4's
`OwnershipIsolation.t.sol` half is local and needs no RPC.
