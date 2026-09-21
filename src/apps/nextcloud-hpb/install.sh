#!/usr/bin/env bash
# TAPPaaS Module: nextcloud-hpb — Installation
#
# Nextcloud Talk High-Performance Backend (nextcloud-spreed-signaling + Janus SFU)
#
# What the ENGINE has already done when this runs (install-module.sh Step 5, in
# dependsOn order): created the VM (cluster:vm); stamped `turnHost` into this
# module's deployed config (coturn:turn) and `nextcloudPublicUrl` into it
# (nextcloud:fileservice); published the Caddy route (network:proxy) and the
# firewall rules (network:rules); shipped the .nix + companion JSON and rebuilt
# the VM against the platform's nixpkgs pin (templates:nixos → update-os.sh).
# So the signaling server already knows its backend URL and TURN host — the
# .nix reads them from the companion JSON. Nothing here edits a deployed .nix
# or runs nixos-rebuild by hand any more.
#
# What is LEFT for this script: the two secrets that only exist once the VM is
# up — publish HPB_SECRET to the management plane, sync COTURN_SECRET into the
# signaling server (update.sh) — and then let the Nextcloud provider wire the
# `hpb` connector (its fileservice converge, which ran too early for the secret
# at Step 5). Plus the one manual step: the public DNS record.
#
# Secret planes:
#   Runtime:    /var/lib/nextcloud-hpb/secrets/ on the HPB VM (NixOS hpb-init-secrets, first boot)
#   Management: /home/tappaas/secrets/nextcloud-hpb.env on tappaas-cicd (written here)
#   coturn dep: /home/tappaas/secrets/coturn.env on tappaas-cicd (written by coturn)
#
# Usage: ./install.sh <module-name>
# Example: ./install.sh nextcloud-hpb

# Source the shared routines (logging + get_config_value) — NOT the deprecated
# install-vm.sh, which re-runs VM creation and expects /root/tappaas/<vm>.json on the node.
. /home/tappaas/bin/common-install-routines.sh

# Effective (environment) module name passed by the engine as $1 — drives all host
# resolution. Read the EFFECTIVE config (e.g. nextcloud-hpb-test.json), never the
# base module json in pwd (which carries the base vmname/zone).
EFFECTIVE="${1:-nextcloud-hpb}"
EFFECTIVE_JSON="/home/tappaas/config/${EFFECTIVE}.json"
ENVIRONMENT="$(jq -r '.environment // empty' "${EFFECTIVE_JSON}" 2>/dev/null || true)"

HPB_VMNAME="$(jq -r '.vmname' "${EFFECTIVE_JSON}")"
HPB_ZONE="$(jq -r '.zone0 // empty' "${EFFECTIVE_JSON}")"
HPB_HOST="${HPB_VMNAME}.${HPB_ZONE}.internal"

# Nextcloud provider — pair with the SAME environment (nextcloud-test ↔
# nextcloud-hpb-test); fall back to the shared config otherwise.
NC_MODULE="$(resolve_provider_module nextcloud "${ENVIRONMENT}")"
NC_JSON="/home/tappaas/config/${NC_MODULE}.json"
NC_LOCATION="$(jq -r '.moduleSource // .location // empty' "${NC_JSON}" 2>/dev/null || true)"
# The HPB's public name, from the platform's one derivation (#715).
PROXY_DOMAIN="$(module_public_domain "$(jq -r '.vmname' "${EFFECTIVE_JSON}")" "${ENVIRONMENT:-}" "$(cat "${EFFECTIVE_JSON}")")"
[[ -n "${PROXY_DOMAIN}" ]] || die "nextcloud-hpb has no public name: its environment '${ENVIRONMENT:-default}' has no domain, so network:proxy does not publish it — Talk's signaling server must be reachable at one"
MGMT_SECRETS="/home/tappaas/secrets/${EFFECTIVE}.env"
# Runtime secrets directory — must match secretsDir in nextcloud-hpb.nix
HPB_SECRETS_DIR="/var/lib/nextcloud-hpb/secrets"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)

