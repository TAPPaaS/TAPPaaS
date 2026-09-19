#!/usr/bin/env bash
#
# Unit tests for the PBS's DNS name (ADR-012 §2.7, #612) — pbs-dns.sh. The
# firewall is replaced by a dns-manager stub that records every call and
# answers `list` from a file, so the test asserts WHAT is asked and in which
# order: the legacy A record goes before the alias is added, a machine Host
# gets an entry first, and nothing is asked when the name is already right.
#
# Usage: ./test-pbs-dns.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info() { :; }; warn() { echo "warn: $*" >&2; }; debug() { :; }
export GN="" CL=""   # read by the sourced library

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pbsdns.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export CONFIG_DIR="${TMP}/config"; mkdir -p "${CONFIG_DIR}"
CALLS="${TMP}/calls"; LIST="${TMP}/list"; ALIASES="${TMP}/aliases"; : > "${ALIASES}"

NO_ALIAS_VERB=0; ALIAS_FAILS=0
dns-manager() {
    shift   # --no-ssl-verify
    case "$1" in
        list) cat "${LIST}" ;;
        alias)
            [[ "${NO_ALIAS_VERB}" == 1 ]] && return 2
            [[ "$2" == list ]] && { cat "${ALIASES}"; return 0; }
            echo "$*" >> "${CALLS}"; [[ "${ALIAS_FAILS}" == 1 ]] && return 1; return 0 ;;
        *) echo "$*" >> "${CALLS}" ;;
    esac
}

# shellcheck source=pbs-dns.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-dns.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
calls() { tr '\n' '|' < "${CALLS}" 2>/dev/null | sed 's/|$//'; }
reset() { : > "${CALLS}"; : > "${ALIASES}"; printf '%s\n' "$@" > "${LIST}"; }

ck "name: <instance>.<zone>.internal"   backup.mgmt.internal "$(pbs_dns_name backup mgmt)"
ck "name: a second instance"            pbs2.mgmt.internal   "$(pbs_dns_name pbs2 mgmt)"
ck "instance: default backup"           backup               "$(pbs_instance "")"
ck "instance: the argument"             pbs2                 "$(pbs_instance pbs2)"

# A pre-#612 install: backup is an A record, the node has its entry.
reset "Found 2 DNS host entries:" "  tappaas3.mgmt.internal  -> 10.0.0.12  (TAPPaaS node tappaas3)" "  backup.mgmt.internal  -> 10.0.0.12  (PBS Backup Server)"
pbs_dns_ensure backup mgmt tappaas3; rc=$?
ck "migrate: succeeds"                  0 "${rc}"
ck "migrate: A record deleted, THEN the alias added" \
   "delete backup mgmt.internal|alias add backup.mgmt.internal tappaas3 mgmt.internal" "$(calls)"

# Already an alias (no A record): only the idempotent alias call.
reset "  tappaas3.mgmt.internal  -> 10.0.0.12  (TAPPaaS node tappaas3)"
pbs_dns_ensure backup mgmt tappaas3
ck "steady state: just the (idempotent) alias" "alias add backup.mgmt.internal tappaas3 mgmt.internal" "$(calls)"

# A debianhost Host with no DNS entry gets one from its address first.
reset "  tappaas1.mgmt.internal  -> 10.0.0.10  ()"
echo '{"kind":"machine","address":"10.0.0.90"}' > "${CONFIG_DIR}/dh-test1.json"
pbs_dns_ensure backup mgmt dh-test1
ck "machine Host: its entry, then the alias" \
   "add dh-test1 mgmt.internal 10.0.0.90 --description TAPPaaS machine dh-test1|alias add backup.mgmt.internal dh-test1 mgmt.internal" "$(calls)"

# A Host with neither an entry nor an address: refused, nothing asked.
reset "  tappaas1.mgmt.internal  -> 10.0.0.10  ()"
pbs_dns_ensure backup mgmt ghost 2>/dev/null; rc=$?
ck "unknown Host: refused"               1 "${rc}"
ck "…and nothing is changed"            "" "$(calls)"

