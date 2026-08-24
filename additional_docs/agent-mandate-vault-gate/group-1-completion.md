# Group 1 — completion note

**Status:** COMPLETE · **Date:** 2026-08-18 · **Branch:** `feat/g1-toolchain` → `wish/agent-mandate-vault-gate`

Gate exited **0**. Command run verbatim from WISH.md group 1 Validation.

**Re-run on 2026-08-20 after PR #1's re-review**, with raw forge output rather than
the hand-written paraphrase this note previously carried. `forge` 1.7.1, live `.env`.

```
Ran 12 tests for test/doubles/Doubles.t.sol:DoublesTest
[PASS] test_AgentIdMintsAndTransfers() (gas: 71938)
[PASS] test_ContainmentCatchesAssetLeakToAgent() (gas: 1563437)
[PASS] test_ContainmentCatchesAssetLeakToRouter() (gas: 1571095)
[PASS] test_ContainmentCatchesShareLeakToAgent() (gas: 1567328)
[PASS] test_ContainmentCatchesShareLeakToRouter() (gas: 1574928)
[PASS] test_ContainmentPassesWhenNothingLeaks() (gas: 1550655)
[PASS] test_ContainmentRejectsUnsetAgent() (gas: 1388067)
[PASS] test_MockUSDCIsSixDecimalsAndMintable() (gas: 59409)
[PASS] test_MockVaultIsInstantiableAndUsable() (gas: 132465)
[PASS] test_OpenZeppelinIsFiveX() (gas: 4678)
[PASS] test_RegistryRevertsForUnmintedId() (gas: 10985)
[PASS] test_ZeroOwnerRegistryReturnsZeroForUnmintedId() (gas: 10611)
Suite result: ok. 12 passed; 0 failed; 0 skipped; finished in 1.75ms (2.30ms CPU time)

Ran 1 test suite in 5.30ms (1.75ms CPU time): 12 tests passed, 0 failed, 0 skipped (12 total tests)
```

Zero tests from `test/fork/` in that run — the default-profile exclusion working.
The remaining legs of the chain, each of which exits 0 or the chain stops:

```
pnpm install --frozen-lockfile   Lockfile is up to date, resolution step is skipped
forge fmt --check                ok
forge build                      Compiler run successful! (Solc 0.8.28)
git check-ignore -q .env         ok  (.env untracked)
git ls-files .env.example        .env.example
```

```
Ran 1 test for test/fork/ProfileGuard.t.sol:ProfileGuardTest
[PASS] test_RunsOnlyUnderForkProfile() (gas: 4459)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 3.97ms (1.13ms CPU time)

Ran 1 test suite in 206.05ms (3.97ms CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
```

The suite-named grep matched `Ran 1 test for test/fork/ProfileGuard.t.sol:`.

## Branches recorded (the WISH asks for these explicitly)

### 1. Which `no_match_path` form was used — deliverable 1

**The project-relative glob `test/fork/**`**, under `[profile.default]`, on
Foundry **1.7.1**. The absolute-path contingency (`**/test/fork/**`) was not
needed, and `skip` was **not** used — `no_match_path` filters test *selection*
and leaves the files compiling, which is what matches the runtime-versus-
compile-time rationale (a fork test fails in `setUp()`, not at compile time).

`[profile.fork]` carries the sentinel override `no_match_path =
"test/__never__/**"`.

Falsifiable in both directions, and checked in both:

| Direction | Result |
|---|---|
| Default profile reaches `test/fork/` | **Fails** — `assertion failed: default != fork` (forced via `FOUNDRY_NO_MATCH_PATH`) |
| Fork profile selects nothing | Caught by the suite-named grep asserting a non-zero count |

### 2. Sepolia registration prerequisite — acceptance criterion 7

**The real-registry branch.** The ERC-8004 registry at
`0x8004A818BFB912233c491871b3d84c89A494BD9e` is live on Base Sepolia and
**registration is permissionless** — `register()` and `register(string)` both
simulate green from a real EOA and return the next id (`8991`). The
`address(0)` call reverts `ERC721InvalidReceiver`, i.e. on the receiver, not on
a permission gate.

`MinimalIdentityRegistry` therefore stays **test-only** and is not deployed to
Base Sepolia. DESIGN decision 7 keeps the registry a constructor parameter, so
the fallback remains available if this changes. Full evidence and reproducible
commands in [findings-external-deps.md](findings-external-deps.md).

This closes the plan review's one carried risk.

