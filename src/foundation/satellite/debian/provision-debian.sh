#!/usr/bin/env bash
#
# provision-debian.sh — turn a stock Debian 12/13 host into a TAPPaaS satellite.
#
# ADR-010 Option 3: the satellite runs Debian (not NixOS). This is the on-host
# installer — the satellite module renders the config files from the instance's
# config/<instance>.json + the derived SAT_* defaults, ships this directory to
# root@<satellite>, and runs this script. It is IDEMPOTENT (safe to re-run) and
# ROLE-GATED (reads roles.env; only touches the packages/services a role needs).
#
# Why Debian for the satellite (esp. the backup/vault role):
#   * Bootstrap is trivial — Hetzner boots Debian directly (no nixos-anywhere kexec).
#   * OS diversity — a nixpkgs/nixos-anywhere supply-chain compromise hits the
#     CLUSTER but not the off-site vault (strengthens ADR-010 §7.3).
#   * Official, supported proxmox-backup-server (no unofficial Nix/OCI port).
#
# The HOME (OPNsense) side is UNCHANGED — this only re-expresses the satellite
# half that satellite.nix used to describe. Reads these siblings (present per role):
#   roles.env                       ROLES="reverse-proxy admin-vpn backup"
#                                   MANAGEMENT="managed|unmanaged" (ADR-010 §8.4)
#   wg-infra.conf                   WireGuard infra tunnel (always)
#   nftables.conf                   input firewall (+ admin-vpn NAT relay)  (always)
#   nginx-stream.conf               L4 :443/:80 passthrough        (reverse-proxy)
#   99-tappaas-ipforward.conf       net.ipv4.ip_forward=1               (admin-vpn)
#   20auto-upgrades,52tappaas-unattended-upgrades   self-patching   (unmanaged)
#   operator_authorized_keys        operator out-of-band key(s)         (optional)
#   cicd_key.pub                    the mothership's key: authorized while managed,
#                                   removed when unmanaged              (optional)
#
# Usage: ./provision-debian.sh            (run as root, from the deploy dir)
set -euo pipefail

# ── logging ──────────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
info()  { printf '[%s] [info]  %s\n'  "$(_ts)" "$*"; }
warn()  { printf '[%s] [warn]  %s\n'  "$(_ts)" "$*" >&2; }
error() { printf '[%s] [error] %s\n'  "$(_ts)" "$*" >&2; }
die()   { error "$*"; exit 1; }

# ── cleanup trap ─────────────────────────────────────────────────────────────
_tmp="$(mktemp -d)"
cleanup() { rm -rf "${_tmp}"; }
trap cleanup EXIT INT TERM

# ── preconditions ────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

[[ "$(id -u)" -eq 0 ]] || die "must run as root (Hetzner boots Debian with a root login)"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — this installer targets Debian 12/13"
[[ -f roles.env ]] || die "roles.env not found in ${HERE} — did the satellite module assemble the deploy dir?"

# shellcheck source=/dev/null
. ./roles.env
ROLES="${ROLES:-}"
MANAGEMENT="${MANAGEMENT:-managed}"
[[ "${MANAGEMENT}" == managed || "${MANAGEMENT}" == unmanaged ]] || die "MANAGEMENT must be managed or unmanaged, not '${MANAGEMENT}'"
has_role() { [[ " ${ROLES} " == *" $1 "* ]]; }
info "Provisioning TAPPaaS satellite — roles: [${ROLES:-<none>}], ${MANAGEMENT}"

export DEBIAN_FRONTEND=noninteractive

# ── 1. packages ──────────────────────────────────────────────────────────────
# Base (every satellite): the infra tunnel + host firewall + self-patching.
PKGS=(wireguard-tools nftables unattended-upgrades apt-listchanges ca-certificates)
has_role reverse-proxy && PKGS+=(nginx libnginx-mod-stream)
# backup role packages (proxmox-backup-server) are installed by a separate,
# role-specific step (P6) — its apt source + key are added there, not here.

info "apt-get update + install: ${PKGS[*]}"
apt-get update -qq
apt-get install -y -qq "${PKGS[@]}" >/dev/null

# ── 2. operator SSH keys (idempotent; Hetzner cloud-init usually did this) ────
if [[ -f operator_authorized_keys ]]; then
    install -d -m 0700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys
    while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        grep -qxF "${key}" /root/.ssh/authorized_keys || echo "${key}" >> /root/.ssh/authorized_keys
    done < operator_authorized_keys
    info "  operator SSH key(s) ensured in /root/.ssh/authorized_keys"
fi

