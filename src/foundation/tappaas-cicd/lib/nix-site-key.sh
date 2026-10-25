#!/usr/bin/env bash
# nix-site-key.sh — the mothership's Nix signing key (ADR-033 D8).
#
# The mothership builds every NixOS guest's system and copies the closure to the
# guest (update-os.sh, #774). The guest checks each store path it receives for a
# signature by a key it trusts: cache.nixos.org's (the baseline) and this site's
# (tappaas-site.nix, rendered from the public half below). Site-local: nothing
# to do with the release signing keys of ADR-033 D1/D2.
#
#   /etc/nix/tappaas-site-signing.sec   root:root 0600 — never leaves the host
#   /etc/nix/tappaas-site-signing.pub   0644 — "tappaas-<site>-1:<base64>"
#
# Created once, by the first caller that needs it (tappaas-render-fragments.sh
# before every mothership rebuild; update-os.sh before it signs). Never rotated
# here: a new key is introduced to each guest the same way the first one was.
#
# Sourced. Privileged steps run as root, through sudo -n when the caller is not.

NIX_SITE_KEY_DIR="${NIX_SITE_KEY_DIR:-/etc/nix}"
NIX_SITE_KEY_SECRET="${NIX_SITE_KEY_SECRET:-${NIX_SITE_KEY_DIR}/tappaas-site-signing.sec}"
NIX_SITE_KEY_PUBLIC="${NIX_SITE_KEY_PUBLIC:-${NIX_SITE_KEY_DIR}/tappaas-site-signing.pub}"

_nsk_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        env "PATH=${PATH}:/run/current-system/sw/bin" "$@"
    else
        sudo -n env "PATH=${PATH}:/run/current-system/sw/bin" "$@"
    fi
}

# The key's name: tappaas-<site code>-1, so a guest's nix.conf says whose key
# it trusts. Nix key names may not contain ':'.
nix_site_key_name() {
    local d
    d="$(jq -r '.name // empty' "${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json" 2>/dev/null)"
    [[ -n "${d}" ]] || d="$(hostname 2>/dev/null)"
    d="$(printf '%s' "${d:-site}" | tr -c 'A-Za-z0-9.-' '-')"
    printf 'tappaas-%s-1' "${d}"
}

# The public key, validated: one "<name>:<base64 of 32 bytes>" line. It ends up
# inside a Nix string, so nothing else gets through. Empty + 1 when absent.
nix_site_key_public() {
    local k
    k="$(head -n 1 "${NIX_SITE_KEY_PUBLIC}" 2>/dev/null)"
    [[ "${k}" =~ ^[A-Za-z0-9.-]+:[A-Za-z0-9+/]{43}=$ ]] || return 1
    printf '%s' "${k}"
}

# Create the key pair when there is none; re-derive the public half when it is
# missing or does not match the secret. Idempotent; a concurrent caller's key
# wins over ours (mv -n), so two first runs cannot leave a mismatched pair.
nix_site_key_ensure() {
    local sec="${NIX_SITE_KEY_SECRET}" pub="${NIX_SITE_KEY_PUBLIC}" want
    if ! _nsk_as_root test -s "${sec}"; then
        _nsk_as_root sh -c 'umask 077 && install -d -m 0755 "$(dirname "$1")" \
            && nix key generate-secret --key-name "$2" > "$1.new.$$" \
            && test -s "$1.new.$$" && mv -n "$1.new.$$" "$1"; rm -f "$1.new.$$"; test -s "$1"' \
            sh "${sec}" "$(nix_site_key_name)" || return 1
    fi
    want="$(_nsk_as_root sh -c 'nix key convert-secret-to-public < "$1"' sh "${sec}")" || return 1
    [[ -n "${want}" ]] || return 1
    [[ "$(head -n 1 "${pub}" 2>/dev/null)" == "${want}" ]] && return 0
    _nsk_as_root sh -c 'printf "%s\n" "$2" > "$1.new.$$" && chmod 0644 "$1.new.$$" && mv -f "$1.new.$$" "$1"' \
        sh "${pub}" "${want}"
}

# Sign <store path> and everything it references with the site key. Paths that
# already carry this signature keep one. Nix's "added N signatures" is detail
# on every OS update, so it goes to debug; when signing fails, what Nix said is
# printed with the failure.
nix_site_key_sign() {
    local out rc=0
    out="$(_nsk_as_root nix store sign --key-file "${NIX_SITE_KEY_SECRET}" --recursive "$1" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
        return "${rc}"
    fi
    if [[ -n "${out}" ]] && declare -F debug >/dev/null; then debug "nix store sign: ${out}"; fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        ensure) nix_site_key_ensure ;;
        public) nix_site_key_public && echo ;;
        *) echo "usage: nix-site-key.sh ensure|public" >&2; exit 2 ;;
    esac
fi