## Acceptance criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | `forge build` exits 0 | Solc 0.8.28, compiler run successful |
| 2 | OpenZeppelin resolves to 5.x, asserted by a genuine discriminator | `test_OpenZeppelinIsFiveX` — 3-component `ECDSA.tryRecover` destructure (does not compile against 4.x) plus `ERC4626.ERC4626ExceededMaxDeposit.selector` reached through the contract |
| 3 | Registry reverts `ERC721NonexistentToken`; `ZeroOwnerRegistry` returns `address(0)` | `test_RegistryRevertsForUnmintedId`, `test_ZeroOwnerRegistryReturnsZeroForUnmintedId` |
| 4 | `agentId` mints to A, transfers to B, `ownerOf` reflects B | `test_AgentIdMintsAndTransfers` |
| 5 | `MockUSDC.decimals() == 6`, mintable; `MockVault` instantiable | `test_MockUSDCIsSixDecimalsAndMintable`, `test_MockVaultIsInstantiableAndUsable` |
| 6 | `BaseTest` compiles with zero `src/` imports; `containment` proven wired by five permanent negative tests, one per assertion in the modifier plus the mandatory-slot guard | `test_ContainmentCatchesAssetLeakToAgent` (a), `…ShareLeakToRouter` (b), `…AssetLeakToRouter` (c), `…ShareLeakToAgent` (d), `test_ContainmentRejectsUnsetAgent` (e) — each verified load-bearing by removing the code it guards and confirming failure |
| 7 | Sepolia prerequisites verified | Real-registry branch, above |
| 8 | `.env` untracked, `.env.example` tracked | Both gate legs pass |

## Handover to wave 2

`BaseTest` ships now precisely so groups 2 and 3 apply `containment` at
authoring time rather than being retro-edited in group 4. **Inheriting
`BaseTest` is not applying the modifier** — every test function must carry it,
and every `setUp` must assign `agent`, `containedAsset` and `containedShare`
(mandatory, the modifier reverts if unset) plus `containedRouter` in any file
that deploys one.

Two things wave 2 should know:

- **Group 3's Morpho escape hatch fires today (2026-08-18).** By the WISH's own
  rule an unevaluated trigger means the hatch is **taken by default, not
  failed** — so `AllowlistedERC4626` holds USDC idle. Record it, don't re-decide.
- **The 8th custom error, `NotAllowlisted`, belongs to the vault (group 3)**, not
  the router. Group 2 ships seven.

Five cosmetic inconsistencies in WISH.md are listed at the end of
[findings-external-deps.md](findings-external-deps.md) — raised rather than
edited, since `.genie/` is Lorenzo's.


---

## Correction from PR #1 re-review: the modifier was armed on 2 of its 4 legs

`BaseTest.sol:45-51` asserts **2 holders × 2 tokens** — asset and share, at the agent
and at the router. `ContainmentHarness` originally exposed only `leakAssetToAgent` and
`leakShareToRouter`: **the diagonal**. The legs are crossed, so two of the four
assertions were reachable-but-unasserted.

Concretely: deleting `BaseTest.sol:49` — the router-holds-no-USDC assertion, which is
the non-custody invariant itself and the single most load-bearing line in the fixture
— left the entire suite green.

This was a plan-level gap rather than an execution failure. WISH group 1 AC 6 models
the modifier as "the asset leg + the share leg + the router leg", and the diagonal
satisfies that wording exactly. Group 4's containment audit certified "armed" without
catching it, because its method — counting *applications* of the modifier — cannot
detect an under-armed one.

**Fixed:** `ContainmentHarness` gains `leakAssetToRouter` and `leakShareToAgent`, plus
tests (c) and (d). Verified by mutation, one line at a time:

| Mutation | Result |
|---|---|
| `BaseTest.sol:45` removed | `test_ContainmentCatchesAssetLeakToAgent` FAIL — next call did not revert as expected |
| `BaseTest.sol:46` removed | `test_ContainmentCatchesShareLeakToAgent` FAIL |
| `BaseTest.sol:49` removed | `test_ContainmentCatchesAssetLeakToRouter` FAIL |
| `BaseTest.sol:50` removed | `test_ContainmentCatchesShareLeakToRouter` FAIL |

Exactly one test red per line, and no line unguarded.

## Correction from PR #1 re-review: the arming evidence rested on a bare `expectRevert()`

The negative tests catch their revert with a bare `vm.expectRevert()`, and they are
the **sole** evidence for the WISH's top-level criterion that the containment
assertion is *armed* rather than merely applied.

The failure mode is regression, not present-day. `_armedHarness()` does fund both legs
today. But if that funding ever broke — a permissioned `MockUSDC.mint`, a first-deposit
rounding change in `MockVault` — then `containedShare.transfer(containedRouter, 1)`
would revert `ERC20InsufficientBalance`, the bare `expectRevert()` would swallow it,
and the arming evidence would evaporate while the suite stayed green.
`test_ContainmentPassesWhenNothingLeaks` does not cover this: `noop()` passes whether
or not the harness holds anything.

**Fixed** by asserting the funding at the end of `_armedHarness()` rather than by
naming the expected revert data, which would couple the tests to Foundry's
assertion-message format. Verified by mutation — commenting out the share-leg
`vault.deposit` turns **five** tests red with `harness: share leg unfunded: 0 <= 0`,
including the positive control, instead of silently passing.

## Recorded, not fixed here: group 5's registration path

Lorenzo's HIGH on PR #1 concerns `script/Deploy.s.sol`, which exists on no branch.
ERC-8004 `register()` mints to `msg.sender`, so the WISH's deployer-key broadcast
would make the deployer the agent owner and every principal-signed mandate would die
at step 5 with `InvalidSignature`.

It is out of scope for group 1, and a GitHub review thread is not where a binding
constraint should live, so it is recorded in
[`group-5-constraints.md`](group-5-constraints.md) with the two acceptable fixes and
the closing `require` that must guard either one.
