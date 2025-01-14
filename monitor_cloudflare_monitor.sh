#!/bin/bash
# monitor_cloudflare_monitor.sh
#
# Checks if the main monitoring script (cloudflare_load_monitor.sh) is running.
# If not, starts it with higher priority.
# https://ru-sfera.pw/threads/intellektualnyj-skript-dlja-zaschity-ot-ddos-na-l7.4833/

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG_FILE="/var/log/cloudflare_monitor_supervisor.log"
MONITOR_SCRIPT="/var/local/cloudflare_load_monitor.sh"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Count processes matching the script name
PROCESS_COUNT=$(pgrep -fc "$(basename "$MONITOR_SCRIPT")")

if [ "$PROCESS_COUNT" -eq 0 ]; then
    log "Main monitoring script not found. Starting it with higher priority."
    nohup nice -n -10 "$MONITOR_SCRIPT" >/dev/null 2>&1 &
    sleep 5
    log "Monitoring script started. PID: $!"
else
    log "Monitoring script is already running (count: ${PROCESS_COUNT})."
fi
