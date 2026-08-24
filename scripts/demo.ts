/**
 * The eleven-transaction demo: eight distinct custom errors printed with their
 * operands, and three transactions that succeed.
 *
 * viem rather than `forge script`, per WISH decision 5: the premise of this script
 * is that every revert reason is *ours*, and viem decodes custom errors with their
 * operands straight off the ABI. That output is the deliverable.
 *
 * Reverting cases are demonstrated by `simulateContract`, which is what surfaces the
 * decoded error and its arguments; the three succeeding cases are broadcast for real.
 * A reverting transaction could also be broadcast, but gas estimation reverts first
 * (so each would need a hand-set `gas`), it costs faucet ETH eight times over, and a
 * receipt does not carry the revert reason anyway -- recovering it needs the same
 * `eth_call` this already does. Recorded in the completion note as a reading of
 * "eleven transactions", not smuggled in.
 *
 * Every case ASSERTS its outcome. A demo that only prints is a demo that passes when
 * the contract is broken.
 */
import {createPublicClient, createWalletClient, http, decodeEventLog, BaseError, ContractFunctionRevertedError} from "viem";
import {baseSepolia} from "viem/chains";
import type {Address, Hex} from "viem";
import {loadConfig, abiOf, domainFor, MANDATE_TYPES, ERC20_ABI, type Mandate} from "./config.ts";

const CAP = 1_000_000_000n; // 1,000 USDC at 6dp
const FIRST_DEPOSIT = 500_000_000n; // 500 USDC
const OVER_CAP = 600_000_000n; // 600 against a remaining 500

const routerAbi = abiOf("MandateRouter");
const vaultAbi = abiOf("AllowlistedERC4626");

const cfg = loadConfig();
const transport = http(cfg.rpcUrl);
const pub = createPublicClient({chain: baseSepolia, transport});
const chainId = await pub.getChainId();

const wallet = (account: (typeof cfg)["agent"]) => createWalletClient({account, chain: baseSepolia, transport});

let step = 0;
const failures: string[] = [];

function usdc(v: bigint): string {
  return `${(Number(v) / 1e6).toLocaleString("en-US", {minimumFractionDigits: 2})} USDC`;
}

/** Assert-and-report. Collects rather than throwing so one bad case does not hide
 *  the state of the other ten; the process still exits non-zero at the end. */
function check(ok: boolean, detail: string): void {
  if (ok) return;
  failures.push(`tx ${step}: ${detail}`);
  console.error(`      ✗ ${detail}`);
}

/**
 * Runs a call expected to revert, and asserts it reverted with OUR named error.
 * Returns the decoded operands so the caller can assert on them too.
 */
async function expectRevert(
  label: string,
  errorName: string,
  call: () => Promise<unknown>,
): Promise<readonly unknown[]> {
  step += 1;
  console.log(`\n[${step}] ${label}`);
  try {
    await call();
  } catch (err) {
    const revert = (err as BaseError).walk?.((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError && revert.data) {
      const {errorName: got, args = []} = revert.data;
      const operands = args.length ? `(${args.map((a) => String(a)).join(", ")})` : "()";
      console.log(`      reverted: ${got}${operands}`);
      check(got === errorName, `expected ${errorName}, got ${got}`);
      return args;
    }
    // An undecoded reason falsifies the group: a raw selector or an OZ error name
    // means the error surface leaked.
    console.error(`      reverted, but NOT as a decoded custom error:`);
    console.error(`      ${(err as Error).message.split("\n")[0]}`);
    check(false, `expected ${errorName}, got an undecodable revert`);
    return [];
  }
  check(false, `expected ${errorName}, but the call SUCCEEDED`);
  return [];
}

/** Runs a call expected to succeed, and says so out loud -- otherwise the three
 *  non-reverting transactions read as missing cases next to eight loud errors. */
async function expectSuccess(label: string, call: () => Promise<Hex>): Promise<Hex> {
  step += 1;
  console.log(`\n[${step}] ${label}`);
  const hash = await call();
  const receipt = await pub.waitForTransactionReceipt({hash});
  const ok = receipt.status === "success";
  console.log(`      SUCCEEDED (this transaction is meant to succeed) — ${hash}`);
  check(ok, `transaction reverted on-chain: ${hash}`);
  return hash;
}

async function sign(m: Mandate, account: (typeof cfg)["principal"]): Promise<Hex> {
  return account.signTypedData({
    domain: domainFor(cfg.router, chainId),
    types: MANDATE_TYPES,
    primaryType: "Mandate",
    message: m,
  });
}

function mandate(overrides: Partial<Mandate> = {}): Mandate {
  return {
    agentId: cfg.agentId,
    agent: cfg.agent.address,
    target: cfg.vault,
    cap: CAP,
    expiry: BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600),
    nonce: 1n,
    ...overrides,
  };
}

