#!/usr/bin/env bash
#
# test-coturn-peers.sh — coturn's relay allow-list follows its consumers.
#
# coturn denies relaying to private addresses; coturn_allow_peer records a
# consumer's media server (the HPB's Janus) in /var/lib/coturn/allowed-peers so
# coturn.nix allows exactly that host. coturn_forget_peer is its inverse, run by
# the turn service's delete-service.sh, so a deleted consumer's address does not
# stay reachable through TURN. The remote scripts run here against a temp file
# through a stubbed ssh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(readlink -f "${HERE}/../../../../apps/coturn/services/turn/turn-common.sh")"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${TC}" ]] || { echo "turn-common.sh not found — cannot run here."; exit 77; }

T="$(mktemp -d "${TMPDIR:-/tmp}/coturn-peers.XXXXXX")"
trap 'rm -rf "${T}"' EXIT INT TERM

cat > "${T}/coturn.json" <<'JSON'
{"vmname":"coturn","zone0":"dmz"}
JSON
cat > "${T}/nextcloud-hpb.json" <<'JSON'
{"vmname":"nextcloud-hpb","zone0":"srv"}
JSON
: > "${T}/allowed-peers"; : > "${T}/restarts"

info() { echo "INFO $*"; }; warn() { echo "WARN $*"; }
# shellcheck disable=SC2034  # read by the sourced turn-common.sh
GN="" CL=""
getent() { echo "10.2.0.55 nextcloud-hpb.srv.internal"; }
sleep() { :; }
# The coturn VM: its script runs locally, on the temp allow-list, with sudo and
# systemctl stubbed. UNREACHABLE=1 plays a coturn ssh cannot reach.
ssh() {
    [[ "${UNREACHABLE:-0}" == 1 ]] && return 255
    local s="${*: -1}"
    s="${s//\/var\/lib\/coturn\/allowed-peers/${T}/allowed-peers}"
    T="${T}" bash -c 'sudo() { "$@"; }; systemctl() { echo restart >> "${T}/restarts"; }; '"${s}"
}
# shellcheck source=/dev/null
. "${TC}"
peers() { tr '\n' ';' < "${T}/allowed-peers"; }
restarts() { grep -c restart "${T}/restarts"; }

echo "── allow: one line per consumer, coturn restarted only on a change ──"
coturn_allow_peer "${T}/coturn.json" "${T}/nextcloud-hpb.json" >/dev/null
ck "the HPB is allow-listed"               "nextcloud-hpb 10.2.0.55;" "$(peers)"
coturn_allow_peer "${T}/coturn.json" "${T}/nextcloud-hpb.json" >/dev/null
ck "a repeat changes nothing, no restart"  "1" "$(restarts)"
echo "other 10.2.0.77" >> "${T}/allowed-peers"

echo "── forget: the consumer's line goes, the others stay ──"
out="$(coturn_forget_peer "${T}/coturn.json" nextcloud-hpb)"
ck "the deleted consumer is gone"          "other 10.2.0.77;" "$(peers)"
ck "…coturn restarted to drop it"          "2" "$(restarts)"
ck "…and it says so"                       "yes" "$(grep -q 'no longer relays to nextcloud-hpb' <<< "${out}" && echo yes || echo no)"
out="$(coturn_forget_peer "${T}/coturn.json" nextcloud-hpb)"
ck "forgetting twice is a no-op"           "2" "$(restarts)"
ck "…named as such"                        "yes" "$(grep -q 'had no relay entry' <<< "${out}" && echo yes || echo no)"
UNREACHABLE=1 coturn_forget_peer "${T}/coturn.json" other >/dev/null; rc=$?
ck "an unreachable coturn is a failure, not 'no entry'" "1" "${rc}"
ck "…and the entry is still there"         "other 10.2.0.77;" "$(peers)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
