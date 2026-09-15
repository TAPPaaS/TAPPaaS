# shellcheck shell=bash
# repo-hold.sh — read a repository's pull hold (#653).
#
# `site-manager repository hold <repo>` writes config/.repo-hold/<repo>.json
# (reason, by, since, until, untilEpoch); refresh-control-plane.sh asks here
# before it pulls. The writer is site-manager/src/hold.ts.
#
# repo_hold_state <repo> [config-dir] [now-epoch]
#   prints "active <until> <by>: <reason>", "expired <until>", or "none"
repo_hold_state() {
    local repo="$1" dir="${2:-/home/tappaas/config}" now="${3:-$(date +%s)}"
    local f="${dir}/.repo-hold/${repo}.json" until_epoch
    [[ -f "${f}" ]] || { echo none; return 0; }
    until_epoch="$(jq -r '.untilEpoch // empty' "${f}" 2>/dev/null)" || until_epoch=""
    [[ "${until_epoch}" =~ ^[0-9]+$ ]] || { echo none; return 0; }
    if (( until_epoch > now )); then
        jq -r '"active \(.until) \(.by): \(.reason)"' "${f}"
    else
        jq -r '"expired \(.until)"' "${f}"
    fi
}

# repo_hold_clear <repo> [config-dir] — remove an expired marker.
repo_hold_clear() {
    rm -f "${2:-/home/tappaas/config}/.repo-hold/${1}.json"
}
