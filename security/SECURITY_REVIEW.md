# AlphaPrimerVault — Security Review

| Field | Value |
|-------|-------|
| Protocol | AlphaPrimer DeFi Autopilot |
| Contract | `AlphaPrimerVault.sol` — UUPS Upgradeable ERC-4626 |
| Chain | Arbitrum One |
| Underlying | USDC |
| Version Reviewed | 3.2.0 (initial) through 3.5.2 (current) |
| Review Period | October 2026 |
| Status | **All findings resolved** |

---

## Scope

The review covered `AlphaPrimerVault.sol`, a UUPS-upgradeable ERC-4626 vault that accepts USDC deposits and routes them to one of three lending protocols (Aave V3, Compound V3, Fluid) on Arbitrum. The vault implements a high-water-mark fee model with performance and management fees, role-separated access (owner, strategist, guardian), and emergency exit functionality.

The following areas were examined:
- Share minting and redemption logic (ERC-4626 compliance)
- Fee calculation (performance fee, management fee, high-water-mark)
- Protocol routing and rebalancing
- Access control and role separation
- Upgrade safety (UUPS proxy pattern)
- Known DeFi attack vectors (inflation, fee manipulation, flash loan, reentrancy)

---

## Summary

| Severity | Found | Resolved |
|----------|-------|----------|
| Medium | 5 | 5 |
| Low | 3 | 3 |
| **Total** | **8** | **8** |

All findings were resolved across versions 3.2.0 through 3.5.2. No outstanding issues remain.

---

## Findings

### SR-01 — Fee calculation compared gross to net values (Medium)

**Description:** The `harvest()` function compared gross asset value against a net high-water-mark (after fee deduction). On repeated calls, previously booked fees were counted as new yield, allowing fee accumulation beyond intended rates.

**Impact:** A strategist calling `harvest()` multiple times in sequence could inflate `accruedFees` beyond the intended performance fee rate. Requires a trusted role.

**Resolution:** `harvest()` now uses consistent NAV-based comparison. Repeated calls in the same state produce no additional fees. Verified with a 30-iteration loop test confirming fees remain constant after the first call.

---

### SR-02 — Inherited `mint()` bypassed vault protections (Medium)

**Description:** The ERC-4626 `mint()` function inherited from OpenZeppelin was not overridden. This allowed deposits through `mint()` to bypass the pause check, minimum deposit requirement, and high-water-mark update.

**Impact:** During a paused state, deposits could still enter the vault through the `mint()` entry point.

**Resolution:** `mint()` is now overridden with the same guards as `deposit()`. Both `maxMint()` and `maxDeposit()` return 0 when paused. Verified that `mint()` reverts when paused and respects the minimum deposit.

---

### SR-03 — First depositor inflation attack on empty vault (Medium)

**Description:** An empty vault with any idle USDC (from a stray transfer or airdrop) could cause the first depositor to receive zero shares due to ERC-4626 share calculation rounding: `shares = assets * (supply + 1) / (totalAssets + 1)`. With large idle USDC, this rounds to zero.

**Impact:** First depositor loses their entire deposit with no shares minted. Funds become unrecoverable without a proxy upgrade.

**Resolution:** Applied three mitigations:
1. `_decimalsOffset()` returns 6, increasing virtual share precision
2. `require(shares > 0)` added to both `deposit()` and `mint()`
3. Donation-based inflation is now economically impractical due to the offset

Verified with a $10K idle USDC scenario: deposit correctly mints proportional shares. A $1M idle scenario triggers the `zero shares` revert, protecting the depositor's USDC.

---

### SR-04 — Initialization accepted uncapped fee values (Medium)

**Description:** The `initialize()` function did not validate that fee parameters fell within acceptable bounds. Performance and management fees could be set to 100% at deployment.

**Impact:** A misconfigured deployment could set fees to 100%, draining all yield from depositors.

