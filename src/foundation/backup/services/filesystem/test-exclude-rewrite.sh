#!/usr/bin/env bash
#
# The exclude-pattern rewrite in tappaas-fs-backup.sh (#662).
#
# proxmox-backup-client matches --exclude against each archive's OWN root, not
# against the filesystem. An operator writes what they see — /root/*.iso — and
# without the rewrite that anchors to /root/root/*.iso and matches nothing: the
# first live run still uploaded 1.589 GiB of netboot images and reported
# success. This pins the translation, offline.
#
set -uo pipefail
pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass+1)); }
bad() { echo "  ✗ $*"; fail=$((fail+1)); }

# The loop under test, lifted verbatim from the runner.
rewrite() {
    local -a PATHS=("$1") EXCLUDE=("$2") effective=()
    local x pat p base
    for x in "${EXCLUDE[@]}"; do
        [[ -n "${x}" ]] || continue
        pat="${x}"
        if [[ "${pat}" == /* ]]; then
            for p in "${PATHS[@]}"; do
                base="${p%/}"
                if [[ "${pat}" == "${base}/"* ]]; then
                    pat="/${pat#"${base}/"}"
                    break
                fi
            done
        fi
        effective+=("${pat}")
    done
    printf '%s' "${effective[0]:-}"
}

is() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (expected '$3', got '$2')"; }

is "an absolute pattern under a declared path is anchored to that archive" \
   "$(rewrite /root '/root/*.iso')" "/*.iso"
is "…at depth too" \
   "$(rewrite /root '/root/build/out/*.img')" "/build/out/*.img"
is "a pattern under a DIFFERENT path is left alone" \
   "$(rewrite /etc '/root/*.iso')" "/root/*.iso"
is "a relative pattern is the operator's own and passes through" \
   "$(rewrite /root '*.iso')" "*.iso"
is "a glob-anywhere pattern passes through" \
   "$(rewrite /root '**/*.iso')" "**/*.iso"
is "the declared path itself is not mistaken for a child" \
   "$(rewrite /root '/rootfs/*.iso')" "/rootfs/*.iso"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
