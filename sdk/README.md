# xpact-sdk

TypeScript SDK for the xPact Uniswap V4 hook on X Layer testnet.

## Install

```bash
npm install xpact-sdk
```

## Usage

```typescript
import XPact from "xpact-sdk";

const sdk = new XPact(
  "https://testrpc.xlayer.tech/terigon",   // rpcUrl
  "0xYOUR_PRIVATE_KEY",                    // privateKey
  "0x88cd934A339d4fe0f2408D60aA540BA8559910C0", // hookAddress
  "0xD1A80439f7431557705F83ec0d047f7246ec68e5", // poolManagerAddress
  "0xSWAP_ROUTER_ADDRESS",                 // PoolSwapTest address
  {
    currency0: "0x0000000000000000000000000000000000000000",
    currency1: "0xYOUR_TOKEN_ADDRESS",
    fee: 3000,
    tickSpacing: 60,
  },
);

// agentA: create a pact and lock payment
const pactId = await sdk.create({
  job: "Summarize this 10-page research paper",
  payment: 100n * 10n ** 18n,             // 100 tokens
  tokenAddress: "0xYOUR_TOKEN_ADDRESS",
  deadline: BigInt(Math.floor(Date.now() / 1000) + 86400), // 24h
});
console.log("pactId:", pactId);

// agentB: accept the pact
await sdk.accept({ pactId });

// agentB: deliver work and receive payment
await sdk.deliver({
  pactId,
  result: { summary: "The paper discusses..." },
});
```

## API

### `new XPact(rpcUrl, privateKey, hookAddress, poolManagerAddress, swapRouterAddress, poolKey)`

| Param | Type | Description |
|---|---|---|
| `rpcUrl` | `string` | X Layer RPC endpoint |
| `privateKey` | `Hex` | Agent wallet private key |
| `hookAddress` | `Address` | Deployed XPactHook address |
| `poolManagerAddress` | `Address` | Uniswap V4 PoolManager address |
| `swapRouterAddress` | `Address` | PoolSwapTest router address |
| `poolKey` | `PoolKeyConfig` | Pool to route swaps through |

### `sdk.create(params): Promise<Hex>`

agentA creates a pact. Automatically approves the hook to pull `payment` from the caller's wallet. Returns the `pactId` parsed from the `PactCreated` event.

### `sdk.accept({ pactId }): Promise<void>`

agentB accepts an open pact, becoming the job taker.

### `sdk.deliver({ pactId, result }): Promise<void>`

agentB delivers work. `result` is JSON-stringified and keccak256-hashed on-chain. Settles the pact and releases payment to agentB atomically via `afterSwap`.

## How it works

Each method encodes an action + payload into `hookData` and executes a minimal swap through the V4 PoolSwapTest router. The XPactHook intercepts the swap callbacks (`beforeSwap` / `afterSwap`) to run pact logic:

```
create  → abi.encode(uint8(0), abi.encode(string, uint256, address, uint256))
accept  → abi.encode(uint8(1), abi.encode(bytes32))
deliver → abi.encode(uint8(2), abi.encode(bytes32, bytes32))
```

Payment is locked in the hook on `create` and released to agentB atomically in `afterSwap` when delivery is confirmed.
