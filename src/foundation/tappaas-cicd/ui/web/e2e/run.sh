#!/usr/bin/env bash
#
# run.sh — the console's visual loop: build, serve from fixtures, capture every
# route at every viewport, compare with the baseline, run the flows, print the
# report's path.
#
#   ui/web/e2e/run.sh [--update-baseline] [--routes id,…] [--viewports phone,…]
#                     [--allow id,…] [--port 9097] [--base <ref>] [--no-flows]
#
# out/ holds this run: shots/<viewport>/<id>.{png,txt}, diff/, report.md.
# baseline/ holds the look to compare with: the PNGs are local (git-ignored)
# and baseline/STAMP names the commit they came from; the .txt siblings are in
# git. A baseline is reused while its stamp lies between the merge base with
# <ref> (default $E2E_BASE, else adr-041) and HEAD. Otherwise it is made again
# from the last commit since the merge base that changed baseline/ (an accepted
# look), else the merge base: in a temporary `git worktree` of that commit,
# built and captured there, then removed; when the working tree's console
# equals that commit's, from the working tree. --update-baseline captures the
# working tree as the baseline (stamp HEAD) and rewrites the .txt files: commit
# them. The flows (flows/*.spec.ts: wizards clicked through, asserted on text
# and the server's journal) run after the capture on the same server, at phone
# and laptop (out/flows.log; --no-flows skips them, --update-baseline too).
# Exit 1 when a capture or a flow fails, or a route differs that --allow does
# not name.
set -euo pipefail

E2E="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="$(dirname "${E2E}")"
UI="$(dirname "${WEB}")"
OUT="${E2E}/out"
BASELINE="${E2E}/baseline"
PORT=9097
ROUTES=""
VIEWPORTS="phone,tablet,laptop,desktop"
ALLOW=""
UPDATE=0
BASE_REF="${E2E_BASE:-adr-041}"
FLOWS=1
usage() { sed -n '6,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update-baseline) UPDATE=1; shift ;;
        --routes) ROUTES="$2"; shift 2 ;;
        --viewports) VIEWPORTS="$2"; shift 2 ;;
        --allow) ALLOW="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --base) BASE_REF="$2"; shift 2 ;;
        --flows) FLOWS=1; shift ;;
        --no-flows) FLOWS=0; shift ;;
        *) usage ;;
    esac
done

[[ -x /opt/homebrew/bin/node ]] && PATH="/opt/homebrew/bin:${PATH}"
[[ -d "${WEB}/node_modules/@playwright/test" ]] || (cd "${WEB}" && npm ci)
# ui/src builds with the web app's tsc (fixture-server.sh calls `tsc`).
PATH="${WEB}/node_modules/.bin:${PATH}"
export PATH
T0=$(date +%s)
REPO="$(git -C "${UI}" rev-parse --show-toplevel)"
UI_REL="${UI#"${REPO}"/}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/console-e2e.XXXXXX")"
SERVER=""
WT=""
cleanup() {
    [[ -n "${SERVER}" ]] && kill "${SERVER}" 2>/dev/null && wait "${SERVER}" 2>/dev/null || true
    [[ -n "${WT}" ]] && git -C "${REPO}" worktree remove --force "${WT}" >/dev/null 2>&1 || true
    rm -rf -- "${TMP}"
}
trap cleanup EXIT

ALL_VPS=(phone tablet laptop desktop)
IFS=, read -ra VPS <<<"${VIEWPORTS}"
for v in "${VPS[@]}"; do
    case "${v}" in phone | tablet | laptop | desktop) ;; *) echo "run.sh: no viewport ${v}" >&2; exit 2 ;; esac
done

# build <ui dir> <web dist>: ui/src (fixture-server.sh does it when stale) and
# the web app into a scratch output; the committed web/dist is not touched.
build() {
    local ui="$1" dist="$2"
    (cd "${ui}/web" && tsc --noEmit -p tsconfig.json && vite build --logLevel error --outDir "${dist}" --emptyOutDir)
}

# serve <ui dir> <web dist>: fixture-server.sh in the background until it answers.
serve() {
    local ui="$1" dist="$2" i
    CONSOLE_WEB_DIR="${dist}" "${ui}/fixture-server.sh" --port "${PORT}" >"${TMP}/server.log" 2>&1 &
    SERVER=$!
    for i in $(seq 120); do
        curl -sf -o /dev/null "http://127.0.0.1:${PORT}/api/v1/status" && return 0
        kill -0 "${SERVER}" 2>/dev/null || break
        sleep 0.5
    done
    cat "${TMP}/server.log" >&2
    echo "run.sh: the fixture server on port ${PORT} did not start" >&2
    exit 1
}

