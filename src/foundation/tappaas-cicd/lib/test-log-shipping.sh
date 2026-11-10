#!/usr/bin/env bash
#
# test-log-shipping.sh — unit tests for the journal client renderers
# (lib/log-shipping.sh, #770 / #903). Offline: no guest, no logging VM.
#
#   - the NixOS fragment and the Debian config.alloy carry the same pipeline;
#   - a module's dropUnits reach the drop selector of both;
#   - the Debian client's guest script parses, decodes to the files it names,
#     and never carries the push secret in clear;
#   - bad hosts, zones and transports are refused.
#
# Usage: test-log-shipping.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }; error(){ :; }; debug(){ :; }
# shellcheck source=log-shipping.sh
. "${HERE}/log-shipping.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

# ── one pipeline, two wrappers ───────────────────────────────────────
drop="generate-.*-secrets.*|secretd.service"
render_logging_nix web dmz "${drop}" > "${T}/frag.nix" || no "render_logging_nix failed"
render_logging_alloy web dmz "${drop}" > "${T}/config.alloy" || no "render_logging_alloy failed"
# The pipeline inside the fragment's '' string, Nix's common indentation removed.
sed -n '/config.alloy".text = '"''"'$/,/^  '"''"';$/p' "${T}/frag.nix" | sed '1d;$d' | sed 's/^    //' > "${T}/nix-pipeline"
sed '1,3d' "${T}/config.alloy" > "${T}/deb-pipeline"
if [[ -s "${T}/nix-pipeline" ]] && cmp -s "${T}/nix-pipeline" "${T}/deb-pipeline"; then ok; else
    no "the NixOS and Debian pipelines differ"; diff "${T}/nix-pipeline" "${T}/deb-pipeline" | head -20; fi
grep -q 'secretd.service' "${T}/config.alloy" && ok || no "dropUnits missing from config.alloy"
grep -q 'host = "web"' "${T}/config.alloy" && grep -q 'zone = "dmz"' "${T}/config.alloy" && ok || no "host/zone labels missing"
grep -q 'CREDENTIALS_DIRECTORY' "${T}/config.alloy" && ok || no "the push secret is not read from the systemd credential"
# The pipeline goes into a Nix '' string: it must not carry an interpolation or
# the string's own terminator.
if _ls_alloy_pipeline web dmz "${drop}" | grep -cE "\\\$\\{|''" >/dev/null; then no "pipeline carries \${ or '' (breaks the Nix string)"; else ok; fi

render_logging_alloy 'bad host' dmz >/dev/null 2>&1 && no "a bad host was accepted" || ok
render_logging_alloy web 'bad;zone' >/dev/null 2>&1 && no "a bad zone was accepted" || ok

