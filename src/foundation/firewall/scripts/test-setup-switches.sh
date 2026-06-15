#!/usr/bin/env bash
#
# Offline tests for setup-switches.sh — the #351 switch-setup bootstrap step.
# Sources it (source-guarded) for unit checks, and drives the brand-first menu
# through a pty (util-linux `script`) with switch-manager + install-module stubbed
# to call logs. Covers: validated menu input, controller detection, the manual
# switch loop, and the final auto `reconcile --apply`.
#
# Usage: ./test-setup-switches.sh   — exit 0 all passed, 1 otherwise.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SUT="${SCRIPT_DIR}/setup-switches.sh"

PASS=0; FAIL=0
ck() { local d="$1" e="$2" g="$3"; if [[ "$e" == "$g" ]]; then echo "  ok: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected '$e', got '$g')"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
SMLOG="${TMP}/sm.log"; IMLOG="${TMP}/im.log"
STUB_SM="${TMP}/switch-manager"; STUB_IM="${TMP}/install-module.sh"
cat > "${STUB_SM}" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${SMLOG}"; exit 0
EOF
cat > "${STUB_IM}" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${IMLOG}"; exit 0
EOF
chmod +x "${STUB_SM}" "${STUB_IM}"
EMPTY='{"controllers":{},"switches":{},"accessPoints":{}}'
ACTFILE="${TMP}/actual.json"; echo "${EMPTY}" > "${ACTFILE}"
NOCRED="${TMP}/none.txt"
CREDS="${TMP}/creds.txt"; echo "url=https://ctrl" > "${CREDS}"

echo "test-setup-switches:"

# ── Unit: source (guarded → main not run) and check helpers ─────────
# shellcheck source=setup-switches.sh disable=SC1091
SWITCH_MANAGER="${STUB_SM}" . "${SUT}"
for fn in discover_brands plugin_arch_of plugin_module_of register_uplinks do_manual \
          do_existing_controller do_use_registered_controller do_install_controller \
          do_controller_brand annotate_controller_switches ask_choice print_inventory \
          controllers_of_vendor register_one_brand run_loop main; do
    ck "function ${fn} defined" "function" "$(type -t "$fn")"
done
ck "discover_brands lists unifi"     "unifi"      "$(discover_brands | tr '\n' ' ' | sed 's/ $//')"
ck "plugin_arch_of unifi"            "controller" "$(plugin_arch_of unifi)"
ck "plugin_module_of unifi"          "unifi-os"   "$(plugin_module_of unifi)"
ck "plugin_arch_of other (none)"     ""           "$(plugin_arch_of netgear)"

# print_inventory renders a switch + its ports (condensed)
cat > "${TMP}/inv.json" <<'JSON'
{"controllers":{},"switches":{"sw1":{"vendor":"tplink","managed":"manual","controller":null,
  "ports":{"9":{"type":"node","target":"tappaas1","targetPort":"eth0","mode":"trunk","taggedVlans":[200,310]}}}},
  "accessPoints":{}}
JSON
ACTUAL="${TMP}/inv.json"
inv="$(print_inventory 2>&1)"
ck "print_inventory lists switch"    "yes" "$(grep -q 'sw1' <<<"$inv" && echo yes || echo no)"
ck "print_inventory indents port"    "yes" "$(grep -qE 'port 9: node . tappaas1/eth0' <<<"$inv" && echo yes || echo no)"
ck "print_inventory shows vlans"     "yes" "$(grep -q 'trunk 200,310' <<<"$inv" && echo yes || echo no)"

# --non-interactive skips cleanly.
( SWITCH_MANAGER="${STUB_SM}" "${SUT}" --non-interactive >/dev/null 2>&1 ); ck "--non-interactive rc 0" "0" "$?"

# pty driver with explicit creds + actual files
run_pty() { # run_pty <inputs> <cred-file> <actual-file>
    : > "${SMLOG}"; : > "${IMLOG}"
    printf '%b' "$1" | SWITCH_MANAGER="${STUB_SM}" INSTALL_MODULE="${STUB_IM}" \
        UNIFI_CRED="$2" ACTUAL="$3" \
        script -qec "${SUT}" /dev/null >/dev/null 2>&1 || true
}

if command -v script >/dev/null 2>&1; then
    # Other brand → manual (free-text vendor; no controller menu). Final reconcile --apply.
    run_pty '2\nnetgear\nnsw\n\n\nn\n' "${NOCRED}" "${ACTFILE}"
    ck "other→manual add-switch"           "1" "$(grep -c -- 'add-switch nsw --vendor netgear --managed manual' "${SMLOG}")"
    ck "ends with reconcile --apply"       "1" "$(grep -c -- '^reconcile --apply$' "${SMLOG}")"

    # Manual loop: two switches of one brand in a single visit.
    run_pty '2\nnetgear\nsw-a\n\nsw-b\n\n\nn\n' "${NOCRED}" "${ACTFILE}"
    ck "manual loops multiple switches"    "2" "$(grep -c -- 'add-switch sw-[ab] --vendor netgear --managed manual' "${SMLOG}")"

    # Invalid menu input re-prompts instead of exiting (foo → then 2=Other).
    run_pty 'foo\n2\nnetgear\nvsw\n\n\nn\n' "${NOCRED}" "${ACTFILE}"
    ck "invalid choice re-prompts"         "1" "$(grep -c -- 'add-switch vsw --vendor netgear --managed manual' "${SMLOG}")"

    # unifi + creds present → menu: 1 use ctrl / 2 manual / 3 install. Pick 2 (manual).
    run_pty '1\n2\ncore-sw\ntappaas1\n9\neth0\n\n\nn\n' "${CREDS}" "${ACTFILE}"
    ck "unifi→manual add-switch"           "1" "$(grep -c -- 'add-switch core-sw --vendor unifi --managed manual' "${SMLOG}")"
    ck "unifi→manual no --ip"              "0" "$(grep -c -- 'add-switch core-sw .*--ip' "${SMLOG}")"
    ck "unifi→manual add-port"             "1" "$(grep -c -- 'add-port core-sw 9 --type node --target tappaas1 --target-port eth0' "${SMLOG}")"

    # unifi + creds present, none registered → pick 1 (use that controller) → add-controller + interrogate.
    run_pty '1\n1\n\n\nn\n' "${CREDS}" "${ACTFILE}"
    ck "creds→use: add-controller w/ url"  "1" "$(grep -c -- 'add-controller unifi-controller --vendor unifi --ip https://ctrl' "${SMLOG}")"
    ck "creds→use: interrogate"            "1" "$(grep -c -- '^interrogate$' "${SMLOG}")"

    # unifi + a controller ALREADY registered → pick 1 (use it) → NO add-controller, just interrogate.
    REGFILE="${TMP}/reg.json"
    echo '{"controllers":{"ctrlX":{"vendor":"unifi","managementIp":"https://ctrl","managed":"auto"}},"switches":{},"accessPoints":{}}' > "${REGFILE}"
    run_pty '1\n1\nn\n' "${CREDS}" "${REGFILE}"
    ck "registered→use: no add-controller" "0" "$(grep -c -- 'add-controller' "${SMLOG}")"
    ck "registered→use: interrogate"       "1" "$(grep -c -- '^interrogate$' "${SMLOG}")"

    # unifi + no creds, none registered → menu: 1 manual / 2 existing / 3 install. Pick 3.
    run_pty '1\n3\nn\n' "${NOCRED}" "${ACTFILE}"
    ck "no-ctrl→install module"            "1" "$(grep -c -- 'unifi-os' "${IMLOG}")"
    ck "no-ctrl→install adds no switch"    "0" "$(grep -c -- 'add-switch' "${SMLOG}")"
else
    echo "  skip: pty menu tests (util-linux 'script' not available)"
fi

echo ""
echo "test-setup-switches: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
