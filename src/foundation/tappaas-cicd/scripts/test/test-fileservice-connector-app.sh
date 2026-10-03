#!/usr/bin/env bash
#
# test-fileservice-connector-app.sh — nextcloud:fileservice meets a Nextcloud on
# either connector app (#743).
#
# Connector v11 renamed the Nextcloud app from `onlyoffice` to `eurooffice`. The
# fileservice scripts arrive with the repository, the app only with Nextcloud's
# own update — so a manual `reconcile euro-office`, or a sweep whose Nextcloud
# update rolled back, meets a guest still on v10. The verifier read `eurooffice`
# only (a false "not set up"), and the converge restarted a unit v10 does not
# have (failing, and rolling euro-office back). Blocks run against a stubbed ssh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS="$(readlink -f "${HERE}/../../../../collaboration/nextcloud/services/fileservice")"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${FS}/connector-app.sh" ]] || { echo "connector-app.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fsapp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# app <rows the database returns, \n-separated | UNREACHABLE> — what the helper says
app() {
    ROWS="$1" bash -c '
        ssh() { [[ "${ROWS}" == UNREACHABLE ]] && return 255; printf "%b" "${ROWS}"; }
        . "'"${FS}"'/connector-app.sh"
        fileservice_connector_app nextcloud.rossen.internal'
}

echo "── which connector app Nextcloud runs ──"
ck "v11: eurooffice"                                  "eurooffice" "$(app 'eurooffice\n')"
ck "v10: onlyoffice"                                  "onlyoffice" "$(app 'onlyoffice\n')"
ck "both enabled (mid-migration): the release's wins" "eurooffice" "$(app 'onlyoffice\neurooffice\n')"
ck "neither enabled: nothing"                         ""           "$(app '')"
ck "the VM cannot be asked: nothing, not a guess"     ""           "$(app UNREACHABLE)"
ckin "an app enabled for groups counts as enabled"    "configvalue <> 'no'" "$(cat "${FS}/connector-app.sh")"

echo "── the verifier reads the settings under the app it found ──"
V="${FS}/test-service.sh"
ck "no query hard-codes the app ID"                   "0" "$(grep -c "appid='eurooffice'" "${V}")"
ck "both settings are read under \${APPID}"          "2" "$(grep -c "appid='\${APPID}'" "${V}")"
awk '/APPID="\$\(fileservice_connector_app/{f=1} f{print} f&&/^    fi$/{exit}' "${V}" > "${TMP}/verify.sh"
verify() {
    APP="$1" bash -c '
        fileservice_connector_app() { echo "${APP}"; }
        FILESERVICE_V10_HINT="update Nextcloud first"
        warn() { echo "WARN $*"; }; fail() { echo "FAIL $*"; }
        VMNAME=nextcloud ZONE=rossen
        '"$(cat "${TMP}/verify.sh")"'
        echo "APPID=${APPID}"'
}
out="$(verify eurooffice)"
ck "v11: settings under eurooffice"                 "APPID=eurooffice" "$(tail -1 <<< "${out}")"
ck "  …no warning"                                     "0" "$(grep -c -E 'WARN|FAIL' <<< "${out}")"
out="$(verify onlyoffice)"
ck "v10: settings under onlyoffice"                   "APPID=onlyoffice" "$(tail -1 <<< "${out}")"
ck "  …passes, with the way forward named"            "1|0" "$(grep -c 'WARN.*update Nextcloud first' <<< "${out}")|$(grep -c FAIL <<< "${out}")"
out="$(verify '')"
ck "no connector app: a real failure"                 "1" "$(grep -c 'FAIL No document-server connector app' <<< "${out}")"

echo "── the converge skips v11 wiring on a v10 Nextcloud ──"
U="${FS}/update-service.sh"
awk '/^    if \[\[ -z "\$\{JWT_SECRET\}" \]\]; then$/{f=1} f{print} f&&/FILESERVICE_V10_HINT/{exit}' "${U}" > "${TMP}/converge.sh"
converge() {
    JWT="$1" APP="$2" bash -c '
        warn() { echo "WARN $*"; }
        FILESERVICE_V10_HINT="update Nextcloud first" MODULE=euro-office EO_HOST=euro-office.srv.internal
        JWT_SECRET="${JWT}" CONNECTOR_APP="${APP}"
        '"$(cat "${TMP}/converge.sh")"'
        else echo WIRED; fi'
}
ck "v11: wires the connector"                         "WIRED" "$(converge secret eurooffice)"
ckin "v10: skips it, naming the way forward"          "update Nextcloud first — connector re-wiring for euro-office skipped" "$(converge secret onlyoffice)"
ck "  …and does not touch the v11 unit"               "0" "$(converge secret onlyoffice | grep -c WIRED)"
ckin "no JWT yet: unchanged behaviour"                "JWT not available yet" "$(converge '' eurooffice)"
ckin "the helper runs before the restart it guards"   "fileservice_connector_app" \
     "$(awk '/CONNECTOR_APP=/{print; exit}' "${U}")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
