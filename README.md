# Agent Mandate Vault Gate

**On-chain proof that an agent address acts for a KYC'd principal, within limits the
principal signed off-chain.**

A KYC-gated vault cannot accept a deposit initiated by an AI agent, because the agent's
address carries no verifiable relationship to the principal the operator has already
approved. The capital is not blocked by risk appetite — the human is underwritten. It is
blocked by the absence of an on-chain proof binding *this address* to *that principal*,
*within limits that principal signed*.

Competing approaches put the limit inside the agent's wallet, where the vault cannot
verify it and must instead trust the agent's operator. This moves the check into the
contract that holds the funds, so it is enforceable by the party carrying the risk and
auditable by anyone.

---

## How it works

An agent presents a signed **mandate** to the router. The router proves the mandate came
from the principal who owns the agent's [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004)
identity, enforces its limits, and then deposits **from the principal, to the principal**.

```
                    ┌──────────────────────┐
   signs EIP-712    │  ERC-8004 registry   │   ownerOf(agentId)
   mandate  ┌──────►│   (agent identity)   │◄──────────┐
            │       └──────────────────────┘           │
     ┌──────┴──────┐                            ┌──────┴───────┐
     │  principal  │  USDC allowance ─────────► │ MandateRouter │
     │   (KYC'd)   │                            │  7 checks     │
     └──────▲──────┘                            └──────┬───────┘
            │                                          │ deposit(assets, principal)
            │  shares mint here, never to the agent    ▼
            │                              ┌───────────────────────┐
     ┌──────┴──────┐  depositFor / redeemFor│  AllowlistedERC4626   │
     │    agent    │───────────────────────►│  gate on *receiver*   │
     │  (never     │                        └───────────────────────┘
     │   funded)   │  direct deposit to itself ──► NotAllowlisted(agent)
     └─────────────┘
```

**Pass-through, not a wrapping vault.** The router calls `vault.deposit(assets, principal)`
so the vault mints straight to the principal. The router's balance is zero before and after
a call; it holds value only between `transferFrom` and `deposit` inside a single
transaction.

**The agent never holds value.** It holds authority — a signature — and nothing else. That
is enforced suite-wide by a `containment` modifier every test function applies: the agent
address and the router must end every test holding zero assets and zero shares.

### The seven checks

`depositFor` runs all seven; `redeemFor` runs 1–6. Each has its own custom error, because
the revert reason *is* the product surface.

| # | Check | Error |
|---|---|---|
| 1 | Caller is the agent named in the mandate | `NotAgent()` |
| 2 | Mandate targets this router's vault | `WrongVault()` |
| 3 | Mandate has not expired (enforced on redeem too) | `MandateExpired()` |
| 4 | `registry.ownerOf(agentId)` yields a non-zero principal | `AgentNotRegistered()` |
| 5 | Recovered EIP-712 signer equals that principal | `InvalidSignature()` |
| 6 | Mandate has not been revoked by its signer | `MandateRevoked()` |
| 7 | Deposit fits the cumulative cap | `ExceedsMandate(remaining, attempted)` |

Plus the vault's own gate — the eighth and last error in the surface:

| Check | Error |
|---|---|
| Share receiver is on the operator's allowlist | `NotAllowlisted(receiver)` |

The principal is deliberately **not** a field in the mandate. It is derived from
`ownerOf(agentId)` and must equal the recovered signer, which is what binds the identity to
the authorization rather than merely mentioning it — and what makes transferring the
`agentId` self-revoking.

### Revocation

`revoke(Mandate)` has no ownership gate, by design. It writes `revoked[(digest, msg.sender)]`
and the value paths read `revoked[(digest, derivedPrincipal)]`, so an entry written by
anyone who did not sign the mandate sits at a key no path ever reads. Third-party DoS is
prevented by the key binding, not by a gate — and dropping the gate keeps the kill switch
working when the registry is unreachable or the `agentId` has moved on.

There is no un-revoke. A signer who wants the same terms back signs a fresh `nonce`.

---

## Contracts

