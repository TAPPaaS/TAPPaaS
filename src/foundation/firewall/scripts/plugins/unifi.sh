# shellcheck shell=bash
#
# plugins/unifi.sh — UniFi vendor plugin for switch-manager (ADR-008 Stage 5, #339).
#
# Configures UniFi switches via the self-hosted UniFi OS Server Network API. Sourced
# by switch-manager (its select_plugin picks this for vendor "unifi"); implements the
# plugin contract: plugin_supports / plugin_interrogate / plugin_apply.
#
# Self-hosted UniFi OS has no API keys, so we authenticate with a LOCAL ADMIN read
# from /home/tappaas/.unifi-os-credentials.txt (POST /api/auth/login -> TOKEN cookie +
# X-CSRF-Token), then use the classic Network API at {url}/proxy/network/api/s/<site>/.
#
# UniFi models a port's VLANs by referencing network objects (networkconf _id), not
# raw VLAN ids — so we map vlan<->_id. TAPPaaS zones keep gateway/DHCP on OPNsense, so
# VLAN networks created here are "VLAN-only" (DHCP disabled). (Phase 2)
#
# Requires: curl, jq, and the caller's info/warn/error helpers (fallbacks provided).

UNIFI_CRED="${UNIFI_CRED:-/home/tappaas/.unifi-os-credentials.txt}"
UNIFI_SITE="${UNIFI_SITE:-default}"

# Per-process session cache.
_UNIFI_JAR=""
_UNIFI_CSRF=""
_UNIFI_URL=""

_unifi_warn() { if command -v warn >/dev/null 2>&1; then warn "$*"; else echo "unifi.sh: $*" >&2; fi; }

# Log in once per process; populates _UNIFI_URL/_UNIFI_JAR/_UNIFI_CSRF. Returns 1 on failure.
_unifi_login() {
    [[ -n "${_UNIFI_JAR}" && -s "${_UNIFI_JAR}" ]] && return 0
    [[ -f "${UNIFI_CRED}" ]] || { _unifi_warn "credentials file ${UNIFI_CRED} not found"; return 1; }
    local url u p
    url=$(awk -F= '/^url=/{sub(/^url=/,"");print;exit}' "${UNIFI_CRED}")
    u=$(awk -F= '/^username=/{sub(/^username=/,"");print;exit}' "${UNIFI_CRED}")
    p=$(awk -F= '/^password=/{sub(/^password=/,"");print;exit}' "${UNIFI_CRED}")
    [[ -n "${url}" && -n "${u}" && -n "${p}" ]] || { _unifi_warn "credentials incomplete in ${UNIFI_CRED} (run setup-credentials.sh)"; return 1; }
    _UNIFI_URL="${url%/}"
    _UNIFI_JAR=$(mktemp)
    local hdr code
    hdr=$(mktemp)
    code=$(curl -sk -m 20 -c "${_UNIFI_JAR}" -D "${hdr}" -o /dev/null -w '%{http_code}' \
        -X POST -H "Content-Type: application/json" \
        -d "$(jq -nc --arg u "${u}" --arg p "${p}" '{username:$u,password:$p}')" \
        "${_UNIFI_URL}/api/auth/login" 2>/dev/null || echo 000)
    _UNIFI_CSRF=$(awk 'tolower($0) ~ /^x-csrf-token:/ {print $2}' "${hdr}" | tr -d '\r' | tail -1)
    rm -f "${hdr}"
    if [[ "${code}" != "200" ]]; then
        _unifi_warn "UniFi login failed (HTTP ${code}) — use a LOCAL admin (no SSO/MFA); see setup-credentials.sh"
        rm -f "${_UNIFI_JAR}"; _UNIFI_JAR=""
        return 1
    fi
    return 0
}

# GET {site-base}{path}; POST/PUT with a JSON body.
_unifi_get()  { curl -sk -m 20 -b "${_UNIFI_JAR}" ${_UNIFI_CSRF:+-H "X-CSRF-Token: ${_UNIFI_CSRF}"} "${_UNIFI_URL}/proxy/network/api/s/${UNIFI_SITE}$1" 2>/dev/null; }
_unifi_send() { local m="$1" path="$2" body="$3"; curl -sk -m 25 -b "${_UNIFI_JAR}" ${_UNIFI_CSRF:+-H "X-CSRF-Token: ${_UNIFI_CSRF}"} -H "Content-Type: application/json" -X "${m}" -d "${body}" "${_UNIFI_URL}/proxy/network/api/s/${UNIFI_SITE}${path}" 2>/dev/null; }

