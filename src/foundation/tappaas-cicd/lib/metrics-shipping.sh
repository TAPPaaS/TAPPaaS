#!/usr/bin/env bash
#
# metrics-shipping.sh — numbers to the logging VM's metrics store
# (logging:metrics, ADR-046 P1). Sourceable only; needs log-shipping.sh's
# credential store, which it sources.
#
# Who pushes, and as whom:
#   - the Proxmox cluster, through its external metric server (OpenTelemetry
#     over HTTPS, one cluster-wide setting in /etc/pve/status.cfg) and the
#     nodes' guest-memory sampler, both with the cluster credential
#     (user METRICS_PVE_USER). The cluster is one trust domain — every node is
#     root on every other — so the credential names the cluster, and the
#     logging VM takes the node from the `node` label, only among the nodes it
#     was told of.
#   - PBS, through its InfluxDB HTTP metric server, with the PBS instance's own
#     credential sent as an InfluxDB token.
#   - guests' own Alloy (P2), with their logging:logs credential.
# The credentials are log-shipping.sh's (~tappaas/.loki-push/<user>): one per
# pushing host, for logs and metrics alike.
#
# Identity (ADR-040 D14, ADR-046 D4.1): nginx on the logging VM passes the
# authenticated user to Alloy, which writes it as `host` over whatever the
# sender said. Alloy then stamps tappaas_ci_id, service_instance_id,
# service_name, service_namespace and deployment_environment_name from a
# module this file renders from the CMDB (render_metrics_identity) and puts on
# the logging VM (metrics_sync_logging): by host for what a host says about
# itself, by vmid for what a node says about its guests. Nothing a sender
# writes in those labels survives.
#
# Functions:
#   metrics_level                      off | basic | service (site.json, by size)
#   metrics_retention_days             days the store keeps (site.json, by size)
#   metrics_wanted                     0 when logging is deployed and level != off
#   metrics_push_url / metrics_query_url
#   metrics_curl_admin <curl args>     curl against the query port as admin
#   metrics_identity_json              the identity map (CMDB + config/), cached
#   render_metrics_identity <json>     the Alloy module, on stdout
#   metrics_sync_logging               identity module, InfluxDB tokens and
#                                      retention onto the logging VM
#   metrics_pve_state / apply_metrics_pve / remove_metrics_pve
#   metrics_pbs_state / apply_metrics_pbs / remove_metrics_pbs
#     *_state prints in-sync | missing | stale | unwanted | absent | unknown

if [[ -z "${_METRICS_SHIPPING_LOADED:-}" ]]; then
_METRICS_SHIPPING_LOADED=1

# shellcheck source=log-shipping.sh
. "${LOG_SHIPPING_LIB:-$(dirname "${BASH_SOURCE[0]}")/log-shipping.sh}"

METRICS_PUSH_PORT=3120
METRICS_QUERY_PORT=3121
METRICS_PVE_USER="${METRICS_PVE_USER:-pvecluster}"
METRICS_TARGET_ID="tappaas"
METRICS_SAMPLER_CONF="/etc/pve/priv/tappaas-metrics.conf"
METRICS_IDENTITY_CACHE="${METRICS_IDENTITY_CACHE:-/home/tappaas/.metrics-identity.json}"
METRICS_IDENTITY_FILE="/etc/alloy-identity/identity.alloy"
METRICS_INFLUX_MAP="/etc/loki-auth/influx-tokens.map"
METRICS_PROM_ENV="/etc/tappaas-metrics/prometheus.env"
METRICS_NODE_SSH="${METRICS_NODE_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new}"

_ms_site() { echo "$(_ls_config_dir)/site.json"; }
_ms_size() {
    local s; s="$(jq -r '.size // "medium"' "$(_ms_site)" 2>/dev/null || echo medium)"
    case "${s}" in small|medium|large) echo "${s}" ;; *) echo medium ;; esac
}

# The site's level: performance.level, else small → off, medium/large → basic.
# trace is never standing configuration (a timed raise only): read as service.
metrics_level() {
    local l; l="$(jq -r '.performance.level // empty' "$(_ms_site)" 2>/dev/null || true)"
    case "${l}" in
        off|basic|service) echo "${l}" ;;
        trace) echo service ;;
        "") [[ "$(_ms_size)" == small ]] && echo off || echo basic ;;
        *) echo "metrics: site.json performance.level '${l}' is not off, basic or service; using the default" >&2
           [[ "$(_ms_size)" == small ]] && echo off || echo basic ;;
    esac
}

metrics_retention_days() {
    local d; d="$(jq -r '.performance.retentionDays // empty' "$(_ms_site)" 2>/dev/null || true)"
    if [[ "${d}" =~ ^[0-9]+$ && "${d}" -ge 1 && "${d}" -le 365 ]]; then echo "${d}"; return; fi
    case "$(_ms_size)" in small) echo 7 ;; large) echo 30 ;; *) echo 15 ;; esac
}

metrics_wanted() {
    [[ -f "$(_ls_config_dir)/logging.json" ]] || return 1
    [[ "$(metrics_level)" != off ]]
}

