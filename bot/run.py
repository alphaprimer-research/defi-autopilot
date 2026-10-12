#!/usr/bin/env python3
"""
AlphaPrimer Vault Bot — automated yield optimization.

Monitors Aave V3, Compound V3, Fluid lending rates.
Rebalances vault to highest yield. Harvests fees hourly.
"""

import os
import sys
import time
import logging
from pathlib import Path
from datetime import datetime, timezone

from yield_monitor import should_rebalance, get_best_protocol, PROTOCOL_NAMES
from vault_operator import VaultOperator
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

CHECK_INTERVAL = 3600  # 1 hour
REBALANCE_MIN_DIFF = 2.0  # only rebalance if APY diff >= 2%


def load_env():
    env_path = Path(__file__).parent / ".env"
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


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

    log.info(f"Bot started. Interval={CHECK_INTERVAL}s. Dry={dry_run}")

    cycle = 0
    last_daily = datetime.now(timezone.utc).date()

    try:
        while True:
            cycle += 1
            log.info(f"--- Cycle {cycle} ---")

            try:
                state = vault.get_state()
                current = state["active_protocol"]

                rebalance, best, current_apy = should_rebalance(
                    current, REBALANCE_MIN_DIFF
                )

                if rebalance and best:
                    if dry_run:
                        log.info(
                            f"[DRY] Would rebalance {PROTOCOL_NAMES.get(current)} "
                            f"→ {best['project']} ({current_apy:.2f}% → {best['apy']:.2f}%)"
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

                # harvest every cycle
                if dry_run:
                    log.info("[DRY] Would harvest")
                else:
                    try:
                        tx, status = vault.harvest()
                        if status == 1:
                            new_state = vault.get_state()
                            alert.harvest(
                                new_state["accrued_fees"] / 1e6,
                                new_state["total_assets"] / 1e6,
                            )
                    except Exception as e:
                        if "not authorized" not in str(e):
                            raise

                # daily report
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

            time.sleep(CHECK_INTERVAL)

    except KeyboardInterrupt:
        log.info("Shutdown")


if __name__ == "__main__":
    main()
