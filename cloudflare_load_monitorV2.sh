#!/bin/bash
# cloudflare_load_monitorV2.sh
#
# This script monitors:
#   1) CPU usage,
#   2) The number of active Nginx connections (via ngx_http_stub_status),
#   3) The number of active Apache connections (without using mod_status).
#
# If any of the following conditions is met:
#   - CPU usage > CPU_THRESHOLD for 5 consecutive checks, or
#   - The number of Nginx connections > CONN_THRESHOLD (once), or
#   - The number of Apache connections > APACHE_CONN_THRESHOLD (once),
# then Cloudflare is switched into "under_attack" mode for ATTACK_DURATION seconds,
# and email notifications are sent with the reason for the switch.
#
# To stop the script, create the file /tmp/cloudflare_monitor_stop.

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#############################################
#### Cloudflare Settings ####################
#############################################
CF_API_TOKEN="Replace_with_your_real_API_token"    # <-- Replace with your real API token
ZONE_ID="Replace_with_your_real_zone_id"            # <-- Replace with your real zone_id
DEFAULT_SECURITY_LEVEL="medium"                     # default security level
SECURITY_LEVEL_ATTACK="under_attack"

#############################################
#### Monitoring Settings ####################
#############################################
CPU_THRESHOLD=80                   # CPU threshold (in %)
CONN_THRESHOLD=2000                # Nginx connections threshold
APACHE_CONN_THRESHOLD=100          # Apache connections threshold
CHECK_INTERVAL=10                  # interval between checks (seconds)
ATTACK_DURATION=300                # duration of "under_attack" mode (seconds)

NGINX_STATUS_URL="http://127.0.0.1/nginx_status"  # URL for retrieving Nginx status (using ngx_http_stub_status)

#############################################
#### Apache Monitoring Settings #############
#############################################
APACHE_PORT=8080                   # Port on which Apache is listening (as defined in your VirtualHost)
APACHE_PROCESS_NAME="apache2"      # Apache process name (for Debian/Ubuntu: apache2, for CentOS/RHEL: httpd)

#############################################
#### Notification Settings ##################
#############################################
EMAIL_TO="notification_email@example.com"        # email address for notifications

#############################################
#### Logging Settings #######################
#############################################
LOG_FILE="/var/log/cloudflare_load_monitor.log"

# Logging function: outputs message to the log file and the console
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Email sending function
send_email() {
    local subject="$1"
    local message="$2"
    echo "$message" | mail -s "$subject" "$EMAIL_TO"
}

# Function to set the Cloudflare security level via API
set_cf_security_level() {
    local level="$1"
    log "Changing Cloudflare security level to: ${level}"
    response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/settings/security_level" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data "{\"value\":\"${level}\"}")
    log "Cloudflare response: $response"
}

# Function to get CPU usage using mpstat
get_cpu_usage() {
    local idle
    # Force LANG=C to ensure mpstat outputs "Average"
    idle=$(LANG=C mpstat 1 1 | awk '/Average/ {print $(NF)}')
    if [ -z "$idle" ]; then
        echo 0
    else
        # Calculate CPU usage as 100 - idle (rounded)
        printf "%.0f" "$(echo "100 - $idle" | bc -l)"
    fi
}

# Function to get the number of active Nginx connections.
# Assumes that Nginx is configured with ngx_http_stub_status_module.
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