**Resolution:** `initialize()` now enforces `require(perfFee_ <= MAX_PERF_FEE && mgmtFee_ <= MAX_MGMT_FEE)`. Verified that initialization with 100% fees reverts.

---

### SR-05 — Fee rate change taxed pending yield retroactively (Medium)

**Description:** `setFees()` did not call `harvest()` before updating fee rates. An owner increasing the performance fee from 10% to 20% would tax already-accrued (but unharvested) yield at the new higher rate.

**Impact:** Depositors could lose more yield than expected if fee rates are increased without a prior harvest.

**Resolution:** `setFees()` now internally calls `harvest()` before applying new rates, booking all pending yield at the original rate. Additionally, `setFees()` is now `nonReentrant`. Verified that a fee increase from 10% to 20% correctly books pending yield at 10%.

---

### SR-06 — Strategist could be set to zero address (Low)

**Description:** `setStrategist()` accepted `address(0)`, which would permanently lock out the strategist role and prevent rebalancing or harvesting.

**Resolution:** Added `require(s != address(0), "zero strategist")`. Same guard added to `setGuardian()`.

---

### SR-07 — Missing reentrancy guards on state-changing functions (Low)

**Description:** Several state-changing functions (`harvest`, `rebalanceTo`, `collectFees`, `emergencyExit`) lacked `nonReentrant` modifiers. While no direct reentrancy path was identified through the current protocol integrations, the absence of guards posed a defense-in-depth concern.

**Resolution:** `nonReentrant` modifier added to all state-changing external functions.

---

### SR-08 — Missing storage gap for upgrade safety (Low)

**Description:** The contract did not reserve a storage gap (`__gap`) for future upgradeable storage variables. Adding new state variables in a future version could corrupt existing storage layout.

**Resolution:** Added `uint256[40] private __gap` at the end of the contract storage.

---

## Historic Attack Vector Analysis

The vault was tested against known DeFi exploit patterns:

| Attack Pattern | Result |
|----------------|--------|
| Harvest Finance ($34M, LP spot price manipulation) | **Not applicable.** Share price derived from aToken/Comet/fUSDC balance, not LP spot price. Flash loan round-trip loses 5 bps. |
| PancakeBunny ($45M, reward token mint) | **Not applicable.** No reward token minting. `harvest()` does not affect `totalSupply`. |
| Pickle Finance ($20M, malicious strategy jar) | **Not applicable.** `rebalanceTo()` only accepts protocol IDs `{1, 2, 3}`. No arbitrary strategy injection. |
| Belt Finance ($6.2M, stranded funds in old strategy) | **Not applicable.** After rebalancing, inactive protocol balance is verified as zero. |
| Same-TX flash deposit-harvest-withdraw | **Not exploitable.** `harvest()` requires `onlyStrategistOrOwner`. Without harvest, attacker loses to rounding. |
| ERC-4626 inflation (first depositor) | **Mitigated.** Decimal offset + zero-share revert. See SR-03. |

---

## Deployment Verification

The following was verified on the live Arbitrum deployment:

- Vault proxy points to the reviewed implementation
- Owner is a TimelockController (24h delay), not an EOA
- TimelockController proposer/executor is a 4/5 Safe multisig
- Guardian is a separate address from the owner
- Strategist is a dedicated bot wallet (cannot withdraw or upgrade)
- Underlying protocol addresses (Aave Pool, aUSDC, Compound Comet, Fluid fUSDC) are the canonical Arbitrum native-USDC markets
- All findings from this review are resolved in the deployed version

---

## Conclusion

Eight findings were identified across the review period. All have been resolved in the current deployment (v3.5.2). No user-fund-draining vulnerabilities remain in the reviewed code.

The vault depends on the security of its underlying protocols (Aave V3, Compound V3, Fluid). A vulnerability in any of these could affect vault funds. The UUPS upgrade pattern means the owner (Timelock + Safe multisig) retains the ability to modify contract logic, subject to a 24-hour delay.
