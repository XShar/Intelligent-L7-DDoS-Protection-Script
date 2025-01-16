# Intelligent L7 DDoS Protection Script

This guide describes how to set up an automated monitoring and protection system for L7 (application-level) DDoS attacks using a custom script that interacts with Cloudflare's "Under Attack" mode via API. It allows you to:

- Automatically switch your site to "I'm Under Attack" mode when a high CPU load or a large number of active connections are detected.
- Switch back to normal mode after a certain period of time.
- Send email notifications when an attack is detected and when normal mode is restored.
- Continuously monitor the health of the script itself so it can restart if it crashes.

Below you will find a brief overview of DDoS attacks, the script logic, and step-by-step instructions to set up the system.

---

## Table of Contents
1. [Overview of DDoS Attacks](#overview-of-ddos-attacks)
2. [How to Handle L7 DDoS Attacks](#how-to-handle-l7-ddos-attacks)
3. [Solution Approach](#solution-approach)
4. [Script Flow Diagram](#script-flow-diagram)
5. [Implementation Steps](#implementation-steps)
   1. [Step 1: Environment Preparation](#step-1-environment-preparation)
   2. [Step 2: Getting Cloudflare API Token](#step-2-getting-cloudflare-api-token)
   3. [Step 3: Creating the Monitoring Script](#step-3-creating-the-monitoring-script)
   4. [Step 4: Creating a Supervisor Script](#step-4-creating-a-supervisor-script)
   5. [Step 5: Log Rotation Setup](#step-5-log-rotation-setup)
6. [Conclusion](#conclusion)

---

## Overview of DDoS Attacks

DDoS (Distributed Denial of Service) attacks aim to exhaust resources or disrupt the normal functionality of a target (e.g., a server, a network, or an application). According to the OSI model, DDoS attacks can be grouped as follows:

1. **Layer 2 (L2) – Saturating the Network Bandwidth**  
   These attacks try to fill your internet connection bandwidth to the maximum (e.g., 1 Gbps link saturated with at least 1.1 Gbps traffic). Common examples include amplification attacks (NTP, DNS, RIP, etc.) and various floods (SYN, UDP, ICMP).

2. **Layer 3 (L3) – Network Infrastructure Disruption**  
   Attacks that cause routing issues with BGP, network hijacking, or overflow the network equipment’s connection tracking.  

3. **Layer 4 (L4) – Exploiting TCP Stack Weaknesses**  
   Attacks targeting the transport layer, taking advantage of the complexity of the TCP protocol (including the large table of open connections, each being a finite state machine).

4. **Layer 7 (L7) – Web Application Degradation**  
   These are “custom” attacks on the application layer, such as GET/POST/HTTP floods, or repeated database queries. The goal is to exhaust server resources (CPU, memory, disk I/O).

Most hosting providers or cloud-based DDoS protection (like Cloudflare, DDOSGUARD, etc.) effectively filter attacks up to L4. However, application-level (L7) attacks are more difficult to mitigate because the filtering system must differentiate malicious requests from legitimate ones without impacting the normal site visitors or APIs.

---

## How to Handle L7 DDoS Attacks

Cloudflare does provide a mode called “I’m under attack,” which challenges visitors with a CAPTCHA or JavaScript page, but this can break APIs, cause inconvenience to legitimate users, and is generally not ideal to keep on all the time.

Expensive Cloudflare plans offer intelligent L7 filtering, but these can cost at least \$200 per month—and even then, some attacks might still slip through.

The approach below shows how to automate toggling Cloudflare’s "Under Attack" mode only when truly necessary—based on real server metrics (CPU usage and active connections).

---

## Solution Approach

1. **Continuous Monitoring**  
   A script regularly checks CPU load and the number of active connections in Nginx.  

2. **Threshold-Based Trigger**  
   If either metric exceeds a specified threshold, the script activates Cloudflare’s "Under Attack" mode.  

3. **Scheduled Reversion**  
   After a set duration (e.g., 300 seconds), the script switches Cloudflare’s security level back to default (e.g., `medium`).  

4. **Notifications**  
   The script sends email alerts when it enters or exits "Under Attack" mode.  

5. **Self-Monitoring**  
   Another script (launched via cron) ensures that the main monitoring script is always running, restarting it if it stops for any reason.

---

## Script Flow Diagram
```
            ┌─────────────────────┐
            │      Server         │
            │ (Nginx + system)    │
            └─────────┬───────────┘
                      │
         (1) Collect metrics (CPU, Nginx)
                      │
                      v
 ┌─────────────────────────────────────────────┐
 │  cloudflare_load_monitor.sh script         │
 │   (monitoring + logic to enable            │
 │    "I'm Under Attack" in Cloudflare)       │
 └───────────────────┬────────────────────────┘
                     │
     (2) Check CPU/Conn thresholds
                     │
                     │  Threshold exceeded?
                     │
     ┌────── No ─────┴──────────────────────┐
     │                                      │
     │Yes                                   v
     v                       (3) Enable under_attack
┌─────────────────┐             via Cloudflare API
│   Script waits   │─────────────────────────────────────────┐
│  ATTACK_DURATION │                                         │
└─────────────────┘                                         │
                      (4) After time expires,                │
                          revert mode back to                │
                          DEFAULT_SECURITY_LEVEL             │
                                                              │
                                                              v
                               ┌───────────────────────────┐
(5) Send email  ─────▶│  Email notifications (start/end) │
                      └───────────────────────────┘

```

### Explanation
- **Server (Nginx + system):**  
  Runs Nginx and collects CPU load metrics.
- **(1) Collect metrics:**  
  Uses `mpstat` to read CPU load and `http://127.0.0.1/nginx_status` to fetch the number of active connections.
- **(2) Check thresholds:**  
  Compares CPU load and number of connections with configured thresholds (`CPU_THRESHOLD` and `CONN_THRESHOLD`).
- **(3) Enable “I’m Under Attack” mode:**  
  If thresholds are exceeded, the script calls Cloudflare’s API (PATCH request) to set the security level to `under_attack`.
- **(4) Wait ATTACK_DURATION:**  
  Keeps “I’m Under Attack” for the configured duration (e.g., 300 seconds), periodically checking if a stop file (`/tmp/cloudflare_monitor_stop`) exists.
- **(5) Revert to DEFAULT_SECURITY_LEVEL + Email Notification:**  
  After the waiting period, sets Cloudflare back to default (e.g., `medium`) and sends email alerts about returning to normal mode.

---

## Implementation Steps

### Step 1: Environment Preparation

#### 1. Install necessary packages
- **sysstat** – for the `mpstat` utility (CPU monitoring).
- **mailutils** (or **mailx**) – for sending email alerts.
- **bc** – for arithmetic operations (`echo "100 - idle" | bc -l`).
- **jq** – for processing JSON responses from Cloudflare (optional, but useful).

**On Ubuntu/Debian:**

sudo apt update
sudo apt install -y sysstat mailutils bc jq

**On CentOS/RHEL:**
sudo yum install -y sysstat mailx bc jq

2. Configure Nginx to provide metrics
Enable the ngx_http_stub_status_module (usually built-in by default). Create a dedicated location for status.

Example /etc/nginx/conf.d/status.conf (or you can place inside nginx.conf):
```
server {
    listen 127.0.0.1:80;
    server_name localhost;

    location /nginx_status {
        stub_status;        # Enable stub status module
        allow 127.0.0.1;    # Allow access only from localhost
        deny all;           # Deny everyone else
    }
}
```

Then reload Nginx:

sudo systemctl reload nginx

You can now access metrics at: http://127.0.0.1/nginx_status

### Step 2: Getting Cloudflare API Token

- Go to Cloudflare Dashboard:https://dash.cloudflare.com/profile/api-tokens
- Click Create Custom Token.
- Set Permissions to:
         Zone: Zone Settings: Edit
- Set Zone Resources to:
         Include > Specific zone (or All zones if needed).
- Create the token and copy it (you can only copy the full token once).
- You also need the Zone ID of your domain. You can find it on the Overview page of your Cloudflare dashboard (right-hand panel).

### Step 3: Creating the Monitoring Script

Below is an example bash script that:

Monitors CPU load (via mpstat) and active Nginx connections (via nginx_status).
If thresholds are exceeded, switches Cloudflare to “I’m Under Attack” mode for 5 minutes (300 seconds).

Sends email notifications when entering and leaving attack mode.
Logs events in /var/log/cloudflare_load_monitor.log.

Exits if it sees the file /tmp/cloudflare_monitor_stop.
Save it, for example, as /opt/scripts/cloudflare_load_monitor.sh. Don’t forget to make it executable:

chmod +x /opt/scripts/cloudflare_load_monitor.sh
```
#!/bin/bash
# cloudflare_load_monitor.sh
#
# Monitors CPU load and active Nginx connections. If thresholds are exceeded,
# enables "I'm Under Attack" mode in Cloudflare, then reverts after 5 minutes.

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
```

Key configuration parameters to adjust:
```
#### Cloudflare Settings ####
CF_API_TOKEN="INSERT_YOUR_API_TOKEN"
ZONE_ID="INSERT_YOUR_ZONE_ID"
DEFAULT_SECURITY_LEVEL="medium"
SECURITY_LEVEL_ATTACK="under_attack"
```
```
#### Monitoring Settings ####
CPU_THRESHOLD=90                  # CPU usage threshold in %
CONN_THRESHOLD=2000               # Threshold for active connections
CHECK_INTERVAL=10                 # Interval between checks
ATTACK_DURATION=300               # Duration to hold "I'm Under Attack"
NGINX_STATUS_URL="http://127.0.0.1/nginx_status"
```

Set appropriate values for your environment.

For example, if worker_processes = 3 and worker_connections = 768, the total maximum active connections are ~2304. You might set CONN_THRESHOLD=2000 to trigger the script before full saturation.
CPU_THRESHOLD=90 means “trigger if CPU usage goes above 90%.”

### Step 4: Creating a Supervisor Script

We need to ensure the cloudflare_load_monitor.sh script is always running—even after crashes. The script below checks if the main monitoring script is running. If not, it restarts it with a high priority (nice -n -10).

Save as /opt/scripts/monitor_cloudflare_monitor.sh:

```
#!/bin/bash
# monitor_cloudflare_monitor.sh
#
# Checks if the main monitoring script (cloudflare_load_monitor.sh) is running.
# If not, starts it with higher priority.

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
```

Make it executable:

chmod +x /opt/scripts/monitor_cloudflare_monitor.sh

Cron Job
Add it to crontab to run every minute:
```
crontab -e

* * * * * /opt/scripts/monitor_cloudflare_monitor.sh
```

This way, if the monitoring script ever crashes, it will be relaunched automatically within a minute.

### Step 5: Log Rotation Setup
To prevent /var/log/cloudflare_load_monitor.log from growing indefinitely, configure logrotate.

Create /etc/logrotate.d/cloudflare_load_monitor with:
```
/var/log/cloudflare_load_monitor.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
    endscript
}
```

This will rotate the log daily, keeping up to 7 compressed archives.

### Conclusion

You now have an automated system that:

Monitors CPU load and Nginx connections.
Enables Cloudflare “Under Attack” mode when the server load/connection count exceeds configured thresholds.
Reverts to normal mode after a specified time period.
Sends email alerts for start/end of the protection mode.

Restarts itself if it crashes or is accidentally stopped.
This solution helps mitigate L7 (application-level) DDoS attacks dynamically, without constantly challenging every visitor with CAPTCHAs or JavaScript checks. Feel free to adapt thresholds, durations, and notifications for your environment.

### See forum
https://ru-sfera.pw/threads/intellektualnyj-skript-dlja-zaschity-ot-ddos-na-l7.4833/

### UPDATE - 1

It can still be modified:
A check is performed every 10 seconds, but if it is detected that:
   CPU usage > CPU_THRESHOLD 5 times in a row, protection is activated.
This is a softer filter to prevent false positives.

Under light load in a normal situation, you can set CPU_THRESHOLD=80, which will provide a buffer before activating protection.

```
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
EMAIL_TO="notification_mail@example"         # email for notifications

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
```

### UPDATE - 2

It can still be modified:

Add a check for Apache connections, especially if you are using Nginx + Apache.

It checks the number of connections to Apache; in this example, the protection is activated when the limit of 100 connections is reached.

```
#!/bin/bash
# cloudflare_load_monitor_v3.sh
#
# This script monitors:
#   1) CPU usage,
#   2) The number of active Nginx connections (via ngx_http_stub_status),
#   3) The number of active Apache connections.
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

# Function to get the number of active Apache connections
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
```
### CHECK_INTERVAL=10 can also be changed, for example, to CHECK_INTERVAL=3.