# Function to get the number of active Apache connections without mod_status
get_apache_conn() {
    # Uses ss to count established (ESTAB) connections on the Apache port.
    # Requires that Apache is listening on 127.0.0.1:APACHE_PORT and its processes are named appropriately.
    local port="$APACHE_PORT"
    local process="$APACHE_PROCESS_NAME"

    local conn_count
    conn_count=$(ss -tanp | awk -v port="$port" -v proc="$process" '
        $1=="ESTAB" && $4 ~ ":"port"$" && $0 ~ proc { count++ }
        END { print count+0 }
    ')
    echo "$conn_count"
}

# Check for necessary commands
if ! command -v mpstat >/dev/null 2>&1; then
    log "mpstat not found. Please install the sysstat package."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    log "jq not found. Please install the jq package."
    exit 1
fi

if ! command -v mail >/dev/null 2>&1; then
    log "The mail utility not found. Please install mailutils (or mailx) for notifications."
    exit 1
fi

# Check availability of the Nginx status page
if ! curl -s "$NGINX_STATUS_URL" | grep -q "Active connections"; then
    log "Unable to retrieve Nginx status. Ensure Nginx is configured with ngx_http_stub_status_module and available at $NGINX_STATUS_URL."
    exit 1
fi

log "Starting Cloudflare load monitoring script. PID: $$"

# Counter for consecutive CPU threshold exceedances
CPU_EXCEED_COUNT=0

# Main monitoring loop
while true; do
    # Stop the script if the stop file is found
    if [ -f /tmp/cloudflare_monitor_stop ]; then
        log "Stop file /tmp/cloudflare_monitor_stop found. Exiting script."
        rm -f /tmp/cloudflare_monitor_stop
        exit 0
    fi

    # Get current metrics
    CPU_USAGE=$(get_cpu_usage)
    NGINX_CONN=$(get_nginx_conn)
    APACHE_CONN=$(get_apache_conn)

    log "Current CPU Usage: ${CPU_USAGE}%"
    log "Current number of active Nginx connections: ${NGINX_CONN}"
    log "Current number of active Apache connections: ${APACHE_CONN}"

    # Reset trigger flags
    TRIGGER_CPU=0
    TRIGGER_CONN=0
    TRIGGER_APACHE=0

    # CPU logic: increase counter if threshold exceeded, otherwise reset
    if [ "$CPU_USAGE" -gt "$CPU_THRESHOLD" ]; then
        CPU_EXCEED_COUNT=$((CPU_EXCEED_COUNT+1))
        log "CPU threshold exceeded. CPU_EXCEED_COUNT = ${CPU_EXCEED_COUNT}"
        # Trigger if threshold exceeded 5 times in a row
        if [ "$CPU_EXCEED_COUNT" -ge 5 ]; then
            TRIGGER_CPU=1
            CPU_EXCEED_COUNT=0
        fi
    else
        CPU_EXCEED_COUNT=0
    fi

    # Nginx connections logic
    if [[ "$NGINX_CONN" =~ ^[0-9]+$ ]] && [ "$NGINX_CONN" -gt "$CONN_THRESHOLD" ]; then
        TRIGGER_CONN=1
    fi

    # Apache connections logic
    if [[ "$APACHE_CONN" =~ ^[0-9]+$ ]] && [ "$APACHE_CONN" -gt "$APACHE_CONN_THRESHOLD" ]; then
        TRIGGER_APACHE=1
    fi

    # Check if any trigger condition is met
    if [ "$TRIGGER_CPU" -eq 1 ] || [ "$TRIGGER_CONN" -eq 1 ] || [ "$TRIGGER_APACHE" -eq 1 ]; then
        REASON=""
        [ "$TRIGGER_CPU" -eq 1 ] && REASON+="CPU usage exceeded (over ${CPU_THRESHOLD}% for 5 consecutive checks). "
        [ "$TRIGGER_CONN" -eq 1 ] && REASON+="Nginx connections exceeded (${NGINX_CONN} > ${CONN_THRESHOLD}). "
        [ "$TRIGGER_APACHE" -eq 1 ] && REASON+="Apache connections exceeded (${APACHE_CONN} > ${APACHE_CONN_THRESHOLD})."
        log "Overload conditions detected: $REASON"

        # Send email notification
        send_email "Activating 'under_attack' mode" "Switching Cloudflare to '${SECURITY_LEVEL_ATTACK}' mode due to: $REASON"

        # Switch Cloudflare to under_attack mode
        set_cf_security_level "$SECURITY_LEVEL_ATTACK"

        log "Maintaining '${SECURITY_LEVEL_ATTACK}' mode for ${ATTACK_DURATION} seconds."
        SECONDS_PASSED=0
        while [ $SECONDS_PASSED -lt $ATTACK_DURATION ]; do
            sleep 10
            SECONDS_PASSED=$((SECONDS_PASSED+10))
            if [ -f /tmp/cloudflare_monitor_stop ]; then
                log "Stop file found during attack mode. Exiting script."
                rm -f /tmp/cloudflare_monitor_stop
                exit 0
            fi
        done

        log "Reverting Cloudflare security level to '${DEFAULT_SECURITY_LEVEL}'"
        set_cf_security_level "$DEFAULT_SECURITY_LEVEL"
        send_email "Restoring normal mode" "Cloudflare reverted to '${DEFAULT_SECURITY_LEVEL}' mode after attack mode."
    fi

    sleep "$CHECK_INTERVAL"
done
