# Design: Agent Mandate Vault Gate

| Field | Value |
|-------|-------|
| **Slug** | `agent-mandate-vault-gate` |
| **Date** | 2026-08-16 |
| **WRS** | 100/100 |

## Problem

A KYC-gated vault cannot accept a deposit initiated by an AI agent, because the
agent's address carries no verifiable relationship to the principal the operator
already approved.

This matters because the capital is not blocked by risk appetite — the operator
has already underwritten the human. It is blocked by the absence of an on-chain
proof that *this address acts for that approved principal, within limits the
principal signed*. Every competing approach puts that limit inside the agent's
wallet, where the vault cannot verify it and must instead trust the agent's
operator. Moving the check to the contract that holds the funds makes it
enforceable by the party carrying the risk and auditable by anyone.

## Scope

### IN
- `MandateRouter` — EIP-712 mandate verification and the deposit/redeem path
- `AllowlistedERC4626` — a minimal KYC-gated ERC-4626 over a real Morpho Blue
  market, standing in for the operator's vault
- ERC-8004 agent-ownership lookup via `ownerOf(agentId)`
- `MinimalIdentityRegistry` — test-only ERC-721 exposing `ownerOf`, used on the
  mainnet fork where the real registry is unusable
- Principal-initiated revocation
- Cumulative spend accounting per mandate
- Foundry suite against a Base mainnet fork
- Deployment to Base Sepolia plus a scripted seven-transaction demo that prints
  every revert reason
- Custom errors throughout — the revert reason is the product surface

### OUT
- x402
- Reputation scoring
- Any actual LLM — the agent is a keypair driven by a script
- Multi-vault routing
- A web UI
- Upgradeability, pausing, admin roles, or fee collection in the router
- Net-position accounting (see Deferred)

## Approach

**Pass-through router, not a wrapping vault.** `MandateRouter` verifies the
mandate and then calls `vault.deposit(assets, principal)` so the vault mints
directly to the principal. The router's balance is zero before and after; it
holds value only between `transferFrom` and `deposit` inside one call.

```
                 ERC-8004 AgentIdentity (ERC-721)
                        |  ownerOf(agentId) -> principal
                        v
  agent EOA  --->  MandateRouter  --->  AllowlistedERC4626  --->  Morpho Blue
   (timing)         (the product)         (the gate)              (the yield)
                        |
                        +-- shares mint to principal, never to the router
```

Verification order inside `depositFor`, cheapest and most-specific first:

1. `msg.sender == m.agent` else `NotAgent`
2. `m.vault == address(vault)` else `WrongVault`
3. `block.timestamp <= m.expiry` else `MandateExpired`
4. `principal = registry.ownerOf(m.agentId)` else `AgentNotRegistered`
5. `ECDSA.tryRecover(digest, sig) == principal` else `InvalidSignature`
6. `!revoked[mandateHash]` else `MandateRevoked`
7. `spent[mandateHash] + assets <= m.cap` else `ExceedsMandate(remaining, attempted)`

Steps 4 and 5 must be written defensively or our custom errors never fire:
OpenZeppelin's `ECDSA.recover` reverts with `ECDSAInvalidSignature*` rather than
returning `address(0)`, and ERC-721 `ownerOf` reverts `ERC721NonexistentToken`.
Use `tryRecover` and wrap the `ownerOf` call in try/catch so the revert reason is
ours. `tryRecover` also rejects malleable high-`s` signatures.

Funds move as `USDC.transferFrom(principal, address(this), assets)` — from the
principal, never from the agent. This is the whole basis of the containment
claim, so it is stated here rather than left to the implementation.

The principal is never a field in the mandate — it is *derived* from the registry
and must match the recovered signer. That is what binds the ERC-8004 identity to
the authorization rather than merely mentioning it, and it makes an `agentId`
transfer self-revoking: the new owner is not the recovered signer, so every
outstanding mandate for that agent stops verifying.

```solidity
struct Mandate {
    uint256 agentId;   // ERC-8004 token id; ownerOf() gives the principal
    address agent;     // the only address permitted to call
    address vault;     // scope: this vault and no other
    uint256 cap;       // cumulative, in USDC units (6 dp)
    uint64  expiry;
    uint256 nonce;     // distinguishes otherwise-identical mandates
}
```

State is two mappings keyed by the EIP-712 struct hash: `spent` and `revoked`.

Revocation takes the full mandate, not its hash — `revoke(Mandate calldata m)`
recomputes the hash and requires `msg.sender == registry.ownerOf(m.agentId)`. A
bare `revoke(bytes32)` cannot be authorized at all, because the hash carries no
`agentId` to look an owner up from; since mandate hashes are public in calldata
after the first deposit, that version would let any third party revoke any
mandate.

