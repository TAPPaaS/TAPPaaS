#!/usr/bin/env bash
# test-module-sizing.sh — site and environment size pick a guest's cores, memory
# and disk (ADR-044, #917).
#
#   1. every module JSON in the repository: each SmallLarge pair is ordered around
#      its medium value, and a disk floor is never below the template it clones;
#   2. apply_module_size: small takes the small value, large the large one, medium the plain
#      value — flat and Pattern A, and a field without a pair is untouched;
#   3. module_size_for: TAPPAAS_SIZE, the environment's size, the site's, medium;
#      a foundation module takes the site's even inside an environment;
#   4. copy-update-json.sh sizes the installed config AND its .orig, and an
#      explicit --memory wins;
#   5. the 3-way merge sizes the release: nothing is pinned by sizing, and a
#      size change reaches an unpinned field while a pinned one stays;
#   6. foundation + home + office at small fit one 32 GB node (26.5 GiB of guests).
# Uses THIS tree's lib and scripts, never /home/tappaas/bin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
FOUNDATION="$(cd "${CICD}/.." && pwd)"
SRC="$(cd "${FOUNDATION}/.." && pwd)"
LIB="${CICD}/lib/common-install-routines.sh"
SIZING="${CICD}/lib/module-sizing.sh"
CUJ="${CICD}/manager/module-manager/copy-update-json.sh"
MERGE="${CICD}/lib/apply-json-merge.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sizing.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# shellcheck source=../../lib/module-sizing.sh
. "${SIZING}"

# ── 1. the repository's module JSONs ────────────────────────────────────────
echo "── module JSONs ──"
mib() { # "16G" → MiB
    local v="${1%[GMKT]}" u="${1: -1}"
    case "$u" in T) echo $((v*1024*1024)) ;; G) echo $((v*1024)) ;; M) echo "$v" ;; K) echo $((v/1024)) ;; *) echo "$1" ;; esac
}
TEMPLATE_DISK="$(mib "$(jq -r '.config["cluster:vm"].diskSize' "${FOUNDATION}/templates/tappaas-nixos.json")")"
sized=0
while IFS= read -r f; do
    rel="${f#"${SRC}/"}"
    blk="$(jq -c '.config // {} | (.["cluster:vm"] // .["cluster:lxc"] // empty)' "$f" 2>/dev/null)"
    [[ -n "$blk" ]] || continue
    jq -e 'has("coresSmallLarge") or has("memorySmallLarge") or has("diskSmallLarge")' <<<"$blk" >/dev/null || continue
    sized=$((sized+1))
    for p in "cores coresSmallLarge 2" "memory memorySmallLarge 4096" "diskSize diskSmallLarge 8G"; do
        set -- $p
        pair="$(jq -c --arg k "$2" '.[$k] // empty' <<<"$blk")"
        [[ -n "$pair" ]] || continue
        ck "${rel}: $2 is a pair" 2 "$(jq 'length' <<<"$pair")"
        med="$(jq -r --arg k "$1" --arg d "$3" '.[$k] // $d' <<<"$blk")"
        lo="$(jq -r '.[0]' <<<"$pair")"; hi="$(jq -r '.[1]' <<<"$pair")"
        if [[ "$1" == "diskSize" ]]; then lo="$(mib "$lo")"; hi="$(mib "$hi")"; med="$(mib "$med")"; fi
        ck "${rel}: $2 small ≤ $1 ≤ large" yes "$( (( lo <= med && med <= hi )) && echo yes || echo "no: ${lo} ${med} ${hi}")"
        if [[ "$1" == "diskSize" ]] && [[ "$(jq -r '.imageType // "clone"' <<<"$blk")" == "clone" ]] \
           && [[ "$(jq -r '.image // ""' <<<"$blk")" == "8080" ]]; then
            ck "${rel}: disk floor ≥ the NixOS template's ${TEMPLATE_DISK} MiB" yes "$( (( lo >= TEMPLATE_DISK )) && echo yes || echo "no: ${lo}")"
        fi
    done
done < <(find "${SRC}" -path '*/node_modules' -prune -o -name '*.json' -path '*/src/*/*/*.json' -print \
         | grep -v -e '/schemas/' -e 'fields.json$' -e '/test' -e '/ui/' -e '\.meta\.json$')
ck "the repository has sized modules" yes "$( (( sized >= 20 )) && echo yes || echo "no: ${sized}")"

