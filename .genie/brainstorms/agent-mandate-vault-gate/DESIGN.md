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
- `MinimalIdentityRegistry` — test-only ERC-721 exposing `ownerOf`, used across the
  fork suite, where the real registry is unusable
- Signer-keyed revocation
- Cumulative spend accounting per (mandate, principal)
- Indexed events binding every action to mandate hash, an account — the derived
  principal on deposit and redeem, the revoking caller on revoke — and `agentId`
- Foundry suite against a Base mainnet fork
- Deployment to Base Sepolia plus a scripted eleven-transaction demo that prints every
  revert reason (enumerated under Delivery — the error surface is eight; the other
  three transactions never revert: the accepted deposit that sets up the cap test,
  the agent's redemption, and `revoke`)
- Custom errors throughout — the revert reason is the product surface

### OUT
- x402
- Reputation scoring
- Any actual LLM — the agent is a keypair driven by a script
- Multi-vault routing
- A web UI
- Upgradeability, pausing, admin roles, or fee collection in the router
- Net-position accounting (see Deferred)
- Any bound on the exit side beyond expiry and revocation — no exit cap, no
  cooldown, no share scoping (see Deferred; risks 11 and 12 state
  what that leaves open)

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
2. `m.target == address(vault)` else `WrongVault`
3. `block.timestamp <= m.expiry` else `MandateExpired`
4. `principal = registry.ownerOf(m.agentId)`, non-zero, else `AgentNotRegistered`
5. `(signer, err, ) = ECDSA.tryRecover(digest, sig)`; require `err == ECDSA.RecoverError.NoError && signer == principal` else `InvalidSignature`
6. `!revoked[key]` else `MandateRevoked`
7. `spent[key] + assets <= m.cap` else `ExceedsMandate(remaining, attempted)`

where `key = keccak256(abi.encode(mandateHash, principal))` — see decision 17.

Steps 4 and 5 must be written defensively or our custom errors never fire:
OpenZeppelin's `ECDSA.recover` reverts with `ECDSAInvalidSignature*` rather than
returning `address(0)`, and ERC-721 `ownerOf` reverts `ERC721NonexistentToken`.
Use `tryRecover` and wrap the `ownerOf` call in try/catch so the revert reason is
ours. `tryRecover` also rejects malleable high-`s` signatures. This lives once, in
the shared verifier described below, and therefore governs both entry points that
derive a principal — `depositFor` and `redeemFor`; `revoke` never calls the
registry at all. Note the try/catch has two gaps it cannot close: a registry
address with **no code** reverts in our own frame on Solidity's `extcodesize`
check before the call is made, and malformed return data fails to decode
uncatchably. Both are constructor-time and deployment-time concerns rather than
runtime ones — verify the address has code at deploy, per the verified-facts list.

In OpenZeppelin 5.x `tryRecover` returns `(address, ECDSA.RecoverError, bytes32)`,
so step 5 must destructure it and check the error member. The enum is declared
inside `library ECDSA` and must be written qualified — `using ECDSA for bytes32`
brings in the functions, not the type name. Taking the address alone
compiles to `address(0)` on a malformed signature, and risk 2 makes that reachable:
a non-conformant registry implementation returning `address(0)` from `ownerOf`
instead of reverting would then satisfy step 5 against garbage. Step 4's try/catch
therefore also rejects a zero principal, with `AgentNotRegistered`.

Steps 1 through 6 live in **one shared internal verifier** called by both
`depositFor` and `redeemFor`, which is why the criteria below name only some
errors "on deposit **and** redeem" — those are the ones worth double-siting to
prove the sharing is real, not an admission that the others differ.

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
    address target;    // scope: this contract and no other; a vault in v0.1
    uint256 cap;       // cumulative, in USDC units (6 dp)
    uint64  expiry;
    uint256 nonce;     // distinguishes otherwise-identical mandates
}
```

The field is `target`, not `vault`, because it is the one part of this design that
cannot be changed later for free: it is inside the EIP-712 typehash, so renaming
it after any mandate has been signed invalidates every outstanding signature.
Nothing else about v0.1 changes — the router still requires `m.target` to equal
its single configured vault, and the error is still `WrongVault`. Error names are
not signed and can be generalized at any redeploy.

Three external functions — plus the getters on the two `public` mappings
described below, which are the only other surface — and the literal type string
and domain arguments the demo script must reproduce byte-for-byte to produce a
signature the router accepts:

```solidity
function depositFor(Mandate calldata m, bytes calldata sig, uint256 assets)
    external returns (uint256 shares);
function redeemFor(Mandate calldata m, bytes calldata sig, uint256 shares)
    external returns (uint256 assets);
