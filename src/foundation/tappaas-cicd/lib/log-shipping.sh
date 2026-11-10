#!/usr/bin/env bash
#
# log-shipping.sh — each guest's journal to Loki, rendered in one place (#770):
# NixOS VMs through a fragment, Debian VMs and containers through Alloy's
# Debian package and the same pipeline (#903).
#
# A module that declares `logging:logs` (integratesWith, or dependsOn) gets an
# Alloy journal client while the logging module is deployed. The client is a
# fragment, /etc/nixos/tappaas-logging.nix, which the NixOS baseline imports
# when it exists — so no module carries its own copy of the pipeline, and a VM
# that should not ship has no file and runs no Alloy.
#
# It pushes to logging's push-only port, logging.mgmt.internal:3101 (nginx in
# front of Alloy's loki.source.api); 3100 is Loki's whole API and stays
# mgmt-only. A VM outside mgmt reaches 3101 through the logging:logs
# pinhole (fromZones: any — per consumer VM, that port only).
#
# Before the line leaves the VM: units that handle secrets are dropped (the
# platform's generate-*-secrets, plus the module's own
# config."logging:logs".dropUnits), and secret-looking values are scrubbed
# everywhere else. The stages are the ones tappaas-cicd and identity shipped
# with (#724): only the captured value is replaced, the key stays readable.
#
# Authentication (#165 §1). Every VM pushes with a credential of its own
# (username = its vmname), kept on the mothership in ~tappaas/.loki-push/<host>
# and written to the VM as /etc/secrets/tappaas-logging-push. nginx on the
# logging VM checks it on :3101 and passes the username on as the tenant;
# Alloy there overwrites the line's `host` with it, so a VM can only ever write
# as itself. :3100 (query and admin) takes one admin credential,
# ~tappaas/.loki-admin-password (user "tappaas").
#
# Sourceable only. Functions:
#   log_shipping_wanted <module>                  0 when the module should ship
#   render_logging_nix <host> <zone> [dropRegex]  the NixOS fragment, on stdout
#   log_shipping_drop_regex <module>              the unit regex to drop
#   apply_log_shipping_nixos <ip> <module>        install (or remove) the fragment
#                                                 and the VM's push secret; the
#                                                 caller rebuilds
#   render_logging_alloy <host> <zone> [dropRegex] the same pipeline as a plain
#                                                 config.alloy, on stdout
#   log_shipping_transport <module>               how to reach a non-NixOS guest
#                                                 as root: ssh:<ip> | lxc:<node>:<vmid>
#   apply_log_shipping_debian <transport> <module> install (or remove) Alloy, its
#                                                 config, secret and heartbeat on a
#                                                 Debian VM or container (#903)
#   remove_log_shipping_debian <transport>        take the client off again
#   apply_log_shipping_opnsense / remove_log_shipping_opnsense
#                                                 the firewall's syslog target (D9)
#   apply_log_shipping_node <node> / remove_log_shipping_node <node>
#                                                 a node's rsyslog forwarder (D9)
#   log_shipping_syslog_kind <module>             opnsense | node | "" (a guest)
#   log_shipping_password <host>                  the host's push secret (created
#                                                 on first use)
#   log_shipping_admin_password                   the :3100 admin secret
#   log_shipping_sync_logging                     write both htpasswd files on the
#                                                 logging VM, reload nginx
#   log_shipping_curl_admin <curl args...>        curl against :3100 as admin
#   log_shipping_push_url / log_shipping_query_url  where to push and query: the
#                                                 TLS ports once logging serves them (#787)

# An override wins; otherwise log_shipping_push_url / log_shipping_query_url
# choose TLS (#787) once logging serves it.
LOG_SHIPPING_PUSH_URL="${LOG_SHIPPING_PUSH_URL:-}"
LOG_SHIPPING_FRAGMENT="/etc/nixos/tappaas-logging.nix"
LOG_SHIPPING_VM_SECRET="/etc/secrets/tappaas-logging-push"
LOG_SHIPPING_CRED_DIR="${LOG_SHIPPING_CRED_DIR:-/home/tappaas/.loki-push}"
LOG_SHIPPING_ADMIN_FILE="${LOG_SHIPPING_ADMIN_FILE:-/home/tappaas/.loki-admin-password}"
LOG_SHIPPING_ADMIN_USER="tappaas"
LOG_SHIPPING_QUERY_URL="${LOG_SHIPPING_QUERY_URL:-}"
LOG_SHIPPING_HOST="${LOG_SHIPPING_HOST:-logging.mgmt.internal}"
# The level-driven metrics pipeline (lib/metrics-shipping.sh writes it).
LOG_SHIPPING_PERF_FILE="/var/lib/alloy-perf/perf.alloy"
LOG_SHIPPING_PERF_DEFAULT='declare "pipeline" { }'
# Units every TAPPaaS VM may have that write secrets: never shipped.
LOG_SHIPPING_BASE_DROP="generate-.*-secrets.*"

_ls_config_dir() { echo "${CONFIG_DIR:-/home/tappaas/config}"; }

