#!/usr/bin/env bash
#
# Unit tests for lib/prune-kernels.sh — the #592 kernel keep/remove computation.
#
# Pure logic: drives the REAL script with --dry-run --stdin and PRUNE_RUNNING,
# so there is no mirrored copy to drift. No Proxmox node, no apt, runs anywhere.
# Invoked by cluster/test.sh (Test 2c) and standalone.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNE="${DIR}/prune-kernels.sh"

PASS=0
FAIL=0
check() {  # $1 desc, $2 expected, $3 actual
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Run the script under test with a synthetic running-kernel and package list.
keep_of()   { printf '%s\n' "$1" | sed -n 's/^KEEP: //p'; }
remove_of() { printf '%s\n' "$1" | sed -n 's/^REMOVE: //p'; }

# A — node is BEHIND (running is an old kernel). Running must survive; latest and
#     latest-1 kept; the one middle version removed; metapkg/helper untouched.
outA="$(PRUNE_RUNNING="6.14.0-2-pve" bash "$PRUNE" --dry-run --stdin <<'PKGS'
proxmox-kernel-6.14.0-2-pve-signed
proxmox-kernel-6.14.5-1-pve-signed
proxmox-kernel-6.14.8-2-pve-signed
proxmox-kernel-6.14.11-4-pve-signed
proxmox-kernel-9.0
proxmox-kernel-helper
PKGS
)"
check "A keep = running,latest-1,latest" "6.14.0-2-pve 6.14.8-2-pve 6.14.11-4-pve" "$(keep_of "$outA")"
check "A remove = only the middle version" "proxmox-kernel-6.14.5-1-pve-signed" "$(remove_of "$outA")"

# B — metapackages + helper + two kernels only: nothing to prune.
outB="$(PRUNE_RUNNING="6.14.11-4-pve" bash "$PRUNE" --dry-run --stdin <<'PKGS'
proxmox-kernel-6.14.8-2-pve-signed
proxmox-kernel-6.14.11-4-pve-signed
proxmox-kernel-9.0
proxmox-headers-9.0
proxmox-kernel-helper
PKGS
)"
check "B remove none (metapkgs never counted)" "(none)" "$(remove_of "$outB")"

# C — only two kernels: nothing to prune.
outC="$(PRUNE_RUNNING="6.14.11-4-pve" bash "$PRUNE" --dry-run --stdin <<'PKGS'
proxmox-kernel-6.14.8-2-pve-signed
proxmox-kernel-6.14.11-4-pve-signed
PKGS
)"
check "C remove none" "(none)" "$(remove_of "$outC")"

# D — running == latest (post-reboot): keep latest+latest-1, purge oldest
#     including its headers.
outD="$(PRUNE_RUNNING="6.14.11-4-pve" bash "$PRUNE" --dry-run --stdin <<'PKGS'
proxmox-kernel-6.14.0-2-pve-signed
proxmox-headers-6.14.0-2-pve
proxmox-kernel-6.14.8-2-pve-signed
proxmox-headers-6.14.8-2-pve
proxmox-kernel-6.14.11-4-pve-signed
proxmox-headers-6.14.11-4-pve
PKGS
)"
check "D keep = latest-1,latest" "6.14.8-2-pve 6.14.11-4-pve" "$(keep_of "$outD")"
check "D remove oldest image + headers" \
      "proxmox-headers-6.14.0-2-pve proxmox-kernel-6.14.0-2-pve-signed" "$(remove_of "$outD")"

# E — the #592 trap: long tail of old kernels, running one in the MIDDLE.
#     Running must be kept and must NOT appear in REMOVE.
outE="$(PRUNE_RUNNING="7.0.14-12-pve" bash "$PRUNE" --dry-run --stdin <<'PKGS'
proxmox-kernel-7.0.14-8-pve-signed
proxmox-kernel-7.0.14-10-pve-signed
proxmox-kernel-7.0.14-12-pve-signed
proxmox-kernel-7.0.14-14-pve-signed
proxmox-kernel-7.0.14-15-pve-signed
PKGS
)"
check "E keep = running,latest-1,latest" "7.0.14-12-pve 7.0.14-14-pve 7.0.14-15-pve" "$(keep_of "$outE")"
case " $(remove_of "$outE") " in
    *" proxmox-kernel-7.0.14-12-pve-signed "*) check "E running NOT in remove" "in-remove" "NOT-in-remove" ;;
    *) check "E running NOT in remove" "safe" "safe" ;;
esac

echo "── kernel-prune: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
