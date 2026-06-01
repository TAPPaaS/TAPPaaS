#!/usr/bin/env bash
#
# Copyright (c) 2025 TAPPaaS org
# MPL-2.0. Incorporates work from community-scripts (MIT) and the original
# vllm-amd Create-TAPPaaS-LXC.sh by Erik Daniel007.
#
# Create-TAPPaaS-LXC.sh — shared TAPPaaS LXC container provisioner.
#
# Runs ON a Proxmox node (synced to /root/tappaas/ by cluster/update.sh) and is
# invoked by the cluster:lxc install-service, mirroring Create-TAPPaaS-VM.sh.
# Generic and meta-driven: GPU passthrough and bind-mounts are OPTIONAL blocks
# in /root/tappaas/<name>.meta.json, so non-GPU containers work too. Resolves
# zone0 → VLAN tag from /root/tappaas/zones.json exactly like the VM creator.
#
# Usage: Create-TAPPaaS-LXC.sh <module-name>
#   Reads  /root/tappaas/<module>.json        (required)
#          /root/tappaas/<module>.meta.json   (optional: gpu, bindMounts, lxcOptions)
#          /root/tappaas/zones.json           (zone → VLAN tag)
#

set -euo pipefail

YW=$'\033[33m'; BL=$'\033[36m'; RD=$'\033[01;31m'
BGN=$'\033[4;92m'; GN=$'\033[1;92m'; DGN=$'\033[32m'; CL=$'\033[m'; BOLD=$'\033[1m'

info()  { echo -e "${DGN}[Info]${CL} $*"; }
warn()  { echo -e "${YW}[Warning]${CL} $*"; }
errln() { echo -e "${RD}[ERROR]${CL} $*" >&2; }

# On any error, tear down a partially-created container (but never an existing one).
CREATED=0
VMID=""
error_handler() {
  local code="$?" line="$1" cmd="$2"
  errln "in line ${line}: exit ${code}: while executing: ${cmd}"
  if [[ "${CREATED}" -eq 1 && -n "${VMID}" ]] && pct status "${VMID}" &>/dev/null; then
    warn "Rolling back partially-created container ${VMID}"
    pct stop "${VMID}" &>/dev/null || true
    pct destroy "${VMID}" &>/dev/null || true
  fi
}
trap 'error_handler "${LINENO}" "${BASH_COMMAND}"' ERR

# ── Args + config ────────────────────────────────────────────────────

if [[ -z "${1:-}" ]]; then
  errln "Missing required argument <module-name>"
  echo  "Usage: $0 <module-name>  (expects /root/tappaas/<module-name>.json)" >&2
  exit 1
fi

JSON_CONFIG="/root/tappaas/$1.json"
META_CONFIG="/root/tappaas/$1.meta.json"
[[ -f "${JSON_CONFIG}" ]] || { errln "Config not found: ${JSON_CONFIG}"; exit 1; }

JSON=$(cat "${JSON_CONFIG}")
META="{}"
[[ -f "${META_CONFIG}" ]] && META=$(cat "${META_CONFIG}")
ZONES=$(cat /root/tappaas/zones.json)

