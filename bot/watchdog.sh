#!/bin/bash
# Vault bot watchdog — runs via cron every 30 min.
# Checks if bot is alive + last log within 2 hours.
# Sends Telegram alert if dead or stale.
# Reads credentials from .env in the same directory.

BOT_SERVICE="vault-bot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STALE_SECONDS=7200  # 2 hours

# load from .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    TG_TOKEN=$(grep TELEGRAM_BOT_TOKEN "$SCRIPT_DIR/.env" | cut -d= -f2)
    TG_CHAT=$(grep TELEGRAM_CHAT_ID "$SCRIPT_DIR/.env" | cut -d= -f2)
    TG_THREAD=$(grep TELEGRAM_THREAD_ID "$SCRIPT_DIR/.env" | cut -d= -f2)
fi

[ -z "$TG_TOKEN" ] && exit 0

send_alert() {
    local params="chat_id=${TG_CHAT}&text=$1&parse_mode=Markdown"
    [ -n "$TG_THREAD" ] && params="${params}&message_thread_id=${TG_THREAD}"
    curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "$params" > /dev/null 2>&1
}

# check systemd service
if ! systemctl is-active --quiet "$BOT_SERVICE"; then
    send_alert "🔴 *WATCHDOG*: vault-bot is DOWN. systemd status: $(systemctl is-active $BOT_SERVICE)"
    exit 1
fi

# check last log timestamp
LAST_LOG=$(journalctl -u "$BOT_SERVICE" --no-pager -n 1 --output=short-unix 2>/dev/null | tail -1 | awk '{print $1}' | cut -d. -f1)
NOW=$(date +%s)

if [ -n "$LAST_LOG" ] && [ "$LAST_LOG" -gt 0 ] 2>/dev/null; then
    AGE=$((NOW - LAST_LOG))
    if [ "$AGE" -gt "$STALE_SECONDS" ]; then
        HOURS=$((AGE / 3600))
        send_alert "🟡 *WATCHDOG*: vault-bot alive but no logs for ${HOURS}h. May be stuck."
        exit 1
    fi
fi

exit 0
