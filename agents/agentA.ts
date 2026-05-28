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
const HOOK_ADDRESS = "0x180903457dcFD8ec6EC6f1CA7460595f55d290c0" as Address;
const POOL_MANAGER = "0x45e4598750e4AAA73162d2c2CE292cecBb423cD8" as Address;
// Swap router only needed for agentB (accept/deliver); placeholder is fine here
const SWAP_ROUTER = "0x0000000000000000000000000000000000000001" as Address;

const PACT_ID_FILE = join(__dirname, ".current-pact");

const PACTS_ABI = parseAbi([
  "function pacts(bytes32) view returns (bytes32 id, address agentA, address agentB, string jobDescription, uint256 payment, bytes32 resultHash, uint8 status, uint256 createdAt, uint256 deadline)",
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
      currency1: "0x0000000000000000000000000000000000000000" as Address,
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
    payment: 1_000_000_000_000_000n, // 0.001 OKB
    deadline,
  });

  console.log(`🔑 Agent A: Pact created — ${pactId}`);
  writeFileSync(PACT_ID_FILE, pactId);
  console.log("🔒 Agent A: OKB locked in hook. Waiting for Agent B...");

  while (true) {
    await sleep(5000);

    const pact = await publicClient.readContract({
      address: HOOK_ADDRESS,
      abi: PACTS_ABI,
      functionName: "pacts",
      args: [pactId],
    });

    // pact[6] = status (paymentToken removed, indices shifted)
    const status = Number(pact[6]);
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
