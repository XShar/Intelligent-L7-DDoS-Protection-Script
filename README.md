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

# Get number of active Nginx connections
get_nginx_conn() {
    local status
    status=$(curl -s "$NGINX_STATUS_URL")
    echo "$status" | awk '/Active connections/ {print $3}'
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
