#!/usr/bin/env bash
#
# test-nixos-canon.sh — the module template and the NixOS baseline keep the two
# canonical network patterns every TAPPaaS VM relies on (#390).
#
#   C4  NetworkManager owns the network: systemd-networkd and its wait-online
#       are forced off, or both activate and fight over the interfaces.
#   C7  The firewall is declared, not left to the stock commented-out example:
#       every TAPPaaS module states its own, and a module copied from the
#       template must start the same way.
#
# The lint that first flagged these (nixos-canon-lint, NXS-001) lives outside
# this repository, so nothing here stopped them regressing. C4 was fixed with
# #446 on 2026-08-16 without saying so; C7 stayed open until #390 was closed.
# A grep, not an evaluation: the template is a starting point with
# placeholders, not a buildable system.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../../.." && pwd)"
FILES=(
    "${SRC}/apps/00-Template/template.nix"
    "${SRC}/foundation/templates/tappaas-common.nix"
)

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

for f in "${FILES[@]}"; do
    [[ -f "${f}" ]] || { echo "${f#"${SRC}"/} not found — cannot run here."; exit 77; }
done

# Only live lines count: a pattern that exists only in a comment is the defect.
live() { sed -E 's/#.*$//' "$1"; }

for f in "${FILES[@]}"; do
    name="${f#"${SRC}"/}"
    echo "── ${name} ──"
    ck "C4: systemd-networkd is forced off" "yes" \
       "$(live "$f" | grep -qE 'systemd\.network\.enable[[:space:]]*=[[:space:]]*lib\.mkForce false' && echo yes || echo no)"
    ck "C4: systemd-networkd wait-online is forced off" "yes" \
       "$(live "$f" | grep -qE 'systemd\.network\.wait-online\.enable[[:space:]]*=[[:space:]]*lib\.mkForce false' && echo yes || echo no)"
    ck "C4: NetworkManager is the network owner" "yes" \
       "$(live "$f" | grep -qE 'networking\.networkmanager\.enable[[:space:]]*=[[:space:]]*true' && echo yes || echo no)"
    ck "C7: the firewall is declared, not only commented" "yes" \
       "$(live "$f" | grep -qE 'networking\.firewall' && echo yes || echo no)"
    ck "C7: it is enabled" "yes" \
       "$(live "$f" | tr '\n' ' ' | grep -qE 'networking\.firewall[[:space:]]*=[[:space:]]*\{[^}]*enable[[:space:]]*=[[:space:]]*(lib\.mkDefault[[:space:]]+)?true|networking\.firewall\.enable[[:space:]]*=[[:space:]]*(lib\.mkDefault[[:space:]]+)?true' && echo yes || echo no)"
    ck "C7: SSH (22) is opened explicitly" "yes" \
       "$(live "$f" | tr '\n' ' ' | grep -qE 'allowedTCPPorts[[:space:]]*=[[:space:]]*\[[^]]*\b22\b' && echo yes || echo no)"
done

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
