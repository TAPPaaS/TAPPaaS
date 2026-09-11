#!/usr/bin/env bash
#
# test-common-install-routines.sh — hermetic unit tests for helpers in
# common-install-routines.sh. Currently covers ensure_scripts_executable()
# (#524): it must chmod +x only files that need it, skip ones already
# executable, and never abort the caller when a chmod cannot succeed (a
# root-owned file left by an earlier sudo run) under `set -euo pipefail`.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-install-routines.sh disable=SC1091
. "${HERE}/common-install-routines.sh" >/dev/null 2>&1

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

echo "ensure_scripts_executable tests (#524):"

# 1. chmods the non-executable, leaves the already-executable, recurses services.
d="$(mktemp -d)"; mkdir -p "$d/services/foo"
printf '#!/bin/sh\n' > "$d/a.sh";              chmod 0644 "$d/a.sh"
printf '#!/bin/sh\n' > "$d/b.sh";              chmod 0755 "$d/b.sh"
printf '#!/bin/sh\n' > "$d/services/foo/s.sh"; chmod 0644 "$d/services/foo/s.sh"
rc=0; ensure_scripts_executable "$d" || rc=$?
[[ "$rc" -eq 0 ]]                    && ok "returns 0 (no abort)"          || bad "returns 0"
[[ -x "$d/a.sh" ]]                   && ok "non-exec root .sh -> +x"       || bad "a.sh +x"
[[ -x "$d/b.sh" ]]                   && ok "already-exec .sh left +x"      || bad "b.sh +x"
[[ -x "$d/services/foo/s.sh" ]]      && ok "service .sh -> +x"             || bad "svc +x"
rm -rf "$d"

# 2. an unavoidable chmod failure warns but does NOT abort (the #524 bug).
#    Stub chmod to fail so no root/foreign-owned file is needed.
d="$(mktemp -d)"; printf '#!/bin/sh\n' > "$d/x.sh"; chmod 0644 "$d/x.sh"
chmod() { return 1; }                       # override the builtin for this test
rc=0; out="$(ensure_scripts_executable "$d" 2>&1)" || rc=$?
unset -f chmod
[[ "$rc" -eq 0 ]]                                   && ok "chmod failure does not abort" || bad "no-abort on chmod fail (rc=$rc)"
grep -q 'cannot chmod +x' <<<"$out"                && ok "chmod failure is warned"       || bad "warns on chmod fail"
rm -rf "$d"

# 3. missing / empty directory is a clean no-op.
rc=0; ensure_scripts_executable "/nonexistent/$$/nope" || rc=$?
[[ "$rc" -eq 0 ]] && ok "missing dir -> 0" || bad "missing dir -> 0"


echo
echo "tappaas_ssh_target_host tests:"

t() { # t <expect> <desc> <argv...>
    local want="$1" desc="$2"; shift 2
    local got; got="$(tappaas_ssh_target_host "$@" 2>/dev/null || echo '<none>')"
    [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc (want '$want' got '$got')"
}
t 10.0.0.110 "bare user@ip"                 tappaas@10.0.0.110 uptime
t host       "bare host, no user"           host
t host       "separate -o values skipped"   -o BatchMode=yes -o ConnectTimeout=10 tappaas@host cmd
t host       "attached -o value skipped"    -oBatchMode=yes root@host
t host       "-i path and -p port skipped"  -i /k/id -p 2222 user@host cmd
t host       "flag without value (-4)"      -4 -q user@host
t host       "':port' stripped"             user@host:22
t '<none>'   "options only -> rc 1"         -o BatchMode=yes
# The trap this parser exists to avoid: -p's VALUE must not be read as the host.
t host       "-p value not mistaken for host" -p 22 host

echo
echo "tappaas_ssh_repin_host tests:"

kh_home="$(mktemp -d)"; mkdir -p "$kh_home/.ssh"
OLD_HOME="$HOME"; HOME="$kh_home"
printf 'stale-entry-for-h\n' > "$kh_home/.ssh/known_hosts"

# Stub the two binaries: keyscan emits a banner comment plus a key (the banner
# is exactly what must NOT be appended); keygen -R clears, -F/-l report.
ssh-keygen() {
    case "${1:-}" in
        -R) : > "$kh_home/.ssh/known_hosts" ;;                       # scrub
        -F) grep -q 'pinned-key' "$kh_home/.ssh/known_hosts" 2>/dev/null && echo 'h ssh-ed25519 PINNED' ;;
        -lf) echo '256 SHA256:STUBFP h (ED25519)' ;;
    esac
    return 0
}
ssh-keyscan() { printf '# h:22 SSH-2.0-OpenSSH\n h ssh-ed25519 pinned-key\n'; }