const depositFor = (m: Mandate, sig: Hex, assets: bigint, account: (typeof cfg)["agent"]) =>
  pub.simulateContract({address: cfg.router, abi: routerAbi, functionName: "depositFor", args: [m, sig, assets], account});

// ---------------------------------------------------------------------------

console.log("=".repeat(72));
console.log("MandateRouter demo — 11 transactions: 8 custom errors, 3 successes");
console.log("=".repeat(72));
console.log(`chain      ${chainId}`);
console.log(`router     ${cfg.router}`);
console.log(`vault      ${cfg.vault}`);
console.log(`agentId    ${cfg.agentId}`);
console.log(`principal  ${cfg.principal.address}`);
console.log(`agent      ${cfg.agent.address}`);

const m = mandate();
const sig = await sign(m, cfg.principal);

// --- Setup, from the PRINCIPAL's key. Not part of the eleven. ---------------
// The USDC allowance is set EQUAL TO THE CAP rather than to something larger:
// the mandate binds tighter than the allowance either way, but the demo should
// show intended practice (DESIGN risk 3).
console.log(`\n--- setup: principal approves ${usdc(CAP)} to the router (allowance == cap) ---`);
{
  const hash = await wallet(cfg.principal).writeContract({
    address: cfg.usdc, abi: ERC20_ABI, functionName: "approve", args: [cfg.router, CAP],
  });
  await pub.waitForTransactionReceipt({hash});
  const allowance = await pub.readContract({
    address: cfg.usdc, abi: ERC20_ABI, functionName: "allowance", args: [cfg.principal.address, cfg.router],
  });
  if (allowance !== CAP) throw new Error(`USDC allowance is ${allowance}, expected ${CAP}`);
}

// --- 1 ----------------------------------------------------------------------
await expectSuccess(`agent deposits ${usdc(FIRST_DEPOSIT)} for the principal → Deposited`, async () => {
  const {request} = await depositFor(m, sig, FIRST_DEPOSIT, cfg.agent);
  return wallet(cfg.agent).writeContract(request);
});

// The position does not exist until transaction 1 creates it, which is why the
// share allowance is granted HERE and not with the USDC one. Read the minted
// amount off the log and approve exactly that -- never type(uint256).max, since
// the share leg is bounded by nothing inside the mandate (risks 11 and 12).
const deposited = await pub.getContractEvents({
  address: cfg.router, abi: routerAbi, eventName: "Deposited", fromBlock: "latest",
});
const mintedShares = (deposited.at(-1)?.args as {shares?: bigint} | undefined)?.shares
  ?? (await pub.readContract({address: cfg.vault, abi: ERC20_ABI, functionName: "balanceOf", args: [cfg.principal.address]}));
const spentAfterDeposit = await pub.readContract({
  address: cfg.router, abi: routerAbi, functionName: "spent",
  args: [await pub.readContract({address: cfg.router, abi: routerAbi, functionName: "mandateKey",
    args: [await pub.readContract({address: cfg.router, abi: routerAbi, functionName: "mandateDigest", args: [m]}), cfg.principal.address]})],
}) as bigint;
console.log(`      minted ${mintedShares} shares to the principal; spent = ${usdc(spentAfterDeposit)}`);

console.log(`\n--- setup: principal approves exactly ${mintedShares} shares (the position tx 1 created) ---`);
{
  const hash = await wallet(cfg.principal).writeContract({
    address: cfg.vault, abi: ERC20_ABI, functionName: "approve", args: [cfg.router, mintedShares],
  });
  await pub.waitForTransactionReceipt({hash});
}

// --- 2 ----------------------------------------------------------------------
await expectSuccess(`agent redeems the position → Redeemed, assets to the PRINCIPAL`, async () => {
  const {request} = await pub.simulateContract({
    address: cfg.router, abi: routerAbi, functionName: "redeemFor",
    args: [m, sig, mintedShares], account: cfg.agent,
  });
  return wallet(cfg.agent).writeContract(request);
});
{
  const key = await pub.readContract({address: cfg.router, abi: routerAbi, functionName: "mandateKey",
    args: [await pub.readContract({address: cfg.router, abi: routerAbi, functionName: "mandateDigest", args: [m]}), cfg.principal.address]});
  const spentNow = await pub.readContract({address: cfg.router, abi: routerAbi, functionName: "spent", args: [key]}) as bigint;
  const agentUsdc = await pub.readContract({address: cfg.usdc, abi: ERC20_ABI, functionName: "balanceOf", args: [cfg.agent.address]}) as bigint;
  const agentShares = await pub.readContract({address: cfg.vault, abi: ERC20_ABI, functionName: "balanceOf", args: [cfg.agent.address]}) as bigint;
  console.log(`      spent is UNCHANGED at ${usdc(spentNow)} — redemption never decreases it`);
  console.log(`      agent holds ${agentUsdc} USDC and ${agentShares} shares (containment)`);
  check(spentNow === spentAfterDeposit, `spent moved on redeem: ${spentNow} != ${spentAfterDeposit}`);
  check(agentUsdc === 0n && agentShares === 0n, `agent is holding value: ${agentUsdc} USDC, ${agentShares} shares`);
}

