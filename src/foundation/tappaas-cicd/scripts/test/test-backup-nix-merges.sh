#!/usr/bin/env bash
#
# test-backup-nix-merges.sh — what backup:filesystem generates must MERGE with
# the configuration that imports it.
#
# backup:filesystem writes /etc/nixos/tappaas-backup.nix. tappaas-cicd.nix (the
# mothership) and templates/tappaas-common.nix (every other guest) declare the
# unit it schedules, and import that file. Two definitions of one option at the
# same priority is not a merge — it is
#
#   error: The option `…' has conflicting definition values
#
# and nixos-rebuild then evaluates nothing at all. The mothership rebuilds
# itself FIRST (ADR-017 D3), so such a file stops the whole sweep before one
# module is updated, on every site, every run. It happened twice in one evening:
# the generated file declared the service (clash on its description), and then
# declared the whole timer (clash on the timer's description).
#
# The invariant, which is what this checks:
#
#   every attribute the generated file sets must be one the importing
#   configurations either do not declare, or declare with lib.mkDefault.
#
# Checked against both importers, because they disagree: RandomizedDelaySec is
# mkDefault in tappaas-common.nix and PLAIN in tappaas-cicd.nix, so an attribute
# that is safe for every guest can still break the mothership alone.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION="$(cd "${HERE}/../../.." && pwd)"
GEN="${FOUNDATION}/backup/lib/pbs-fs.sh"
IMPORTERS=("${FOUNDATION}/tappaas-cicd/tappaas-cicd.nix" "${FOUNDATION}/templates/tappaas-common.nix")

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${GEN}" ]] || { echo "pbs-fs.sh not found — cannot run here."; exit 77; }

# The generated template, as the heredoc in pbs_fs_install_timer_nix writes it.
TMPL="$(sed -n '/^# tappaas-backup.nix — GENERATED/,/^EOF$/p' "${GEN}" | sed '$d')"
[[ -n "${TMPL}" ]] || { echo "  FAIL: could not read the generated template"; exit 1; }
ck "the generated template is readable" "yes" "yes"

# Every attribute it assigns, e.g. `OnCalendar = "20:04";` → OnCalendar.
mapfile -t ATTRS < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' <<< "${TMPL}" \
                     | sed 's/[[:space:]]*=$//' | sort -u)
# `lib` comes from the module header `{ lib, ... }:`, not from an assignment.
mapfile -t ATTRS < <(printf '%s\n' "${ATTRS[@]}" | grep -vx 'lib' || true)

if [[ "${#ATTRS[@]}" -eq 0 ]]; then
    ck "it sets at least one attribute" "yes" "no"
else
    echo "  (generated file sets: ${ATTRS[*]})"
fi

# The unit block each importer declares: from the service to the end of the
# timer's timerConfig. That is the region whose attributes can collide.
unit_block() {
    awk '/systemd\.services\.tappaas-fs-backup/{f=1}
         f{print}
         f&&/^  systemd\.timers\.tappaas-fs-backup/{t=1}
         t&&/^  };$/{print; exit}' "$1"
}

for imp in "${IMPORTERS[@]}"; do
    name="$(basename "${imp}")"
    block="$(unit_block "${imp}")"
    if [[ -z "${block}" ]]; then
        ck "${name}: declares the tappaas-fs-backup unit" "yes" "no"
        continue
    fi
    for attr in "${ATTRS[@]}"; do
        # How does this importer define the same attribute?
        line="$(grep -E "^[[:space:]]*${attr}[[:space:]]*=" <<< "${block}" | head -1)"
        if [[ -z "${line}" ]]; then
            ck "${name}: '${attr}' is not declared there — safe to set" "safe" "safe"
        elif [[ "${line}" == *"mkDefault"* ]]; then
            ck "${name}: '${attr}' is mkDefault there — safe to override" "safe" "safe"
        else
            ck "${name}: '${attr}' would collide (declared plainly there)" "safe" "COLLIDES"
            echo "      ${name}: ${line#"${line%%[![:space:]]*}"}"
        fi
    done
done

# The two shapes that actually broke it, named so a regression says why.
ck "the generated file declares no service"  "0" "$(grep -c 'systemd.services' <<< "${TMPL}")"
ck "…and no description of its own"          "0" "$(grep -c 'description[[:space:]]*=' <<< "${TMPL}")"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