rc=0; out="$(tappaas_ssh_repin_host h 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] && ok "repin returns 0" || bad "repin returns 0 (rc=$rc)"
grep -q 'pinned-key' "$kh_home/.ssh/known_hosts" && ok "new key appended"   || bad "new key appended"
grep -q '^#'         "$kh_home/.ssh/known_hosts" && bad "banner comment stripped" || ok "banner comment stripped"
grep -q 'stale-entry' "$kh_home/.ssh/known_hosts" && bad "stale entry removed" || ok "stale entry removed"
rc=0; tappaas_ssh_repin_host "" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "empty host -> non-zero" || bad "empty host -> non-zero"

echo
echo "tappaas_ssh_guest tests:"

# Stub ssh: fail the first call with the real OpenSSH message, succeed after.
calls_f="$(mktemp)"; : > "$calls_f"
ncalls() { wc -l < "$calls_f" | tr -d ' '; }
ssh() {
    echo x >> "$calls_f"
    if [[ "$(ncalls)" -eq 1 ]]; then
        echo "Host key verification failed." >&2
        return 255
    fi
    echo "COMMAND-OUTPUT"
    return 0
}

: > "$calls_f"
rc=0; out="$(tappaas_ssh_guest tappaas@h true 2>/dev/null)" || rc=$?
[[ "$rc" -eq 0 ]]              && ok "changed key is healed, caller sees success" || bad "healed (rc=$rc)"
[[ "$(ncalls)" -eq 2 ]]        && ok "retried exactly once"                       || bad "retried once (calls=$(ncalls))"
[[ "$out" == "COMMAND-OUTPUT" ]] && ok "stdout passed through to caller"          || bad "stdout passthrough (got '$out')"

# Opt-out: refuse to re-pin, and surface the original failure.
: > "$calls_f"
rc=0; out="$(TAPPAAS_SSH_NO_REPIN=1 tappaas_ssh_guest tappaas@h true 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]]        && ok "NO_REPIN=1 keeps the failure"     || bad "NO_REPIN keeps failure"
[[ "$(ncalls)" -eq 1 ]]  && ok "NO_REPIN=1 does not retry"        || bad "NO_REPIN no retry (calls=$(ncalls))"
grep -q 'refusing to re-pin' <<<"$out" && ok "NO_REPIN=1 says why" || bad "NO_REPIN says why"

# A failure that is NOT a host-key problem must pass straight through, untouched.
ssh() { echo "Permission denied (publickey)." >&2; return 255; }
: > "$calls_f"
rc=0; tappaas_ssh_guest tappaas@h true >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 255 ]] && ok "non-hostkey failure preserved, no retry" || bad "non-hostkey preserved (rc=$rc)"

# #630: the caller passed -q, so ssh says NOTHING on stderr. The old wrapper
# grepped that empty file, found no reason, and handed the caller a bare
# failure. The pinned key no longer matches what the host offers, and THAT is
# the evidence the heal must run on.
ssh-keyscan() { printf ' h ssh-ed25519 a-brand-new-key\n'; }
ssh-keygen() { # -F reports the pin, -lf fingerprints whatever it is handed
    case "${1:-}" in
        -R)  : > "$kh_home/.ssh/known_hosts" ;;
        -F)  echo 'h ssh-ed25519 pinned-key' ;;
        -lf) if grep -q 'a-brand-new-key'; then echo '256 SHA256:NEWFP h (ED25519)'
             else echo '256 SHA256:OLDFP h (ED25519)'; fi ;;
    esac
    return 0
}
ssh() {
    echo x >> "$calls_f"
    [[ "$(ncalls)" -eq 1 ]] && return 255      # -q: no stderr, no reason given
    echo "COMMAND-OUTPUT"; return 0
}
: > "$calls_f"
rc=0; out="$(tappaas_ssh_guest -q tappaas@h true 2>/dev/null)" || rc=$?
[[ "$rc" -eq 0 ]]       && ok "-q: changed key healed with no stderr to match (#630)" || bad "-q healed (rc=$rc)"
[[ "$(ncalls)" -eq 2 ]] && ok "-q: retried exactly once"                              || bad "-q retried once (calls=$(ncalls))"

# …and the mirror image: silent failure, but the pin still matches what the
# host offers. Nothing to heal, so the failure must stand.
ssh-keyscan() { printf ' h ssh-ed25519 pinned-key\n'; }
: > "$calls_f"
rc=0; tappaas_ssh_guest -q tappaas@h true >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]]       && ok "-q: silent failure with a matching pin stays failed" || bad "-q matching pin stays failed (rc=$rc)"
[[ "$(ncalls)" -eq 1 ]] && ok "-q: matching pin does not retry"                     || bad "-q no retry (calls=$(ncalls))"

unset -f ssh ssh-keygen ssh-keyscan ncalls; rm -f "$calls_f"

echo
echo "tappaas_ssh_host_key_changed tests (#630):"

