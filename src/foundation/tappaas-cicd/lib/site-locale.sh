#!/usr/bin/env bash
#
# site-locale.sh — the site's time and locale, rendered for each OS family (#472, #87).
#
# Country, keyboard and timezone are answered once, on the first Proxmox install,
# and recorded in site.json `.location` (#408). This library is the only place
# that turns those facts into something a guest can apply, so the three consumers
# — NixOS, Debian, and a Proxmox node — cannot drift into three interpretations.
#
# Before this, every module's .nix picked its own: tappaas-common.nix said
# Europe/Amsterdam, euro-office.nix said UTC, and the operator's own answer
# (Europe/Copenhagen) reached nothing. That is #472's "two hours out".
#
# Time SOURCE is part of the same fact (#87): a guest syncs against its zone's
# gateway — the OPNsense firewall — not a public pool it may not be allowed to
# reach. A zone with no derivable gateway simply gets no server line, leaving the
# guest's own default alone rather than pointing it at nothing.
#
# The gateway is FIRST, not only (#716): where the zone may reach the internet,
# two public pool servers follow it. timesyncd tries its servers in order and
# moves on when one times out or reports too large a root distance — exactly
# what the firewall's ntpd did for 17 minutes on 2026-09-23 while it had lost its
# own upstream. A zone without internet access still gets the gateway alone.
#
# Sourceable only. Functions:
#   site_locale_value <key> [default]   one field of .location
#   site_locale_ntp <zone>              the NTP server for that zone, or ""
#   site_locale_ntp_servers <zone>      all of the zone's NTP servers, in order
#   render_site_nix <zone>              the NixOS fragment, on stdout
#   apply_site_locale_nixos <ip> <zone> install the fragment (the caller rebuilds)
#   apply_site_locale_debian <ip> <zone> converge a running Debian guest or host
#
# No `set` here: a sourced library must not change its caller's shell options.

_SL_CONFIG_DIR="${TAPPAAS_CONFIG:-${CONFIG_DIR:-/home/tappaas/config}}"
_SL_SITE="${_SL_CONFIG_DIR}/site.json"

# One field of .location, or the default when the site has never recorded it.
site_locale_value() {
    local key="$1" fallback="${2:-}" v=""
    [[ -f "${_SL_SITE}" ]] && v="$(jq -r --arg k "${key}" '(.location[$k] // "") | tostring' "${_SL_SITE}" 2>/dev/null)"
    [[ -n "${v}" && "${v}" != "null" ]] || v="${fallback}"
    printf '%s' "${v}"
}

# A POSIX locale needs its charset; the site records the language part (en_US).
_sl_locale_full() {
    local l; l="$(site_locale_value locale en_US)"
    [[ "${l}" == *.* ]] || l="${l}.UTF-8"
    printf '%s' "${l}"
}

# The zone's gateway is the site's time source (#87): the first host of the
# zone's subnet, which is the OPNsense interface on the client's own subnet.
#
# Prefer zone_gateway_ip from common-install-routines.sh, but derive it here when
# that is not loaded — tappaas-self-rebuild.sh runs as root and deliberately
# sources nothing from ~tappaas/bin, and without this fallback the MOTHERSHIP was
# the one machine left syncing against the public pool.
site_locale_ntp() {
    local zone="${1:-}"
    [[ -n "${zone}" ]] || return 0
    if declare -F zone_gateway_ip >/dev/null 2>&1; then
        zone_gateway_ip "${zone}" 2>/dev/null || true
        return 0
    fi
    local zones="${_SL_CONFIG_DIR}/zones.json"
    [[ -f "${zones}" ]] || return 0
    jq -r --arg z "${zone}" \
        '(.[$z].ip // "") | if . == "" then "" else (split("/")[0] | split(".") | .[0:3] | join(".") + ".1") end' \
        "${zones}" 2>/dev/null || true
}

# The public servers a zone falls back to, when its access-to includes the
# internet (#716). The NixOS pool, because it is the one every NixOS guest already
# lists as its fallback, and two of them so the fallback is not a single host.
SITE_NTP_PUBLIC=("0.nixos.pool.ntp.org" "1.nixos.pool.ntp.org")

_sl_zone_has_internet() {
    local zone="$1" zones="${_SL_CONFIG_DIR}/zones.json"
    [[ -n "${zone}" && -f "${zones}" ]] || return 1
    jq -e --arg z "${zone}" '((.[$z]["access-to"] // []) | index("internet")) != null' "${zones}" >/dev/null 2>&1
}

# All of the zone's NTP servers, gateway first, space-separated; "" when the
# gateway cannot be derived (then the guest keeps its own default, as before).
site_locale_ntp_servers() {
    local zone="${1:-}" gw
    gw="$(site_locale_ntp "${zone}")"
    [[ -n "${gw}" ]] || return 0
    if _sl_zone_has_internet "${zone}"; then
        printf '%s %s' "${gw}" "${SITE_NTP_PUBLIC[*]}"
    else
        printf '%s' "${gw}"
    fi
}