# get_config_value <key> [default]  — mirrors Create-TAPPaaS-VM.sh.
# Supports both flat (top-level) and Pattern-A (nested under .config."<module>:<service>") layouts.
get_config_value() {
  local key="$1"
  local value=""
  if echo "${JSON}" | jq -e --arg K "${key}" 'has($K)' >/dev/null; then
    # Found at top level
    value=$(echo "${JSON}" | jq -r --arg KEY "${key}" '.[$KEY]')
  elif echo "${JSON}" | jq -e --arg K "${key}" '.config // {} | to_entries[] | select(.value | has($K))' >/dev/null 2>&1; then
    # Found in a nested config block (Pattern-A)
    value=$(echo "${JSON}" | jq -r --arg K "${key}" '[.config // {} | to_entries[] | select(.value | has($K)) | .value[$K]][0]')
  else
    # Key not found anywhere
    if [[ $# -lt 2 ]]; then
      errln "Missing required key '${key}' in ${JSON_CONFIG}"
      exit 1
    fi
    value="$2"
  fi
  info "     - ${key} has value: ${BGN}${value}${CL}" >&2
  echo -n "${value}"
}

# get_meta <jq-filter> [default] — read from the optional meta.json.
get_meta() {
  local out
  out=$(echo "${META}" | jq -r "$1 // empty" 2>/dev/null || true)
  if [[ -z "${out}" || "${out}" == "null" ]]; then echo -n "${2:-}"; else echo -n "${out}"; fi
}

# get_vlan_value <zone> — resolve an active zone to its VLAN tag.
get_vlan_value() {
  local key="$1" state tag
  if ! echo "${ZONES}" | jq -e --arg K "${key}" 'has($K)' >/dev/null; then
    errln "Missing required zone '${key}' in zones.json"
    exit 1
  fi
  state=$(echo "${ZONES}" | jq -r --arg K "${key}" '.[$K].state')
  if [[ "${state}" == "Inactive" ]]; then
    errln "Zone '${key}' in zones.json is not active (state: ${state})"
    exit 1
  fi
  tag=$(echo "${ZONES}" | jq -r --arg K "${key}" '.[$K].vlantag')
  info "     - ${key} has vlan value: ${BGN}${tag}${CL}" >&2
  echo -n "${tag}"
}

# resolve_trunks <zone;zone;...> — semicolon list of zone names → tag list.
resolve_trunks() {
  local list="$1" result="" state tag
  local -a names
  IFS=';' read -ra names <<< "${list}"
  for z in "${names[@]}"; do
    [[ -z "${z}" ]] && continue
    if ! echo "${ZONES}" | jq -e --arg K "${z}" 'has($K)' >/dev/null; then
      errln "Trunk zone '${z}' is not defined in zones.json"; exit 1
    fi
    state=$(echo "${ZONES}" | jq -r --arg K "${z}" '.[$K].state')
    # Allowlist (#211): only Active/Mandatory/Manual zones go on the trunk.
    # Inactive/Disabled and any future state are skipped with a warning.
    case "${state}" in
      Active|Mandatory|Manual) ;;
      *) warn "Trunk zone '${z}' (state: ${state}) is not trunkable, skipping"; continue ;;
    esac
    tag=$(echo "${ZONES}" | jq -r --arg K "${z}" '.[$K].vlantag')
    # Reject vlantag=0 (untagged is meaningless on a trunk list).
    if [[ -z "${tag}" || "${tag}" -le 0 ]]; then
      warn "Trunk zone '${z}' has vlantag=${tag} (untagged), skipping"
      continue
    fi
    result="${result:+${result};}${tag}"
  done
  echo -n "${result}"
}

# ── Resolve desired state ────────────────────────────────────────────

info "${BOLD}Creating TAPPaaS LXC using the following settings:${CL}"

VMID="$(get_config_value 'vmid')"
if pct status "${VMID}" &>/dev/null || qm status "${VMID}" &>/dev/null; then
  errln "Guest ${VMID} already exists on this node — refusing to overwrite. Remove it first."
  trap - ERR
  exit 1
fi

VMNAME="$(get_config_value 'vmname' "$1")"
VMTAG="$(get_config_value 'vmtag' 'TAPPaaS')"
CORES="$(get_config_value 'cores' '2')"
MEMORY="$(get_config_value 'memory' '4096')"
DISK="$(get_config_value 'diskSize' '8G')"
STORAGE="$(get_config_value 'storage' 'tanka1')"
IMAGE="$(get_config_value 'image')"               # CT template filename
BRIDGE0="$(get_config_value 'bridge0' 'lan')"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
TRUNKS0="$(get_config_value 'trunks0' 'NONE')"

GEN_MAC0="02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')"
MAC0="$(get_config_value 'mac0' "${GEN_MAC0}")"

VLANTAG0="$(get_vlan_value "${ZONE0}")"
TRUNKTAGS0=""
[[ "${TRUNKS0}" != "NONE" ]] && TRUNKTAGS0="$(resolve_trunks "${TRUNKS0}")"

# LXC options (overridable via meta.lxcOptions)
UNPRIVILEGED="$(get_meta '.lxcOptions.unprivileged' '1')"
FEATURES="$(get_meta '.lxcOptions.features' 'nesting=1')"
SWAP="$(get_meta '.lxcOptions.swap' '0')"

# ostype: sniff from template filename (debian-*/ubuntu-*); else 'unmanaged'.
case "${IMAGE,,}" in
  *debian*) CT_OSTYPE="debian" ;;
  *ubuntu*) CT_OSTYPE="ubuntu" ;;
  *alpine*) CT_OSTYPE="alpine" ;;
  *)        CT_OSTYPE="unmanaged" ;;