hk_home="$(mktemp -d)"; mkdir -p "$hk_home/.ssh"; HOME="$hk_home"
printf 'h ssh-ed25519 pinned-key\n' > "$hk_home/.ssh/known_hosts"
ssh-keygen() {
    local inp
    case "${1:-}" in
        -F)  cat "$hk_home/.ssh/known_hosts" ;;
        # Fingerprint what it is HANDED — an empty stdin must fingerprint to
        # nothing, or "no pin at all" is indistinguishable from a stale one.
        -lf) inp="$(cat)"; [[ -n "$inp" ]] || return 0
             if grep -q 'a-brand-new-key' <<<"$inp"; then echo '256 SHA256:NEWFP h (ED25519)'
             else echo '256 SHA256:OLDFP h (ED25519)'; fi ;;
    esac
    return 0
}

ssh-keyscan() { printf ' h ssh-ed25519 a-brand-new-key\n'; }
tappaas_ssh_host_key_changed h && ok "different key -> changed"        || bad "different key -> changed"

ssh-keyscan() { printf ' h ssh-ed25519 pinned-key\n'; }
tappaas_ssh_host_key_changed h && bad "same key -> not changed"        || ok "same key -> not changed"

# The two "I cannot tell" answers are NOT-changed: they must never provoke a
# re-pin, because neither is evidence that the key moved.
ssh-keyscan() { return 1; }                                  # host unreachable
tappaas_ssh_host_key_changed h && bad "unreachable -> not changed"     || ok "unreachable -> not changed"

ssh-keyscan() { printf ' h ssh-ed25519 a-brand-new-key\n'; }
: > "$hk_home/.ssh/known_hosts"                              # nothing pinned
tappaas_ssh_host_key_changed h && bad "nothing pinned -> not changed"  || ok "nothing pinned -> not changed"

tappaas_ssh_host_key_changed "" && bad "empty host -> not changed"     || ok "empty host -> not changed"

unset -f ssh-keygen ssh-keyscan; HOME="$OLD_HOME"; rm -rf "$hk_home"

echo
echo "tappaas_scp_target_host tests:"

ts() { # ts <expect> <desc> <argv...>
    local want="$1" desc="$2"; shift 2
    local got; got="$(tappaas_scp_target_host "$@" 2>/dev/null || echo '<none>')"
    [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc (want '$want' got '$got')"
}
# scp's destination is NOT "the first non-option" — that is the LOCAL source.
ts host    "upload: remote is the 2nd operand"  -q /local/f.sh tappaas@host:/remote/f.sh
ts host    "download: remote is the 1st operand" -q tappaas@host:/remote/f /local/f
ts host    "separate -o values skipped"          -o BatchMode=yes /l/f tappaas@host:/r/
ts host    "-P port value not read as host"      -P 2222 /l/f user@host:/r/
ts host    "-i path value not read as host"      -i /k/id /l/f host:/r/
ts host    "relative local source skipped"       ./f.sh host:/r/
ts '<none>' "no remote operand -> rc 1"          -q /local/a /local/b

echo
echo "tappaas_scp_guest tests:"

kh_home="$(mktemp -d)"; mkdir -p "$kh_home/.ssh"; HOME="$kh_home"
printf 'stale\n' > "$kh_home/.ssh/known_hosts"
ssh-keygen() { case "${1:-}" in -R) : > "$kh_home/.ssh/known_hosts" ;; -F) echo 'h ssh-ed25519 PINNED' ;; -lf) echo '256 SHA256:STUBFP h (ED25519)' ;; esac; return 0; }
ssh-keyscan() { printf ' h ssh-ed25519 pinned-key\n'; }

calls_f="$(mktemp)"; : > "$calls_f"
ncalls() { wc -l < "$calls_f" | tr -d ' '; }
scp() {
    echo x >> "$calls_f"
    if [[ "$(ncalls)" -eq 1 ]]; then
        echo "Host key verification failed." >&2
        return 255
    fi
    return 0
}

: > "$calls_f"
rc=0; tappaas_scp_guest /l/f tappaas@h:/r/f >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]]       && ok "changed key is healed, transfer retried" || bad "healed (rc=$rc)"
[[ "$(ncalls)" -eq 2 ]] && ok "retried exactly once"                    || bad "retried once (calls=$(ncalls))"

# The #626 shape: a transfer that fails for any other reason must stay failed,
# so a caller cannot mistake it for a delivery.
scp() { echo "scp: Connection closed" >&2; return 1; }
: > "$calls_f"
rc=0; tappaas_scp_guest /l/f tappaas@h:/r/f >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "non-hostkey failure preserved" || bad "non-hostkey preserved (rc=$rc)"

unset -f scp ssh-keygen ssh-keyscan ncalls; rm -f "$calls_f"
HOME="$OLD_HOME"; rm -rf "$kh_home"

echo "----"
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
