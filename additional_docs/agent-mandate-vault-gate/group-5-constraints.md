# Group 5 — binding constraints, recorded before the group is authored

**Date:** 2026-08-20 · **Status:** group 5 is UNWRITTEN — `script/` exists on zero
branches · **Source:** Lorenzo's HIGH on PR #1, 2026-08-21

This file exists because the finding is a *plan-level* trap with no code to fix yet,
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

## 2. The `scripts/` vs `script/` split is currently broken

- `package.json` declares `"demo": "tsx scripts/demo.ts"` — **plural**, and that file
  exists on no branch.
- `foundry.toml` sets `script = "script"` — **singular**, which is where
  `forge script script/Deploy.s.sol` will look.

Both are correct in isolation: `script/` is Foundry's Solidity broadcast directory,
`scripts/` is the TypeScript demo runner. They are different things and the split is
intentional, but nothing currently creates either directory, and group 5's Validation
chain ends in `pnpm demo`. Settle it when group 5 is authored; do not "fix" the
`package.json` line to singular, which would point the TS runner at Foundry's script
dir.

---

## 3. Ordering, restated from WISH.md:325

`depends-on` for group 5 is `2, 3`, but the final gate-and-broadcast run must execute
on a tree that already contains group 4's containment audit if group 4 has landed —
otherwise the gate certifies a tree that is about to change. Broadcasting is
irreversible; this is the last point at which any regression is catchable.
