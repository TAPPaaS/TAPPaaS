#!/usr/bin/env bash
#
# Unit tests for lib/dns-sample.sh — who Standard 4 may hold to a DNS record.
#
# The contract under test:
#   aliasType=network            → excluded (#241/#255), a device set has no host
#   backup shim/external/remote-only → excluded (ADR-012 §2.1), no local host
#   status=archived              → excluded (#631), the VM is gone, the config is not
#   guest not running            → excluded (#631), no guest means no lease
#   no vmid at all               → KEPT; an absence is not evidence of no host
#   runtime unknown              → guest filter skipped, config-only exclusions
#
# The #631 shape: `module delete --archive` is the supported way to retire a
# module and leaves the config with its vmname behind. Standard 4 then failed
# on it forever, and Standard 4 gates `modify network` — so retiring a module
# wedged the site's network updates, reporting `DNS cannot resolve <name>`
# while DNS was entirely correct.
#
# Usage: ./test-dns-sample.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dns-sample.sh disable=SC1091
. "${SCRIPT_DIR}/dns-sample.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
CFG="${TMP}/config"; mkdir -p "${CFG}"
RUN="${TMP}/running"

mod() { # mod <name> <vmid> <extra-jq-object>
    jq -n --arg n "$1" --arg v "$2" --argjson x "${3:-{\}}" \
       '{vmname: $n, vmid: $v} * $x' > "${CFG}/$1.json"
}
selected() { printf '%s' "${DNS_SAMPLE_MODULES}" | tr '\n' ',' | sed 's/,$//'; }

mod app      340                                    # running, ordinary
mod stopped  341                                    # a guest that is simply off
mod gone     342 '{"status":"archived"}'          # module delete --archive
mod devices  343 '{"aliasType":"network"}'          # a set of devices (#241)
mod extpbs   344 '{"placementState":"external"}'    # someone else's PBS
mod shimpbs  345 '{"placementState":"shim"}'        # waiting for storage
mod legacy   346 '{"placementState":"remote-only"}' # the legacy spelling
mod policy   ""                                     # no guest to look up
printf '%s\n' 340 346 > "${RUN}"   # only app (and legacy, which is excluded anyway)

# ── the runtime is known: every category applies ─────────────────────
dns_sample_select "${CFG}" "${RUN}"
ck "selected: only the running, host-bearing modules" "app,policy" "$(selected)"
ck "excluded: aliasType=network"   "1" "${DNS_SAMPLE_N_ALIAS}"
ck "excluded: no local datastore"  "3" "${DNS_SAMPLE_N_HOSTLESS}"
ck "excluded: no running guest"    "2" "${DNS_SAMPLE_N_GUESTLESS}"

# The two halves of that last count, named. Both are #631; only one of them
# can be seen without asking the cluster.
ck "archived module is excluded"   ""  "$(grep -o '\bgone\b' <<<"$(selected)")"
ck "stopped module is excluded"    ""  "$(grep -o '\bstopped\b' <<<"$(selected)")"

# ── the runtime is UNKNOWN: degrade to the wider check, not to none ───
# An unreachable cluster must not silently empty the sample — that is a green
# tick over an unexamined site, which is the failure mode in the other
# direction from #631.
dns_sample_select "${CFG}" ""
ck "runtime unknown: the guest filter is skipped" "app,policy,stopped" "$(selected)"
ck "runtime unknown: archived is still excluded"  "1" "${DNS_SAMPLE_N_GUESTLESS}"
ck "runtime unknown: config exclusions still apply" "1" "${DNS_SAMPLE_N_ALIAS}"

# ── a config with no vmid is KEPT ────────────────────────────────────
# It may be a static host entry that genuinely resolves. Excluding on an
# absence trades a false failure for a silent gap; only the first of those is
# what #631 is about.
dns_sample_select "${CFG}" "${RUN}"
ck "no vmid: kept, not excluded on an absence" "policy" "$(grep -o '\bpolicy\b' <<<"$(selected)")"

# ── nothing installed at all ─────────────────────────────────────────
EMPTY="${TMP}/empty"; mkdir -p "${EMPTY}"
dns_sample_select "${EMPTY}" "${RUN}"
ck "empty config dir: nothing selected" "" "$(selected)"
ck "empty config dir: no exclusions"    "0" "${DNS_SAMPLE_N_GUESTLESS}"

# ── a module whose vmid is not in the running list ───────────────────
printf '%s\n' 999 > "${RUN}"
dns_sample_select "${CFG}" "${RUN}"
ck "nothing running: only the vmid-less module remains" "policy" "$(selected)"

# ── #657: the zone travels with the vmname ───────────────────────────
# The caller used to re-read the config keyed by vmname. For a config file
# named differently from its vmname that read returned nothing, the zone fell
# back to the literal "srvHome", and Standard 4 then failed a name the estate
# never declared.
records() { printf '%s' "${DNS_SAMPLE_RECORDS}" | tr '\n' ',' | sed 's/,$//'; }
VAR="${TMP}/variant"; mkdir -p "${VAR}"
# config FILE name differs from vmname, exactly the #657 case
cat > "${VAR}/pai-EvB.json" <<'JSON'
{ "vmname": "pai", "vmid": 500, "zone0": "srvWork" }
JSON
# Pattern A: the zone is nested under .config."<module>:<service>" (#555 shape)
cat > "${VAR}/nested.json" <<'JSON'
{ "vmname": "nested", "vmid": 501, "config": { "nested:cluster:vm": { "zone0": "iot" } } }
JSON
# declares no zone at all
cat > "${VAR}/nozone.json" <<'JSON'
{ "vmname": "nozone", "vmid": 502 }
JSON
printf '%s\n' 500 501 502 > "${TMP}/run-variant"
dns_sample_select "${VAR}" "${TMP}/run-variant"
ck "#657: the zone comes from the selected config, not a vmname lookup" \
   "pai	srvWork" "$(grep '^pai	' <<<"${DNS_SAMPLE_RECORDS}")"
ck "#657: a Pattern A zone is found by descent" \
   "nested	iot" "$(grep '^nested	' <<<"${DNS_SAMPLE_RECORDS}")"
ck "#657: no zone declared → empty, never the srvHome guess" \
   "nozone	" "$(grep '^nozone' <<<"${DNS_SAMPLE_RECORDS}")"
ck "#657: the vmname list is unchanged for existing callers" \
   "nested,nozone,pai" "$(selected)"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
