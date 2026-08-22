/**
 * The whole mandate flow, built live on an empty local chain.
 *
 * Press Start and this deploys four contracts onto a fresh anvil, links an agent
 * identity to a principal, has the principal sign a mandate, then deposits, redeems
 * and revokes -- every step a real transaction, every readout an eth_call.
 *
 * ZERO DEPENDENCIES, and anvil is why. Three things would normally force a library
 * into the browser, and anvil supplies all three over plain JSON-RPC:
 *
 *   - transaction signing   -> eth_sendTransaction on its unlocked dev accounts
 *   - EIP-712 signing       -> eth_signTypedData_v4  (verified: the router accepts it)
 *   - keccak                -> the router's own mandateDigest() / mandateKey()
 *
 * The ABI codec below is the same shape as demo/app.js and is duplicated on purpose,
 * so each folder stands alone and demo/ stays byte-identical to what was reviewed.
 */

const RPC_URL = "http://127.0.0.1:8545";

// anvil's deterministic dev accounts. Publicly known keys, which is exactly why they
// are safe here and were NOT safe on Sepolia: on a fresh chain they carry no EIP-7702
// delegation, so ERC-721 _safeMint treats them as the plain EOAs they are.
const ACC = {
  deployer: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  principal: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  agent: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
};

const AGENT_ID = 42n;
const CAP = 20_000_000n; // 20 USDC, 6dp
const DEPOSIT = 10_000_000n; // half the cap, as in the design
const MINT_TO_PRINCIPAL = 1_000_000_000n; // 1,000 USDC of headroom

// `cast sig`. Hardcoded so the page never needs keccak.
const SEL = {
  // doubles
  mint: "0x40c10f19", // mint(address,uint256) -- same shape on both doubles
  // vault
  setAllowlisted: "0x9aa54181", // setAllowlisted(address,bool)
  allowlisted: "0x03f45d41",
  deposit: "0x6e553f65",
  // erc20
  approve: "0x095ea7b3",
  balanceOf: "0x70a08231",
  allowance: "0xdd62ed3e",
  // router
  vault: "0xfbfa77cf",
  registry: "0x7b103999",
  asset: "0x38d52e0f",
  spent: "0xae20bed3",
  revoked: "0x328a93e8",
  mandateDigest: "0x65cfda80",
  mandateKey: "0x9e2a5eaf",
  depositFor: "0xac4c0f07",
  redeemFor: "0xed4cdda2",
  revoke: "0x8c64c575", // revoke((uint256,address,address,uint256,uint64,uint256))
  ownerOf: "0x6352211e",
  totalAssets: "0x01e1d114",
  totalSupply: "0x18160ddd",
};

const ERRORS = {
  "0x0d9ab13f": { name: "NotAgent", args: [] },
  "0xe224e0ca": { name: "WrongVault", args: [] },
  "0x27267dfd": { name: "MandateExpired", args: [] },
  "0x83bcfb47": { name: "AgentNotRegistered", args: [] },
  "0x8baa579f": { name: "InvalidSignature", args: [] },
  "0x2baefe03": { name: "MandateRevoked", args: [] },
  "0x81b688ac": { name: "ExceedsMandate", args: ["uint256", "uint256"] },
  "0x6f7a5275": { name: "NotAllowlisted", args: ["address"] },
  "0x08c379a0": { name: "Error", args: ["string"] },
  "0x4e487b71": { name: "Panic", args: ["uint256"] },
};

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

let rpcId = 0;

async function rpc(method, params) {
  let res;
  try {
    res = await fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
    });
  } catch {
    throw new Error(`cannot reach anvil at ${RPC_URL} — is \`pnpm local-demo\` still running?`);
  }
  const body = await res.json();
  if (body.error) {
    const e = new Error(body.error.message || "RPC error");
    e.data = body.error.data;
    throw e;
  }
  return body.result;
}

const ethCall = (to, data) => rpc("eth_call", [{ to, data }, "latest"]);

/** Sends and waits. anvil mines instantly, so one poll is normally enough. */
async function send(from, tx) {
  const hash = await rpc("eth_sendTransaction", [{ from, ...tx }]);
  for (let i = 0; i < 60; i++) {
    const r = await rpc("eth_getTransactionReceipt", [hash]);
    if (r) {
      if (r.status !== "0x1") throw new Error(`transaction reverted (${hash})`);
      return r;
    }
    await new Promise((s) => setTimeout(s, 50));
  }
  throw new Error("no receipt after 3s — is anvil mining?");
}

