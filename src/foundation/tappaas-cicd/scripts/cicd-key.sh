#!/usr/bin/env bash
#
# cicd-key.sh — the mothership's SSH key: see it, rotate it, recover it (#122).
#
# The mothership (tappaas-cicd) holds ONE key, ~/.ssh/id_ed25519, comment
# "tappaas-cicd" (bootstrap.sh). Two kinds of machine trust it:
#   - every Proxmox node, as root, through the cluster-wide file
#     /etc/pve/priv/authorized_keys (each node's /root/.ssh/authorized_keys is a
#     symlink to it);
#   - every VM that accepts tappaas@<vm> by key, through
#     /home/tappaas/.ssh/authorized_keys, written once by cloud-init at creation.
# The firewall is not a target: it trusts a separate key (~/.ssh/tappaas-fw).
# An LXC is reached with `pct` through its node, so the node key covers it.
# A Windows VM trusts the key too (templates/winserver injects it) but keeps it
# in a file this script does not edit: rotate aborts before the switch if one
# takes the key, and recover names it for a manual fix.
#
#   status            what the current key reaches, and every OTHER tappaas-cicd
#                     key still trusted anywhere (a stale mothership key is root
#                     on every node until it is removed)
#   rotate [--dry-run] [--skip-unreachable]
#                     the current key still works: generate a new key, ADD it
#                     everywhere, prove it reaches every target the old one did,
#                     switch, then REVOKE every other tappaas-cicd key, and
#                     refresh the console debug copy on the nodes (below).
#                     Aborts before the switch if the new key misses a target;
#                     the old key is archived as ~/.ssh/id_ed25519.old-<time>.
#                     Refuses to START while any VM is in doubt — a host key that
#                     does not match known_hosts, or no answer — because a rotation
#                     that skipped it would leave the old key valid there.
#                     --skip-unreachable proceeds past VMs that do not answer (a
#                     stopped VM) and names them in the report as NOT rotated.
#   recover [--dry-run]
#                     the old key is LOST (the mothership was reinstalled): put
#                     the current key on every VM through its QEMU guest agent,
#                     driven from the nodes — no SSH to the VM needed — and revoke
#                     every other tappaas-cicd key. Needs the current key on the
#                     nodes first; SSH to the nodes is key-only (#19), so that is
#                     one line in a node's web-GUI Shell, which this prints.
#
# What it deliberately leaves alone: each VM's cloud-init `sshkeys`. PVE derives
# the cloud-init instance-id from sha1(user-data + network-data), so changing
# the keys there makes the VM's next boot a NEW instance and regenerates its SSH
# host keys. The old PUBLIC key therefore stays dormant in existing VMs'
# cloud-init config; it grants nothing unless that user-data changes, and then
# only to a holder of the old private key. New VMs get the new key: they read
# /root/tappaas/tappaas-cicd.pub on the node, which rotate refreshes.
#
# The console debug copy: the installer puts the mothership's PRIVATE key on the
# nodes as /root/tappaas/tappaas-cicd.key, deliberately — from a node's console
# or web-GUI Shell it reaches the mothership (and from there every VM) when
# nothing else does. No script reads it. rotate and recover REFRESH it with the
# current key on every node that has one; they never delete it — after recover
# it would otherwise hold the key that was lost.
#
# Refuses to run while update-tappaas.service is active — the sweep holds SSH
# sessions on the key being changed.
#
# Exit: 0 done · 1 failed (the report says what state each target is in) · 2 usage

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh
tappaas_require_operator

readonly CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
readonly KEY="${HOME}/.ssh/id_ed25519"
readonly CLUSTER_FILE="/etc/pve/priv/authorized_keys"
readonly VM_FILE="/home/tappaas/.ssh/authorized_keys"
readonly SSHO=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)

VERB="${1:-}"; shift || true
DRY=0; SKIP_UNREACHABLE=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --skip-unreachable) SKIP_UNREACHABLE=1 ;;
        *) error "unknown option: $a"; exit 2 ;;
    esac
