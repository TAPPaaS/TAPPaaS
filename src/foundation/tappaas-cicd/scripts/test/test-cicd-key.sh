#!/usr/bin/env bash
# test-cicd-key.sh — the authorized_keys editor inside cicd-key.sh, and the
# invariants the mothership-key work rests on (#122). Self-contained: temp
# files and freshly generated keys, no cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
FOUNDATION="$(cd "${CICD}/.." && pwd)"
SCRIPT="${CICD}/scripts/cicd-key.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT

# The helper exactly as shipped: the lines between the heredoc markers.
awk '/^read -r -d .. EDIT_HELPER <<.SH.$/ {f=1; next} f && /^SH$/ {f=0} f' "${SCRIPT}" > "${d}/helper.sh"
[[ -s "${d}/helper.sh" ]] || { echo "  ✗ could not extract EDIT_HELPER from ${SCRIPT}"; exit 1; }

key() { ssh-keygen -q -t ed25519 -N "" -C "$2" -f "${d}/$1"; }
fp()  { ssh-keygen -lf "${d}/$1.pub" | awk '{print $2}'; }
key cur tappaas-cicd;  key old1 tappaas-cicd;  key old2 tappaas-cicd;  key lars lars@laptop
CUR_PUB="$(cat "${d}/cur.pub")"; CUR="$(fp cur)"
edit() { sh "${d}/helper.sh" "$1" "$2" "${CUR_PUB}" "${CUR}" >/dev/null 2>&1; }
has()  { ssh-keygen -lf "$1" 2>/dev/null | grep -c "$2" || true; }

F="${d}/ak"
{ echo "# managed by hand"; cat "${d}/lars.pub" "${d}/old1.pub"; echo; cat "${d}/old2.pub"; } > "${F}"

edit "${F}" add
ck "add: the current key is present"            1 "$(has "${F}" "${CUR}")"
ck "add: other keys are kept"                   1 "$(has "${F}" "$(fp old1)")"
edit "${F}" add
ck "add twice: still exactly one copy"          1 "$(has "${F}" "${CUR}")"

edit "${F}" revoke
ck "revoke: every other tappaas-cicd key goes"  0 "$(( $(has "${F}" "$(fp old1)") + $(has "${F}" "$(fp old2)") ))"
ck "revoke: the current key stays"              1 "$(has "${F}" "${CUR}")"
ck "revoke: someone else's key stays"           1 "$(has "${F}" "$(fp lars)")"
ck "revoke: comments and blank lines stay"      2 "$(grep -c -E '^(#|$)' "${F}")"

G="${d}/ak-without-current"; cat "${d}/old1.pub" "${d}/lars.pub" > "${G}"; cp "${G}" "${G}.before"
sh "${d}/helper.sh" "${G}" revoke "${CUR_PUB}" "${CUR}" >/dev/null 2>&1; rc=$?
ck "revoke refuses a file the current key is not in" 1 "${rc}"
cmp -s "${G}" "${G}.before" && same=yes || same=no
ck "...and leaves it untouched"                 yes "${same}"

H="${d}/ak-replace"; cat "${d}/old1.pub" "${d}/lars.pub" > "${H}"
edit "${H}" replace
ck "replace: current in, old out, others kept" "1 0 1" \
   "$(has "${H}" "${CUR}") $(has "${H}" "$(fp old1)") $(has "${H}" "$(fp lars)")"

# A node's /root/.ssh/authorized_keys is a symlink into /etc/pve: renaming over
# the link would silently un-share that node's keys from the cluster.
mkdir -p "${d}/pve" "${d}/root"; cat "${d}/old1.pub" > "${d}/pve/authorized_keys"
ln -s "${d}/pve/authorized_keys" "${d}/root/authorized_keys"
edit "${d}/root/authorized_keys" replace
[[ -L "${d}/root/authorized_keys" ]] && link=kept || link=replaced
ck "a symlinked file stays a symlink"           kept "${link}"
ck "...and its target is the file edited"       1 "$(has "${d}/pve/authorized_keys" "${CUR}")"

sh "${d}/helper.sh" "/home/no-such-user-$$/.ssh/authorized_keys" add "${CUR_PUB}" "${CUR}" >/dev/null 2>&1; rc=$?
ck "no such user: skip (exit 3), nothing created" "3 no" "${rc} $([[ -e /home/no-such-user-$$ ]] && echo yes || echo no)"

# ── invariants in the code around it ─────────────────────────────────
# Changing a VM's cloud-init keys changes its instance-id (PVE hashes the
# user-data), so the next boot regenerates its SSH host keys. cicd-key.sh must
# never do it.
grep -qE -- '--sshkey|qm set .*sshkey' "${SCRIPT}" && touches=yes || touches=no
ck "cicd-key.sh never changes a VM's cloud-init sshkeys" no "${touches}"

# The mothership's PRIVATE key is not copied to the nodes any more.
grep -qE 'id_ed25519 +root@.*tappaas-cicd\.key' "${CICD}/install.sh" && copies=yes || copies=no
ck "install.sh does not copy the private key to the nodes" no "${copies}"

# distribute_cicd_key replaces the previous mothership key instead of appending,
# and edits the real file behind the symlink.
D="$(sed -n '/^distribute_cicd_key()/,/^}/p' "${FOUNDATION}/cluster/install-platform.sh")"
grep -q "grep -v ' tappaas-cicd" <<< "${D}" && rep=yes || rep=no
grep -q 'readlink -f /root/.ssh/authorized_keys' <<< "${D}" && rl=yes || rl=no
ck "distribute_cicd_key replaces, symlink-safe"  "yes yes" "${rep} ${rl}"

echo "  ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
