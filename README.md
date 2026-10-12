# AlphaPrimer DeFi Autopilot

**Non-custodial multi-strategy yield vault on Arbitrum.** Deposits USDC and automatically routes capital to the highest-yielding lending protocol — currently Aave V3, Compound V3, and Fluid.

Users deposit USDC and receive `apUSDC` shares representing their proportional claim on vault assets. A strategist bot continuously monitors lending rates and rebalances when a better opportunity arises. Users can withdraw at any time.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## How It Works

```
User deposits USDC ──► Vault mints apUSDC shares
                            │
                            ▼
                    ┌───────────────┐
                    │   Strategist  │  (bot, limited permissions)
                    │   monitors    │
                    │   APY rates   │
                    └──────┬────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
          ┌───────┐   ┌──────────┐  ┌───────┐
          │Aave V3│   │Compound  │  │ Fluid │
          │       │   │  V3      │  │       │
          └───────┘   └──────────┘  └───────┘

           Capital sits in ONE protocol at a time.
           Bot rebalances when APY difference ≥ 2%.
```

**Non-custodial** means: your USDC is held by the smart contract, not by us. Only you can withdraw your funds. The vault owner cannot move user deposits — only adjust protocol routing and collect earned fees.

---

## Key Features

| Feature | Detail |
|---------|--------|
| **Standard** | ERC-4626 Tokenized Vault (composable with any ERC-4626 integration) |
| **Upgradeability** | UUPS proxy — owner can upgrade logic without moving funds |
| **Yield sources** | Aave V3, Compound V3 (Comet), Fluid (fUSDC) on Arbitrum |
| **Fee model** | High-water-mark: only new yield is taxed, never principal |
| **Performance fee** | Up to 20% of yield (currently 10%) |
| **Management fee** | Up to 2% annually (currently 1%) |
| **Minimum deposit** | 1 USDC |
| **Emergency exit** | Owner can pull all funds from protocols and pause — users can always redeem |
| **Slippage protection** | Fluid deposit/redeem bounded to 0.5% max slippage |

---

## Architecture

### Roles

| Role | Permissions | Who |
|------|-------------|-----|
| **Owner** | Upgrade, set fees, emergency exit, collect fees, set strategist, pause | TimelockController (24h delay) behind 4/5 Gnosis Safe |
| **Strategist** | Rebalance between protocols, harvest fees, deploy idle funds | Automated bot wallet |
| **Users** | Deposit, withdraw, redeem | Anyone |

The strategist **cannot** withdraw user funds, upgrade the contract, change fees, or pause deposits. These actions require the owner (multi-sig + timelock).

### Fee Accounting

The vault uses a **high-water-mark** model to ensure fees are only charged on genuine yield:

1. `highWaterMark` tracks the net asset value after each fee settlement
2. `yield = totalAssets() - highWaterMark` — only positive yield is taxable
3. Performance fee is charged on yield; management fee is time-weighted on the prior NAV
4. Deposits and withdrawals adjust the high-water-mark proportionally
5. Fees are settled automatically on every deposit, mint, withdraw, and redeem — not just on explicit `harvest()` calls

This prevents fee manipulation through deposit timing or exit-before-harvest strategies.

### Protocol Routing

The vault holds capital in **one protocol at a time**. The strategist calls `rebalanceTo(protocolId)` to move all capital when a better rate is available:

| ID | Protocol | Market |
|----|----------|--------|
| 1 | Aave V3 | aUSDC |
| 2 | Compound V3 | cUSDCv3 (Comet) |
| 3 | Fluid | fUSDC |

---

## Deployments

### Arbitrum One

