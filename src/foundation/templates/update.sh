#!/usr/bin/env bash
#
# TAPPaaS VM Template update (templates module)
#
# Keeps the prebuilt NixOS VM template (VM 8080) in sync with the version
# specified in tappaas-nixos.json. The target version is controlled by the
# branch — update the JSON's "version" and "imageLocation" fields to roll out
# a new template image. This ensures stable branches stay on tested versions
# while main can point to newer builds.
#
# GitHub Actions builds the image and publishes it as a `nixos-template-v*`
# Release — see .github/workflows/build-nixos-template-image.yml.
#
# It is VERSION-GATED so it is cheap to run regularly: it compares the version
# from tappaas-nixos.json to the tag recorded on the template's node
# (/root/tappaas/nixos-template.version). The ~700 MB image is downloaded and
# the template rebuilt ONLY when the JSON specifies a different version — an
# already-current template costs nothing.
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

readonly TAG_PREFIX="nixos-template-v"
readonly NIX_JSON="${SCRIPT_DIR}/tappaas-nixos.json"
readonly CREATE_VM="${SCRIPT_DIR}/../cluster/Create-TAPPaaS-VM.sh"
readonly MARKER="/root/tappaas/nixos-template.version"   # lives on the template's node
readonly SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

[[ -f "$NIX_JSON" ]] || die "tappaas-nixos.json not found at ${NIX_JSON}"
# tappaas-nixos.json is stored in Pattern-A form (image/vmid/... nested under
# .config."cluster:vm"); flatten it before reading so the asset pre-flight below
# resolves a real filename instead of "null" (Pattern-A migration fix).
NIX_JSON_FLAT="$(normalize_module_config < "$NIX_JSON")"
VMID="$(jq -r '.vmid' <<< "$NIX_JSON_FLAT")"
VMNAME="$(jq -r '.vmname' <<< "$NIX_JSON_FLAT")"
IMAGE="$(jq -r '.image' <<< "$NIX_JSON_FLAT")"
IMAGE_LOCATION="$(jq -r '.imageLocation' <<< "$NIX_JSON_FLAT")"
JSON_VERSION="$(jq -r '.version' "$NIX_JSON")"
[[ -n "$VMID" && "$VMID" != "null" ]] || die "vmid missing from ${NIX_JSON}"
[[ -n "$IMAGE" && "$IMAGE" != "null" ]] || die "image missing from ${NIX_JSON}"
[[ -n "$JSON_VERSION" && "$JSON_VERSION" != "null" ]] || die "version missing from ${NIX_JSON}"
[[ -n "$IMAGE_LOCATION" && "$IMAGE_LOCATION" != "null" ]] || die "imageLocation missing from ${NIX_JSON}"

# The target tag is derived from the version in the JSON (branch-controlled).
readonly TARGET_TAG="${TAG_PREFIX}${JSON_VERSION}"
readonly TAG_URL="${IMAGE_LOCATION%/}"

NODE1_FQDN="$(get_primary_node_fqdn)"

# Run a command on the template's node as root.
node_run() { ssh "${SSH_OPTS[@]}" "root@${NODE}.mgmt.internal" "$@"; }

echo ""
info "${BOLD}TAPPaaS NixOS template update${CL} (${VMNAME}, VM ${VMID})"

# ── 1. Target version from tappaas-nixos.json (branch-controlled). ─────────────
info "Target template version: ${GN}${TARGET_TAG}${CL} (from tappaas-nixos.json)"

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

if [[ "$is_template" == "1" && "$installed_tag" == "$TARGET_TAG" ]]; then
  info "Template already at ${GN}${TARGET_TAG}${CL} — nothing to do."
  exit 0
fi

info "Update available: ${YW}${installed_tag:-<none>}${CL} -> ${GN}${TARGET_TAG}${CL}"

# Fall back to the primary node if the template does not exist yet.
[[ -n "$NODE" ]] || NODE="$(get_node_hostname 0)"
[[ -n "$NODE" ]] || die "Could not determine a target node for the template."

# ── 4. Pre-flight: confirm the release asset is fetchable BEFORE we destroy the
#       existing template, so a bad/missing release leaves us untouched. ────────
asset_url="${TAG_URL}/${IMAGE#/}"
info "Verifying release asset is reachable: ${asset_url}"
http_code="$(curl -fsIL -o /dev/null -w '%{http_code}' "$asset_url" 2>/dev/null || echo 000)"
[[ "$http_code" == "200" ]] || die "Release asset not reachable (HTTP ${http_code}): ${asset_url}"

# ── 5. Stage the current provisioner + module JSON on the node. ────────────────
info "Staging provisioner files to ${NODE}..."
node_run "mkdir -p /root/tappaas"
# Stage the module JSON with imageLocation pinned to the resolved release tag, so
# Create-TAPPaaS-VM.sh downloads THIS stream's asset (not the repo-wide latest).
staged_json="$(mktemp)"
jq --arg loc "${TAG_URL}/" '.imageLocation = $loc' "$NIX_JSON" > "$staged_json"
scp -q "${SSH_OPTS[@]}" "$staged_json"  "root@${NODE}.mgmt.internal:/root/tappaas/tappaas-nixos.json"
rm -f "$staged_json"
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
printf '%s\n' "${TARGET_TAG}" > ${MARKER}
REMOTE

echo ""
info "${GN}✓${CL} NixOS template ${VMNAME} (VM ${VMID}) updated to ${BOLD}${TARGET_TAG}${CL} on ${NODE}."
info "New clones use the updated template; existing VMs update via their own nixos-rebuild."
