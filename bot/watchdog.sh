#!/bin/bash
# Vault bot watchdog — runs via cron every 30 min.
# Checks if bot is alive + last log within 2 hours.
# Sends Telegram alert if dead or stale.

BOT_SERVICE="vault-bot"
TG_TOKEN="8594403416:AAHnZPhr3vM-LSAVV3XMiDajhIMaolYknrI"
TG_CHAT="-1004244532414"
TG_THREAD="23"
STALE_SECONDS=7200  # 2 hours

send_alert() {
    curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" \
        -d "message_thread_id=${TG_THREAD}" \
        -d "text=$1" \
        -d "parse_mode=Markdown" > /dev/null 2>&1
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
