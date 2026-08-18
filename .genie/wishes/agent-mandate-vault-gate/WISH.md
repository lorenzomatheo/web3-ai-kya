# Wish: Agent Mandate Vault Gate

| Field | Value |
|-------|-------|
| **Status** | APPROVED |
| **Slug** | `agent-mandate-vault-gate` |
| **Date** | 2026-08-17 |
| **Author** | Lorenzo |
| **Appetite** | medium |
| **Branch** | `wish/agent-mandate-vault-gate` |
| **Repos touched** | web3-kyc |
| **Design** | [DESIGN.md](../../brainstorms/agent-mandate-vault-gate/DESIGN.md) |

## Summary

Build `MandateRouter`, a pass-through contract that lets an AI agent's EOA deposit
into and redeem from a KYC-gated ERC-4626 vault on behalf of a human principal, by
proving on-chain that the agent acts for that principal within EIP-712 limits the
principal signed. The repository is currently empty apart from `.genie/`, so this
wish covers the whole build: toolchain, three contracts, a Foundry suite against a
Base mainnet fork, and a Base Sepolia deployment with an eleven-transaction demo
that prints every custom revert reason.

## Scope

### IN

- Foundry + pnpm toolchain pinned to OpenZeppelin **5.x**, with Base mainnet fork
  and Base Sepolia configured as separate profiles
- `MandateRouter` — EIP-712 verification, `depositFor` / `redeemFor` / `revoke`,
  custom errors carrying operands, indexed events, `(mandateHash, account)` state keying
- `AllowlistedERC4626` — minimal KYC gate holding USDC idle by default, over a
  Morpho Blue USDC market only under group 3's escape-hatch conditions, with an
  explicit `NotAllowlisted(receiver)` revert that fires before the inherited max check
- `MinimalIdentityRegistry` — test-only ERC-721 exposing `ownerOf`, plus a
  deliberately non-conformant variant returning `address(0)`
- Fork suite against pinned Moonwell Flagship USDC (`0xc1256Ae5...A2Ca`) on Base
  mainnet, and against `AllowlistedERC4626` for the gate
- Base Sepolia deployment, contract verification, and `pnpm demo`

### OUT

- x402, reputation scoring, any actual LLM, multi-vault routing, a web UI
- Upgradeability, pausing, admin roles, or fee collection in the router
- Net-position accounting; any exit-side bound beyond expiry and revocation —
  no exit cap, no cooldown, no share scoping (DESIGN Deferred; risks 11 and 12)
- ERC-1271 / ERC-4337 principals — step 5 cannot pass for a contract account
- CI pipelines; validation is run locally against the deadline

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | The full DESIGN.md decision table (17 entries) is binding and not re-opened here | It carries verified design-review evidence at SHIP; this wish plans the build, it does not re-litigate the architecture |
| 2 | All shared test infrastructure ships in group 1 — the registry double and its zero-owner variant, a 6-decimal mock USDC, a concrete mock vault, and the `containment` modifier on `BaseTest` | Makes groups 2 and 3 genuinely parallel. Both would otherwise reach into the other's group for a double, and the containment modifier is the subtler edge: if it arrives in group 4 it forces a retro-edit of every test file authored in wave 2 |
| 3 | OpenZeppelin is pinned to 5.x explicitly in group 1's acceptance | Decision 13 depends on `tryRecover` returning a **3-tuple**, which is 5.x-only — 4.9.x returns `(address, RecoverError)`, so a 4.x resolution silently changes the destructure. Note what is *not* a discriminator: `ECDSA.RecoverError` and `IERC4626` both exist in 4.9.x and resolve fine, and `ERC4626.deposit` checks `maxDeposit` first in **both** majors, so decision 6's hazard is real but version-independent |
| 4 | Risk 1's Morpho escape hatch is a stated exit condition on group 3, with a wall-clock trigger | The design already fixes the trigger at end of 2026-08-18; binding it to a group's acceptance rather than leaving it as prose is what stops it becoming a judgement call made under pressure two days before the deadline |
| 5 | The demo is a viem/TypeScript script, not `forge script` | The demo's whole premise is that every revert reason is ours; viem decodes custom errors with operands off the ABI natively, which is the output being demonstrated. `forge script` is retained for deployment |
| 6 | Group 2 carries the repository full gate; groups 3 and 4 carry focused validation; group 5 re-runs the gate immediately before broadcasting | `MandateRouter` is shared core behavior with the invariants the design record shows are easiest to get subtly wrong, so it escalates on its own merits. Group 5 re-runs it because its own step is irreversible — a live broadcast — and it is the last point at which any regression is catchable. Group 5's *authoring* needs nothing from group 4, which is why the dependency edge stays off; only the final gate-and-broadcast run is ordered after whatever group 4 has landed |

## Simplicity Case

- **Simplest complete design:** one non-upgradeable, ownerless router holding two
  public mappings, verifying an EIP-712 signature against an ERC-721 owner lookup
  and calling `deposit`/`redeem` on a vault. No custody, no share math, no admin
  surface, no arbitrary-call path.
- **Added machinery:** `AllowlistedERC4626` is the only component beyond the
  minimum, paid for by a present requirement — the demo must show the vault itself
  rejecting an agent that skips the router, which no permissionless vault can
  demonstrate. `spent` is paid for by the cap criteria, `revoked` by the revocation
  criteria, events by irreversibility (logs cannot be backfilled) and by the
  business model's per-transaction attribution requirement.
- **Deferred until measured:** net-position accounting (trigger: the first mandate
  intended to outlive a week, or the first complaint about re-signing); an exit
  cooldown (trigger: the first `Redeemed` followed by a `Deposited` under the same
  mandate key inside one hour, or the first operator asking what stops churn);
  share scoping as an unconditional v0.2 item whose key is still open; multi-vault
  mandates (trigger: a second vault operator signing on).
- **Complexity removed:** no share ledger, no exchange rate, no rounding-direction
  analysis, no donation/inflation-attack surface, no decimals conversion, no
  upgrade path, no owner, no pause, no fee logic, no CI.