# An old dns-manager without the alias verb: the A record is NOT touched.
reset "  tappaas3.mgmt.internal  -> 10.0.0.12  ()" "  backup.mgmt.internal  -> 10.0.0.12  (PBS Backup Server)"
NO_ALIAS_VERB=1; pbs_dns_ensure backup mgmt tappaas3 2>/dev/null; rc=$?; NO_ALIAS_VERB=0
ck "no alias verb: refused"             1 "${rc}"
ck "…and the A record is left alone (found live on hrossen)" "" "$(calls)"

# The alias add fails after the delete: the A record is put back.
reset "  tappaas3.mgmt.internal  -> 10.0.0.12  ()" "  backup.mgmt.internal  -> 10.0.0.12  (PBS Backup Server)"
ALIAS_FAILS=1; pbs_dns_ensure backup mgmt tappaas3 2>/dev/null; rc=$?; ALIAS_FAILS=0
ck "alias add fails: reported"          1 "${rc}"
ck "…and the A record is restored" \
   "delete backup mgmt.internal|alias add backup.mgmt.internal tappaas3 mgmt.internal|add backup mgmt.internal 10.0.0.12 --description PBS Backup Server" "$(calls)"

pbs_dns_ensure backup mgmt "" 2>/dev/null; rc=$?
ck "no Host at all (shim/external): refused" 1 "${rc}"

# #672: the PBS moves from a machine to a cluster node — the machine's Host
# entry is released (the guarded verb decides whether it is ours to remove).
reset "  tappaas3.mgmt.internal  -> 10.0.0.12  ()" "  dh-test1.mgmt.internal  -> 10.0.0.90  (TAPPaaS machine dh-test1)"
echo "  backup.mgmt.internal  -> dh-test1.mgmt.internal" > "${ALIASES}"
pbs_dns_ensure backup mgmt tappaas3
ck "move: the alias moves, THEN the old Host is released" \
   "alias add backup.mgmt.internal tappaas3 mgmt.internal|release dh-test1 mgmt.internal" "$(calls)"

# Staying on the same Host releases nothing.
reset "  tappaas3.mgmt.internal  -> 10.0.0.12  ()"
echo "  backup.mgmt.internal  -> tappaas3.mgmt.internal" > "${ALIASES}"
pbs_dns_ensure backup mgmt tappaas3
ck "no move: nothing released" "alias add backup.mgmt.internal tappaas3 mgmt.internal" "$(calls)"

# A failed move releases nothing: the alias still needs the old Host.
reset "  tappaas3.mgmt.internal  -> 10.0.0.12  ()"
echo "  backup.mgmt.internal  -> dh-test1.mgmt.internal" > "${ALIASES}"
ALIAS_FAILS=1; pbs_dns_ensure backup mgmt tappaas3 2>/dev/null; ALIAS_FAILS=0
ck "failed move: the old Host is kept" "alias add backup.mgmt.internal tappaas3 mgmt.internal" "$(calls)"

# pbs_dns_remove (delete.sh): the alias goes, then its Host is released.
reset "  dh-test1.mgmt.internal  -> 10.0.0.90  (TAPPaaS machine dh-test1)"
echo "  pbs2.mgmt.internal  -> dh-test1.mgmt.internal" > "${ALIASES}"
pbs_dns_remove pbs2 mgmt; rc=$?
ck "remove: succeeds"                   0 "${rc}"
ck "remove: alias deleted, THEN its Host released" \
   "alias delete pbs2.mgmt.internal|release dh-test1 mgmt.internal" "$(calls)"

reset "  tappaas3.mgmt.internal  -> 10.0.0.12  ()"
pbs_dns_remove pbs2 mgmt; rc=$?
ck "remove: not an alias → nothing asked" "0:" "${rc}:$(calls)"

echo ""
echo "pbs-dns: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
