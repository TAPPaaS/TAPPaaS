#!/usr/bin/env bash
#
# test-nixos-update-service-cwd.sh — templates:nixos update-service.sh runs
# update-os.sh from the module's directory, whoever calls it (#861).
#
# update-os.sh reads the module's build-facts.sh relative to its working
# directory (#797). reconcile and update-module.sh run update-service.sh from
# the module directory; a bare run from elsewhere skipped the collector and the
# guest built from a stale facts file. The template now resolves the directory
# from the deployed config (get_module_dir) and cds there, and refuses a module
# whose directory it cannot resolve. The template is run with its library and
# update-os.sh stubbed; the stub reports where it was called from.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../../templates/services/nixos/update-service.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "templates/services/nixos/update-service.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nixos-update-cwd.XXXXXX")"
TMP="$(cd "${TMP}" && pwd -P)"   # as pwd prints it (macOS TMPDIR ends in /)
trap 'rm -rf "${TMP}"' EXIT INT TERM
mkdir -p "${TMP}/modules/identity" "${TMP}/elsewhere"

# The library: what the template reads from it. get_module_dir keeps the real
# contract — 0 + path, 1 unresolvable, 2 + path when the recorded dir is gone.
cat > "${TMP}/lib.sh" <<EOF
error() { echo "error: \$*" >> "${TMP}/out"; }
get_config_value() { case "\$1" in vmname) echo identity ;; vmid) echo 9 ;; node) echo node0 ;; esac; }
get_node_hostname() { echo node0; }
get_module_dir() {
    case "\$1" in
        identity) echo "${TMP}/modules/identity" ;;
        orphan)   return 1 ;;
        moved)    echo "${TMP}/modules/moved"; return 2 ;;
    esac
}
EOF
cat > "${TMP}/update-os.sh" <<EOF
#!/usr/bin/env bash
echo "update-os from \$(pwd) for \$1" >> "${TMP}/out"
EOF
chmod +x "${TMP}/update-os.sh"
sed -e "s#^\. /home/tappaas/bin/common-install-routines.sh#. ${TMP}/lib.sh#" \
    -e "s#/home/tappaas/bin/update-os.sh#${TMP}/update-os.sh#" "${SRC}" > "${TMP}/update-service.sh"
ck "the template's library and update-os.sh are stubbed" "no" "$(grep -q '/home/tappaas/bin' "${TMP}/update-service.sh" && echo yes || echo no)"

# run <module> — from a directory that is NOT the module's; prints rc and what happened
run() {
    rm -f "${TMP}/out"
    local rc=0
    ( cd "${TMP}/elsewhere" && bash "${TMP}/update-service.sh" "$1" >/dev/null 2>&1 ) || rc=$?
    echo "rc=${rc} $(cat "${TMP}/out" 2>/dev/null | paste -sd'|' -)"
}

ck "run from elsewhere: update-os.sh runs in the module's directory" \
   "rc=0 update-os from ${TMP}/modules/identity for identity" "$(run identity)"
ck "a module with no resolvable directory is refused, update-os.sh never runs" \
   "rc=1 error: module 'orphan': its source directory is not resolvable — not updating its OS blind" "$(run orphan)"
ck "a recorded directory that is gone is named" \
   "rc=1 error: module 'moved': its source directory is not resolvable (${TMP}/modules/moved is gone) — not updating its OS blind" "$(run moved)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
