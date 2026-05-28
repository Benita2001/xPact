import { createPublicClient, http, parseAbi, defineChain, type Hex, type Address } from "viem";
import { writeFileSync } from "fs";
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
// Set SWAP_ROUTER_ADDRESS and USDC_ADDRESS in your env before running
const SWAP_ROUTER = (process.env.SWAP_ROUTER_ADDRESS ?? "0x0000000000000000000000000000000000000001") as Address;
const MOCK_USDC   = (process.env.USDC_ADDRESS        ?? "0x0000000000000000000000000000000000000002") as Address;

const PACT_ID_FILE = join(__dirname, ".current-pact");

const PACTS_ABI = parseAbi([
  "function pacts(bytes32) view returns (bytes32 id, address agentA, address agentB, string jobDescription, uint256 payment, address paymentToken, bytes32 resultHash, uint8 status, uint256 createdAt, uint256 deadline)",
]);

const STATUS_LABEL: Record<number, string> = {
  0: "Open",
  1: "Active",
  2: "Settled",
  3: "Cancelled",
};

async function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  const privateKey = process.env.AGENT_A_KEY as Hex | undefined;
  if (!privateKey) throw new Error("AGENT_A_KEY env var required");

  console.log("🤖 Agent A: Starting up...");

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

  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour from now

  console.log("📝 Agent A: Creating pact on-chain...");
  const pactId = await sdk.create({
    job: "Fetch current OKB/USDC price from OKX API",
    payment: 1_000_000n, // 1 USDC (6 decimals)
    tokenAddress: MOCK_USDC,
    deadline,
  });

  console.log(`🔑 Agent A: Pact created — ${pactId}`);
  writeFileSync(PACT_ID_FILE, pactId);
  console.log("🔒 Agent A: Payment locked in hook. Waiting for Agent B...");

  while (true) {
    await sleep(5000);

    const pact = await publicClient.readContract({
      address: HOOK_ADDRESS,
      abi: PACTS_ABI,
      functionName: "pacts",
      args: [pactId],
    });

    // readContract returns a labeled tuple; access by index [7] = status
    const status = Number(pact[7]);
    console.log(`📊 Agent A: Pact status — ${STATUS_LABEL[status] ?? status}`);

    if (status === 2) {
      console.log("✅ Agent A: Job complete! Agent B was paid.");
      break;
    }
    if (status === 3) {
      console.log("❌ Agent A: Pact was cancelled.");
      break;
    }
  }
}

main().catch((err) => {
  console.error("Agent A error:", err.message);
  process.exit(1);
});
