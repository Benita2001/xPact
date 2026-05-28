# xPact Demo Agents

Two agent scripts demonstrating a full xPact pact lifecycle on X Layer testnet.

## Setup

```bash
cd agents
npm install
```

## Required env vars

| Variable | Description |
|---|---|
| `AGENT_A_KEY` | Private key for agentA (the job poster) |
| `AGENT_B_KEY` | Private key for agentB (the job taker) |
| `SWAP_ROUTER_ADDRESS` | Deployed PoolSwapTest address |
| `USDC_ADDRESS` | Deployed mock ERC20 address (payment token) |

Create a `.env` file (never commit it):

```bash
AGENT_A_KEY=0x...
AGENT_B_KEY=0x...
SWAP_ROUTER_ADDRESS=0x...
USDC_ADDRESS=0x...
```

Pre-fund both wallets with OKB for gas (X Layer testnet faucet).
Pre-mint `USDC_ADDRESS` tokens to agentA's wallet (at least 1 USDC = 1,000,000 units for 6-decimal token).

## Running

Open **two terminals**, both from the `agents/` directory.

**Terminal 1 — agentA (job poster):**

```bash
export $(cat .env | xargs) && tsx agentA.ts
```

**Terminal 2 — agentB (job taker):**

```bash
export $(cat .env | xargs) && tsx agentB.ts
```

Start agentA first. AgentA creates the pact and writes the pactId to `.current-pact`.
AgentB polls that file every 3 seconds, picks up the pactId, accepts the pact, executes the job, and delivers.

## Expected output

**agentA:**
```
🤖 Agent A: Starting up...
📝 Agent A: Creating pact on-chain...
🔑 Agent A: Pact created — 0xabc...
🔒 Agent A: Payment locked in hook. Waiting for Agent B...
📊 Agent A: Pact status — Open
📊 Agent A: Pact status — Active
📊 Agent A: Pact status — Settled
✅ Agent A: Job complete! Agent B was paid.
```

**agentB:**
```
🤖 Agent B: Scanning for open pacts...
....
📌 Agent B: Found pact — 0xabc...
📋 Agent B: Job — "Fetch current OKB/USDC price from OKX API"
🤝 Agent B: Accepting pact...
⚡ Agent B: Accepted pact. Executing job...
📈 Agent B: Got price — OKB/USDC = 0.4231 (OKX API)
📤 Agent B: Delivering proof on-chain...
💸 Agent B: Proof delivered. Waiting for payment...
🎉 Agent B: Payment received!
```

## How it works

```
agentA.create()  →  beforeSwap(_handleCreate)  →  locks payment in hook
agentB.accept()  →  beforeSwap(_handleAccept)  →  pact status: Active
agentB.deliver() →  beforeSwap(_handleDeliver) →  pact status: Settled
                 →  afterSwap(_releasePayout)  →  payment transferred to agentB
```

AgentA polls pact status every 5 seconds via `readContract`. AgentB's payment is released atomically in `afterSwap` — confirmed the moment the deliver tx lands.
