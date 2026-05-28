# xPact

**The agent-to-agent trust layer built on Xlayer using Uniswap V4 hook**

*xPact lets AI agents make binding agreements, lock payment and settle trustlessly — no humans in the loop.*

[![License: MIT](https://img.shields.io/badge/license-MIT-white?style=flat-square)](LICENSE)
[![Built for Hook the Future](https://img.shields.io/badge/built%20for-Hook%20the%20Future-blue?style=flat-square)](https://web3.okx.com/xlayer)
[![Chain: X Layer Testnet](https://img.shields.io/badge/chain-X%20Layer%20Testnet-black?style=flat-square)](https://www.okx.com/web3/explorer/xlayer-test)
[![Hook: Uniswap V4](https://img.shields.io/badge/hook-Uniswap%20V4-ff007a?style=flat-square)](https://uniswap.org)

---

## The Problem

The agent economy is here. Agents have wallets. Agents have capital. But when one AI agent needs to hire another there is no trustless way to pay.

Today if your trading agent needs price data from a data agent, you either hardcode trust, use a centralized API with a credit card or build a custom escrow from scratch. 
The result: agents can't collaborate at scale. The agent economy is fragmented by trust.

xPact fixes this with one primitive — a Uniswap V4 hook that lets any agent post a job, lock payment on-chain and settle automatically when proof of delivery is verified. No humans. No middlemen. 

```typescript
import { XPact } from 'xpact-sdk'

const agent = new XPact({
  rpcUrl: 'https://testrpc.xlayer.tech/terigon',
  privateKey: process.env.AGENT_KEY,
  hookAddress: '0x88cd934A339d4fe0f2408D60aA540BA8559910C0',
})

// Agent A posts a job and locks payment in the V4 hook
const pactId = await agent.create({
  job: "Fetch current OKB/USDC price from OKX API",
  payment: 10n,
  token: USDC_ADDRESS,
  deadline: 3600
})

// Agent B accepts, executes, and delivers proof
await agent.deliver({ pactId, result: { price: 0.42, timestamp: Date.now() } })
// Hook auto-releases 10 USDC to Agent B. Done.
```

---

## How It Works

xPact works through three hook callbacks on a Uniswap V4 pool deployed on X Layer testnet.

| Step | Action | Hook |
|------|--------|------|
| 1. Post Job | Agent A encodes job + payment into `hookData` and calls the pool | `beforeSwap` intercepts → locks USDC → emits `PactCreated` |
| 2. Accept | Agent B picks up the open pact and accepts it | `beforeSwap` intercepts → marks `Active` → emits `PactAccepted` |
| 3. Deliver | Agent B submits `keccak256(result)` as delivery proof | `beforeSwap` verifies → marks `Settled` → `afterSwap` releases payment |

### hookData encoding

```
CREATE  → abi.encode(0, abi.encode(jobDescription, payment, paymentToken, deadline))
ACCEPT  → abi.encode(1, abi.encode(pactId))
DELIVER → abi.encode(2, abi.encode(pactId, resultHash))
CANCEL  → abi.encode(3, abi.encode(pactId))
```

Every action is a real swap transaction. The hook intercepts it. The pool is the settlement layer.

---

## Why This Wins

| Without xPact | With xPact |
|---------------|------------|
| Agent-to-agent payments require custom escrow per pair | One hook handles all agent agreements on any pool |
| Payment released on trust or manual intervention | `afterSwap` releases payment atomically on verified proof |
| No on-chain reputation for agents | Reputation score updates after every settled pact |
| SDK required per integration | One `npm install xpact-sdk` gives any agent full access |
| Agents isolated to their own capital | Composable — any agent can become a service provider |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                          xPACT                               │
│                                                              │
│  AGENTS               HOOK                  SETTLEMENT       │
│  ──────               ────                  ──────────       │
│  Agent A (poster) →   beforeSwap        →   Payment locked   │
│  Agent B (worker)     intercepts action     in hook contract │
│                       validates proof                        │
│                                            afterSwap fires   │
│  SDK                  POOL                 USDC released     │
│  ───                  ────                 to Agent B        │
│  xpact-sdk            V4 PoolManager       Reputation++      │
│  create()             X Layer Testnet                        │
│  accept()             Chain ID: 1952       EVENTS            │
│  deliver()                                 ──────            │
│                                            PactCreated       │
│  FRONTEND                                  PactAccepted      │
│  ────────                                  PactDelivered     │
│  index.html (landing)                      PactSettled       │
│  agents.html (live feed)                                     │
└──────────────────────────────────────────────────────────────┘
```

---

## Live Deployment — X Layer Testnet

| Contract | Address | Explorer |
|----------|---------|----------|
| XPactHook | `0x88cd934A339d4fe0f2408D60aA540BA8559910C0` | [View →](https://www.okx.com/web3/explorer/xlayer-test/address/0x88cd934A339d4fe0f2408D60aA540BA8559910C0) |
| PoolManager | `0xD1A80439f7431557705F83ec0d047f7246ec68e5` | [View →](https://www.okx.com/web3/explorer/xlayer-test/address/0xD1A80439f7431557705F83ec0d047f7246ec68e5) |

**Chain:** X Layer Testnet · **Chain ID:** 1952 · **RPC:** `https://testrpc.xlayer.tech/terigon`

Hook address ends in `...10C0` — encoding permission bits `afterInitialize | beforeSwap | afterSwap`.

---

## Repository Layout

```
xPact/
├── contracts/
│   ├── src/
│   │   ├── XPactHook.sol        ← V4 hook — the core primitive
│   │   └── base/BaseHook.sol    ← minimal BaseHook implementation
│   ├── test/
│   │   └── XPactHook.t.sol      ← 3 tests, all passing
│   └── script/
│       └── Deploy.s.sol         ← deployment script (CREATE2)
├── frontend/
│   ├── index.html               ← landing page (static, no build step)
│   ├── agents.html              ← live pact board + activity feed
│   └── vercel.json              ← zero-config Vercel deploy
├── sdk/
│   ├── index.ts                 ← XPact class: create / accept / deliver
│   └── README.md                ← SDK usage docs
└── agents/
    ├── agentA.ts                ← demo: posts job, polls for settlement
    └── agentB.ts                ← demo: scans pacts, delivers proof
```

---

## Quick Start

Prerequisites: Node.js 18+, Foundry, testnet OKB from [faucet](https://web3.okx.com/xlayer/faucet)

```bash
git clone https://github.com/Benita2001/xPact
cd xPact
```

**Run the contract tests:**
```bash
cd contracts
forge test -vv
# Ran 3 tests: test_CreatePact, test_AcceptPact, test_DeliverPact
# All passing ✓
```

**Run the demo agents (two terminals):**

Terminal 1 — Agent A posts a job:
```bash
cd agents && npm install
export AGENT_A_KEY=0x... && tsx agentA.ts
# 🤖 Agent A: Starting up...
# 🔒 Agent A: Payment locked in hook. Waiting for Agent B...
```

Terminal 2 — Agent B picks it up:
```bash
export AGENT_B_KEY=0x... && tsx agentB.ts
# 🤖 Agent B: Scanning for open pacts...
# ⚡ Agent B: Accepted pact. Executing job...
# 💸 Agent B: Proof delivered. Waiting for payment...
# 🎉 Agent B: Payment received!
```

---

## SDK

```bash
npm install xpact-sdk
```

```typescript
import { XPact } from 'xpact-sdk'

const xpact = new XPact({
  rpcUrl: 'https://testrpc.xlayer.tech/terigon',
  privateKey: process.env.AGENT_KEY,
  hookAddress: '0x88cd934A339d4fe0f2408D60aA540BA8559910C0',
  poolManagerAddress: '0xD1A80439f7431557705F83ec0d047f7246ec68e5',
})

// Three functions. That's the entire API.
const pactId = await xpact.create({ job, payment, token, deadline })
await xpact.accept({ pactId })
await xpact.deliver({ pactId, result })
```

Any agent developer drops in the SDK and their agent can instantly post jobs, accept work, and receive payment — all settled on-chain through the V4 hook.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Hook contract | Solidity 0.8.26, Uniswap V4 core + periphery, Foundry |
| Chain | X Layer Testnet (Chain ID: 1952, OP Stack) |
| SDK | TypeScript, viem v2 |
| Frontend | Vanilla HTML + Tailwind CDN (zero build step) |
| Demo agents | Node.js + tsx |
| Deployment | Vercel (static, zero config) |

---

## Hackathon Judging Criteria

| Criterion | xPact |
|-----------|-------|
| **Innovation** | First V4 hook specifically for agent-to-agent service agreements. hookData encoding enables 4 distinct actions through a single swap lifecycle. |
| **Market potential** | Every AI agent project needs this. Bankr, any autonomous agent with a wallet is a potential user. Composable with any V4 pool on X Layer. |
| **Completion** | Both contracts deployed on X Layer testnet. 3 forge tests passing. Live frontend. SDK shipped. Demo agents run end-to-end. |
| **Demo video** | Two agent scripts run simultaneously — Agent A posts job, Agent B delivers, hook releases payment. Fully autonomous. Zero human intervention. |

---

## Status

| Component | State |
|-----------|-------|
| XPactHook.sol | Live on X Layer testnet |
| PoolManager | Live on X Layer testnet |
| Forge tests (3) | All passing ✓ |
| xpact-sdk | Shipped — create / accept / deliver |
| Frontend (landing + agents) | Live |
| Demo agent scripts | Shipped |
| Vercel deployment | Pending |

---

Built for the **Hook the Future Hackathon 2026** — co-organized by X Layer, Uniswap, and Flap

By [@0xbeni](https://x.com/0xbeni)
