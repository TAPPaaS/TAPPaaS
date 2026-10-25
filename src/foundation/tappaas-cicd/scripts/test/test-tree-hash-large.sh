#!/usr/bin/env bash
# test-tree-hash-large.sh — the release tree hash (verify_tree_sha256, ADR-033
# D3) finishes on a tree larger than a pipe, and its value does not change.
#
# It fed every blob id to `git cat-file --batch` before reading any output: on a
# tree whose ids and contents overflow a 64 KiB Linux pipe, git stopped reading
# and the two waited on each other for ever — the 2.3 boundary hung at its tag.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../../lib/verify-repo.sh"
pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok: $1"; else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }
command -v python3 >/dev/null || { echo "python3 not found — cannot run here."; exit 77; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
W="$(mktemp -d "${TMPDIR:-/tmp}/tree-hash.XXXXXX")"; trap 'rm -rf "${W}"' EXIT
git init -q "${W}/r"
for i in $(seq 1 2500); do printf 'file %05d %s\n' "${i}" "$(printf '%0200d' "${i}")" > "${W}/r/f${i}"; done
git -C "${W}/r" add -A && git -C "${W}/r" commit -qm big

# hash <commit> — the value, or HUNG when it has not finished in 60 s.
hash() {
    bash -c '. "$1"; verify_tree_sha256 "$2" "$3"' _ "${LIB}" "${W}/r" "$1" > "${W}/out" 2>&1 &
    local p=$! i
    for i in $(seq 1 60); do kill -0 "${p}" 2>/dev/null || break; sleep 1; done
    if kill -0 "${p}" 2>/dev/null; then pkill -P "${p}" 2>/dev/null; kill "${p}" 2>/dev/null; echo HUNG; return; fi
    cat "${W}/out"
}
got="$(hash HEAD)"
ck "a 2500-file tree is hashed (no deadlock)" "$([[ "${got}" == sha256:* ]] && echo done || echo "${got}")" "done"

# The value: what an independent reading of the same tree gives.
want="$(python3 - "${W}/r" <<'PY'
import hashlib, subprocess, sys
r = sys.argv[1]
out = hashlib.sha256()
for e in subprocess.run(["git", "-C", r, "ls-tree", "-r", "-z", "--full-tree", "HEAD"], capture_output=True, check=True).stdout.split(b"\0"):
    if not e: continue
    meta, p = e.split(b"\t", 1); mode, typ, oid = meta.split(b" ")
    blob = subprocess.run(["git", "-C", r, "cat-file", "blob", oid.decode()], capture_output=True, check=True).stdout
    out.update(mode + b" " + hashlib.sha256(blob).hexdigest().encode() + b" " + p + b"\n")
print("sha256:" + out.hexdigest())
PY
)"
ck "…and the value is the content hash, unchanged" "${got}" "${want}"

echo "test-tree-hash-large: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