esac

# ── Download CT template if absent ───────────────────────────────────

TEMPLATE_PATH="/var/lib/vz/template/cache/${IMAGE}"
if [[ ! -f "${TEMPLATE_PATH}" ]]; then
  info "Downloading CT template ${BL}${IMAGE}${CL} via pveam..."
  pveam update >/dev/null
  pveam download local "${IMAGE}" >/dev/null
fi

# ── Build net0 (name=eth0,bridge,tag,hwaddr,trunks,ip=dhcp) ──────────

NET0="name=eth0,bridge=${BRIDGE0},hwaddr=${MAC0},ip=dhcp"
[[ "${VLANTAG0}" != "0" ]] && NET0="${NET0},tag=${VLANTAG0}"
[[ -n "${TRUNKTAGS0}" ]]   && NET0="${NET0},trunks=${TRUNKTAGS0}"

# ── Create the container ─────────────────────────────────────────────

info "${BOLD}Creating LXC ${VMNAME} (ID: ${VMID})...${CL}"
pct create "${VMID}" "local:vztmpl/${IMAGE}" \
  --hostname "${VMNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK//G/}" \
  --net0 "${NET0}" \
  --ostype "${CT_OSTYPE}" \
  --unprivileged "${UNPRIVILEGED}" \
  --features "${FEATURES}" \
  --tags "${VMTAG}" \
  --onboot 1 \
  >/dev/null
CREATED=1
info "  Created container ${VMID} on bridge ${BRIDGE0} (zone ${ZONE0}, tag ${VLANTAG0})"

CONF="/etc/pve/lxc/${VMID}.conf"

# ── Optional GPU passthrough (meta.gpu) ──────────────────────────────

if [[ "$(get_meta '.gpu' '')" != "" ]]; then
  KFD_MAJOR="$(get_meta '.gpu.kfd_major')"
  KFD_MINOR="$(get_meta '.gpu.kfd_minor')"
  RENDER_NODE="$(get_meta '.gpu.render_node')"
  RENDER_MAJOR="$(get_meta '.gpu.render_major')"
  RENDER_MINOR="$(get_meta '.gpu.render_minor')"
  info "Configuring GPU passthrough (kfd ${KFD_MAJOR}:${KFD_MINOR}, ${RENDER_NODE} ${RENDER_MAJOR}:${RENDER_MINOR})..."
  {
    echo ""
    echo "# GPU passthrough — generated by Create-TAPPaaS-LXC.sh"
    echo "lxc.cgroup2.devices.allow: c ${KFD_MAJOR}:${KFD_MINOR} rwm"
    echo "lxc.cgroup2.devices.allow: c ${RENDER_MAJOR}:${RENDER_MINOR} rwm"
    echo "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file"
    echo "lxc.mount.entry: /dev/dri/${RENDER_NODE} dev/dri/${RENDER_NODE} none bind,optional,create=file"
  } >> "${CONF}"
fi

# ── Optional bind mounts (meta.bindMounts[]) ─────────────────────────

BIND_COUNT="$(echo "${META}" | jq -r '.bindMounts | length // 0' 2>/dev/null || echo 0)"
if [[ "${BIND_COUNT}" =~ ^[0-9]+$ && "${BIND_COUNT}" -gt 0 ]]; then
  info "Configuring ${BIND_COUNT} bind-mount(s) (note: pct snapshot unavailable with bind mounts)..."
  for i in $(seq 0 $((BIND_COUNT - 1))); do
    src="$(echo "${META}" | jq -r --argjson i "${i}" '.bindMounts[$i].src')"
    dst="$(echo "${META}" | jq -r --argjson i "${i}" '.bindMounts[$i].dst')"
    [[ -z "${src}" || -z "${dst}" || "${src}" == "null" || "${dst}" == "null" ]] && continue
    mkdir -p "${src}"
    echo "mp${i}: ${src},mp=${dst}" >> "${CONF}"
    info "  mp${i}: ${src} → ${dst}"
  done
fi

# ── Start ────────────────────────────────────────────────────────────

info "Starting LXC ${VMID}..."
pct start "${VMID}"

trap - ERR
echo ""
info "${GN}✅ LXC ${VMNAME} (ID: ${VMID}) created and started on $(hostname -s).${CL}"