## Dependencies

**depends-on:** none
**blocks:** none

## Success Criteria

- [ ] `forge build` and the whole default-profile `forge test` suite pass against
      OpenZeppelin 5.x, and each fork profile passes separately — the default
      profile excludes the fork directories by construction, so "the full suite"
      is the union of those runs, never one command
- [ ] Every one of the eight custom errors is reachable and asserted by a test, and
      none of OZ's own errors (`ECDSAInvalidSignature*`, `ERC721NonexistentToken`,
      `ERC4626ExceededMaxDeposit`, `ERC20InsufficientAllowance`) reaches a caller
- [ ] Transferring the `agentId` to a new owner makes a previously valid mandate
      revert `InvalidSignature` — the test that proves deriving the principal from
      the registry is load-bearing rather than decorative
- [ ] With a 10,000 USDC allowance against a 1,000 cap, looping deposits until
      rejection never pulls more than 1,000 from the principal
- [ ] The agent address and the router both end every test that exercises the
      router or a KYC-gated vault holding zero asset and zero shares, asserted
      centrally rather than restated per test, with the central assertion
      **armed** — a fixture that silently checks nothing would satisfy the letter
      of this and none of it. Group 1's own fixture tests are outside the scope:
      they exist to prove the assertion fires, so they leak on purpose inside a
      reverting sub-call
- [ ] Router deposits into and redeems from real `mwUSDC` on a Base mainnet fork,
      shares credited to the principal, round trip within a stated tolerance
- [ ] Contracts deployed and verified on Base Sepolia
- [ ] `pnpm demo` runs all eleven transactions end to end and prints each revert
      reason with its operands

## Execution Strategy

### Wave 1 (sequential)

| Group | Agent | Complexity | Model | Description |
|-------|-------|------------|-------|-------------|
| 1 | engineer | 2 — multi-package work (+1, Foundry and pnpm side by side); no deterministic test (+1, the Sepolia registration write path is an unverified external dependency with a branch to record) | engineer-standard / medium | Toolchain, network profiles, and the three test doubles plus `BaseTest` that every later group consumes |

### Wave 2 (parallel)

| Group | Agent | Complexity | Model | Description |
|-------|-------|------------|-------|-------------|
| 2 | engineer | 4 — stateful work (+2, two mappings with asymmetric read/write keying); prior rework (+1, the keying and verification order were wrong across several design-review rounds); the reentrancy/CEI argument has no deterministic test (+1) | engineer-complex / high | `MandateRouter` — the product |
| 3 | engineer | 3 — stateful work (+2, allowlist plus vault accounting); no deterministic test (+1, the Morpho Blue Sepolia market is an unverified external dependency with a wall-clock branch to record) | engineer-standard / high | `AllowlistedERC4626`, and the Morpho-vs-idle escape hatch decision |

### Wave 3 (parallel)