done
case "${VERB}" in status|rotate|recover) ;; *)
    echo "Usage: cicd-key.sh status | rotate [--dry-run] [--skip-unreachable] | recover [--dry-run]" >&2; exit 2 ;;
esac

fp_file() { ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'; }

# ── the helper that edits an authorized_keys file, shipped to the target ──
# POSIX sh, so it runs over SSH on a node or a VM and through `qm guest exec`
# (where PATH is minimal — hence the explicit PATH). Args: FILE MODE PUB FP.
#   add     ensure PUB is present
#   revoke  drop every line commented tappaas-cicd whose fingerprint is not FP
#   replace add, then revoke
# Never writes a file that would not contain FP. Exit 3 = no such user (skip).
read -r -d '' EDIT_HELPER <<'SH'
PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
set -eu
F="$1"; MODE="$2"; PUB="$3"; FP="$4"
# Edit the REAL file: a node's /root/.ssh/authorized_keys is a symlink into
# /etc/pve, and renaming over the link would un-share that node's keys.
[ -L "$F" ] && F=$(readlink -f "$F")
d=$(dirname "$F")
case "$F" in /home/*) [ -d "$(dirname "$d")" ] || { echo "SKIP no $(dirname "$d")"; exit 3; } ;; esac
[ -d "$d" ] || { mkdir -p "$d"; chmod 700 "$d"; }
[ -f "$F" ] || : > "$F"
tmp="$F.tappaas-new"; : > "$tmp"; have=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;; esac
  f=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || f=""
  c=${line##* }
  if [ "$f" = "$FP" ]; then
    [ "$have" -eq 1 ] && continue
    have=1
  elif [ "$MODE" != add ] && [ "$c" = tappaas-cicd ]; then
    echo "revoked $f"; continue
  fi
  printf '%s\n' "$line" >> "$tmp"
done < "$F"
if [ "$MODE" != revoke ] && [ "$have" -eq 0 ]; then printf '%s\n' "$PUB" >> "$tmp"; have=1; echo "added $FP"; fi
[ "$have" -eq 1 ] || { rm -f "$tmp"; echo "ABORT $FP would not be present in $F"; exit 1; }
case "$F" in /etc/pve/*) ;; *) chown --reference="$d" "$tmp" 2>/dev/null || true; chmod 600 "$tmp" ;; esac
mv "$tmp" "$F"
case "$F" in /etc/pve/*) ;; *) chown --reference="$d" "$F" 2>/dev/null || true ;; esac
echo "ok"
SH

sq() { printf "'%s'" "$1"; }   # the pubkey and paths contain no single quotes

# edit_over_ssh <user@host> <file> <mode> <pub> <fp> [identity]
edit_over_ssh() {
    local id=()
    [[ -n "${6:-}" ]] && id=(-i "$6" -o IdentitiesOnly=yes)
    ssh "${SSHO[@]}" "${id[@]}" "$1" "sh -s -- $(sq "$2") $(sq "$3") $(sq "$4") $(sq "$5")" <<< "${EDIT_HELPER}"
}

# edit_via_agent <node> <vmid> <file> <mode> <pub> <fp> — through qemu-guest-agent
edit_via_agent() {
    local script b64 out rc
    script="set -- $(sq "$3") $(sq "$4") $(sq "$5") $(sq "$6")
${EDIT_HELPER}"
    b64="$(printf '%s' "${script}" | base64 | tr -d '\n')"
    out="$(ssh -n "${SSHO[@]}" "root@$1.mgmt.internal" \
        "qm guest exec $2 --timeout 60 -- /bin/sh -c 'PATH=/run/current-system/sw/bin:/usr/bin:/bin; echo ${b64} | base64 -d | sh'" 2>&1)"
    rc="$(jq -r '.exitcode // 1' <<< "${out}" 2>/dev/null || echo 1)"
    jq -r '."out-data" // empty' <<< "${out}" 2>/dev/null | tr '\n' ' '
    [[ "${rc}" == "0" ]] && return 0
    [[ "${rc}" == "3" ]] && return 3
    [[ -z "$(jq -r '.exitcode // empty' <<< "${out}" 2>/dev/null)" ]] && printf '%s ' "${out}"
    return 1
}

# probe <user@host> [identity] → ok | refused | hostkey | unreachable
# "refused" is the only answer that means "this machine does not trust the key".
# A host-key mismatch or no answer means "cannot tell" — and a rotation that
# treated those as "not a target" would leave the old key valid there.
probe() {
    local id=() err
    [[ -n "${2:-}" ]] && id=(-i "$2" -o IdentitiesOnly=yes)
    err="$(ssh -n "${SSHO[@]}" -o PasswordAuthentication=no "${id[@]}" "$1" true 2>&1 >/dev/null)" && { echo ok; return; }
    case "${err}" in
        *"Permission denied"*) echo refused ;;
        *"Host key verification failed"*|*"IDENTIFICATION HAS CHANGED"*) echo hostkey ;;
        *) echo unreachable ;;
    esac
}
reach() { [[ "$(probe "$@")" == ok ]]; }

# ── inventory ────────────────────────────────────────────────────────
PRIMARY="$(get_primary_node_fqdn)"
NODES="$(ssh -n "${SSHO[@]}" "root@${PRIMARY}" \
    "pvesh get /cluster/resources --type node --output-format json" 2>/dev/null \
    | jq -r '.[] | select(.status=="online") | .node' | sort)"
[[ -n "${NODES}" ]] || { error "cannot list the cluster nodes through ${PRIMARY} with the current key"
    [[ "${VERB}" == recover ]] && { error "put this mothership's key on the nodes first — in any node's web-GUI Shell run:"
        error "  echo '$(cat "${KEY}.pub")' >> ${CLUSTER_FILE}"; }
    exit 1; }
GUESTS="$(ssh -n "${SSHO[@]}" "root@${PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
    | jq -r '.[] | select(.type=="qemu" and (.template // 0) == 0) | "\(.vmid) \(.node)"')"

# One line per VM module: "<module> <vmid> <node> <tappaas@fqdn>"
VMS=""
for f in "${CONFIG_DIR}"/*.json; do
    jq -e '(.vmid // empty) and ((.status // "") | test("^(archived|external)$") | not)' "$f" >/dev/null 2>&1 || continue
    m="$(basename "$f" .json)"; vmid="$(jq -r '.vmid' "$f")"
    node="$(awk -v v="${vmid}" '$1 == v { print $2 }' <<< "${GUESTS}")"
    [[ -n "${node}" ]] || continue   # not a VM (an LXC, or not on the cluster)
    VMS+="${m} ${vmid} ${node} tappaas@$(jq -r ".vmname // \"${m}\"" "$f").$(jq -r '.zone0 // "mgmt"' "$f").internal"$'\n'
done
VMS="${VMS%$'\n'}"

CUR_FP="$(fp_file "${KEY}.pub")"
CUR_PUB="$(cat "${KEY}.pub")"

stale_in() {   # stale_in <ssh-target> <file> — tappaas-cicd fingerprints other than current
    ssh -n "${SSHO[@]}" "$1" "cat $2 2>/dev/null" 2>/dev/null \
        | awk '$NF == "tappaas-cicd"' | while IFS= read -r l; do
            f="$(printf '%s\n' "$l" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
            [[ "$f" != "${CUR_FP}" ]] && printf '%s\n' "$f"
        done
}

# ── status ───────────────────────────────────────────────────────────
do_status() {
    info "${BOLD}Mothership key${CL}: ${CUR_FP}"
    info "${BOLD}Nodes${CL} (root, ${CLUSTER_FILE} — cluster-wide)"
    for n in ${NODES}; do
        if reach "root@${n}.mgmt.internal"; then info "  ${GN}✓${CL} ${n}"; else error "  ✗ ${n}: current key refused"; fi
    done
    local s; s="$(stale_in "root@${PRIMARY}" "${CLUSTER_FILE}" | wc -l)"
    [[ "$s" -eq 0 ]] && info "  no stale mothership keys" || warn "  ${s} stale mothership key(s) still trusted as root on every node"
    local dbg f
    for n in ${NODES}; do
        f="$(ssh -n "${SSHO[@]}" "root@${n}.mgmt.internal" \
            "test -f /root/tappaas/tappaas-cicd.key && ssh-keygen -y -f /root/tappaas/tappaas-cicd.key | ssh-keygen -lf - | awk '{print \$2}'" 2>/dev/null)"
        if [[ -z "${f}" ]]; then dbg+="${n}: none  "
        elif [[ "${f}" == "${CUR_FP}" ]]; then dbg+="${n}: current  "
        else warn "  ${n}: console debug key is STALE (${f}) — rotate or recover refreshes it"; dbg+="${n}: stale  "; fi
    done
    info "  console debug key (/root/tappaas/tappaas-cicd.key): ${dbg}"
    info "${BOLD}VMs${CL} (tappaas, ${VM_FILE})"
    while read -r m vmid node tgt; do
        [[ -n "$m" ]] || continue
        case "$(probe "${tgt}")" in
            ok) s="$(stale_in "${tgt}" "${VM_FILE}" | wc -l)"
                [[ "$s" -eq 0 ]] && info "  ${GN}✓${CL} ${m}" || warn "  ${m}: ${s} stale mothership key(s)" ;;
            refused) info "  - ${m}: does not take this key (not a target)" ;;
            hostkey) error "  ✗ ${m}: its host key does not match ~/.ssh/known_hosts — cannot tell whether it trusts this key" ;;
            *) warn "  ? ${m}: no answer (stopped?) — cannot tell whether it trusts this key" ;;
        esac
    done <<< "${VMS}"
}

if [[ "${VERB}" == status ]]; then do_status; exit 0; fi

if systemctl is-active --quiet update-tappaas.service; then
    error "update-tappaas.service is running — it holds SSH sessions on this key. Try again when it has finished."
    exit 1
fi

FAILED=0

# ── rotate ───────────────────────────────────────────────────────────
do_rotate() {
    local n m vmid node tgt out
    info "${BOLD}Step 1: what the current key reaches${CL}"
    for n in ${NODES}; do
        reach "root@${n}.mgmt.internal" || { error "  ${n}: the current key is refused — rotate needs it everywhere (use recover)"; exit 1; }
    done
    local targets="" doubt="" skipped=""
    while read -r m vmid node tgt; do
        [[ -n "$m" ]] || continue
        case "$(probe "${tgt}")" in
            ok) targets+="${m} ${tgt}"$'\n' ;;
            refused) ;;
            hostkey) doubt+="${m} (host key does not match known_hosts) " ;;
            *) if [[ "${SKIP_UNREACHABLE}" -eq 1 ]]; then skipped+="${m} "; else doubt+="${m} (no answer) "; fi ;;
        esac
    done <<< "${VMS}"
    targets="${targets%$'\n'}"
    if [[ -n "${doubt}" ]]; then
        error "  cannot tell whether these trust the current key: ${doubt}"
        error "  A rotation that skipped them could leave the old key valid there, so none is started."
        error "  Host key: confirm it (e.g. read /etc/ssh/ssh_host_ed25519_key.pub through 'qm guest exec'), then ssh-keygen -R <host>."
        error "  No answer: start the VM, or re-run with --skip-unreachable to leave it out knowingly."
        exit 1
    fi
    ROTATE_SKIPPED="${skipped}"
    info "  nodes: $(echo ${NODES}) · VMs: $(awk '{print $1}' <<< "${targets}" | tr '\n' ' ')"
    if [[ "${DRY}" -eq 1 ]]; then
        info "DRY RUN — would generate a new key, add it to ${CLUSTER_FILE} and to the $(grep -c . <<< "${targets}") VMs above,"
        info "verify it, switch, then revoke every other tappaas-cicd key and refresh the console debug key on the nodes."
        return 0
    fi

    local ts new; ts="$(date +%Y%m%d-%H%M%S)"; new="${KEY}.new-${ts}"
    ssh-keygen -q -t ed25519 -N "" -C "tappaas-cicd" -f "${new}"
    local NEW_FP NEW_PUB; NEW_FP="$(fp_file "${new}.pub")"; NEW_PUB="$(cat "${new}.pub")"
    info "${BOLD}Step 2: add the new key${CL} ${NEW_FP}"
    out="$(edit_over_ssh "root@${PRIMARY}" "${CLUSTER_FILE}" add "${NEW_PUB}" "${NEW_FP}")" \
        || { error "  nodes: ${out}"; exit 1; }
    info "  nodes: $(tr '\n' ' ' <<< "${out}")"
    while read -r m tgt; do
        [[ -n "$m" ]] || continue
        out="$(edit_over_ssh "${tgt}" "${VM_FILE}" add "${NEW_PUB}" "${NEW_FP}" 2>&1)" \
            && info "  ${m}: $(tr '\n' ' ' <<< "${out}")" || { error "  ${m}: ${out}"; FAILED=1; }
    done <<< "${targets}"

    info "${BOLD}Step 3: prove the new key reaches every target${CL}"
    for n in ${NODES}; do
        reach "root@${n}.mgmt.internal" "${new}" || { error "  ${n}: new key refused"; FAILED=1; }
    done
    while read -r m tgt; do
        [[ -n "$m" ]] || continue
        reach "${tgt}" "${new}" || { error "  ${m}: new key refused"; FAILED=1; }
    done <<< "${targets}"
    if [[ "${FAILED}" -ne 0 ]]; then
        error "Stopping BEFORE the switch: the current key is unchanged and still works everywhere."
        error "The new key is added where it succeeded (harmless) and kept at ${new}."
        exit 1
    fi
    info "  ${GN}✓${CL} new key accepted by every node and VM"

    info "${BOLD}Step 4: switch${CL}"
    cp -p "${KEY}" "${KEY}.old-${ts}" && cp -p "${KEY}.pub" "${KEY}.pub.old-${ts}"
    mv "${new}" "${KEY}" && mv "${new}.pub" "${KEY}.pub"
    info "  ~/.ssh/id_ed25519 is the new key; the old one is ${KEY}.old-${ts}"

    CUR_FP="${NEW_FP}"; CUR_PUB="${NEW_PUB}"
    revoke_everywhere "${targets}" "${targets}"
}

# revoke_everywhere <ssh-revoke list> <verify list> — lines "module tappaas@fqdn".
# rotate passes the same list twice; recover has already revoked on each VM
# through the agent (replace mode) and passes only a verify list.
revoke_everywhere() {
    local m tgt out n
    info "${BOLD}Step 5: revoke every other mothership key${CL}"
    out="$(edit_over_ssh "root@${PRIMARY}" "${CLUSTER_FILE}" revoke "${CUR_PUB}" "${CUR_FP}" 2>&1)" \
        && info "  nodes: $(tr '\n' ' ' <<< "${out}")" || { error "  nodes: ${out}"; FAILED=1; }
    for n in ${NODES}; do
        scp -q "${SSHO[@]}" "${KEY}.pub" "root@${n}.mgmt.internal:/root/tappaas/tappaas-cicd.pub" \
            || { error "  ${n}: could not refresh tappaas-cicd.pub"; FAILED=1; }
        # The console debug copy: refresh it where one exists, never delete it.
        if ssh -n "${SSHO[@]}" "root@${n}.mgmt.internal" "test -f /root/tappaas/tappaas-cicd.key" 2>/dev/null; then
            scp -q "${SSHO[@]}" "${KEY}" "root@${n}.mgmt.internal:/root/tappaas/tappaas-cicd.key" \
                && ssh -n "${SSHO[@]}" "root@${n}.mgmt.internal" "chmod 600 /root/tappaas/tappaas-cicd.key" \
                || { error "  ${n}: could not refresh the console debug key"; FAILED=1; }
        fi
    done
    while read -r m tgt; do
        [[ -n "$m" ]] || continue
        out="$(edit_over_ssh "${tgt}" "${VM_FILE}" revoke "${CUR_PUB}" "${CUR_FP}" 2>&1)" \
            && info "  ${m}: $(tr '\n' ' ' <<< "${out}")" || { error "  ${m}: ${out}"; FAILED=1; }
    done <<< "$1"

    info "${BOLD}Step 6: verify${CL}"
    for n in ${NODES}; do
        reach "root@${n}.mgmt.internal" && info "  ${GN}✓${CL} ${n}" || { error "  ✗ ${n}"; FAILED=1; }
    done
    while read -r m tgt; do
        [[ -n "$m" ]] || continue
        case "$(probe "${tgt}")" in
            ok) info "  ${GN}✓${CL} ${m}" ;;
            hostkey) warn "  ${m}: key in place, but SSH is blocked by a stale ~/.ssh/known_hosts entry — confirm the host key, then ssh-keygen -R" ;;
            refused) error "  ✗ ${m}: refused"; FAILED=1 ;;
            *) warn "  ? ${m}: no answer to verify" ;;
        esac
    done <<< "$2"
    [[ -z "${ROTATE_SKIPPED:-}" ]] || warn "NOT rotated (skipped, no answer): ${ROTATE_SKIPPED}— the old key may still be valid there"
}

# ── recover ──────────────────────────────────────────────────────────
do_recover() {
    local n m vmid node tgt out rc os targets="" skipped=""
    info "${BOLD}Step 1: the current key must reach the nodes${CL} (${CUR_FP})"
    for n in ${NODES}; do
        reach "root@${n}.mgmt.internal" || { error "  ${n}: refused. In any node's web-GUI Shell run:"
            error "    echo '${CUR_PUB}' >> ${CLUSTER_FILE}"; exit 1; }
    done
    info "  ${GN}✓${CL} all nodes"
    if [[ "${DRY}" -eq 1 ]]; then
        info "DRY RUN — would put the current key on each VM below through its guest agent, then revoke every other tappaas-cicd key:"
        while read -r m vmid node tgt; do [[ -n "$m" ]] && info "  ${m} (VM ${vmid} on ${node})"; done <<< "${VMS}"
        return 0
    fi
    info "${BOLD}Step 2: install the key on every VM through its guest agent${CL}"
    while read -r m vmid node tgt; do
        [[ -n "$m" ]] || continue
        # Only a Linux guest has the key file this edits. A Windows guest DOES
        # trust the mothership key (templates/winserver injects it) but keeps it
        # elsewhere; anything else — the OPNsense firewall — trusts its own key.
        os="$(ssh -n "${SSHO[@]}" "root@${node}.mgmt.internal" "qm config ${vmid}" 2>/dev/null | awk -F': ' '/^ostype:/ {print $2}')"
        case "${os}" in
            l2*|"") ;;
            win*) warn "  ${m}: Windows VM — this script does not edit its key file; add the key by hand"; skipped+="${m} "; continue ;;
            *) info "  - ${m}: not a Linux VM (ostype ${os}) — not a mothership-key target"; continue ;;
        esac
        if ! ssh -n "${SSHO[@]}" "root@${node}.mgmt.internal" "qm agent ${vmid} ping" >/dev/null 2>&1; then
            warn "  ${m}: no guest agent answering — add the key by hand (VM console)"; skipped+="${m} "; continue
        fi
        out="$(edit_via_agent "${node}" "${vmid}" "${VM_FILE}" replace "${CUR_PUB}" "${CUR_FP}")"; rc=$?
        case "${rc}" in
            0) info "  ${m}: ${out}"; targets+="${m} ${tgt}"$'\n' ;;
            3) info "  - ${m}: no tappaas user (not a target)" ;;
            *) error "  ${m}: ${out}"; FAILED=1 ;;
        esac
    done <<< "${VMS}"
    targets="${targets%$'\n'}"
    revoke_everywhere "" "${targets}"
    [[ -z "${skipped}" ]] || warn "Not reached (no agent): ${skipped}"
}

case "${VERB}" in
    rotate)  do_rotate ;;
    recover) do_recover ;;
esac

if [[ "${FAILED}" -ne 0 ]]; then
    error "Finished WITH FAILURES — see above."
    exit 1
fi
info "${GN}✓${CL} done"
exit 0