# TLS (#787): logging serves push and query on :3111 and :3110 with a
# certificate from the site's internal CA. A sender moves to them only once
# they answer with a certificate this mothership verifies — the guests trust the
# same CA (ADR-043 D8) — so a guest updated before logging keeps shipping on the
# plain port rather than losing its lines and failing its test. Asked once per
# process: 401 is nginx asking for the credential over a verified TLS connection.
log_shipping_tls_ready() {
    if [[ -z "${_LS_TLS:-}" ]]; then
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://${LOG_SHIPPING_HOST}:3111/loki/api/v1/push" 2>/dev/null || true)"
        if [[ "${code}" == "401" ]]; then _LS_TLS=1; else _LS_TLS=0; fi
    fi
    [[ "${_LS_TLS}" == "1" ]]
}
log_shipping_push_url() {
    if [[ -n "${LOG_SHIPPING_PUSH_URL}" ]]; then echo "${LOG_SHIPPING_PUSH_URL}"
    elif log_shipping_tls_ready; then echo "https://${LOG_SHIPPING_HOST}:3111/loki/api/v1/push"
    else echo "http://${LOG_SHIPPING_HOST}:3101/loki/api/v1/push"; fi
}
log_shipping_query_url() {
    if [[ -n "${LOG_SHIPPING_QUERY_URL}" ]]; then echo "${LOG_SHIPPING_QUERY_URL}"
    elif log_shipping_tls_ready; then echo "https://${LOG_SHIPPING_HOST}:3110"
    else echo "http://${LOG_SHIPPING_HOST}:3100"; fi
}