# ── Contract: supports ──────────────────────────────────────────────
plugin_supports() { [[ "${1:-}" == "unifi" ]]; }

# ── Contract: interrogate <name> <mgmt_ip> ──────────────────────────
# Emit the device's live state in switch-manager's actual-switch shape:
#   {vendor,model,managementIp,ports:{ "<idx>": {mode,nativeVlan,taggedVlans,...} }}
# Match the UniFi device by management IP first, then by name.
plugin_interrogate() {
    local name="$1" mgmt_ip="${2:-}"
    _unifi_login || { echo "{}"; return 0; }
    local devs nets
    devs=$(_unifi_get /stat/device) || { echo "{}"; return 0; }
    nets=$(_unifi_get /rest/networkconf)
    [[ -n "${devs}" ]] || { echo "{}"; return 0; }
    [[ -n "${nets}" ]] || nets='{}'

    jq -n --arg name "${name}" --arg ip "${mgmt_ip}" \
          --argjson devs "${devs}" --argjson nets "${nets}" '
        # vlan map: networkconf _id -> vlan id (0 when untagged/Default)
        (reduce (($nets.data // [])[]) as $n ({}; .[$n._id] = ($n.vlan // 0))) as $id2vlan
        # all defined tagged VLAN ids (for forward=all/customize trunks)
        | ([ ($nets.data // [])[] | (.vlan // 0) | select(. > 0) ] | sort | unique) as $allvlans
        | ( ($devs.data // []) | map(select(((.ip==$ip) and ($ip!="")) or (.name==$name))) | .[0] ) as $d
        | if $d == null then {} else
          # port_overrides keyed by port_idx (explicit config); port_table gives effective forward
          (reduce ($d.port_overrides[]?) as $o ({}; .[($o.port_idx|tostring)] = $o)) as $ov
          | {
              vendor: "unifi",
              model: ($d.model // ""),
              managementIp: ($d.ip // $ip),
              ports: (reduce ($d.port_table[]?) as $p ({};
                  ($p.port_idx|tostring) as $k
                  | ($ov[$k] // {}) as $o
                  | (($o.forward // $p.forward) // "all") as $fwd
                  | (($o.native_networkconf_id) // null) as $nat
                  | (if $nat == null then 0 else ($id2vlan[$nat] // 0) end) as $natvlan
                  | (($o.excluded_networkconf_ids) // []) as $excl
                  | ([ $excl[] | ($id2vlan[.] // empty) ]) as $exclv
                  | . + { ($k): (
                      if $fwd == "native" then
                        { mode:"access", nativeVlan:$natvlan, source:"discovered" }
                      elif $fwd == "disabled" then
                        { mode:"access", nativeVlan:0, disabled:true, source:"discovered" }
                      elif $fwd == "customize" then
                        { mode:"trunk", nativeVlan:$natvlan, taggedVlans:($allvlans - $exclv), source:"discovered" }
                      else   # "all"
                        { mode:"trunk", nativeVlan:$natvlan, taggedVlans:$allvlans, source:"discovered" }
                      end) }
              ))
          }
        end'
    return 0
}

# ── Contract: apply <name> <delta_json> ─────────────────────────────
# Converge the UniFi switch to the DESIRED port config (read from
# switch-configuration-desired.json — the delta only signals that work exists):
#   1. ensure a VLAN-only network exists for every native/tagged VLAN used;
#   2. merge per-port overrides into the device's port_overrides (preserving
#      ports not managed by TAPPaaS), then PUT the device.
# Port mapping (confirmed against UniFi OS 5.x):
#   access      → forward:native,   native_networkconf_id, tagged_vlan_mgmt:block_all
#   trunk       → forward:customize, native, excluded_networkconf_ids = (all VLAN
#                 networks) − (tagged ∪ native)   [exclusion model; empty ⇒ all]
plugin_apply() {
    local name="$1"  # $2 = delta json (unused; we converge to desired)
    _unifi_login || return 1
    local dfile="${CONFIG_DIR:-/home/tappaas/config}/switch-configuration-desired.json"
    [[ -f "${dfile}" ]] || { _unifi_warn "desired config not found: ${dfile}"; return 1; }

    local desired mip
    desired=$(jq -c --arg n "${name}" '.switches[$n].ports // {}' "${dfile}" 2>/dev/null)
    mip=$(jq -r --arg n "${name}" '.switches[$n].managementIp // ""' "${dfile}" 2>/dev/null)
    [[ -n "${desired}" && "${desired}" != "{}" && "${desired}" != "null" ]] || { _unifi_warn "${name}: no desired ports — nothing to apply"; return 0; }

    local nets devs devid
    nets=$(_unifi_get /rest/networkconf); [[ -n "${nets}" ]] || { _unifi_warn "could not read networks"; return 1; }
    devs=$(_unifi_get /stat/device)
    devid=$(echo "${devs}" | jq -r --arg n "${name}" --arg ip "${mip}" '.data[] | select(((.ip==$ip) and ($ip!="")) or (.name==$n)) | ._id' 2>/dev/null | head -1)
    [[ -n "${devid}" ]] || { _unifi_warn "${name}: no matching UniFi device (ip=${mip})"; return 1; }

    # Ensure a VLAN-only network for each VLAN id used by the desired ports.
    local needed v id resp
    needed=$(echo "${desired}" | jq -r '[ (.[] | (.nativeVlan // 0), ((.taggedVlans // [])[]) ) ] | map(select(. > 0)) | unique | .[]' 2>/dev/null)
    for v in ${needed}; do
        id=$(echo "${nets}" | jq -r --argjson v "${v}" '.data[] | select(.vlan==$v) | ._id' | head -1)
        [[ -n "${id}" ]] && continue
        resp=$(_unifi_send POST /rest/networkconf \
            "$(jq -nc --arg n "tappaas-vlan-${v}" --argjson v "${v}" '{name:$n,purpose:"vlan-only",vlan_enabled:true,vlan:$v,networkgroup:"LAN",enabled:true}')")
        if [[ "$(echo "${resp}" | jq -r '.meta.rc // empty')" != "ok" ]]; then
            _unifi_warn "failed to create VLAN-only network for VLAN ${v}: $(echo "${resp}" | jq -rc '.meta.msg // .')"; return 1
        fi
        _unifi_log_ok "created VLAN-only network for VLAN ${v}"
    done
    # Re-read networks so the map includes any just-created ones.
    nets=$(_unifi_get /rest/networkconf)

    # Build the merged port_overrides array.
    local overrides
    overrides=$(jq -n --argjson nets "${nets}" --argjson desired "${desired}" \
                       --argjson cur "$(echo "${devs}" | jq -c --arg id "${devid}" '.data[]|select(._id==$id)|.port_overrides // []')" '
        (reduce ($nets.data[] | select(.vlan != null and .vlan > 0)) as $n ({}; .[($n.vlan|tostring)] = $n._id)) as $vid
        | ([ $nets.data[] | select(.vlan == null) ][0]._id // $nets.data[0]._id) as $def
        | ([ $nets.data[] | select(.vlan != null and .vlan > 0) | ._id ]) as $allvlannets
        | (reduce ($cur[]?) as $o ({}; .[($o.port_idx|tostring)] = $o)) as $curmap
        | ($desired | to_entries | map(
            (.key|tonumber) as $idx | .value as $p
            | ($p.nativeVlan // 0) as $nv
            | (if $nv > 0 then ($vid[($nv|tostring)] // $def) else $def end) as $native_id
            | if $p.mode == "access" then
                {port_idx:$idx, forward:"native", native_networkconf_id:$native_id, tagged_vlan_mgmt:"block_all"}
              else
                ([ ($p.taggedVlans // [])[] | ($vid[(.|tostring)] // empty) ]) as $tagids
                | {port_idx:$idx, forward:"customize", native_networkconf_id:$native_id,
                   excluded_networkconf_ids: ($allvlannets - $tagids - [$native_id])}
              end)) as $new
        | (reduce $new[] as $np ($curmap; .[($np.port_idx|tostring)] = $np)) | [ .[] ]
    ')

    resp=$(_unifi_send PUT "/rest/device/${devid}" "$(jq -nc --argjson po "${overrides}" '{port_overrides:$po}')")
    if [[ "$(echo "${resp}" | jq -r '.meta.rc // empty')" == "ok" ]]; then
        _unifi_log_ok "${name}: applied $(echo "${desired}" | jq 'length') port(s) to UniFi"
        return 0
    fi
    _unifi_warn "${name}: device PUT failed: $(echo "${resp}" | jq -rc '.meta.msg // .' 2>/dev/null | head -c 200)"
    return 1
}

_unifi_log_ok() { if command -v info >/dev/null 2>&1; then info "  ${GN:-}✓${CL:-} $*"; else echo "unifi.sh: $*" >&2; fi; }
