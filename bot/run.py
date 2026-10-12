#!/usr/bin/env python3
"""
AlphaPrimer Vault Bot — automated yield optimization.

Monitors Aave V3, Compound V3, Fluid lending rates on Arbitrum.
Rebalances vault to highest yield. Harvests fees on a dynamic schedule
tuned to TVL and gas conditions.
"""

import os
import sys
import time
import logging
from pathlib import Path
from datetime import datetime, timezone

from yield_monitor import should_rebalance, get_best_protocol
from vault_operator import VaultOperator, PROTOCOL_NAMES
from alerts import TelegramAlert

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    handlers=[
        logging.FileHandler("vault_bot.log"),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("bot")

POLL_INTERVAL = 1800  # check conditions every 30min
REBALANCE_MIN_DIFF = 2.0
MIN_HARVEST_PROFIT_USD = 0.05
ESTIMATED_GAS_USD = 0.04


def load_env():
    env_path = Path(__file__).parent / ".env"
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def get_harvest_interval(tvl_usd):
    """Dynamic harvest interval based on TVL."""
    if tvl_usd >= 500_000:
        return 3600       # 1h
    elif tvl_usd >= 50_000:
        return 21600      # 6h
    elif tvl_usd >= 5_000:
        return 43200      # 12h
    elif tvl_usd >= 1_000:
        return 86400      # 24h
    else:
        return 172800     # 48h


def is_low_gas_window():
    """True during historically cheapest gas hours (UTC)."""
    hour = datetime.now(timezone.utc).hour
    day = datetime.now(timezone.utc).weekday()  # 0=Mon, 5=Sat, 6=Sun
    is_weekend = day >= 5
    if is_weekend and 1 <= hour <= 7:
        return True
    if 2 <= hour <= 5:
        return True
    if 21 <= hour <= 23:
        return True
    return False


def is_harvest_profitable(total_assets, high_water_mark, perf_fee_bps):
    """Check if expected fee exceeds gas cost."""
    if total_assets <= high_water_mark:
        return False
    yield_amount = total_assets - high_water_mark
    expected_fee_usd = (yield_amount * perf_fee_bps / 10000) / 1e6
    return expected_fee_usd > MIN_HARVEST_PROFIT_USD


def main():
    load_env()

    vault_addr = os.environ.get("VAULT_ADDRESS")
    strat_pk = os.environ.get("STRATEGIST_PK")
    rpc = os.environ.get("RPC_URL", "https://arb1.arbitrum.io/rpc")
    tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    tg_chat = os.environ.get("TELEGRAM_CHAT_ID", "")

    if not vault_addr or not strat_pk:
        log.error("Set VAULT_ADDRESS and STRATEGIST_PK in .env")
        sys.exit(1)

    dry_run = "--dry-run" in sys.argv

    vault = VaultOperator(rpc, vault_addr, strat_pk)
    alert = TelegramAlert(tg_token, tg_chat)

    state = vault.log_state()
    if not dry_run:
        alert.startup(vault_addr, state["version"])

    log.info(f"Bot started. Poll={POLL_INTERVAL}s. Dry={dry_run}")

    last_harvest_ts = time.time()
    last_daily = datetime.now(timezone.utc).date()

    try:
        while True:
            try:
                state = vault.get_state()
                current = state["active_protocol"]
                tvl_usd = state["total_assets"] / 1e6
                harvest_interval = get_harvest_interval(tvl_usd)

                log.info(
                    f"TVL=${tvl_usd:.2f} interval={harvest_interval}s "
                    f"low_gas={is_low_gas_window()}"
                )

                # --- rebalance check ---
                rebalance, best, current_apy = should_rebalance(
                    current, REBALANCE_MIN_DIFF
                )

                if rebalance and best and is_low_gas_window():
                    if dry_run:
                        log.info(
                            f"[DRY] Would rebalance {PROTOCOL_NAMES.get(current)} "
                            f"-> {best['project']} ({current_apy:.2f}% -> {best['apy']:.2f}%)"
                        )
                    else:
                        tx, status = vault.rebalance_to(best["protocol_id"])
                        if status == 1:
                            alert.rebalance(
                                PROTOCOL_NAMES.get(current, "?"),
                                best["project"],
                                best["apy"],
                                tx,
                            )

                # --- harvest check ---
                elapsed = time.time() - last_harvest_ts
                should_harvest = (
                    elapsed >= harvest_interval
                    and is_low_gas_window()
                    and is_harvest_profitable(
                        state["total_assets"],
                        state["high_water_mark"],
                        state["perf_fee_bps"],
                    )
                )

                if should_harvest:
                    if dry_run:
                        log.info("[DRY] Would harvest")
                    else:
                        try:
                            tx, status = vault.harvest()
                            if status == 1:
                                last_harvest_ts = time.time()
                                new_state = vault.get_state()
                                alert.harvest(
                                    new_state["accrued_fees"] / 1e6,
                                    new_state["total_assets"] / 1e6,
                                )
                        except Exception as e:
                            if "not authorized" not in str(e):
                                raise
                else:
                    next_harvest = max(0, harvest_interval - elapsed)
                    log.debug(
                        f"Harvest skipped: elapsed={elapsed:.0f}s "
                        f"interval={harvest_interval}s next_in={next_harvest:.0f}s "
                        f"low_gas={is_low_gas_window()} "
                        f"profitable={is_harvest_profitable(state['total_assets'], state['high_water_mark'], state['perf_fee_bps'])}"
                    )

                # --- daily report ---
                today = datetime.now(timezone.utc).date()
                if today != last_daily:
                    state = vault.log_state()
                    best_info = get_best_protocol()
                    best_apy = best_info["apy"] if best_info else 0
                    if not dry_run:
                        alert.daily_report(state, best_apy)
                    last_daily = today

            except Exception as e:
                log.error(f"Cycle error: {e}", exc_info=True)
                if not dry_run:
                    alert.error(str(e)[:200])

            time.sleep(POLL_INTERVAL)

    except KeyboardInterrupt:
        log.info("Shutdown")


if __name__ == "__main__":
    main()
