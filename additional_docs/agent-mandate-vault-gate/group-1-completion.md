# Group 1 — completion note

**Status:** COMPLETE · **Date:** 2026-08-18 · **Branch:** `feat/g1-toolchain` → `wish/agent-mandate-vault-gate`

Gate exited **0**. Command run verbatim from WISH.md group 1 Validation.

```
pnpm install --frozen-lockfile   ok (lockfile up to date)
forge fmt --check                ok
forge build                      ok (Solc 0.8.28)
forge test                       10 passed, 0 failed  — zero tests from test/fork/
git check-ignore -q .env         ok  (.env untracked)
git ls-files .env.example        ok  (.env.example tracked)
FOUNDRY_PROFILE=fork forge test  1 passed  (ProfileGuardTest)
grep 'Ran [1-9]... ProfileGuard' ok
```

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
| 6 | `BaseTest` compiles with zero `src/` imports; `containment` proven wired by three permanent negative tests | `test_ContainmentCatchesAssetLeakToAgent` (a), `test_ContainmentCatchesShareLeakToRouter` (b), `test_ContainmentRejectsUnsetAgent` (c) — each verified load-bearing by removing the code it guards and confirming failure |
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
