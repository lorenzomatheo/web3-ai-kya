# Group 1 — approach

**Branch:** `feat/g1-toolchain` → `wish/agent-mandate-vault-gate`
**Scope:** WISH.md group 1, deliverables 1–12. Nothing else.

Group 1 is wave 1 and blocks every other group, so its only real job is to make
waves 2 and 3 genuinely parallel: pin the library versions the design's
correctness arguments depend on, and ship the shared test doubles plus the
`containment` fixture so groups 2 and 3 never reach into each other for a double.

## What was pinned, and why the exact versions matter

| Dependency | Pin | Why this floor |
|---|---|---|
| `openzeppelin-contracts` | **v5.0.2** | `ECDSA.tryRecover` returns a **3-tuple** in 5.x and a 2-tuple in 4.9.x. DESIGN decision 13 destructures three components, so a 4.x resolution silently changes the shape. v5.0.2 is the version the plan review verified against. |
| `forge-std` | **v1.9.6** | From v1.8.0 `assertEq` delegates to the `vm.assertEq` cheatcode and **reverts**, which is what `vm.expectRevert` catches. Under v1.7.6 a DSTest-style failure sets a flag via `vm.store` without reverting, and the negative containment tests fail with "call did not revert as expected". |

Both are git submodules, committed. Foundry 1.x does not auto-commit them, so
they were staged explicitly — otherwise a clean clone dies at `forge build`.

Deliberately **not** used as version discriminators, because all of them resolve
identically under 4.9.x and would pass while proving nothing: `ECDSA.RecoverError`,
`IERC4626`, and `ERC4626.deposit`'s `maxDeposit`-first check order.

## The two mechanisms that could have passed while asserting nothing

Both were the defect classes that consumed rounds 3–6 of the plan review, so both
were checked by *breaking them on purpose* rather than by reading the output.

### 1. Profile exclusion

`[profile.default]` sets `no_match_path = "test/fork/**"`; `[profile.fork]` sets
the sentinel `no_match_path = "test/__never__/**"`. The sentinel is not
decoration — Foundry profiles inherit from `[profile.default]` and TOML cannot
express "unset", so omitting the key would make the fork profile exclude its own
tests, match nothing, and still exit 0.

`test/fork/ProfileGuard.t.sol` asserts `FOUNDRY_PROFILE == "fork"`, making the
mechanism falsifiable in both directions. Verified:

- Default profile: 10 tests run, **zero** from `test/fork/`.
- Fork profile: `ProfileGuardTest` runs and passes, count ≥ 1.
- Forced through the default profile (`FOUNDRY_NO_MATCH_PATH` override), it
  **fails** with `assertion failed: default != fork` — so the guard is real.

**Form recorded (deliverable 1 requires this):** the project-relative glob
`test/fork/**` works on Foundry 1.7.1. The absolute-path contingency
(`**/test/fork/**`) was not needed, and `skip` was not used.

### 2. The `containment` modifier

Four `internal` slots on `BaseTest`. `agent`, `containedAsset` and
`containedShare` are **mandatory** — the modifier `require`s each before running
the body, so an unwired subclass fails loudly instead of passing inert against
`address(0)`, whose balances are trivially zero. Only `containedRouter` is
skip-on-unset, the one legitimate absent case (group 3 deploys no router).

`BaseTest` imports nothing from `src/` — the router does not exist yet — but does
import `IERC20`, which is what lets it name the tokens rather than only their
holders.

Armed by three permanent negative tests in `test/doubles/Doubles.t.sol`, all
using an inner harness that inherits `BaseTest`, is deployed by the outer test,
and has its slots assigned through a setter (its storage is separate):

- **(a)** leaks the asset to `agent`
- **(b)** leaks **one share to `containedRouter`** — the only test arming the
  share leg and the router leg at all
- **(c)** leaves `agent` unset

A fourth case for unset token slots is deliberately omitted: an unset `IERC20`
slot is `address(0)` and `balanceOf` on it reverts on `extcodesize` regardless of
the modifier's guard, so it would prove a property that holds for free.

Each was verified load-bearing by removing the code it guards and confirming the
test fails: gutting the balance assertions fails (a) and (b); removing the
`agent != address(0)` require fails (c). A fourth test,
`test_ContainmentPassesWhenNothingLeaks`, is the positive control — without it,
all three negatives would pass against a modifier that unconditionally reverted.

## Deviations from the WISH

None in substance. Two additions:

- **`test_ContainmentPassesWhenNothingLeaks`** — the positive control described
  above. The WISH specifies three negative tests; a fourth positive one is what
  stops them being satisfiable by an always-reverting modifier.
- **`[fmt]` settings and a `solc = "0.8.28"` pin** in `foundry.toml`, for
  reproducible builds and stable `forge fmt --check` across machines. Neither is
  required by the WISH; neither affects any acceptance criterion.
