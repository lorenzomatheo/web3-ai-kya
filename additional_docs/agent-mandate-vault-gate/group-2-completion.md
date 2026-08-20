# Group 2 — completion note

**Status:** COMPLETE · **Date:** 2026-08-19 · **Branch:** `feat/g2-router` → `wish/agent-mandate-vault-gate`

Gate exited **0**. Command run verbatim from WISH.md group 2 Validation — the
repository full gate, deliberately not narrowed.

```
forge fmt --check   ok
forge build         ok (Solc 0.8.28, no warnings)
forge test          45 passed, 0 failed  (10 group 1 + 35 group 2)
```

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
| 10,000 allowance vs 1,000 cap: loop never pulls more than 1,000 | `LoopUntilRejectionNeverPullsMoreThanCap` — asserts pulled ≤ cap and ≪ allowance |
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

## Correction from PR review: the error surface is eight *for a legitimate caller*

PR review surfaced a ninth reachable error that this note originally missed:
`ReentrancyGuardReentrantCall()`, OpenZeppelin's, declared at
`ReentrancyGuard.sol:42` and reachable on both value paths via `nonReentrant`.

The claim should be stated precisely rather than dropped. **The eight custom
errors are the *product surface* — what a caller acting in good faith can
encounter.** The ninth is a safety net reachable only by a caller who is actively
re-entering, i.e. attacking, and when it fires the defence is working.

Why it is recorded rather than fixed:

- The wish's criterion enumerates four specific OZ errors —
  `ECDSAInvalidSignature*`, `ERC721NonexistentToken`, `ERC4626ExceededMaxDeposit`,
  `ERC20InsufficientAllowance` — and each of those signals a **design failure**
  (forgetting `tryRecover`, forgetting the try/catch, mis-ordering the vault gate,
  forgetting the share approval). This one signals the opposite.
- OZ's `ReentrancyGuard` hardcodes its revert with no customisation hook, so
  emitting our own error means hand-writing a security primitive. DESIGN is
  explicit that `nonReentrant` is "load-bearing here, not belt-and-braces -- do
  not drop it", and replacing it against a two-day deadline is a worse trade than
  an imprecise sentence.
- Adding a ninth *custom* error would contradict DESIGN's own enumeration of eight
  and the demo's eleven-transaction count.

No demo transaction can reach it: the router is bound to one vault at
construction, and reaching the guard requires that vault or its asset to call back
into the router.

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
