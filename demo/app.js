/**
 * Live reader for the deployed MandateRouter.
 *
 * SEEDED WITH THE ROUTER ADDRESS AND A START BLOCK. NOTHING ELSE.
 * The vault, the registry, the asset, the transaction hashes, and the signed
 * mandate itself are all read back off the chain -- the mandate and its signature
 * come out of the deposit transaction's own calldata. Nothing on this page is a
 * value someone typed in and hoped was still true.
 *
 * No dependencies and no build step: plain JSON-RPC over fetch, and a minimal ABI
 * codec below. Function and error selectors are hardcoded constants generated with
 * `cast sig`, which is what removes the need for keccak in the browser -- the one
 * thing that would otherwise force a bundler.
 */

const CFG = {
  rpcUrl: "https://ethereum-sepolia-rpc.publicnode.com",
  chainId: 11155111,
  chainName: "Ethereum Sepolia",
  router: "0xf65ee68c59cd31d04ec19ca98c1573ebb487f936",
  fromBlock: 11537900, // the endpoint caps eth_getLogs at a 50k range
  explorer: "https://sepolia.etherscan.io",
};

// Generated with `cast sig "<signature>"`. Verified against forge's own artifacts.
const SEL = {
  vault: "0xfbfa77cf",
  registry: "0x7b103999",
  asset: "0x38d52e0f",
  spent: "0xae20bed3", // spent(bytes32)
  revoked: "0x328a93e8", // revoked(bytes32)
  mandateDigest: "0x65cfda80",
  mandateKey: "0x9e2a5eaf", // mandateKey(bytes32,address)
  depositFor: "0xac4c0f07",
  ownerOf: "0x6352211e",
  allowlisted: "0x03f45d41",
  balanceOf: "0x70a08231",
  deposit: "0x6e553f65", // deposit(uint256,address)
  decimals: "0x313ce567",
  symbol: "0x95d89b41",
};

// `cast sig-event`. Only topic0 is needed -- the logs are found by address anyway.
const TOPIC = {
  Deposited: "0x7b8a77f8095f01411daa3508e862de8093066b7a97205f6988131a0e11b14bf1",
  Redeemed: "0xbdc776dec3f96bc264615f8ea2fa7e6dab8a820b0d123c56ce4fb2e760693b5b",
  Revoked: "0xbad7982cc5cd1310cfc1c83b1e7e9bc771332036ea180c362910e4068fc5ecf6",
};

// Every revert this page can provoke, plus the two standard ones so an UNEXPECTED
// failure is still legible rather than a bare selector.
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
  const res = await fetch(CFG.rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });
  if (!res.ok) throw new Error(`RPC HTTP ${res.status}`);
  const body = await res.json();
  if (body.error) {
    const e = new Error(body.error.message || "RPC error");
    e.data = body.error.data;
    throw e;
  }
  return body.result;
}

/** eth_call that EXPECTS a revert. Returns decoded revert data, or throws if the
 *  call unexpectedly succeeded -- which for this page is itself a failure. */
async function callExpectingRevert(from, to, data, block = "latest", tries = 8) {
  try {
    await rpc("eth_call", [{ from, to, data }, block]);
  } catch (e) {
    // The public endpoint load-balances across backends with different retention, so
    // a historical call misses roughly half the time and succeeds on a retry against
    // the same block. Measured 6/12 on this deployment. Giving up on the first miss
    // reported a permanent-sounding failure for a transient one.
    if (tries > 1 && isPruned(e)) {
      await new Promise((r) => setTimeout(r, 220));
      return callExpectingRevert(from, to, data, block, tries - 1);
    }
    const raw = typeof e.data === "string" ? e.data : e.data?.data;
    if (raw && raw.startsWith("0x") && raw.length >= 10) return decodeError(raw);
    if (isPruned(e)) {
      const err = new Error("no backend answered with state from that block");
      err.pruned = true;
      throw err;
    }
    throw new Error(e.message);
  }
  throw new Error("the call SUCCEEDED — it was supposed to revert");
}

/** Whether a failure is "this backend does not hold that block's state" rather than a
 *  real revert. Nodes word it differently, hence the spread of patterns. */
const isPruned = (e) =>
  /historical state|missing trie node|state.*not available|pruned|header not found/i.test(e.message || "");

const ethCall = (to, data, block = "latest") => rpc("eth_call", [{ to, data }, block]);