async function callExpectingRevert(from, to, data) {
  try {
    await rpc("eth_call", [{ from, to, data }, "latest"]);
  } catch (e) {
    const raw = typeof e.data === "string" ? e.data : e.data?.data;
    if (raw && raw.startsWith("0x") && raw.length >= 10) return decodeError(raw);
    throw new Error(e.message);
  }
  throw new Error("the call SUCCEEDED — it was supposed to revert");
}

// ---------------------------------------------------------------------------
// ABI codec
// ---------------------------------------------------------------------------

const strip = (h) => (h.startsWith("0x") ? h.slice(2) : h);
const word = (v) => BigInt(v).toString(16).padStart(64, "0");
const wordAddr = (a) => strip(a).toLowerCase().padStart(64, "0");
const wordHex = (h) => strip(h).padStart(64, "0");
const wordBool = (b) => (b ? "1" : "0").padStart(64, "0");

const readWord = (hex, i) => strip(hex).slice(i * 64, (i + 1) * 64);
const asBig = (w) => BigInt("0x" + w);
const asAddr = (w) => "0x" + w.slice(24);
const asBool = (w) => asBig(w) !== 0n;

const encMandate = (m) =>
  word(m.agentId) + wordAddr(m.agent) + wordAddr(m.target) + word(m.cap) + word(m.expiry) + word(m.nonce);

/** (Mandate, bytes, uint256): head is 6 mandate words + offset + amount = 0x100. */
function encWithSig(sel, m, sig, amount) {
  const s = strip(sig);
  const len = s.length / 2;
  return sel + encMandate(m) + word(0x100) + word(amount) + word(len) + s.padEnd(Math.ceil(len / 32) * 64, "0");
}

function decodeError(raw) {
  const sel = raw.slice(0, 10);
  const spec = ERRORS[sel];
  if (!spec) return { name: null, text: `unknown error ${sel}` };
  const body = raw.slice(10);
  const args = spec.args.map((t, i) => {
    const w = body.slice(i * 64, (i + 1) * 64);
    return t === "address" ? asAddr(w) : t === "string" ? "(string)" : asBig(w).toString();
  });
  return { name: spec.name, args, text: args.length ? `${spec.name}(${args.join(", ")})` : `${spec.name}()` };
}

// ---------------------------------------------------------------------------
// EIP-712 — signed by anvil, as the principal
// ---------------------------------------------------------------------------

const MANDATE_TYPES = {
  EIP712Domain: [
    { name: "name", type: "string" },
    { name: "version", type: "string" },
    { name: "chainId", type: "uint256" },
    { name: "verifyingContract", type: "address" },
  ],
  Mandate: [
    { name: "agentId", type: "uint256" },
    { name: "agent", type: "address" },
    { name: "target", type: "address" },
    { name: "cap", type: "uint256" },
    { name: "expiry", type: "uint64" },
    { name: "nonce", type: "uint256" },
  ],
};

/** The domain is built from the literal strings the contract passes to
 *  EIP712("MandateRouter", "1") -- never read back off the deployed contract, which
 *  would make the two agree by construction and prove nothing. */