Redemption runs checks 1 through 6 — everything except the cap, since
`vault.redeem(shares, principal, principal)` hard-codes the destination and no
value can leave the principal's control. Expiry *is* enforced on redemption: an
expired mandate ends the agent's authority in both directions, and the principal
can always redeem directly because they hold the shares, so they are never locked
out. The router must never pass an `owner` argument other than the derived
principal.

**Alternatives considered and why they lost:**

- *Wrapping ERC-4626* — would custody every Morpho share, contradicting the
  non-custody claim that keeps this out of fund territory; would make the router
  an omnibus account, moving per-principal attribution out of the operator's
  ledger and into ours, which is backwards for a product whose premise is
  extending the operator's existing KYC; and would strand funds behind our own
  redemption logic if we have a bug. It also introduces the only place where
  USDC's 6 decimals must be reconciled against 18-decimal shares.
- *Per-deposit cap* — loopable, so the effective limit collapses into the
  principal's ERC-20 allowance, which carries no expiry, no vault scoping, no
  agent identity, and nothing the operator can verify.
- *On-chain mandate registration* — costs the principal a transaction and
  discards the main ergonomic advantage of signing offline.

## Simplicity Case

- **Simplest complete design:** one stateless-by-construction router holding two
  mappings, verifying a signature against an ERC-721 owner lookup, calling
  `deposit`/`redeem` on a vault. No custody, no share math, no admin surface.
- **Added machinery:** `AllowlistedERC4626` is the only component beyond the
  minimum. It is paid for by a present requirement — the demo must show the vault
  itself rejecting an agent that skips the router, which is the load-bearing
  claim of the pitch and cannot be demonstrated by a permissionless vault.
  `spent` is paid for by the "cap actually binds" criteria; `revoked` by the
  Revocation criteria.
- **Deferred until measured:** net-position accounting (counter decrementing on
  redeem) is the more natural reading of "max amount" and better suits an agent
  that rebalances, but it needs a clamp against yield-inflated redemptions and
  permits unbounded churn. Trigger for reconsidering: the first mandate intended
  to live longer than a week, or the first user complaint about re-signing.
  Multi-vault mandates: trigger is a second vault operator signing on.
- **Complexity removed:** no share ledger, no exchange rate, no rounding-direction
  analysis, no donation/inflation-attack surface, no decimals conversion, no
  upgrade path, no owner, no pause, no fee logic, and no arbitrary-call function
  in a contract that holds user allowances.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Pass-through router, not a wrapping ERC-4626 | Preserves the non-custody claim; keeps the vault's ledger identical to the operator's KYC list; nothing is stranded if the router breaks; removes the decimals hazard entirely |
| 2 | Cumulative cap on total deposited per mandate | A per-deposit ceiling is loopable and degrades the safety property into an ERC-20 allowance |
| 3 | Redemption authorized by the same mandate, uncapped | Destination is hard-coded to the principal so no value can leak; revocation kills both directions at once; keeps "the agent controls timing" literally true |
| 4 | Principal derived via `registry.ownerOf(agentId)`, not carried in the mandate | Makes the ERC-8004 identity load-bearing rather than decorative; the signature must come from whoever owns the agent *now* |
| 5 | Mandate travels in calldata; no on-chain registration | Preserves offline signing; no extra principal transaction |
| 6 | `AllowlistedERC4626` over a real Morpho Blue market on Sepolia | No Morpho ERC-4626 exists on Base Sepolia (verified); authoring the gate earns the "vault rejects the agent" transaction |
| 7 | Registry and vault addresses are constructor parameters | The registry is live on Sepolia but unusable on Base mainnet (verified), so the two environments must differ by config, not by code |
| 8 | Fork tests deploy a minimal conformant registry; use the real vault | We consume exactly one registry function (`ownerOf`), so mocking it is zero-risk, whereas mocking a vault would hide the rounding behavior that matters |
| 9 | Custom errors carrying operands, e.g. `ExceedsMandate(remaining, attempted)` | The revert reason is the product; reporting headroom is more useful than echoing a static cap |
| 10 | Contracts + tests + demo script; no UI | Highest signal per hour against the Aug 22 date, and it foregrounds the revert reasons |
| 11 | Router is non-upgradeable, ownerless, with no arbitrary-call path | The router holds standing ERC-20 allowances; that blast radius is only acceptable if the code cannot change and cannot be steered |
| 12 | `revoke` takes the full `Mandate`, not its hash | A hash carries no `agentId`, so a hash-only revoke cannot be authorized; mandate hashes are public after the first deposit, making third-party revocation DoS trivial |
| 13 | `ECDSA.tryRecover` plus try/catch on `ownerOf` | Otherwise OZ and ERC-721 revert with their own errors and decision 9 silently fails; `tryRecover` additionally rejects malleable high-`s` signatures |
| 14 | Expiry is enforced on redemption as well as deposit | Expiry should mean the agent's authority ended, not merely that it cannot add; the principal holds the shares and can always exit directly, so nobody is locked out |

