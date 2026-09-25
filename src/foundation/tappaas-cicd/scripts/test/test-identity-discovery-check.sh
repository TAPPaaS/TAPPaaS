#!/usr/bin/env bash
#
# test-identity-discovery-check.sh — identity's OIDC discovery check names an ssh
# failure as one, and clears a changed host key before it runs (#738).
#
# After a guest's reboot or rebuild its ssh host key can change. The stale
# known_hosts entry was cleared only before the WRITE step, so the check before it
# ran into accept-new's refusal (ssh exit 255) and died with "add a firewall rule".
# The check block is lifted out of install-service.sh and run against a stubbed ssh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(readlink -f "${HERE}/../../../identity/services/identity/install-service.sh")"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "install-service.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/idcheck.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# From the known_hosts clearing to the end of the check.
awk '/^ssh-keygen -R "\$\{UPSTREAM\}"/{f=1} f{print} f&&/^    die "OIDC discovery URI unreachable/{getline; print; exit}' "${SRC}" > "${TMP}/block.sh"
ck "the check block extracts" "yes" \
   "$(grep -q 'for _attempt in 1 2 3' "${TMP}/block.sh" && grep -q 'firewall rule' "${TMP}/block.sh" && echo yes || echo no)"

# run <ssh exit codes, one per attempt…> — prints "<exit>|<calls in order>"; log in ${TMP}/out.
run() {
    RCS="$*" T="${TMP}" bash -c '
        set -euo pipefail
        : > "${T}/calls"
        info(){ :; }; debug(){ :; }; warn(){ echo "WARN $*"; }
        die(){ echo "DIE $*"; exit 1; }; sleep(){ :; }
        ssh-keygen(){ echo keygen >> "${T}/calls"; }
        ssh(){ echo ssh >> "${T}/calls"; local n rcs=(${RCS}); n=$(grep -c ssh "${T}/calls"); return "${rcs[$((n-1))]:-0}"; }
        UPSTREAM=nextcloud.rossen.internal VMNAME=nextcloud DISCOVERY_URI=https://auth.example/.well-known
        '"$(cat "${TMP}/block.sh")"'
        echo PASSED
    ' > "${TMP}/out" 2>&1
    echo "$?|$(tr '\n' ',' < "${TMP}/calls")"
}

ck "reachable: passes, the host key cleared FIRST"   "0|keygen,ssh," "$(run 0)"
ck "a transient failure, then reachable: passes"     "0|keygen,ssh,ssh," "$(run 7 0)"
ck "ssh itself fails (255): dies"                     "1|keygen,ssh,ssh,ssh," "$(run 255 255 255)"
ckin "  …naming ssh, not the firewall"                "cannot ssh to nextcloud.rossen.internal" "$(cat "${TMP}/out")"
ck "  …and not blaming the firewall"                  "no" "$(grep -q 'firewall rule' "${TMP}/out" && echo yes || echo no)"
ck "curl cannot reach Authentik (7): dies"            "1|keygen,ssh,ssh,ssh," "$(run 7 7 7)"
ckin "  …as unreachable, with curl's exit"            "unreachable from nextcloud.rossen.internal: https://auth.example/.well-known (curl exit 7)" "$(cat "${TMP}/out")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
