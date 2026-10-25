#!/usr/bin/env bash
# lib/verify-repo.sh — is this revision a release its owners signed? (ADR-033)
#
# A repository is verified by its RELEASE TAGS, not its commits: on a staging or
# production branch the tip must be exactly an annotated `v<MAJOR>.<MINOR>[.N]`
# tag, SSH-signed by a key listed in `.tappaas/allowed_signers` (D1, D2, D4).
#
# The rule that keeps a repository from vouching for itself (D4): the signers
# that count are the ones listed AT THE BASE — the release this site last
# verified, or failing that the revision it already runs — never the ones in the
# revision being checked. A key added in a release signs the release AFTER it.
#
# What a tag message carries besides the train's own lines (D3):
#   tree-sha256: sha256:<hex>   the tree, hashed without git's SHA-1 (below)
#   signers-at:  <commit>       where the allowed_signers that authorized it lives
#
# Sourced, not executed. Needs git >= 2.34 (SSH signatures), ssh-keygen, jq, python3.
# Callers define info()/warn()/error()/debug(); fallbacks below.

command -v info  >/dev/null 2>&1 || info()  { echo "$*"; }
command -v warn  >/dev/null 2>&1 || warn()  { echo "WARN: $*" >&2; }
command -v error >/dev/null 2>&1 || error() { echo "ERROR: $*" >&2; }
command -v debug >/dev/null 2>&1 || debug() { :; }

VERIFY_SIGNERS_PATH=".tappaas/allowed_signers"
# Keys that must never verify again, whatever date a tag claims: a stolen key
# goes here (one public key per line, `#` comments allowed).
VERIFY_REVOKED_PATH=".tappaas/revoked_signers"
# Which clock a key's valid-after/valid-before is read against:
#   now  (default) today — for anything about to be TRUSTED: a site moving to a
#        release, a fresh clone, a tag being cut. Git itself reads the tag's own
#        date, which whoever signs it chooses, so an expired or retired key
#        could otherwise sign a back-dated tag.
#   tag  the tag's date — for reporting on a release already running, so a
#        release signed while its key was valid stays verified after the key
#        expires.
VERIFY_AT="${VERIFY_AT:-now}"
VERIFY_TAG_RE='^v[0-9]+\.[0-9]+(\.[0-9]+)?$'
# The recovery key (ADR-033 D4a) is any key whose principal is recovery@<...>.
# It is kept offline and may sign only a release that changes nothing but
# .tappaas/ — enough to enrol new signers after both have lost theirs, never
# enough to ship code.
VERIFY_RECOVERY_RE='^recovery@'

# verify_tree_sha256 <path> <commit>
# A SHA-256 over the tree's CONTENT, so a signature on the tag does not rest on
# git's SHA-1 object ids alone (ADR-033 Context, D3). One line per entry in git's
# own tree order — `<mode> <sha256 of the blob> <path>` — hashed once more. A
# symlink hashes its target; a submodule its commit id (it has no content here).
# Printed as `sha256:<hex>`.
verify_tree_sha256() {
    local path="$1" commit="$2"
    git -C "${path}" rev-parse -q --verify "${commit}^{tree}" >/dev/null || return 1
    # One `git cat-file --batch` stream for every blob: a process per file took
    # 18 s on this repository, the stream well under one.
    python3 -I - "${path}" "${commit}" <<'PY'
import hashlib, subprocess, sys
path, commit = sys.argv[1], sys.argv[2]
ls = subprocess.run(["git", "-C", path, "ls-tree", "-r", "-z", "--full-tree", commit],
                    check=True, capture_output=True).stdout
entries = []
for e in ls.split(b"\0"):
    if not e:
        continue
    meta, p = e.split(b"\t", 1)
    mode, typ, oid = meta.split(b" ")
    entries.append((mode, typ, oid, p))
blobs = [oid for _, typ, oid, _ in entries if typ == b"blob"]
cat = subprocess.Popen(["git", "-C", path, "cat-file", "--batch"],
                       stdin=subprocess.PIPE, stdout=subprocess.PIPE)
cat.stdin.write(b"".join(o + b"\n" for o in blobs)); cat.stdin.close()
digest = {}
for oid in blobs:
    hdr = cat.stdout.readline().split(b" ")
    size = int(hdr[2])
    digest[oid] = hashlib.sha256(cat.stdout.read(size)).hexdigest().encode()
    cat.stdout.read(1)
cat.wait()
out = hashlib.sha256()
for mode, typ, oid, p in entries:
    out.update(mode + b" " + (digest[oid] if typ == b"blob" else oid) + b" " + p + b"\n")
print("sha256:" + out.hexdigest())
PY
}