# ── the Debian client's guest script ─────────────────────────────────
mkdir -p "${T}/config" "${T}/cred"
echo '{}' > "${T}/config/logging.json"
echo '{"vmname":"site1","kind":"lxc","vmid":631,"zone0":"dmz","integratesWith":["logging:logs"]}' > "${T}/config/site1.json"
echo '{"vmname":"quiet","kind":"lxc","vmid":632}' > "${T}/config/quiet.json"
(
    export CONFIG_DIR="${T}/config" LOG_SHIPPING_CRED_DIR="${T}/cred"
    log_shipping_sync_logging() { :; }
    _ls_guest_root() { cat > "${T}/script-$1.sh"; }
    apply_log_shipping_debian lxc:tappaas2:631 site1
    apply_log_shipping_debian lxc:tappaas2:632 quiet
)
S="${T}/script-lxc:tappaas2:631.sh"
[[ -s "${S}" ]] && bash -n "${S}" && ok || no "the install script is missing or does not parse"
pw="$(cat "${T}/cred/site1" 2>/dev/null)"
[[ ${#pw} -eq 32 ]] && ok || no "no 32-character push secret was made"
grep -qF "${pw}" "${S}" && no "the push secret is in the script in clear" || ok
dec() { grep "^put $1 " "${S}" | sed "s/^put [^ ]* [0-7]* '//; s/'\$//" | base64 -d; }
[[ "$(dec /etc/secrets/tappaas-logging-push)" == "${pw}" ]] && ok || no "the secret file does not decode to the secret"
dec /etc/alloy/config.alloy | grep -c 'host = "site1"' >/dev/null && ok || no "config.alloy is not site1's"
dec /etc/apt/keyrings/tappaas-grafana.asc | head -1 | grep -c 'BEGIN PGP PUBLIC KEY BLOCK' >/dev/null && ok || no "the Grafana key is not shipped"
grep -q "alloy=${LOG_SHIPPING_ALLOY_DEB}" "${S}" && grep -q 'apt-mark hold alloy' "${S}" && ok || no "Alloy is not pinned and held"
grep -q '\.tappaas-managed' "${S}" && ok || no "the install does not mark what it owns"
# A module that does not declare logging:logs gets the removal, and only of
# what TAPPaaS installed.
R="${T}/script-lxc:tappaas2:632.sh"
grep -q 'apt-get purge' "${R}" && grep -q '\[ -f /etc/alloy/.tappaas-managed \] || exit 0' "${R}" && ok \
    || no "an undeclared module does not get the guarded removal"

# ── syslog senders (ADR-039 D9) ──────────────────────────────────────
echo '{"moduleSource":"/x/src/foundation/pvehost"}' > "${T}/config/tappaas1.json"
echo '{"vmname":"network","moduleSource":"/x/src/foundation/network/"}' > "${T}/config/network.json"
echo '{"vmname":"network","location":"/x/src/foundation/network","firewallType":"pfsense"}' > "${T}/config/pf.json"
echo '{"vmname":"logging","zone0":"mgmt"}' > "${T}/config/logging.json"
kinds="$(CONFIG_DIR="${T}/config"; for m in tappaas1 network pf site1; do printf '%s=%s ' "$m" "$(CONFIG_DIR="${T}/config" log_shipping_syslog_kind "$m")"; done)"
[[ "${kinds}" == "tappaas1=node network=opnsense pf= site1= " ]] && ok || no "syslog kinds: ${kinds}"
conf="$(CONFIG_DIR="${T}/config" _ls_rsyslog_conf "$(CONFIG_DIR="${T}/config" _ls_syslog_target)")"
grep -q 'target="logging.mgmt.internal"' <<<"${conf}" && grep -q 'port="1515"' <<<"${conf}" && ok || no "the rsyslog forwarder does not name logging:1515"
apply_log_shipping_node 'bad;node' >/dev/null 2>&1 && no "a bad node name was accepted" || ok

_ls_guest_root 'lxc:tappaas2:63x;rm' </dev/null >/dev/null 2>&1 && no "a bad transport was accepted" || ok
_ls_guest_root 'ftp:host' </dev/null >/dev/null 2>&1 && no "an unknown transport was accepted" || ok

# ── TLS (#787): the TLS ports once logging serves them, the plain ones until then ──
[[ "$(_LS_TLS=1 log_shipping_push_url)" == "https://logging.mgmt.internal:3111/loki/api/v1/push" ]] && ok || no "TLS ready: push to :3111"
[[ "$(_LS_TLS=1 log_shipping_query_url)" == "https://logging.mgmt.internal:3110" ]] && ok || no "TLS ready: query :3110"
[[ "$(_LS_TLS=0 log_shipping_push_url)" == "http://logging.mgmt.internal:3101/loki/api/v1/push" ]] && ok || no "TLS not ready: push stays on :3101"
[[ "$(_LS_TLS=1 LOG_SHIPPING_PUSH_URL=http://x:1/p log_shipping_push_url)" == "http://x:1/p" ]] && ok || no "an override wins"
_ls_rsyslog_conf logging.mgmt.internal tls | grep -c 'port="6515"' >/dev/null && _ls_rsyslog_conf logging.mgmt.internal tls | grep -c 'StreamDriverPermittedPeers="logging.mgmt.internal"' >/dev/null && ok || no "a node's TLS forwarder: :6515, logging's name checked"
_ls_rsyslog_conf logging.mgmt.internal | grep -c 'port="1515"' >/dev/null && ! _ls_rsyslog_conf logging.mgmt.internal | grep -c StreamDriver >/dev/null && ok || no "…and the plain one unchanged"
_LS_TLS=1 render_logging_alloy web dmz "x" | grep -c 'url = "https://logging.mgmt.internal:3111/loki/api/v1/push"' >/dev/null && ok || no "the rendered client pushes over TLS once it is ready"

echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
