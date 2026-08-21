import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import {privateKeyToAccount} from "viem/accounts";
import type {Abi, Address, Hex} from "viem";

const ROOT = resolve(import.meta.dirname, "..");

/** Fail loudly and early. A demo that reads `undefined` into a viem call fails
 *  much later and much less legibly. */
function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set. Copy .env.example to .env and fill it in.`);
  return v;
}

function privateKey(name: string): Hex {
  const raw = required(name);
  return (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
}

/** ABIs come from forge's own build artifacts rather than being hand-written, so
 *  they cannot drift from the bytecode that is actually deployed. A hand-copied
 *  ABI that has drifted decodes a custom error as an unknown selector, which is
 *  precisely the failure this demo exists to rule out. */
export function abiOf(contract: string): Abi {
  const path = resolve(ROOT, "out", `${contract}.sol`, `${contract}.json`);
  try {
    return JSON.parse(readFileSync(path, "utf8")).abi as Abi;
  } catch {
    throw new Error(`No build artifact at ${path}. Run \`forge build\` first.`);
  }
}

/** Deployed addresses, resolved from the environment, falling back to the
 *  broadcast artifact `--broadcast` writes automatically. The fallback is what
 *  keeps the deploy → demo handoff free of hand-copied hex. */
function fromBroadcast(chainId: number): Record<string, Address> {
  const path = resolve(ROOT, "broadcast", "Deploy.s.sol", String(chainId), "run-latest.json");
  const run = JSON.parse(readFileSync(path, "utf8"));
  const out: Record<string, Address> = {};
  for (const tx of run.transactions ?? []) {
    if (tx.transactionType === "CREATE" && tx.contractName && tx.contractAddress) {
      out[tx.contractName] = tx.contractAddress as Address;
    }
  }
  return out;
}

export function loadConfig() {
  const rpcUrl = required("BASE_SEPOLIA_RPC_URL");

  const deployer = privateKeyToAccount(privateKey("DEPLOYER_PRIVATE_KEY"));
  const principal = privateKeyToAccount(privateKey("PRINCIPAL_PRIVATE_KEY"));
  const agent = privateKeyToAccount(privateKey("AGENT_PRIVATE_KEY"));

  const usdc = required("USDC_ADDRESS") as Address;
  const registry = required("REGISTRY_ADDRESS") as Address;

  let vault = process.env.VAULT_ADDRESS as Address | undefined;
  let router = process.env.ROUTER_ADDRESS as Address | undefined;
  if (!vault || !router) {
    const chainId = Number(process.env.CHAIN_ID ?? 84532);
    const deployed = fromBroadcast(chainId);
    vault ??= deployed.AllowlistedERC4626;
    router ??= deployed.MandateRouter;
  }
  if (!vault || !router) {
    throw new Error("Could not resolve VAULT_ADDRESS / ROUTER_ADDRESS from the environment or the broadcast artifact.");
  }

  const agentId = BigInt(required("AGENT_ID"));

  return {rpcUrl, deployer, principal, agent, usdc, registry, vault, router, agentId};
}

/** The EIP-712 type, in the field order the contract's typehash commits to.
 *  Reordering these silently invalidates every signature and surfaces only as
 *  `InvalidSignature`. */
export const MANDATE_TYPES = {
  Mandate: [
    {name: "agentId", type: "uint256"},
    {name: "agent", type: "address"},
    {name: "target", type: "address"},
    {name: "cap", type: "uint256"},
    {name: "expiry", type: "uint64"},
    {name: "nonce", type: "uint256"},
  ],
} as const;

export type Mandate = {
  agentId: bigint;
  agent: Address;
  target: Address;
  cap: bigint;
  expiry: bigint;
  nonce: bigint;
};

/** Built from the literal strings the contract passes to `EIP712("MandateRouter", "1")`,
 *  never read off the deployed contract. Reading `DOMAIN_SEPARATOR()` back would make
 *  the demo agree with the contract by construction and prove nothing about whether an
 *  independent signer can reproduce it. */
export function domainFor(router: Address, chainId: number) {
  return {name: "MandateRouter", version: "1", chainId, verifyingContract: router} as const;
}

export const ERC20_ABI = [
  {type: "function", name: "approve", stateMutability: "nonpayable",
   inputs: [{name: "spender", type: "address"}, {name: "value", type: "uint256"}],
   outputs: [{type: "bool"}]},
  {type: "function", name: "balanceOf", stateMutability: "view",
   inputs: [{name: "account", type: "address"}], outputs: [{type: "uint256"}]},
  {type: "function", name: "allowance", stateMutability: "view",
   inputs: [{name: "owner", type: "address"}, {name: "spender", type: "address"}],
   outputs: [{type: "uint256"}]},
] as const;
