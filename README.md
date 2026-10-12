# AlphaPrimer DeFi Autopilot

Multi-strategy ERC-4626 yield vault on Arbitrum. Routes USDC to the highest-yielding protocol among Aave V3, Compound V3, and Fluid.

## Architecture

- **Vault**: UUPS-upgradeable ERC-4626 (`apUSDC` shares)
- **Protocols**: Aave V3, Compound V3 (Comet), Fluid (fUSDC)
- **Access**: Owner (TimelockController + 4/5 multi-sig) + Strategist (bot, rebalance only)
- **Fees**: Performance (max 20%) + Management (max 2%), high-water-mark based
- **Safety**: Non-custodial, emergency exit, MIN_DEPOSIT, reentrancy guard

## Fee Accounting

Uses a **high-water-mark** model:
- `highWaterMark` records total assets at the last harvest
- Yield = current assets − high-water-mark (only genuine new yield is taxed)
- Deposits/withdrawals adjust the high-water-mark proportionally

## Quick Start

```bash
forge install
forge build
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

## Test Coverage

35 tests across 3 suites, all on Arbitrum fork with real protocol state:
- **AlphaPrimerVault.t.sol**: deposit, withdraw, yield, harvest, access control
- **VaultEdgeCases.t.sol**: zero deposit, dust, large amounts, multi-user, pause, inflation attack
- **RebalanceTest.t.sol**: per-protocol deposit/yield/withdraw, cross-protocol rotation

## Contracts

| File | Description |
|------|-------------|
| `src/AlphaPrimerVault.sol` | Core vault — multi-protocol routing + fee logic |
| `script/Deploy.s.sol` | UUPS proxy deployment on Arbitrum |

## Deployments

| Network | Proxy | Implementation |
|---------|-------|----------------|
| Arbitrum | [`0x87Ef5c25...dF1fa9`](https://arbiscan.io/address/0x87Ef5c25203886b1026ad907E7f84fBAABdF1fa9) | [`0xC351fA4B...D05aeC`](https://arbiscan.io/address/0xC351fA4BfED999bC105B9c63AEf5EC9806D05aeC) |

## Security

- OpenZeppelin v5.7 (ERC-4626, UUPS, Ownable)
- Reentrancy protection via transient storage
- Fee caps hardcoded (max 20% perf, 2% mgmt)
- High-water-mark prevents fee-on-fee compounding
- Emergency exit withdraws all, pauses deposits, users can still redeem
- Strategist can only rebalance — cannot withdraw, upgrade, or change fees

## License

MIT