| Contract | Purpose |
|---|---|
| [`src/MandateRouter.sol`](src/MandateRouter.sol) | EIP-712 mandate verification, deposit/redeem, cumulative spend accounting, signer-keyed revocation. Non-upgradeable, ownerless, no arbitrary-call path, no fees, no pause |
| [`src/AllowlistedERC4626.sol`](src/AllowlistedERC4626.sol) | Minimal KYC-gated ERC-4626 standing in for the operator's vault. The gate is on `receiver`, not `caller` — anyone may push assets in; only an allowlisted address may hold the shares |

The router is intentionally immutable and unsteerable: it holds standing ERC-20 allowances,
and that blast radius is only acceptable if the code cannot change.

---

## Repository layout

```
src/                       the two contracts
script/Deploy.s.sol        deploys both, allowlists the principal, registers the agentId
scripts/demo.ts            the eleven-transaction demo (viem)
scripts/dryrun.sh          the whole of the above against a local anvil fork, first
test/                      local suite — 68 tests under the default profile
  BaseTest.sol             the suite-wide containment invariant
  doubles/                 MockUSDC, MockVault, MinimalIdentityRegistry, ReenteringVault
  fork/                    Base mainnet fork suite (excluded from the default profile)
.genie/                    design and build plan — the source of truth
additional_docs/           per-group plans, findings and completion notes
```

---

## Quick start

