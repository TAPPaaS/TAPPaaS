#!/usr/bin/env bash
# shellcheck shell=bash
#
# remove-node-lib.sh — the decisions behind removing a node from the cluster
# (#417). Pure: every function reads JSON it is handed (from pvesh, ha-manager,
# config/) and prints what it finds, so remove-node.sh's plan can be tested
# without a cluster. Sourced after common-install-routines.sh.

# Guests the cluster places on <node>: "<vmid> <name> <type>", one per line.
# Args: <node> <pvesh /cluster/resources --type vm JSON>
rmn_guests_on() {
    jq -r --arg n "$1" '.[] | select(.node == $n) | "\(.vmid) \(.name // "-") \(.type)"' <<<"$2" 2>/dev/null | sort -n
}

# Replication jobs with <node> at either end: "<id> <source>-><target>".
# A job FROM it moves with its guest; a job TO it would replicate into a node
# that is gone — both have to be dealt with before the node goes.
# Args: <node> <pvesh /cluster/replication JSON>
rmn_replication_touching() {
    jq -r --arg n "$1" '.[] | select(.source == $n or .target == $n) | "\(.id) \(.source // "?")->\(.target)"' \
        <<<"$2" 2>/dev/null | sort
}

# HA rules that name <node>: "<rule> <nodes>". A rule pinning a service to a node
# that no longer exists is a module's placement declaration still pointing there.
# Args: <node> <pvesh /cluster/ha/rules JSON>
rmn_ha_rules_naming() {
    jq -r --arg n "$1" '.[] | select((.nodes // "") | split(",") | map(sub(":.*$"; "")) | index($n))
                        | "\(.rule) \(.nodes)"' <<<"$2" 2>/dev/null | sort
}

# What happens to each storage entry that lists <node>: "set <storage> <nodes>"
# with the node taken out, or "remove <storage>" when it was the only one (the
# entry is configuration; the data on the node's disks is not touched by this).
# Args: <node> <pvesh /storage JSON>
rmn_storage_changes() {
    jq -r --arg n "$1" '.[] | select((.nodes // "") | split(",") | index($n))
        | ((.nodes | split(",")) - [$n]) as $rest
        | if ($rest | length) == 0 then "remove \(.storage)" else "set \(.storage) \($rest | join(","))" end' \
        <<<"$2" 2>/dev/null | sort
}

# The module whose guest is <vmid>, from config/*.json; empty when none claims it.
# Args: <vmid> [config-dir]
rmn_module_of_vmid() {
    local dir="${2:-${TAPPAAS_CONFIG:-/home/tappaas/config}}" f
    for f in "${dir}"/*.json; do
        [[ -f "$f" ]] || continue
        if jq -e --arg v "$1" '(.vmid // empty | tostring) == $v' "$f" >/dev/null 2>&1; then
            basename "$f" .json
            return 0
        fi
    done
}

# 0 when the site's PBS runs on <node> — the backup datastore would go with it.
# Args: <node> <config/backup.json content>
rmn_pbs_on() {
    local node
    node="$(jq -r 'if .placementState == "node" then (.node // "")
                   elif ((.placementState // "") | startswith("node:")) then (.placementState | ltrimstr("node:"))
                   else (.node // "") end' <<<"$2" 2>/dev/null)"
    [[ -n "$node" && "$node" == "$1" ]]
}

# The script run ON the node by --erase, after the workload check has passed and
# the operator typed ERASE. Destroys every ZFS pool and wipes its disks, then
# wipes every partition and the partition table of the disk(s) behind / and
# /boot/efi, deletes the boot entry it started from, and powers off at once.
# Nothing reads the disks after that: the running system is in memory, and the
# immediate power-off (sysrq) keeps a shutdown from writing to them.
rmn_erase_script() {
    cat <<'ERASE'
set -u
disks=""
add_disk() { local d; d="$(lsblk -no PKNAME "$1" 2>/dev/null | head -1)"; [ -n "$d" ] || d="$(basename "$1")"
             case " $disks " in *" $d "*) ;; *) disks="$disks $d" ;; esac; }
for p in $(zpool list -H -o name 2>/dev/null); do
    devs="$(zpool status -P -L "$p" 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}')"
    zpool destroy -f "$p" && echo "destroyed pool $p"
    for d in $devs; do wipefs -af "$d" >/dev/null 2>&1; add_disk "$d"; done
done
for m in / /boot/efi; do
    src="$(findmnt -no SOURCE "$m" 2>/dev/null)" || continue
    for d in $(lsblk -snlo NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" {print $1}'); do add_disk "/dev/$d"; done
done
for d in $disks; do
    for part in $(lsblk -lnpo NAME,TYPE "/dev/$d" 2>/dev/null | awk '$2 == "part" {print $1}'); do wipefs -af "$part" >/dev/null 2>&1; done
    sgdisk --zap-all "/dev/$d" >/dev/null 2>&1 || wipefs -af "/dev/$d" >/dev/null 2>&1
    echo "wiped /dev/$d"
done
cur="$(efibootmgr 2>/dev/null | sed -n 's/^BootCurrent: //p')"
[ -n "$cur" ] && efibootmgr -q -b "$cur" -B && echo "removed boot entry $cur"
sync
echo ERASED
( sleep 2; echo 1 > /proc/sys/kernel/sysrq; echo o > /proc/sysrq-trigger ) >/dev/null 2>&1 &
ERASE
}
