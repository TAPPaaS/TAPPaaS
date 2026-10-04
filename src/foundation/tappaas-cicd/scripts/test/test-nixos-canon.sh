#!/usr/bin/env bash
#
# test-nixos-canon.sh — the module template and the NixOS baseline keep the two
# canonical network patterns every TAPPaaS VM relies on (#390, #448).
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
# placeholders, not a buildable system. (scripts/nixos-baseline-eval.sh is the
# evaluation, on the mothership.)
#
# Since #324 the baseline is where C4 lives: the module template, and every
# module, import it and must not restate it — a copy drifts (no app VM got
# #323, #448 or #626 while each carried its own) and a copy with another value
# fails the build.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../../.." && pwd)"
FILES=(
    "${SRC}/misc/00-Template/template.nix"
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
    if [[ "${f}" == */tappaas-common.nix ]]; then
    ck "C4: systemd-networkd is forced off" "yes" \
       "$(live "$f" | grep -qE 'systemd\.network\.enable[[:space:]]*=[[:space:]]*lib\.mkForce false' && echo yes || echo no)"
    ck "C4: systemd-networkd wait-online is forced off" "yes" \
       "$(live "$f" | grep -qE 'systemd\.network\.wait-online\.enable[[:space:]]*=[[:space:]]*lib\.mkForce false' && echo yes || echo no)"
    ck "C4: NetworkManager is the network owner" "yes" \
       "$(live "$f" | grep -qE 'networking\.networkmanager\.enable[[:space:]]*=[[:space:]]*true' && echo yes || echo no)"
    fi
    ck "C7: the firewall is declared, not only commented" "yes" \
       "$(live "$f" | grep -qE 'networking\.firewall' && echo yes || echo no)"
    ck "C7: it is enabled" "yes" \
       "$(live "$f" | tr '\n' ' ' | grep -qE 'networking\.firewall[[:space:]]*=[[:space:]]*\{[^}]*enable[[:space:]]*=[[:space:]]*(lib\.mkDefault[[:space:]]+)?true|networking\.firewall\.enable[[:space:]]*=[[:space:]]*(lib\.mkDefault[[:space:]]+)?true' && echo yes || echo no)"
    ck "C7: SSH (22) is opened explicitly" "yes" \
       "$(live "$f" | tr '\n' ' ' | grep -qE 'allowedTCPPorts[[:space:]]*=[[:space:]]*\[[^]]*\b22\b' && echo yes || echo no)"
done

# #324: every module NixOS config imports the baseline and restates none of it.
# The options below are the baseline's alone; a module that sets one is
# carrying a copy. (Module-specific values the baseline yields to — stateVersion,
# the SSH lockdown, a gc cadence, extra groups and packages — are not listed.)
BASELINE_ONLY='security\.sudo\.wheelNeedsPassword|services\.cloud-init|nix\.settings\.(trusted-users|experimental-features)|services\.qemuGuest|programs\.ssh\.startAgent|nixpkgs\.config\.allowUnfree|boot\.growPartition|boot\.loader\.(systemd-boot|efi)|systemd\.network\.|networking\.networkmanager|serial-getty@ttyS0|zramSwap|systemd\.oomd|time\.timeZone|users\.users\.tappaas[[:space:]]*='
echo "── every module NixOS config: imports the baseline, restates none of it (#324) ──"
while IFS= read -r f; do
    name="${f#"${SRC}"/}"
    ck "${name} imports the baseline" "yes" \
       "$( (( $(live "$f" | grep -c '/etc/nixos/tappaas-common\.nix') > 0 )) && echo yes || echo no)"
    ck "${name} restates none of it" "" \
       "$(live "$f" | grep -oE "${BASELINE_ONLY}" | sort -u | paste -sd, -)"
done < <(grep -rl --include='*.nix' 'system\.stateVersion' "${SRC}" \
           | grep -v -e '/foundation/templates/' -e '/flake\.nix$' -e '/foundation/tappaas-cicd/tappaas-cicd\.nix$' | sort)

# #448: the baseline turns cloud-init's network stage off, so it cannot rename
# the NIC under NetworkManager. The template follows once modules import the
# baseline (#324); until then this is the baseline's own guarantee.
echo "── foundation/templates/tappaas-common.nix: cloud-init ──"
ck "cloud-init's network stage is disabled (#448)" "yes" \
   "$(live "${SRC}/foundation/templates/tappaas-common.nix" | grep -qE 'network\.config[[:space:]]*=[[:space:]]*"disabled"' && echo yes || echo no)"

# #324: a module importing the baseline states these itself, with another
# value — the baseline's must yield, or every such module fails to evaluate.
echo "── foundation/templates/tappaas-common.nix: values a module overrides (#324) ──"
for opt in 'system\.stateVersion' 'PasswordAuthentication' 'PermitRootLogin'; do
    ck "${opt//\\/} yields to the module (mkDefault)" "yes" \
       "$(live "${SRC}/foundation/templates/tappaas-common.nix" | grep -qE "${opt}[[:space:]]*=[[:space:]]*lib\.mkDefault " && echo yes || echo no)"
done
ck "networking.hostName yields even to a module's mkDefault" "yes" \
   "$(live "${SRC}/foundation/templates/tappaas-common.nix" | grep -qE 'networking\.hostName[[:space:]]*=[[:space:]]*lib\.mkOptionDefault ' && echo yes || echo no)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