// ---------------------------------------------------------------------------
// Minimal ABI codec. Every value in this contract's surface is a 32-byte word
// except one `bytes`, which keeps this honest at ~60 lines.
// ---------------------------------------------------------------------------

const strip = (h) => (h.startsWith("0x") ? h.slice(2) : h);
const word = (v) => BigInt(v).toString(16).padStart(64, "0");
const wordAddr = (a) => strip(a).toLowerCase().padStart(64, "0");
const wordHex = (h) => strip(h).padStart(64, "0");

const readWord = (hex, i) => strip(hex).slice(i * 64, (i + 1) * 64);
const asBig = (w) => BigInt("0x" + w);
const asAddr = (w) => "0x" + w.slice(24);
const asBool = (w) => asBig(w) !== 0n;

/** Mandate is an all-static tuple, so it encodes inline with no offset. */
const encMandate = (m) =>
  word(m.agentId) + wordAddr(m.agent) + wordAddr(m.target) + word(m.cap) + word(m.expiry) + word(m.nonce);

/** depositFor(Mandate, bytes, uint256). Head is 6 mandate words + offset + assets
 *  = 8 words = 0x100, which is where the signature's length prefix sits. */
function encDepositFor(m, sig, assets) {
  const s = strip(sig);
  const len = s.length / 2;
  const padded = s.padEnd(Math.ceil(len / 32) * 64, "0");
  return SEL.depositFor + encMandate(m) + word(0x100) + word(assets) + word(len) + padded;
}

function decodeError(raw) {
  const sel = raw.slice(0, 10);
  const spec = ERRORS[sel];
  if (!spec) return { name: null, selector: sel, args: [], text: `unknown error ${sel}` };
  const body = raw.slice(10);
  const args = spec.args.map((t, i) => {
    const w = body.slice(i * 64, (i + 1) * 64);
    if (t === "address") return asAddr(w);
    if (t === "string") return "(string)";
    return asBig(w).toString();
  });
  return {
    name: spec.name,
    selector: sel,
    args,
    text: args.length ? `${spec.name}(${args.join(", ")})` : `${spec.name}()`,
  };
}

/** Recovers the mandate and its signature from a depositFor transaction's own
 *  calldata. This is what makes "nothing baked in" literally true: the signed
 *  authorization is read back off the chain rather than pasted into this file. */
