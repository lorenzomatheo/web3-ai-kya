# DRAFT — Agent Mandate Vault Gate

Status: Raw · WRS 60/100

## Problem

Gated vaults have KYC'd the human principal but cannot accept deposits initiated by
that human's AI agent, because the agent's address carries no verifiable relationship
to the approved principal. The missing primitive is an on-chain proof that *this
address acts for that approved principal, within limits the principal signed*.

## Scope

### IN
- EIP-712 `Mandate` signed offline by the principal (agentId, vault, cap, expiry, nonce)
- On-chain verification path: ERC-8004 agent ownership lookup → signature recovery →
  scope checks (vault match, cap, expiry, revocation)
- Deposit path where shares land with the principal, never the agent
- Redemption path returning assets to the principal, never the agent
- Principal-initiated revocation
- Five-transaction demo on Base Sepolia
- Custom errors as the primary UX surface — the revert reason is the product

### OUT (explicitly cut)
- x402
- Reputation scoring
- An actual LLM (the "agent" is a keypair driven by a script)
- Multi-vault routing

## Decisions

Settled from the brief:
- EIP-712 typed-data mandate, signed offline by the principal — no on-chain
  registration step, mandate + signature travel in deposit calldata
- ERC-8004 IdentityRegistry is the source of truth for agent → owner
- Custom errors, not bare `require`
- Develop against forked Base mainnet; deploy demo to Base Sepolia
- Funds originate from the principal's wallet via ERC-20 allowance to the router.
  This is what produces the containment property: a compromised agent key can only
  move the principal's money into and out of the principal's own positions.

**Custody: pass-through router, not a wrapping ERC-4626.** The contract
(`MandateRouter`, not `GatedVault`) verifies the mandate and then calls
`vault.deposit(assets, principal)` so the vault mints directly to the principal.
Its balance is zero before and after; it holds value only between `transferFrom`
and `deposit` inside a single call. Rationale, in order of weight:

1. A wrapper would custody every Morpho share in the system, contradicting the
   "you never custody" claim that keeps this out of fund territory.
2. A wrapper is an omnibus account. Under the router the vault's own ledger reads
   `principal → shares`, so the operator's KYC file and their share registry are
   the same list of addresses. A wrapper moves per-principal attribution inside
   our contract, making us the sub-ledger of record — backwards for a product
   whose premise is extending the operator's existing KYC.
3. Blast radius. Principals hold standard vault shares and can always redeem
   directly through Morpho; if the router breaks or is abandoned, nothing is
   stranded and the operator's downside really is zero.
4. The router never converts between USDC (6) and share (18) decimals — caps are
   denominated in USDC, share amounts are opaque values passed through. The
   decimals hazard exists only in the wrapper branch.

Accepted costs of this choice:
- Two approvals from the principal, not one: USDC to the router for deposits,
  and vault shares to the router so the agent can trigger redemption. Surface
  this in the demo rather than designing around it.
- AUM attribution for rev-share becomes an event-indexing problem rather than
  reading a single `totalAssets()`. Off-chain concern, not a protocol one.

**Cap semantics: cumulative budget.** `cap` bounds the total ever deposited under
a mandate. The router keeps `spent[mandateHash]`, monotonically increasing, beside
the revocation flag it already needs. Rejected alternatives:

- *Per-deposit ceiling* — loopable. Twenty deposits of 1,000 defeat a cap of 1,000,
  so the real limit collapses into the principal's ERC-20 allowance. An allowance
  carries no expiry, no vault scoping and no agent identity, and the vault operator
  cannot verify it, so the headline safety property must not degrade into one.
- *Net position limit* (counter falls on redeem) — arguably the more natural reading
  of "max amount" and friendlier to an agent that rebalances, but it needs a clamp
  against yield-inflated redemptions and permits unbounded churn. Deferred; revisit
  only if durable long-lived mandates become a requirement.

Known limitation to document, not to engineer around: because the counter never
decreases, round trips consume budget permanently. An agent that deposits 500,
redeems it, and deposits 500 again has spent 1,000 of its cap while never having
more than 500 at risk. Acceptable for a demo horizon; it would bite on mandates
meant to live for weeks.

Error shape: `ExceedsMandate(uint256 remaining, uint256 attempted)` — report the
headroom left rather than echoing the static cap.

Open — see Questions:
- What plays the role of the "gated vault" on Base Sepolia
- Whether the mandate authorizes redemption, and under what limit

## Risks

### Verified external facts
- ERC-8004 IdentityRegistry reported at `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`
  on Base Sepolia — an ERC-721 where `ownerOf(agentId)` gives the principal.
  NOT yet confirmed on-chain. Confirm before it becomes load-bearing.
- Morpho on Base Sepolia (docs.morpho.org/addresses, verified):
  - Morpho Blue `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`
  - Adaptive Curve IRM `0x46415998764C29aB2a25CbeA6254146D50D22687`
  - **No vault factory is listed for Base Sepolia.** Morpho Blue is the lending
    primitive, not an ERC-4626. There is therefore no ready-made Morpho ERC-4626
    vault to wrap on Base Sepolia — the demo must supply its own.
  - The Vault V2 Factory `0x4501125508079A99ebBebCE205DeC9593C2b5857` is Base
    **mainnet** only. A web search initially misattributed it to Sepolia; do not
    trust that address on testnet.

### Open risks
- Router allowance is a trust surface. The principal grants the router an ERC-20
  allowance; that allowance bounds the blast radius if the router is buggy.
  Argues for a non-upgradeable router with no owner-controlled fund path.
- Stated caveat, to be kept in the pitch: if the *principal's* key is compromised,
  this design does nothing.
- Signature replay across chains and deployments — EIP-712 domain must pin
  chainId and verifying contract.
- Decimals: USDC is 6, vault shares are typically 18. Severity depends on the
  custody decision below; a pass-through router never converts between them.

## Criteria

Demo acceptance, five transactions:
1. No mandate → rejected
2. Valid mandate, 500 USDC → accepted, shares to principal
3. Attempt 5,000 → rejected, exceeds mandate
4. Principal revokes, same valid 500 replayed → rejected, revoked
5. Agent redeems → assets land with the principal and nowhere else

Each rejection must surface a distinct, named custom error.

Addition: the five transactions above do not actually discriminate between cap
semantics — with a cap of 1,000, every candidate design rejects 5,000. Add the
transaction that proves the cap binds where a per-deposit ceiling would not:

  deposit 500 → accepted, then deposit 600 → ExceedsMandate(remaining: 500, attempted: 600)

## Questions outstanding

1. Custody architecture — pass-through router or wrapping ERC-4626?
2. Mandate cap — cumulative budget across deposits, or per-deposit ceiling?
3. What is the gated vault on Base Sepolia, given none exists to wrap?
4. Deliverable shape and audience — contracts and a script, or is a UI in scope?