# ── 2. apply_module_size ────────────────────────────────────────────────────
echo "── apply_module_size ──"
FLAT='{"cores":4,"coresSmallLarge":[2,8],"memory":8192,"memorySmallLarge":[2048,16384],"diskSize":"32G","diskSmallLarge":["16G","64G"],"swap":512}'
PA='{"stack":"home","config":{"cluster:vm":{"cores":4,"coresSmallLarge":[2,8],"memory":8192,"diskSize":"32G"},"network:proxy":{"proxyPort":80}}}'
r() { apply_module_size "$1" <<<"$2" | jq -c "$3"; }
ck "small: flat takes the small value"   '[2,2048,"16G"]'  "$(r small "$FLAT" '[.cores,.memory,.diskSize]')"
ck "large: flat takes the large value"   '[8,16384,"64G"]' "$(r large "$FLAT" '[.cores,.memory,.diskSize]')"
ck "medium: flat unchanged"      "$(jq -c . <<<"$FLAT")" "$(r medium "$FLAT" '.')"
ck "a field without a pair stays" 512 "$(r small "$FLAT" '.swap')"
ck "small: Pattern A cores"      2    "$(r small "$PA" '.config["cluster:vm"].cores')"
ck "small: Pattern A memory without a pair stays" 8192 "$(r small "$PA" '.config["cluster:vm"].memory')"
ck "other service blocks untouched" 80 "$(r large "$PA" '.config["network:proxy"].proxyPort')"
ck "the pairs stay in the config" '[2,8]' "$(r small "$PA" '.config["cluster:vm"].coresSmallLarge')"
ck "an unknown size is medium"   4 "$(r huge "$FLAT" '.cores')"
ck "a pair without a plain value sets it (small)" 1024 "$(apply_module_size small <<<'{"memorySmallLarge":[1024,8192]}' | jq .memory)"

# ── 3. module_size_for ──────────────────────────────────────────────────────
echo "── module_size_for ──"
C="${TMP}/cfg"; mkdir -p "${C}/environments"
APP="${TMP}/app.json";  echo '{"stack":"home"}' > "${APP}"
FND="${TMP}/fnd.json";  echo '{"stack":"foundation"}' > "${FND}"
ck "nothing set: medium"                 medium "$(module_size_for "${APP}" "" "${C}")"
echo '{"name":"s1","defaultEnvironment":"home","size":"small"}' > "${C}/site.json"
ck "site small: an app module is small"  small  "$(module_size_for "${APP}" "" "${C}")"
ck "site small: foundation is small"     small  "$(module_size_for "${FND}" "" "${C}")"
echo '{"name":"home","displayName":"Home","ownerOrg":"o","size":"large"}' > "${C}/environments/home.json"
ck "default environment large wins over the site" large "$(module_size_for "${APP}" "" "${C}")"
ck "foundation stays at the site's size"  small  "$(module_size_for "${FND}" "home" "${C}")"
echo '{"name":"lab","displayName":"Lab","ownerOrg":"o"}' > "${C}/environments/lab.json"
ck "an environment without a size takes the site's" small "$(module_size_for "${APP}" "lab" "${C}")"
echo '{"stack":"home","environment":"lab"}' > "${TMP}/inst.json"
ck "the environment is read from the config" small "$(module_size_for "${TMP}/inst.json" "" "${C}")"
ck "TAPPAAS_SIZE wins"                   large  "$(TAPPAAS_SIZE=large module_size_for "${APP}" "lab" "${C}")"
ck "a bad TAPPAAS_SIZE is ignored"       small  "$(TAPPAAS_SIZE=huge module_size_for "${APP}" "lab" "${C}" 2>/dev/null)"
echo '{"name":"s1","defaultEnvironment":"home","size":"bogus"}' > "${C}/site.json"; rm -f "${C}/environments/home.json"
ck "a bad site size is medium"           medium "$(module_size_for "${APP}" "" "${C}")"

# ── 4. copy-update-json.sh ──────────────────────────────────────────────────
echo "── install (copy-update-json.sh) ──"
MOD="${TMP}/src/home/demo"; CFG="${TMP}/config"
mkdir -p "${MOD}" "${CFG}/environments"
MOD="$(cd "${MOD}" && pwd -P)"; CFG="$(cd "${CFG}" && pwd -P)"
cat > "${MOD}/demo.json" <<'JSON'
{"description":"demo","version":"0.1.0","kind":"vm","stack":"home","vmid":990,"dependsOn":["cluster:vm"],
 "config":{"cluster:vm":{"cores":4,"coresSmallLarge":[2,8],"memory":8192,"memorySmallLarge":[2048,16384],
   "diskSize":"32G","diskSmallLarge":["16G","64G"],"imageType":"clone","image":"8080"}}}