# The NixOS fragment. Plain assignments, not mkDefault: this is the site saying
# where it is, and it must win over a baseline default. A module that genuinely
# needs otherwise says so with lib.mkForce, which is then visible in review.
render_site_nix() {
    local zone="${1:-}" tz locale keymap ntp
    tz="$(site_locale_value timezone UTC)"
    locale="$(_sl_locale_full)"
    keymap="$(site_locale_value keyboard)"
    ntp="$(site_locale_ntp_servers "${zone}")"

    cat <<EOF
# tappaas-site.nix — GENERATED from site.json by TAPPaaS. Do not edit here.
#
# The site's own answers for time and locale (#408, #472): they are recorded once
# in config/site.json on the mothership and written here on every module update.
# Change them with:  site-manager site modify --locationTimezone <tz> ...
{ lib, ... }:
{
  time.timeZone = "${tz}";
  i18n.defaultLocale = "${locale}";
EOF
    [[ -n "${keymap}" ]] && printf '  console.keyMap = "%s";\n' "${keymap}"
    if [[ -n "${ntp}" ]]; then
        local list="" h
        for h in ${ntp}; do list+="\"${h}\" "; done
        cat <<EOF

  # The zone's gateway is the time source (#87) — the firewall serves it. Where
  # the zone may reach the internet, public servers follow it (#716), so a
  # firewall ntpd that has lost its own upstream does not leave the guest with
  # nothing; timesyncd moves down the list only when one fails.
  services.timesyncd.enable = lib.mkDefault true;
  services.timesyncd.servers = [ ${list}];
EOF
    fi
    printf '}\n'
}

# Install the fragment on a NixOS guest. The caller's nixos-rebuild picks it up:
# tappaas-common.nix imports it when it exists.
apply_site_locale_nixos() {
    local ip="$1" zone="${2:-}" tmp
    tmp="$(mktemp)" || return 1
    render_site_nix "${zone}" > "${tmp}"
    if ! scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${tmp}" "tappaas@${ip}:/tmp/tappaas-site.nix"; then
        rm -f "${tmp}"; return 1
    fi
    rm -f "${tmp}"
    ssh -o BatchMode=yes "tappaas@${ip}" \
        "sudo install -m 0644 /tmp/tappaas-site.nix /etc/nixos/tappaas-site.nix && rm -f /tmp/tappaas-site.nix"
}

# Converge a running Debian guest or host. Idempotent, and it says what it
# changed rather than changing it silently: these are facts an operator may have
# set by hand, and a sweep that rewrites them without a word is how drift hides.
apply_site_locale_debian() {
    local ip="$1" zone="${2:-}" user="${3:-tappaas}" tz locale keymap ntp changed=0 cur
    tz="$(site_locale_value timezone)"
    locale="$(_sl_locale_full)"
    keymap="$(site_locale_value keyboard)"
    ntp="$(site_locale_ntp_servers "${zone}")"

    if [[ -n "${tz}" ]]; then
        cur="$(ssh -o BatchMode=yes "${user}@${ip}" 'timedatectl show -p Timezone --value' 2>/dev/null || true)"
        if [[ -n "${cur}" && "${cur}" != "${tz}" ]]; then
            if ssh -o BatchMode=yes "${user}@${ip}" "sudo timedatectl set-timezone '${tz}'" 2>/dev/null; then
                info "  timezone ${cur} → ${tz}"; changed=1
            else
                warn "  could not set the timezone on ${ip} (it stays ${cur})"
            fi
        fi
    fi

    if [[ -n "${keymap}" ]]; then
        cur="$(ssh -o BatchMode=yes "${user}@${ip}" '. /etc/default/keyboard 2>/dev/null && printf "%s" "${XKBLAYOUT:-}"' 2>/dev/null || true)"
        if [[ -n "${cur}" && "${cur}" != "${keymap}" ]]; then
            if ssh -o BatchMode=yes "${user}@${ip}" "sudo localectl set-x11-keymap '${keymap}'" 2>/dev/null; then
                info "  keyboard ${cur} → ${keymap}"; changed=1
            else
                warn "  could not set the keyboard on ${ip} (it stays ${cur})"
            fi
        fi
    fi

    if [[ -n "${locale}" ]]; then
        cur="$(ssh -o BatchMode=yes "${user}@${ip}" '. /etc/default/locale 2>/dev/null && printf "%s" "${LANG:-}"' 2>/dev/null || true)"
        if [[ -n "${cur}" && "${cur}" != "${locale}" ]]; then
            if ssh -o BatchMode=yes "${user}@${ip}" "sudo localectl set-locale 'LANG=${locale}'" 2>/dev/null; then
                info "  locale ${cur} → ${locale}"; changed=1
            else
                warn "  could not set the locale on ${ip} (it stays ${cur})"
            fi
        fi
    fi

    # Time source: a drop-in, so the distribution's own timesyncd config stays
    # as it is and the site's choice is one removable file. NTP= holds the whole
    # ordered list (#716): the gateway, then public servers where reachable.
    if [[ -n "${ntp}" ]]; then
        if ! ssh -o BatchMode=yes "${user}@${ip}" "grep -qs '^NTP=${ntp}\$' /etc/systemd/timesyncd.conf.d/tappaas.conf" 2>/dev/null; then
            if ssh -o BatchMode=yes "${user}@${ip}" "sudo install -d -m 0755 /etc/systemd/timesyncd.conf.d && printf '# TAPPaaS (#87, #716): the zone gateway first, public servers after it.\n[Time]\nNTP=${ntp}\n' | sudo tee /etc/systemd/timesyncd.conf.d/tappaas.conf >/dev/null && sudo systemctl restart systemd-timesyncd" 2>/dev/null; then
                info "  time source → ${ntp}"; changed=1
            else
                warn "  could not point ${ip} at the time source ${ntp}"
            fi
        fi
    fi

    [[ "${changed}" -eq 1 ]] && debug "  site locale converged on ${ip}"
    return 0
}