# 32 characters from [A-Za-z0-9]: 190 bits, nothing a shell or nginx quotes.
# A finite read, cut in bash: `tr < /dev/urandom | head` ends tr with SIGPIPE,
# which the callers' pipefail turned into a failure (#165 live test).
_ls_new_secret() {
    local s
    s="$(head -c 96 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9')"
    [[ ${#s} -ge 32 ]] || return 1
    printf '%s' "${s:0:32}"
}

# Create <file> with a new secret unless it has one. Run as root (the
# mothership's own fragment), it still leaves the file to tappaas, who owns the
# store. Sets LOG_SHIPPING_NEW=1 when it created one.
_ls_ensure_secret() {
    local f="$1"
    [[ -s "${f}" ]] && return 0
    (umask 077; mkdir -p "$(dirname "${f}")" && _ls_new_secret > "${f}") || return 1
    if [[ ${EUID} -eq 0 ]]; then chown tappaas:users "$(dirname "${f}")" "${f}" 2>/dev/null || true; fi
    LOG_SHIPPING_NEW=1
}

log_shipping_password() {
    local host="$1"
    [[ "${host}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "log_shipping_password: bad host '${host}'" >&2; return 1; }
    _ls_ensure_secret "${LOG_SHIPPING_CRED_DIR}/${host}" && cat "${LOG_SHIPPING_CRED_DIR}/${host}"
}

log_shipping_admin_password() {
    _ls_ensure_secret "${LOG_SHIPPING_ADMIN_FILE}" && cat "${LOG_SHIPPING_ADMIN_FILE}"
}

# nginx's {SHA} scheme: base64 of the raw SHA-1. Unsalted is enough for a
# 190-bit random secret, and it needs nothing beyond coreutils.
_ls_sha() { printf '%s' "$1" | sha1sum | cut -d' ' -f1 | tr 'a-f' 'A-F' | basenc --base16 -d | base64; }

_ls_htpasswd_push() {
    local f
    for f in "${LOG_SHIPPING_CRED_DIR}"/*; do
        [[ -s "${f}" ]] || continue
        printf '%s:{SHA}%s\n' "$(basename "${f}")" "$(_ls_sha "$(cat "${f}")")"
    done
}

_ls_logging_vm() {
    local cfg; cfg="$(_ls_config_dir)/logging.json"
    printf 'tappaas@%s.%s.internal' "$(jq -r '.vmname // "logging"' "${cfg}" 2>/dev/null || echo logging)" \
        "$(jq -r '.zone0 // "mgmt"' "${cfg}" 2>/dev/null || echo mgmt)"
}

# Put one htpasswd file on the logging VM, only when it differs. Echoes
# "changed" when it wrote one.
_ls_put_htpasswd() {
    local vm="$1" path="$2" content="$3" want have
    want="$(printf '%s' "${content}" | sha256sum | cut -d' ' -f1)"
    have="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" "sudo sha256sum ${path} 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"
    [[ "${have}" == "${want}" ]] && return 0
    printf '%s' "${content}" | ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" \
        "sudo install -m 0640 -o root -g nginx /dev/stdin ${path}" || return 1
    echo changed
}

# Both password files on the logging VM: one line per pushing host (:3101), and
# the admin (:3100). nginx reloads only when one changed.
log_shipping_sync_logging() {
    local vm admin changed=""
    [[ -f "$(_ls_config_dir)/logging.json" ]] || return 0
    vm="$(_ls_logging_vm)"
    admin="$(log_shipping_admin_password)" || return 1
    changed+="$(_ls_put_htpasswd "${vm}" /etc/loki-auth/push.htpasswd "$(_ls_htpasswd_push)")" || return 1
    changed+="$(_ls_put_htpasswd "${vm}" /etc/loki-auth/admin.htpasswd \
        "$(printf '%s:{SHA}%s\n' "${LOG_SHIPPING_ADMIN_USER}" "$(_ls_sha "${admin}")")")" || return 1
    if [[ -n "${changed}" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 "${vm}" "sudo systemctl reload-or-restart nginx" || return 1
    fi
}

# curl against Loki's query/admin port with the admin credential.
log_shipping_curl_admin() {
    local pw
    pw="$(log_shipping_admin_password)" || return 1
    curl -u "${LOG_SHIPPING_ADMIN_USER}:${pw}" "$@"
}

# The module declares logging:logs, and logging is deployed on this site.
log_shipping_wanted() {
    local module="$1" cfg
    cfg="$(_ls_config_dir)"
    [[ -f "${cfg}/logging.json" && -f "${cfg}/${module}.json" ]] || return 1
    jq -e '((.dependsOn // []) + (.integratesWith // [])) | index("logging:logs") != null' \
        "${cfg}/${module}.json" >/dev/null 2>&1
}

# The regex of units whose lines never leave the VM. A module's dropUnits that
# are not plain unit patterns are refused rather than pasted into the selector.
log_shipping_drop_regex() {
    local module="$1" cfg extra re="${LOG_SHIPPING_BASE_DROP}" u
    cfg="$(_ls_config_dir)"
    # The installed config carries service fields flat (copy-update-json);
    # the module's source JSON nests them under config."logging:logs".
    extra="$(jq -r '(.dropUnits // .config["logging:logs"].dropUnits // [])[]' "${cfg}/${module}.json" 2>/dev/null)"
    while IFS= read -r u; do
        [[ -n "${u}" ]] || continue
        if [[ "${u}" =~ ^[A-Za-z0-9_.*@-]+$ ]]; then
            re+="|${u}"
        else
            echo "log-shipping: ignoring dropUnits entry '${u}' of ${module} (unit pattern characters only)" >&2
        fi
    done <<<"${extra}"
    echo "${re}"
}

# The Alloy pipeline itself (#770, #903), the same text for every client: the
# NixOS fragment embeds it as /etc/alloy/config.alloy (render_logging_nix), a
# Debian VM or container gets it as the file (render_logging_alloy). The push
# secret reaches Alloy as the systemd credential `loki-push` on both.
_ls_alloy_pipeline() {
    local host="$1" zone="${2:-}" drop="${3:-${LOG_SHIPPING_BASE_DROP}}"
    cat <<EOF
    loki.process "journal" {
      forward_to = [loki.write.default.receiver]

      // 1. Drop the units that handle secrets.
      stage.match {
        selector = "{unit=~\\"${drop}\\"}"
        action   = "drop"
      }
EOF
    cat <<'EOF'

      // 2. Scrub secret assignments anywhere else. Only the captured value is
      //    replaced (no $1 expansion, #724): the key stays readable.
      stage.replace {
        expression = "(?i)\\b(?:token|secret|password|passwd|api[_-]?key)\\s*[:=]\\s*(\\S+)"
        replace    = "***REDACTED***"
      }

      // 3. Scrub HTTP basic-auth in curl-like lines: -u "user:pass"
      stage.replace {
        expression = "-u[[:space:]]+[\"']?([^\"' ]+:[^\"' ]+)[\"']?"
        replace    = "***REDACTED***"
      }

      // 4. Scrub Authorization headers.
      stage.replace {
        expression = "Authorization:[[:space:]]+(?:Basic|Bearer)[[:space:]]+(\\S+)"
        replace    = "***REDACTED***"
      }

      // 5. Container lines carry their own level (#785). Podman's journald
      //    driver writes all of stderr at priority err, so authentik's info
      //    JSON arrived as severity=error. Where a line names its level
      //    ("level": "info", level=warn, | INFO |, [ERROR], ERROR: ...), that
      //    is its severity, in the journal's words. A line without one keeps
      //    the journal's priority: no match leaves the template empty, and an
      //    empty template drops the key, so stage.labels leaves severity alone.
      stage.match {
        selector = "{container=~\".+\"}"

        stage.regex {
          expression = "(?i)(?:^|\"level\"\\s*:\\s*\"|\\blevel=|\\|\\s*|\\[)(?P<lvl>debug|info|notice|warn|warning|error|err|critical|crit|fatal|panic)\\b"
        }

        stage.template {
          source   = "lvl"
          template = "{{ $l := ToLower .Value }}{{ if eq $l \"warn\" }}warning{{ else if eq $l \"err\" }}error{{ else if or (eq $l \"critical\") (eq $l \"fatal\") }}crit{{ else if eq $l \"panic\" }}emerg{{ else }}{{ $l }}{{ end }}"
        }

        stage.labels {
          values = { severity = "lvl" }
        }
      }
    }

    discovery.relabel "journal" {
      targets = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "severity"
      }

      // The podman container a line came from (journald driver), whatever
      // the unit is called; the level stage above keys on it.
      rule {
        source_labels = ["__journal_container_name"]
        target_label  = "container"
      }
    }

    loki.source.journal "journal" {
      max_age       = "12h0m0s"
      relabel_rules = discovery.relabel.journal.rules
      forward_to    = [loki.process.journal.receiver]
      labels        = {
EOF
    printf '        host = "%s",\n' "${host}"
    [[ -n "${zone}" ]] && printf '        zone = "%s",\n' "${zone}"
    cat <<EOF
        job  = "systemd-journal",
      }
    }

    loki.write "default" {
      endpoint {
        url = "$(log_shipping_push_url)"
        // HTTP/1.1: a push that times out closes its connection, so the retry
        // opens a new one. Over HTTP/2 the client kept waiting on a connection
        // the firewall had dropped when it restarted, and the VM's logs stalled
        // for half an hour.
        enable_http2 = false
        basic_auth {
          username      = "${host}"
          password_file = sys.env("CREDENTIALS_DIRECTORY") + "/loki-push"
        }
      }
    }

    // The level-driven part (ADR-046 D3): this guest's own numbers, written by
    // the mothership into a runtime file and re-read when it changes, so a
    // level change needs no rebuild. Level off is an empty pipeline.
    import.file "perf" {
      filename = "${LOG_SHIPPING_PERF_FILE}"
    }

    perf.pipeline "guest" { }
EOF
}

render_logging_nix() {
    local host="$1" zone="${2:-}" drop="${3:-${LOG_SHIPPING_BASE_DROP}}"
    [[ "${host}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "render_logging_nix: bad host '${host}'" >&2; return 1; }
    [[ -z "${zone}" || "${zone}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "render_logging_nix: bad zone '${zone}'" >&2; return 1; }
    cat <<EOF
# tappaas-logging.nix — GENERATED by TAPPaaS (#770). Do not edit here.
#
# This VM's journal to Loki on the logging VM, through its push-only receiver.
# Written on every update while the module declares logging:logs and logging is
# deployed; removed otherwise. Safe if the target is down: Alloy buffers and
# retries.
{ pkgs, ... }:
{
  # A line every 5 minutes, so a healthy VM is never silent (#770). HostSilent
  # alerts on a host with no line for 15 minutes; near-idle VMs (coturn,
  # jellyfin, …) log only on the hour, and raised it — and its resolve — every
  # hour (hrossen, 2026-10-07). With this, a silent host is down or not shipping.
  systemd.services.tappaas-log-heartbeat = {
    description = "TAPPaaS log heartbeat";
    serviceConfig.Type = "oneshot";
    script = "echo 'tappaas-log-heartbeat: alive'";
  };
  systemd.timers.tappaas-log-heartbeat = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; AccuracySec = "30s"; };
  };

  # The push secret (#165 §1), handed to Alloy by systemd: readable by the
  # service whatever user it runs as, and never in the store.
  systemd.services.alloy.serviceConfig.LoadCredential = [ "loki-push:${LOG_SHIPPING_VM_SECRET}" ];

  # The metrics pipeline's runtime file (ADR-046): the mothership writes it on
  # a level change; until then, and at level off, an empty pipeline.
  systemd.services.alloy.serviceConfig.ExecStartPre = [
    "+\${pkgs.writeShellScript "alloy-perf-default" ''
      install -d -m 0755 /var/lib/alloy-perf
      [ -s ${LOG_SHIPPING_PERF_FILE} ] || echo 'declare "pipeline" { }' > ${LOG_SHIPPING_PERF_FILE}
    ''}"
  ];

  services.alloy = {
    enable = true;
    extraFlags = [
      # Alloy's own HTTP server, localhost only.
      "--server.http.listen-addr=127.0.0.1:9080"
      # A TAPPaaS site tells no one what it runs.
      "--disable-reporting"
    ];
  };

  # In /etc, not the store, so alloy reloads it in place on switch.
  environment.etc."alloy/config.alloy".text = ''
EOF
    _ls_alloy_pipeline "${host}" "${zone}" "${drop}"
    cat <<EOF
  '';
}
EOF
}

# Install the fragment on a NixOS guest when the module ships, remove it when it
# does not. The caller's nixos-rebuild applies either.
apply_log_shipping_nixos() {
    local ip="$1" module="$2" cfg host zone tmp pw
    cfg="$(_ls_config_dir)"
    if ! log_shipping_wanted "${module}"; then
        ssh -o BatchMode=yes "tappaas@${ip}" "sudo rm -f ${LOG_SHIPPING_FRAGMENT} ${LOG_SHIPPING_VM_SECRET}"
        return
    fi
    host="$(jq -r '.vmname // empty' "${cfg}/${module}.json" 2>/dev/null)"
    zone="$(jq -r '(.zone0 // (.config? // {} | to_entries[]?.value.zone0?)) // ""' "${cfg}/${module}.json" 2>/dev/null | head -1)"
    # The VM's push secret first: the fragment names it, and Alloy will not
    # start without it. A new one is added to the logging VM's password file at
    # once, so the VM's first push is accepted.
    LOG_SHIPPING_NEW=0
    pw="$(log_shipping_password "${host:-${module}}")" || return 1
    printf '%s' "${pw}" | ssh -o BatchMode=yes "tappaas@${ip}" \
        "{ [ -d /etc/secrets ] || sudo install -d -m 0755 /etc/secrets; } && sudo install -m 0600 -o root -g root /dev/stdin ${LOG_SHIPPING_VM_SECRET}" \
        || return 1
    if [[ "${LOG_SHIPPING_NEW}" -eq 1 ]]; then
        log_shipping_sync_logging || echo "log-shipping: could not add ${host:-${module}} to the logging VM's password file — its pushes are refused until logging's next update" >&2
    fi
    tmp="$(mktemp)" || return 1
    if ! render_logging_nix "${host:-${module}}" "${zone}" "$(log_shipping_drop_regex "${module}")" > "${tmp}"; then
        rm -f "${tmp}"; return 1
    fi
    if ! scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${tmp}" "tappaas@${ip}:/tmp/tappaas-logging.nix"; then
        rm -f "${tmp}"; return 1
    fi
    rm -f "${tmp}"
    ssh -o BatchMode=yes "tappaas@${ip}" \
        "sudo install -m 0644 /tmp/tappaas-logging.nix ${LOG_SHIPPING_FRAGMENT} && rm -f /tmp/tappaas-logging.nix"
}

# ── Debian VMs and containers (#903) ─────────────────────────────────
# The same pipeline as a plain /etc/alloy/config.alloy, Alloy from Grafana's
# Debian repository at a pinned version, and the push secret handed to Alloy as
# the systemd credential `loki-push` — as on NixOS. A Debian VM is reached as
# tappaas over SSH (sudo), a container through `pct exec` on its node, so it
# needs no SSH of its own. Only what TAPPaaS installed is ever removed
# (/etc/alloy/.tappaas-managed).

# The Alloy release Debian guests run: the minor NixOS guests run (nixpkgs'
# grafana-alloy), so both read the pipeline the same way. Bumped with the
# release pins.
LOG_SHIPPING_ALLOY_DEB="${LOG_SHIPPING_ALLOY_DEB:-1.16.3-1}"
LOG_SHIPPING_APT_LIST="deb [signed-by=/etc/apt/keyrings/tappaas-grafana.asc] https://apt.grafana.com stable main"

# Grafana Labs' repository signing key, pinned here rather than fetched on the
# guest: fingerprint B53A E77B ADB6 30A6 8304  6005 963F A277 1045 8545
# (rsa3072, 2023-08-24, expires 2027-08-22 — replace it before then).
_ls_grafana_key() {
    cat <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQGNBGTnhmkBDADUE+SzjRRyitIm1siGxiHlIlnn6KO4C4GfEuV+PNzqxvwYO+1r
mcKlGDU0ugo8ohXruAOC77Kwc4keVGNU89BeHvrYbIftz/yxEneuPsCbGnbDMIyC
k44UOetRtV9/59Gj5YjNqnsZCr+e5D/JfrHUJTTwKLv88A9eHKxskrlZr7Un7j3i
Ef3NChlOh2Zk9Wfk8IhAqMMTferU4iTIhQk+5fanShtXIuzBaxU3lkzFSG7VuAH4
CBLPWitKRMn5oqXUE0FZbRYL/6Qz0Gt6YCJsZbaQ3Am7FCwWCp9+ZHbR9yU+bkK0
Dts4PNx4Wr9CktHIvbypT4Lk2oJEPWjcCJQHqpPQZXbnclXRlK5Ea0NVpaQdGK+v
JS4HGxFFjSkvTKAZYgwOk93qlpFeDML3TuSgWxuw4NIDitvewudnaWzfl9tDIoVS
Bb16nwJ8bMDzovC/RBE14rRKYtMLmBsRzGYHWd0NnX+FitAS9uURHuFxghv9GFPh
eTaXvc4glM94HBUAEQEAAbQmR3JhZmFuYSBMYWJzIDxlbmdpbmVlcmluZ0BncmFm
YW5hLmNvbT6JAdQEEwEKAD4CGwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AWIQS1
Oud7rbYwpoMEYAWWP6J3EEWFRQUCaKhvPQUJB4NP1AAKCRCWP6J3EEWFRUjOC/9Y
dWOWJLJVKzLx8uv5YVzebyw15HevhKahbznJX5fHnE8irjkiPFltVEZ4T37s5afR
GBEJnR1UFd80s7jzwbuoZh/zEB3jN8q50g64AznuzDa0PWKzaY7Tgkssx3+hs6TS
vIwV4z8T7f56lDudeHxHXx+htRnZ3ebKNPCJS7+G12GF6W3C3znpdjgvhVUB0uxd
+42V0fRqk2GLNZeKS9988fi5dYRAy9Ozwced7ByCFjde9FBgUtrH3mG1/ibzLEh0
4k02nYjc8mrH32t4UCWpxQEJ1vZA2vT2HN3/cH/4uyFdyU6OHkMyMbz6lmeXe71d
F5hOB4+/RP6Ndyj7ViRNDbm70NRBaFne/+YOJvmMfJTCh7YbF5qEn1ihGkJJ0ohE
u2IB+EGEhyiDm8SIsj1uMw7n17iIPNtbsU5GgnmLtfguP/WbwKV2UeuxTpiOeYb6
blDwRlh48uHMlA5HBW+487Jktw3iPj1IKhdtAC9CU3xAvzDcseMbgmM6Xj2bSQG5
AY0EZOeGaQEMALNIFUricEIwtZiX7vSDjwxobbqPKqzdek8x3ud0CyYlrbGHy0k+
FDEXstjJQQ1s9rjJSu3sv5wyg9GDAUH3nzO976n/ZZvKPti3p2XU2UFx5gYkaaFV
D56yYxqGY0YU5ft6BG+RUz3iEPg3UBUzt0sCIYnG9+CsDqGOnRYIIa46fu2/H9Vu
8JvvSq9xbsK9CfoQDkIcoQOixPuI4P7eHtswCeYR/1LUTWEnYQWsBCf57cEpzR6t
7mlQnzQo9z4i/kp4S0ybDB77wnn+isMADOS+/VpXO+M7Zj5tpfJ6PkKch3SGXdUy
3zht8luFOYpJr2lVzp7n3NwB4zW08RptTzTgFAaW/NH2JjYI+rDvQm4jNs08Dtsp
nm4OQvBA9Df/6qwMEOZ9i10ixqk+55UpQFJ3nf4uKlSUM7bKXXVcD/odq804Y/K4
y3csE059YVIyaPexEvYSYlHE2odJWRg2Q1VehmrOSC8Qps3xpU7dTHXD74ZpaYbr
haViRS5v/lCsiwARAQABiQG8BBgBCgAmAhsMFiEEtTrne622MKaDBGAFlj+idxBF
hUUFAmiobzkFCQeDT9AACgkQlj+idxBFhUVsmQwA0PA/zd7NqtnZ/Z8857gp2Wq2
/e4EX8nRjsW2ZlrZfbU5oMQv9OZZ4z1UjIKEUV+TnCwXEKXTMJomdekQSSayVVx/
u5w+0YM8gRuQGrG8hW0GRR8sHIeuwBFlyQrlwxUwXvDOPDYyieETjaQqMucupIKo
IPm3CjFySvfizvSWUVSWBnGmQfpv6OiGYawvwfewcQHUdLMgWN3lYlzGQJL4+OMm
7XcB8VNTa586Q00fmjDfktHYvGpmhqr3gsd4gS3AjTk0zI65qXBRJkdqVnwUrMUD
8TcxXYNXf90mhR0NWkLmp6kBYiW8+QY6ndMmRVpodg1A87qgMYaZUAAlxCS4XKTU
r+/YMDYOWgLN6i4UeYG/3/hsnAEHm5ITojfh6cLfdlhjohFTnD0IYw3AsNJXRzKB
1g5FTBKLLLIdXgS/3rWV1qjAd3drQVIMCku6HKl/vT4ftrBHeSyV7eLwOYbe3/bw
8VMx+lmMheD8/qJMia1om0iBBRSXRjY//f+Lllqm
=TH3J
-----END PGP PUBLIC KEY BLOCK-----
EOF
}

render_logging_alloy() {
    local host="$1" zone="${2:-}" drop="${3:-${LOG_SHIPPING_BASE_DROP}}"
    [[ "${host}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "render_logging_alloy: bad host '${host}'" >&2; return 1; }
    [[ -z "${zone}" || "${zone}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "render_logging_alloy: bad zone '${zone}'" >&2; return 1; }
    echo "// config.alloy — GENERATED by TAPPaaS (#903). Do not edit here."
    echo "// This guest's journal to Loki on the logging VM, through its push-only receiver."
    echo ""
    _ls_alloy_pipeline "${host}" "${zone}" "${drop}" | sed 's/^    //'
}

# The module's guest as root, for the Debian client: lxc:<node>:<vmid> for a
# container (its live node), ssh:<ip> for a Debian VM. rc 1 (nothing printed)
# for a NixOS guest — update-os.sh writes its fragment — or one this cannot
# reach or does not know (HAOS, Windows).
log_shipping_transport() {
    local module="$1" cfg vmid vmname zone node n target
    cfg="$(_ls_config_dir)/${module}.json"
    [[ -f "${cfg}" ]] || return 1
    vmid="$(jq -r '(.vmid // (.config? // {} | to_entries[]?.value.vmid?)) // empty' "${cfg}" 2>/dev/null | head -1)"
    if jq -e '.kind == "lxc" or ((.dependsOn // []) | index("cluster:lxc") != null)' "${cfg}" >/dev/null 2>&1; then
        [[ "${vmid}" =~ ^[0-9]+$ ]] || return 1
        for n in $(get_all_node_hostnames 2>/dev/null); do
            node="$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 "root@${n}.mgmt.internal" \
                "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
                | jq -r --argjson id "${vmid}" '.[] | select(.vmid == $id and .type == "lxc") | .node' 2>/dev/null)" || node=""
            [[ -n "${node}" ]] && break
        done
        [[ -n "${node}" ]] || return 1
        printf 'lxc:%s:%s\n' "${node}" "${vmid}"
        return 0
    fi
    vmname="$(jq -r '.vmname // empty' "${cfg}" 2>/dev/null)"
    zone="$(jq -r '(.zone0 // (.config? // {} | to_entries[]?.value.zone0?)) // ""' "${cfg}" 2>/dev/null | head -1)"
    target="${vmname:-${module}}.${zone:-mgmt}.internal"
    ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "tappaas@${target}" \
        'test -f /etc/debian_version && test ! -e /etc/NIXOS' 2>/dev/null || return 1
    printf 'ssh:%s\n' "${target}"
}

# Run the script on stdin as root on the guest.
_ls_guest_root() {
    local t="$1" node vmid
    case "${t}" in
        ssh:*) ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "tappaas@${t#ssh:}" "sudo bash -s" ;;
        lxc:*)
            node="${t#lxc:}"; vmid="${node#*:}"; node="${node%%:*}"
            [[ "${node}" =~ ^[A-Za-z0-9.-]+$ && "${vmid}" =~ ^[0-9]+$ ]] || { echo "log-shipping: bad transport '${t}'" >&2; return 1; }
            ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${node}.mgmt.internal" "pct exec ${vmid} -- bash -s" ;;
        *) echo "log-shipping: bad transport '${t}'" >&2; return 1 ;;
    esac
}

_ls_b64() { base64 -w0; }

apply_log_shipping_debian() {
    local t="$1" module="$2" cfg host zone pw
    cfg="$(_ls_config_dir)"
    if ! log_shipping_wanted "${module}"; then
        remove_log_shipping_debian "${t}"
        return
    fi
    host="$(jq -r '.vmname // empty' "${cfg}/${module}.json" 2>/dev/null)"
    host="${host:-${module}}"
    zone="$(jq -r '(.zone0 // (.config? // {} | to_entries[]?.value.zone0?)) // ""' "${cfg}/${module}.json" 2>/dev/null | head -1)"
    LOG_SHIPPING_NEW=0
    pw="$(log_shipping_password "${host}")" || return 1
    if [[ "${LOG_SHIPPING_NEW}" -eq 1 ]]; then
        log_shipping_sync_logging || echo "log-shipping: could not add ${host} to the logging VM's password file — its pushes are refused until logging's next update" >&2
    fi
    local alloy defaults dropin hbs hbt
    alloy="$(render_logging_alloy "${host}" "${zone}" "$(log_shipping_drop_regex "${module}")")" || return 1
    defaults=$'# GENERATED by TAPPaaS (#903).\nCONFIG_FILE="/etc/alloy/config.alloy"\nCUSTOM_ARGS="--server.http.listen-addr=127.0.0.1:9080 --disable-reporting"\nRESTART_ON_UPGRADE=true\n'
    dropin=$'# GENERATED by TAPPaaS (#903): the push secret, as on NixOS.\n[Service]\nLoadCredential=loki-push:'"${LOG_SHIPPING_VM_SECRET}"$'\n'
    hbs=$'[Unit]\nDescription=TAPPaaS log heartbeat\n\n[Service]\nType=oneshot\nExecStart=/bin/echo tappaas-log-heartbeat: alive\n'
    hbt=$'[Unit]\nDescription=TAPPaaS log heartbeat\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=5min\nAccuracySec=30s\n\n[Install]\nWantedBy=timers.target\n'
    # Every file travels base64 in the script on stdin: no secret on a command
    # line, nothing for a remote shell to expand.
    _ls_guest_root "${t}" <<EOF
set -eu
export DEBIAN_FRONTEND=noninteractive
[ -f /etc/debian_version ] || { echo "not a Debian guest" >&2; exit 3; }
changed=0
put() {
    tmp=\$(mktemp)
    printf '%s' "\$3" | base64 -d > "\$tmp"
    if [ -f "\$1" ] && cmp -s "\$tmp" "\$1"; then rm -f "\$tmp"; return 0; fi
    install -D -m "\$2" -o root -g root "\$tmp" "\$1"; rm -f "\$tmp"; changed=1
}
install -d -m 0755 /etc/apt/keyrings /etc/secrets
put /etc/apt/keyrings/tappaas-grafana.asc 0644 '$(_ls_grafana_key | _ls_b64)'
put /etc/apt/sources.list.d/tappaas-grafana.list 0644 '$(printf '%s\n' "${LOG_SHIPPING_APT_LIST}" | _ls_b64)'
if [ "\$(dpkg-query -W -f='\${Version}' alloy 2>/dev/null || true)" != "${LOG_SHIPPING_ALLOY_DEB}" ]; then
    apt-get update -qq
    apt-mark unhold alloy >/dev/null 2>&1 || true
    apt-get install -y -qq --allow-downgrades -o Dpkg::Options::=--force-confold alloy=${LOG_SHIPPING_ALLOY_DEB} >/dev/null
    apt-mark hold alloy >/dev/null
    changed=1
fi
put ${LOG_SHIPPING_VM_SECRET} 0600 '$(printf '%s' "${pw}" | _ls_b64)'
put /etc/alloy/config.alloy 0644 '$(printf '%s\n' "${alloy}" | _ls_b64)'
put /etc/default/alloy 0644 '$(printf '%s' "${defaults}" | _ls_b64)'
put /etc/systemd/system/alloy.service.d/tappaas.conf 0644 '$(printf '%s' "${dropin}" | _ls_b64)'
put /etc/systemd/system/tappaas-log-heartbeat.service 0644 '$(printf '%s' "${hbs}" | _ls_b64)'
put /etc/systemd/system/tappaas-log-heartbeat.timer 0644 '$(printf '%s' "${hbt}" | _ls_b64)'
touch /etc/alloy/.tappaas-managed
install -d -m 0755 /var/lib/alloy-perf
[ -s ${LOG_SHIPPING_PERF_FILE} ] || printf '%s\n' '${LOG_SHIPPING_PERF_DEFAULT}' > ${LOG_SHIPPING_PERF_FILE}
usermod -a -G systemd-journal alloy 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now tappaas-log-heartbeat.timer >/dev/null 2>&1
systemctl enable alloy >/dev/null 2>&1
if [ "\$changed" = 1 ] || ! systemctl is-active -q alloy; then systemctl restart alloy; fi
sleep 2
systemctl is-active -q alloy || { journalctl -u alloy -n 20 --no-pager >&2; exit 1; }
echo "alloy ${LOG_SHIPPING_ALLOY_DEB} shipping as ${host}\$( [ "\$changed" = 1 ] && echo ' (changed)' )"
EOF
}

remove_log_shipping_debian() {
    _ls_guest_root "$1" <<EOF
set -eu
[ -f /etc/alloy/.tappaas-managed ] || exit 0
systemctl disable --now tappaas-log-heartbeat.timer alloy >/dev/null 2>&1 || true
apt-mark unhold alloy >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq alloy >/dev/null 2>&1 || true
rm -rf /etc/alloy /etc/systemd/system/alloy.service.d /etc/default/alloy /var/lib/alloy-perf
rm -f ${LOG_SHIPPING_VM_SECRET} /etc/apt/sources.list.d/tappaas-grafana.list /etc/apt/keyrings/tappaas-grafana.asc
rm -f /etc/systemd/system/tappaas-log-heartbeat.service /etc/systemd/system/tappaas-log-heartbeat.timer
systemctl daemon-reload
echo "alloy removed"
EOF
}

# ── Syslog senders: the firewall and the nodes (ADR-039 D9) ───────────
# They declare logging:logs like any consumer; their client is a syslog target,
# not a journal client: OPNsense's remote destination (:1514, source=opnsense)
# and each node's rsyslog forwarder (:1515, source=proxmox). Logging's Alloy
# labels their lines host=<the first label of the syslog hostname>, which is
# the instance's vmname (network, tappaas1, …).

_ls_syslog_target() {
    local cfg; cfg="$(_ls_config_dir)/logging.json"
    printf '%s.%s.internal' "$(jq -r '.vmname // "logging"' "${cfg}" 2>/dev/null || echo logging)" \
        "$(jq -r '.zone0 // "mgmt"' "${cfg}" 2>/dev/null || echo mgmt)"
}

# Which kind of syslog sender a consumer is: "opnsense" for the firewall
# (the network module on an OPNsense site), "node" for a pvehost instance,
# empty for a guest (journal client).
log_shipping_syslog_kind() {
    local module="$1" cfg src
    cfg="$(_ls_config_dir)/${module}.json"
    [[ -f "${cfg}" ]] || return 0
    src="$(jq -r '(.moduleSource // .location // "") | sub("/+$"; "") | split("/") | last' "${cfg}" 2>/dev/null)"
    case "${src}" in
        pvehost) echo node ;;
        network) [[ "$(jq -r '.firewallType // "opnsense"' "${cfg}" 2>/dev/null)" == "opnsense" ]] && echo opnsense ;;
    esac
    return 0
}

LOG_SHIPPING_OPNSENSE_DESC="tappaas-logging"

# Over TLS (#787) once logging serves it: to :6514 with tls4, presenting a
# certificate the internal CA signs for the firewall (its syslog-ng insists on
# one), and verifying logging's against the firewall's trust store, which holds
# the internal CA once ca-manager has put it there. Until then, tcp4 to :1514.
apply_log_shipping_opnsense() {
    local target out rc port=1514 transport=tcp4 refid=""
    local -a cert=()
    command -v syslog-manager >/dev/null 2>&1 || { echo "syslog-manager not found — rebuild the mothership" >&2; return 1; }
    target="$(_ls_syslog_target)"
    if log_shipping_tls_ready && command -v ca-manager >/dev/null 2>&1 \
        && ca-manager cert issue firewall-syslog --dns firewall.mgmt.internal --if-absent >/dev/null 2>&1; then
        refid="$(ca-manager cert to-firewall firewall-syslog 2>/dev/null | tail -1)"
        [[ "${refid}" =~ ^[0-9a-f]{8,}$ ]] && { port=6514; transport=tls4; cert=(--certificate "${refid}"); }
    fi
    out="$(syslog-manager add-destination --hostname "${target}" --port "${port}" --transport "${transport}" "${cert[@]}" --rfc5424 \
            --description "${LOG_SHIPPING_OPNSENSE_DESC}" --no-ssl-verify 2>&1)" && rc=0 || rc=$?
    [[ ${rc} -eq 0 ]] || { echo "${out}" >&2; return 1; }
    out="$(syslog-manager reconfigure --no-ssl-verify 2>&1)" || { echo "${out}" >&2; return 1; }
    echo "OPNsense forwards syslog to ${target}:${port} (${transport})"
}

remove_log_shipping_opnsense() {
    command -v syslog-manager >/dev/null 2>&1 || return 0
    syslog-manager delete-destination --description "${LOG_SHIPPING_OPNSENSE_DESC}" --no-ssl-verify >/dev/null 2>&1 || return 1
    syslog-manager reconfigure --no-ssl-verify >/dev/null 2>&1
}

LOG_SHIPPING_RSYSLOG_CONF="/etc/rsyslog.d/99-tappaas-loki.conf"

# A node's rsyslog forwarder; with "tls", to :6515 over TLS (#787), logging's
# certificate checked against the node's CA bundle, which holds the site's CAs
# (the cluster update), and its name against the target.
_ls_rsyslog_conf() {
    local target="$1" tls="${2:-}" port=1515
    [[ "${tls}" == "tls" ]] && port=6515
    cat <<CONF
# TAPPaaS-managed — ship syslog to Loki via Alloy on ${target}:${port}
# Format: RFC 5424 over TCP with octet-counted framing (RFC 5425)$([[ "${tls}" == "tls" ]] && printf ', over TLS')
# Do not edit by hand; this file is regenerated by logging:logs (lib/log-shipping.sh).
*.* action(type="omfwd"
           target="${target}"
           port="${port}"
           protocol="tcp"$([[ "${tls}" == "tls" ]] && printf '\n           StreamDriver="gtls"\n           StreamDriverMode="1"\n           StreamDriverAuthMode="x509/name"\n           StreamDriverPermittedPeers="%s"\n           StreamDriver.CAFile="/etc/ssl/certs/ca-certificates.crt"' "${target}")
           template="RSYSLOG_SyslogProtocol23Format"
           TCP_Framing="octet-counted"
           Action.ResumeRetryCount="-1"
           queue.type="LinkedList"
           queue.size="10000")
CONF
}

# A node's rsyslog forwarder: rsyslog installed if missing (PVE 9 ships
# journald only), the conf written, rsyslog restarted only when it changed.
apply_log_shipping_node() {
    local node="$1" target fqdn
    [[ "${node}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "apply_log_shipping_node: bad node '${node}'" >&2; return 1; }
    target="$(_ls_syslog_target)"; fqdn="${node}.mgmt.internal"
    # TLS once logging serves it AND this node verifies its certificate itself: a
    # node whose CA bundle does not hold the internal CA yet stays on :1515.
    local tls="" code
    if log_shipping_tls_ready; then
        code="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@${fqdn}" \
            "curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://${target}:3111/loki/api/v1/push" 2>/dev/null || true)"
        [[ "${code}" == "401" ]] && tls="tls"
    fi
    _ls_rsyslog_conf "${target}" "${tls}" | ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@${fqdn}" "
        set -e
        command -v rsyslogd >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsyslog >/dev/null 2>&1
        [ -z '${tls}' ] || dpkg -s rsyslog-gnutls >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsyslog-gnutls >/dev/null 2>&1
        t=\$(mktemp); cat > \"\$t\"
        if cmp -s \"\$t\" ${LOG_SHIPPING_RSYSLOG_CONF}; then rm -f \"\$t\"; c=0; else install -m 0644 \"\$t\" ${LOG_SHIPPING_RSYSLOG_CONF}; rm -f \"\$t\"; c=1; fi
        systemctl enable rsyslog >/dev/null 2>&1
        if [ \$c = 1 ] || ! systemctl is-active -q rsyslog; then systemctl restart rsyslog; fi
        systemctl is-active -q rsyslog" || return 1
    echo "${node}: rsyslog → ${target}:$([[ -n "${tls}" ]] && echo "6515 (TLS)" || echo 1515)"
}

remove_log_shipping_node() {
    local node="$1"
    [[ "${node}" =~ ^[A-Za-z0-9-]+$ ]] || return 1
    ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${node}.mgmt.internal" \
        "[ -e ${LOG_SHIPPING_RSYSLOG_CONF} ] || exit 0; rm -f ${LOG_SHIPPING_RSYSLOG_CONF}; systemctl restart rsyslog"
}