function decodeDepositForCalldata(input) {
  const d = strip(input).slice(8);
  const m = {
    agentId: asBig(readWord(d, 0)),
    agent: asAddr(readWord(d, 1)),
    target: asAddr(readWord(d, 2)),
    cap: asBig(readWord(d, 3)),
    expiry: asBig(readWord(d, 4)),
    nonce: asBig(readWord(d, 5)),
  };
  const sigOffset = Number(asBig(readWord(d, 6))) * 2;
  const assets = asBig(readWord(d, 7));
  const sigLen = Number(BigInt("0x" + d.slice(sigOffset, sigOffset + 64)));
  const sig = "0x" + d.slice(sigOffset + 64, sigOffset + 64 + sigLen * 2);
  return { mandate: m, sig, assets };
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const usdc = (v) => {
  const n = BigInt(v);
  const whole = n / 1000000n;
  const frac = (n % 1000000n).toString().padStart(6, "0").slice(0, 2);
  return `${whole.toLocaleString("en-US")}.${frac}`;
};
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const txUrl = (h) => `${CFG.explorer}/tx/${h}`;
const addrUrl = (a) => `${CFG.explorer}/address/${a}`;

// ---------------------------------------------------------------------------
// Derivation — everything below is read, not declared
// ---------------------------------------------------------------------------

const S = { cfg: CFG }; // the resolved world

async function derive() {
  const chainId = Number(await rpc("eth_chainId", []));
  if (chainId !== CFG.chainId) {
    throw new Error(`RPC is on chain ${chainId}, expected ${CFG.chainId} (${CFG.chainName})`);
  }
  S.chainId = chainId;
  S.block = Number(await rpc("eth_blockNumber", []));

  const code = await rpc("eth_getCode", [CFG.router, "latest"]);
  if (!code || code === "0x") throw new Error(`no contract at ${CFG.router} on this chain`);

  // The router names its own collaborators.
  S.vault = asAddr(readWord(await ethCall(CFG.router, SEL.vault), 0));
  S.registry = asAddr(readWord(await ethCall(CFG.router, SEL.registry), 0));
  S.asset = asAddr(readWord(await ethCall(CFG.router, SEL.asset), 0));

  // The router's own logs name its transactions.
  const logs = await rpc("eth_getLogs", [
    { address: CFG.router, fromBlock: "0x" + CFG.fromBlock.toString(16), toBlock: "latest" },
  ]);
  S.logs = logs.map((l) => ({
    topic0: l.topics[0],
    block: Number(l.blockNumber),
    tx: l.transactionHash,
    name:
      l.topics[0] === TOPIC.Deposited
        ? "Deposited"
        : l.topics[0] === TOPIC.Redeemed
          ? "Redeemed"
          : l.topics[0] === TOPIC.Revoked
            ? "Revoked"
            : "?",
  }));

  const dep = S.logs.find((l) => l.name === "Deposited");
  if (!dep) throw new Error("no Deposited log — has the demo run against this router?");

  // The mandate and its signature, out of the deposit's calldata.
  const tx = await rpc("eth_getTransactionByHash", [dep.tx]);
  const { mandate, sig, assets } = decodeDepositForCalldata(tx.input);
  S.mandate = mandate;
  S.sig = sig;
  S.depositAmount = assets;
  S.agent = mandate.agent;
  S.depositBlock = dep.block;

  // The principal is whoever the registry says owns the agent id.
  S.principal = asAddr(readWord(await ethCall(S.registry, SEL.ownerOf + word(mandate.agentId)), 0));

  // The storage key both value paths read, computed by the router itself.
  const digest = "0x" + readWord(await ethCall(CFG.router, SEL.mandateDigest + encMandate(mandate)), 0);
  S.digest = digest;
  S.key =
    "0x" + readWord(await ethCall(CFG.router, SEL.mandateKey + wordHex(digest) + wordAddr(S.principal)), 0);
}

async function loadState() {
  const bal = async (token, who) => asBig(readWord(await ethCall(token, SEL.balanceOf + wordAddr(who)), 0));
  const allow = async (who) => asBool(readWord(await ethCall(S.vault, SEL.allowlisted + wordAddr(who)), 0));

  S.spent = asBig(readWord(await ethCall(CFG.router, SEL.spent + wordHex(S.key)), 0));
  S.revokedFlag = asBool(readWord(await ethCall(CFG.router, SEL.revoked + wordHex(S.key)), 0));

  S.balances = {
    principalAsset: await bal(S.asset, S.principal),
    principalShares: await bal(S.vault, S.principal),
    agentAsset: await bal(S.asset, S.agent),
    agentShares: await bal(S.vault, S.agent),
    routerAsset: await bal(S.asset, CFG.router),
    routerShares: await bal(S.vault, CFG.router),
  };
  S.allowlist = { principal: await allow(S.principal), agent: await allow(S.agent) };
  S.ownerOf = asAddr(readWord(await ethCall(S.registry, SEL.ownerOf + word(S.mandate.agentId)), 0));
}

// ---------------------------------------------------------------------------
// The eight refusals, each re-executed against the live chain
// ---------------------------------------------------------------------------

const GARBAGE_SIG = "0x" + "11".repeat(65);

function refusals() {
  const m = S.mandate;
  const alt = (o) => ({ ...m, ...o });
  const dep = (mm, sig, amt) => encDepositFor(mm, sig, amt);

  return [
    {
      step: 1,
      error: "NotAgent",
      title: "Someone other than the agent calls",
      blurb:
        "The mandate names exactly one address that may act on it. Here the principal — the mandate's own author — calls it, and is refused. Authority is not transferable by being important.",
      run: () => callExpectingRevert(S.principal, CFG.router, dep(m, S.sig, S.depositAmount)),
    },
    {
      step: 2,
      error: "WrongVault",
      title: "The mandate points at a different vault",
      blurb:
        "A mandate is scoped to one target. Re-aiming it at another contract — here the USDC token — is refused even though the signature is genuine.",
      run: () => callExpectingRevert(S.agent, CFG.router, dep(alt({ target: S.asset }), S.sig, S.depositAmount)),
    },
    {
      step: 3,
      error: "MandateExpired",
      title: "The mandate has expired",
      blurb:
        "Expiry ends authority in both directions — the agent can no longer deposit and no longer redeem. Not merely a limit on adding more.",
      run: () => callExpectingRevert(S.agent, CFG.router, dep(alt({ expiry: 1n }), S.sig, S.depositAmount)),
    },
    {
      step: 4,
      error: "AgentNotRegistered",
      title: "The agent identity does not exist",
      blurb:
        "The principal is derived from the ERC-8004 registry, never taken from the mandate. An unminted id has no owner, so there is nobody to have authorized this.",
      run: () =>
        callExpectingRevert(S.agent, CFG.router, dep(alt({ agentId: 999999999n }), S.sig, S.depositAmount)),
    },
    {
      step: 5,
      error: "InvalidSignature",
      title: "The signature is not the principal's",
      blurb:
        "The recovered signer must equal the registry's owner of the agent id. Malformed and malleable signatures are refused with our error, never OpenZeppelin's.",
      run: () => callExpectingRevert(S.agent, CFG.router, dep(m, GARBAGE_SIG, S.depositAmount)),
    },
    {
      step: 6,
      error: "MandateRevoked",
      title: "The principal revoked it",
      blurb:
        "The kill switch, and it is live right now: this exact mandate was revoked on-chain, so the very call that succeeded earlier is refused today. There is no un-revoke.",
      run: () => callExpectingRevert(S.agent, CFG.router, dep(m, S.sig, S.depositAmount)),
    },
    {
      step: 7,
      error: "ExceedsMandate",
      title: "It would exceed the cap",
      blurb:
        "The cap is cumulative and redemption never decreases it, so the headroom is what it was. The error reports remaining and attempted, not the static cap.",
      // Step 6 now short-circuits step 7 -- the mandate is revoked -- so this one is
      // replayed at the block where it was reachable. Still the chain's own answer,
      // just at the moment it mattered.
      historical: true,
      run: () =>
        callExpectingRevert(
          S.agent,
          CFG.router,
          dep(m, S.sig, S.mandate.cap - S.spent + 2000000n),
          "0x" + (S.depositBlock + 2).toString(16),
        ),
    },
    {
      step: null,
      error: "NotAllowlisted",
      title: "The agent goes around the router entirely",
      blurb:
        "The vault's own gate, with no router involved. The agent asks to hold a position itself and is refused by name. This is what makes the router the only way through.",
      run: () =>
        callExpectingRevert(S.agent, S.vault, SEL.deposit + word(S.depositAmount) + wordAddr(S.agent)),
    },
  ];
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, html) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html !== undefined) n.innerHTML = html;
  return n;
};

