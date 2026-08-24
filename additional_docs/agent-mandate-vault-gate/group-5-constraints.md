# Group 5 — binding constraints, recorded before the group is authored

**Date:** 2026-08-20 · **Status:** group 5 is now AUTHORED on `feat/g5-deploy-demo`;
§1 is implemented and proven by mutation, §1b was found while proving it, §2 is
resolved · **Source:** Lorenzo's HIGH on PR #1, plus the group 5 dry run

This file exists because §1 was a *plan-level* trap with no code to fix at the time,
and a GitHub review thread is not where a binding constraint should live. Everything
below is a hard requirement on `script/Deploy.s.sol` and the demo, not a suggestion.

---

## 1. HIGH — `register()` mints to `msg.sender`, so the deployer becomes the principal

ERC-8004's `register()` mints the agent NFT to `msg.sender`.
[`findings-external-deps.md` §1](findings-external-deps.md) proves it from the
failure side: calling `register()` with no `--from` — i.e. as `address(0)` — reverts
`ERC721InvalidReceiver(address)` (`0x64a0ae92`). It fails on the *receiver* being
zero, and the receiver is the caller.

The WISH's own group 5 Validation broadcasts under the deployer:

```bash
forge script script/Deploy.s.sol --rpc-url "$BASE_SEPOLIA_RPC_URL" \
     --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --verify
```

So the default path makes **the deployer** the owner of `agentId`.

### Why that is fatal rather than untidy

`MandateRouter._verify` derives the principal from `registry.ownerOf(m.agentId)` and
requires the recovered signature signer to equal it
(`src/MandateRouter.sol:266-282`). If `ownerOf(agentId)` is the deployer while the
mandate was signed by `PRINCIPAL_PRIVATE_KEY`, **every** mandate fails at step 5 with
`InvalidSignature`. Nine of the eleven demo transactions become unconstructible.

This is the hardest failure in the design to debug under deadline, because
`InvalidSignature` is exactly what a genuinely malformed signature, a typehash typo,
or a domain-separator mismatch also produce. The revert reason carries no signal
distinguishing "your key is wrong" from "the NFT is at the wrong address".

### Required — pick one, both are acceptable

1. **Broadcast the registration under `PRINCIPAL_PRIVATE_KEY`**, not the deployer's.
   In a `forge script` this means a separate `vm.startBroadcast(principalPk)` section
   around the `register()` call.
2. **Register from the deployer, then `transferFrom(deployer, principal, agentId)`
   in the same script run.** `MinimalIdentityRegistry` and the live registry both
   support it, and group 2 already proves an `agentId` transfer re-points the
   principal (`test_AgentIdTransferInvalidatesExistingMandate`).

### Required regardless of which — the closing assertion

The script must not exit without:

```solidity
require(IERC721(registry).ownerOf(agentId) == principal, "Deploy: agentId not at principal");
```

against **the same `agentId` that gets pinned into the demo config**. Deriving the id
twice — once for the assertion, once for the config — reintroduces the same trap one
level up.

---

## 1b. HIGH, found during the dry run — a 7702-delegated principal cannot receive the agentId

Not in the original review; surfaced by rehearsing the deploy against a fork of Base
Sepolia, and it fails in the same place and with the same symptom as §1.

The registry's `register()` uses ERC-721 `_safeMint`, which calls
`onERC721Received` on the receiver **whenever the receiver has code**. An EOA
carrying an EIP-7702 delegation has code — `cast code` returns
`0xef0100<delegate>` — so unless the delegate implements the receiver hook, the mint
reverts `ERC721InvalidReceiver` and the deploy aborts.

This is not hypothetical. All three of anvil's well-known default accounts are
delegated on live Base Sepolia, because their private keys are public:

```bash
cast code 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --rpc-url "$BASE_SEPOLIA_RPC_URL"
#   0xef010091128fa0c92671265263548853eb875feded35b4
```

**Required:** before provisioning, confirm the principal address is codeless.

```bash
cast code "$PRINCIPAL_ADDRESS" --rpc-url "$BASE_SEPOLIA_RPC_URL"   # must be 0x
```

If it is not, generate a fresh principal key rather than trying to clear the
delegation. `scripts/dryrun.sh` asserts this for its own generated accounts so the
failure, if it ever recurs, arrives with a legible message instead of from inside an
ERC-721 mint.

---

## 2. The `scripts/` vs `script/` split is currently broken

**Resolved as authored.** Both were correct in isolation and the split was
intentional: `script/` is Foundry's Solidity broadcast directory (`script = "script"`
in `foundry.toml`), `scripts/` is the TypeScript demo runner
(`"demo": "tsx scripts/demo.ts"`). Group 5 creates both. The `package.json` line was
**not** "fixed" to singular, which would have pointed the TS runner at Foundry's
script dir.

---

## 3. Ordering, restated from WISH.md:325

`depends-on` for group 5 is `2, 3`, but the final gate-and-broadcast run must execute
on a tree that already contains group 4's containment audit if group 4 has landed —
otherwise the gate certifies a tree that is about to change. Broadcasting is
irreversible; this is the last point at which any regression is catchable.
