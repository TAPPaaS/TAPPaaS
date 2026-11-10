#!/usr/bin/env bash
#
# service-metrics.sh — the `service` level of performance monitoring (ADR-046
# D2, D3, D5; plan step P3). Sourced by metrics-shipping.sh; sourceable only.
#
# What `service` adds to `basic`, and who collects it:
#   - the published services, the user's view: Caddy on the firewall counts
#     every request per published host (rate, 5xx, a latency histogram). The
#     firewall (OPNsense) runs no Alloy, so the controller — the mothership's
#     Alloy, which already reaches every plane — scrapes Caddy's metrics
#     listener on the firewall's mgmt address (a caddy.d file this library
#     converges) and pushes them as itself;
#   - black-box probes: the same Alloy probes each published service over
#     HTTPS once a minute from inside the site (response time, status, the
#     certificate's expiry);
#   - a module's own exporters, as it declares them under `performance`
#     (D5): its guest's Alloy scrapes them on the guest, keeping only the
#     metric names the declaration lists. The logging VM, whose Alloy is the
#     store's receiver and not a guest pipeline, scrapes its own exporters
#     from a module the mothership writes (self.alloy, as identity.alloy).
#
# Identity: the store stamps a series by the host that pushed it (P1). A
# series about a published service, pushed by the controller, carries the
# route's host in `tappaas_route`; the identity module the mothership renders
# gives such series the proxy-route CI's identity and `tappaas_module`, only
# when the controller sent them.
#
# Only active at `service`: a route is collected while its module is at
# service (or traced); a module's exporters while the module is.
#
# Functions:
#   service_metrics_level <module>    the module's effective level: P2's cascade
#                                     (metrics_effective) when present, else the
#                                     site's (metrics_level) — the one place to change
#   service_routes_json               [{host, id, module, ns}] of the published hosts
#   service_routes_wanted             those whose module is at service or traced
#   perf_declaration_of <module>      the module's `performance` block (D5), or {}
#   perf_keep_regex <globs...>        a keep-list's metric-name regex
#   render_service_blocks <module> <level>   Alloy components for the module's pipeline
#   render_route_identity <map>       the identity module's rules for routes
#   render_module_dashboard <module>  a Grafana dashboard from its declaration
#   render_self_alloy <level>         logging's own exporters, the Alloy module it imports
#   service_metrics_sync_logging      module dashboards and logging's own targets onto
#                                     the logging VM
#   caddy_metrics_state / apply_caddy_metrics / remove_caddy_metrics
#     the firewall's metrics listener; *_state prints in-sync | missing | stale |
#     unwanted | absent | unknown

if [[ -z "${_SERVICE_METRICS_LOADED:-}" ]]; then
_SERVICE_METRICS_LOADED=1

SERVICE_CONTROLLER="${SERVICE_CONTROLLER:-tappaas-cicd}"
SERVICE_FIREWALL="${SERVICE_FIREWALL:-firewall.mgmt.internal}"
SERVICE_FW_SSH="${SERVICE_FW_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=10}"
CADDY_METRICS_PORT=9180
CADDY_D="/usr/local/etc/caddy/caddy.d"
CADDY_METRICS_GLOBAL="${CADDY_D}/tappaas-metrics.global"
CADDY_METRICS_SITE="${CADDY_D}/tappaas-metrics.conf"
SERVICE_ROUTES_CACHE="${SERVICE_ROUTES_CACHE:-/home/tappaas/.metrics-routes.json}"
SERVICE_DASH_DIR="/var/lib/grafana-tappaas/dashboards"
SERVICE_SELF_FILE="/etc/alloy-identity/self.alloy"
SERVICE_PROBE_STATUS='[200, 201, 204, 301, 302, 303, 307, 308, 401, 403]'
# What a Caddy series keeps (#caddy_http_* with per_host); nothing that carries a path.
SERVICE_CADDY_KEEP='caddy_http_request_duration_seconds_(bucket|count|sum)'
SERVICE_PROBE_KEEP='probe_(success|duration_seconds|http_status_code|ssl_earliest_cert_expiry)'