function renderHeader() {
  $("#live-badge").innerHTML = `
    <span class="dot"></span>
    <strong>live</strong> · ${CFG.chainName} · block ${S.block.toLocaleString("en-US")}
    · read ${new Date().toLocaleTimeString()}`;
  $("#live-badge").classList.add("ok");
}

function actorCard({ role, tag, addr, lines, tone }) {
  const c = el("div", `card actor ${tone || ""}`);
  c.innerHTML = `
    <div class="role">${role}</div>
    <div class="tag">${tag}</div>
    <a class="addr" href="${addrUrl(addr)}" target="_blank" rel="noopener">${short(addr)}</a>
    <dl>${lines.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("")}</dl>`;
  return c;
}

function renderActors() {
  const b = S.balances;
  const zero = (v) => (v === 0n ? `<span class="good">0</span>` : `<span class="bad">${v}</span>`);
  const box = $("#actors");
  box.innerHTML = "";

  box.append(
    actorCard({
      role: "The principal",
      tag: "a KYC'd human",
      addr: S.principal,
      tone: "principal",
      lines: [
        ["owns agent id", `#${S.mandate.agentId}`],
        ["USDC", usdc(b.principalAsset)],
        ["vault shares", b.principalShares.toString()],
        ["allowlisted", S.allowlist.principal ? `<span class="good">yes</span>` : `<span class="bad">no</span>`],
      ],
    }),
    actorCard({
      role: "The agent",
      tag: "the AI's wallet",
      addr: S.agent,
      tone: "agent",
      lines: [
        ["USDC", zero(b.agentAsset)],
        ["vault shares", zero(b.agentShares)],
        ["allowlisted", S.allowlist.agent ? `<span class="bad">yes</span>` : `<span class="good">no — by design</span>`],
        ["spent of cap", `${usdc(S.spent)} / ${usdc(S.mandate.cap)}`],
      ],
    }),
    actorCard({
      role: "The router",
      tag: "ownerless · non-upgradeable",
      addr: CFG.router,
      tone: "router",
      lines: [
        ["USDC held", zero(b.routerAsset)],
        ["shares held", zero(b.routerShares)],
        ["mandate revoked", S.revokedFlag ? `<span class="good">yes</span>` : "no"],
      ],
    }),
    actorCard({
      role: "The vault",
      tag: "KYC-gated ERC-4626",
      addr: S.vault,
      tone: "vault",
      lines: [
        ["asset", `<a href="${addrUrl(S.asset)}" target="_blank" rel="noopener">USDC</a>`],
        ["gate is on", "receiver, not caller"],
      ],
    }),
  );
}

