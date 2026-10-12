# AlphaPrimer DeFi Autopilot

ERC-4626 yield vault on Arbitrum. Deposits USDC into Aave V3 and auto-compounds yield.

## Architecture

- **Vault**: UUPS-upgradeable ERC-4626 (`apUSDC` shares)
- **Strategy**: Aave V3 USDC lending
- **Access**: Owner expected to be `TimelockController` behind a 4/5 multi-sig
- **Fees**: 10% performance + 1% annual management (capped in contract)

## Quick Start

```bash
forge install
forge build
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

## Deployments

| Network | Proxy | Implementation |
|---------|-------|----------------|
| Arbitrum | TBD | TBD |

## Contracts

| File | Description |
|------|-------------|
| `src/AlphaPrimerVault.sol` | Core vault logic |
| `script/Deploy.s.sol` | Deployment script |
| `test/AlphaPrimerVault.t.sol` | Fork-based integration tests |

## Security

- OpenZeppelin v5.7 (ERC-4626, UUPS, Ownable)
- Reentrancy protection via transient storage
- Fee caps hardcoded (max 20% perf, 2% mgmt)
- Emergency exit withdraws all from Aave, pauses deposits
- Users can always withdraw regardless of vault state

## License

MIT
