#!/usr/bin/env bash
#
# test-update-os-activation-settled.sh — an activation exit (2, 4, 6) from
# nixos-rebuild is accepted only when the new generation is active and no unit
# has failed; anything else stays a failure.
#
# A fresh guest's first switch can fail to start systemd-hostnamed.socket while
# its service is still stopping: exit 4, nothing failed afterwards, the new
# system running. update-os.sh died there and the install failed with it.
#
# activation_settled() is lifted out of update-os.sh and run against a stubbed
# ssh; the rebuild loop is checked for calling it on 2, 4 and 6 only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../manager/health-manager/update-os.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-os.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/activation-settled.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

awk '/^activation_settled\(\) \{$/{f=1} f{print} f&&/^}$/{exit}' "${SRC}" > "${TMP}/fn.sh"
ck "activation_settled extracts" "yes" "$(grep -c 'systemctl --failed' "${TMP}/fn.sh" >/dev/null && echo yes || echo no)"

# run <system now|same|none> <failed: a list of per-check answers, e.g. "x.socket,," or "down">
# The n-th systemctl check answers the n-th comma-separated entry ("" = no
# failed unit, "down" = no answer). Prints the exit code and the checks made.
run() {
    NOW="$1" ANSWERS="$2" T="${TMP}" bash -c '
        set -euo pipefail
        : > "${T}/n"
        ssh() {
            case "${*: -1}" in
                "readlink -f /run/current-system")
                    case "${NOW}" in new) echo /nix/store/bbb-nixos-system-guest ;; same) echo /nix/store/aaa-nixos-system-guest ;; none) return 255 ;; esac ;;
                systemctl*)
                    echo x >> "${T}/n"
                    local k a; k="$(wc -l < "${T}/n" | tr -d " ")"
                    a="$(cut -d, -f"${k}" <<<"${ANSWERS}")"
                    [[ "${a}" == down ]] && return 255
                    [[ -n "${a}" ]] && echo "${a}"
                    echo __end__ ;;
            esac
        }
        source "${T}/fn.sh"
        ACTIVATION_SETTLE_SECONDS=0
        rc=0; activation_settled 10.2.0.9 "${BEFORE-/nix/store/aaa-nixos-system-guest}" || rc=$?
        echo "${rc}|$(wc -l < "${T}/n" | tr -d " ")"
    '
}

echo "[1] the new generation is active"
ck "no failed unit: settled, one check" "0|1" "$(run new ",,")"
ck "a unit failed, then none: settled on the second check" "0|2" "$(run new "x.socket,,")"
ck "a unit stays failed: not settled, three checks" "1|3" "$(run new "x.socket,x.socket,x.socket")"
ck "the guest stops answering: not settled" "1|1" "$(run new "down,,")"

echo "[2] the new generation is not active"
ck "the system did not move: not settled, no unit check" "1|0" "$(run same ",,")"
ck "the system cannot be read: not settled" "1|0" "$(run none ",,")"
ck "no system recorded before the switch: not settled" "1|0" "$(BEFORE="" run new ",,")"

echo "[3] the rebuild loop"
loop="$(awk '/for attempt in 1 2 3; do/{f=1} f{print} f&&/^    done$/{exit}' "${SRC}")"
# shellcheck disable=SC2016  # the pattern is update-os.sh's literal text
ck "accepts a settled activation on exit 2, 4 and 6" "yes" \
   "$(grep -c 'rc" -eq 2 || "$rc" -eq 4 || "$rc" -eq 6 ]] && activation_settled' <<<"${loop}" >/dev/null && echo yes || echo no)"
ck "…before the branch that dies on any other exit" "yes" \
   "$(awk '/activation_settled "/{a=NR} /Not retrying/{b=NR} END{print (a && b && a<b) ? "yes" : "no"}' <<<"${loop}")"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
