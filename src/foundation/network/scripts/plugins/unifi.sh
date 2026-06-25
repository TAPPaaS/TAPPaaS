# shellcheck shell=bash
#
# plugins/unifi.sh — UniFi vendor plugin for switch-controller + ap-manager (ADR-008 Stage 5, #339).
#
# Configures UniFi switches AND WiFi APs via the self-hosted UniFi OS Server Network
# API. Sourced by switch-controller and ap-manager (each select_plugin picks this for
# vendor "unifi"). Implements two contracts that share plugin_supports:
#   switch verbs: plugin_interrogate / plugin_apply       (ports → port_overrides)
#   AP verbs:     plugin_ap_interrogate / plugin_ap_apply (SSIDs → wlanconf)
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

# ── Contract: supports + management metadata ────────────────────────
plugin_supports() { [[ "${1:-}" == "unifi" ]]; }

# UniFi is a CONTROLLER-architecture brand: switches are adopted by a UniFi OS
# controller (which setup-switches can install or register), not configured per
# device. (MikroTik will be "device".) Drives setup-switches' management menu.
plugin_arch() { echo "controller"; }
# The TAPPaaS module that provides a controller for the "install a controller" path.
plugin_controller_module() { echo "unifi-os"; }

# ── Contract: interrogate <name> <mgmt_ip> ──────────────────────────
# Emit the device's live state in switch-controller's actual-switch shape:
#   {vendor,model,managementIp,ports:{ "<idx>": {mode,nativeVlan,taggedVlans,...} }}
# Match the UniFi device by management IP first, then by name.
plugin_interrogate() {
    local name="$1" mgmt_ip="${2:-}"
    _unifi_login || { echo "{}"; return 0; }
    local devs nets
    devs=$(_unifi_get /stat/device)
    echo "${devs}" | jq -e . >/dev/null 2>&1 || { _unifi_warn "no/invalid device list (unreachable or rate-limited?)"; echo "{}"; return 0; }
    nets=$(_unifi_get /rest/networkconf)
    echo "${nets}" | jq -e . >/dev/null 2>&1 || nets='{"data":[]}'

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

# ── Contract: controller-interrogate <controller> <controller_ip> ───
# Enumerate every SWITCH (type "usw") the UniFi controller adopts and emit them
# in switch-controller's controller-upload shape:
#   { switches: { "<device name>": {vendor,model,managementIp,ports:{ "<idx>":{...} }} } }
# Port mapping is identical to plugin_interrogate (forward/native/excluded →
# access/trunk + VLANs). switch-controller merges this into actual, preserving any
# operator port annotations (type/target/targetPort).
plugin_controller_interrogate() {
    local name="$1" mgmt_ip="${2:-}"   # mgmt_ip unused: creds carry the URL
    _unifi_login || { echo "{}"; return 0; }
    local devs nets
    devs=$(_unifi_get /stat/device)
    echo "${devs}" | jq -e . >/dev/null 2>&1 || { _unifi_warn "controller returned no/invalid device list (unreachable or rate-limited?)"; echo "{}"; return 0; }
    nets=$(_unifi_get /rest/networkconf)
    echo "${nets}" | jq -e . >/dev/null 2>&1 || nets='{"data":[]}'

    jq -n --argjson devs "${devs}" --argjson nets "${nets}" '
        (reduce (($nets.data // [])[]) as $n ({}; .[$n._id] = ($n.vlan // 0))) as $id2vlan
        | ([ ($nets.data // [])[] | (.vlan // 0) | select(. > 0) ] | sort | unique) as $allvlans
        # switch MAC -> name, to resolve an AP uplink to its switch.
        | ([ ($devs.data // [])[] | select(.type=="usw") | {key:.mac, value:.name} ] | from_entries) as $swmac
        | { switches: (reduce (($devs.data // []) | map(select(.type=="usw")) | .[]) as $d ({};
            (reduce ($d.port_overrides[]?) as $o ({}; .[($o.port_idx|tostring)] = $o)) as $ov
            | .[$d.name] = {
                vendor: "unifi",
                model: ($d.model // ""),
                managementIp: ($d.ip // ""),
                ports: (reduce ($d.port_table[]?) as $p ({};
                    ($p.port_idx|tostring) as $k
                    | ($ov[$k] // {}) as $o
                    | (($o.forward // $p.forward) // "all") as $fwd
                    | (($o.native_networkconf_id) // null) as $nat
                    | (if $nat == null then 0 else ($id2vlan[$nat] // 0) end) as $natvlan
                    | (($o.excluded_networkconf_ids) // []) as $excl
                    | ([ $excl[] | ($id2vlan[.] // empty) ]) as $exclv
                    | . + { ($k): (
                        if $fwd == "native" then { mode:"access", nativeVlan:$natvlan, source:"discovered" }
                        elif $fwd == "disabled" then { mode:"access", nativeVlan:0, disabled:true, source:"discovered" }
                        elif $fwd == "customize" then { mode:"trunk", nativeVlan:$natvlan, taggedVlans:($allvlans - $exclv), source:"discovered" }
                        else { mode:"trunk", nativeVlan:$natvlan, taggedVlans:$allvlans, source:"discovered" } end) }
                  ))
              } )),
            # APs (type "uap") with their wired uplink resolved to a switch + port,
            # so switch-controller can register that port as an AP trunk.
            aps: (reduce (($devs.data // []) | map(select(.type=="uap")) | .[]) as $d ({};
                ($d.uplink // {}) as $u
                | .[$d.name] = {
                    vendor: "unifi",
                    model: ($d.model // ""),
                    managementIp: ($d.ip // ""),
                    uplinkSwitch: (($u.uplink_device_name // $swmac[$u.uplink_mac]) // ""),
                    uplinkPort: (if ($u.uplink_remote_port != null) then ($u.uplink_remote_port|tostring) else "" end)
                  } )) }'
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

    # TAPPaaS only manages ports it has ANNOTATED (a `type` set by add-port /
    # update-port, or the auto-detected AP port). Discovered ports with no type
    # are left exactly as the switch has them (don't convert forward:all → custom).
    desired=$(echo "${desired}" | jq -c 'with_entries(select(.value.type != null))')
    [[ "${desired}" != "{}" ]] || { _unifi_warn "${name}: no TAPPaaS-managed ports — nothing to apply"; return 0; }

    # Ensure a VLAN-only network for each VLAN id used by the managed ports.
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

# ════════════════════════════════════════════════════════════════════
# AP / WiFi support (sourced by ap-manager). The AP contract uses the
# `plugin_ap_*` names so it never collides with the switch verbs above —
# both managers source THIS file. plugin_supports (vendor==unifi) is shared.
# ════════════════════════════════════════════════════════════════════

# Cached networkconf blob (shared by the VLAN-network helper).
_UNIFI_NETS=""
_unifi_refresh_nets() { _UNIFI_NETS=$(_unifi_get /rest/networkconf); }

# Ensure a VLAN-only network exists for <vlan>; echo its networkconf _id.
# vlan 0 → the Default (untagged) network. TAPPaaS keeps gateway/DHCP on
# OPNsense, so created networks are VLAN-only (DHCP off). Returns 1 on error.
_unifi_ensure_vlan_network() {
    local vlan="$1" id resp
    [[ -n "${_UNIFI_NETS}" ]] || _unifi_refresh_nets
    if [[ "${vlan}" -eq 0 ]]; then
        echo "${_UNIFI_NETS}" | jq -r '([.data[]|select((.vlan//null)==null)][0]._id) // .data[0]._id'
        return 0
    fi
    id=$(echo "${_UNIFI_NETS}" | jq -r --argjson v "${vlan}" '.data[]|select(.vlan==$v)._id' | head -1)
    if [[ -z "${id}" || "${id}" == "null" ]]; then
        resp=$(_unifi_send POST /rest/networkconf \
            "$(jq -nc --arg n "tappaas-vlan-${vlan}" --argjson v "${vlan}" '{name:$n,purpose:"vlan-only",vlan_enabled:true,vlan:$v,networkgroup:"LAN",enabled:true}')")
        if [[ "$(echo "${resp}" | jq -r '.meta.rc // empty')" != "ok" ]]; then
            _unifi_warn "failed to create VLAN-only network for VLAN ${vlan}: $(echo "${resp}" | jq -rc '.meta.msg // .')"; return 1
        fi
        id=$(echo "${resp}" | jq -r '.data[0]._id')
        _unifi_refresh_nets
        _unifi_log_ok "created VLAN-only network for VLAN ${vlan}" >&2
    fi
    echo "${id}"
}

# The site's "All APs" group id (newer wlanconf uses ap_group_ids + ap_group_mode).
_unifi_default_apgroup() {
    curl -sk -m 20 -b "${_UNIFI_JAR}" ${_UNIFI_CSRF:+-H "X-CSRF-Token: ${_UNIFI_CSRF}"} \
        "${_UNIFI_URL}/proxy/network/v2/api/site/${UNIFI_SITE}/apgroups" 2>/dev/null \
        | jq -r '([.[]|select(.attr_hidden_id=="default")][0]._id) // (.[0]._id) // empty'
}

# WLAN passphrase for <ssid>, read from the vendor-neutral secrets file managed
# by setup-wlan-secrets.sh (never the committed config): lines "<ssid>=<passphrase>"
# (split on the FIRST '=' so passphrases may contain '='). Empty if not present.
_unifi_wlan_passphrase() {
    local ssid="$1" f="${WLAN_SECRETS:-/home/tappaas/.wlan-secrets.txt}"
    [[ -f "${f}" ]] || return 0
    awk -v s="${ssid}" '{eq=index($0,"="); if(eq>0 && substr($0,1,eq-1)==s){print substr($0,eq+1); exit}}' "${f}"
}

# Build the wlanconf security fields for a TAPPaaS security level + passphrase.
# (Enterprise needs a RADIUS profile object — handled by the caller, not here.)
_unifi_security_fields() {
    local sec="$1" pass="$2"
    jq -nc --arg sec "${sec}" --arg pass "${pass}" '
        if   $sec=="open" then {security:"open"}
        elif $sec=="wpa3-personal" then {security:"wpapsk", wpa_mode:"wpa3", wpa_enc:"ccmp", pmf_mode:"required"}
        else {security:"wpapsk", wpa_mode:"wpa2", wpa_enc:"ccmp", pmf_mode:"optional"} end
        + (if $pass!="" then {x_passphrase:$pass} else {} end)'
}

# ── AP contract: interrogate <name> <mgmt_ip> ───────────────────────
# UniFi WLANs are controller-wide (broadcast by AP groups), so we report
# every WLAN as an SSID on the matched AP. Emit ap-manager's actual shape:
#   {vendor,model,managementIp,ssids:{ "<ssid>": {vlan,enabled,security} }}
plugin_ap_interrogate() {
    local name="$1" mgmt_ip="${2:-}"
    _unifi_login || { echo "{}"; return 0; }
    local devs nets wlans
    devs=$(_unifi_get /stat/device)
    echo "${devs}" | jq -e . >/dev/null 2>&1 || { _unifi_warn "no/invalid device list (unreachable or rate-limited?)"; echo "{}"; return 0; }
    nets=$(_unifi_get /rest/networkconf); echo "${nets}" | jq -e . >/dev/null 2>&1 || nets='{"data":[]}'
    wlans=$(_unifi_get /rest/wlanconf);   echo "${wlans}" | jq -e . >/dev/null 2>&1 || wlans='{"data":[]}'

    jq -n --arg name "${name}" --arg ip "${mgmt_ip}" \
          --argjson devs "${devs}" --argjson nets "${nets}" --argjson wlans "${wlans}" '
        (reduce (($nets.data // [])[]) as $n ({}; .[$n._id] = ($n.vlan // 0))) as $id2vlan
        | ( ($devs.data // []) | map(select((.type=="uap") and (((.ip==$ip) and ($ip!="")) or (.name==$name)))) | .[0] ) as $d
        | if $d == null then {} else
            {
              vendor: "unifi",
              model: ($d.model // ""),
              managementIp: ($d.ip // $ip),
              ssids: (reduce (($wlans.data // [])[]) as $w ({};
                  .[$w.name] = {
                    vlan: ($id2vlan[$w.networkconf_id] // 0),
                    enabled: (if ($w|has("enabled")) then $w.enabled else true end),
                    security: (
                      if   $w.security=="open"  then "open"
                      elif $w.security=="wpaeap" then (if $w.wpa_mode=="wpa3" then "wpa3-enterprise" else "wpa2-enterprise" end)
                      else (if $w.wpa_mode=="wpa3" then "wpa3-personal" else "wpa2-personal" end) end),
                    source: "discovered"
                  }))
            }
          end'
    return 0
}

# ── AP contract: apply <name> <delta_json> ──────────────────────────
# Converge controller WLANs to the DESIRED ssids of this AP (read from
# switch-configuration-desired.json). Creates VLAN-only networks as needed,
# then creates/updates a wlanconf per SSID bound to that network. Does not
# delete WLANs (mirrors switch-controller — removal stays operator-driven).
plugin_ap_apply() {
    local name="$1"  # $2 = delta json (unused; we converge to desired)
    _unifi_login || return 1
    local dfile="${CONFIG_DIR:-/home/tappaas/config}/switch-configuration-desired.json"
    [[ -f "${dfile}" ]] || { _unifi_warn "desired config not found: ${dfile}"; return 1; }

    local ssids
    ssids=$(jq -c --arg n "${name}" '.accessPoints[$n].ssids // {}' "${dfile}" 2>/dev/null)
    [[ -n "${ssids}" && "${ssids}" != "{}" && "${ssids}" != "null" ]] || { _unifi_warn "${name}: no desired SSIDs — nothing to apply"; return 0; }

    _unifi_refresh_nets
    local ug ag wlans
    ug=$(_unifi_get /rest/usergroup | jq -r '.data[]|select(.name=="Default")._id' | head -1)
    ag=$(_unifi_default_apgroup)
    wlans=$(_unifi_get /rest/wlanconf)
    [[ -n "${ug}" && "${ug}" != "null" ]] || { _unifi_warn "no Default usergroup found"; return 1; }
    [[ -n "${ag}" ]] || { _unifi_warn "no AP group found"; return 1; }

    local rc=0 ssid
    while IFS= read -r ssid; do
        [[ -z "${ssid}" ]] && continue
        local vlan sec enabled netid pass secf existing body resp cur
        vlan=$(echo "${ssids}"   | jq -r --arg s "${ssid}" '.[$s].vlan // 0')
        sec=$(echo "${ssids}"    | jq -r --arg s "${ssid}" '.[$s].security // "wpa2-personal"')
        enabled=$(echo "${ssids}"| jq -r --arg s "${ssid}" '.[$s] | if has("enabled") then .enabled else true end')
        existing=$(echo "${wlans}" | jq -r --arg s "${ssid}" '.data[]|select(.name==$s)._id' | head -1)

        case "${sec}" in
            wpa2-enterprise|wpa3-enterprise)
                _unifi_warn "${ssid}: ${sec} needs a RADIUS profile (not yet automated) — configure this SSID by hand in the UniFi UI"
                rc=1; continue ;;
        esac

        pass=$(_unifi_wlan_passphrase "${ssid}")
        if [[ "${sec}" == wpa2-personal || "${sec}" == wpa3-personal ]] && [[ -z "${existing}" && -z "${pass}" ]]; then
            _unifi_warn "${ssid}: WPA-personal needs a passphrase to create — run setup-wlan-secrets.sh (or add '${ssid}=<psk>' to ${WLAN_SECRETS:-/home/tappaas/.wlan-secrets.txt}), then re-run"
            rc=1; continue
        fi

        netid=$(_unifi_ensure_vlan_network "${vlan}") || { rc=1; continue; }
        secf=$(_unifi_security_fields "${sec}" "${pass}")

        if [[ -n "${existing}" && "${existing}" != "null" ]]; then
            cur=$(echo "${wlans}" | jq -c --arg id "${existing}" '.data[]|select(._id==$id)')
            body=$(jq -nc --argjson cur "${cur}" --argjson en "${enabled}" --arg net "${netid}" --argjson sf "${secf}" \
                '$cur + {enabled:$en, networkconf_id:$net} + $sf')
            resp=$(_unifi_send PUT "/rest/wlanconf/${existing}" "${body}")
        else
            body=$(jq -nc --arg n "${ssid}" --argjson en "${enabled}" --arg net "${netid}" \
                          --arg ug "${ug}" --arg ag "${ag}" --argjson sf "${secf}" \
                '{name:$n, enabled:$en, networkconf_id:$net, usergroup_id:$ug,
                  ap_group_ids:[$ag], ap_group_mode:"all", wlan_band:"both"} + $sf')
            resp=$(_unifi_send POST /rest/wlanconf "${body}")
        fi
        if [[ "$(echo "${resp}" | jq -r '.meta.rc // empty')" == "ok" ]]; then
            _unifi_log_ok "${name}: SSID '${ssid}' → VLAN ${vlan} ($([[ -n "${existing}" && "${existing}" != "null" ]] && echo updated || echo created))"
        else
            _unifi_warn "${name}: SSID '${ssid}' failed: $(echo "${resp}" | jq -rc '.meta.msg // .' 2>/dev/null | head -c 200)"
            rc=1
        fi
    done < <(echo "${ssids}" | jq -r 'keys[]')
    return "${rc}"
}
