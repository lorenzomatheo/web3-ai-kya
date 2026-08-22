# Agent Vault Gate

Vaults have learned to KYC a human and whitelist their wallet, but what about when
people start delegating allocation decisions to their agents?

**KYC scales to people. It does not scale to agents.** A compliance desk can onboard a
human once; it cannot onboard the fleet of agents that human spins up, retires and
replaces every quarter — and it should not have to, because the agents are not the
customer.

This keeps KYC where it belongs, on the human, and lets agents prove **authority**
instead of **identity**. One KYC, any number of agents, each capped and revocable on
its own.

---

On-chain proof that an AI agent's wallet acts for a KYC'd human, within limits that
human signed — while the agent's own balance stays at zero, permanently.

An agent that manages a position has to deposit and redeem on someone's behalf. The
usual answer is to fund its wallet and hope. This one never funds it: the principal
signs a **mandate** off-chain, and `MandateRouter` proves on-chain that the agent is
acting under it before a single token moves. The vault's allowlist holds the human and
**never the agent** — an agent that tries to hold a position directly is refused by
name.

**Live on Ethereum Sepolia**, verified:

| | |
|---|---|
| Router | [`0xf65eE68C…87F936`](https://sepolia.etherscan.io/address/0xf65ee68c59cd31d04ec19ca98c1573ebb487f936) |
| KYC-gated vault | [`0x66352111…B8a390`](https://sepolia.etherscan.io/address/0x66352111c8f85062b7f3426ccd99713bf6b8a390) |
| Agent identity | ERC-8004 token `#9710` |

---

## Two demos

Run them in this order. The first shows how the thing works; the second shows it
standing in public.

| | what it is | needs a network? |
|---|---|---|
| **`pnpm local-demo`** | An empty chain. Press Start and watch it get built — contracts deployed, agent linked to principal, mandate signed, deposit, redeem, revoke — then eight things it refuses. | **No.** Fully offline |
| **`pnpm demo:web`** | The real Sepolia deployment, read live. Re-executes all eight refusals in your browser against the deployed contracts. | Yes, read-only |

Neither needs a `.env`, a private key, or any funds.

---

## Install

**Prerequisites**

| Tool | Why | Install |
|---|---|---|
| [Foundry](https://getfoundry.sh) ≥ 1.7 | `forge` to build, `anvil` for the local chain | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Node ≥ 20 | the demo runner | [nodejs.org](https://nodejs.org) |
| pnpm ≥ 10 | package manager | `npm i -g pnpm` |
| Python 3 | serves the demo pages | preinstalled on macOS and most Linux |

**Then**

```bash
git clone <this-repo> && cd web3-ai-kya
git submodule update --init --recursive     # forge-std + OpenZeppelin 5.x
pnpm install
forge build
```

Check it worked:

```bash
forge test        # 68 passing
```

> **OpenZeppelin must resolve to 5.x.** `ECDSA.tryRecover` returns a 3-tuple in 5.x and
> a 2-tuple in 4.9, and a 4.x resolution changes the destructure silently.
> `test_OpenZeppelinIsFiveX` fails to compile against 4.x, so a green `forge build` is
> already the check.

---

## 1. `pnpm local-demo` — the whole flow, on an empty chain

```bash
pnpm local-demo
```

Boots `anvil`, extracts the compiled contracts, serves the page, and prints a URL —
**http://localhost:8081**. Ctrl-C stops both.

Press **Start**. Thirteen steps, each a real transaction:

1. Deploy the token, the identity registry, the KYC-gated vault, the router
2. Fund the principal, **link agent id 42 to them**, KYC them
3. The principal signs a mandate — off-chain, no gas
4. Approve, deposit, approve the shares, redeem, **revoke**

Take them at your own pace with **Next** (which sits on the step that just finished, so
it follows you down the page), or hit **Play the rest**. Then run the eight refusals
underneath.

Nothing external is involved — no RPC, no faucet, no keys. It cannot fail because a
network was slow.

## 2. `pnpm demo:web` — the deployed contracts, read live

```bash
pnpm demo:web
```

Serves **http://localhost:8080**, reading Ethereum Sepolia.

Every value on the page is fetched at load. The eight **Run** buttons each send a real
`eth_call` and decode the revert the contract returns — `ExceedsMandate(10000000,
12000000)` is the chain answering, not a string in the source.

The page is seeded with **one router address**. The vault, registry, asset, transaction
hashes, and the signed mandate with its signature are all read back off the chain — the
mandate comes out of the deposit transaction's own calldata.

---

## What the router checks

Seven checks run before a token moves, each with its own error. No caller ever receives
a bare selector or a library's error.

| # | Check | Reverts with |
|---|---|---|
| 1 | caller is the agent the mandate names | `NotAgent` |
| 2 | mandate is scoped to this vault | `WrongVault` |
| 3 | not past expiry — *ends redeeming too* | `MandateExpired` |
| 4 | registry returns a non-zero owner for `agentId` | `AgentNotRegistered` |
| 5 | recovered signer **equals that owner** | `InvalidSignature` |
| 6 | not revoked by the principal | `MandateRevoked` |
| 7 | fits the cumulative cap *(deposit only)* | `ExceedsMandate(remaining, attempted)` |

Plus an eighth from the vault itself: `NotAllowlisted(receiver)`, which fires before any
transfer, so an agent cannot hold a position even by going around the router.

**Steps 4 and 5 together are the design.** The principal is not a field in the mandate —
it is derived from `registry.ownerOf(agentId)` at call time, and the signature must
agree. Transfer the identity and every mandate signed under it stops verifying, with no
revocation needed.

---

## Repository

```
src/           MandateRouter, AllowlistedERC4626
test/          68 tests + a Base-mainnet fork suite against real mwUSDC
script/        Deploy.s.sol
scripts/       demo runners, the anvil rehearsal, preflight checks
demo/          the live Sepolia page
local-demo/    the offline build-it-live page
```

Each demo folder has its own README covering how it works and why.

## Tests

```bash
forge test                                          # 68, local only
FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/**'   # needs BASE_RPC_URL
```

The default profile excludes `test/fork/**` by construction, so "the full suite" is the
union of those two runs and never one command.

## Deploying your own

Only needed if you want your own instance; both demos run against what already exists.

```bash
cp .env.example .env      # fill in the keys, then:
./scripts/preflight.sh    # checks keys, funding, chain, and the 7702 hazard
./scripts/dryrun.sh       # full rehearsal on a fork before spending anything
```

Then the deploy and demo as described in
[`additional_docs/agent-mandate-vault-gate/group-5-completion.md`](additional_docs/agent-mandate-vault-gate/group-5-completion.md).

> The principal address **must be codeless** — `cast code` returns `0x`. An EOA carrying
> an EIP-7702 delegation has code, which makes ERC-721 `_safeMint` revert
> `ERC721InvalidReceiver` and the deploy abort. `preflight.sh` checks this.

## Design

`.genie/` holds the binding design record and build plan.
[`DESIGN.md`](.genie/brainstorms/agent-mandate-vault-gate/DESIGN.md) carries 17 decisions
and the risk table; [`WISH.md`](.genie/wishes/agent-mandate-vault-gate/WISH.md) is the
build plan. Group completion notes live in
[`additional_docs/agent-mandate-vault-gate/`](additional_docs/agent-mandate-vault-gate/).
