# The live demo page

A local page that reads the deployed `MandateRouter` off Ethereum Sepolia and
**re-executes all eight refusals in the browser**, decoding the real revert data.
Nothing on it is a recorded result.

```bash
pnpm demo:web        # http://localhost:8080
```

Served rather than opened as `file://` because browsers differ on whether they allow
`fetch` from a `null` origin.

## Seeded with one address

`CFG` in `app.js` carries the router address, a start block, an RPC and an explorer.
Everything else is read back off the chain:

| Derived | From |
|---|---|
| vault, registry, asset | `router.vault()` / `.registry()` / `.asset()` |
| the three demo tx hashes | `eth_getLogs` on the router |
| the principal | `registry.ownerOf(agentId)` |
| **the mandate and its signature** | the deposit transaction's own calldata |
| balances, `spent`, `revoked`, allowlist | `eth_call` |

Point `CFG.router` at another deployment and the rest follows.

## Why there is no dependency

The call surface is one struct, one `bytes` and a handful of words, so the ABI codec
is ~60 lines. Function and error selectors are hardcoded constants from `cast sig`,
which is what removes the need for keccak in the browser — the one thing that would
have forced a bundler into a repo whose plan lists a web UI as out of scope.

That codec is the part that could silently lie, so it is checked rather than trusted:
every encoded call was diffed byte-for-byte against `cast calldata`, and every decoded
read against `cast call`.

## One replay is historical, and says so

Seven refusals run at `latest`. `ExceedsMandate` cannot: the mandate has since been
revoked, and step 6 refuses the call before step 7 is reached. It is therefore replayed
at the block where it was reachable — still the chain's own answer, at the moment it
mattered. The card says so.

Public nodes prune old state. When that block ages out, the card degrades to the stored
evidence (`spent` against `cap`, which is the same arithmetic) and explains why, rather
than reading as a broken page.

## Not part of the wish

`WISH.md` lists a web UI under `OUT`. This touches no contract and no test — it is a
presentation layer over a finished deployment, and lives on its own branch.