**Prerequisites:** [Foundry](https://book.getfoundry.sh/) (`forge` 1.7+), Node 20+, and
[pnpm](https://pnpm.io/) 10.

```bash
git clone --recurse-submodules <repo-url> && cd web3-ai-kya
pnpm install --frozen-lockfile
forge build
forge test
```

Pinned dependencies, both load-bearing: **OpenZeppelin 5.0.2** (`ECDSA.tryRecover` returns a
3-tuple in 5.x and a 2-tuple in 4.9.x — a 4.x resolution silently changes the destructure)
and **forge-std v1.9.6** (below v1.8.0 `assertEq` sets a failure flag instead of reverting,
and the negative containment tests fail with "call did not revert").

### The test suites

`forge test` runs the 68 local tests and reports **zero** from `test/fork/`, which needs a
mainnet RPC it does not otherwise require. The fork suite runs under its own profile:

```bash
set -o pipefail
FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/**' -vv | tee /tmp/fork.log \
  && grep -q 'MandateRouterFork.t.sol' /tmp/fork.log
```

Both guards are required, not decoration. Without `set -o pipefail` the `tee` supplies the
pipeline's exit status and a failing suite reads green; without the suite-named `grep` a
zero-match run also reads green, because `forge test` exits 0 when its filter selects
nothing. `test/fork/ProfileGuard.t.sol` makes the profile split falsifiable in the other
direction — it fails if the default profile ever reaches it.

The fork suite composes the router with a **real** production vault: Moonwell Flagship USDC,
a MetaMorpho vault over Morpho Blue on Base mainnet, at a pinned block. Mocking a vault
there would hide the rounding behaviour the suite exists to measure (1 wei of round-trip
loss, bounded at 10).

---

## Configuration

Copy [`.env.example`](.env.example) to `.env` and fill it in. `.env` is gitignored.

| Variable | Used for |
|---|---|
| `BASE_RPC_URL` | Base mainnet, for `[profile.fork]` |
| `BASE_SEPOLIA_RPC_URL` | Deployment and the demo |
| `DEPLOYER_PRIVATE_KEY` | Deploys the vault and the router |
| `PRINCIPAL_PRIVATE_KEY` | Owns the `agentId`, signs the mandate, grants both allowances, revokes |
| `AGENT_PRIVATE_KEY` | The agent's operating EOA — never funded with USDC |
| `BASESCAN_API_KEY` | Verification, consumed via the `[etherscan]` table |
| `REGISTRY_ADDRESS` | ERC-8004 AgentIdentity (Base Sepolia default provided) |
| `USDC_ADDRESS` | Circle test USDC, 6 decimals (default provided) |
| `VAULT_ADDRESS`, `ROUTER_ADDRESS`, `AGENT_ID` | Optional — resolved from the broadcast artifact if unset |

The registry is a constructor parameter rather than a constant so that Base Sepolia and a
local fork differ by config, not by code.

> **Before provisioning, check that the principal's address returns `0x` from `cast code`.**
> ERC-721 `_safeMint` takes its `onERC721Received` branch whenever the receiver has code, and
> an EOA carrying an EIP-7702 delegation *has* code. The delegate does not implement the
> hook, so `register()` reverts `ERC721InvalidReceiver` and the deploy aborts. This is why
> `scripts/dryrun.sh` generates fresh keys rather than using anvil's deterministic accounts,
> whose private keys are public and which are all delegated on live Base Sepolia.

---

## The demo

Eleven transactions: **eight distinct custom errors printed with their operands, and three
that succeed.** Every case asserts its outcome and the script exits non-zero on any
mismatch — a demo that only prints is a demo that passes when the contract is broken.

Rehearse the whole thing against a local anvil fork of Base Sepolia first, before any
faucet ETH is spent:

```bash
pnpm dryrun
```

`script/Deploy.s.sol` and `scripts/demo.ts` run **byte-identical** there and against live
Sepolia — only the RPC and the keys differ, and both come from the environment. There is no
test-only branch in either file.

Then, for real:

```bash
forge script script/Deploy.s.sol --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --verify
pnpm demo
```

| # | Transaction | Outcome |
|---|---|---|
| 1 | Agent deposits 500 USDC for the principal | `Deposited` ✓ |
| 2 | Agent redeems the position — assets to the **principal** | `Redeemed` ✓ |
| 3 | Agent deposits 600 against a remaining 500 | `ExceedsMandate(500000000, 600000000)` |
| 4 | The principal calls `depositFor`, but the mandate names the agent | `NotAgent()` |
| 5 | Mandate targets a different vault | `WrongVault()` |
| 6 | Mandate expired an hour ago | `MandateExpired()` |
| 7 | `agentId` was never minted | `AgentNotRegistered()` |
| 8 | One byte flipped in the signature | `InvalidSignature()` |
| 9 | The **principal** revokes the mandate | `Revoked` ✓ |
| 10 | Agent replays the previously valid mandate | `MandateRevoked()` |
| 11 | Agent deposits into the vault directly, to itself | `NotAllowlisted(agent)` |

Transaction 2 leaves `spent` unchanged — redemption never decreases it, so round trips
permanently consume budget. Transaction 9 must come from the principal's key: `revoke`
writes at `(digest, msg.sender)` and the deposit path reads at `(digest, principal)`, so
revoking from the agent's key would leave transaction 10 quietly succeeding.

The eight reverting cases are demonstrated with `simulateContract`, which is what surfaces
the decoded error and its operands; the three that succeed are broadcast for real. That
reading is recorded and reviewable in
[`group-5-completion.md`](additional_docs/agent-mandate-vault-gate/group-5-completion.md).

---

## Status

| | |
|---|---|
| Contracts, tests, deploy script, demo | **Complete** — 68 local tests plus the mainnet fork suite, green |
| Repository gate `forge fmt --check && forge build && forge test` | **Exit 0** |
| Full dry run on a Base Sepolia fork, all eleven transactions | **Exit 0** |
| Live Base Sepolia broadcast, verified on Basescan | **Open** — blocked on key and faucet provisioning, not on code |

Deployed addresses and the `agentId` will be recorded in
[`group-5-completion.md`](additional_docs/agent-mandate-vault-gate/group-5-completion.md)
when the live broadcast lands.

### Known limits

Out of scope by design: x402, reputation scoring, any actual LLM (the agent is a keypair
driven by a script), multi-vault routing, a web UI, and upgradeability, pausing, admin
roles or fees in the router.

The cap is a **deposit-side instrument only**. Nothing bounds the exit side beyond expiry
and revocation — no exit cap, no cooldown, no share scoping — because no quantity bound
separates a forced exit from a legitimate one. A live mandate can therefore reach shares it
did not create, and `test/OwnershipIsolation.t.sol` pins that behaviour rather than hiding
it.

---

## Documentation

[`.genie/`](.genie/) is the source of truth for design and plan:

- **Design**, 17 binding decisions — [`DESIGN.md`](.genie/brainstorms/agent-mandate-vault-gate/DESIGN.md)
- **Build plan** — [`WISH.md`](.genie/wishes/agent-mandate-vault-gate/WISH.md)

[`additional_docs/`](additional_docs/) carries the execution record: per-group plans,
externally verified findings, and completion notes. It never re-opens a design decision —
where the two disagree, `.genie/` is correct.

---

## License

MIT.
