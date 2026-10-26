#!/usr/bin/env bash
#
# Offline tests for setup-wlan-secrets.sh — SSID names + passphrases.
# Sources the script (source-guarded) with ZONES_FILE/SECRETS_FILE pointed at
# fixtures, then exercises the secret store (wlan-lib.sh) and --list. A final
# pty-driven run (via util-linux `script`) covers the interactive happy path if
# available: it declares the SSIDs through ap-manager (#889), which writes the
# zone's SSID through a network-manager stub.
#
# Usage: ./test-setup-wlan-secrets.sh   — exit 0 all passed, 1 otherwise.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

PASS=0; FAIL=0
ck() { local d="$1" exp="$2" got="$3"; if [[ "$exp" == "$got" ]]; then echo "  ok: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected '$exp', got '$got')"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export CONFIG_DIR="${TMP}/config"; mkdir -p "${CONFIG_DIR}"
export SECRETS_FILE="${TMP}/wlan-secrets.txt"
export ZONES_FILE="${CONFIG_DIR}/zones.json"
export AP_MANAGER="${SCRIPT_DIR}/ap-manager"
# shellcheck source=test-lib.bash
. "${SCRIPT_DIR}/test-lib.bash"
export AP_NETWORK_MANAGER="${AP_TEST_NETWORK_MANAGER:-$(make_nm_stub "${TMP}")}"
cat > "${ZONES_FILE}" <<'JSON'
{
  "home": {"state":"Active","vlantag":310,"SSID":"<HOME_SSID>"},
  "guest":{"state":"Active","vlantag":510,"SSID":"GuestNet"},
  "iotX": {"state":"Disabled","vlantag":440,"SSID":"<IOT_X>"},
  "srv":  {"state":"Active","vlantag":200}
}
JSON

echo "test-setup-wlan-secrets:"

# shellcheck source=setup-wlan-secrets.sh disable=SC1091
. "${SCRIPT_DIR}/setup-wlan-secrets.sh"

# placeholder detection
if is_placeholder "<HOME_SSID>"; then ck "placeholder <..> detected" yes yes; else ck "placeholder <..> detected" yes no; fi
if is_placeholder "RealName";   then ck "real name not placeholder" no yes; else ck "real name not placeholder" no no; fi

# ssid_zones: only ACTIVE zones with an SSID (home, guest), not Disabled iotX, not srv (no SSID)
ck "ssid_zones lists active SSID zones" "guest home" "$(ssid_zones | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"

# secret store round-trip, incl. a passphrase that contains '='
set_secret "GuestNet" "p=ss/word=123"
ck "get_secret returns value (with '=')" "p=ss/word=123" "$(get_secret GuestNet)"
ck "has_secret true"  "0" "$(has_secret GuestNet; echo $?)"
ck "has_secret false" "1" "$(has_secret Nope; echo $?)"
ck "secrets file is 0600" "600" "$(stat -c '%a' "${SECRETS_FILE}")"

# overwrite same key (no duplicate line)
set_secret "GuestNet" "newpass1"
ck "overwrite updates value" "newpass1" "$(get_secret GuestNet)"
ck "no duplicate key lines" "1" "$(grep -c '^GuestNet=' "${SECRETS_FILE}")"

# delete
del_secret "GuestNet"
ck "del_secret removes key" "" "$(get_secret GuestNet)"

# the script writes no zones.json of its own (#889): ap-manager owns the SSID
ck "no zones.json writer here" "no" "$(declare -F set_zone_ssid >/dev/null && echo yes || echo no)"

# --list runs clean (returns 0) — call the function directly
out="$(cmd_list 2>&1)"; ck "cmd_list rc 0" "0" "$?"
ck "--list: a placeholder names ap-manager ssid add" "yes" "$(grep -q 'ssid add <ssid> --zone home' <<<"${out}" && echo yes || echo no)"
ck "--list: an undeclared SSID says so" "yes" "$(grep -q "not declared — ap-manager ssid add 'GuestNet'" <<<"${out}" && echo yes || echo no)"

# pty-driven interactive happy path (best-effort; skipped if `script` absent)
if command -v script >/dev/null 2>&1; then
    : > "${SECRETS_FILE}"
    jq '.home.SSID="<HOME_SSID>"' "${ZONES_FILE}" > "${ZONES_FILE}.t" && mv "${ZONES_FILE}.t" "${ZONES_FILE}"
    # answers: home -> name "MyHome", the default wpa2-personal, passphrase twice;
    #          guest -> keep the name GuestNet, open (no passphrase)
    printf 'MyHome\n\nsecretpw1\nsecretpw1\n\nopen\n' | \
        SECRETS_FILE="${SECRETS_FILE}" ZONES_FILE="${ZONES_FILE}" \
        script -qec "${SCRIPT_DIR}/setup-wlan-secrets.sh" /dev/null >/dev/null 2>&1 || true
    ck "interactive: the zone's SSID, through ap-manager" "MyHome" "$(jq -r '.home.SSID' "${ZONES_FILE}")"
    ck "interactive: declared site-wide"         "wpa2-personal|open" "$(jq -r '"\(.ssids.MyHome.security)|\(.ssids.GuestNet.security)"' "${CONFIG_DIR}/switch-configuration-desired.json")"
    ck "interactive stored passphrase"           "secretpw1" "$(get_secret MyHome)"
    ck "…marked for the reconcile"               "true" "$(jq -r '.ssids.MyHome.passphraseChanged' "${CONFIG_DIR}/switch-configuration-desired.json")"
else
    echo "  skip: pty interactive test (util-linux 'script' not available)"
fi

echo ""
echo "test-setup-wlan-secrets: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