# The mothership's key (ADR-010 §8.4.2/§8.4.4): a managed satellite is patched by
# the nightly sweep, which logs in with it; a locked-down one must not accept it,
# so a compromised home cannot reach the vault. Matched by the key itself (type
# and base64), not the comment.
if [[ -f cicd_key.pub ]]; then
    install -d -m 0700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys
    _ck="$(awk 'NF>=2 {print $1" "$2; exit}' cicd_key.pub)"
    [[ -n "${_ck}" ]] || die "cicd_key.pub holds no key"
    if [[ "${MANAGEMENT}" == managed ]]; then
        grep -qF "${_ck}" /root/.ssh/authorized_keys || cat cicd_key.pub >> /root/.ssh/authorized_keys
        info "  the mothership's key is authorized (managed: the sweep patches this machine)"
    else
        grep -vF "${_ck}" /root/.ssh/authorized_keys > "${_tmp}/ak" || true
        cat "${_tmp}/ak" > /root/.ssh/authorized_keys
        grep -qF "${_ck}" /root/.ssh/authorized_keys && die "could not remove the mothership's key"
        info "  the mothership's key is removed (unmanaged: nothing at home can log in here)"
    fi
fi

# ── 3. WireGuard infra tunnel (always) ───────────────────────────────────────
# Private key is generated ON-HOST and never leaves it (mirrors satellite.nix
# privateKeyFile + generatePrivateKeyFile). wg-infra.conf carries NO private key
# — it is injected via the interface's PostUp from the 0600 keyfile.
install -d -m 0700 /etc/wireguard
if [[ ! -s /etc/wireguard/wg-infra.key ]]; then
    ( umask 077; wg genkey > /etc/wireguard/wg-infra.key )
    info "  generated /etc/wireguard/wg-infra.key (on-host; never leaves this host)"
else
    info "  /etc/wireguard/wg-infra.key already present — keeping it"
fi
chmod 0600 /etc/wireguard/wg-infra.key
install -m 0600 wg-infra.conf /etc/wireguard/wg-infra.conf
systemctl enable --now wg-quick@wg-infra >/dev/null 2>&1 || true
systemctl restart wg-quick@wg-infra
info "  wg-infra up — public key: $(wg show wg-infra public-key 2>/dev/null || echo '<pending>')"

# ── 4. host firewall (+ admin-vpn NAT relay) via nftables (always) ───────────
if has_role admin-vpn; then
    install -m 0644 99-tappaas-ipforward.conf /etc/sysctl.d/99-tappaas-ipforward.conf
    sysctl -q --system >/dev/null 2>&1 || sysctl -q -p /etc/sysctl.d/99-tappaas-ipforward.conf || true
    info "  net.ipv4.ip_forward enabled (admin-vpn relay)"
fi
install -m 0644 nftables.conf /etc/nftables.conf
nft -c -f /etc/nftables.conf || die "nftables.conf failed syntax check — refusing to apply"
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables
info "  nftables applied (input firewall$(has_role admin-vpn && echo ' + admin-vpn NAT relay'))"

# ── 5. reverse-proxy — nginx stream L4 passthrough ───────────────────────────
if has_role reverse-proxy; then
    install -m 0644 nginx-stream.conf /etc/nginx/nginx.conf
    nginx -t || die "nginx config failed -t — refusing to reload"
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    info "  nginx stream passthrough active (:443/:80 -> Caddy over the tunnel)"
fi

# ── 6. self-patching — unattended-upgrades (unmanaged only) ──────────────────
# A managed satellite is patched by the sweep, whose reboots follow rebootOk; an
# unattended reboot of its own would bypass that. A locked-down one patches itself.
if [[ "${MANAGEMENT}" == unmanaged ]]; then
    install -m 0644 20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
    install -m 0644 52tappaas-unattended-upgrades /etc/apt/apt.conf.d/52tappaas-unattended-upgrades
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    # dry-run validates the config parses and the security origin resolves
    if unattended-upgrade --dry-run --debug >"${_tmp}/uu.log" 2>&1; then
        info "  unattended-upgrades enabled (security auto-patching; reboot window per config)"
    else
        warn "  unattended-upgrades dry-run reported issues (see below) — auto-patching may be degraded"
        tail -5 "${_tmp}/uu.log" >&2 || true
    fi
else
    rm -f /etc/apt/apt.conf.d/52tappaas-unattended-upgrades
    printf 'APT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
    systemctl disable --now unattended-upgrades >/dev/null 2>&1 || true
    info "  unattended-upgrades off (managed: the sweep patches this machine)"
fi

info "TAPPaaS satellite provisioning complete."
info "  Next (on tappaas-cicd): the satellite module reads back the wg-infra public key"
info "  and wires the OPNsense peer; then it validates the tunnel handshake."