async function signMandate(m) {
  return rpc("eth_signTypedData_v4", [
    ACC.principal,
    {
      types: MANDATE_TYPES,
      primaryType: "Mandate",
      domain: { name: "MandateRouter", version: "1", chainId: S.chainId, verifyingContract: S.router },
      message: {
        agentId: m.agentId.toString(),
        agent: m.agent,
        target: m.target,
        cap: m.cap.toString(),
        expiry: m.expiry.toString(),
        nonce: m.nonce.toString(),
      },
    },
  ]);
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const usdc = (v) => {
  const n = BigInt(v);
  return `${(n / 1000000n).toLocaleString("en-US")}.${(n % 1000000n).toString().padStart(6, "0").slice(0, 2)}`;
};
const short = (a) => `${a.slice(0, 8)}…${a.slice(-6)}`;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const S = { running: false, done: false };

async function readState() {
  if (!S.router) return;
  const bal = async (t, w) => asBig(readWord(await ethCall(t, SEL.balanceOf + wordAddr(w)), 0));
  S.st = {
    principalAsset: await bal(S.usdc, ACC.principal),
    principalShares: await bal(S.vault, ACC.principal),
    agentAsset: await bal(S.usdc, ACC.agent),
    agentShares: await bal(S.vault, ACC.agent),
    routerAsset: await bal(S.usdc, S.router),
    routerShares: await bal(S.vault, S.router),
    spent: S.key ? asBig(readWord(await ethCall(S.router, SEL.spent + wordHex(S.key)), 0)) : 0n,
    revoked: S.key ? asBool(readWord(await ethCall(S.router, SEL.revoked + wordHex(S.key)), 0)) : false,
    // ownerOf reverts ERC721NonexistentToken until the identity is minted in step 6,
    // and the panel is read from step 4 onwards -- so "not yet" is a state, not a bug.
    owner: await ethCall(S.registry, SEL.ownerOf + word(AGENT_ID))
      .then((r) => asAddr(readWord(r, 0)))
      .catch(() => null),
    allowPrincipal: asBool(readWord(await ethCall(S.vault, SEL.allowlisted + wordAddr(ACC.principal)), 0)),
    allowAgent: asBool(readWord(await ethCall(S.vault, SEL.allowlisted + wordAddr(ACC.agent)), 0)),
    vaultAssets: asBig(readWord(await ethCall(S.vault, SEL.totalAssets), 0)),
    vaultSupply: asBig(readWord(await ethCall(S.vault, SEL.totalSupply), 0)),
  };
  renderState();
}

// ---------------------------------------------------------------------------
// The flow
// ---------------------------------------------------------------------------

function steps() {
  const deployTx = (name, args = "") => ({ data: "0x" + strip(S.art[name].bytecode) + args });

  return [
    {
      t: "Deploy the token",
      d: "A 6-decimal mock USDC. The chain is empty; this is the first thing on it.",
      run: async () => {
        S.usdc = (await send(ACC.deployer, deployTx("MockUSDC"))).contractAddress;
        return `MockUSDC at ${short(S.usdc)}`;
      },
    },
    {
      t: "Deploy the identity registry",
      d: "An ERC-721 where a token id is an agent's identity. On Sepolia this is the real ERC-8004 registry; the router only ever calls ownerOf.",
      run: async () => {
        S.registry = (await send(ACC.deployer, deployTx("MinimalIdentityRegistry"))).contractAddress;
        return `registry at ${short(S.registry)}`;
      },
    },
    {
      t: "Deploy the KYC-gated vault",
      d: "An ERC-4626 that refuses to mint shares to anyone not on its allowlist. The gate is on the receiver, not the caller.",
      run: async () => {
        const args =
          wordAddr(S.usdc) + word(0x80) + word(0xc0) + wordAddr(ACC.deployer) +
          word(14) + encStr("KYC USDC Vault") + word(5) + encStr("kUSDC");
        S.vault = (await send(ACC.deployer, deployTx("AllowlistedERC4626", args))).contractAddress;
        return `vault at ${short(S.vault)}`;
      },
    },
    {
      t: "Deploy the router",
      d: "Ownerless, non-upgradeable, no arbitrary-call path. Bound at construction to one registry and one vault, and it holds standing allowances — which is only acceptable because the code cannot change or be steered.",
      run: async () => {
        S.router = (await send(ACC.deployer, deployTx("MandateRouter", wordAddr(S.registry) + wordAddr(S.vault))))
          .contractAddress;
        return `router at ${short(S.router)}`;
      },
    },
    {
      t: "Fund the principal",
      d: "1,000 USDC to the human. The agent is never funded — not now, not ever. That is the containment claim, and every later step is asserted against it.",
      run: async () => {
        await send(ACC.deployer, {
          to: S.usdc,
          data: SEL.mint + wordAddr(ACC.principal) + word(MINT_TO_PRINCIPAL),
        });
        return `${usdc(MINT_TO_PRINCIPAL)} USDC to the principal`;
      },
    },
    {
      t: "Link the agent to the principal",
      d: "Agent id 42 is minted to the principal. From here the router derives the principal by asking the registry who owns 42 — never by trusting a field in the mandate. Transfer the id and every outstanding mandate dies.",
      run: async () => {
        await send(ACC.deployer, { to: S.registry, data: SEL.mint + wordAddr(ACC.principal) + word(AGENT_ID) });
        return `ownerOf(42) = the principal`;
      },
    },
    {
      t: "KYC the principal",
      d: "The principal goes on the vault's allowlist. The agent deliberately does not — which is what makes the last refusal below reachable.",
      run: async () => {
        await send(ACC.deployer, {
          to: S.vault,
          data: SEL.setAllowlisted + wordAddr(ACC.principal) + wordBool(true),
        });
        return "principal allowlisted; agent not";
      },
    },
    {
      t: "The principal signs a mandate",
      d: "Off-chain, no gas, no transaction. It authorises one agent, against one vault, up to a cumulative cap, until an expiry. The principal is not a field in it — it is derived.",
      run: async () => {
        S.mandate = {
          agentId: AGENT_ID,
          agent: ACC.agent,
          target: S.vault,
          cap: CAP,
          expiry: BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600),
          nonce: 1n,
        };
        S.sig = await signMandate(S.mandate);
        S.digest = "0x" + readWord(await ethCall(S.router, SEL.mandateDigest + encMandate(S.mandate)), 0);
        S.key =
          "0x" +
          readWord(await ethCall(S.router, SEL.mandateKey + wordHex(S.digest) + wordAddr(ACC.principal)), 0);
        return `signed · cap ${usdc(CAP)} USDC · digest ${short(S.digest)}`;
      },
    },
    {
      t: "The principal approves USDC",
      d: "<b>ERC-20 requires the allowance.</b> The mandate is the policy layer on top: the allowance says <em>how much can move</em>, the mandate says <em>who may move it, where to, and up to what</em>. Set equal to the cap here as intended practice.",
      run: async () => {
        await send(ACC.principal, { to: S.usdc, data: SEL.approve + wordAddr(S.router) + word(CAP) });
        return `allowance ${usdc(CAP)} USDC == cap`;
      },
    },
    {
      t: "The agent deposits",
      d: "The agent sends this transaction and never touches the money: the router pulls from the principal and the vault mints to the principal. The router's balance is zero before and after.",
      run: async () => {
        await send(ACC.agent, { to: S.router, data: encWithSig(SEL.depositFor, S.mandate, S.sig, DEPOSIT) });
        S.shares = asBig(readWord(await ethCall(S.vault, SEL.balanceOf + wordAddr(ACC.principal)), 0));
        return `${usdc(DEPOSIT)} USDC in · ${S.shares} shares to the principal`;
      },
    },
    {
      t: "The principal approves the shares",
      d: "Exactly the position the deposit just created, never unlimited. This could not have happened one step earlier — the position did not exist yet.",
      run: async () => {
        await send(ACC.principal, { to: S.vault, data: SEL.approve + wordAddr(S.router) + word(S.shares) });
        return `approved exactly ${S.shares} shares`;
      },
    },
    {
      t: "The agent redeems",
      d: "Assets go back to the principal, and spent does not move. Redemption never refunds budget, so a round trip permanently consumes it.",
      run: async () => {
        const before = S.st.spent;
        await send(ACC.agent, { to: S.router, data: encWithSig(SEL.redeemFor, S.mandate, S.sig, S.shares) });
        const after = asBig(readWord(await ethCall(S.router, SEL.spent + wordHex(S.key)), 0));
        return `assets to the principal · spent unchanged at ${usdc(after)}${after === before ? "" : " ⚠"}`;
      },
    },
    {
      t: "The principal revokes",
      d: "The kill switch, and it succeeds silently — worth saying out loud. It writes at msg.sender while the value paths read at the derived principal, which is what stops anyone else revoking on the principal's behalf.",
      run: async () => {
        await send(ACC.principal, { to: S.router, data: SEL.revoke + encMandate(S.mandate) });
        return "mandate revoked — there is no un-revoke";
      },
    },
  ];
}

