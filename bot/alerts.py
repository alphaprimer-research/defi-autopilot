"""
Telegram alerts for vault bot.
"""

import urllib.request
import urllib.parse
import logging

log = logging.getLogger("alerts")


class TelegramAlert:
    def __init__(self, token, chat_id):
        self.token = token
        self.chat_id = chat_id
        self.enabled = bool(token and chat_id)

    def send(self, msg):
        if not self.enabled:
            return
        try:
            url = f"https://api.telegram.org/bot{self.token}/sendMessage"
            data = urllib.parse.urlencode(
                {"chat_id": self.chat_id, "text": msg, "parse_mode": "Markdown"}
            ).encode()
            urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=10)
        except Exception as e:
            log.error(f"Telegram error: {e}")

    def startup(self, vault_addr, version):
        self.send(f"🟢 *Vault Bot Started*\nVault: `{vault_addr[:10]}...`\nVersion: {version}")

    def rebalance(self, from_name, to_name, to_apy, tx_hash):
        self.send(
            f"🔄 *Rebalanced*\n{from_name} → {to_name}\n"
            f"Target APY: {to_apy:.2f}%\nTX: `{tx_hash[:16]}...`"
        )

    def harvest(self, fees_usd, total_assets_usd):
        self.send(
            f"🌾 *Harvested*\nFees: ${fees_usd:.4f}\n"
            f"Total Assets: ${total_assets_usd:.2f}"
        )

    def daily_report(self, state, best_apy):
        self.send(
            f"📊 *Daily Report*\n"
            f"Assets: ${state['total_assets']/1e6:.2f}\n"
            f"Active: {state['active_name']}\n"
            f"Best APY: {best_apy:.2f}%\n"
            f"Fees: ${state['accrued_fees']/1e6:.4f}"
        )

    def error(self, msg):
        self.send(f"🔴 *Error*\n{msg}")
