#!/usr/bin/env bash
#
# log-shipping.sh — each NixOS VM's journal to Loki, rendered in one place (#770).
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
#   log_shipping_password <host>                  the host's push secret (created
#                                                 on first use)
#   log_shipping_admin_password                   the :3100 admin secret
#   log_shipping_sync_logging                     write both htpasswd files on the
#                                                 logging VM, reload nginx
#   log_shipping_curl_admin <curl args...>        curl against :3100 as admin

LOG_SHIPPING_PUSH_URL="${LOG_SHIPPING_PUSH_URL:-http://logging.mgmt.internal:3101/loki/api/v1/push}"
LOG_SHIPPING_FRAGMENT="/etc/nixos/tappaas-logging.nix"
LOG_SHIPPING_VM_SECRET="/etc/secrets/tappaas-logging-push"
LOG_SHIPPING_CRED_DIR="${LOG_SHIPPING_CRED_DIR:-/home/tappaas/.loki-push}"
LOG_SHIPPING_ADMIN_FILE="${LOG_SHIPPING_ADMIN_FILE:-/home/tappaas/.loki-admin-password}"
LOG_SHIPPING_ADMIN_USER="tappaas"
LOG_SHIPPING_QUERY_URL="${LOG_SHIPPING_QUERY_URL:-http://logging.mgmt.internal:3100}"
# Units every TAPPaaS VM may have that write secrets: never shipped.
LOG_SHIPPING_BASE_DROP="generate-.*-secrets.*"

_ls_config_dir() { echo "${CONFIG_DIR:-/home/tappaas/config}"; }

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
{ ... }:
{
  # The push secret (#165 §1), handed to Alloy by systemd: readable by the
  # service whatever user it runs as, and never in the store.
  systemd.services.alloy.serviceConfig.LoadCredential = [ "loki-push:${LOG_SHIPPING_VM_SECRET}" ];

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
        url = "${LOG_SHIPPING_PUSH_URL}"
        basic_auth {
          username      = "${host}"
          password_file = sys.env("CREDENTIALS_DIRECTORY") + "/loki-push"
        }
      }
    }
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
        "sudo install -d -m 0755 /etc/secrets && sudo install -m 0600 -o root -g root /dev/stdin ${LOG_SHIPPING_VM_SECRET}" \
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
