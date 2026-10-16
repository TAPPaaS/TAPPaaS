#!/usr/bin/env bash
# test-roadmap-cut.sh — release/roadmap-cut.py moves what a release carries out of the waves.
#
# On a throwaway ROADMAP.md: the ✅ rows of a wave and of Future Work move into a new release
# section under their wave and group; a group with nothing open leaves the waves, and a wave with
# no group left goes too; a `####` table that empties goes with its rows; `## Next release`
# becomes the summary (or a factual line when empty) and is emptied; the promoted release gets
# its production date; no row is lost or doubled; a second run and --check change nothing;
# --normalize rewrites the old `released in X: N` counts. Then the real ROADMAP.md: --normalize
# leaves it as it is (it is kept in the current form).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../../../.." && pwd)"
CUT="${ROOT}/release/roadmap-cut.py"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — cannot run here."; exit 77; }

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { grep -qF -- "$2" "$1" && echo yes || echo no; }

T="$(mktemp -d "${TMPDIR:-/tmp}/roadmapcut.XXXXXX")"
trap 'rm -rf "${T}"' EXIT
F="${T}/ROADMAP.md"
cat > "${F}" <<'EOF'
# Roadmap

## At a glance

old

## Future Work — not yet in a wave

| # | Issue | Note |
|---|-------|------|
| #50 | later | |
| ✅ #51 | finished outside a wave | done |

## Wave 2 — two

Wave two.

### G2.1 Mixed — Ease M · Risk L · released in 2.0: 3 · done for 2.1: 1 · open: 1

Mixed intent.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #10 | done in two | L | L | done |
| #11 | open in two | L | L | open |

#### Sub table

Sub prose.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #12 | sub done | L | L | done |

## Wave 1 — one

Wave one.

### ✅ G1.1 Finished — Ease L · Risk H · done for 2.1: 1

Finished intent.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #20 | done in one | L | H | done |

## Next release

<!-- next-release summary -->

<!-- /next-release summary -->

## Release 2.0 — staging 2026-09-01 · production at the next boundary

Tag `v2.0`.
EOF
rows() { grep -cE '^\| (✅ )?(FW )?#[0-9]+ \|' "$1"; }
before="$(rows "${F}")"
cp "${F}" "${T}/orig"

python3 "${CUT}" --file "${F}" --version 2.1 --date 2026-10-09 --check >/dev/null
ck "--check writes nothing"                              "" "$(diff -q "${T}/orig" "${F}")"

python3 "${CUT}" --file "${F}" --version 2.1 --date 2026-10-09 --promoted 2.0 >/dev/null; rc=$?
ck "a cut succeeds"                                      0 "${rc}"
ck "no row is lost or doubled"                           "${before}" "$(rows "${F}")"
ck "a release section is made"                           yes "$(has "${F}" '## Release 2.1 — staging 2026-10-09 · production at the next boundary')"
ck "…above the previous release"                         yes "$(awk '/^## Release 2.1/{a=NR} /^## Release 2.0/{b=NR} END{print (a<b)?"yes":"no"}' "${F}")"
ck "the promoted release gets its production date"       yes "$(has "${F}" '## Release 2.0 — staging 2026-09-01 · production 2026-10-09')"
ck "an empty Next release gives a factual summary"       yes "$(has "${F}" '4 issues done across G1.1, G2.1.')"
waves="$(sed -n '/^## Wave 2/,/^## Next release/p' "${F}")"
ck "no ✅ row is left in the waves"                       0 "$(grep -c '^| ✅' <<< "${waves}")"
ck "the open row stays"                                  yes "$(grep -q '| #11 | open in two' <<< "${waves}" && echo yes || echo no)"
ck "a group still open is recounted"                     yes "$(grep -qF '### G2.1 Mixed — Ease M · Risk L · released: 5 · open: 1' <<< "${waves}" && echo yes || echo no)"
ck "a sub-table that empties leaves the wave"            no "$(grep -q 'Sub table' <<< "${waves}" && echo yes || echo no)"
ck "a finished group leaves the waves"                   no "$(grep -q 'G1.1' <<< "${waves}" && echo yes || echo no)"
ck "…and a wave with no group left goes too"             no "$(grep -q '^## Wave 1' "${F}" && echo yes || echo no)"
rel="$(sed -n '/^## Release 2.1/,/^## Release 2.0/p' "${F}")"
ck "the release keeps the wave and group headings"       yes "$(grep -q '^### Wave 1 — one' <<< "${rel}" && grep -q '^#### G1.1 Finished — Ease L · Risk H' <<< "${rel}" && echo yes || echo no)"
ck "…the finished group's intent"                        yes "$(grep -q 'Finished intent.' <<< "${rel}" && echo yes || echo no)"
ck "…and the sub-table under its own heading"            yes "$(grep -q '^##### Sub table' <<< "${rel}" && grep -q '| ✅ #12 | sub done' <<< "${rel}" && echo yes || echo no)"
ck "Future Work's ✅ row moves too"                       yes "$(grep -q '| ✅ #51 | finished outside a wave' <<< "${rel}" && echo yes || echo no)"
ck "…and its open row stays"                             yes "$(sed -n '/^## Future Work/,/^## Wave/p' "${F}" | grep -c '| #50 | later' >/dev/null && echo yes || echo no)"
ck "At a glance is recomputed"                           yes "$(has "${F}" '| Wave | Group | Ease | Risk | released | done for 2.2 | open |')"
cp "${F}" "${T}/once"
python3 "${CUT}" --file "${F}" --version 2.1 --date 2026-10-09 --promoted 2.0 >/dev/null
ck "a second run for the same version changes nothing"   "" "$(diff -q "${T}/once" "${F}")"

echo "── the summary written ahead ──"
cp "${T}/orig" "${F}"
python3 - "${F}" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("<!-- next-release summary -->\n\n<!-- /next-release summary -->",
              "<!-- next-release summary -->\nAlerting and storage.\n<!-- /next-release summary -->")
open(p, "w").write(s)
PY
python3 "${CUT}" --file "${F}" --version 2.1 --date 2026-10-09 >/dev/null
ck "Next release becomes the summary"                    yes "$(sed -n '/^## Release 2.1/,/^## Release 2.0/p' "${F}" | grep -c 'Alerting and storage.' >/dev/null && echo yes || echo no)"
ck "…and is left empty"                                  no "$(sed -n '/^## Next release/,/^## Release 2.1/p' "${F}" | grep -c 'Alerting and storage.' >/dev/null && echo yes || echo no)"

echo "── --normalize ──"
cp "${T}/orig" "${F}"
python3 "${CUT}" --file "${F}" --normalize >/dev/null
ck "old counts are rewritten"                            yes "$(has "${F}" '### G2.1 Mixed — Ease M · Risk L · released: 3 · done for 2.1: 2 · open: 1')"
ck "…and nothing moves"                                  "${before}" "$(grep -c '^| ✅' "${T}/orig" | sed "s/.*/$(rows "${F}")/")"
ck "a broken file is refused"                            1 "$(printf '# empty\n' > "${T}/bad"; python3 "${CUT}" --file "${T}/bad" --normalize >/dev/null 2>&1; echo $?)"

echo "── the real tree ──"
if [[ -f "${ROOT}/ROADMAP.md" ]]; then
    cp "${ROOT}/ROADMAP.md" "${T}/real"
    python3 "${CUT}" --file "${T}/real" --normalize >/dev/null
    ck "ROADMAP.md is in the current form (--normalize changes nothing)" "" "$(diff -q "${ROOT}/ROADMAP.md" "${T}/real")"
fi

echo
echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