// --- 3 ----------------------------------------------------------------------
{
  const args = await expectRevert(
    `agent deposits ${usdc(OVER_CAP)} against a remaining ${usdc(CAP - FIRST_DEPOSIT)} → ExceedsMandate`,
    "ExceedsMandate",
    () => depositFor(m, sig, OVER_CAP, cfg.agent),
  );
  check(args[0] === CAP - FIRST_DEPOSIT, `remaining should be ${CAP - FIRST_DEPOSIT}, got ${args[0]}`);
  check(args[1] === OVER_CAP, `attempted should be ${OVER_CAP}, got ${args[1]}`);
  console.log(`      the arithmetic is unaffected by tx 2 — the counter never decreases`);
}

// --- 4 ----------------------------------------------------------------------
await expectRevert("the PRINCIPAL calls depositFor, but the mandate names the agent → NotAgent", "NotAgent",
  () => depositFor(m, sig, FIRST_DEPOSIT, cfg.principal));

// --- 5 ----------------------------------------------------------------------
{
  const wrong = mandate({target: cfg.usdc, nonce: 2n});
  await expectRevert("mandate targets a different vault → WrongVault", "WrongVault",
    async () => depositFor(wrong, await sign(wrong, cfg.principal), FIRST_DEPOSIT, cfg.agent));
}

// --- 6 ----------------------------------------------------------------------
{
  const expired = mandate({expiry: BigInt(Math.floor(Date.now() / 1000) - 3600), nonce: 3n});
  await expectRevert("mandate expired an hour ago → MandateExpired", "MandateExpired",
    async () => depositFor(expired, await sign(expired, cfg.principal), FIRST_DEPOSIT, cfg.agent));
}

// --- 7 ----------------------------------------------------------------------
{
  const unminted = mandate({agentId: cfg.agentId + 10_000_000n, nonce: 4n});
  await expectRevert("agentId was never minted → AgentNotRegistered", "AgentNotRegistered",
    async () => depositFor(unminted, await sign(unminted, cfg.principal), FIRST_DEPOSIT, cfg.agent));
}

// --- 8 ----------------------------------------------------------------------
{
  // One byte flipped inside `r`. Recovers a different address, so step 5 fails on
  // the signer rather than on the length -- a length change would be a different
  // path through `tryRecover`.
  const flipped = (sig.slice(0, 10) + (sig[10] === "0" ? "1" : "0") + sig.slice(11)) as Hex;
  await expectRevert("one byte flipped in the signature → InvalidSignature", "InvalidSignature",
    () => depositFor(m, flipped, FIRST_DEPOSIT, cfg.agent));
}

// --- 9 ----------------------------------------------------------------------
// The caller matters and is the reason this is the principal's key: `revoke`
// writes at (digest, msg.sender) and the deposit path reads at (digest, principal),
// so revoking from the AGENT's key would leave transaction 10 quietly succeeding
// and this demo asserting nothing.
await expectSuccess("the PRINCIPAL revokes the mandate → Revoked, and does NOT revert", async () => {
  const {request} = await pub.simulateContract({
    address: cfg.router, abi: routerAbi, functionName: "revoke", args: [m], account: cfg.principal,
  });
  return wallet(cfg.principal).writeContract(request);
});

// --- 10 ---------------------------------------------------------------------
await expectRevert("agent replays the previously valid mandate → MandateRevoked", "MandateRevoked",
  () => depositFor(m, sig, FIRST_DEPOSIT, cfg.agent));

// --- 11 ---------------------------------------------------------------------
// The RECEIVER is the point. The gate is on `receiver`, so an agent calling
// deposit(assets, principal) would succeed and prove nothing.
await expectRevert("agent deposits into the vault directly, to ITSELF → NotAllowlisted(agent)", "NotAllowlisted",
  () => pub.simulateContract({
    address: cfg.vault, abi: vaultAbi, functionName: "deposit",
    args: [FIRST_DEPOSIT, cfg.agent.address], account: cfg.agent,
  }));

// ---------------------------------------------------------------------------
console.log(`\n${"=".repeat(72)}`);
if (failures.length) {
  console.error(`FAILED — ${failures.length} of ${step} transactions did not behave as specified:`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log(`OK — ${step} transactions: 8 custom errors decoded with operands, 3 succeeded as intended.`);
