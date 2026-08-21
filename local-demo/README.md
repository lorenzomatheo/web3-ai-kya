# The local demo

The one to show **first**. An empty chain, then press Start: four contracts get
deployed, an agent identity is linked to a principal, a mandate is signed, and the
agent moves money it never holds — then eight things it should refuse, refused by name.

`demo/` shows the same mechanism afterwards, standing in public on Ethereum Sepolia.

```bash
pnpm local-demo      # boots anvil + serves, prints the URL
```

Ctrl-C stops both.

## Pacing

`Start` takes the first step and then waits. From there:

- **Next** — one step at a time, labelled with what is about to happen, so you can
  talk over it. The button also appears **inline on the step that just finished**, so
  it follows you down the page instead of leaving you scrolling back to the header.
- **Play the rest** — runs the remainder unattended, and turns into **Pause**.

The signed mandate is drawn as a document once step 8 completes, because its *shape*
is the argument: there is no principal field. The principal is derived from
`registry.ownerOf(agentId)` and must equal the recovered signer, which is what makes
transferring the identity self-revoking.

## Why a fresh chain and not a fork

No RPC, no faucet, no network of any kind. A demo that depends on nothing external
cannot fail in front of an audience — and starting from an empty chain is what turns
"link the agent to the principal" into a step you can watch rather than a precondition
that already happened.

It also sidesteps a real hazard `dryrun.sh` hit: anvil's default accounts are
EIP-7702-delegated on live Sepolia, which gives them code and makes ERC-721
`_safeMint` revert `ERC721InvalidReceiver`. On a fresh chain they are plain EOAs, so
the well-known keys are safe to use here.

## Why there are no dependencies

Three things would normally force a library into the browser. anvil supplies all
three over plain JSON-RPC:

| Need | Supplied by |
|---|---|
| transaction signing | `eth_sendTransaction` on unlocked dev accounts |
| EIP-712 signing | `eth_signTypedData_v4` — verified: `MandateRouter` accepts it |
| keccak | the router's own `mandateDigest()` / `mandateKey()` |

Function and error selectors are hardcoded constants from `cast sig`. The ABI codec
is the same shape as `demo/app.js` and is duplicated here deliberately, so each folder
stands alone and `demo/` stays byte-identical to what was reviewed.

## `artifacts.json` is generated, not committed

`scripts/local-demo.sh` extracts creation bytecode from `out/` on every run. A
committed copy would eventually deploy yesterday's contracts while the page claimed to
be showing today's. It is gitignored for that reason.

The page is served from `local-demo/` specifically rather than the repo root:
`python3 -m http.server` serves everything beneath it, and the repo root has `.env`.

## Check 7 works here, unlike in `demo/`

`ExceedsMandate` is step 7, and revocation is step 6 — so once a mandate is revoked
the cap is never consulted and the error is unreachable. `demo/` has to replay it at a
historical block. Here the page just signs a spare 5 USDC mandate on demand and asks
for 8, so all eight checks run at head with no trickery.

## Verified

Driven headlessly against a real anvil: all 13 flow steps, containment asserted
(agent and router hold zero of both), `spent` unchanged by the redemption, and all
eight refusals with correct operands.

Deployed code is compared **byte-for-byte** against forge's `deployedBytecode`, with
immutable slots masked using the artifact's own `immutableReferences` offsets — so the
claim "this deploys the contracts the test suite covers" is checked rather than
asserted.

## Not part of the wish

`WISH.md` lists a web UI under `OUT`. No contract and no test is modified.