## Risks & Assumptions

Addresses below were verified by `eth_getCode` / `eth_call` against public RPCs on
2026-08-16, not taken from documentation or search results.

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | Morpho Blue market creation on Sepolia may be blocked — a market needs an enabled LLTV, an oracle and an IRM, and a supply-only market earns no yield. Blue is not an ERC-4626, so this means hand-written supply/withdraw accounting | Medium | Supply-side only; the demo needs correct accounting, not yield. Escape hatch with a wall-clock trigger: **if a usable USDC market is not supplying and withdrawing correctly by end of Day 1, take the hatch** — `AllowlistedERC4626` holds USDC idle and the Morpho integration lives only in the fork tests, which keeps the Vault mechanics criteria satisfiable and deletes the hand-rolled accounting entirely. The decision is a checkpoint, not a judgement call made under deadline pressure on Day 3 |
| 2 | The ERC-8004 registry is an ERC-1967 proxy and can be upgraded beneath us, changing `ownerOf` semantics | Low | Address is a constructor parameter and pinned per deployment; only one function is consumed; fork tests run against our own conformant instance |
| 3 | The principal grants the router **two** standing allowances — USDC for deposits and vault shares for redemption — and together they are the real blast radius, larger than any single mandate | Medium | Router is non-upgradeable, ownerless, has no arbitrary-call path, never transfers to any address other than the vault or the principal, and never passes an `owner`/`from` other than the derived principal. Criterion "cap binds below allowance" tests exactly this. Demo sets the USDC allowance equal to the mandate cap to show intended practice |
| 4 | Cumulative counter never decreases, so round trips permanently consume budget | Low | Documented limitation, not engineered around. An agent that deposits 500, redeems, and deposits 500 has spent 1,000 of its cap while never risking more than 500 |
| 5 | Signature replay across chains or deployments | Low | EIP-712 domain pins `chainId` and `verifyingContract`; `nonce` distinguishes otherwise-identical mandates |
| 6 | Reentrancy during `deposit`/`redeem` | Low | `nonReentrant` is **load-bearing here, not belt-and-braces — do not drop it.** Full checks-effects-interactions is not achievable: `registry.ownerOf` (step 4) is an external call to an upgradeable proxy and must precede the `spent` write, because budget may only be consumed after the signature is verified and the signer can only be known by asking the registry. What CEI we do have is that `spent` is written before the *vault* interaction |
| 9 | `spent`/`revoked` key on the mandate struct hash, which omits the owner, so state survives an `agentId` transfer: a prior owner's consumed budget carries into a byte-identical struct signed by a new owner, and a prior owner can pre-revoke structs they never signed | Low | Self-healing through `nonce` — mandates from different owners should not collide in practice. Documented rather than redesigned; revisit if agent NFTs turn out to change hands routinely |
| 7 | Principal key compromise defeats the entire design | High, accepted | Out of scope by construction. State it openly in the pitch rather than implying protection that does not exist |
| 8 | Sepolia USDC and gas needed on demo day | Low | Faucet in advance; pin the funded addresses in the deploy script |

**Verified facts**

- Base Sepolia (84532): ERC-8004 `AgentIdentity` live at
  `0x8004A818BFB912233c491871b3d84c89A494BD9e` — `supportsInterface(0x80ac58cd)`
  returns true and `ownerOf(1)` resolves. USDC at
  `0x036CbD53842c5426634e7929541eC2318f3dCF7e` (6 dp). Morpho Blue at
  `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`. **No vault factory**, therefore no
  Morpho ERC-4626 to deposit into.
- Base mainnet (8453): the same registry address is a proxy whose implementation
  differs from Sepolia's and whose calls revert — **do not depend on it**. Morpho
  Blue and the Vault V2 Factory (`0x4501125508079A99ebBebCE205DeC9593C2b5857`) are
  present, so real ERC-4626 vaults exist here and only here.
