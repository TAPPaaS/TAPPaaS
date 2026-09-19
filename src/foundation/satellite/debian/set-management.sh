#!/usr/bin/env bash
#
# set-management.sh — who patches this satellite, and whether home may log in
# (ADR-010 §8.4.2, §8.4.4). Runs on the satellite, LAST, after provision-debian.sh
# (and provision-backup.sh for a vault), from the same deploy dir:
#
#   MANAGEMENT=managed    the nightly sweep patches it: the mothership's key
#                         (cicd_key.pub) is authorized, unattended-upgrades is off
#                         — an unattended reboot would bypass rebootOk.
#   MANAGEMENT=unmanaged  locked down: it patches itself (security-only
#                         unattended-upgrades, reboot window), and the mothership's
#                         key is removed, so nothing at home can log in to the
#                         vault. The operator's own key must be there first.
#
# Reads roles.env (MANAGEMENT), cicd_key.pub, and for unmanaged 20auto-upgrades +
# 52tappaas-unattended-upgrades. Idempotent.
#
# Usage: ./set-management.sh            (run as root, from the deploy dir)
set -euo pipefail

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
info() { printf '[%s] [info]  %s\n' "$(_ts)" "$*"; }
warn() { printf '[%s] [warn]  %s\n' "$(_ts)" "$*" >&2; }
die()  { printf '[%s] [error] %s\n' "$(_ts)" "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"
# SAT_SM_TEST=1 (the module's offline suite only): act on the files below in a
# scratch tree and touch no service.
if [[ "${SAT_SM_TEST:-0}" == 1 ]]; then
    systemctl() { :; }; unattended-upgrade() { :; }
else
    [[ "$(id -u)" -eq 0 ]] || die "must run as root"
fi
AK="${SAT_SM_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"
APT="${SAT_SM_APT_DIR:-/etc/apt/apt.conf.d}"
[[ -f roles.env ]] || die "roles.env not found in ${HERE}"
# shellcheck source=/dev/null
. ./roles.env
MANAGEMENT="${MANAGEMENT:-managed}"
install -d -m 0700 "$(dirname "${AK}")"
touch "${AK}" && chmod 0600 "${AK}"

# The mothership's key, matched by type + base64 (not the comment).
ck=""
if [[ -f cicd_key.pub ]]; then
    ck="$(awk 'NF>=2 {print $1" "$2; exit}' cicd_key.pub)"
    [[ -n "${ck}" ]] || die "cicd_key.pub holds no key"
fi

case "${MANAGEMENT}" in
    managed)
        [[ -n "${ck}" ]] || die "a managed satellite needs the mothership's key (cicd_key.pub) — the sweep logs in with it"
        grep -qF "${ck}" "${AK}" || cat cicd_key.pub >> "${AK}"
        rm -f "${APT}/52tappaas-unattended-upgrades"
        printf 'APT::Periodic::Unattended-Upgrade "0";\n' > "${APT}/20auto-upgrades"
        systemctl disable --now unattended-upgrades >/dev/null 2>&1 || true
        info "managed: the mothership's key is authorized; unattended-upgrades is off (the sweep patches this machine)"
        ;;
    unmanaged)
        # Self-patching first, so the machine is never left patched by nobody.
        install -m 0644 20auto-upgrades "${APT}/20auto-upgrades"
        install -m 0644 52tappaas-unattended-upgrades "${APT}/52tappaas-unattended-upgrades"
        systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
        if unattended-upgrade --dry-run >/dev/null 2>&1; then
            info "unattended-upgrades on (security-only; reboot window per config)"
        else
            warn "unattended-upgrades dry-run reported issues — self-patching may be degraded"
        fi
        # Never lock everyone out: an operator key other than the mothership's must remain.
        others="$(awk -v c="${ck}" '/^(ssh-|ecdsa-|sk-)/ && (c == "" || index($0, c) == 0)' "${AK}" | wc -l | tr -d ' ')"
        [[ "${others}" -ge 1 ]] || die "no operator key besides the mothership's in ${AK} — refusing to remove it and lock everyone out"
        if [[ -n "${ck}" ]]; then
            grep -vF "${ck}" "${AK}" > "${AK}.new" || true
            cat "${AK}.new" > "${AK}"; rm -f "${AK}.new"
            grep -qF "${ck}" "${AK}" && die "could not remove the mothership's key"
        fi
        info "unmanaged: the mothership's key is removed — nothing at home can log in here (${others} operator key(s) remain)"
        ;;
    *) die "MANAGEMENT must be managed or unmanaged, not '${MANAGEMENT}'" ;;
esac
