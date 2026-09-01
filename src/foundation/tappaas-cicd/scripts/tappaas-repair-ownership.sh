#!/usr/bin/env bash
#
# tappaas-repair-ownership.sh — keep the config dir and git checkouts
#                               owned by the tappaas operator (#533).
#
# The TAPPaaS managers must run as the 'tappaas' operator, never root. The only
# reason anyone reaches for sudo is that a config or git-repo file became
# root-owned — a self-reinforcing trap: root write -> tappaas can't read ->
# operator adds sudo -> more root writes -> sudo -n breaks SSH identity (the
# getpwuid-based resolution documented in ADR-018).
#
# This script makes that state self-healing. It finds any file under the config
# dir or the TAPPaaS git checkout(s) not owned by 'tappaas', warns, and chowns
# it back. It is idempotent and safe to run on every update cycle.
#
# Bounded by design: it only ever chowns a path that resolves *inside*
# /home/tappaas, so a hostile site.json repository path cannot redirect it at
# some path outside the operator's home.
#
# Runs either as root (systemd ExecStartPre=+, chowns directly) or as the
# operator (interactive, elevating each chown through passwordless `sudo -n`).
#
# Usage: tappaas-repair-ownership.sh [--check]
#   (none)     Warn about and repair any non-tappaas-owned files.
#   --check    Report drift only; exit 1 if any found, 0 if clean. No repair.
#   -h|--help  Show this help.
#
set -euo pipefail

# ── Shared library ────────────────────────────────────────────────────
# shellcheck source=../lib/common-install-routines.sh disable=SC1091
if [[ -r /home/tappaas/bin/common-install-routines.sh ]]; then
    . /home/tappaas/bin/common-install-routines.sh
else
    _SELF="$(readlink -f "${BASH_SOURCE[0]}")"
    # shellcheck source=../lib/common-install-routines.sh disable=SC1091
    . "$(dirname "${_SELF}")/../lib/common-install-routines.sh"
fi

# ── Configuration (overridable for tests) ────────────────────────────
readonly OWNER="${TAPPAAS_OPERATOR:-tappaas}"
readonly OWNER_GROUP="${TAPPAAS_OPERATOR_GROUP:-users}"
readonly HOME_ROOT="${TAPPAAS_HOME_ROOT:-/home/tappaas}"

usage() {
    cat << 'EOF'
Usage: tappaas-repair-ownership.sh [--check]
    (none)     Warn about and repair any non-tappaas-owned files under the
               config dir and TAPPaaS git checkout(s).
    --check    Report drift only; exit 1 if any found, 0 if clean. No repair.
    -h|--help  Show this help message.
EOF
}

# List the directories whose contents must be tappaas-owned: the config dir,
# the primary checkout, and every repository declared in site.json.
target_paths() {
    printf '%s\n' "${CONFIG_DIR}"
    printf '%s\n' "${HOME_ROOT}/TAPPaaS"
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done < <(get_repositories | jq -r '.[]?.path // empty' 2>/dev/null)
}

# within_home <path> — true (0) if <path> resolves inside HOME_ROOT. Both sides
# are canonicalised so a symlinked prefix (e.g. macOS /var -> /private/var, or a
# symlinked home) compares equal. Callers guarantee <path> exists (the main loop
# skips non-existent targets first), so plain realpath — portable to BSD/macOS —
# suffices; no GNU-only `-m` needed.
within_home() {
    local rp root
    rp="$(realpath -- "$1" 2>/dev/null)"   || return 1
    root="$(realpath -- "$HOME_ROOT" 2>/dev/null)" || return 1
    [[ "$rp" == "$root" || "$rp" == "$root"/* ]]
}

# do_chown <path> — restore ownership of a tree, elevating only if not root.
# -h so an in-tree symlink is retargeted rather than followed out of the tree.
do_chown() {
    local path="$1"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        chown -Rh "${OWNER}:${OWNER_GROUP}" -- "$path"
    else
        sudo -n chown -Rh "${OWNER}:${OWNER_GROUP}" -- "$path"
    fi
}

# has_drift <path> — true (0) if <path> contains a file not owned by OWNER.
# Stops at the first offender (-quit), so the common clean case is cheap-ish.
has_drift() {
    [[ -n "$(find "$1" ! -user "$OWNER" -print -quit 2>/dev/null)" ]]
}

main() {
    local mode="repair"
    case "${1:-}" in
        --check)    mode="check" ;;
        -h|--help)  usage; exit 0 ;;
        "")         ;;
        *)          error "unknown argument: $1"; usage; exit 2 ;;
    esac

    local drift=0 path
    local -a seen=()
    while IFS= read -r path; do
        [[ -e "$path" ]] || continue
        # de-dupe (a repositories[] entry may repeat the config dir/checkout)
        local dup=0 s
        if [[ ${#seen[@]} -gt 0 ]]; then
            for s in "${seen[@]}"; do [[ "$s" == "$path" ]] && { dup=1; break; }; done
        fi
        [[ "$dup" -eq 1 ]] && continue
        seen+=("$path")

        if ! within_home "$path"; then
            warn "skipping '${path}' — outside ${HOME_ROOT}, refusing to chown"
            continue
        fi
        has_drift "$path" || continue
        drift=1
        if [[ "$mode" == "check" ]]; then
            warn "ownership drift: '${path}' contains files not owned by '${OWNER}'"
        else
            warn "ownership drift in '${path}' — repairing to ${OWNER}:${OWNER_GROUP}"
            if do_chown "$path"; then
                info "repaired ownership: ${path}"
            else
                error "could not repair '${path}' — run: sudo chown -R ${OWNER}:${OWNER_GROUP} ${path}"
            fi
        fi
    done < <(target_paths)

    if [[ "$mode" == "check" && "$drift" -ne 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
