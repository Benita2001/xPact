import { createPublicClient, http, parseAbi, defineChain, type Hex, type Address } from "viem";
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import XPact from "../sdk/index";

const xLayerTestnet = defineChain({
  id: 1952,
  name: "X Layer Testnet",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: { default: { http: ["https://testrpc.xlayer.tech/terigon"] } },
});

const RPC_URL = "https://testrpc.xlayer.tech/terigon";
const HOOK_ADDRESS = "0x88cd934A339d4fe0f2408D60aA540BA8559910C0" as Address;
const POOL_MANAGER = "0xD1A80439f7431557705F83ec0d047f7246ec68e5" as Address;
const SWAP_ROUTER = (process.env.SWAP_ROUTER_ADDRESS ?? "0x0000000000000000000000000000000000000001") as Address;
const MOCK_USDC   = (process.env.USDC_ADDRESS        ?? "0x0000000000000000000000000000000000000002") as Address;

const PACT_ID_FILE = join(__dirname, ".current-pact");

const PACTS_ABI = parseAbi([
  "function pacts(bytes32) view returns (bytes32 id, address agentA, address agentB, string jobDescription, uint256 payment, address paymentToken, bytes32 resultHash, uint8 status, uint256 createdAt, uint256 deadline)",
]);

async function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  const privateKey = process.env.AGENT_B_KEY as Hex | undefined;
  if (!privateKey) throw new Error("AGENT_B_KEY env var required");

  console.log("🤖 Agent B: Scanning for open pacts...");

  const sdk = new XPact(
    RPC_URL,
    privateKey,
    HOOK_ADDRESS,
    POOL_MANAGER,
    SWAP_ROUTER,
    {
      currency0: "0x0000000000000000000000000000000000000000" as Address,
      currency1: MOCK_USDC,
      fee: 3000,
      tickSpacing: 60,
    },
  );

  const publicClient = createPublicClient({
    chain: xLayerTestnet,
    transport: http(RPC_URL),
  });

  // Poll for a pactId written by agentA
  let pactId: Hex | null = null;
  while (!pactId) {
    if (existsSync(PACT_ID_FILE)) {
      const raw = readFileSync(PACT_ID_FILE, "utf8").trim();
      if (raw.startsWith("0x") && raw.length === 66) {
        pactId = raw as Hex;
      }
    }
    if (!pactId) {
      process.stdout.write(".");
      await sleep(3000);
    }
  }
  console.log(`\n📌 Agent B: Found pact — ${pactId}`);

  // Verify it's still Open on-chain
  const pact = await publicClient.readContract({
    address: HOOK_ADDRESS,
    abi: PACTS_ABI,
    functionName: "pacts",
    args: [pactId],
  });

  // readContract returns a labeled tuple; [3]=jobDescription, [7]=status
  if (Number(pact[7]) !== 0) {
    console.log(`❌ Agent B: Pact is not Open (status=${pact[7]}). Exiting.`);
    process.exit(1);
  }

  console.log(`📋 Agent B: Job — "${pact[3]}"`);
  console.log("🤝 Agent B: Accepting pact...");
  await sdk.accept({ pactId });
  console.log("⚡ Agent B: Accepted pact. Executing job...");

  // Simulate fetching OKB/USDC price
  await sleep(3000);
  const price = Math.random() * 0.5 + 0.3;
  const result = {
    price: parseFloat(price.toFixed(4)),
    timestamp: Date.now(),
    source: "OKX API",
  };
  console.log(`📈 Agent B: Got price — OKB/USDC = ${result.price} (${result.source})`);

  console.log("📤 Agent B: Delivering proof on-chain...");
  await sdk.deliver({ pactId, result });
  console.log("💸 Agent B: Proof delivered. Waiting for payment...");

  // After deliver() the afterSwap callback releases payment atomically —
  // by the time the tx is confirmed, payment is already transferred.
  await sleep(2000);
  console.log("🎉 Agent B: Payment received!");
}

main().catch((err) => {
  console.error("Agent B error:", err.message);
  process.exit(1);
});
