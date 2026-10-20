#!/usr/bin/env bash
# controller-shim.sh — a controller from a file of plugin_* functions (ADR-035 D4).
#
# The switch and AP controllers written in bash keep their vendor logic as a
# file of plugin_* functions (unifi.sh, the built-in manual one); this turns such
# a file into an executable answering the switch/1 and ap/1 verbs, so a manager
# only ever runs a controller and never sources one. A controller in any other
# language answers the same verbs itself.
#
# Usage: controller-shim.sh --plugin FILE [--contract FILE] <verb> [options]
#
#   describe                                   the controller's facts (JSON)
#   supports <vendor>                          exit 0 if it drives <vendor>, 3 if not
#   check-access   --ip IP                     can it log in (JSON); 3 if it cannot tell
#   interrogate    --ip IP --controller NAME   (arch controller) every device it adopts
#   interrogate    --ip IP --switch NAME       (arch device) that switch
#   apply          --switch NAME [--desired FILE] [--changes-json JSON]
#   ap-interrogate --ap NAME --ip IP
#   ap-apply       --ap NAME [--changes-json JSON]
#   mlag-status    --switch NAME --ip IP        (the mlag capability)
#
# Common options: --credentials FILE, --session DIR, --config-dir DIR, --debug.
# JSON on stdout only; the plugin's own messages go to stderr. Exit: the
# plugin's own code for apply (a manual controller prints the steps and returns
# non-zero), 0/1 otherwise; 2 bad usage; 3 not this controller's.

set -uo pipefail

plugin=""; contract=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plugin) plugin="$2"; shift 2 ;;
        --contract) contract="$2"; shift 2 ;;
        *) break ;;
    esac
done
[[ -r "${plugin}" ]] || { echo "controller-shim: no plugin file '${plugin}'" >&2; exit 2; }
[[ -z "${contract}" && -r "$(dirname "${plugin}")/contract.json" ]] && contract="$(dirname "${plugin}")/contract.json"

verb="${1:-}"; [[ $# -gt 0 ]] && shift
ip=""; sw=""; ctl=""; ap=""; desired=""; changes="{}"; arg=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip) ip="$2"; shift 2 ;;
        --switch) sw="$2"; shift 2 ;;
        --controller) ctl="$2"; shift 2 ;;
        --ap) ap="$2"; shift 2 ;;
        --desired) desired="$2"; shift 2 ;;
        --changes-json) changes="$2"; shift 2 ;;
        --credentials) export CONTROLLER_CREDENTIALS="$2"; shift 2 ;;
        --session) export CONTROLLER_SESSION="$2" UNIFI_SESSION="$2"; shift 2 ;;
        --config-dir) export CONFIG_DIR="$2"; shift 2 ;;
        --debug) export TAPPAAS_DEBUG=1; shift ;;
        --check) echo "controller-shim: --check is not supported by $(basename "${plugin}")" >&2; exit 3 ;;
        -*) echo "controller-shim: unknown option $1" >&2; exit 2 ;;
        *) arg="$1"; shift ;;
    esac
done

# The manager's logging, so a plugin's messages read as they did when it ran
# inside the manager (info/warn on the terminal, the colours).
# shellcheck disable=SC1091
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null || true
# shellcheck disable=SC1090
. "${plugin}"
has() { declare -F "$1" >/dev/null; }

case "${verb}" in
    describe)
        arch="device"; has plugin_arch && arch="$(plugin_arch)"
        module=""; has plugin_controller_module && module="$(plugin_controller_module)"
        vendors="[]"; has plugin_vendors && vendors="$(plugin_vendors | jq -Rsc 'split("\n") | map(select(. != ""))')"
        caps='["vlans"]'
        has plugin_controller_interrogate && caps="$(jq -c '. + ["controller"]' <<<"${caps}")"
        has plugin_ap_interrogate && caps="$(jq -c '. + ["ap"]' <<<"${caps}")"
        has plugin_mlag_status && caps="$(jq -c '. + ["mlag"]' <<<"${caps}")"
        has plugin_capabilities && caps="$(plugin_capabilities | jq -Rsc 'split("\n") | map(select(. != ""))')"
        base='{}'; [[ -n "${contract}" ]] && base="$(jq -c . "${contract}" 2>/dev/null || echo '{}')"
        jq -n --argjson b "${base}" --arg arch "${arch}" --arg module "${module}" --argjson v "${vendors}" --argjson c "${caps}" \
            --arg plugin "${plugin}" '
            { contracts: ["switch/1", "ap/1"], vendors: $v, arch: $arch,
              module: (if $module == "" then null else $module end), capabilities: $c, implementation: $plugin } + $b'
        ;;
    supports)
        [[ -n "${arg}" ]] || { echo "controller-shim: supports <vendor>" >&2; exit 2; }
        has plugin_supports && plugin_supports "${arg}" "" >/dev/null 2>&1 && exit 0
        exit 3
        ;;
    check-access)
        has plugin_check_access || exit 3
        plugin_check_access "${ip}"
        ;;
    interrogate)
        if [[ -n "${ctl}" ]]; then
            has plugin_controller_interrogate || { echo "controller-shim: $(basename "${plugin}") adopts no devices (arch device)" >&2; exit 3; }
            plugin_controller_interrogate "${ctl}" "${ip}"
        elif [[ -n "${sw}" ]]; then
            has plugin_interrogate || exit 3
            out="$(plugin_interrogate "${sw}" "${ip}")" || exit $?
            jq -c --arg n "${sw}" '{switches: {($n): .}}' <<<"${out}"
        else
            echo "controller-shim: interrogate needs --controller or --switch" >&2; exit 2
        fi
        ;;
    apply)
        [[ -n "${sw}" ]] || { echo "controller-shim: apply needs --switch" >&2; exit 2; }
        has plugin_apply || exit 3
        rc=0
        if [[ -n "${desired}" ]]; then
            SWITCH_DESIRED="${desired}" plugin_apply "${sw}" "${changes}" 1>&2 || rc=$?
        else
            plugin_apply "${sw}" "${changes}" 1>&2 || rc=$?
        fi
        jq -nc --arg s "${sw}" --argjson rc "${rc}" '{switch: $s, ok: ($rc == 0)}'
        exit "${rc}"
        ;;
    ap-interrogate)
        has plugin_ap_interrogate || exit 3
        plugin_ap_interrogate "${ap}" "${ip}"
        ;;
    ap-apply)
        has plugin_ap_apply || exit 3
        rc=0
        plugin_ap_apply "${ap}" "${changes}" 1>&2 || rc=$?
        jq -nc --arg a "${ap}" --argjson rc "${rc}" '{ap: $a, ok: ($rc == 0)}'
        exit "${rc}"
        ;;
    mlag-status)
        has plugin_mlag_status || exit 3
        plugin_mlag_status "${sw}" "${ip}"
        ;;
    ""|--help|-h)
        sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "controller-shim: unknown verb '${verb}'" >&2; exit 2 ;;
esac