- Fork-test vault, pinned: Moonwell Flagship USDC (`mwUSDC`) at
  `0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca` on Base mainnet. Verified
  `asset() == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Base USDC, 6 dp),
  `decimals() == 18`, and roughly 9.6M USDC of `totalAssets`. This is the concrete
  target for the fork suite, and it is also live confirmation of the 6-versus-18
  decimals gap that decision 1 avoids having to reconcile.
- Corrected during research: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` has no
  code on Base Sepolia, and the Vault V2 Factory is mainnet-only. Both were
  asserted by web search and are wrong.

**Assumptions**

- The principal owns the ERC-8004 agent NFT; the agent's operating EOA is a
  separate address named in the mandate. If operators instead transfer the NFT to
  the agent, decision 4 inverts and must be revisited.
- The operator's real vault would gate on `receiver`, matching `AllowlistedERC4626`.

## Success Criteria

The fork suite runs against **two** vault targets, since no single vault proves
both halves: a real Morpho ERC-4626 on the Base mainnet fork shows the router
composes with production vault mechanics, and `AllowlistedERC4626` shows the gate.
The registry is our own minimal conformant instance in both cases.

### Authorization

- [ ] Invalid signature reverts `InvalidSignature` — our error, not OZ's `ECDSAInvalidSignature*`
- [ ] A malleable high-`s` signature is rejected rather than recovered
- [ ] An unminted `agentId` reverts `AgentNotRegistered` — our error, not `ERC721NonexistentToken`
- [ ] Caller other than `m.agent` reverts `NotAgent`, on deposit **and** redeem
- [ ] Mandate naming a different vault reverts `WrongVault`, on deposit **and** redeem
- [ ] Mandate past `expiry` reverts `MandateExpired`, on deposit **and** redeem
- [ ] **`agentId` transferred to a new owner: a previously valid mandate now reverts
      `InvalidSignature`** — the only test that proves deriving the principal from
      the registry (decision 4) is load-bearing rather than decorative

### Revocation

- [ ] After `revoke`, replaying the previously valid 500 reverts `MandateRevoked`
- [ ] **After `revoke`, redemption under the same mandate also reverts
      `MandateRevoked`** — decision 3 claims revocation kills both directions at
      once, and only this proves it
- [ ] **`revoke` called by anyone other than the current `ownerOf(agentId)` reverts** —
      without this, the authorization bug ships undetected behind a passing happy path

### The cap actually binds

- [ ] Valid mandate, 500 USDC: accepted, shares credited to the principal, router
      holding zero USDC and zero shares afterward
- [ ] With cap 1,000 and 500 spent, a 600 deposit reverts
      `ExceedsMandate(remaining: 500, attempted: 600)` — the case a per-deposit
      ceiling would wrongly allow
- [ ] A 5,000 deposit reverts `ExceedsMandate`
- [ ] **USDC allowance set to 10,000 against a cap of 1,000: loop deposits until
      rejection and assert total pulled from the principal never exceeds 1,000** —
      this is what falsifies risk 3, proving the mandate binds tighter than the
      allowance

### Containment

- [ ] Agent redeems: assets arrive at the principal, and the agent's USDC and share
      balances are both provably zero
- [ ] Across the entire suite, the agent address ends every test holding zero USDC
      and zero shares, and the router likewise — asserted as an invariant, not
      per-test, so the containment claim is proven rather than illustrated

### Vault mechanics

- [ ] Router deposits into `mwUSDC` (`0xc1256Ae5...A2Ca`) on the mainnet fork;
      shares are credited to the principal
- [ ] Deposit followed by immediate full redeem returns the principal's assets
      within a stated tolerance and leaves the router holding nothing — the
      rounding behavior that justifies testing against a real vault (decision 8).
      Assert a small explicit tolerance rather than exact equality: two rounding
      layers plus fee accrual on a live vault will not return the deposit to the
      wei, and a one-wei bound would be flaky
- [ ] Agent depositing straight to `AllowlistedERC4626` reverts `NotAllowlisted`

### Delivery

- [ ] Contracts deployed and verified on Base Sepolia
- [ ] `pnpm demo` runs the seven transactions end to end and prints each revert reason

## Next Step

After an independent design review returns SHIP, persist the evidence below and verify its content digest before running `wish`.

<!-- genie-design-review:start -->
## Design Review Evidence

- **Verdict:** SHIP
- **Reviewed content SHA-256:** `605bc0f428bd499590f0dc5a08cc0097fb94235ecf9a7e847324a80d8a303b73`
- **Reviewer:** a4415435943693213
- **Reviewed at:** 2026-08-16T19:59:31.000Z
<!-- genie-design-review:end -->