# ── Is the VM actually on the network? Say so in one legible line ────────────
# The first HPB deployment (2026-08) landed in the site's default zone, whose
# VLAN carried no DHCP to that node: the guest ran with no IPv4, every later step
# failed as an ssh error, and the real cause surfaced three weeks later. Name
# the zone and VLAN here, before anything else is attempted.
echo ""
info "${BOLD}Checking ${HPB_HOST} is reachable…${CL}"
if ! getent hosts "${HPB_HOST}" >/dev/null 2>&1; then
    _vlan="$(jq -r --arg z "${HPB_ZONE}" '.[$z].vlantag // "?"' /home/tappaas/config/zones.json 2>/dev/null || echo "?")"
    die "${HPB_HOST} does not resolve — the VM has no DHCP lease in zone '${HPB_ZONE}' (VLAN ${_vlan}). \
Check that the zone's VLAN reaches the node hosting VMID $(jq -r '.vmid' "${EFFECTIVE_JSON}") (switch trunk, firewall VM trunks=), \
or place the HPB in Nextcloud's zone ($(jq -r '.zone0 // "?"' "${NC_JSON}")) — see INSTALL.md."
fi
ssh-keygen -R "${HPB_HOST}" >/dev/null 2>&1 || true   # recreate-safe: a redeployed VM has a new host key
if ! ssh "${SSH_OPTS[@]}" "tappaas@${HPB_HOST}" true >/dev/null 2>&1; then
    die "${HPB_HOST} resolves but does not answer ssh — templates:nixos should have rebuilt it; check the engine log above"
fi

# ── Sync COTURN_SECRET → HPB (runtime) — the converge, shared with update.sh ──
. ./update.sh

# ── Read HPB_SECRET from the runtime plane → save to the management plane ────
echo ""
info "${BOLD}Publishing HPB_SECRET to the management plane…${CL}"

HPB_SECRET=$(ssh "${SSH_OPTS[@]}" "tappaas@${HPB_HOST}" \
    "sudo cat ${HPB_SECRETS_DIR}/hpb-secret 2>/dev/null" || true)

if [[ -n "${HPB_SECRET}" ]]; then
    mkdir -p "$(dirname "${MGMT_SECRETS}")"
    { grep -v '^HPB_SECRET=' "${MGMT_SECRETS}" 2>/dev/null || true; printf 'HPB_SECRET=%s\n' "${HPB_SECRET}"; } > "${MGMT_SECRETS}.tmp"
    mv "${MGMT_SECRETS}.tmp" "${MGMT_SECRETS}"
    chmod 600 "${MGMT_SECRETS}"
    info "  HPB_SECRET saved to ${MGMT_SECRETS}."
else
    die "Could not read HPB_SECRET from ${HPB_SECRETS_DIR}/hpb-secret — the NixOS config was not applied (hpb-init-secrets did not run)"
fi

# ── Nextcloud side: the provider wires the `hpb` connector (ADR-COM-0002) ─────
# nextcloud:fileservice's converge does the writing (hpb.env on the Nextcloud VM
# + nextcloud-configure-hpb.service). It ran at Step 5 before this VM had a
# secret; run it again now that the secret is published. Every later
# `update-module.sh nextcloud-hpb` re-converges it the same way.
echo ""
info "${BOLD}Registering the HPB as Talk's signaling backend (nextcloud:fileservice)…${CL}"
if [[ -n "${NC_LOCATION}" && -x "${NC_LOCATION}/services/fileservice/update-service.sh" ]]; then
    "${NC_LOCATION}/services/fileservice/update-service.sh" "${EFFECTIVE}" \
        || warn "  nextcloud:fileservice converge returned non-zero — run 'update-module.sh ${EFFECTIVE}' once both VMs are up"
else
    warn "  Cannot locate the Nextcloud module (${NC_JSON}: .moduleSource/.location) — run 'update-module.sh ${EFFECTIVE}' to wire Talk"
fi

# ── Sanity: the facts the .nix was built from ─────────────────────────────────
_turn_host="$(jq -r '.turnHost // empty' "${EFFECTIVE_JSON}")"
_nc_url="$(jq -r '.nextcloudPublicUrl // empty' "${EFFECTIVE_JSON}")"
[[ -n "${_turn_host}" ]] || warn "  turnHost is not stamped in ${EFFECTIVE_JSON} — coturn:turn did not run; the HPB advertises coturn's internal name"
[[ -n "${_nc_url}"    ]] || warn "  nextcloudPublicUrl is not stamped in ${EFFECTIVE_JSON} — Talk will reject the HPB (invalid_backend); run 'update-module.sh ${EFFECTIVE}'"

echo ""
info "${GN}✓${CL} nextcloud-hpb installation completed successfully."
echo ""
info "  Signaling URL : wss://${PROXY_DOMAIN:-<proxyDomain>}/spreed"
info "  Backend       : ${_nc_url:-<not stamped>}"
info "  TURN          : ${_turn_host:-<not stamped>}"
info ""
info "  ${BOLD}ACTION REQUIRED — public DNS record only:${CL}"
info "    ${PROXY_DOMAIN:-<proxyDomain>} → <WAN IP>  (external clients, e.g. 5G)"
info "    (The internal split-horizon record is registered by network:proxy.)"