function revoke(Mandate calldata m) external;
```

```
Mandate(uint256 agentId,address agent,address target,uint256 cap,uint64 expiry,uint256 nonce)
```

```solidity
constructor(...) EIP712("MandateRouter", "1")
```

The type string and the domain arguments are written out here rather than left to
the implementation because decision 15 makes them the artifacts that cannot change
after the first signature, and because a mismatch anywhere in them surfaces only as
`InvalidSignature` — indistinguishable from a genuinely bad signature, and the
hardest failure in this design to debug under deadline. `_hashTypedDataV4` folds in
the domain separator, so the demo script must reproduce `name`, `version`,
`chainId` and `verifyingContract` exactly; the last two come free from the
deployment, but the first two are byte-sensitive strings that the contract and the
script would otherwise pick independently.

`mandateHash` throughout this document means the EIP-712 **digest** —
`_hashTypedDataV4(hashStruct(m))`, the same value recovered against in step 5, not
the bare struct hash. It is already computed for the signature check so it costs
nothing extra, and the digest binds the storage key to `chainId` and
`verifyingContract`, extending risk 5's replay protection from the signature to
the state keyed by it.

State is two public mappings, `spent` and `revoked`, keyed by
`keccak256(abi.encode(mandateHash, account))` rather than by the mandate hash
alone. The mandate struct omits the principal by design (decision 4), so a hash key
alone lets state written under one owner of an `agentId` bind a byte-identical
mandate signed by a later owner. Binding the key to an account means consumed
budget belongs to the owner who spent it and revocations belong to the signer who
issued them.

`account` is the **derived principal everywhere the mappings are read**, and
`msg.sender` on the single `revoked` write. `spent` uses the derived principal on
both sides. `revoked` is the asymmetric one, and that asymmetry is the whole
mechanism — read it at `msg.sender` and the kill switch is permanently inert, since
step 1 has already forced `msg.sender == m.agent` on the paths that read it, while
the legitimate revoker — who is the principal — wrote under their own address.

`spent` is keyed on the derived principal, since only the current owner can sign a
mandate that verifies at all. `revoked` is keyed on **`msg.sender`**, with no
ownership check on the call:

```solidity
revoked[keccak256(abi.encode(mandateHash, msg.sender))] = true;
```

That looks unauthenticated and is not. The deposit path reads
`revoked[keccak256(abi.encode(mandateHash, principal))]` with `principal` derived
from the registry, and step 5 independently forces the recovered signer to equal
that same principal. An entry written by anyone who did not sign the mandate
therefore sits at a key no path ever reads. Third-party revocation DoS — the
concern behind decision 12 — is prevented by the key binding rather than by a gate.

Dropping the gate is what makes revocation reliable rather than merely present. A
gate of `msg.sender == registry.ownerOf(m.agentId)` means a principal who has
transferred the `agentId` away can no longer revoke a signature they themselves
produced: their key is `(hash, them)`, but they are no longer the owner, so the
call reverts — while the current owner's revocation writes a different key. If the
`agentId` ever comes back, that old mandate goes live again against a still-standing
allowance, with no point in the interim at which anybody could have killed it.
Keying on the caller also takes `registry.ownerOf` off the emergency path, so
revocation still works when the registry proxy is bricked (risk 2) or the agent NFT
has been burned.

`revoked` is one-way. There is no un-revoke, so a signer who revokes and later
wants the same terms must sign a fresh `nonce` — the entry at `(hash, them)` is
permanent. This is the second concrete job the `nonce` field does.

Revocation still takes the full mandate rather than its hash —
`revoke(Mandate calldata m)` recomputes the digest itself. Authorization is no
longer the reason, since the key now carries it. The reason is that recomputing
beats trusting caller-supplied bytes: under `msg.sender` keying, a mis-derived hash
writes `revoked[(wrongHash, you)]`, which reverts nothing and emits a log that looks
correct — a silent no-op, the worst available failure mode for a kill switch.
Recomputing on-chain eliminates that class of error, though not all of it: passing
a wrong `nonce` or `expiry` still silently revokes nothing, and decision 5 leaves no
on-chain mandate record to check the struct against. The full struct also lets the
event echo an `agentId`, but see below — nothing validates that field.

**Events.** Every state-changing path emits an indexed record binding the action to
the mandate, an account — the derived principal on `Deposited` and `Redeemed`, the
revoking caller on `Revoked` — and the agent identity:

```solidity
event Deposited(
    bytes32 indexed mandateHash,
    address indexed principal,
    uint256 indexed agentId,
    address agent,
    uint256 assets,
    uint256 shares,
    uint256 spentTotal
);
event Redeemed(
    bytes32 indexed mandateHash,
    address indexed principal,
    uint256 indexed agentId,
    address agent,
    uint256 shares,
    uint256 assets
);
event Revoked(
    bytes32 indexed mandateHash,
    address indexed revoker,
    uint256 indexed agentId
);
```

The event is `Revoked`, not `MandateRevoked` — that name is already taken by the
custom error, and Solidity will not accept both in one contract.

**`Revoked` is the one log that is not attribution.** Its second field is
`revoker`, not `principal`, because `revoke` performs no registry lookup — that is
the point of keying on the caller — so `msg.sender` is the only address it can
honestly emit. Its `agentId` topic is caller-supplied and unvalidated: nothing checks that the
`agentId` exists or that it relates to the caller. Its `mandateHash` is *recomputed*
by the router from the caller's struct, so it is not free-form — an attacker can
only emit a digest for a mandate whose fields they hold in full, and the emitted
`agentId` is necessarily the one inside that digest's preimage, so the pair is
always self-consistent. In particular nobody can lift a `mandateHash` topic out of a
public `Deposited` log and re-emit it as a revocation. Anyone *holding* a mandate —
the agent, for one — can emit `Revoked(thatDigest, themselves, thatAgentId)` for the
cost of the gas. On-chain that is harmless: the entry lands at a key no path reads.
Off-chain, an indexer subscribed by `agentId` topic, which decision 16 makes the
natural subscription, can be shown a revocation for any mandate the attacker has
seen.

Consumption rule: **a `Revoked` log is authoritative only for mandates whose
recovered signer equals `revoker`.** The indexer already holds the mandate and the
signature it was issued with — a struct alone yields only a digest — so it can
recover the signer itself and discard the rest. Treat the `agentId` topic as an
indexing hint, never as attribution. The alternative — deriving the principal
inside `revoke` purely so the event can carry it — is rejected: it puts
`registry.ownerOf` back on the emergency path and forfeits revocation-when-bricked.

`mandateHash` is emitted rather than the storage key so an off-chain indexer can
match a log against a mandate it holds without re-deriving ownership; the account
is carried alongside it, so the pair reconstructs the key. `spentTotal`
is the post-increment value, which lets an indexer report remaining headroom
without replaying history. `agentId` is indexed rather than the agent EOA because
the NFT is the durable identity and the operating key is not.

Redemption runs checks 1 through 6 — everything except the cap. The cap is
skipped not because the exit side is safe but because no quantity bound separates
a forced exit from a legitimate one (decision 3). Hard-coding
`vault.redeem(shares, principal, principal)` defeats theft, not grief. Expiry *is* enforced on redemption: an
expired mandate ends the agent's authority in both directions, and the principal
can always redeem directly because they hold the shares, so they are never locked
out. The router must never pass an `owner` argument other than the derived
principal.

`cap` is a deposit-side instrument only. Within a live mandate the exit side is
bounded by nothing but the share allowance — the agent chooses when and how much
to exit, repeatedly. Hard-coding the destination makes that unprofitable rather
than impossible, which is the honest claim; expiry and revocation are the only
things that end it. Risks 11 and 12 state the residue, and the Simplicity Case
records the two candidate bounds and what would trigger building them.

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
- *A signed `exitCap`, mirroring `cap` on the redemption side* — the obvious
  answer to risk 11 and the wrong one. It is the only exit-side bound that sits
  inside the typehash, so unlike the deferred alternatives it is cheap *only*
  today; and it is denominated in USDC while the thing it limits is a position
  that earns, so it decays against its own subject. A 1,000 exit cap on a
  position grown to 1,100 leaves the agent unable to exit 9% of it — authority
  shrinking exactly as the strategy works. It also cannot be charged without
  pricing shares in assets — `previewRedeem` supplies that figure pre-interaction,
  so `redeem` need not be abandoned, but either way the bound then depends on the
  vault's preview rounding and reintroduces the asset/share reconciliation that
  decision 1 exists to remove. Counting shares is **not** a substitute: it bounds
  which shares a mandate may touch (risk 12), not how much may leave, and by
  decision 3 nothing bounds the latter. Share counting carries no signed field and
  no decay, which is why it is deferred rather than dismissed.

## Simplicity Case

- **Simplest complete design:** one stateless-by-construction router holding two
  mappings, verifying a signature against an ERC-721 owner lookup, calling
  `deposit`/`redeem` on a vault. No custody, no share math, no admin surface.
- **Added machinery:** `AllowlistedERC4626` is the only component beyond the
  minimum. It is paid for by a present requirement — the demo must show the vault
  itself rejecting an agent that skips the router, which is the load-bearing
  claim of the pitch and cannot be demonstrated by a permissionless vault.
  `spent` is paid for by the "cap actually binds" criteria; `revoked` by the
  Revocation criteria. Events (decision 16) are paid for first by irreversibility —
  logs cannot be backfilled onto transactions that already happened, and
  per-transaction attribution is the unit the business model is priced in — and
  second by the four Events criteria. Keying state on `(mandateHash, account)`
  (decision 17) adds one `keccak256` per call and no new storage or durable state;
  it does change the revocation recovery path, and decision 12 argues that change
  is an improvement.
- **Deferred until measured:** net-position accounting (counter decrementing on
  redeem) is the more natural reading of "max amount" and better suits an agent
  that rebalances, but it needs a clamp against yield-inflated redemptions and
  permits unbounded churn. Trigger for reconsidering: the first mandate intended
  to live longer than a week, or the first user complaint about re-signing.
  Multi-vault mandates: trigger is a second vault operator signing on.
  **Exit cooldown** — `mapping(bytes32 => uint64) lastExit` plus
  `error ExitCooldown(uint64 secondsRemaining)`, checked after step 6 and before
  the vault call — is the only candidate that attacks risk 11 on the axis that
  actually separates grief from strategy. Deferred because it is pure router
  state with a constant interval: nothing about it touches the typehash, so it
  costs exactly the same to add later, and it buys a real cost today by blocking
  a legitimate stop-loss inside the window. Trigger, measured off logs the design
  already emits: the first `Redeemed` followed by a `Deposited` under the same
  mandate key inside one hour, or the first operator who asks what stops churn.
  Note when building it that keying `lastExit` like `spent` — on
  `keccak256(abi.encode(mandateHash, principal))` — lets two live mandates for the
  same agent halve the effective interval, so a frequency bound may honestly
  belong at `(principal, agent)` instead. **Share scoping** — counting
  `sharesMinted` on deposit against `sharesBurned` on redeem, on the derived
  principal for read and write — bounds risk 12 and
  is yield-correct by construction, since a share inflates in value rather than
  in quantity, which is exactly what defeats a USDC-denominated exit cap.
  Also pure router state, also free to add later. This one is an unconditional
  v0.2 item rather than a triggered deferral, because the obvious trigger — a
  principal holding vault shares from any source other than this mandate — is
  guaranteed by the document's own workflow: decision 2 bumps the budget by
  signing a fresh `nonce`, and so does re-authorizing after a revoke, each of
  which leaves shares minted under a predecessor. That same fact leaves the key
  itself open, and it must be settled before building: scoping the counters per
  mandate — the natural reading, and how `spent` is keyed — would strand the
  position a re-signed mandate is meant to keep managing, so the honest key is
  probably `(principal, agent)`, or else a successor mandate must inherit its
  predecessor's count. Both deferrals are cheap *because* they are unsigned; the
  exit-side option that is not — a signed `exitCap` — is rejected outright under
  Alternatives.
- **Complexity removed:** no share ledger (a share *counter* is deferred above,
  which is a different and much smaller thing), no exchange rate, no rounding-direction
  analysis, no donation/inflation-attack surface, no decimals conversion, no
  upgrade path, no owner, no pause, no fee logic, and no arbitrary-call function
  in a contract that holds user allowances.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Pass-through router, not a wrapping ERC-4626 | Preserves the non-custody claim; keeps the vault's ledger identical to the operator's KYC list; nothing is stranded if the router breaks; removes the decimals hazard entirely |
| 2 | Cumulative cap on total deposited per (mandate, principal) | A per-deposit ceiling is loopable and degrades the safety property into an ERC-20 allowance. The cap binds the *agent*, not the principal: a principal can reset their own counter by moving the `agentId` to a second address they control and re-signing, but that needs both an NFT transfer and a fresh signature, so the agent cannot do it alone — and a principal who wants a bigger budget can simply sign a new nonce anyway |
| 3 | Redemption authorized by the same mandate, uncapped | Hard-coding the destination to the principal defeats *theft* — no value can leave the principal's control — but it does not bound *grief*, and the rationale must not be read as if it did: whoever holds the agent key can force-exit the position repeatedly within the mandate's life. That is accepted for v0.1 rather than solved, because no bound on **quantity** separates a forced exit from a legitimate one — on-chain they are the same transaction and the contract has no access to intent. The axis that separates them is frequency (see Deferred). The real exit-side limits are expiry and revocation, each of which ends both directions in one call; risks 11 and 12 carry the residue |
| 4 | Principal derived via `registry.ownerOf(agentId)`, not carried in the mandate | Makes the ERC-8004 identity load-bearing rather than decorative; the signature must come from whoever owns the agent *now* |
| 5 | Mandate travels in calldata; no on-chain registration | Preserves offline signing; no extra principal transaction |
| 6 | `AllowlistedERC4626` over a real Morpho Blue market on Sepolia, gating with an explicit `revert NotAllowlisted(receiver)` rather than via `maxDeposit` | No Morpho ERC-4626 exists on Base Sepolia (verified); authoring the gate earns the "vault rejects the agent" transaction. The gate must be an override of `deposit`/`mint` that reverts **before** calling into the inherited implementation: OZ 5.x `ERC4626.deposit` checks `maxDeposit(receiver)` first and reverts `ERC4626ExceededMaxDeposit`, so expressing the allowlist by returning 0 from `maxDeposit` — the spec-compliant way — makes `NotAllowlisted` unreachable and silently kills the demo's closing transaction. `maxDeposit` may return 0 as well for conformance, but must not be the mechanism that produces the revert reason. Same hazard, same fix as decision 13 |
| 7 | Registry and vault addresses are constructor parameters | The registry is live on Sepolia but unusable on Base mainnet (verified), so the two environments must differ by config, not by code |
| 8 | Fork tests deploy a minimal conformant registry; use the real vault | We consume exactly one registry function (`ownerOf`), so mocking it is zero-risk, whereas mocking a vault would hide the rounding behavior that matters |
| 9 | Custom errors carrying operands, e.g. `ExceedsMandate(remaining, attempted)` | The revert reason is the product; reporting headroom is more useful than echoing a static cap |
| 10 | Contracts + tests + demo script; no UI | Highest signal per hour against the Aug 22 date, and it foregrounds the revert reasons |
| 11 | Router is non-upgradeable, ownerless, with no arbitrary-call path | The router holds standing ERC-20 allowances; that blast radius is only acceptable if the code cannot change and cannot be steered |
| 12 | `revoke` takes the full `Mandate`, not its hash, and is keyed on `msg.sender` with no ownership gate | Third-party DoS is prevented by the key binding, not by a gate: an entry written by a non-signer sits where no path reads. An ownership gate would strand a past signer who transferred the `agentId` and can no longer revoke their own signature. Passing the full struct keeps the three entry points symmetric and lets the router recompute the digest rather than trust caller-supplied bytes, which is what stops a mis-derived hash from silently revoking nothing. It also lets the event echo the caller's `agentId` for convenience — but nothing validates that field, so it is an indexing hint, not attribution |
| 13 | `ECDSA.tryRecover` plus try/catch on `ownerOf` | Otherwise OZ and ERC-721 revert with their own errors and decision 9 silently fails; `tryRecover` additionally rejects malleable high-`s` signatures |
| 14 | Expiry is enforced on redemption as well as deposit | Expiry should mean the agent's authority ended, not merely that it cannot add; the principal holds the shares and can always exit directly, so nobody is locked out. This is load-bearing beyond tidiness: with the exit side otherwise unbounded, expiry and revocation are risk 11's only two limits, which is why the operating guidance there is short expiries |
| 15 | Mandate field is `target`, not `vault` | The field sits inside the EIP-712 typehash, the only part of this design that cannot be changed for free later — renaming it after the first signature invalidates every outstanding mandate. Costs nothing today; behaviour in v0.1 is unchanged |
| 16 | Indexed events on deposit, redeem and revoke | An attributable record binding action to mandate hash, account and `agentId` cannot be backfilled after the fact; per-transaction attribution is a stated requirement of the business model and there is no other source for it. `Deposited` and `Redeemed` carry the derived principal and are attribution; `Revoked` carries the caller and is not — see the consumption rule under Events |
| 17 | `spent`/`revoked` keyed on `keccak256(abi.encode(mandateHash, account))` — `spent` on the derived principal for both read and write, `revoked` **written** at `msg.sender` and **read** at the derived principal — where `mandateHash` is the EIP-712 digest | The mandate omits the principal (decision 4), so a hash-only key lets one owner's consumed budget bind a later owner's byte-identical mandate, and lets a prior owner pre-revoke structs they never signed. Using the digest rather than the struct hash extends risk 5's chain/deployment pinning from the signature to the state. The `spent`/`revoked` split in `account` is decision 12 |

## Risks & Assumptions

Addresses below were verified by `eth_getCode` / `eth_call` against public RPCs on
2026-08-16, not taken from documentation or search results.

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | Morpho Blue market creation on Sepolia may be blocked — a market needs an enabled LLTV, an oracle and an IRM, and a supply-only market earns no yield. Blue is not an ERC-4626, so this means hand-written supply/withdraw accounting | Medium | Supply-side only; the demo needs correct accounting, not yield. Escape hatch with a wall-clock trigger: **if a usable USDC market is not supplying and withdrawing correctly by end of Day 1, take the hatch** — `AllowlistedERC4626` holds USDC idle and the Morpho integration lives only in the fork tests, which keeps the Vault mechanics criteria satisfiable and deletes the hand-rolled accounting entirely. The decision is a checkpoint, not a judgement call made under deadline pressure on Day 3 |
| 2 | The ERC-8004 registry is an ERC-1967 proxy and can be upgraded beneath us, changing `ownerOf` semantics | Low | Address is a constructor parameter and pinned per deployment; only one function is consumed; fork tests run against our own conformant instance |
| 3 | The principal grants the router **two** standing allowances — USDC for deposits and vault shares for redemption — and together they are the real blast radius, larger than any single mandate | Medium | Both legs: router is non-upgradeable, ownerless, has no arbitrary-call path, never transfers to any address other than the vault or the principal, and never passes an `owner`/`from` other than the derived principal. **USDC leg** is bounded inside the mandate by `cap`, and the loop-until-rejection criterion under "The cap actually binds" proves the mandate binds tighter than the allowance; demo sets the USDC allowance equal to the cap to show intended practice. **Share leg** must also be approved before demo transaction 2, equal to the position transaction 1 creates and no more — the router calls `vault.redeem(shares, principal, principal)` with `msg.sender != owner`, so OZ's `_spendAllowance` runs and an unapproved redeem reverts `ERC20InsufficientAllowance`, an OZ error in the one script whose premise is that every revert reason is ours. That leg is **bounded by nothing inside the mandate** — risks 11 and 12 — so its only limits are expiry, revocation, and operating guidance: approve shares up to the position the agent is meant to manage, never `type(uint256).max` |
| 4 | The `(mandate, principal)` counter never decreases, so round trips permanently consume budget | Low alone, compounding with 11 | Documented limitation, not engineered around. An agent that deposits 500, redeems, and deposits 500 has spent 1,000 of its cap while never risking more than 500. Benign when the round trips are the agent's own strategy; risk 11 is the case where they are not |
| 5 | Signature replay across chains or deployments | Low | EIP-712 domain pins `chainId` and `verifyingContract`; `nonce` distinguishes otherwise-identical mandates |
| 6 | Reentrancy during `deposit`/`redeem` | Low | `nonReentrant` is **load-bearing here, not belt-and-braces — do not drop it.** Full checks-effects-interactions is not achievable: `registry.ownerOf` (step 4) is an external call to an upgradeable proxy and must precede the `spent` write, because budget may only be consumed after the signature is verified and the signer can only be known by asking the registry. What CEI we do have is that `spent` is written before the *vault* interaction |
| 7 | Principal key compromise defeats the entire design | High, accepted | Out of scope by construction. State it openly in the pitch rather than implying protection that does not exist |
| 8 | Sepolia USDC and gas needed on demo day | Low | Faucet in advance; pin the funded addresses in the deploy script |
| 9 | `spent`/`revoked` state surviving an `agentId` transfer: a prior owner's consumed budget carrying into a byte-identical struct signed by a new owner, and a prior owner pre-revoking structs they never signed | Closed | Fixed rather than documented — decision 17 keys both mappings on `keccak256(abi.encode(mandateHash, account))`: `spent` on the principal derived at call time, `revoked` written at `msg.sender` and read at the derived principal. State written under one account cannot be read under another. Previously rated Low on the assumption that `nonce` hygiene made collisions unlikely; that mitigation lived in client code, not the contract |
| 10 | A standing mandate outliving the `agentId` transfer that was supposed to end it | Low | Would be Medium under an ownership-gated `revoke`, which strands a past signer who can no longer revoke their own signature. Decision 12 writes `revoked` at `msg.sender` instead, so the signer can always withdraw their authorization regardless of who owns the NFT now. Operating guidance stands anyway: revoke and zero both allowances before transferring an `agentId` |
| 11 | **The exit side is uncapped, so the agent key can force-exit the position repeatedly** — costing yield, gas, and, through risk 4's monotonic counter, deposit budget that re-entry can no longer pay for. Grief on the exit side therefore strands the mandate on the entry side | Medium, accepted | Not solved in v0.1, and decision 3 no longer claims otherwise. Bounded by expiry and killed by revocation, each one call, so the exposure is the mandate's life and never the principal's funds — the destination is hard-coded, so an attacker pays gas to move the principal's money into the principal's own wallet. Not bounded within that window, and no cap can be: forcing an exit and exiting on a risk decision are the same transaction. Operating guidance is short expiries. The fix is a frequency bound, not a value bound — see Deferred. **State this in the pitch alongside risk 7 rather than letting it be discovered** |
| 12 | **A mandate does not scope the agent to the position it created.** `redeem` names the derived principal as `owner`, so shares the principal holds from a direct deposit or from a second mandate are reachable by any mandate that verifies | Medium | The only bound is the share allowance of risk 3 — which carries no expiry, no per-mandate scoping and no agent identity, i.e. exactly the criticism this design levels at wallet-side guardrails, reappearing on the exit side. Operating guidance until it is fixed: approve shares to the router only up to the position the agent is meant to manage, never `type(uint256).max`. The criterion under Containment pins the current behaviour so the gap is proven rather than assumed. The fix is counting shares minted under the mandate's authority; what that counter should be keyed on is itself an open question — see Deferred |

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
- The principal is an EOA. A smart-contract account whose authority is code rather
  than a key cannot produce an ECDSA signature that recovers to its own address, so
  step 5 can never pass for one: ERC-1271 and ERC-4337 principals are out of scope
  for v0.1, which is a real gap in the institutional KYC setting this product
  targets. EIP-7702 accounts work unmodified:
  delegation sets code on the account but leaves the key, so recovery on the digest
  still returns the account's own address and step 5 passes. `revoke` is unaffected
  for the separate reason that it only reads `msg.sender`.

## Success Criteria

The fork suite runs against **two** vault targets, since no single vault proves
both halves: a real Morpho ERC-4626 on the Base mainnet fork shows the router
composes with production vault mechanics, and `AllowlistedERC4626` shows the gate.
The registry is our own `MinimalIdentityRegistry` in both cases — conformant by
default, with a deliberately non-conformant variant used only by the `address(0)`
criterion below.

### Authorization

- [ ] Invalid signature reverts `InvalidSignature` — our error, not OZ's `ECDSAInvalidSignature*`
- [ ] A malleable high-`s` signature is rejected rather than recovered
- [ ] A registry returning `address(0)` from `ownerOf` instead of reverting yields
      `AgentNotRegistered`, not a pass against a zero principal — reachable via a
      stub on `MinimalIdentityRegistry`, which decision 8 already has us shipping
- [ ] An unminted `agentId` reverts `AgentNotRegistered` — our error, not
      `ERC721NonexistentToken` — on deposit **and** redeem, since only a
      redeem-sited test proves `redeemFor` actually calls the shared verifier
- [ ] Caller other than `m.agent` reverts `NotAgent`, on deposit **and** redeem
- [ ] Mandate whose `target` is not this vault reverts `WrongVault`, on deposit **and** redeem
- [ ] Mandate past `expiry` reverts `MandateExpired`, on deposit **and** redeem
- [ ] **`agentId` transferred to a new owner: a previously valid mandate now reverts
      `InvalidSignature`** — the only test that proves deriving the principal from
      the registry (decision 4) is load-bearing rather than decorative

### Revocation

- [ ] After the **principal** calls `revoke`, replaying the previously valid 500
      reverts `MandateRevoked`
- [ ] **After the principal's `revoke`, redemption under the same mandate also
      reverts `MandateRevoked`** — decision 3 claims revocation kills both
      directions at once, and only this proves it
- [ ] **A third party calls `revoke` on a mandate they did not sign; the owner's
      deposit under that mandate still succeeds** — the DoS decision 12 must not
      permit. Tests the property rather than the gate, since there is no gate
- [ ] **The signer revokes after transferring the `agentId` away, and the mandate is
      still dead when the `agentId` returns to them** — the case an ownership-gated
      `revoke` cannot express at all, and the reason decision 12 writes at
      `msg.sender`
- [ ] **A third party who holds the mandate — the agent — calls `revoke` passing the
      victim's real mandate in full: the emitted `Revoked` carries the attacker as
      `revoker`, on the victim's real `agentId` topic, with a `mandateHash` equal to
      the live mandate's digest, and the owner's deposit still succeeds** — with the
      digest identical, the deposit can only succeed because of the key binding, and
      the log can only be discarded by recovering the signer. Any variant that
      changes the digest passes for the wrong reason and isolates nothing. This is
      the case the consumption rule under Events exists for

### State isolation across ownership

Both criteria below require owner B to be allowlisted in `AllowlistedERC4626`,
funded with USDC, and to have approved the router — the `agentId` transfer re-keys
router state but carries no KYC, so the operator must have underwritten B
independently. Neither test may warp past `expiry` between A's activity and B's,
since a byte-identical struct fixes the expiry.

- [ ] **Owner A spends 800 of a 1,000 cap, `agentId` transfers to owner B, B signs a
      byte-identical mandate and deposits 1,000: accepted** — under a hash-only key
      this reverts `ExceedsMandate(remaining: 200, ...)`, charging B for A's spending
- [ ] **A revokes, `agentId` transfers to B, B signs a byte-identical struct: B's
      deposit is accepted** — A's revocation is a withdrawal of A's signature, not a
      permanent blacklisting of a byte pattern. B has issued a fresh authorization
      with their own key

### Events

- [ ] All three events emit `mandateHash` equal to `_hashTypedDataV4(hashStruct(m))`
      — the digest, asserted against an independently computed value, not against
      however the contract happens to compute it
- [ ] `Deposited` and `Redeemed` carry the **derived** `principal` and the `agentId`
      in their indexed positions
- [ ] `Revoked` carries `revoker == msg.sender` and echoes `agentId` from calldata
      unvalidated — asserting the caller, not a derived principal, so no future
      change reintroduces a registry lookup into `revoke` to satisfy this test
- [ ] `Deposited.spentTotal` equals the post-increment cumulative figure, so
      `cap - spentTotal` reproduces the `remaining` that `ExceedsMandate` reports

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
      and zero shares, and the router likewise — asserted centrally rather than
      restated per test, so the containment claim is proven rather than
      illustrated. Forge has `setUp()` and `afterInvariant()` but no per-test
      teardown, so the mechanism is a `containment` modifier declared on the base
      test contract and applied to every test function. This holds only if the
      suite never deals USDC to the agent, which in turn requires decision 6's
      explicit `NotAllowlisted` revert to fire before any `transferFrom`
- [ ] After `agentId` transfers to a new owner, the prior owner still redeems their
      existing shares directly from the vault — losing the agent's authority never
      costs a principal access to their own position, which holds by construction
      only because the router never custodies
- [ ] **The principal deposits directly into the vault, never touching the router;
      the agent then redeems those shares under a mandate signed by that same
      principal under a different `nonce`, through which no deposit has ever been
      routed — so a `sharesMinted` counter under it would read zero — and it is
      accepted, assets arriving at the principal** — pins risk 12 as a proven
      property rather than an assumption. The mandate must be the same principal's:
      under a different owner's mandate the derived principal differs and `redeem`
      would burn that other owner's shares, which tests nothing. Written to pass
      today so that adding a `sharesMinted` bound later has a test to invert, not a
      paragraph to reinterpret

### Vault mechanics

- [ ] Router deposits into `mwUSDC` (`0xc1256Ae5...A2Ca`) on the mainnet fork;
      shares are credited to the principal
- [ ] Deposit followed by immediate full redeem returns the principal's assets
      within a stated tolerance and leaves the router holding nothing — the
      rounding behavior that justifies testing against a real vault (decision 8).
      Assert a small explicit tolerance rather than exact equality: two rounding
      layers plus fee accrual on a live vault will not return the deposit to the
      wei, and a one-wei bound would be flaky
- [ ] Agent calling `AllowlistedERC4626.deposit(assets, agent)` reverts
      `NotAllowlisted(agent)` — the receiver must be the agent, since the gate is on
      `receiver` and `deposit(assets, principal)` from the agent's key succeeds

### Delivery

- [ ] Contracts deployed and verified on Base Sepolia
- [ ] `pnpm demo` runs these eleven transactions end to end and prints each revert
      reason — eight errors plus three that do not revert. Enumerated rather than
      counted, because the count has drifted twice already and there is no other
      place the discrepancy would surface:

      1. deposit 500 → accepted, `Deposited`
      2. agent redeems the position → accepted, `Redeemed`, assets arrive at the
         **principal** and the agent's balances stay zero, while `spent` is
         unchanged — as transaction 3 then proves. The exit path is the half of the product an operator will ask about
         first, and it demonstrates decision 3, risk 4's monotonic counter and the
         containment claim in one transaction. It also exercises the share
         allowance, the second of risk 3's two, which nothing else in the demo
         touches
      3. deposit 600 against remaining 500 → `ExceedsMandate(500, 600)` — the
         arithmetic is unaffected by transaction 2 precisely because the counter
         never decreases
      4. caller is not `m.agent` → `NotAgent`
      5. `m.target` is not this vault → `WrongVault`
      6. mandate signed with a past `expiry` → `MandateExpired`
      7. unminted `agentId` → `AgentNotRegistered`
      8. tampered signature → `InvalidSignature`
      9. **the principal** calls `revoke` → emits `Revoked` and **does not revert**
         — a transaction that succeeds silently, which the script should say
         out loud rather than leave looking like a missing case. The caller matters:
         the write lands at `(digest, msg.sender)` and the deposit path reads at
         `(digest, principal)`, so revoking from the agent's key would leave
         transaction 10 quietly succeeding
      10. replay the previously valid 500 → `MandateRevoked`
      11. agent calls `AllowlistedERC4626.deposit(assets, agent)` directly →
          `NotAllowlisted(agent)`. The receiver is the point: the gate is on
          `receiver`, so an agent calling `deposit(assets, principal)` would
          succeed and prove nothing

## Next Step

After an independent design review returns SHIP, persist the evidence below and verify its content digest before running `wish`.

<!-- genie-design-review:start -->
## Design Review Evidence

- **Verdict:** SHIP
- **Reviewed content SHA-256:** `2be9b1d37190ed9425379c36c2ebe0c9f81e0fe736adefc86d224a24b1c13d52`
- **Reviewer:** a21da1bfaf59c65b4
- **Reviewed at:** 2026-08-17T23:21:45.000Z
<!-- genie-design-review:end -->
