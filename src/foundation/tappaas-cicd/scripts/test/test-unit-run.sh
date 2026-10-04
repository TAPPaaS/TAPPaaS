#!/usr/bin/env bash
#
# test-unit-run.sh — tappaas-unit-run.sh builds the unit's context from the live
# unit (#767). Offline: systemctl is stubbed, the command is printed, not run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UR="${HERE}/../tappaas-unit-run.sh"
PASS=0; FAIL=0
ck() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }
no() { if [[ "$3" != *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (unexpected '$2')"; FAIL=$((FAIL+1)); fi; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

stub() {  # $1 = NoNewPrivileges, $2 = ProtectSystem, $3 = ReadWritePaths
    cat > "${T}/systemctl" <<S
#!/usr/bin/env bash
case "\$4" in
  User) echo tappaas ;;
  Environment) echo "PATH=/home/tappaas/bin:/run/current-system/sw/bin LANG=C" ;;
  NoNewPrivileges) echo "$1" ;;
  PrivateTmp) echo no ;;
  ProtectSystem) echo "$2" ;;
  ReadWritePaths) echo "$3" ;;
esac
S
    chmod +x "${T}/systemctl"
}
run() { TAPPAAS_SYSTEMCTL="${T}/systemctl" bash "${UR}" --print "$@"; }

stub no no ""
OUT="$(run -- module-manager list)"
ck "runs as the unit's user"                          "User=tappaas"            "${OUT}"
ck "with the unit's environment"                      "Environment=PATH=/home/tappaas/bin:/run/current-system/sw/bin" "${OUT}"
ck "…every variable of it"                            "Environment=LANG=C"      "${OUT}"
ck "through a login shell, as the unit's steps run"   "bash -l -c"              "${OUT}"
ck "the command itself"                               "module-manager\\ list"   "${OUT}"
ck "as a systemd service: no terminal, no agent"      "systemd-run --quiet --wait --pipe --collect" "${OUT}"
no "an aligned unit adds no sandbox"                  "NoNewPrivileges"         "${OUT}"
OUT="$(run --root -- tappaas-selfcheck.sh)"
ck "--root: sudo -n inside that context, as the root steps" "/run/wrappers/bin/sudo\\ -n\\ tappaas-selfcheck.sh" "${OUT}"
stub yes strict "/home/tappaas/config /etc/secrets/backup-fs"
OUT="$(run -- true)"
ck "a hardened unit's NoNewPrivileges is reproduced" "NoNewPrivileges=yes" "${OUT}"
ck "…and ProtectSystem"                              "ProtectSystem=strict" "${OUT}"
ck "…and each ReadWritePaths entry"                  "ReadWritePaths=/etc/secrets/backup-fs" "${OUT}"
cat > "${T}/systemctl" <<'S'
#!/usr/bin/env bash
exit 1
S
TAPPAAS_SYSTEMCTL="${T}/systemctl" bash "${UR}" -- true >/dev/null 2>&1; ck "an unreadable unit: exit 2" "2" "$?"
bash "${UR}" >/dev/null 2>&1; ck "no command: exit 2" "2" "$?"

echo "── unit-run: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