metrics_push_url()  { echo "https://${LOG_SHIPPING_HOST}:${METRICS_PUSH_PORT}"; }
metrics_query_url() { echo "https://${LOG_SHIPPING_HOST}:${METRICS_QUERY_PORT}"; }
metrics_curl_admin() { log_shipping_curl_admin "$@"; }

# The PBS instance: the module whose source is foundation/backup.
_ms_pbs_instance() {
    local f src
    for f in "$(_ls_config_dir)"/*.json; do
        src="$(jq -r '(.moduleSource // .location // "") | sub("/+$"; "") | split("/") | last' "${f}" 2>/dev/null || true)"
        if [[ "${src}" == backup ]] && [[ "$(jq -r '.kind // ""' "${f}" 2>/dev/null)" == application ]]; then
            basename "${f}" .json; return 0
        fi
    done
    return 1
}

# ── identity ─────────────────────────────────────────────────────────

# {"cluster": "<user>", "nodes": [names], "hosts": {name: id}, "guests":
#  {vmid: id}, "ids": {id: {name, ns}}}, from the CMDB's nodes (machine, vm,
# lxc) and the PBS app, the namespace from each instance's config. Cached:
# when the CMDB does not answer, the last map stands.
metrics_identity_json() {
    local cfg q pbs app defenv out
    cfg="$(_ls_config_dir)"
    defenv="$(jq -r '.defaultEnvironment // "mgmt"' "$(_ms_site)" 2>/dev/null || echo mgmt)"
    if q="$(cmdb query node --json 2>/dev/null)" && jq -e 'type == "array"' <<<"${q}" >/dev/null 2>&1; then
        app='[]'
        if pbs="$(_ms_pbs_instance)"; then
            app="$(cmdb show "${pbs}" --class app --json 2>/dev/null | jq -c '[{id, class, name}]' 2>/dev/null || echo '[]')"
        fi
        # Each object's namespace: its instance's environment, else the site's default.
        local envs='{}' n e
        while IFS= read -r n; do
            [[ -f "${cfg}/${n}.json" ]] || continue
            e="$(jq -r '.environment // empty' "${cfg}/${n}.json" 2>/dev/null || true)"
            [[ -n "${e}" ]] && envs="$(jq -c --arg n "${n}" --arg e "${e}" '. + {($n): $e}' <<<"${envs}")"
        done < <(jq -r '.[] | select(.class == "machine" or .class == "vm" or .class == "lxc") | .name' <<<"${q}"; jq -r '.[].name' <<<"${app}")
        out="$(jq -c --argjson app "${app}" --argjson envs "${envs}" --arg def "${defenv}" --arg cl "${METRICS_PVE_USER}" '
            ([.[] | select(.class == "machine" or .class == "vm" or .class == "lxc")] + $app) as $all
            | {cluster: $cl,
               nodes:  [$all[] | select(.class == "machine") | .name] | sort,
               hosts:  ([$all[] | {(.name): .id}] | add // {}),
               guests: ([$all[] | select((.class == "vm" or .class == "lxc") and ((.attributes.vmid // null) != null))
                         | {(.attributes.vmid | tostring): .id}] | add // {}),
               ids:    ([$all[] | {(.id): {name: .name, ns: ($envs[.name] // $def)}}] | add // {})}' <<<"${q}")" || out=""
        if [[ -n "${out}" ]]; then
            (umask 077; printf '%s\n' "${out}" > "${METRICS_IDENTITY_CACHE}.tmp" && mv "${METRICS_IDENTITY_CACHE}.tmp" "${METRICS_IDENTITY_CACHE}") 2>/dev/null || true
            printf '%s\n' "${out}"; return 0
        fi
    fi
    if [[ -s "${METRICS_IDENTITY_CACHE}" ]]; then
        echo "metrics: the CMDB did not answer — using the identities known from the last time" >&2
        cat "${METRICS_IDENTITY_CACHE}"; return 0
    fi
    echo "metrics: the CMDB did not answer and no identities are cached — series carry their host only" >&2
    jq -nc --arg cl "${METRICS_PVE_USER}" '{cluster: $cl, nodes: [], hosts: {}, guests: {}, ids: {}}'
}

_ms_name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; }
_ms_id_ok()   { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

# Five rules: the CI's identity, when the series' source_labels match regex.
_ms_stamp_rules() {
    local src="$1" re="$2" id="$3" name="$4" ns="$5" k v
    for k in tappaas_ci_id service_instance_id service_name service_namespace deployment_environment_name; do
        case "${k}" in
            tappaas_ci_id|service_instance_id) v="${id}" ;;
            service_name) v="${name}" ;;
            *) v="${ns}" ;;
        esac
        printf '    rule {\n      source_labels = [%s]\n      separator     = ";"\n      regex         = "%s"\n      target_label  = "%s"\n      replacement   = "%s"\n    }\n' \
            "${src}" "${re}" "${k}" "${v}"
    done
}

# The Alloy module the logging VM imports (import.file): declare "stamp" with
# a prometheus.relabel that sets every series' identity. Pure: the map in, the
# file out. Entries that are not plain names, ids or vmids are left out.
render_metrics_identity() {
    local map="$1" cl nodes="" n id name ns vmid
    cl="$(jq -r '.cluster // ""' <<<"${map}")"
    _ms_name_ok "${cl}" || cl="pvecluster"
    while IFS= read -r n; do
        _ms_name_ok "${n}" || continue
        nodes+="${nodes:+|}${n}"
    done < <(jq -r '.nodes[]?' <<<"${map}")
    cat <<EOF
// GENERATED on the mothership (lib/metrics-shipping.sh). Do not edit here:
// rewritten on every logging update and metrics reconcile.
declare "stamp" {
  argument "forward_to" { }

  prometheus.relabel "stamp" {
    forward_to = argument.forward_to.value

    // What a sender says about identity never counts.
    rule {
      action = "labeldrop"
      regex  = "tappaas_ci_id|service_instance_id|service_name|service_namespace|deployment_environment_name|instance|tappaas_node"
    }
EOF
    if [[ -n "${nodes}" ]]; then
        cat <<EOF

    // The cluster's credential speaks for its nodes: host = the node it names.
    rule {
      source_labels = ["host", "node"]
      separator     = ";"
      regex         = "${cl};(${nodes})"
      target_label  = "host"
      replacement   = "\$1"
    }
EOF
    fi
    cat <<EOF
    rule {
      source_labels = ["host"]
      regex         = "${cl}"
      action        = "drop"
    }
EOF
    if [[ -n "${nodes}" ]]; then
        cat <<EOF

    // Only a node may speak about guests (vmid).
    rule {
      source_labels = ["host"]
      regex         = "${nodes}"
      target_label  = "tappaas_node"
      replacement   = "1"
    }
EOF
    fi
    cat <<'EOF'
    rule {
      source_labels = ["tappaas_node", "vmid"]
      separator     = ";"
      regex         = ";.+"
      action        = "drop"
    }

    // Each host as itself.
EOF
    while IFS=$'\t' read -r n id; do
        _ms_name_ok "${n}" && _ms_id_ok "${id}" || continue
        ns="$(jq -r --arg id "${id}" '.ids[$id].ns // ""' <<<"${map}")"
        _ms_name_ok "${ns}" || ns=""
        _ms_stamp_rules '"host"' "${n}" "${id}" "${n}" "${ns}"
    done < <(jq -r '.hosts // {} | to_entries[] | [.key, .value] | @tsv' <<<"${map}")
    echo
    echo "    // A node's series about a guest are the guest's."
    while IFS=$'\t' read -r vmid id; do
        [[ "${vmid}" =~ ^[0-9]+$ ]] && _ms_id_ok "${id}" || continue
        name="$(jq -r --arg id "${id}" '.ids[$id].name // ""' <<<"${map}")"
        ns="$(jq -r --arg id "${id}" '.ids[$id].ns // ""' <<<"${map}")"
        _ms_name_ok "${name}" || continue
        _ms_name_ok "${ns}" || ns=""
        _ms_stamp_rules '"tappaas_node", "vmid"' "1;${vmid}" "${id}" "${name}" "${ns}"
    done < <(jq -r '.guests // {} | to_entries[] | [.key, .value] | @tsv' <<<"${map}")
    cat <<'EOF'

    rule {
      action = "labeldrop"
      regex  = "tappaas_node"
    }
  }

  export "receiver" {
    value = prometheus.relabel.stamp.receiver
  }
}
EOF
}

# nginx map lines for InfluxDB senders (PBS): "Token <user>:<secret>" → user.
# The token is the secret in clear, so the file is root:nginx 0640 like the
# htpasswd files beside it; only the PBS instance pushes this way.
_ms_influx_map() {
    local pbs pw
    pbs="$(_ms_pbs_instance)" || return 0
    _ms_name_ok "${pbs}" || return 0
    pw="$(log_shipping_password "${pbs}")" || return 1
    printf '"Token %s:%s" "%s";\n' "${pbs}" "${pw}" "${pbs}"
}

# Put one file on the logging VM when it differs. Echoes "changed".
_ms_put() {
    local vm="$1" path="$2" mode="$3" owner="$4" content="$5" want have
    want="$(printf '%s' "${content}" | sha256sum | cut -d' ' -f1)"
    have="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" "sudo sha256sum ${path} 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"
    [[ "${have}" == "${want}" ]] && return 0
    printf '%s' "${content}" | ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" \
        "sudo install -d -m 0755 \$(dirname ${path}) && sudo install -m ${mode} -o ${owner%%:*} -g ${owner##*:} /dev/stdin ${path}" || return 1
    echo changed
}

# The identity module, the InfluxDB tokens and the store's retention onto the
# logging VM; nginx reloads when the tokens changed, Prometheus restarts when
# the retention did; Alloy re-reads the module by itself. The cluster's and the
# PBS instance's credentials are made here (log-shipping's store), so the
# htpasswd sync after it carries them.
metrics_sync_logging() {
    local vm map ident tokens c="" retention
    [[ -f "$(_ls_config_dir)/logging.json" ]] || return 0
    vm="$(_ls_logging_vm)"
    log_shipping_password "${METRICS_PVE_USER}" >/dev/null || return 1
    if _ms_pbs_instance >/dev/null; then log_shipping_password "$(_ms_pbs_instance)" >/dev/null || return 1; fi
    log_shipping_sync_logging || return 1
    map="$(metrics_identity_json)"
    ident="$(render_metrics_identity "${map}")" || return 1
    _ms_put "${vm}" "${METRICS_IDENTITY_FILE}" 0644 root:root "${ident}" >/dev/null || return 1
    tokens="$(_ms_influx_map)" || return 1
    c="$(_ms_put "${vm}" "${METRICS_INFLUX_MAP}" 0640 root:nginx "${tokens}")" || return 1
    if [[ -n "${c}" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" "sudo systemctl reload-or-restart nginx" || return 1
    fi
    retention="$(metrics_retention_days)"
    c="$(_ms_put "${vm}" "${METRICS_PROM_ENV}" 0644 root:root "PROM_RETENTION=${retention}d
")" || return 1
    if [[ -n "${c}" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" "sudo systemctl try-restart prometheus" || return 1
    fi
    echo "metrics: $(jq -r '(.hosts|length|tostring) + " hosts and " + (.guests|length|tostring) + " guests with an identity"' <<<"${map}"), retention ${retention} days"
}

# ── Proxmox: the cluster's external metric server ─────────────────────

_ms_basic() { printf '%s:%s' "$1" "$2" | base64 -w0; }
# The otel-headers value: base64 of {"Authorization":"Basic …"}.
_ms_pve_headers() {
    local pw; pw="$(log_shipping_password "${METRICS_PVE_USER}")" || return 1
    printf '{"Authorization":"Basic %s"}' "$(_ms_basic "${METRICS_PVE_USER}" "${pw}")" | base64 -w0
}
_ms_sampler_conf() {
    local pw; pw="$(log_shipping_password "${METRICS_PVE_USER}")" || return 1
    printf '# TAPPaaS-managed (lib/metrics-shipping.sh): where the guest memory sampler pushes metrics.\nurl=%s/v1/metrics\nauth=Basic %s\n' \
        "$(metrics_push_url)" "$(_ms_basic "${METRICS_PVE_USER}" "${pw}")"
}

_ms_first_node() {
    local n
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        # shellcheck disable=SC2086
        ${METRICS_NODE_SSH} -n "root@${n}.mgmt.internal" true 2>/dev/null && { echo "${n}"; return 0; }
    done < <(get_all_node_hostnames 2>/dev/null)
    return 1
}

metrics_pve_state() {
    local node have want_h want_s sum
    node="$(_ms_first_node)" || { echo unknown; return 0; }
    # shellcheck disable=SC2086
    have="$(${METRICS_NODE_SSH} -n "root@${node}.mgmt.internal" \
        "pvesh get /cluster/metrics/server/${METRICS_TARGET_ID} --output-format json 2>/dev/null; echo; sha256sum ${METRICS_SAMPLER_CONF} 2>/dev/null | cut -d' ' -f1" 2>/dev/null)" \
        || { echo unknown; return 0; }
    sum="$(tail -1 <<<"${have}")"; have="$(head -1 <<<"${have}")"
    if ! metrics_wanted; then
        if jq -e '.type' <<<"${have}" >/dev/null 2>&1 || [[ -n "${sum}" ]]; then echo unwanted; else echo absent; fi
        return 0
    fi
    jq -e '.type' <<<"${have}" >/dev/null 2>&1 || { echo missing; return 0; }
    want_h="$(_ms_pve_headers)" || { echo unknown; return 0; }
    want_s="$(_ms_sampler_conf | sha256sum | cut -d' ' -f1)"
    if jq -e --arg s "${LOG_SHIPPING_HOST}" --argjson p "${METRICS_PUSH_PORT}" --arg h "${want_h}" '
            .type == "opentelemetry" and .server == $s and (.port|tonumber) == $p
            and (.["otel-headers"] // "") == $h and ((.disable // 0)|tostring) != "1"
            and (.["otel-protocol"] // "https") == "https"' <<<"${have}" >/dev/null 2>&1 \
       && [[ "${sum}" == "${want_s}" ]]; then
        echo in-sync
    else
        echo stale
    fi
}

apply_metrics_pve() {
    local node h
    metrics_wanted || { remove_metrics_pve; return; }
    node="$(_ms_first_node)" || { echo "no cluster node answers" >&2; return 1; }
    h="$(_ms_pve_headers)" || return 1
    # shellcheck disable=SC2086
    _ms_sampler_conf | ${METRICS_NODE_SSH} "root@${node}.mgmt.internal" "
        set -e
        t=\$(mktemp); cat > \"\$t\"
        cmp -s \"\$t\" ${METRICS_SAMPLER_CONF} || install -m 0600 \"\$t\" ${METRICS_SAMPLER_CONF}
        rm -f \"\$t\"
        if pvesh get /cluster/metrics/server/${METRICS_TARGET_ID} >/dev/null 2>&1; then
            pvesh set /cluster/metrics/server/${METRICS_TARGET_ID} --server ${LOG_SHIPPING_HOST} --port ${METRICS_PUSH_PORT} \
                --otel-protocol https --otel-path /v1/metrics --otel-headers '${h}' --otel-verify-ssl 1 --disable 0
        else
            pvesh create /cluster/metrics/server/${METRICS_TARGET_ID} --type opentelemetry --server ${LOG_SHIPPING_HOST} \
                --port ${METRICS_PUSH_PORT} --otel-protocol https --otel-path /v1/metrics --otel-headers '${h}' --otel-verify-ssl 1
        fi" >/dev/null || return 1
    echo "Proxmox pushes metrics to ${LOG_SHIPPING_HOST}:${METRICS_PUSH_PORT} (OpenTelemetry)"
}

remove_metrics_pve() {
    local node
    node="$(_ms_first_node)" || { echo "no cluster node answers" >&2; return 1; }
    # shellcheck disable=SC2086
    ${METRICS_NODE_SSH} -n "root@${node}.mgmt.internal" "
        rm -f ${METRICS_SAMPLER_CONF}
        if pvesh get /cluster/metrics/server/${METRICS_TARGET_ID} >/dev/null 2>&1; then
            pvesh delete /cluster/metrics/server/${METRICS_TARGET_ID}
        fi" >/dev/null || return 1
    echo "Proxmox pushes no metrics"
}

# ── PBS: its InfluxDB HTTP metric server ──────────────────────────────

# PBS's API through its own CLI, on the host it runs on (the instance's node).
_ms_pbs_host() {
    local pbs n
    pbs="$(_ms_pbs_instance)" || return 1
    n="$(jq -r '.node // empty' "$(_ls_config_dir)/${pbs}.json" 2>/dev/null)"
    _ms_name_ok "${n}" || return 1
    echo "${n}.mgmt.internal"
}

metrics_pbs_state() {
    local host have pbs pw
    host="$(_ms_pbs_host)" || { echo absent; return 0; }
    # shellcheck disable=SC2086
    have="$(${METRICS_NODE_SSH} -n "root@${host}" \
        "proxmox-backup-debug api get /config/metrics/influxdb-http/${METRICS_TARGET_ID} --output-format json 2>/dev/null" 2>/dev/null || true)"
    if ! metrics_wanted; then
        jq -e '.url' <<<"${have}" >/dev/null 2>&1 && echo unwanted || echo absent
        return 0
    fi
    jq -e '.url' <<<"${have}" >/dev/null 2>&1 || { echo missing; return 0; }
    pbs="$(_ms_pbs_instance)"; pw="$(log_shipping_password "${pbs}")" || { echo unknown; return 0; }
    # PBS does not hand its token back; the url and enable decide, and the token
    # is set again on every apply.
    if jq -e --arg u "$(metrics_push_url)" '.url == $u and ((.enable // true) == true)' <<<"${have}" >/dev/null 2>&1; then
        echo in-sync
    else
        echo stale
    fi
}

apply_metrics_pbs() {
    local host pbs pw
    metrics_wanted || { remove_metrics_pbs; return; }
    host="$(_ms_pbs_host)" || { echo "no PBS instance on this site" >&2; return 0; }
    pbs="$(_ms_pbs_instance)"; pw="$(log_shipping_password "${pbs}")" || return 1
    # shellcheck disable=SC2086
    ${METRICS_NODE_SSH} "root@${host}" "
        set -e
        tok=\$(cat)
        if proxmox-backup-debug api get /config/metrics/influxdb-http/${METRICS_TARGET_ID} >/dev/null 2>&1; then
            proxmox-backup-debug api set /config/metrics/influxdb-http/${METRICS_TARGET_ID} --url '$(metrics_push_url)' \
                --token \"\$tok\" --enable true --verify-tls true >/dev/null
        else
            proxmox-backup-debug api create /config/metrics/influxdb-http --name ${METRICS_TARGET_ID} --url '$(metrics_push_url)' \
                --token \"\$tok\" --enable true --verify-tls true --comment 'TAPPaaS metrics store' >/dev/null
        fi" <<<"${pbs}:${pw}" || return 1
    echo "PBS pushes metrics to ${LOG_SHIPPING_HOST}:${METRICS_PUSH_PORT} (InfluxDB line protocol)"
}

remove_metrics_pbs() {
    local host
    host="$(_ms_pbs_host)" || return 0
    # shellcheck disable=SC2086
    ${METRICS_NODE_SSH} -n "root@${host}" "
        if proxmox-backup-debug api get /config/metrics/influxdb-http/${METRICS_TARGET_ID} >/dev/null 2>&1; then
            proxmox-backup-debug api delete /config/metrics/influxdb-http/${METRICS_TARGET_ID} >/dev/null
        fi" || return 1
    echo "PBS pushes no metrics"
}


# ── the cascade (ADR-046 D3) ─────────────────────────────────────────
# site → environment → module instance, most specific wins, then an active
# timed raise (health-manager perf). A record that says trace is read as
# service: trace exists only as a raise.

METRICS_RAISES_FILE_NAME="performance-raises.json"
_ms_raises_file() { echo "$(_ls_config_dir)/${METRICS_RAISES_FILE_NAME}"; }

_ms_level_ok() { case "$1" in off|basic|service) return 0 ;; *) return 1 ;; esac; }
_ms_standing() { local l="$1"; [[ "${l}" == trace ]] && l=service; _ms_level_ok "${l}" && echo "${l}"; }
_ms_res_ok() { case "$1" in normal|fine) return 0 ;; *) return 1 ;; esac; }

# A record's performance.<key>, flat or nested ("performance.level" in a
# config written by hand is read too).
_ms_rec() { jq -r --arg k "$2" '(.performance[$k] // .["performance." + $k]) // empty' "$1" 2>/dev/null || true; }

# The active raise for a module instance, as JSON, or nothing.
metrics_raise_of() {
    local module="$1" f now
    f="$(_ms_raises_file)"; [[ -s "${f}" ]] || return 0
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -c --arg m "${module}" --arg now "${now}" \
        '[.investigations[]? | select(.module == $m and (.ended // null) == null and .until > $now)] | last // empty' "${f}" 2>/dev/null || true
}

# metrics_effective <module> → {"level","resolution","from","source","raise"}:
# from/source the standing level and where it comes from (site, environment
# <env>, module), raise the active raise or null.
metrics_effective() {
    local module="$1" cfg env l r src rl rr site raise
    cfg="$(_ls_config_dir)"
    site="$(_ms_site)"
    l="$(_ms_standing "$(_ms_rec "${site}" level)")"; src="site"
    [[ -n "${l}" ]] || { l="$(metrics_level 2>/dev/null)"; src="site (by size)"; }
    r="$(_ms_rec "${site}" resolution)"; _ms_res_ok "${r}" || r=normal
    env="$(jq -r '.environment // empty' "${cfg}/${module}.json" 2>/dev/null || true)"
    if [[ -n "${env}" && -f "${cfg}/environments/${env}.json" ]]; then
        rl="$(_ms_standing "$(_ms_rec "${cfg}/environments/${env}.json" level)")"
        [[ -n "${rl}" ]] && { l="${rl}"; src="environment ${env}"; }
        rr="$(_ms_rec "${cfg}/environments/${env}.json" resolution)"; _ms_res_ok "${rr}" && r="${rr}"
    fi
    if [[ -f "${cfg}/${module}.json" ]]; then
        rl="$(_ms_standing "$(_ms_rec "${cfg}/${module}.json" level)")"
        [[ -n "${rl}" ]] && { l="${rl}"; src="module"; }
        rr="$(_ms_rec "${cfg}/${module}.json" resolution)"; _ms_res_ok "${rr}" && r="${rr}"
    fi
    raise="$(metrics_raise_of "${module}")"
    jq -nc --arg l "${l}" --arg r "${r}" --arg src "${src}" --argjson raise "${raise:-null}" '
        {from: $l, source: $src, raise: $raise,
         level: (if $raise then $raise.level else $l end),
         resolution: (if $raise and ($raise.resolution // "") == "fine" then "fine" else $r end)}'
}

# ── the guest's own view (ADR-046 D2, P2) ────────────────────────────
# Alloy's prometheus.exporter.unix, a keep-list per class and level, pushed as
# OTLP with the guest's push credential to the store. Rendered here, written to
# the guest's runtime file (LOG_SHIPPING_PERF_FILE), which its Alloy re-reads.

# The keep-lists (metric names; RE2, anchored by Alloy).
METRICS_KEEP_BASIC='node_cpu_seconds_total|node_load(1|5|15)|node_memory_(MemTotal|MemAvailable|MemFree|Cached|Buffers|SwapTotal|SwapFree)_bytes|node_pressure_(cpu|memory|io)_(waiting|stalled)_seconds_total|node_filesystem_(avail|size)_bytes|node_filesystem_files(_free)?|node_disk_(read|written)_bytes_total|node_disk_(reads|writes)_completed_total|node_disk_io_time_seconds_total|node_network_(receive|transmit)_(bytes|errs|drop)_total|node_boot_time_seconds|node_procs_(running|blocked)|node_context_switches_total'
METRICS_KEEP_SERVICE='node_netstat_Tcp_(CurrEstab|RetransSegs|InSegs|OutSegs|ActiveOpens|PassiveOpens)|node_sockstat_(TCP_inuse|TCP_tw|sockets_used)|node_vmstat_(pgmajfault|oom_kill)|node_filefd_allocated'
# A container's /proc pressure and boot time are its node's: not its own.
METRICS_DROP_LXC='node_pressure_.*|node_boot_time_seconds'

# guest | lxc
metrics_class_of() {
    local cfg; cfg="$(_ls_config_dir)/$1.json"
    if jq -e '.kind == "lxc" or ((.dependsOn // []) | index("cluster:lxc") != null)' "${cfg}" >/dev/null 2>&1; then echo lxc; else echo guest; fi
}

# render_metrics_alloy <host> <level> <resolution> <class> — the runtime file.
render_metrics_alloy() {
    local host="$1" level="$2" res="$3" class="${4:-guest}" keep interval=60s collectors
    _ms_name_ok "${host}" || { echo "render_metrics_alloy: bad host '${host}'" >&2; return 1; }
    [[ "${level}" == trace ]] && level=service
    _ms_level_ok "${level}" || { echo "render_metrics_alloy: bad level '${level}'" >&2; return 1; }
    echo "// GENERATED on the mothership (lib/metrics-shipping.sh): ${host} at level ${level}, resolution ${res}."
    echo "// Rewritten on every level change; Alloy re-reads it. Do not edit here."
    if [[ "${level}" == off ]]; then
        echo "${LOG_SHIPPING_PERF_DEFAULT}"
        return 0
    fi
    keep="${METRICS_KEEP_BASIC}"
    collectors='"cpu", "loadavg", "meminfo", "pressure", "filesystem", "diskstats", "netdev", "stat"'
    if [[ "${level}" == service ]]; then
        keep+="|${METRICS_KEEP_SERVICE}"
        collectors+=', "netstat", "sockstat", "vmstat", "filefd"'
    fi
    [[ "${res}" == fine ]] && interval=15s
    cat <<EOF
declare "pipeline" {
  prometheus.exporter.unix "host" {
    set_collectors = [${collectors}]
    filesystem {
      fs_types_exclude     = "^(tmpfs|devtmpfs|overlay|squashfs|nsfs|proc|sysfs|cgroup2?|autofs|ramfs|fuse\\\\..*|efivarfs|bpf|tracefs|debugfs|securityfs|pstore|configfs|binfmt_misc|mqueue|hugetlbfs)\$"
      mount_points_exclude = "^/(dev|proc|run|sys|nix/store)(\$|/)"
    }
    netdev {
      device_exclude = "^(lo|veth.*|docker.*|br-.*|cni.*|podman.*|virbr.*)\$"
    }
  }

  prometheus.scrape "host" {
    targets         = prometheus.exporter.unix.host.targets
    scrape_interval = "${interval}"
    job_name        = "node"
    forward_to      = [prometheus.relabel.keep.receiver]
  }

  // The keep-list of the class and level: names only, no label carrying input.
  prometheus.relabel "keep" {
    forward_to = [otelcol.receiver.prometheus.perf.receiver]
    rule {
      source_labels = ["__name__"]
      regex         = "${keep}"
      action        = "keep"
    }
EOF
    if [[ "${class}" == lxc ]]; then
        cat <<EOF
    rule {
      source_labels = ["__name__"]
      regex         = "${METRICS_DROP_LXC}"
      action        = "drop"
    }
EOF
    fi
    cat <<EOF
  }

  otelcol.receiver.prometheus "perf" {
    output {
      metrics = [otelcol.exporter.otlphttp.perf.input]
    }
  }

  local.file "push_secret" {
    filename  = sys.env("CREDENTIALS_DIRECTORY") + "/loki-push"
    is_secret = true
  }

  otelcol.auth.basic "perf" {
    username = "${host}"
    password = local.file.push_secret.content
  }

  // To the store's push receiver, as this guest (its logs credential): the
  // store sets the series' identity from it.
  otelcol.exporter.otlphttp "perf" {
    client {
      endpoint = "$(metrics_push_url)"
      auth     = otelcol.auth.basic.perf.handler
    }
  }
}
EOF
}

# Where a guest is reached as root to write its runtime file: ssh:<host> for a
# VM (NixOS or Debian), lxc:<node>:<vmid> for a container. rc 1 when it ships
# no logs (no Alloy) or cannot be reached.
_ms_guest_transport() {
    local module="$1" cfg vmname zone
    log_shipping_wanted "${module}" || return 1
    # A syslog sender (the firewall, a node) runs no Alloy of TAPPaaS's.
    [[ -z "$(log_shipping_syslog_kind "${module}")" ]] || return 1
    cfg="$(_ls_config_dir)/${module}.json"
    if [[ "$(metrics_class_of "${module}")" == lxc ]]; then
        log_shipping_transport "${module}"; return
    fi
    vmname="$(jq -r '.vmname // empty' "${cfg}" 2>/dev/null)"
    zone="$(jq -r '(.zone0 // (.config? // {} | to_entries[]?.value.zone0?)) // ""' "${cfg}" 2>/dev/null | head -1)"
    _ms_name_ok "${vmname:-${module}}" || return 1
    printf 'ssh:%s.%s.internal\n' "${vmname:-${module}}" "${zone:-mgmt}"
}

# The file a guest should have now, from the cascade and any raise.
metrics_guest_render() {
    local module="$1" eff host lvl
    eff="$(metrics_effective "${module}")"
    host="$(jq -r '.vmname // empty' "$(_ls_config_dir)/${module}.json" 2>/dev/null)"
    lvl="$(jq -r .level <<<"${eff}")"
    # The site's level decides only the site's default (and the Proxmox and PBS
    # targets); a module or environment that sets its own collects regardless.
    [[ -f "$(_ls_config_dir)/logging.json" ]] || lvl=off
    render_metrics_alloy "${host:-${module}}" "${lvl}" "$(jq -r .resolution <<<"${eff}")" "$(metrics_class_of "${module}")"
}

# apply_metrics_guest <module> — write the runtime file when it differs and
# have Alloy re-read it. Prints "changed" or "unchanged" and the level.
apply_metrics_guest() {
    local module="$1" t file eff
    t="$(_ms_guest_transport "${module}")" || { echo "${module} ships no logs here, so it has no Alloy to collect its own numbers"; return 0; }
    file="$(metrics_guest_render "${module}")" || return 1
    eff="$(metrics_effective "${module}")"
    _ls_guest_root "${t}" <<EOF || return 1
set -eu
f=${LOG_SHIPPING_PERF_FILE}
install -d -m 0755 \$(dirname "\$f")
t=\$(mktemp)
printf '%s' '$(printf '%s\n' "${file}" | base64 -w0)' | base64 -d > "\$t"
if [ -f "\$f" ] && cmp -s "\$t" "\$f"; then rm -f "\$t"; echo unchanged; exit 0; fi
install -m 0644 "\$t" "\$f"; rm -f "\$t"
systemctl reload alloy 2>/dev/null || systemctl try-restart alloy
echo changed
EOF
    echo "${module}: level $(jq -r .level <<<"${eff}") ($(jq -r 'if .raise then "raised until " + .raise.until else "from " + .source end' <<<"${eff}")), every $(jq -r 'if .resolution == "fine" then "15" else "60" end' <<<"${eff}") s"
}

# ── purge (ADR-046 D3) ───────────────────────────────────────────────
# metrics_purge <ci-id> — the CI's series out of both stores (Prometheus'
# delete_series, then clean_tombstones). Prints what each store said.
metrics_purge() {
    local id="$1" q code rc=0 base
    _ms_id_ok "${id}" || { echo "metrics_purge: '${id}' is not a CI id" >&2; return 1; }
    q="$(metrics_query_url)"
    for base in "${q}" "${q}/trends"; do
        code="$(metrics_curl_admin -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST -G "${base}/api/v1/admin/tsdb/delete_series" \
                --data-urlencode "match[]={tappaas_ci_id=\"${id}\"}" 2>/dev/null || true)"
        if [[ "${code}" == 204 ]]; then
            metrics_curl_admin -s -o /dev/null --max-time 120 -X POST "${base}/api/v1/admin/tsdb/clean_tombstones" 2>/dev/null || true
        else
            echo "${base}: delete_series answered ${code:-nothing}" >&2; rc=1
        fi
    done
    return "${rc}"
}

# ── sizing (ADR-044, ADR-046 D3) ─────────────────────────────────────
# Per-object cost of a level, from what hrossen measured (P1, P2): series, MB
# of disk a day, MB of RAM in the store. A guest's own view comes on top of its
# outside view; fine resolution is four times the samples (disk), not series.
#   metrics_cost → {"series","diskMBPerDay","ramMB"} for the whole site now
metrics_cost() {
    local cfg n_nodes=0 n_guests=0 own_series=0 own_disk=0 m eff lvl res f
    cfg="$(_ls_config_dir)"
    [[ "$(metrics_level)" == off ]] && [[ -z "$(jq -r '.performance.level // empty' "${cfg}"/environments/*.json "${cfg}"/*.json 2>/dev/null | grep -v '^off$')" ]] \
        && { jq -nc '{series: 0, diskMBPerDay: 0, ramMB: 0}'; return 0; }
    n_nodes="$(get_all_node_hostnames 2>/dev/null | grep -c . || true)"
    for f in "${cfg}"/*.json; do
        m="$(basename "${f}" .json)"
        jq -e '.kind == "vm" or .kind == "lxc"' "${f}" >/dev/null 2>&1 || continue
        n_guests=$((n_guests + 1))
        log_shipping_wanted "${m}" || continue
        eff="$(metrics_effective "${m}")"; lvl="$(jq -r .level <<<"${eff}")"; res="$(jq -r .resolution <<<"${eff}")"
        case "${lvl}" in basic) s=60 ;; service|trace) s=90 ;; *) s=0 ;; esac
        own_series=$((own_series + s))
        # 1.5 bytes a sample; 1440 samples a day at a minute, 5760 at 15 s.
        if [[ "${res}" == fine ]]; then own_disk=$((own_disk + s * 5760 * 3 / 2)); else own_disk=$((own_disk + s * 1440 * 3 / 2)); fi
    done
    # Outside view, measured on hrossen: ~45 series a guest, ~200 a node
    # (NICs and storages), PVE every 10 s.
    jq -nc --argjson g "${n_guests}" --argjson n "${n_nodes}" --argjson os "${own_series}" --argjson od "${own_disk}" '
        ($g * 45 + $n * 200) as $outside
        | {series: ($outside + $os),
           diskMBPerDay: ((($outside * 8640 * 1.5) + $od) / 1048576 | . * 10 | round / 10),
           ramMB: (180 + (($outside + $os) / 1000 * 30) | round)}'
}

fi