| Contract | Address | Verified |
|----------|---------|----------|
| **Vault (Proxy)** | [`0x87Ef5c25203886b1026ad907E7f84fBAABdF1fa9`](https://arbiscan.io/address/0x87Ef5c25203886b1026ad907E7f84fBAABdF1fa9) | Yes |
| **Implementation** | [`0x18a14fEaA5f220E012Ab9079d5c0e4AdFd85f8E0`](https://arbiscan.io/address/0x18a14fEaA5f220E012Ab9079d5c0e4AdFd85f8E0) | Yes |

### Underlying Protocol Addresses

| Protocol | Address |
|----------|---------|
| USDC (native) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Aave V3 Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| aUSDC | `0x724dc807b04555b71ed48a6896b6F41593b8C637` |
| Compound V3 (Comet) | `0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf` |
| Fluid (fUSDC) | `0x1A996cb54bb95462040408C06122D45D6Cdb6096` |

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast)
- An Arbitrum RPC endpoint

### Build

```bash
git clone https://github.com/alphaprimer-research/defi-autopilot.git
cd defi-autopilot
forge install
forge build
```

### Test

All tests run against a live Arbitrum fork with real protocol state:

```bash
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

### Test Suites

| Suite | Tests | Coverage |
|-------|-------|----------|
| `AlphaPrimerVault.t.sol` | 9 | Core: deposit, withdraw, yield accrual, harvest, access control, version |
| `VaultEdgeCases.t.sol` | 12 | Edge cases: dust deposits, large amounts, multi-user, pause, inflation attack, fee collection |
| `RebalanceTest.t.sol` | 14 | Protocol routing: per-protocol deposit/yield/withdraw, cross-protocol rotation, access control |
| `MainnetEdgeCases.t.sol` | 5 | Deployed vault: fee compounding, donation attack, multi-user proportionality, full drain, permissions |
| `FeeSettlement.t.sol` | 6 | Fee logic: deposit clock-reset protection, exit fee settlement, harvest regression, Fluid slippage |
| **Total** | **46** | |

### Deploy

```bash
export OWNER=<timelock-address>
export STRATEGIST=<bot-wallet-address>
export PRIVATE_KEY=<deployer-private-key>

forge script script/Deploy.s.sol \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --broadcast --verify
```

---

## Security

### Design Principles

- **Non-custodial**: User funds live in the smart contract. Owner cannot transfer user deposits.
- **Separation of roles**: Strategist (bot) can only rebalance and harvest. Cannot withdraw, upgrade, or change parameters.
- **Fee caps hardcoded**: Performance fee capped at 20%, management fee at 2%. Cannot be exceeded even by owner.
- **Inflation resistance**: `_decimalsOffset(6)` plus `MIN_DEPOSIT` and `require(shares > 0)` prevent ERC-4626 donation-based inflation attacks.
- **Reentrancy protection**: All state-changing functions use `ReentrancyGuardTransient` (EIP-1153 transient storage).
- **Fee settlement on entry/exit**: `_settleFees()` is called before every deposit, mint, withdraw, and redeem, preventing fee manipulation through timing.
- **Slippage protection**: Fluid deposits and redeems enforce a 0.5% maximum slippage bound via `previewDeposit`/`previewRedeem` checks.

### Known Limitations

- The vault trusts the underlying protocols (Aave, Compound, Fluid). A vulnerability in any underlying protocol could affect vault funds.
- `max approve` is granted to all three protocols at initialization. This is standard practice but means idle USDC in the vault is exposed if a protocol is compromised.
- Strategist has no slippage protection on Aave/Compound rebalancing (these markets are deep enough that sandwich attacks are not economical at current scale).

### Emergency Procedures

The owner can call `emergencyExit()` to:
1. Withdraw all funds from the active protocol back to the vault
2. Pause new deposits
3. Users can still redeem their shares for USDC at any time

---

## Contracts

| File | Description |
|------|-------------|
| `src/AlphaPrimerVault.sol` | Core vault: multi-protocol routing, ERC-4626, fee settlement, slippage protection |
| `script/Deploy.s.sol` | Deployment script: deploys implementation + ERC1967 proxy on Arbitrum |

---

## Bot

The vault includes an automated strategist bot (`bot/`) that:

- Monitors Aave, Compound, and Fluid lending rates via DefiLlama API
- Rebalances to the highest-yielding protocol when the APY difference exceeds 2%
- Harvests accrued fees on a dynamic schedule based on TVL
- Executes only during low-gas windows (UTC 02:00–06:00) to minimize costs
- Skips harvest when expected fee revenue is below gas cost threshold
- Sends Telegram alerts for rebalances, harvests, daily reports, and errors

See `bot/` directory for setup instructions.

---

## Version History

| Version | Changes |
|---------|---------|
| 3.3.0 | Fee settlement on every entry/exit via `_settleFees()`, Fluid slippage protection (0.5% bound), `MAX_SLIPPAGE_BPS` constant |
| 3.2.0 | Management fee clock fix, `_decimalsOffset(6)`, deposit/mint lastHarvest checkpoint |
| 3.1.0 | Inflation guard, fee ambush prevention, storage gap, reentrancy on all functions |
| 3.0.0 | High-water-mark fee model, mint override, initialize fee caps |
| 2.0.0 | Multi-protocol (Aave + Compound + Fluid), UUPS proxy, strategist role |
| 1.0.0 | Single-protocol Aave vault |

---

## License

MIT