stop() { kill "${SERVER}" 2>/dev/null; wait "${SERVER}" 2>/dev/null || true; SERVER=""; }

# capture <ui dir> <out dir> <routes> <viewport>…: by this tree's capture.ts.
capture() {
    local ui="$1" out="$2" routes="$3" now v
    shift 3
    now="$(head -1 "${ui}/test/fixtures/CAPTURED")"
    rm -rf -- "${out:?}"
    (cd "${WEB}" && E2E_BASE_URL="http://127.0.0.1:${PORT}" E2E_NOW="${now}" E2E_OUT="${out}" E2E_ROUTES="${routes}" \
        E2E_RESULTS="${TMP}/results" playwright test -c e2e/playwright.config.ts "${@/#/--project=}")
}

# store_baseline <shots> <stamp> <all>: all=1 replaces each viewport's files;
# else (a route subset) the other routes stay.
store_baseline() {
    local from="$1" stamp="$2" all="$3" v f
    for v in "${ALL_VPS[@]}"; do
        [[ -d "${from}/${v}" ]] || continue
        mkdir -p "${BASELINE}/${v}"
        [[ "${all}" == 1 ]] && rm -f -- "${BASELINE}/${v}"/*.png "${BASELINE}/${v}"/*.txt
        for f in "${from}/${v}"/*; do cp -- "${f}" "${BASELINE}/${v}/"; done
    done
    echo "${stamp}" >"${BASELINE}/STAMP"
}

# The console's own files: what makes a capture differ.
CONSOLE_PATHS=("${UI_REL}/src" "${UI_REL}/fixture-server.sh" "${UI_REL}/test/fixtures" "${UI_REL}/web/src" "${UI_REL}/web/index.html" "${UI_REL}/web/public" "${UI_REL}/web/vite.config.ts" "${UI_REL}/web/package-lock.json")

HEAD="$(git -C "${REPO}" rev-parse HEAD)"
if [[ "${UPDATE}" == 0 ]]; then
    MB="$(git -C "${REPO}" merge-base HEAD "${BASE_REF}")"
    STAMP="$(cat "${BASELINE}/STAMP" 2>/dev/null || true)"
    if [[ -z "${STAMP}" ]] || ! git -C "${REPO}" merge-base --is-ancestor "${MB}" "${STAMP}" 2>/dev/null || ! git -C "${REPO}" merge-base --is-ancestor "${STAMP}" HEAD 2>/dev/null; then
        REF="$(git -C "${REPO}" log -1 --format=%H "${MB}..HEAD" -- "${UI_REL}/web/e2e/baseline")"
        REF="${REF:-${MB}}"
        if ! git -C "${REPO}" cat-file -e "${REF}:${UI_REL}/fixture-server.sh" 2>/dev/null; then
            # Before fixture mode: the first commit since that has it.
            REF="$(git -C "${REPO}" rev-list --reverse --ancestry-path "${REF}..HEAD" | while read -r c; do git -C "${REPO}" cat-file -e "${c}:${UI_REL}/fixture-server.sh" 2>/dev/null && { echo "${c}"; break; }; done || true)"
            [[ -n "${REF}" ]] || { echo "run.sh: no commit since the merge base with ${BASE_REF} has fixture mode" >&2; exit 1; }
        fi
        echo "== baseline: none or stale (${STAMP:-no stamp}); making it from ${REF:0:12}"
        if git -C "${REPO}" diff --quiet "${REF}" -- "${CONSOLE_PATHS[@]}" && [[ -z "$(git -C "${REPO}" ls-files --others --exclude-standard -- "${CONSOLE_PATHS[@]}")" ]]; then
            SRC="${UI}"
        else
            WT="${TMP}/base"
            git -C "${REPO}" worktree add --detach --quiet "${WT}" "${REF}"
            SRC="${WT}/${UI_REL}"
            if cmp -s "${SRC}/web/package-lock.json" "${WEB}/package-lock.json"; then
                rm -rf "${SRC}/web/node_modules" && ln -s "${WEB}/node_modules" "${SRC}/web/node_modules"
            else
                (cd "${SRC}/web" && npm ci --no-audit --no-fund --loglevel error)
            fi
        fi
        build "${SRC}" "${TMP}/base-dist"
        serve "${SRC}" "${TMP}/base-dist"
        # Every route at every viewport, whatever this run asks for.
        capture "${SRC}" "${TMP}/base-shots" "" "${ALL_VPS[@]}" || { stop; echo "run.sh: the baseline capture at ${REF:0:12} failed" >&2; exit 1; }
        stop
        store_baseline "${TMP}/base-shots" "${REF}" 1
        if [[ -n "${WT}" ]]; then git -C "${REPO}" worktree remove --force "${WT}"; WT=""; fi
    fi
fi

echo "== build"
(cd "${WEB}" && tsc --noEmit -p e2e/tsconfig.json)
build "${UI}" "${OUT}/web-dist"
serve "${UI}" "${OUT}/web-dist"
echo "== capture ${VIEWPORTS}${ROUTES:+ (${ROUTES})}"
CAPTURED=0
capture "${UI}" "${OUT}/shots" "${ROUTES}" "${VPS[@]}" || CAPTURED=$?
# The flows: after the capture, whose pages their jobs would change.
FLOWED=0
FLOWS_LINE=""
if [[ "${FLOWS}" == 1 && "${UPDATE}" == 0 ]]; then
    echo "== flows"
    (cd "${WEB}" && E2E_BASE_URL="http://127.0.0.1:${PORT}" E2E_NOW="$(head -1 "${UI}/test/fixtures/CAPTURED")" \
        E2E_RESULTS="${TMP}/flow-results" playwright test -c e2e/flows/playwright.config.ts) 2>&1 | tee "${OUT}/flows.log" || FLOWED=$?
    FLOWS_LINE="$(grep -E '^ +[0-9]+ (passed|failed|flaky)' "${OUT}/flows.log" | sed 's/^ *//' | paste -sd, - | sed 's/,/, /g')"
fi
stop

if [[ "${UPDATE}" == 1 ]]; then
    [[ "${CAPTURED}" == 0 ]] || { echo "run.sh: a capture failed; the baseline is unchanged" >&2; exit 1; }
    store_baseline "${OUT}/shots" "${HEAD}" "$([[ -z "${ROUTES}" ]] && echo 1 || echo 0)"
    echo "baseline: ${BASELINE} (stamp ${HEAD:0:12}); commit the .txt files ($(( $(date +%s) - T0 )) s)"
    exit 0
fi

echo "== compare"
rm -rf -- "${OUT}/diff"
COMPARED=0
node "${E2E}/compare.ts" --shots "${OUT}/shots" --baseline "${BASELINE}" --out "${OUT}" --allow "${ALLOW}" || COMPARED=$?
# A route that differs is captured once more, alone and serially: a graph that
# drew late under the parallel load comes back the same, a real change stays.
if [[ "${COMPARED}" != 0 && "${CAPTURED}" == 0 ]]; then
    AGAIN="$(sed -n '/^## Changed routes/,/^## Route/p' "${OUT}/report.md" | sed -nE 's/^- \*\*([^*]+)\*\*.*/\1/p' | paste -sd, -)"
    if [[ -n "${AGAIN}" ]]; then
        echo "== recapture ${AGAIN} (serially)"
        serve "${UI}" "${OUT}/web-dist"
        if E2E_WORKERS=1 capture "${UI}" "${OUT}/recapture" "${AGAIN}" "${VPS[@]}"; then
            stop
            cp -R "${OUT}/recapture/." "${OUT}/shots/"
            rm -rf -- "${OUT}/diff"
            COMPARED=0
            node "${E2E}/compare.ts" --shots "${OUT}/shots" --baseline "${BASELINE}" --out "${OUT}" --allow "${ALLOW}" || COMPARED=$?
            printf '\nRecaptured alone after a first difference: %s.\n' "${AGAIN}" >>"${OUT}/report.md"
        else
            stop
        fi
    fi
fi
if [[ "${FLOWS}" == 1 ]]; then
    printf '\n## Flows\n\n%s: %s (flows.log)\n' "$([[ "${FLOWED}" == 0 ]] && echo ok || echo FAILED)" "${FLOWS_LINE:-no result}" >>"${OUT}/report.md"
    [[ "${FLOWED}" == 0 ]] || grep -E '^ +✘' "${OUT}/flows.log" | sed 's/^ */- /' >>"${OUT}/report.md" || true
fi
echo "report: ${OUT}/report.md ($(( $(date +%s) - T0 )) s)"
[[ "${CAPTURED}" == 0 ]] || echo "run.sh: a capture failed (above)" >&2
[[ "${FLOWED}" == 0 ]] || echo "run.sh: a flow failed (${OUT}/flows.log)" >&2
[[ "${CAPTURED}" == 0 && "${COMPARED}" == 0 && "${FLOWED}" == 0 ]]
