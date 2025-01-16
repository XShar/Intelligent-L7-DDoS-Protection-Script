#!/bin/bash
# cloudflare_load_monitor_v2.sh
#
# This script monitors the CPU load and the number of active Nginx connections.
# If it detects that:
#   - CPU usage > CPU_THRESHOLD 5 times in a row, or
#   - the number of active connections > CONN_THRESHOLD (just once),
# then Cloudflare is switched to "under_attack" mode for ATTACK_DURATION seconds,
# and an email notification is sent with the reason for the switch.
#
# To stop this script, create the file /tmp/cloudflare_monitor_stop.

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#### Cloudflare Settings ####
CF_API_TOKEN="INSERT_YOUR_API_TOKEN"
ZONE_ID="INSERT_YOUR_ZONE_ID"
DEFAULT_SECURITY_LEVEL="medium"     # default mode
SECURITY_LEVEL_ATTACK="under_attack"

#### Monitoring Settings ####
CPU_THRESHOLD=80                    # CPU threshold (in %)
CONN_THRESHOLD=2000                 # Nginx connection threshold
CHECK_INTERVAL=10                   # check interval (seconds)
ATTACK_DURATION=300                 # "under_attack" mode duration (seconds)
NGINX_STATUS_URL="http://127.0.0.1/nginx_status"  # URL to retrieve Nginx status

#### Notification Settings ####
EMAIL_TO="info@ru-sfera.pw"         # email for notifications

#### Logging ####
LOG_FILE="/var/log/cloudflare_load_monitor.log"

# Logging function: output to log file and console
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Email sending function
send_email() {
    local subject="$1"
    local message="$2"
    echo "$message" | mail -s "$subject" "$EMAIL_TO"
}

# Function to set security_level via the Cloudflare API
set_cf_security_level() {
    local level="$1"
    log "Changing Cloudflare security mode to: ${level}"
    response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/settings/security_level" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data "{\"value\":\"${level}\"}")
    log "Cloudflare response: $response"
}

# Function to get CPU usage using mpstat
get_cpu_usage() {
    local idle
    # Force LANG=C so mpstat will print "Average"
    idle=$(LANG=C mpstat 1 1 | awk '/Average/ {print $(NF)}')
    if [ -z "$idle" ]; then
        echo 0
    else
        # Calculate usage as 100 - idle (rounded)
        printf "%.0f" "$(echo "100 - $idle" | bc -l)"
    fi
}

# Function to get the number of active Nginx connections.
# Assumes Nginx is configured with ngx_http_stub_status_module.
get_nginx_conn() {
    local status
    status=$(curl -s "$NGINX_STATUS_URL")
    if [ -z "$status" ] || [[ "$status" != *"Active connections:"* ]]; then
        log "Unable to retrieve Nginx status. The worker_connections limit might be exceeded."
        echo 9999
    else
        echo "$status" | awk '/Active connections/ {print $3}'
    fi
}

# Check required commands
if ! command -v mpstat >/dev/null 2>&1; then
    log "mpstat not found. Please install the sysstat package."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    log "jq not found. Please install the jq package."
    exit 1
fi

if ! command -v mail >/dev/null 2>&1; then
    log "mail command not found. Please install the mailutils (or mailx) package to send notifications."
    exit 1
fi

log "Starting Cloudflare monitoring script. PID: $$"

# Counter for consecutive CPU threshold exceedances
CPU_EXCEED_COUNT=0

# Main monitoring loop
while true; do
    # If the stop file exists, terminate
    if [ -f /tmp/cloudflare_monitor_stop ]; then
        log "Detected /tmp/cloudflare_monitor_stop. Stopping the script."
        rm -f /tmp/cloudflare_monitor_stop
        exit 0
    fi

    # Get current metrics:
    CPU_USAGE=$(get_cpu_usage)
    NGINX_CONN=$(get_nginx_conn)
    log "Current CPU load: ${CPU_USAGE}%"
    log "Current number of active Nginx connections: ${NGINX_CONN}"

    # Reset trigger flags
    TRIGGER_CPU=0
    TRIGGER_CONN=0

    # CPU logic: increment counter if threshold is exceeded, otherwise reset
    if [ "$CPU_USAGE" -gt "$CPU_THRESHOLD" ]; then
        CPU_EXCEED_COUNT=$((CPU_EXCEED_COUNT+1))
        log "CPU threshold exceeded. CPU_EXCEED_COUNT = ${CPU_EXCEED_COUNT}"
        # If threshold exceeded 5 times in a row, set TRIGGER_CPU
        if [ "$CPU_EXCEED_COUNT" -ge 5 ]; then
            TRIGGER_CPU=1
            # Reset counter after triggering
            CPU_EXCEED_COUNT=0
        fi
    else
        CPU_EXCEED_COUNT=0
    fi

    # If NGINX_CONN is not a number, consider the condition as not met
    if [[ "$NGINX_CONN" =~ ^[0-9]+$ ]] && [ "$NGINX_CONN" -gt "$CONN_THRESHOLD" ]; then
        TRIGGER_CONN=1
    fi

    # Check if we need to switch to "under_attack" mode
    if [ "$TRIGGER_CPU" -eq 1 ] || [ "$TRIGGER_CONN" -eq 1 ]; then
        REASON=""
        if [ "$TRIGGER_CPU" -eq 1 ]; then
            REASON+="CPU usage exceeded (over ${CPU_THRESHOLD}% 5 times in a row). "
        fi
        if [ "$TRIGGER_CONN" -eq 1 ]; then
            REASON+="Nginx connections exceeded (${NGINX_CONN} > ${CONN_THRESHOLD})."
        fi
        log "Overload conditions detected: $REASON"
        
        # If switching to under_attack mode, send email
        send_email "Enabling 'under_attack' mode" "Switching Cloudflare to 'under_attack' mode due to: $REASON"

        # Switch to under_attack mode
        set_cf_security_level "$SECURITY_LEVEL_ATTACK"

        log "Holding '${SECURITY_LEVEL_ATTACK}' mode for ${ATTACK_DURATION} seconds."
        # Wait in a loop, checking every 10 seconds (stop file can still stop it)
        SECONDS_PASSED=0
        while [ $SECONDS_PASSED -lt $ATTACK_DURATION ]; do
            sleep 10
            SECONDS_PASSED=$((SECONDS_PASSED+10))
            if [ -f /tmp/cloudflare_monitor_stop ]; then
                log "Detected /tmp/cloudflare_monitor_stop during attack mode. Stopping."
                rm -f /tmp/cloudflare_monitor_stop
                exit 0
            fi
        done

        log "Reverting Cloudflare security mode back to '${DEFAULT_SECURITY_LEVEL}'"
        set_cf_security_level "$DEFAULT_SECURITY_LEVEL"
        send_email "Reverting to normal mode" "Reverted to '${DEFAULT_SECURITY_LEVEL}' mode after disabling 'under_attack'."
    fi

    sleep "$CHECK_INTERVAL"
done
