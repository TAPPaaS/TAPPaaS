#!/usr/bin/env bash
#
# TAPPaaS SSD lifecycle management (issue #152)
#
# Runs on a Proxmox node. Idempotent. Performs three things:
#   1. Sets autotrim=on on every imported zpool
#   2. Installs /etc/cron.weekly/tappaas-zpool-trim
#   3. Installs /etc/cron.monthly/tappaas-ssd-health
#
# smartmontools must already be installed. install.sh handles that for new
# nodes; update.sh apt-installs it on existing nodes before invoking this.
#
# Usage: ./setup-ssd-lifecycle.sh
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "setup-ssd-lifecycle.sh must run as root" >&2
    exit 1
fi

# 1. Enable autotrim on all imported zpools.
if command -v zpool >/dev/null 2>&1; then
    for pool in $(zpool list -H -o name 2>/dev/null); do
        current=$(zpool get -H -o value autotrim "$pool" 2>/dev/null || echo "")
        if [[ "$current" != "on" ]]; then
            echo "Setting autotrim=on on $pool"
            zpool set autotrim=on "$pool"
        fi
    done
fi

# 2. Weekly explicit TRIM. autotrim handles incremental TRIM on free;
#    this job reclaims fragmented free space autotrim may skip.
cat >/etc/cron.weekly/tappaas-zpool-trim <<'CRON'
#!/usr/bin/env bash
# TAPPaaS weekly explicit zpool TRIM (issue #152)
set -euo pipefail

LOG=/var/log/tappaas-trim.log
exec >>"$LOG" 2>&1

echo "=== $(date -Is) tappaas-zpool-trim start ==="
if ! command -v zpool >/dev/null 2>&1; then
    echo "zpool not installed; nothing to do"
    exit 0
fi

for pool in $(zpool list -H -o name 2>/dev/null); do
    if zpool status "$pool" | grep -qE "trimming|trim in progress"; then
        echo "$pool: trim already in progress, skipping"
        continue
    fi
    echo "$pool: starting trim"
    if ! zpool trim "$pool" 2>&1; then
        logger -t tappaas-zpool-trim -p daemon.warning \
            "zpool trim failed on $pool"
    fi
done
echo "=== $(date -Is) tappaas-zpool-trim end ==="
CRON
chmod 755 /etc/cron.weekly/tappaas-zpool-trim

# 3. Monthly SSD health report. Warnings emit via syslog (journald).
#    Read the full report at /var/log/tappaas-ssd-health.log.
cat >/etc/cron.monthly/tappaas-ssd-health <<'CRON'
#!/usr/bin/env bash
# TAPPaaS monthly SSD health report (issue #152)
set -euo pipefail

LOG=/var/log/tappaas-ssd-health.log
exec >>"$LOG" 2>&1

echo "=== $(date -Is) tappaas-ssd-health start ==="
if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl not installed; nothing to do"
    exit 0
fi

# Wear thresholds: warn at >=80% used, critical at >=90% used.
WARN_USED=80
CRIT_USED=90

mapfile -t devs < <(lsblk -dn -o NAME,TYPE 2>/dev/null \
    | awk '$2=="disk"{print "/dev/"$1}' \
    | grep -Ev '/dev/(loop|zd|ram|rbd|md|dm-)')

for dev in "${devs[@]}"; do
    [[ -b "$dev" ]] || continue
    echo "--- $dev ---"
    out=$(smartctl -A -H "$dev" 2>&1 || true)
    echo "$out"

    # SATA SSD: Wear_Leveling_Count "VALUE" counts DOWN from 100 (lower = more wear).
    wear_val=$(echo "$out" | awk '/Wear_Leveling_Count/ {print $4; exit}')
    # NVMe: "Percentage Used" counts UP from 0.
    pct_used=$(echo "$out" | awk -F: '/Percentage Used/ {gsub(/[ %]/,"",$2); print $2; exit}')

    # Force base-10: leading zeros (e.g. "099") would otherwise be parsed as octal.
    used=""
    if [[ "$pct_used" =~ ^[0-9]+$ ]]; then
        used=$(( 10#$pct_used ))
    elif [[ "$wear_val" =~ ^[0-9]+$ ]]; then
        used=$(( 100 - 10#$wear_val ))
    fi

    if [[ -n "$used" ]]; then
        if (( used >= CRIT_USED )); then
            logger -t tappaas-ssd-health -p daemon.err \
                "$(hostname): $dev wear at ${used}% (critical, >=${CRIT_USED}%) - plan replacement"
        elif (( used >= WARN_USED )); then
            logger -t tappaas-ssd-health -p daemon.warning \
                "$(hostname): $dev wear at ${used}% (warn, >=${WARN_USED}%)"
        fi
    fi

    if echo "$out" | grep -q "overall-health self-assessment test result: FAILED"; then
        logger -t tappaas-ssd-health -p daemon.err \
            "$(hostname): $dev SMART overall health FAILED"
    fi
done
echo "=== $(date -Is) tappaas-ssd-health end ==="
CRON
chmod 755 /etc/cron.monthly/tappaas-ssd-health

echo "SSD lifecycle setup complete."
