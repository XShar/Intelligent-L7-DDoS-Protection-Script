#!/bin/bash
# cloudflare_load_monitor.sh
#
# Monitors CPU load and active Nginx connections. If thresholds are exceeded,
# enables "I'm Under Attack" mode in Cloudflare, then reverts after 5 minutes.
# https://ru-sfera.pw/threads/intellektualnyj-skript-dlja-zaschity-ot-ddos-na-l7.4833/

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#### Cloudflare Settings ####
CF_API_TOKEN="INSERT_YOUR_API_TOKEN"
ZONE_ID="INSERT_YOUR_ZONE_ID"
DEFAULT_SECURITY_LEVEL="medium"
SECURITY_LEVEL_ATTACK="under_attack"

#### Monitoring Settings ####
CPU_THRESHOLD=90                  # CPU usage threshold in %
CONN_THRESHOLD=2000               # Threshold for active Nginx connections
CHECK_INTERVAL=10                 # Check interval in seconds
ATTACK_DURATION=300               # Duration to hold "I'm Under Attack" mode
NGINX_STATUS_URL="http://127.0.0.1/nginx_status"

#### Notification Settings ####
EMAIL_TO="admin@example.com"      # Where to send notifications

#### Logging ####
LOG_FILE="/var/log/cloudflare_load_monitor.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Send email function
send_email() {
    local subject="$1"
    local message="$2"
    echo "$message" | mail -s "$subject" "$EMAIL_TO"
}

# Set security level in Cloudflare
set_cf_security_level() {
    local level="$1"
    log "Changing Cloudflare security level to: ${level}"
    response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/settings/security_level" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data "{\"value\":\"${level}\"}")
    log "Cloudflare response: $response"
}

# Get CPU usage
get_cpu_usage() {
    local idle
    idle=$(LANG=C mpstat 1 1 | awk '/Average/ {print $(NF)}')
    if [ -z "$idle" ]; then
        echo 0
    else
        printf "%.0f" "$(echo "100 - $idle" | bc -l)"
    fi
}

# Function to get the number of active Nginx connections.
# Assumes that Nginx is configured with ngx_http_stub_status_module.
# If the status page is unavailable (e.g. due to exhausted worker_connections),
# the function returns CONN_THRESHOLD+1 to trigger protection.
get_nginx_conn() {
    local status
    status=$(curl -s "$NGINX_STATUS_URL")
    if [ -z "$status" ] || [[ "$status" != *"Active connections:"* ]]; then
        log "Unable to retrieve Nginx status. Possibly worker_connections are exhausted."
        echo $((CONN_THRESHOLD + 1))
    else
        echo "$status" | awk '/Active connections/ {print $3}'
    fi
}

# Check that necessary utilities exist
if ! command -v mpstat >/dev/null 2>&1; then
    log "mpstat not found. Please install sysstat."
    exit 1
fi

if ! command -v mail >/dev/null 2>&1; then
    log "mail utility not found. Please install mailutils (or mailx)."
    exit 1
fi

log "Starting Cloudflare monitoring script. PID: $$"

while true; do
    # If /tmp/cloudflare_monitor_stop exists — exit
    if [ -f /tmp/cloudflare_monitor_stop ]; then
        log "Found /tmp/cloudflare_monitor_stop, exiting."
        rm -f /tmp/cloudflare_monitor_stop
        exit 0
    fi

    CPU_USAGE=$(get_cpu_usage)
    NGINX_CONN=$(get_nginx_conn)

    log "Current CPU usage: ${CPU_USAGE}%"
    log "Current active connections: ${NGINX_CONN}"

    TRIGGER_CPU=0
    TRIGGER_CONN=0

    [ "$CPU_USAGE" -gt "$CPU_THRESHOLD" ] && TRIGGER_CPU=1

    if [[ "$NGINX_CONN" =~ ^[0-9]+$ ]] && [ "$NGINX_CONN" -gt "$CONN_THRESHOLD" ]; then
        TRIGGER_CONN=1
    fi

    if [ "$TRIGGER_CPU" -eq 1 ] || [ "$TRIGGER_CONN" -eq 1 ]; then
        REASON=""
        [ "$TRIGGER_CPU" -eq 1 ] && REASON+="CPU usage is above threshold (${CPU_USAGE}%). "
        [ "$TRIGGER_CONN" -eq 1 ] && REASON+="Connections count is above threshold (${NGINX_CONN})."

        log "Overload condition detected: $REASON"
        send_email "Enabling 'I'm Under Attack' mode" \
                   "Cloudflare 'under_attack' mode enabled. Reason: $REASON"

        set_cf_security_level "$SECURITY_LEVEL_ATTACK"

        log "Holding '${SECURITY_LEVEL_ATTACK}' mode for ${ATTACK_DURATION} seconds..."
        SECONDS_PASSED=0
        while [ $SECONDS_PASSED -lt $ATTACK_DURATION ]; do
            sleep 10
            SECONDS_PASSED=$((SECONDS_PASSED+10))
            if [ -f /tmp/cloudflare_monitor_stop ]; then
                log "Found /tmp/cloudflare_monitor_stop during attack mode, exiting."
                exit 0
            fi
        done

        log "Reverting security level to '${DEFAULT_SECURITY_LEVEL}'"
        set_cf_security_level "$DEFAULT_SECURITY_LEVEL"
        send_email "Returning to normal mode" \
                   "Under_attack mode disabled. Back to '${DEFAULT_SECURITY_LEVEL}'."
    fi

    sleep "$CHECK_INTERVAL"
done