_sm_cfg() { echo "$(_ls_config_dir)/$1.json"; }
_sm_rank() { case "$1" in off) echo 0 ;; basic) echo 1 ;; service) echo 2 ;; trace) echo 3 ;; *) echo 0 ;; esac; }
_sm_host_ok() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }
# A label value made safe for an Alloy component name.
_sm_ident() { printf '%s' "$1" | tr -c 'A-Za-z0-9_\n' '_'; }

# The one function P2 replaces: until the cascade exists, the site's level.
service_metrics_level() {
    if declare -F metrics_effective >/dev/null; then
        metrics_effective "$1" | jq -r '.level'
    else
        metrics_level
    fi
}

_sm_at_service() { (( $(_sm_rank "$(service_metrics_level "$1" 2>/dev/null)") >= 2 )); }

# The published hosts, from the CMDB's proxy-routes (one per host; a route
# with a path shares its host's series). The module comes from the
# description network:proxy writes ("TAPPaaS: <module>"), the namespace from
# the module's environment. Cached like the identities, for a CMDB that is down.
service_routes_json() {
    local q out cfg envs='{}' m e
    cfg="$(_ls_config_dir)"
    if q="$(cmdb query proxy-route --json 2>/dev/null)" && jq -e 'type == "array"' <<<"${q}" >/dev/null 2>&1; then
        while IFS= read -r m; do
            [[ -f "${cfg}/${m}.json" ]] || continue
            e="$(jq -r '.environment // empty' "${cfg}/${m}.json" 2>/dev/null || true)"
            [[ -n "${e}" ]] && envs="$(jq -c --arg m "${m}" --arg e "${e}" '. + {($m): $e}' <<<"${envs}")"
        done < <(jq -r '.[] | (.attributes.description // "") | capture("^TAPPaaS: (?<m>[a-z0-9-]+)")?.m' <<<"${q}" | sort -u)
        out="$(jq -c --argjson envs "${envs}" '
            [.[] | select((.ended // null) == null and ((.attributes.path // "") == ""))
             | {host: (.attributes.host // .name), id,
                module: ((.attributes.description // "") | capture("^TAPPaaS: (?<m>[a-z0-9-]+)")?.m // null)}
             | select(.module != null) | . + {ns: ($envs[.module] // "")}]
            | unique_by(.host) | sort_by(.host)' <<<"${q}")" || out=""
        if [[ -n "${out}" ]]; then
            (umask 077; printf '%s\n' "${out}" > "${SERVICE_ROUTES_CACHE}.tmp" && mv "${SERVICE_ROUTES_CACHE}.tmp" "${SERVICE_ROUTES_CACHE}") 2>/dev/null || true
            printf '%s\n' "${out}"; return 0
        fi
    fi
    if [[ -s "${SERVICE_ROUTES_CACHE}" ]]; then cat "${SERVICE_ROUTES_CACHE}"; return 0; fi
    echo '[]'
}

service_routes_wanted() {
    local all m keep='[]'
    all="$(service_routes_json)"
    while IFS= read -r m; do
        [[ -n "${m}" ]] || continue
        _sm_at_service "${m}" && keep="$(jq -c --arg m "${m}" '. + [$m]' <<<"${keep}")"
    done < <(jq -r '[.[].module] | unique[]' <<<"${all}")
    jq -c --argjson keep "${keep}" '[.[] | select(.module as $m | $keep | index($m))]' <<<"${all}"
}

# ── a module's declaration (D5) ─────────────────────────────────────────

# The module's `performance` block, as the module JSON declares it. A module
# from any source but official declares none (O8: module-manager refuses it
# at install; this keeps a hand-edited config from rendering anyway).
perf_declaration_of() {
    local f; f="$(_sm_cfg "$1")"
    [[ -f "${f}" ]] || { echo '{}'; return 0; }
    jq -c 'if ((.source // "official") == "official") then (.performance // {} | {exporters: (.exporters // []), traces: (.traces // null), thresholds: (.thresholds // [])}) else {} end' "${f}" 2>/dev/null || echo '{}'
}

# Metric-name globs (authentik_*_total) to one regex. Only names and `*`
# pass; anything else is dropped (the validator refuses it at install).
perf_keep_regex() {
    local g out=""
    for g in "$@"; do
        [[ "${g}" =~ ^[A-Za-z_:*][A-Za-z0-9_:*]*$ ]] || continue
        out+="${out:+|}${g//\*/.*}"
    done
    echo "${out}"
}

_sm_exporter_blocks() {
    local module="$1" level="$2" decl n i name port path elevel keep
    decl="$(perf_declaration_of "${module}")"
    n="$(jq '.exporters // [] | length' <<<"${decl}")"
    for (( i = 0; i < n; i++ )); do
        name="$(jq -r ".exporters[${i}].name // empty" <<<"${decl}")"
        port="$(jq -r ".exporters[${i}].port // empty" <<<"${decl}")"
        path="$(jq -r ".exporters[${i}].path // \"/metrics\"" <<<"${decl}")"
        elevel="$(jq -r ".exporters[${i}].level // \"service\"" <<<"${decl}")"
        [[ "${name}" =~ ^[a-z][a-z0-9-]*$ && "${port}" =~ ^[0-9]+$ && "${path}" =~ ^/[A-Za-z0-9/_.-]*$ ]] || continue
        (( $(_sm_rank "${level}") >= $(_sm_rank "${elevel}") )) || continue
        mapfile -t globs < <(jq -r ".exporters[${i}].keep // [] | .[]" <<<"${decl}")
        keep="$(perf_keep_regex "${globs[@]}")"
        [[ -n "${keep}" ]] || continue
        local id; id="$(_sm_ident "${name}")"
        cat <<EOF

  // ${module} declares the exporter ${name} (performance.exporters): kept names only.
  prometheus.scrape "exp_${id}" {
    targets         = [{"__address__" = "127.0.0.1:${port}", "__metrics_path__" = "${path}"}]
    job_name        = "${name}"
    scrape_interval = "60s"
    forward_to      = [prometheus.relabel.exp_${id}.receiver]
  }

  prometheus.relabel "exp_${id}" {
    forward_to = [otelcol.receiver.prometheus.perf.receiver]
    rule {
      source_labels = ["__name__"]
      regex         = "${keep}"
      action        = "keep"
    }
    rule {
      action = "labeldrop"
      regex  = "path|uri|url|user|username|query"
    }
  }
EOF
    done
}

# The controller's part: Caddy's per-host numbers and the probes, for the
# routes whose module is at service.
_sm_controller_blocks() {
    local routes hosts="" h n=0
    routes="$(service_routes_wanted)"
    while IFS= read -r h; do
        _sm_host_ok "${h}" || continue
        hosts+="${hosts:+|}${h//./\\\\.}"
        n=$((n + 1))
    done < <(jq -r '.[].host' <<<"${routes}")
    (( n > 0 )) || return 0
    cat <<EOF

  // Caddy on the firewall: requests per published host, for the ${n} route(s)
  // at level service. The host goes to tappaas_route (the store rewrites
  // \`host\` to the pusher); the status code is bucketed to its class.
  prometheus.scrape "caddy" {
    targets         = [{"__address__" = "${SERVICE_FIREWALL}:${CADDY_METRICS_PORT}"}]
    job_name        = "caddy"
    scrape_interval = "60s"
    forward_to      = [prometheus.relabel.caddy.receiver]
  }

  prometheus.relabel "caddy" {
    forward_to = [otelcol.receiver.prometheus.perf.receiver]
    rule {
      source_labels = ["__name__"]
      regex         = "${SERVICE_CADDY_KEEP}"
      action        = "keep"
    }
    rule {
      source_labels = ["host"]
      regex         = "${hosts}"
      action        = "keep"
    }
    rule {
      source_labels = ["host"]
      target_label  = "tappaas_route"
    }
    rule {
      source_labels = ["code"]
      regex         = "([1-5])..*"
      target_label  = "code"
      replacement   = "\${1}xx"
    }
    rule {
      action = "labeldrop"
      regex  = "host|handler|server|method|path|uri|instance"
    }
  }

  // Black-box: each route from inside the site, once a minute.
  prometheus.exporter.blackbox "routes" {
    config = "{modules: {https: {prober: http, timeout: 10s, http: {preferred_ip_protocol: ip4, valid_status_codes: ${SERVICE_PROBE_STATUS}, no_follow_redirects: true}}}}"
EOF
    while IFS= read -r h; do
        _sm_host_ok "${h}" || continue
        cat <<EOF
    target {
      name    = "$(_sm_ident "${h}")"
      address = "https://${h}/"
      module  = "https"
      labels  = {"tappaas_route" = "${h}"}
    }
EOF
    done < <(jq -r '.[].host' <<<"${routes}")
    cat <<EOF
  }

  prometheus.scrape "probes" {
    targets         = prometheus.exporter.blackbox.routes.targets
    job_name        = "probe"
    scrape_interval = "60s"
    forward_to      = [prometheus.relabel.probes.receiver]
  }

  prometheus.relabel "probes" {
    forward_to = [otelcol.receiver.prometheus.perf.receiver]
    rule {
      source_labels = ["__name__"]
      regex         = "${SERVICE_PROBE_KEEP}"
      action        = "keep"
    }
    rule {
      action = "labeldrop"
      regex  = "instance"
    }
  }
EOF
}

# What a module's pipeline adds at `service`: empty below it.
render_service_blocks() {
    local module="$1" level="$2"
    (( $(_sm_rank "${level}") >= 2 )) && _sm_exporter_blocks "${module}" "${level}"
    [[ "${module}" == "${SERVICE_CONTROLLER}" ]] && _sm_controller_blocks
    return 0
}

# ── identity ────────────────────────────────────────────────────────────

# Rules for the identity module (render_metrics_identity): a series the
# controller sent with tappaas_route = a published host is that route's.
render_route_identity() {
    local map="$1" ctl h id ns m
    ctl="$(jq -r '.controller // ""' <<<"${map}")"
    _ms_name_ok "${ctl}" || return 0
    echo
    echo "    // The controller's series about a published service are the route's."
    while IFS=$'\t' read -r h id ns m; do
        _sm_host_ok "${h}" && _ms_id_ok "${id}" || continue
        _ms_name_ok "${ns}" || ns=""
        _ms_name_ok "${m}" || continue
        _ms_stamp_rules '"host", "tappaas_route"' "${ctl};${h//./\\\\.}" "${id}" "${h}" "${ns}"
        printf '    rule {\n      source_labels = ["host", "tappaas_route"]\n      separator     = ";"\n      regex         = "%s"\n      target_label  = "tappaas_module"\n      replacement   = "%s"\n    }\n' "${ctl};${h//./\\\\.}" "${m}"
    done < <(jq -r '.routes // [] | .[] | [.host, .id, (.ns // ""), (.module // "")] | @tsv' <<<"${map}")
    cat <<'EOF'
    rule {
      action = "labeldrop"
      regex  = "tappaas_route"
    }
EOF
}

# ── dashboards and the logging VM's own exporters ───────────────────────

# A dashboard from a module's declaration: one panel per kept name pattern,
# for the CI chosen in its variable (the console links with var-ci=<id>).
render_module_dashboard() {
    local module="$1" decl
    decl="$(perf_declaration_of "${module}")"
    jq -n --arg m "${module}" --argjson d "${decl}" '
      def rx: gsub("\\*"; ".*");
      [($d.exporters // [])[] | select((.port | type) == "number" and ((.name // "") | test("^[a-z][a-z0-9-]*$")))
       | . as $e | ($e.keep // [])[] | select(test("^[A-Za-z_:*][A-Za-z0-9_:*]*$")) | {e: $e.name, g: .}] as $rows
      | {uid: ("tappaas-mod-" + $m), title: ($m + " — its own numbers"), tags: ["tappaas", "module"],
         schemaVersion: 39, time: {from: "now-24h", to: "now"}, editable: false,
         templating: {list: [{name: "ci", label: "CI id", type: "textbox", query: ""}]},
         panels: [$rows | to_entries[] | .key as $i | .value as $r
           | {id: ($i + 1), type: "timeseries", title: ($r.e + ": " + $r.g),
              gridPos: {x: (($i % 2) * 12), y: (($i / 2 | floor) * 8), w: 12, h: 8},
              datasource: {type: "prometheus", uid: "prometheus"},
              targets: [{refId: "A", legendFormat: "{{__name__}}",
                expr: (if ($r.g | test("_total$|_count$")) then "sum by (__name__) (rate({__name__=~\"" + ($r.g | rx) + "\", tappaas_ci_id=\"$ci\"}[5m]))"
                       else "sum by (__name__) ({__name__=~\"" + ($r.g | rx) + "\", tappaas_ci_id=\"$ci\"})" end)}]}]}'
}

# The logging VM's own exporters (its Grafana, Loki, Alloy, Prometheus), as
# the Alloy module its receiver imports (logging.nix, import.file "self"):
# scraped there, kept by the declaration, labelled with its own host so the
# identity module stamps them. An empty module below service.
render_self_alloy() {
    local level="$1" decl host n i name port path elevel keep
    host="$(jq -r '.vmname // "logging"' "$(_sm_cfg logging)" 2>/dev/null || echo logging)"
    _ms_name_ok "${host}" || host=logging
    echo "// GENERATED on the mothership (lib/service-metrics.sh): logging's own exporters at level ${level}. Do not edit here."
    echo 'declare "scrape" {'
    echo '  argument "forward_to" { }'
    if (( $(_sm_rank "${level}") >= 2 )); then
        decl="$(perf_declaration_of logging)"
        n="$(jq '.exporters // [] | length' <<<"${decl}")"
        for (( i = 0; i < n; i++ )); do
            name="$(jq -r ".exporters[${i}].name // empty" <<<"${decl}")"
            port="$(jq -r ".exporters[${i}].port // empty" <<<"${decl}")"
            path="$(jq -r ".exporters[${i}].path // \"/metrics\"" <<<"${decl}")"
            elevel="$(jq -r ".exporters[${i}].level // \"service\"" <<<"${decl}")"
            [[ "${name}" =~ ^[a-z][a-z0-9-]*$ && "${port}" =~ ^[0-9]+$ && "${path}" =~ ^/[A-Za-z0-9/_.-]*$ ]] || continue
            (( $(_sm_rank "${level}") >= $(_sm_rank "${elevel}") )) || continue
            mapfile -t globs < <(jq -r ".exporters[${i}].keep // [] | .[]" <<<"${decl}")
            keep="$(perf_keep_regex "${globs[@]}")"
            [[ -n "${keep}" ]] || continue
            local id; id="$(_sm_ident "${name}")"
            cat <<EOF

  prometheus.scrape "${id}" {
    targets         = [{"__address__" = "127.0.0.1:${port}", "__metrics_path__" = "${path}"}]
    job_name        = "${name}"
    scrape_interval = "60s"
    forward_to      = [prometheus.relabel.${id}.receiver]
  }

  prometheus.relabel "${id}" {
    forward_to = argument.forward_to.value
    rule {
      source_labels = ["__name__"]
      regex         = "${keep}"
      action        = "keep"
    }
    rule {
      target_label = "host"
      replacement  = "${host}"
    }
    rule {
      action = "labeldrop"
      regex  = "instance|path|uri"
    }
  }
EOF
        done
    fi
    echo '}'
}

service_metrics_sync_logging() {
    local vm f m names="" c dash level
    [[ -f "$(_sm_cfg logging)" ]] || return 0
    vm="$(_ls_logging_vm)"
    for f in "$(_ls_config_dir)"/*.json; do
        m="$(basename "${f}" .json)"
        _ms_name_ok "${m}" || continue
        jq -e '(.source // "official") == "official" and ((.performance.exporters // []) | length > 0)' "${f}" >/dev/null 2>&1 || continue
        dash="$(render_module_dashboard "${m}")" || continue
        _ms_put "${vm}" "${SERVICE_DASH_DIR}/tappaas-mod-${m}.json" 0644 root:root "${dash}" >/dev/null || return 1
        names+=" tappaas-mod-${m}.json"
    done
    # Dashboards of modules gone or no longer declaring.
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" "cd ${SERVICE_DASH_DIR} 2>/dev/null && for f in tappaas-mod-*.json; do case ' ${names} ' in *\" \$f \"*) ;; *) [ -e \"\$f\" ] && sudo rm -f \"\$f\";; esac; done; true" || true
    level="$(service_metrics_level logging 2>/dev/null || echo off)"
    metrics_wanted || level=off
    c="$(_ms_put "${vm}" "${SERVICE_SELF_FILE}" 0644 root:root "$(render_self_alloy "${level}")
")" || return 1
    [[ -n "${c}" ]] && echo "logging's own exporters: level ${level}"
    return 0
}

# ── the firewall's Caddy metrics listener ───────────────────────────────

# Caddy keeps per-host numbers (the global `metrics` option), and serves
# them on the firewall's mgmt address to the controller only. os-caddy has no
# setting for it; caddy.d/*.global and *.conf are its documented extension.
_sm_caddy_files() {
    local fw ctl
    fw="$(getent ahostsv4 "${SERVICE_FIREWALL}" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "${fw}" =~ ^[0-9.]+$ ]] || return 1
    ctl="$(ip -4 route get "${fw}" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
    [[ "${ctl}" =~ ^[0-9.]+$ ]] || return 1
    printf '%s\n' "# GENERATED by TAPPaaS (lib/service-metrics.sh): per-host request numbers. Do not edit." \
        "metrics {" "	per_host" "}"
    printf '\x1e'
    printf '%s\n' "# GENERATED by TAPPaaS (lib/service-metrics.sh): the numbers, to the mothership only." \
        "http://${fw}:${CADDY_METRICS_PORT} {" \
        "	bind ${fw}" \
        "	@controller remote_ip ${ctl}/32" \
        "	handle @controller {" "		metrics" "	}" \
        "	respond 403" "}"
}

_sm_caddy_wanted() {
    metrics_wanted || return 1
    [[ "$(jq 'length' <<<"$(service_routes_wanted)")" -gt 0 ]]
}

caddy_metrics_state() {
    local files g s have
    have="$(${SERVICE_FW_SSH} "root@${SERVICE_FIREWALL}" "cat ${CADDY_METRICS_GLOBAL} 2>/dev/null; printf '\\036'; cat ${CADDY_METRICS_SITE} 2>/dev/null" 2>/dev/null)" || { echo unknown; return 0; }
    if ! _sm_caddy_wanted; then
        [[ "${have}" == $'\x1e' ]] && echo absent || echo unwanted
        return 0
    fi
    files="$(_sm_caddy_files)" || { echo unknown; return 0; }
    g="${files%%$'\x1e'*}"; s="${files#*$'\x1e'}"
    if [[ "${have}" == $'\x1e' ]]; then echo missing
    elif [[ "${have}" == "${g%$'\n'}"$'\x1e'"${s%$'\n'}" || "${have}" == "${g}"$'\x1e'"${s}" ]]; then echo in-sync
    else echo stale; fi
}

# Write both files, check the whole Caddyfile, and reload; a Caddyfile that
# does not validate takes the files out again, so Caddy never stops on them.
apply_caddy_metrics() {
    local files g s
    files="$(_sm_caddy_files)" || { echo "caddy metrics: cannot tell the firewall's or this machine's mgmt address" >&2; return 1; }
    g="${files%%$'\x1e'*}"; s="${files#*$'\x1e'}"
    ${SERVICE_FW_SSH} "root@${SERVICE_FIREWALL}" /bin/sh -s <<EOF || return 1
set -e
mkdir -p ${CADDY_D}
printf '%s' '$(printf '%s' "${g}" | base64 | tr -d '\n')' | b64decode -r > ${CADDY_METRICS_GLOBAL}
printf '%s' '$(printf '%s' "${s}" | base64 | tr -d '\n')' | b64decode -r > ${CADDY_METRICS_SITE}
if ! caddy validate --config /usr/local/etc/caddy/Caddyfile >/tmp/tappaas-caddy-validate.log 2>&1; then
    rm -f ${CADDY_METRICS_GLOBAL} ${CADDY_METRICS_SITE}
    tail -3 /tmp/tappaas-caddy-validate.log >&2
    echo "caddy metrics: the Caddyfile did not validate with them; taken out again" >&2
    exit 1
fi
configctl caddy reload >/dev/null 2>&1 || service caddy reload >/dev/null 2>&1 || true
EOF
    echo "caddy metrics: on ${SERVICE_FIREWALL}:${CADDY_METRICS_PORT}, for the mothership"
}

remove_caddy_metrics() {
    ${SERVICE_FW_SSH} "root@${SERVICE_FIREWALL}" "rm -f ${CADDY_METRICS_GLOBAL} ${CADDY_METRICS_SITE}; configctl caddy reload >/dev/null 2>&1 || service caddy reload >/dev/null 2>&1 || true" || return 1
    echo "caddy metrics: off"
}

fi