function renderProof() {
  const byName = (n) => S.logs.filter((l) => l.name === n).map((l) => l);
  const rows = [
    ...byName("Deposited").map((l) => ["deposit", `${usdc(S.depositAmount)} USDC in, shares to the principal`, l]),
    ...byName("Redeemed").map((l) => ["redeem", "position out, assets to the principal", l]),
    ...byName("Revoked").map((l) => ["revoke", "the principal kills the mandate", l]),
  ].sort((a, b) => a[2].block - b[2].block);

  $("#proof").innerHTML = rows
    .map(
      ([k, desc, l]) => `
      <div class="tx">
        <span class="kind ${k}">${k}</span>
        <span class="desc">${desc}</span>
        <span class="blk">block ${l.block.toLocaleString("en-US")}</span>
        <a href="${txUrl(l.tx)}" target="_blank" rel="noopener">${short(l.tx)}</a>
      </div>`,
    )
    .join("");

  $("#spent-note").innerHTML = `
    <code>spent</code> reads <strong>${usdc(S.spent)} USDC</strong> against a
    <strong>${usdc(S.mandate.cap)}</strong> cap — read from the chain just now, after the
    redemption. Redemption never decreases it, which is why a round trip permanently
    consumes budget rather than resetting it.`;
}

function renderRefusals() {
  const box = $("#refusals");
  box.innerHTML = "";
  S.cases = refusals();

  S.cases.forEach((c, i) => {
    const card = el("div", "card refusal");
    card.innerHTML = `
      <div class="rhead">
        <span class="step">${c.step ? `step ${c.step}` : "the vault"}</span>
        <button class="run" data-i="${i}">Run</button>
      </div>
      <h3>${c.title}</h3>
      <p>${c.blurb}</p>
      ${c.historical ? `<p class="hist">Replayed at block ${(S.depositBlock + 2).toLocaleString("en-US")} — the mandate has since been revoked, and step 6 now refuses it before step 7 is reached.</p>` : ""}
      <div class="result" id="r${i}"><span class="muted">not run yet</span></div>`;
    box.append(card);
  });

  box.querySelectorAll("button.run").forEach((b) => b.addEventListener("click", () => runOne(Number(b.dataset.i))));
}

async function runOne(i) {
  const c = S.cases[i];
  const out = $(`#r${i}`);
  out.innerHTML = `<span class="muted">calling the chain…</span>`;
  try {
    const d = await c.run();
    const right = d.name === c.error;
    out.className = `result ${right ? "reverted" : "wrong"}`;
    out.innerHTML = right
      ? `<code>${d.text}</code><span class="tick">refused ✓</span>`
      : `<code>${d.text}</code><span class="tick">expected ${c.error}</span>`;
  } catch (e) {
    if (e.pruned && c.historical) {
      // Lead with the arithmetic, which is the same claim the live call would have
      // made, and explain the miss underneath rather than beside it.
      const remaining = S.mandate.cap - S.spent;
      out.className = "result pruned";
      out.innerHTML = `
        <code>ExceedsMandate(${remaining}, …) — from stored state</code>
        <span class="tick">spent ${usdc(S.spent)} of ${usdc(S.mandate.cap)} → ${usdc(remaining)} headroom.
        ${e.message}; press Run again.</span>`;
      return;
    }
    out.className = "result wrong";
    out.innerHTML = `<code>${e.message}</code>`;
  }
}

async function runAll() {
  for (let i = 0; i < S.cases.length; i++) await runOne(i);
}

// ---------------------------------------------------------------------------

async function main() {
  const badge = $("#live-badge");
  try {
    badge.textContent = "reading the chain…";
    await derive();
    await loadState();
    renderHeader();
    renderActors();
    renderProof();
    renderRefusals();
    $("#content").classList.remove("hidden");
    $("#runall").addEventListener("click", runAll);
  } catch (e) {
    badge.classList.add("err");
    badge.textContent = `could not read the chain — ${e.message}`;
    $("#fatal").classList.remove("hidden");
    $("#fatal-msg").textContent = e.message;
  }
}

main();
