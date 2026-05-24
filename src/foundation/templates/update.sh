#!/usr/bin/env bash
#
# TAPPaaS VM Template update (templates module)
#
# Keeps the prebuilt NixOS VM template (VM 8080) in sync with the latest
# published image release (GitHub Actions builds the image and publishes it as
# the `nixos-template-v*` Release — see
# .github/workflows/build-nixos-template-image.yml).
#
# It is VERSION-GATED so it is cheap to run regularly: it makes one small GitHub
# API call for the latest release tag and compares it to the tag recorded on the
# template's node (/root/tappaas/nixos-template.version). The ~700 MB image is
# downloaded and the template rebuilt ONLY when a newer release exists — an
# already-current template costs a single HTTPS request and nothing else.
#
# Updating the template affects only NEW clones; VMs already cloned from an older
# template are independent (full clones) and update via their own nixos-rebuild.
#
# Usage: ./update.sh [module-name]
#   module-name   (optional) passed by update-module.sh; not used here.
#
# Exit codes: 0 ok / up-to-date, 1 error.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly GH_REPO="TAPPaaS/TAPPaaS"
readonly RELEASE_API="https://api.github.com/repos/${GH_REPO}/releases/latest"
readonly NIX_JSON="${SCRIPT_DIR}/tappaas-nixos.json"
readonly CREATE_VM="${SCRIPT_DIR}/../cluster/Create-TAPPaaS-VM.sh"
readonly MARKER="/root/tappaas/nixos-template.version"   # lives on the template's node
readonly SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

[[ -f "$NIX_JSON" ]] || die "tappaas-nixos.json not found at ${NIX_JSON}"
VMID="$(jq -r '.vmid' "$NIX_JSON")"
VMNAME="$(jq -r '.vmname' "$NIX_JSON")"
IMAGE="$(jq -r '.image' "$NIX_JSON")"
IMAGELOCATION="$(jq -r '.imageLocation' "$NIX_JSON")"
[[ -n "$VMID" && "$VMID" != "null" ]] || die "vmid missing from ${NIX_JSON}"

NODE1_FQDN="$(get_primary_node_fqdn)"

# Run a command on the template's node as root.
node_run() { ssh "${SSH_OPTS[@]}" "root@${NODE}.mgmt.internal" "$@"; }

echo ""
info "${BOLD}TAPPaaS NixOS template update${CL} (${VMNAME}, VM ${VMID})"

# ── 1. Latest available release tag (cheap). Fail-soft on a network hiccup so a
#       transient GitHub outage does not fail the whole hourly update run. ──────
info "Checking latest published template release..."
latest_tag="$(curl -fsSL "$RELEASE_API" 2>/dev/null | jq -r '.tag_name // empty')"
if [[ -z "$latest_tag" ]]; then
  warn "Could not reach the GitHub releases API — skipping template update this run."
  exit 0
fi

# ── 2. Locate the template in the cluster (empty if it does not exist yet). ────
NODE="$(vm_exists_on_cluster "$VMID" "$NODE1_FQDN" || true)"

# ── 3. Decide whether an update is needed (no image download to find out). ─────
installed_tag=""
is_template=0
if [[ -n "$NODE" ]]; then
  if node_run "qm config ${VMID} 2>/dev/null | grep -qE '^template:[[:space:]]*1'"; then
    is_template=1
  fi
  installed_tag="$(node_run "cat ${MARKER} 2>/dev/null" || true)"
fi

if [[ "$is_template" == "1" && "$installed_tag" == "$latest_tag" ]]; then
  info "Template already at ${GN}${latest_tag}${CL} — nothing to do."
  exit 0
fi

info "Update available: ${YW}${installed_tag:-<none>}${CL} -> ${GN}${latest_tag}${CL}"

# Fall back to the primary node if the template does not exist yet.
[[ -n "$NODE" ]] || NODE="$(get_node_hostname 0)"
[[ -n "$NODE" ]] || die "Could not determine a target node for the template."

# ── 4. Pre-flight: confirm the release asset is fetchable BEFORE we destroy the
#       existing template, so a bad/missing release leaves us untouched. ────────
asset_url="${IMAGELOCATION%/}/${IMAGE#/}"
info "Verifying release asset is reachable: ${asset_url}"
http_code="$(curl -fsIL -o /dev/null -w '%{http_code}' "$asset_url" 2>/dev/null || echo 000)"
[[ "$http_code" == "200" ]] || die "Release asset not reachable (HTTP ${http_code}): ${asset_url}"

# ── 5. Stage the current provisioner + module JSON on the node. ────────────────
info "Staging provisioner files to ${NODE}..."
node_run "mkdir -p /root/tappaas"
scp -q "${SSH_OPTS[@]}" "$NIX_JSON"   "root@${NODE}.mgmt.internal:/root/tappaas/"
scp -q "${SSH_OPTS[@]}" "$CREATE_VM"  "root@${NODE}.mgmt.internal:/root/tappaas/Create-TAPPaaS-VM.sh"
node_run "chmod +x /root/tappaas/Create-TAPPaaS-VM.sh"
# zones.json is normally already distributed by the cluster update; push if absent.
if ! node_run "test -f /root/tappaas/zones.json"; then
  scp -q "${SSH_OPTS[@]}" "${CONFIG_DIR}/zones.json" "root@${NODE}.mgmt.internal:/root/tappaas/"
fi

# ── 6. Rebuild the template on the node: drop the old one, recreate from the new
#       image (this is the only step that downloads the ~700 MB image), convert
#       to a template, and record the new version. ──────────────────────────────
info "Rebuilding template on ${NODE} (downloading the new image)..."
node_run bash -s <<REMOTE
set -euo pipefail
cd /root/tappaas
if qm status ${VMID} >/dev/null 2>&1; then
  qm stop ${VMID} >/dev/null 2>&1 || true
  qm destroy ${VMID} --purge >/dev/null
fi
./Create-TAPPaaS-VM.sh ${VMNAME}
qm stop ${VMID} >/dev/null 2>&1 || true
for _ in \$(seq 1 30); do qm status ${VMID} 2>/dev/null | grep -q stopped && break; sleep 1; done
qm template ${VMID} >/dev/null
printf '%s\n' "${latest_tag}" > ${MARKER}
REMOTE

echo ""
info "${GN}✓${CL} NixOS template ${VMNAME} (VM ${VMID}) updated to ${BOLD}${latest_tag}${CL} on ${NODE}."
info "New clones use the updated template; existing VMs update via their own nixos-rebuild."