# verify_signers_at <path> <commit> <outfile>
# Writes the allowed_signers of <commit> to <outfile>. 0 when it lists at least
# one key; 1 when the file is absent or holds only comments — the repository is
# then unsigned by declaration (D9).
verify_signers_at() {
    local path="$1" commit="$2" out="$3"
    git -C "${path}" show "${commit}:${VERIFY_SIGNERS_PATH}" >"${out}" 2>/dev/null || { : >"${out}"; return 1; }
    grep -qvE '^[[:space:]]*(#|$)' "${out}"
}

# verify_keyring <path> <commit> <signers-out> <revoked-out>
# The keys that may sign, as of <commit>: its allowed_signers — without the
# keys whose validity window excludes today when VERIFY_AT=now — and its
# revoked_signers (comments stripped; empty when there are none). Returns as
# verify_signers_at does, on the file as written: a repository whose keys have
# all expired still SIGNS, so its releases fail rather than read as unsigned.
verify_keyring() {
    local path="$1" commit="$2" out="$3" revoked="$4" raw now
    : >"${revoked}"
    git -C "${path}" show "${commit}:${VERIFY_REVOKED_PATH}" 2>/dev/null \
        | grep -vE '^[[:space:]]*(#|$)' >"${revoked}" || true
    raw="$(mktemp)"
    if ! verify_signers_at "${path}" "${commit}" "${raw}"; then
        cp "${raw}" "${out}"; rm -f "${raw}"; return 1
    fi
    if [[ "${VERIFY_AT}" == tag ]]; then
        cp "${raw}" "${out}"; rm -f "${raw}"; return 0
    fi
    now="${VERIFY_NOW:-$(date -u +%Y%m%d%H%M%S)}"
    # A timestamp is YYYYMMDD[HHMM[SS]]; right-padded to 14 digits it compares
    # as a string. valid-before is exclusive, valid-after inclusive (ssh-keygen).
    awk -v now="${now}" '
        function ts(line, opt,   m) {
            if (match(line, opt "=\"?[0-9]+")) {
                m = substr(line, RSTART, RLENGTH); sub(/^[^0-9]*/, "", m)
                while (length(m) < 14) m = m "0"
                return m
            }
            return ""
        }
        /^[[:space:]]*(#|$)/ { print; next }
        { vb = ts($0, "valid-before"); va = ts($0, "valid-after")
          if (vb != "" && now >= vb) next
          if (va != "" && now <  va) next
          print }' "${raw}" >"${out}"
    rm -f "${raw}"
    return 0
}

# verify_release_tags <path> <commit> — the annotated release tags naming
# <commit>, highest version first.
verify_release_tags() {
    local path="$1" commit="$2" t
    git -C "${path}" tag --points-at "${commit}" 2>/dev/null | sort -rV | while IFS= read -r t; do
        [[ "${t}" =~ ${VERIFY_TAG_RE} ]] || continue
        [[ "$(git -C "${path}" cat-file -t "refs/tags/${t}" 2>/dev/null)" == tag ]] || continue
        printf '%s\n' "${t}"
    done
}

# verify_tag_field <path> <tag> <field> — `<field>: <value>` from the tag message.
verify_tag_field() {
    git -C "$1" cat-file tag "refs/tags/$2" 2>/dev/null \
        | sed -n "s/^$3:[[:space:]]*//p" | head -1
}

# verify_tag_signature <path> <tag> <signers-file> [<revoked-file>]
# Prints `<principal> <key fingerprint>` for a good signature by a listed key
# and returns 0; otherwise prints why (git's own words) and returns 1. Reasons go
# to stdout because callers run it in $(...). The tag object must
# also carry the name it is published under: a signed v2.1 object re-published
# as v2.9 names an old revision under a new number.
verify_tag_signature() {
    local path="$1" tag="$2" signers="$3" revoked="${4:-}" out name
    local -a rev=()
    [[ -n "${revoked}" && -s "${revoked}" ]] && rev=(-c gpg.ssh.revocationFile="${revoked}")
    name="$(git -C "${path}" cat-file tag "refs/tags/${tag}" 2>/dev/null | sed -n 's/^tag //p' | head -1)"
    if [[ "${name}" != "${tag}" ]]; then
        printf "tag object is named '%s', published as '%s'\n" "${name:-?}" "${tag}"
        return 1
    fi
    out="$(git -C "${path}" -c gpg.ssh.allowedSignersFile="${signers}" ${rev[@]+"${rev[@]}"} verify-tag --raw "${tag}" 2>&1)" || {
        out="$(printf '%s\n' "${out}" | grep -v '^$' | tail -1)"
        printf '%s\n' "${out:-no valid signature}"
        return 1
    }
    # Good "git" signature for <principal> with <TYPE> key SHA256:<fp>
    printf '%s\n' "${out}" | sed -n 's/^Good "git" signature for \(.*\) with .* key \(SHA256:[^ ]*\).*/\1 \2/p' | head -1
}

# verify_target <path> <target-commit> <base-commit>
# Is <target> a release that the signers at <base> — or, through the releases
# in between, the signers they authorized — signed? The CHAIN: every release tag
# between <base> and <target>, oldest first, that verifies against the current
# base becomes the next base, so a key enrolled in a release the site never
# stopped at still counts once that release is in the chain. A release that does
# not verify is passed over, never trusted: only a release signed by a key already
# trusted can change which keys are trusted. Then <target> itself is checked
# against the last base reached. When <base> is not an ancestor of <target>
# (a forge change, a forced move) there is no chain, only <target> against <base>.
# Sets VERIFY_* for <target>, as _verify_one does, plus VERIFY_BASE — the
# release it was finally checked against.
verify_target() {
    local path="$1" target="$2" base="$3" c rc
    VERIFY_BASE="${base}"
    if [[ -n "${base}" ]] && verify_moves_forward "${path}" "${base}" "${target}"; then
        while IFS= read -r c; do
            [[ -n "${c}" ]] || continue
            rc=0; _verify_one "${path}" "${c}" "${VERIFY_BASE}" || rc=$?
            # 0 verified; 4: the base signs nothing, so neither does this step —
            # the chain moves on as an update stopping there would have.
            if [[ "${rc}" == 0 || "${rc}" == 4 ]]; then VERIFY_BASE="${c}"; fi
        done < <(verify_chain_commits "${path}" "${base}" "${target}")
    fi
    _verify_one "${path}" "${target}" "${VERIFY_BASE}"
}

# verify_chain_commits <path> <base> <target> — the commits strictly between
# <base> and <target> that carry a release tag, oldest first.
verify_chain_commits() {
    local path="$1" base="$2" target="$3" t c tc
    local -A tagged=()
    tc="$(git -C "${path}" rev-parse -q --verify "${target}^{commit}" 2>/dev/null)" || return 0
    while IFS= read -r t; do
        [[ "${t}" =~ ${VERIFY_TAG_RE} ]] || continue
        c="$(git -C "${path}" rev-parse -q --verify "refs/tags/${t}^{commit}" 2>/dev/null)" || continue
        [[ "${c}" != "${tc}" ]] && tagged["${c}"]=1
    done < <(git -C "${path}" tag --merged "${tc}" --no-merged "${base}" 2>/dev/null)
    [[ ${#tagged[@]} -gt 0 ]] || return 0
    git -C "${path}" rev-list --topo-order --reverse "${base}..${tc}" 2>/dev/null \
        | while IFS= read -r c; do [[ -n "${tagged[${c}]:-}" ]] && printf '%s\n' "${c}"; done
    return 0
}

# _verify_one <path> <target-commit> <base-commit>
# Is <target> a release the signers at <base> authorized — one step, no chain? Sets:
#   VERIFY_STATUS  verified | unsigned-declared | failed
#   VERIFY_TAG VERIFY_SIGNER VERIFY_TREE VERIFY_REASON
# Returns 0 verified, 4 unsigned-declared (no signers at the base), 1 failed.
# Going backwards is the caller's check (verify_moves_forward): the base of a
# fresh clone has no history to compare with.
_verify_one() {
    local path="$1" target="$2" base="$3" signers revoked t sig want got
    VERIFY_STATUS="" VERIFY_TAG="" VERIFY_SIGNER="" VERIFY_TREE="" VERIFY_REASON=""
    signers="$(mktemp)"; revoked="$(mktemp)"
    if ! verify_keyring "${path}" "${base}" "${signers}" "${revoked}"; then
        rm -f "${signers}" "${revoked}"
        VERIFY_STATUS="unsigned-declared"
        VERIFY_REASON="no keys in ${VERIFY_SIGNERS_PATH} at $(git -C "${path}" rev-parse --short "${base}" 2>/dev/null || echo "${base}")"
        return 4
    fi
    local tags; tags="$(verify_release_tags "${path}" "${target}")"
    if [[ -z "${tags}" ]]; then
        rm -f "${signers}" "${revoked}"
        VERIFY_STATUS="failed"
        VERIFY_REASON="$(git -C "${path}" rev-parse --short "${target}" 2>/dev/null) is not a release tag"
        return 1
    fi
    VERIFY_REASON=""
    while IFS= read -r t; do
        sig="$(verify_tag_signature "${path}" "${t}" "${signers}" "${revoked}")" || {
            VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t}: ${sig}"; continue; }
        want="$(verify_tag_field "${path}" "${t}" tree-sha256)"
        got="$(verify_tree_sha256 "${path}" "${target}")"
        if [[ -z "${want}" ]]; then
            VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t}: signed, but carries no tree-sha256"; continue
        fi
        if [[ "${want}" != "${got}" ]]; then
            VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t}: tree-sha256 mismatch (tag ${want}, tree ${got})"; continue
        fi
        if [[ "${sig%% *}" =~ ${VERIFY_RECOVERY_RE} ]] && ! verify_only_signers_changed "${path}" "${base}" "${target}"; then
            VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t}: signed by the recovery key, which may sign only a release that changes nothing outside .tappaas/"; continue
        fi
        rm -f "${signers}" "${revoked}"
        VERIFY_STATUS="verified" VERIFY_TAG="${t}" VERIFY_SIGNER="${sig}" VERIFY_TREE="${got}" VERIFY_REASON=""
        return 0
    done <<<"${tags}"
    rm -f "${signers}" "${revoked}"
    VERIFY_STATUS="failed"
    return 1
}

# verify_only_signers_changed <path> <base> <target> — 0 when every file that
# differs between <base> and <target> is under .tappaas/. What a recovery-key
# signature may cover (D4a).
verify_only_signers_changed() {
    local f changed
    # Fails closed: a diff git cannot compute is not "nothing changed".
    changed="$(git -C "$1" diff --name-only "$2" "$3" 2>/dev/null)" || return 1
    while IFS= read -r f; do
        [[ -z "${f}" || "${f}" == .tappaas/* ]] || return 1
    done <<<"${changed}"
    return 0
}

# verify_moves_forward <path> <base> <target> — 0 when <target> descends from
# <base> (or is it). A validly signed OLD release is still validly signed: this
# is what refuses being moved back to it (D6). A rollback is an operator's act.
verify_moves_forward() {
    git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null
}

# ── The introduction: first trust for a fresh clone (D5) ───────────────
# A fresh clone runs nothing yet, so there is no base to read signers from. Its
# first trust comes from outside the repository: the fingerprints of the keys its
# owners sign with, published by them — site.json repositories[].trust.signers,
# written by the installer (TAPPaaS) or `repository add --signer`. No release
# number: the branch's current release is checked against them, and if the
# owners' keys have changed since, they publish the new fingerprints.

# verify_signers_fingerprints <signers-file> — the SHA256 fingerprint of every
# key the file lists, one per line.
verify_signers_fingerprints() {
    local line key
    grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | while IFS= read -r line; do
        key="$(grep -oE '(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+' <<<"${line}" | head -1)"
        [[ -n "${key}" ]] && ssh-keygen -lf - <<<"${key}" 2>/dev/null | awk '{print $2}'
    done
    return 0
}

# verify_introduction <path> <fingerprints> <target>
# Is <target> trusted on the owners' word? <fingerprints> is one SHA256:... or
# several, space-separated — any of them may have signed. <target> must be
# exactly a release tag, signed by a key whose fingerprint is one of them and
# which <target>'s own allowed_signers lists as valid (today, VERIFY_AT=now) and
# does not revoke, with a matching tree-sha256. An emergency (recovery@) key does
# not count here: what it may sign is judged against an earlier release, and a
# fresh clone has none. Sets VERIFY_* as verify_target does; VERIFY_INTRO_SIGNER
# is the matching `<principal> <fingerprint>`. Returns 0 trusted, 1 not.
verify_introduction() {
    local path="$1" fps="$2" target="$3" signers revoked tags t sig fp want got
    VERIFY_STATUS="failed" VERIFY_TAG="" VERIFY_SIGNER="" VERIFY_TREE="" VERIFY_REASON="" VERIFY_INTRO_SIGNER=""
    if [[ -z "${fps// /}" ]]; then
        VERIFY_REASON="no signer fingerprint given"; return 1
    fi
    target="$(git -C "${path}" rev-parse -q --verify "${target}^{commit}" 2>/dev/null)" \
        || { VERIFY_REASON="no commit to check"; return 1; }
    tags="$(verify_release_tags "${path}" "${target}")"
    if [[ -z "${tags}" ]]; then
        VERIFY_REASON="$(git -C "${path}" rev-parse --short "${target}") is not a release tag"; return 1
    fi
    signers="$(mktemp)"; revoked="$(mktemp)"
    if ! verify_keyring "${path}" "${target}" "${signers}" "${revoked}"; then
        rm -f "${signers}" "${revoked}"
        VERIFY_REASON="the release lists no keys in ${VERIFY_SIGNERS_PATH} — it signs nothing"; return 1
    fi
    while IFS= read -r t; do
        sig="$(verify_tag_signature "${path}" "${t}" "${signers}" "${revoked}")" || {
            VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t}: ${sig}"; continue; }
        fp="${sig##* }"
        case " ${fps} " in
            *" ${fp} "*) ;;
            *) VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t} is signed by ${sig}, which is not one of the given fingerprints"; continue ;;
        esac
        if [[ "${sig%% *}" =~ ${VERIFY_RECOVERY_RE} ]]; then
            VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t} is signed by an emergency key, which cannot start trust"; continue
        fi
        want="$(verify_tag_field "${path}" "${t}" tree-sha256)"
        got="$(verify_tree_sha256 "${path}" "${target}")"
        if [[ -z "${want}" || "${want}" != "${got}" ]]; then
            VERIFY_REASON="${VERIFY_REASON:+${VERIFY_REASON}; }${t}: tree-sha256 ${want:-missing} does not match the tree"; continue
        fi
        rm -f "${signers}" "${revoked}"
        # shellcheck disable=SC2034  # read by callers (repo_sync_introduce)
        VERIFY_INTRO_SIGNER="${sig}"
        VERIFY_STATUS="verified" VERIFY_TAG="${t}" VERIFY_SIGNER="${sig}" VERIFY_TREE="${got}" VERIFY_REASON=""
        return 0
    done <<<"${tags}"
    rm -f "${signers}" "${revoked}"
    return 1
}

# verify_introduce <path> <state-dir> <name> <fingerprints> <target>
# verify_introduction, then record <target> as the last verified release, so
# the next update takes its signers from there (the normal base rule).
# shellcheck disable=SC2034  # VERIFY_* are this library's results
verify_introduce() {
    local path="$1" dir="$2" name="$3" target
    target="$(git -C "${path}" rev-parse -q --verify "$5^{commit}" 2>/dev/null)" \
        || { VERIFY_STATUS="failed" VERIFY_REASON="no commit '$5'"; return 1; }
    verify_introduction "${path}" "$4" "${target}" || return 1
    verify_state_record "${dir}" "${name}" "${target}" \
        || { VERIFY_REASON="verified, but could not record it in ${dir}"; return 1; }
}

# verify_fingerprint_ok <fp> — 0 when <fp> looks like ssh-keygen's SHA256:... .
verify_fingerprint_ok() { [[ "$1" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; }

# ── Trust state (run state, not declaration) ────────────────────────────
# The last release a site verified per repository, in <dir>/<name>.json. It is
# the base for the next verification. site.json holds what the operator declares
# (requireSigned, an introduction); this holds what the runs found.

verify_state_file() { printf '%s/%s.json' "${1}" "${2}"; }

# verify_state_commit <dir> <name> — the last verified commit, or empty.
verify_state_commit() {
    local f; f="$(verify_state_file "$1" "$2")"
    [[ -r "${f}" ]] || return 0
    jq -r '.commit // empty' "${f}" 2>/dev/null
}

# verify_state_record <dir> <name> <commit> — after a verified move.
verify_state_record() {
    local dir="$1" name="$2" commit="$3" f tmp
    mkdir -p "${dir}" 2>/dev/null || return 1
    f="$(verify_state_file "${dir}" "${name}")"
    tmp="$(mktemp "${dir}/.${name}.XXXXXX")" || return 1
    jq -n --arg tag "${VERIFY_TAG}" --arg commit "${commit}" --arg signer "${VERIFY_SIGNER}" \
          --arg tree "${VERIFY_TREE}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{tag: $tag, commit: $commit, signer: $signer, treeSha256: $tree, verifiedAt: $at}' >"${tmp}" \
        && mv "${tmp}" "${f}"
}

# verify_base <path> <state-dir> <name> — what the signers are read from: the
# last verified release if this checkout still has it, else what it runs now.
# Trusting the running revision is no weaker than today — it is the code already
# executing here — and it is how a site that predates ADR-033 starts verifying.
verify_base() {
    local c; c="$(verify_state_commit "$2" "$3")"
    if [[ -n "${c}" ]] && git -C "$1" cat-file -e "${c}^{commit}" 2>/dev/null; then
        printf '%s\n' "${c}"; return 0
    fi
    git -C "$1" rev-parse -q --verify HEAD
}

# ── Making a release tag (tappaas-train) ────────────────────────────────

# verify_tag_lines <path> <commit> — the lines ADR-033 D3 adds to a release
# tag's message: the tree's SHA-256 and the commit whose allowed_signers
# authorizes the signature. signers-at is empty for a repository that signs
# nothing yet.
verify_tag_lines() {
    local path="$1" commit="$2" tree at
    tree="$(verify_tree_sha256 "${path}" "${commit}")" || return 1
    at="$(git -C "${path}" log -1 --format=%H "${commit}" -- "${VERIFY_SIGNERS_PATH}" 2>/dev/null || true)"
    printf 'tree-sha256: %s\n' "${tree}"
    [[ -n "${at}" ]] && printf 'signers-at: %s\n' "${at}"
    return 0
}

# verify_repo_signs <path> <commit> — 0 when <commit> lists signing keys, i.e.
# its release tags must be signed.
verify_repo_signs() {
    local f rc=0; f="$(mktemp)"
    verify_signers_at "$1" "$2" "${f}" || rc=1
    rm -f "${f}"; return "${rc}"
}
