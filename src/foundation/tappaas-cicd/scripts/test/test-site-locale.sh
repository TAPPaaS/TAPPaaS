#!/usr/bin/env bash
#
# test-site-locale.sh — the site's time and locale, rendered per OS family (#472, #87).
#
# Offline: a fixture site.json and a stubbed zone_gateway_ip. What it pins is the
# thing #472 was about — one fact, one interpretation — so a second reader cannot
# quietly grow a different default.
#
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB="${HERE}/../../lib/site-locale.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass+1)); }
bad() { echo "  ✗ $*"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (expected '$3', got '$2')"; }
has() { grep -qF -- "$2" <<<"$1" && ok "$3" || bad "$3 — not in output"; }
hasnt() { grep -qF -- "$2" <<<"$1" && bad "$3 — unexpectedly present" || ok "$3"; }

site() { mkdir -p "${WORK}/config"; printf '%s' "$1" > "${WORK}/config/site.json"; }
load() { ( export TAPPAAS_CONFIG="${WORK}/config"; eval "${2:-:}"; . "${LIB}"; eval "$1" ); }

echo "== site-locale: the fields =="
site '{"location":{"country":"DK","timezone":"Europe/Copenhagen","locale":"en_US","keyboard":"dk"}}'
is "timezone comes from the site"  "$(load 'site_locale_value timezone UTC')"   "Europe/Copenhagen"
is "keyboard comes from the site"  "$(load 'site_locale_value keyboard')"       "dk"
is "a field the site never set is the caller's default" "$(load 'site_locale_value nosuch fallback')" "fallback"

site '{"location":{"country":"DK","timezone":"Europe/Copenhagen"}}'
is "a site with no timezone recorded still answers UTC" "$(load 'site_locale_value timezone UTC')" "Europe/Copenhagen"
is "no keyboard recorded is empty, not a guess"         "$(load 'site_locale_value keyboard')"     ""

echo ""
echo "== site-locale: the NixOS fragment =="
site '{"location":{"country":"DK","timezone":"Europe/Copenhagen","locale":"en_US","keyboard":"dk"}}'
out="$(load 'render_site_nix ""')"
has "$out" 'time.timeZone = "Europe/Copenhagen";'   "the timezone is the site's"
has "$out" 'i18n.defaultLocale = "en_US.UTF-8";'    "the locale gains its charset (the site records en_US)"
has "$out" 'console.keyMap = "dk";'                 "the keymap is rendered"
hasnt "$out" 'mkDefault "Europe'                    "the timezone is NOT mkDefault — the site must beat the baseline"
hasnt "$out" 'services.timesyncd.servers'           "no zone, no time source (rather than an empty one)"

# The NTP server is the zone's gateway (#87), via common-install-routines.sh.
out="$(load 'render_site_nix trusted' 'zone_gateway_ip() { echo 10.0.3.1; }')"
has "$out" 'services.timesyncd.servers = [ "10.0.3.1" ];' "the zone gateway is the time source"
has "$out" 'services.timesyncd.enable = lib.mkDefault true;' "timesyncd is enabled, as a default the guest may override"

# Without common-install-routines.sh loaded — which is how tappaas-self-rebuild.sh
# runs, as root, sourcing nothing from ~tappaas/bin — the gateway must still be
# derived. The mothership was the one machine left on the public pool because of
# this (found on the test site 2026-09-20).
printf '%s' '{"mgmt":{"ip":"10.0.0.0/24"},"trusted":{"ip":"10.2.0.0/24"}}' > "${WORK}/config/zones.json"
out="$(load 'render_site_nix mgmt')"
has "$out" 'services.timesyncd.servers = [ "10.0.0.1" ];' "the gateway is derived from zones.json with no helper loaded"
out="$(load 'render_site_nix trusted')"
has "$out" 'services.timesyncd.servers = [ "10.2.0.1" ];' "…and it is that zone's gateway, not the first one"
rm -f "${WORK}/config/zones.json"

# #716: the gateway first, and public servers after it where the zone may reach
# the internet — so a firewall ntpd that lost its own upstream (orphaned, or not
# answering) does not leave the guest with nothing. A zone without internet
# access keeps the gateway alone: it could not reach a public server anyway.
printf '%s' '{"rossen":{"ip":"10.2.0.0/24","access-to":["internet"]},"iotLocal":{"ip":"10.3.0.0/24","access-to":[]}}' > "${WORK}/config/zones.json"
out="$(load 'render_site_nix rossen')"
has "$out" 'services.timesyncd.servers = [ "10.2.0.1" "0.nixos.pool.ntp.org" "1.nixos.pool.ntp.org" ];' \
    "a zone with internet access: the gateway first, then two public servers"
out="$(load 'render_site_nix iotLocal')"
has "$out" 'services.timesyncd.servers = [ "10.3.0.1" ];' "a zone without internet access: the gateway alone"
is "the ordered list, for the Debian drop-in" "$(load 'site_locale_ntp_servers rossen')" "10.2.0.1 0.nixos.pool.ntp.org 1.nixos.pool.ntp.org"
is "…and a zone the site does not know gets nothing" "$(load 'site_locale_ntp_servers nosuch')" ""
grep -q 'NTP=${ntp}' "${LIB}" && grep -q 'site_locale_ntp_servers "${zone}"' <(sed -n '/^apply_site_locale_debian()/,/^}/p' "${LIB}") \
    && ok "the Debian drop-in writes the same ordered list" || bad "the Debian drop-in does not use the ordered list"
rm -f "${WORK}/config/zones.json"

# A zone the gateway cannot be derived for must not produce a broken server line.
out="$(load 'render_site_nix nosuchzone' 'zone_gateway_ip() { return 1; }')"
hasnt "$out" 'services.timesyncd.servers'           "an underivable gateway leaves the guest's own default alone"
has "$out" 'time.timeZone'                          "…and the rest of the fragment is still written"

echo ""
echo "== site-locale: a site.json that is missing or unreadable =="
rm -f "${WORK}/config/site.json"
out="$(load 'render_site_nix ""')"
has "$out" 'time.timeZone = "UTC";'                 "no site.json falls back to UTC, not to a European guess"
has "$out" 'i18n.defaultLocale = "en_US.UTF-8";'    "…with the documented locale default"

site '{ this is not json'
out="$(load 'render_site_nix ""')"
has "$out" 'time.timeZone = "UTC";'                 "unparsable site.json falls back rather than emitting a broken fragment"

echo ""
echo "== site-locale: the fragment is valid Nix =="
site '{"location":{"country":"DK","timezone":"Europe/Copenhagen","locale":"en_US","keyboard":"dk"}}'
out="$(load 'render_site_nix trusted' 'zone_gateway_ip() { echo 10.0.3.1; }')"
printf '%s' "$out" > "${WORK}/frag.nix"
if command -v nix-instantiate >/dev/null 2>&1; then
    if nix-instantiate --parse "${WORK}/frag.nix" >/dev/null 2>&1; then
        ok "nix-instantiate parses the fragment"
    else
        bad "the generated fragment is not valid Nix"
    fi
else
    # Without nix, check the shape the generator controls: the function header
    # `{ lib, ... }:`, the attrset it opens, and a closing brace on the last line.
    _hdr="$(grep -c '^{ lib' "${WORK}/frag.nix")"
    _open="$(grep -cx '{' "${WORK}/frag.nix")"
    [[ "${_hdr}" -eq 1 && "${_open}" -eq 1 && "$(tail -1 "${WORK}/frag.nix")" == "}" ]] \
        && ok "fragment shape is balanced (no nix here to parse it)" \
        || bad "fragment shape looks wrong (header=${_hdr} open=${_open} last='$(tail -1 "${WORK}/frag.nix")')"
fi

echo ""
echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
