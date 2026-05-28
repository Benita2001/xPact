import {
  createWalletClient,
  createPublicClient,
  http,
  encodeAbiParameters,
  keccak256,
  toBytes,
  parseAbi,
  defineChain,
  type Hex,
  type Address,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const xLayerTestnet = defineChain({
  id: 1952,
  name: "X Layer Testnet",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://testrpc.xlayer.tech/terigon"] },
  },
});

const POOL_SWAP_TEST_ABI = parseAbi([
  "function swap((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, (bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, (bool takeClaims, bool settleUsingBurn) testSettings, bytes hookData) payable returns (int256)",
]);

const HOOK_ABI = parseAbi([
  "function createPact(string calldata jobDescription, uint256 deadline) external payable returns (bytes32)",
]);

const ACTION_ACCEPT = 1;
const ACTION_DELIVER = 2;

// MIN_SQRT_PRICE + 1; used as price limit for minimal zeroForOne swaps
const SQRT_PRICE_LIMIT = 4295128740n;

// keccak256("PactCreated(bytes32,address,uint256,uint256)")
const PACT_CREATED_SIG = keccak256(
  toBytes("PactCreated(bytes32,address,uint256,uint256)"),
);

export interface PoolKeyConfig {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
}

export interface CreateParams {
  job: string;
  payment: bigint;
  deadline: bigint;
}

export interface AcceptParams {
  pactId: Hex;
}

export interface DeliverParams {
  pactId: Hex;
  result: unknown;
}

export class XPact {
  private readonly wallet: ReturnType<typeof createWalletClient>;
  private readonly client: ReturnType<typeof createPublicClient>;
  private readonly account: ReturnType<typeof privateKeyToAccount>;
  private readonly hookAddress: Address;
  private readonly poolManagerAddress: Address;
  private readonly swapRouterAddress: Address;
  private readonly poolKey: PoolKeyConfig;

  constructor(
    rpcUrl: string,
    privateKey: Hex,
    hookAddress: Address,
    poolManagerAddress: Address,
    swapRouterAddress: Address,
    poolKey: PoolKeyConfig,
  ) {
    this.account = privateKeyToAccount(privateKey);

    this.wallet = createWalletClient({
      account: this.account,
      chain: xLayerTestnet,
      transport: http(rpcUrl),
    });
    this.client = createPublicClient({
      chain: xLayerTestnet,
      transport: http(rpcUrl),
    });
    this.hookAddress = hookAddress;
    this.poolManagerAddress = poolManagerAddress;
    this.swapRouterAddress = swapRouterAddress;
    this.poolKey = poolKey;
  }

  /**
   * agentA: create a pact and lock native OKB payment directly in the hook.
   * Returns the pactId emitted in PactCreated.
   */
  async create({ job, payment, deadline }: CreateParams): Promise<Hex> {
    const hash = await this.wallet.writeContract({
      chain: xLayerTestnet,
      account: this.account,
      address: this.hookAddress,
      abi: HOOK_ABI,
      functionName: "createPact",
      args: [job, deadline],
      value: payment,
    });

    const receipt = await this.client.waitForTransactionReceipt({ hash });

    const log = receipt.logs.find((l) => l.topics[0] === PACT_CREATED_SIG);
    if (!log?.topics[1]) throw new Error("PactCreated event not found in receipt");

    return log.topics[1];
  }

  /**
   * agentB: accept an open pact.
   */
  async accept({ pactId }: AcceptParams): Promise<void> {
    const payload = encodeAbiParameters([{ type: "bytes32" }], [pactId]);

    const hookData = encodeAbiParameters(
      [{ type: "uint8" }, { type: "bytes" }],
      [ACTION_ACCEPT, payload],
    );

    await this._swap(hookData);
  }

  /**
   * agentB: deliver work. Settles the pact and releases OKB payment to agentB.
   * resultHash = keccak256(JSON.stringify(result))
   */
  async deliver({ pactId, result }: DeliverParams): Promise<void> {
    const resultHash = keccak256(toBytes(JSON.stringify(result)));

    const payload = encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [pactId, resultHash],
    );

    const hookData = encodeAbiParameters(
      [{ type: "uint8" }, { type: "bytes" }],
      [ACTION_DELIVER, payload],
    );

    await this._swap(hookData);
  }

  private async _swap(hookData: Hex): Promise<TransactionReceipt> {
    const hash = await this.wallet.writeContract({
      chain: xLayerTestnet,
      account: this.account,
      address: this.swapRouterAddress,
      abi: POOL_SWAP_TEST_ABI,
      functionName: "swap",
      args: [
        {
          currency0: this.poolKey.currency0,
          currency1: this.poolKey.currency1,
          fee: this.poolKey.fee,
          tickSpacing: this.poolKey.tickSpacing,
          hooks: this.hookAddress,
        },
        {
          zeroForOne: true,
          amountSpecified: 1n,
          sqrtPriceLimitX96: SQRT_PRICE_LIMIT,
        },
        { takeClaims: false, settleUsingBurn: false },
        hookData,
      ],
    });

    return this.client.waitForTransactionReceipt({ hash });
  }
}

export default XPact;