/** A short ASCII string as one padded ABI word. Only used for the vault's two
 *  constructor strings, both well under 32 bytes. */
function encStr(str) {
  let hex = "";
  for (const ch of str) hex += ch.charCodeAt(0).toString(16).padStart(2, "0");
  return hex.padEnd(64, "0");
}

// ---------------------------------------------------------------------------
// The refusals
// ---------------------------------------------------------------------------

const GARBAGE = "0x" + "11".repeat(65);

function refusals() {
  const m = S.mandate;
  const alt = (o) => ({ ...m, ...o });
  const dep = (mm, sig, amt) => encWithSig(SEL.depositFor, mm, sig, amt);

  return [
    {
      step: 1, error: "NotAgent", t: "Someone else calls",
      d: "The principal — the mandate's own author — is refused. Authority is not transferable by being important.",
      run: () => callExpectingRevert(ACC.principal, S.router, dep(m, S.sig, DEPOSIT)),
    },
    {
      step: 2, error: "WrongVault", t: "Aimed at another vault",
      d: "The signature is genuine; the target is not this router's vault. One mandate, one destination.",
      run: () => callExpectingRevert(ACC.agent, S.router, dep(alt({ target: S.usdc }), S.sig, DEPOSIT)),
    },
    {
      step: 3, error: "MandateExpired", t: "Past its expiry",
      d: "Expiry ends authority in both directions — no more deposits and no more redemptions.",
      run: () => callExpectingRevert(ACC.agent, S.router, dep(alt({ expiry: 1n }), S.sig, DEPOSIT)),
    },
    {
      step: 4, error: "AgentNotRegistered", t: "Unknown agent identity",
      d: "An unminted id has no owner, so there is nobody who could have authorised this.",
      run: () => callExpectingRevert(ACC.agent, S.router, dep(alt({ agentId: 999999n }), S.sig, DEPOSIT)),
    },
    {
      step: 5, error: "InvalidSignature", t: "Not the principal's signature",
      d: "The recovered signer must equal the registry's owner of the agent id. Ours is the error, never the library's.",
      run: () => callExpectingRevert(ACC.agent, S.router, dep(m, GARBAGE, DEPOSIT)),
    },
    {
      step: 6, error: "MandateRevoked", t: "Revoked by the principal",
      d: "The exact call that succeeded during the flow is now refused. Live, against the mandate you watched being revoked.",
      run: () => callExpectingRevert(ACC.agent, S.router, dep(m, S.sig, DEPOSIT)),
    },
    {
      step: 7, error: "ExceedsMandate", t: "Over the cap",
      d: "Step 6 would refuse the flow's mandate before the cap is ever consulted, so this signs a fresh 5 USDC mandate and asks for 8. The error reports headroom and attempt, not the static cap.",
      run: async () => {
        const spare = { ...m, cap: 5_000_000n, nonce: 99n };
        const sig = await signMandate(spare);
        return callExpectingRevert(ACC.agent, S.router, dep(spare, sig, 8_000_000n));
      },
    },
    {
      step: null, error: "NotAllowlisted", t: "Going around the router",
      d: "The vault's own gate, no router involved. The agent asks to hold a position itself and is refused by name.",
      run: () =>
        callExpectingRevert(ACC.agent, S.vault, SEL.deposit + word(DEPOSIT) + wordAddr(ACC.agent)),
    },
  ];
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

const $ = (s) => document.querySelector(s);

function renderState() {
  const s = S.st;
  if (!s) return;
  const z = (v) => (v === 0n ? `<b class="good">0</b>` : `<b class="bad">${v}</b>`);
  $("#state").innerHTML = `
    <div class="sgrid">
      <div class="sbox"><h4>Principal</h4>
        <div><span>USDC</span><b>${usdc(s.principalAsset)}</b></div>
        <div><span>shares</span><b>${s.principalShares}</b></div>
        <div><span>owns id 42</span><b>${!s.owner ? "not minted yet" : s.owner.toLowerCase() === ACC.principal.toLowerCase() ? "yes" : "no"}</b></div>
        <div><span>allowlisted</span><b>${s.allowPrincipal ? "yes" : "no"}</b></div></div>
      <div class="sbox agent"><h4>Agent <em>holds nothing</em></h4>
        <div><span>USDC</span>${z(s.agentAsset)}</div>
        <div><span>shares</span>${z(s.agentShares)}</div>
        <div><span>allowlisted</span><b class="${s.allowAgent ? "bad" : "good"}">${s.allowAgent ? "yes" : "no — by design"}</b></div></div>
      <div class="sbox"><h4>Router <em>pass-through</em></h4>
        <div><span>USDC</span>${z(s.routerAsset)}</div>
        <div><span>shares</span>${z(s.routerShares)}</div>
        <div><span>spent</span><b>${usdc(s.spent)} / ${usdc(CAP)}</b></div>
        <div><span>revoked</span><b>${s.revoked ? "yes" : "no"}</b></div></div>
      <div class="sbox"><h4>Vault <em>KYC-gated</em></h4>
        <div><span>total assets</span><b>${usdc(s.vaultAssets)}</b></div>
        <div><span>shares issued</span><b>${s.vaultSupply}</b></div>
        <div><span>holders</span><b>${(s.allowPrincipal ? 1 : 0)} allowlisted</b></div>
        <div><span>gate is on</span><b>receiver</b></div></div>
    </div>`;
}

/** The mandate, inline on the step that produced it.
 *
 *  Worth showing rather than describing, because the shape is the argument: there is
 *  no principal field. It is derived from `registry.ownerOf(agentId)` and must equal
 *  the recovered signer, which is what makes transferring the identity self-revoking.
 */
function renderMandateInto(stepIndex) {
  const m = S.mandate;
  const sig = strip(S.sig);
  const expiry = new Date(Number(m.expiry) * 1000);
  const days = Math.round((Number(m.expiry) - Date.now() / 1000) / 86400);
  const slot = $(`#s${stepIndex} .mandateslot`);
  if (!slot) return;

  const f = (k, v, note) => `<div><span>${k}</span><b>${v}</b><em>${note}</em></div>`;

  slot.innerHTML = `
    <div class="mcard">
      <div class="mhead"><span class="mkicker">the signed mandate</span>
        <span class="seal">✓ off-chain · no gas</span></div>
      <div class="mfields">
        ${f("agentId", m.agentId, "the identity — transfer it and this dies")}
        ${f("agent", short(m.agent), "the only address permitted to call")}
        ${f("target", short(m.target), "one vault, no other")}
        ${f("cap", usdc(m.cap) + " USDC", "cumulative; redeeming gives none back")}
        ${f("expiry", expiry.toLocaleDateString(), `in ${days} days — ends redeeming too`)}
        ${f("nonce", m.nonce, "distinguishes identical mandates")}
      </div>
      <div class="mabsent"><strong>No principal field.</strong> Derived from
        <code>registry.ownerOf(${m.agentId})</code>, and it must equal the recovered
        signer.</div>
      <div class="msig">
        <div class="mrow"><span>digest</span><code>${S.digest}</code></div>
        <div class="mrow"><span>sig</span><code>0x${sig.slice(0, 32)}… <i>r</i>·<i>s</i>·<i>v</i>, 65 bytes</code></div>
      </div>
    </div>`;
}

function renderSteps(list) {
  $("#flow").innerHTML = list
    .map(
      (s, i) => `
    <li id="s${i}" class="step">
      <div class="num">${i + 1}</div>
      <div class="body"><div class="t">${s.t}</div><div class="d">${s.d}</div>
      <div class="out"></div><div class="mandateslot"></div><div class="nextslot"></div></div>
    </li>`,
    )
    .join("");
}

function renderChecks() {
  S.checks = refusals();
  $("#checks").innerHTML = S.checks
    .map(
      (c, i) => `
    <div class="card check">
      <div class="chead"><span class="stp">${c.step ? `step ${c.step}` : "the vault"}</span>
        <button class="run" data-i="${i}">Run</button></div>
      <h3>${c.t}</h3><p>${c.d}</p>
      <div class="res" id="c${i}"><span class="muted">not run</span></div>
    </div>`,
    )
    .join("");
  $("#checks").querySelectorAll("button.run").forEach((b) =>
    b.addEventListener("click", () => runCheck(Number(b.dataset.i))),
  );
}

async function runCheck(i) {
  const c = S.checks[i];
  const out = $(`#c${i}`);
  out.className = "res";
  out.innerHTML = `<span class="muted">calling…</span>`;
  try {
    const d = await c.run();
    const ok = d.name === c.error;
    out.className = `res ${ok ? "ok" : "no"}`;
    out.innerHTML = `<code>${d.text}</code><span class="tick">${ok ? "refused ✓" : "expected " + c.error}</span>`;
  } catch (e) {
    out.className = "res no";
    out.innerHTML = `<code>${e.message}</code>`;
  }
}

async function runAllChecks() {
  for (let i = 0; i < S.checks.length; i++) await runCheck(i);
}

// ---------------------------------------------------------------------------

/** Advance exactly one step. Returns false when the flow is finished or has failed,
 *  which is what both the Next button and Play loop key off. */
async function stepOnce() {
  if (S.busy || !S.list || S.i >= S.list.length) return false;
  S.busy = true;
  const i = S.i;
  const li = $(`#s${i}`);
  li.classList.add("active");
  li.scrollIntoView({ behavior: "smooth", block: "center" });
  setControls();

  try {
    const msg = await S.list[i].run();
    li.classList.remove("active");
    li.classList.add("done");
    li.querySelector(".out").innerHTML = `<code>${msg}</code>`;
    await readState();
    if (S.mandate && S.sig && !S.mandateShown) {
      renderMandateInto(i);
      S.mandateShown = true;
    }
  } catch (e) {
    li.classList.remove("active");
    li.classList.add("failed");
    li.querySelector(".out").innerHTML = `<code class="bad">${e.message}</code>`;
    S.failed = true;
    S.busy = false;
    setControls();
    return false;
  }

  S.i = i + 1;
  S.busy = false;

  if (S.i >= S.list.length) {
    renderChecks();
    $("#checks-section").classList.remove("hidden");
  }
  setControls();
  return S.i < S.list.length;
}

async function playRest() {
  if (S.playing) { S.playing = false; setControls(); return; }
  S.playing = true;
  setControls();
  while (S.playing && (await stepOnce())) {
    await new Promise((r) => setTimeout(r, 650));
  }
  S.playing = false;
  setControls();
}

/** One place that decides what every button says and whether it is enabled --
 *  the flow has enough states (idle, mid-step, paused, playing, failed, done) that
 *  toggling them at each call site drifts. */
function setControls() {
  const started = !!S.list;
  const done = started && S.i >= S.list.length;
  const start = $("#start"), next = $("#next"), play = $("#play");

  start.textContent = !started ? "Start" : done || S.failed ? "Run it again" : "Restart";
  start.disabled = S.busy;

  next.classList.toggle("hidden", !started || done || S.failed);
  next.disabled = S.busy || S.playing;
  next.textContent = started && !done ? `Next · ${S.list[S.i].t}` : "Next";

  play.classList.toggle("hidden", !started || done || S.failed);
  play.disabled = S.busy && !S.playing;
  play.textContent = S.playing ? "Pause" : "Play the rest";

  $("#progress").textContent = started ? `${Math.min(S.i, S.list.length)} / ${S.list.length}` : "";

  placeInlineNext(started, done);
}

/** Puts a Next button on the step that just finished, so the control is wherever you
 *  are reading rather than back at the top of the page. Only one exists at a time --
 *  it moves down with you. */
function placeInlineNext(started, done) {
  if (!S.list) return;
  for (let k = 0; k < S.list.length; k++) {
    const slot = $(`#s${k} .nextslot`);
    if (slot) slot.innerHTML = "";
  }
  if (!started || done || S.failed || S.i === 0 || S.playing) return;

  const slot = $(`#s${S.i - 1} .nextslot`);
  if (!slot) return;
  slot.innerHTML =
    `<button class="inline-next"${S.busy ? " disabled" : ""}>Next · ${S.list[S.i].t} <span>▸</span></button>`;
  const b = slot.querySelector("button");
  if (b) b.addEventListener("click", () => stepOnce());
}

async function start() {
  if (S.busy) return;
  S.playing = false;
  S.failed = false;
  S.key = null;
  S.mandate = null;
  S.sig = null;
  S.mandateShown = false;
  S.i = 0;
  S.list = steps();

  $("#checks-section").classList.add("hidden");
  renderSteps(S.list);
  $("#flow").classList.remove("hidden");
  await readState();
  setControls();

  // Take the first step immediately so Start does something visible, then wait.
  await stepOnce();
}

async function boot() {
  try {
    S.chainId = Number(await rpc("eth_chainId", []));
    const res = await fetch("artifacts.json");
    if (!res.ok) throw new Error("artifacts.json is missing — start with `pnpm local-demo`");
    S.art = await res.json();
    $("#status").innerHTML = `<span class="dot"></span> anvil · chain ${S.chainId} · empty, nothing deployed yet`;
    $("#status").classList.add("ok");
    $("#start").disabled = false;
    $("#start").addEventListener("click", start);
    $("#next").addEventListener("click", () => stepOnce());
    $("#play").addEventListener("click", playRest);
    $("#runall").addEventListener("click", runAllChecks);
  } catch (e) {
    $("#status").classList.add("err");
    $("#status").textContent = e.message;
    $("#fatal").classList.remove("hidden");
    $("#fatal-msg").textContent = e.message;
  }
}

boot();