JSON
S="${TMP}/schema.json"
"${CICD}/scripts/compose-fields.sh" "${FOUNDATION}" > "${S}" 2>/dev/null || echo '{"fields":{}}' > "${S}"
cuj() {
    ( cd "${MOD}" && CONFIG_DIR="${CFG}" SCHEMA_FILE="${S}" TAPPAAS_SCHEMA_FILE="${S}" bash -c '
        . "$1" >/dev/null 2>&1; shift; cuj="$1"; shift
        set -- "$@"; . "${cuj}" >/dev/null 2>&1; echo "${EFFECTIVE_MODULE:-}"' _ "${LIB}" "${CUJ}" "$@" )
}
get() { jq -r "[.. | objects | .$2? // empty] | first" "$1"; }
echo '{"name":"s1","defaultEnvironment":"home","size":"small"}' > "${CFG}/site.json"
cuj demo >/dev/null
ck "small site: installed memory is the min" 2048 "$(get "${CFG}/demo.json" memory)"
ck "small site: installed cores are the min" 2    "$(get "${CFG}/demo.json" cores)"
ck "small site: installed disk is the min"   16G  "$(get "${CFG}/demo.json" diskSize)"
ck "the .orig baseline is sized too"         2048 "$(get "${CFG}/demo.json.orig" memory)"
ck "the pair is kept in the installed config" '[2048,16384]' "$(jq -c '[.. | objects | .memorySmallLarge? // empty] | first' "${CFG}/demo.json")"
rm -f "${CFG}"/demo.json*
cuj demo --memory 6144 >/dev/null
ck "an explicit --memory wins over the size"  6144 "$(get "${CFG}/demo.json" memory)"
ck "…and the other fields are still sized"    2    "$(get "${CFG}/demo.json" cores)"
rm -f "${CFG}"/demo.json*
echo '{"name":"s1","defaultEnvironment":"home"}' > "${CFG}/site.json"
cuj demo >/dev/null
ck "no size: medium values"                   8192 "$(get "${CFG}/demo.json" memory)"

# ── 5. the 3-way merge ──────────────────────────────────────────────────────
echo "── update (apply-json-merge.sh) ──"
merge() {
    TAPPAAS_MERGE_CONFIG_DIR="${CFG}" TAPPAAS_SCHEMA_FILE="${S}" CONFIG_DIR="${CFG}" bash -c '
        . "$1" >/dev/null 2>&1; . "$2"; apply_three_way_merge "$3" "$4"' _ "${LIB}" "${MERGE}" demo "${MOD}" >/dev/null 2>&1
}
rm -f "${CFG}"/demo.json*
echo '{"name":"s1","defaultEnvironment":"home","size":"small"}' > "${CFG}/site.json"
cuj demo >/dev/null
merge; ck "same release, same size: the merge succeeds" 0 "$?"
ck "…the sized memory is kept, not reset to medium" 2048 "$(get "${CFG}/demo.json" memory)"
# Operator pins cores; the site grows to medium.
tmp="$(mktemp)"; jq '(.. | objects | select(has("cores")) | .cores) = 6' "${CFG}/demo.json" > "$tmp" && mv "$tmp" "${CFG}/demo.json"
echo '{"name":"s1","defaultEnvironment":"home","size":"medium"}' > "${CFG}/site.json"
merge
ck "size small→medium: unpinned memory follows" 8192 "$(get "${CFG}/demo.json" memory)"
ck "…the operator's cores stay pinned"           6    "$(get "${CFG}/demo.json" cores)"
ck "….orig advanced to the medium release"      8192 "$(get "${CFG}/demo.json.orig" memory)"
echo '{"name":"s1","defaultEnvironment":"home","size":"large"}' > "${CFG}/site.json"
merge
ck "size medium→large: memory takes the max"    16384 "$(get "${CFG}/demo.json" memory)"

# A config installed while the pairs were called *MinMax (before the rename):
# the release no longer defines them, so the merge drops them and adopts the new.
echo '{"name":"s1","defaultEnvironment":"home"}' > "${CFG}/site.json"
rm -f "${CFG}"/demo.json*
cuj demo >/dev/null
for f in "${CFG}/demo.json" "${CFG}/demo.json.orig"; do
    tmp="$(mktemp)"; jq '(.. | objects | select(has("coresSmallLarge"))) |= (with_entries(.key |= sub("SmallLarge$"; "MinMax")))' "$f" > "$tmp" && mv "$tmp" "$f"
done
merge
ck "an old *MinMax field is dropped by the next update" 0 "$(jq '[.. | objects | keys[] | select(endswith("MinMax"))] | length' "${CFG}/demo.json")"
ck "…and the *SmallLarge one is there instead" '[2,8]' "$(jq -c '[.. | objects | .coresSmallLarge? // empty] | first' "${CFG}/demo.json")"
ck "…with the sized values unchanged" 8192 "$(get "${CFG}/demo.json" memory)"

# ── 6. the 32 GB budget ─────────────────────────────────────────────────────
echo "── 32 GB single node at small ──"
total=0; lines=""
for m in foundation/network foundation/tappaas-cicd foundation/identity foundation/logging \
         home/deconz home/hass home/immich home/jellyfin home/karakeep home/nomad \
         collaboration/nextcloud collaboration/euro-office collaboration/coturn collaboration/nextcloud-hpb; do
    f="${SRC}/${m}/$(basename "$m").json"
    mem="$(apply_module_size small < "$f" | jq '.config["cluster:vm"].memory // .config["cluster:lxc"].memory // 4096')"
    total=$((total + mem)); lines="${lines} $(basename "$m")=${mem}"
done
echo "   ${lines# }"
echo "   total ${total} MiB"
# A 32 GB node reports about 31.3 GiB. Proxmox itself takes about 1.5 GiB and the
# ZFS ARC 10 % (3.1 GiB), leaving about 26.7 GiB for guests: 26.5 keeps a margin.
ck "foundation + home + office at small ≤ 26.5 GiB of guest memory" yes "$( (( total <= 27136 )) && echo yes || echo "no: ${total} MiB")"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
