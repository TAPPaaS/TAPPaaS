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

fi