| Group | Agent | Complexity | Model | Description |
|-------|-------|------------|-------|-------------|
| 4 | engineer | 3 — stateful work (+2, pinned fork state across ownership transfers); prior rework (+1, the containment invariant's mechanism was mis-specified in design review) | engineer-standard / high | Fork suite, cross-ownership isolation, containment invariant |
| 5 | engineer | 3 — release work (+1, deployment and verification); a live-testnet script has no deterministic test (+1, RPC and faucet state are external); prior rework (+1, the demo enumeration drifted twice) | engineer-standard / high | Base Sepolia deployment and the eleven-transaction demo |

Groups 4 and 5 both depend only on 2 and 3 — group 5 deploys the wave-2 contracts and needs nothing the fork suite produces. Keeping the edge off group 5 is what preserves the trim option in the risk table below. Sequence them anyway if only one pair of hands is available: land group 4's local half first, since it carries the only proof of decision 17's **cross-owner** half — group 2 already proves the `msg.sender`-keying half.

Complexity scoring rubric: score each group independently and record the total plus a short rationale in **Complexity**. Add:

- **+2** each for orchestration / agent-lifecycle / routing; cost / model / escalation; stateful work; subjective acceptance.
- **+1** each for multi-package work; OTel-label dependency; no deterministic test; prior rework; prompt-skill change; CI / release work.

Route the total in **Model** by portable role and reasoning effort: **0–1** →
`engineer-trivial` / low; **2–3** → `engineer-standard` / medium or high;
**4–6** → `engineer-complex` / high; **7+** → `engineer-complex` plus an
independent `final-gate` at the highest justified effort. Codex maps these to
the `genie_*` profiles; other runtimes use their matching native roles. Keep
model and effort in runtime session/agent configuration, never skill frontmatter.

## Execution Groups

### Group 1: Toolchain and test doubles

**Goal:** Stand up a Foundry + pnpm project pinned to the library versions the design depends on, with the three test doubles and the shared `BaseTest` fixture that let groups 2 and 3 proceed in parallel.

**Deliverables:**
1. `foundry.toml` with a default profile that **excludes `test/fork/**`** via `no_match_path = "test/fork/**"` under `[profile.default]` — verified to be a real config key, not a CLI-only flag — and a `fork` profile supplying the Base mainnet RPC and a pinned block that **explicitly overrides** the key rather than merely omitting it: `no_match_path = "test/__never__/**"` under `[profile.fork]`. **Foundry profiles inherit from `[profile.default]`**, and TOML has no way to write "unset", so an omitted key means the fork profile silently inherits `test/fork/**` — under which every fork command in this wish matches zero tests and, because `forge test` exits 0 on a zero-match run, passes green while running nothing. Do not re-simplify this back to an omission. Without a working default exclusion, the bare `forge test` in groups 1, 2, 4 and 5 goes red for want of a mainnet RPC it does not need, since a fork test fails at *runtime* in `setUp()` rather than at compile time — which is also why `no_match_path` is the right key and `skip = ["test/fork/**"]` only a fallback: they are not drop-in substitutes. `no_match_path` takes a **single glob string** and filters test *selection*, leaving the files compiling; `skip` takes an **array** and excludes from *compilation*. Both satisfy the zero-tests criterion; only the first matches the runtime-versus-compile-time rationale. Record which was used
2. Also in `foundry.toml`: an `[rpc_endpoints]` table with `base` and `base_sepolia` aliases, which the `fork` profile's RPC setting references so the mainnet URL is named in one place; and an `[etherscan]` entry `base_sepolia = { key = "${BASESCAN_API_KEY}", chain = 84532 }`. Group 5's `--verify` resolves its key from this table or from `ETHERSCAN_API_KEY`, never from a bare `BASESCAN_API_KEY` in the environment, so without this entry the one command that produces the deploy-and-verify criterion cannot run. If Basescan keys stop verifying through Foundry under Etherscan's unified V2 API, repoint the table at `ETHERSCAN_API_KEY` — the table interpolates whatever variable it names
3. `remappings.txt`; `.gitignore` additions for `out/`, `cache/`, `broadcast/`, `node_modules/`
4. `openzeppelin-contracts` **5.x** and `forge-std` **≥ v1.8.0** installed into `lib/` via `forge install` and pinned to tags, with the submodules committed. State the mechanism explicitly: group 1's own gate runs `pnpm install` but no `forge install`, so if these arrive any other way a clean clone fails at `forge build`. The forge-std floor is load-bearing for the negative containment test: from v1.8.0 `assertEq` delegates to the `vm.assertEq` cheatcode and **reverts**, which is what `vm.expectRevert` catches (v1.7.6 has no `vm.assertEq` call sites; v1.8.0 has them throughout `StdAssertions.sol`). Legacy DSTest-style failures set a flag via `vm.store` without reverting, under which that test fails with "call did not revert as expected"
5. `package.json` + `pnpm-lock.yaml` with `viem` and `tsx`, and a `demo` script placeholder
6. `.env.example` naming `BASE_RPC_URL`, `BASE_SEPOLIA_RPC_URL`, `DEPLOYER_PRIVATE_KEY`, `PRINCIPAL_PRIVATE_KEY`, `AGENT_PRIVATE_KEY`, `BASESCAN_API_KEY` — real `.env` stays gitignored
7. `test/doubles/MinimalIdentityRegistry.sol` — conformant ERC-721 exposing `ownerOf`, plus a `ZeroOwnerRegistry` variant that returns `address(0)` instead of reverting. Surface beyond the ERC-721 interface: an unpermissioned `mint(address to, uint256 agentId)`, since minting is not part of ERC-721 and five downstream criteria need an `agentId` to exist and then transfer
8. `test/doubles/MockUSDC.sol` — 6-decimal ERC-20 with an unpermissioned `mint(address,uint256)`, which group 4 needs to fund owner B
9. `test/doubles/MockVault.sol` — concrete subclass of OZ's `ERC4626` over `MockUSDC`. OZ's `ERC4626` is `abstract`, so groups 2 and 4 cannot instantiate it directly
10. `test/BaseTest.sol` — shared fixture carrying the `containment` modifier that asserts the agent and the router hold zero of the asset and zero shares on exit. It imports **nothing from `src/`** — the router does not exist until group 2 — but it does import `IERC20` from OZ, which is what lets it name the tokens rather than only their holders. Four `internal` slots, set by subclasses in their own `setUp`: `address agent`, `address containedRouter`, `IERC20 containedAsset`, `IERC20 containedShare`. The token pair differs per consumer — MockUSDC/`MockVault` in group 2, MockUSDC/`AllowlistedERC4626` in group 3 and group 4's local file, real Base USDC/`mwUSDC` in the fork file — so no address can be hardcoded here. **`agent`, `containedAsset` and `containedShare` are all mandatory: the modifier reverts if any is unset**, so an unwired subclass fails loudly instead of passing inert. `agent` is on that list for the same reason as the tokens — an unset `agent` reads as `address(0)`, whose balances are trivially zero, so the agent half of the invariant would pass while checking nobody. Only `containedRouter` is skip-on-unset, which is the one legitimate absent case (group 3 deploys no router). It ships here, not in group 4, so every test file authored in waves 2 and 3 inherits it at authoring time rather than being retro-edited
11. `test/doubles/Doubles.t.sol` — the test contract that actually asserts deliverables 7 through 10 behave as their consumers assume, and the home of the OZ-5.x compile-time discriminator described in the acceptance criteria. Without it group 1's gate is `forge build` alone and four of its acceptance criteria are asserted by nothing
12. `test/fork/ProfileGuard.t.sol` — a single test asserting `assertEq(vm.envOr("FOUNDRY_PROFILE", string("default")), "fork")`; Solidity has no `==` on `string`, so this is the literal form. It therefore **fails if the default profile ever reaches it** and passes under the fork profile, making the exclusion in deliverable 1 falsifiable immediately rather than discovered in group 4 when `test/fork/` is first populated. Every fork invocation in this wish sets that variable explicitly

**Acceptance Criteria:**
- [ ] `forge build` exits 0 on a tree containing only the doubles
- [ ] The resolved OpenZeppelin version is 5.x, asserted by a compile-time reference that genuinely discriminates: a **three**-component destructure of `ECDSA.tryRecover`, which is `(address, RecoverError)` in 4.9.x and `(address, RecoverError, bytes32)` in 5.x, plus a reference to `ERC4626ExceededMaxDeposit`, which exists only in 5.x and is declared **inside** `abstract contract ERC4626`, so it must be reached as `ERC4626.ERC4626ExceededMaxDeposit.selector` or through `MockVault` rather than written bare. `ECDSA.RecoverError` and `IERC4626` are **not** discriminators — both resolve under 4.9.x
- [ ] `MinimalIdentityRegistry.ownerOf` reverts `ERC721NonexistentToken` for an unminted id, and `ZeroOwnerRegistry.ownerOf` returns `address(0)` for the same input
- [ ] An `agentId` mints to A, transfers to B, and `ownerOf` reflects B — the operation five downstream criteria are built on
- [ ] `MockUSDC.decimals()` returns 6, `MockUSDC.mint` funds an arbitrary address, and `MockVault` is instantiable in a test
- [ ] `BaseTest` compiles with zero imports from `src/`, and the `containment` modifier is proven wired rather than merely declared by **three permanent** negative tests, all under `vm.expectRevert` so the assertion failure is the asserted outcome rather than a red suite: (a) an inner harness contract — itself inheriting `BaseTest`, deployed by the outer test, with its slots assigned through a setter since its storage is separate — exposes an external function carrying the modifier and leaking the asset to the agent; (b) the same shape leaking **one share to `containedRouter`**, which is the only test that arms the share leg and the router leg at all — (a) alone leaves half the modifier unexercised, and a modifier that checks only assets on only the agent would pass every test in this wish while asserting a quarter of what it claims; (c) a harness leaving `agent` unset, shown to revert, because `address(0)` has trivially zero balances and would otherwise pass while checking nobody. A fourth case for `containedAsset`/`containedShare` unset is deliberately **not** required: an unset `IERC20` slot is `address(0)`, and calling `balanceOf` on it reverts on `extcodesize` regardless of the modifier's own guard, so that test would prove a property that already holds for free. Without (a) through (c), an unwired subclass passes inert and the suite-wide invariant means nothing
- [ ] `forge test` under the default profile runs without any RPC configured and reports **zero** tests from `test/fork/`, while `FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/**'` runs `ProfileGuard` green **with a passing count of at least 1**. The count assertion is not decoration: `forge test` exits 0 when the filter matches nothing, so a leaked `no_match_path`, a wrong glob and a renamed directory all present identically as a green fork run. A default-profile leak turns the guard red and an empty fork run turns the count red, which is what makes the mechanism falsifiable in both directions
- [ ] **Sepolia prerequisites verified by end of 2026-08-18, alongside the faucet:** the principal can come to own an `agentId` in the ERC-8004 registry at `0x8004A818BFB912233c491871b3d84c89A494BD9e`. Only *read* calls against that registry were verified during design; the registration write path is unverified and is the plan's one unhedged external dependency. If registration turns out to be permissioned or the interface does not cooperate, deploy `MinimalIdentityRegistry` to Base Sepolia and pass it as the registry constructor argument — decision 7 already permits this, since the registry is a parameter rather than a constant. Record which branch was taken
- [ ] `.env` is not tracked and `.env.example` is

**Validation:**
```bash
set -o pipefail
pnpm install --frozen-lockfile && forge fmt --check && forge build && forge test \
  && git check-ignore -q .env && git ls-files --error-unmatch .env.example \
  && FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/**' | tee /tmp/g1-fork.log \
  && grep -qE 'Ran [1-9][0-9]* tests? for test/fork/ProfileGuard\.t\.sol:' /tmp/g1-fork.log
```
Scope: build plus the full default-profile run, the gitignore check, then the profile guard under the fork profile.

Two shapes here are deliberate and must not be "simplified". The default-profile run is a **bare** `forge test` — it picks up `DoublesTest` anyway, and it is the only form that proves the *default* half of the exclusion criterion, because **any** `--match-path` or `--match-contract` filter on that run excludes `ProfileGuard` whether or not `no_match_path` works, so a completely broken exclusion would exit green and detection would slip to group 2. And the fork run carries two guards: `set -o pipefail`, without which `tee` supplies the pipeline's exit status and a failing suite reports green; and a grep naming `ProfileGuard.t.sol`, because `forge test` exits 0 when the filter matches nothing, so an inherited `no_match_path` in `[profile.fork]` would otherwise let this command certify an empty run.

`forge fmt --check` runs here rather than first appearing in group 2, so formatting drift is attributed to the group that introduced it. The remaining group-1 criterion — the Sepolia registration write path — is inherently manual and is deliberately not in this chain; its evidence is the recorded branch in the completion note. Note that the fork leg needs a live `BASE_RPC_URL` already at group-1 time: the `fork` profile's `eth_rpc_url` resolves through the `[rpc_endpoints]` alias, and forge auto-loads `.env`, so provisioning it belongs with the faucet step rather than being deferred to group 4.

**depends-on:** none

---

### Group 2: MandateRouter

**Goal:** Implement the router — EIP-712 verification, the three external functions, the eight custom errors, three indexed events, and the `(mandateHash, account)` state keying.

**Deliverables:**
1. `src/MandateRouter.sol` — `struct Mandate`, the typehash and `EIP712("MandateRouter", "1")` domain, one shared internal verifier for steps 1–6, `depositFor`, `redeemFor`, `revoke`, `nonReentrant` on both value paths
2. Seven of the eight custom errors: `NotAgent`, `WrongVault`, `MandateExpired`, `AgentNotRegistered`, `InvalidSignature`, `MandateRevoked`, `ExceedsMandate(remaining, attempted)`. The eighth, `NotAllowlisted`, belongs to the vault and ships in group 3
3. Events `Deposited`, `Redeemed`, `Revoked` exactly as specified in DESIGN
4. `spent` and `revoked` as **public** mappings keyed on `keccak256(abi.encode(mandateHash, account))` — one key shape, two different rules, and the asymmetry is decision 17 itself: `spent` reads and writes at the **derived principal**, while `revoked` is **written at `msg.sender`** and **read at the derived principal**. Writing `revoked` at the derived principal instead is the subtle failure that lets an attacker holding a copy of the mandate revoke it on the owner's behalf
5. `test/MandateRouter.t.sol` — the Authorization, Revocation and "cap actually binds" criteria from DESIGN, extending `BaseTest` and **applying the `containment` modifier to every test function** (inheriting it is not applying it), running against `MinimalIdentityRegistry` and `MockVault`

**Acceptance Criteria:**
- [ ] Every step of the verification order reverts with our custom error, never OZ's — including a malformed signature (`tryRecover` destructured, `err` checked) and an unminted `agentId` (`ownerOf` in try/catch)
- [ ] `NotAgent`, `WrongVault`, `MandateExpired` and `AgentNotRegistered` are each sited on **both** `depositFor` and `redeemFor`. Deposit-only coverage is not sufficient: only a redeem-sited test proves `redeemFor` actually calls the shared verifier rather than carrying its own copy
- [ ] A malleable high-`s` signature is rejected rather than recovered
- [ ] A registry returning `address(0)` yields `AgentNotRegistered`, not a pass against a zero principal
- [ ] `ExceedsMandate` reports `remaining` and `attempted`, `cap - Deposited.spentTotal` reproduces `remaining`, and a single deposit exceeding the whole cap reverts the same way as one exceeding only the remainder
- [ ] `revoke` writes at `msg.sender` with no ownership gate; a third party's `revoke` on a mandate they did not sign leaves the owner's deposit succeeding
- [ ] After the principal's `revoke`, `depositFor` under the same mandate reverts `MandateRevoked`
- [ ] **And redemption under that same revoked mandate reverts `MandateRevoked` too** — decision 3 claims revocation kills both directions at once, and only the redeem-sited half proves it
- [ ] The signer can revoke after transferring the `agentId` away, and the mandate stays dead when the `agentId` returns
- [ ] An attacker holding the victim's real mandate in full emits a `Revoked` with an identical digest and the victim's `agentId`, and the owner's deposit still succeeds — with `revoker` equal to the caller, never a derived principal, since the whole consumption rule depends on that field naming who actually wrote the flag
- [ ] All three events emit `mandateHash` equal to an independently computed `_hashTypedDataV4(hashStruct(m))`, and `Deposited`/`Redeemed` carry the **derived** `principal` and the `agentId` in their indexed positions
- [ ] `USDC.transferFrom` pulls from the principal, never from the agent, and `redeemFor` passes no `owner` argument other than the derived principal — asserted directly, not inferred from where the assets landed
- [ ] Transferring the `agentId` to a new owner makes a previously valid mandate revert `InvalidSignature` — the only test that proves deriving the principal from the registry is load-bearing rather than decorative
- [ ] With a 10,000 USDC allowance against a 1,000 cap, looping `depositFor` until rejection pulls at most 1,000 from the principal in total
- [ ] The router performs **no decimals conversion**: `cap` and the `assets` argument are in 6-decimal asset units end to end, and `shares` is passed through to the vault untouched. Asserted here rather than in group 3, since only a router test can observe it
- [ ] The router holds zero of both assets after every call

**Validation:**
```bash
forge fmt --check && forge build && forge test
```
Scope: repository full gate. The router is shared core behavior that groups 3, 4 and 5 all reach, and its keying and verification-order invariants are the ones the design record shows are easiest to get subtly wrong, so nothing narrower is proportional. If group 3 is concurrent on the shared branch, run the gate in an isolated worktree holding groups 1 and 2 only. That is the requirement, not a preference: `--no-match-contract` filters test *execution* while `forge test` compiles the whole project first, so it is inert against the dominant concurrent failure — a half-written `src/AllowlistedERC4626.sol` that does not compile. A wave-2 sibling must not fail this group for reasons outside its scope, and only worktree isolation actually prevents it.

**depends-on:** 1

---

### Group 3: AllowlistedERC4626 and the Morpho decision

**Goal:** Author the KYC gate that earns the "vault rejects the agent" transaction, and settle whether it sits over a real Morpho Blue market or holds USDC idle.

**Deliverables:**
1. `src/AllowlistedERC4626.sol` — `deposit`/`mint` overrides that `revert NotAllowlisted(receiver)` **before** delegating to the inherited implementation, plus the minimal admin surface that puts an address on the allowlist in the first place. Group 4 needs it for owner B and group 5 for the principal before demo transaction 1
2. **Idle-USDC by default.** The Morpho Blue supply/withdraw integration on the Sepolia market is taken *only if* it lands together with its own test — a `sepolia-fork` profile plus a supply/withdraw round-trip criterion — because that branch means hand-written accounting. If it is taken, its tests live under `test/sepolia-fork/` and group 1 deliverable 1's default-profile exclusion widens to `test/{fork,sepolia-fork}/**` (globset supports brace alternation, and `no_match_path` holds only one glob), otherwise the bare `forge test` in groups 2, 4 and 5 goes red for want of a Sepolia RPC — the exact failure that exclusion exists to prevent. `[profile.sepolia-fork]` must then carry its **own sentinel `no_match_path` override**, for the identical reason `[profile.fork]` does: profiles inherit from `[profile.default]`, so an omitted key means the profile excludes its own tests, matches nothing, and exits 0 while running nothing. Shipping it untested into a live Sepolia demo is the failure mode the escape hatch exists to prevent, so the burden of proof sits on the integration, not on the fallback. The hatched branch needs nothing extra here: it is already covered by group 4's `mwUSDC` fork test — `mwUSDC` is a MetaMorpho vault over Morpho Blue, verified live on Base mainnet (`MORPHO()` returns `0xBBBB...FFCb`, with non-empty supply and withdraw queues)
3. `test/AllowlistedERC4626.t.sol`, containing `contract AllowlistedERC4626Test` — the name is pinned because this group's validation selects on it with `--match-contract` and `forge test` exits 0 on a zero-match run, so a renamed contract would turn the whole gate green while running nothing. It extends `BaseTest` and applies the `containment` modifier to every test function. Note for execution review: the positive-case caller below is a **deliberate deviation** from DESIGN's Vault-mechanics wording, which says the agent's key deposits to the principal. DESIGN also states the containment invariant holds only if the suite never deals USDC to the agent; the two are in tension and this wish takes the containment side. Do not re-litigate it as a transcription error

**Acceptance Criteria:**
- [ ] `deposit(assets, agent)` from any caller reverts `NotAllowlisted(agent)`, while `deposit(assets, principal)` from a funded neutral `outsider` address succeeds — together these prove the gate keys on `receiver`, not on `caller`. The positive case must **not** be called from the `agent` slot: OZ's `_deposit` pulls via `safeTransferFrom(asset, caller, ...)`, so an agent-called success requires dealing the agent USDC, which the containment invariant asserts never happens (group 4). The negative case already covers "from any caller"
- [ ] The revert is ours, not `ERC4626ExceededMaxDeposit`: the check precedes the inherited `maxDeposit` comparison. If `maxDeposit` also returns 0 for an unallowlisted receiver, a test asserts the error selector is still `NotAllowlisted`
- [ ] `asset()` is a 6-decimal token and `decimals()` returns 6 — OZ 5.x `ERC4626.decimals()` is `_underlyingDecimals + _decimalsOffset()` with the offset 0 by default, so shares here are 6-decimal, unlike `mwUSDC`'s 18. The router's no-conversion property is asserted in group 2, which is where a router test can observe it
- [ ] **Escape hatch, evaluated by end of 2026-08-18:** if a usable Morpho Blue USDC market is not supplying and withdrawing correctly **with a passing test** by that date, **take the hatch** — the vault holds USDC idle and Morpho exposure is confined to group 4's fork suite. Not "decide": the design fixes this as a checkpoint precisely so it is not a judgement call made under deadline pressure. The date is absolute rather than relative to when this group starts, since a trigger that slides with the schedule cannot protect against the schedule. Record which branch was taken in the group's completion note. If the date passes unevaluated — which it can, since this group sits in wave 2 behind group 1 — the hatch is **taken by default**, not failed: the clock exists to force the safe branch, not to fail the group

**Validation:**
```bash
forge fmt --check && forge test --match-contract AllowlistedERC4626Test -vv
```
Scope: focused behavior tests. This group adds one contract with one boundary — the receiver gate — and does not touch the router's contracts or state, so the full gate would only re-run group 2's suite unchanged. The exposure is symmetric with group 2's, so the same rule applies: if group 2 is concurrent on the shared branch, run this gate in an isolated worktree holding groups 1 and 3 only. `--match-contract` filters execution while `forge test` compiles all of `src/` first, so a half-written `src/MandateRouter.sol` fails this group for reasons outside its scope and no filter prevents it. This command is sufficient **only for the idle-USDC default**. If the Morpho branch is taken, this group's deliverable 2 requires it to arrive with a `sepolia-fork` profile and a supply/withdraw round-trip test, and that run is appended here with the same `set -o pipefail` plus suite-named grep that groups 1 and 4 use — hand-written accounting cannot ship on a local-only gate, and it especially cannot ship on a gate that reports green when it selected nothing.

**depends-on:** 1

---

### Group 4: Fork suite, ownership isolation, containment invariant

**Goal:** Prove the router composes with a production vault, that state does not leak across an `agentId` transfer, and that containment holds suite-wide rather than per illustrative test.

**Deliverables:**
1. `test/fork/MandateRouterFork.t.sol` against pinned `mwUSDC` (`0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca`) on a Base mainnet fork at a pinned block
2. `test/OwnershipIsolation.t.sol` — **local, no RPC**: state isolation across an `agentId` transfer with owner B independently allowlisted, funded and approved; the prior-owner-redeems-directly criterion; and the risk-12 test. It runs against `AllowlistedERC4626`, which mwUSDC cannot stand in for since it has no allowlist, so these belong outside `test/fork/` — which is also what makes the schedule mitigation below executable by path
3. Verification that `BaseTest`'s `containment` modifier is both **applied and armed** across every test file under `test/` that deploys the router or a vault, backfilling any that missed it. Application alone is not the criterion. A subclass that never assigns `agent`, `containedAsset` or `containedShare` fails loudly by group 1's design, so the audit confirms each such `setUp` assigns all three — and **additionally `containedRouter` in every file that deploys one**. That fourth leg is checked by inspection rather than by a negative test precisely because it is skip-on-unset by design, which makes it the one slot that cannot fail loudly: a file that applies the modifier but forgets it passes the router half of the invariant while checking nobody. Scoped that way on purpose rather than as an exception: `test/fork/ProfileGuard.t.sol` deploys nothing, and group 1's fixture tests in `test/doubles/Doubles.t.sol` exist to prove the assertion fires, so they leak the asset deliberately inside a reverting sub-call. Group 1 ships the modifier so waves 2 and 3 apply it at authoring time; this is the audit, not the point of application

**Acceptance Criteria:**
- [ ] Router deposits into `mwUSDC` on the fork and shares are credited to the principal
- [ ] Deposit followed by immediate full redeem returns the principal's assets within an explicit stated tolerance — not exact equality, since two rounding layers plus fee accrual will not return the deposit to the wei. The tolerance is expressed in **asset** units (USDC, 6 decimals). `mwUSDC` shares are 18 decimals, unlike `AllowlistedERC4626`'s, which inherit USDC's 6 through OZ's default zero decimals offset; no share-side epsilon is implied by either
- [ ] Owner A spends 800 of a 1,000 cap, the `agentId` transfers to B, B signs a byte-identical mandate and deposits 1,000: accepted. Neither test warps past `expiry`
- [ ] A revokes, the `agentId` transfers to B, B signs a byte-identical struct: B's deposit is accepted
- [ ] The agent and the router hold zero asset and zero shares at the end of **every router- or vault-deploying test in the suite**, not merely the fork tests, with the modifier armed rather than merely applied — it holds only because group 3's `NotAllowlisted` revert fires before any `transferFrom` and no test ever funds the agent, which is why group 3's positive case is called from a neutral `outsider`
- [ ] After an `agentId` transfer, the prior owner still redeems their existing shares directly from the vault
- [ ] The risk-12 test passes: the agent redeems shares the principal acquired without the router, under a same-principal different-`nonce` mandate through which no deposit was ever routed. Written to pass today so a later `sharesMinted` bound has a test to invert

**Validation:**
```bash
set -o pipefail
FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/**' -vv | tee /tmp/g4-fork.log \
  && grep -qE 'Ran [1-9][0-9]* tests? for test/fork/MandateRouterFork\.t\.sol:' /tmp/g4-fork.log \
  && forge test
```
Scope: fork tests under the pinned profile from group 1 deliverable 1, which carries the RPC and the pinned block so they are not retyped per invocation — plus the **full** local suite, because this group's containment criterion is explicitly suite-wide and the fork-only command could be satisfied while the modifier is applied to fork tests alone. Two guards make this command mean something, and neither is optional. `set -o pipefail` is required because `tee` otherwise supplies the pipeline's exit status and a **failing** fork suite reports green. The grep names `MandateRouterFork.t.sol` specifically rather than counting passes, because `forge test` exits 0 on a zero-match run and `ProfileGuard` also lives under `test/fork/` — a bare count would be satisfied by the guard alone while the mwUSDC suite was renamed, misplaced or never selected. Together they prove the fork profile actually selected and ran the mwUSDC suite.

**depends-on:** 2, 3

---

### Group 5: Base Sepolia deployment and the demo

**Goal:** Deploy, verify, and ship the eleven-transaction demo that prints every custom revert reason with its operands.

**Deliverables:**
1. `script/Deploy.s.sol` — deploys `AllowlistedERC4626`, then `MandateRouter` with the registry address read from config and the freshly-deployed vault address (the vault is produced by this script, not supplied to it), asserts the registry address has code before deployment completes, and allowlists the principal. Whichever registry branch group 1 recorded, the run must end with `ownerOf(agentId) == principal` for an `agentId` pinned into the demo config: without it, nine of the eleven demo transactions cannot even be constructed
2. Verified contracts on Base Sepolia, addresses pinned into the demo config
3. `scripts/demo.ts` run by `pnpm demo` — viem, signing the mandate with typed data reproducing `name`, `version`, `chainId` and `verifyingContract` exactly
4. Allowances granted **by the principal's key** — never the deployer's: the USDC allowance equal to the cap before transaction 1, and the share allowance granted *after* transaction 1 from the balance it actually minted, since the position does not exist until then. Read the minted amount from the `Deposited` log or `previewDeposit`, and approve exactly it, never `type(uint256).max`

**Acceptance Criteria:**
- [ ] All eleven transactions run in order and the script exits 0: (1) deposit 500 accepted; (2) agent redeems, assets to the principal, `spent` unchanged; (3) `ExceedsMandate(500, 600)`; (4) `NotAgent`; (5) `WrongVault`; (6) `MandateExpired`; (7) `AgentNotRegistered`; (8) `InvalidSignature`; (9) the **principal** calls `revoke`, emits and does not revert; (10) `MandateRevoked`; (11) `NotAllowlisted(agent)`
- [ ] Eight distinct errors and three non-reverting transactions, matching the design's enumeration exactly
- [ ] Transaction 9 is called from the principal's key, not the agent's — otherwise transaction 10 quietly succeeds and the demo asserts nothing
- [ ] Transaction 2 does not revert `ERC20InsufficientAllowance`; the share approval lands between transactions 1 and 2, from the principal's key
- [ ] Every revert prints as our decoded custom error with operands, never a raw selector or an OZ error name
- [ ] Both contracts resolve on Basescan with verified source — the deploy ran with `--verify` and reported success, or `forge verify-contract` was run per address afterwards — and the two addresses plus the `agentId` are recorded in the completion note. This is the wish's own top-level criterion and nothing else in the plan would produce it
- [ ] The script says out loud that transactions 1, 2 and 9 succeed, so they do not read as missing cases

**Validation:**
```bash
set -a && . ./.env && set +a \
  && forge fmt --check && forge test \
  && forge script script/Deploy.s.sol --rpc-url "$BASE_SEPOLIA_RPC_URL" \
       --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --verify \
  && pnpm demo
```
The env is sourced into the **invoking shell** first: forge's own `.env` autoload populates forge's environment, not the shell's, and `$BASE_SEPOLIA_RPC_URL` here is expanded by the shell before forge ever runs.
Scope: the demo is simultaneously the validation and the deliverable — a non-zero exit or any undecoded revert reason falsifies the group. The full local gate runs first because broadcasting is irreversible and this is the last point at which any regression is catchable.

**Ordering constraint, distinct from the dependency edge:** authoring group 5 needs only groups 2 and 3, which is why `depends-on` stops there and the trim option in the risk table survives. But the final gate-and-broadcast run must execute on a tree that already contains group 4's containment audit if group 4 has landed — otherwise the gate certifies a tree that is about to change. If group 4 is still in flight, run the gate on the merge of both or sequence group 5 after it; never race them on the shared branch.

**depends-on:** 2, 3

---

## QA Criteria

_What must be verified on dev after merge. The QA agent tests each criterion._

- [ ] A third party can read a `Deposited` log and reconstruct the storage key from `mandateHash` and `principal`, and `cap - spentTotal` matches what `ExceedsMandate` would report
- [ ] A `Revoked` log emitted by a non-signer is correctly discarded by recovering the signer from the mandate and its signature — the consumption rule holds against a live log, not just a unit test
- [ ] Re-running `pnpm demo` a second time against the same deployment either succeeds from a clean mandate `nonce` or fails with our own error, never with an unhandled revert
- [ ] No regression: the full `forge test` suite still passes after the demo has mutated Sepolia state, since the suite is fork- and local-only

---

## Assumptions / Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Morpho Blue market creation on Sepolia is blocked — a market needs an enabled LLTV, an oracle and an IRM, and Blue is not an ERC-4626 | Medium | Group 3's escape hatch with a wall-clock trigger at end of 2026-08-18: the vault holds USDC idle and Morpho lives only in group 4's mainnet fork suite. Deciding on a checkpoint rather than under pressure two days before the deadline |
| The exit side is uncapped, so the agent key can force-exit repeatedly and, via the monotonic `spent` counter, strand the mandate on the entry side | Medium, accepted | Not solved in v0.1 by design. Bounded by expiry and revocation; operating guidance is short expiries. Stated openly in the pitch alongside principal-key compromise, never sanded off |
| A mandate does not scope the agent to the position it created | Medium | Operating guidance: approve shares up to the managed position, never `type(uint256).max`. Group 4 pins the current behavior so a later `sharesMinted` bound has a test to invert |
| Principal key compromise defeats the entire design | High, accepted | Out of scope by construction; stated openly rather than implying protection that does not exist |
| The principal grants **two** standing allowances — USDC for deposits and vault shares for redemption — and together they exceed any single mandate | Medium | Router is non-upgradeable, ownerless, has no arbitrary-call path, never transfers anywhere but the vault or the principal, and never passes an `owner`/`from` other than the derived principal. USDC leg is bounded by `cap` and proven by the loop-until-rejection criterion; the share leg is bounded by nothing inside the mandate, so operating guidance is to approve only the managed position, never `type(uint256).max` — group 5 demonstrates that practice on both legs |
| An OpenZeppelin 4.x resolution silently changes `tryRecover`'s return shape | Medium | Group 1 pins 5.x and asserts it with the 3-component destructure, which is the genuine discriminator. `ECDSA.RecoverError`, `IERC4626` and `ERC4626.deposit`'s check order are **not** — all behave the same across both majors, so a version guard built on them would pass under 4.x |
| Sepolia USDC and gas needed on demo day | Low | Faucet in advance during group 1; pin the funded addresses in the deploy script |
| Four days to the Aug 22 deadline against a five-group plan | Medium | Waves 2 and 3 are both parallel. If the schedule slips, the trimmable subset is the **mainnet-fork half of group 4 only** — the `mwUSDC` deposit and the round-trip tolerance, which need network access. The ownership-isolation, containment and risk-12 tests are local, cost no RPC, and must not be trimmed: they carry the only proof of decision 17's **cross-owner** half — A's `spent` not charging B, and A's revocation not blacklisting B's byte-identical struct — which group 2's single-owner revocation tests cannot reach |
| The council returned `revise` on the *framing* — the load-bearing assumption that an operator's vault gates on `receiver` is unvalidated | Medium | Does not block the build; one conversation with a vault operator before or during wave 2 would confirm or kill the premise. Tracked outside this wish |
| The design assumes the principal owns the agent NFT and the agent's operating EOA is a separate address named in the mandate | Medium | If operators instead transfer the NFT to the agent, decision 4 inverts and the whole derivation must be revisited — this is the same operator conversation as the row above, and the two questions should be asked together |
| ERC-1271 and ERC-4337 principals cannot satisfy step 5, since a contract account produces no ECDSA signature recovering to its own address | Medium, accepted | A real gap in the institutional KYC setting this targets, and out of scope for v0.1. EIP-7702 accounts work unmodified — delegation sets code but leaves the key. State the gap rather than letting it be discovered |

---

## Review Results

_The read-only reviewer returns evidence; the invoking orchestrator appends a timestamped block here after plan, execution, and PR reviews._

### Plan review — 2026-08-18 — **SHIP**

| Field | Value |
|-------|-------|
| Artifact | `.genie/wishes/agent-mandate-vault-gate/WISH.md` |
| Verdict | **SHIP** |
| Reviewer | `genie:reviewer` thread `a2a6ff2bc2c5824f0` |
| Round | 7 (rounds 1–6 returned FIX-FIRST) |

**Verified.** Every numbered-deliverable, profile-name, glob and file-path
cross-reference resolves. The round-6 fixes did not spill: `set -o pipefail` is
sound in bash and fails closed under `dash` (exit 2), and the suite-named greps
match forge's actual `Ran {N} tests for {path}:{Contract}` output, which is
uncolored when piped. Library claims were re-checked against upstream
OpenZeppelin 5.0.2/4.9.6, forge-std v1.7.6/v1.8.0, Foundry master source, and
live Base mainnet / Base Sepolia RPC.

**The two defect classes that consumed rounds 3–6, now closed:**

1. *Gates that certify nothing.* `forge test` exits 0 on a zero-match run and
   warns only on stderr. Every filtered invocation in this wish is now paired
   with a suite-named grep, and every profile that runs excluded tests carries
   an explicit sentinel `no_match_path` override — because Foundry profiles
   inherit from `[profile.default]` and TOML cannot express "unset".
2. *Fixtures that cannot express their own assertion.* `BaseTest` carries four
   slots, three mandatory, with the containment modifier proven wired by three
   permanent negative tests.

**Non-blocking findings resolved before dispatch:** the share/router leg of the
containment modifier is now armed by negative test (b), and group 3's
`--match-contract` target is pinned to `contract AllowlistedERC4626Test` in its
deliverable. Remaining LOWs were judged not worth a further round against a
4-day appetite.

**Carried risk (accepted, not closed):** the ERC-8004 registration *write* path
on Base Sepolia is unverified — only reads were checked during design. Group 1
carries a same-day checkpoint and a `MinimalIdentityRegistry` fallback that
decision 7 already permits.

---

## Files to Create/Modify

```
foundry.toml
remappings.txt
package.json
pnpm-lock.yaml
.env.example
.gitignore                                   (modify)
src/MandateRouter.sol
src/AllowlistedERC4626.sol
test/doubles/MinimalIdentityRegistry.sol
test/doubles/MockUSDC.sol
test/doubles/MockVault.sol
test/doubles/Doubles.t.sol                   (asserts the doubles; group 1)
test/BaseTest.sol                            (containment modifier; group 1)
test/fork/ProfileGuard.t.sol                 (profile-exclusion guard; group 1)
test/MandateRouter.t.sol
test/AllowlistedERC4626.t.sol
test/OwnershipIsolation.t.sol                (local, no RPC; group 4)
test/fork/MandateRouterFork.t.sol
script/Deploy.s.sol
scripts/demo.ts

test/sepolia-fork/MorphoSupplyWithdraw.t.sol (only if group 3 takes the Morpho
                                              branch; widens group 1 deliverable
                                              1's exclusion glob to
                                              test/{fork,sepolia-fork}/** and
                                              needs its own sentinel override)
```
