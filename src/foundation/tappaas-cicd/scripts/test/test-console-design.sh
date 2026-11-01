#!/usr/bin/env bash
#
# test-console-design.sh — the console's web app keeps to its design system,
# .interface-design/system.md: every colour, spacing, radius and breakpoint is a
# token on :root in styles.css (docs/plans/console-gui-pipeline.md, O3).
#
# Fails on a hex colour, an rgb( or a px padding/gap/margin/radius/media-query
# width in ui/web/src that is neither a token nor covered by
# .interface-design/allow.txt, and when system.md and :root disagree on a token.
#
# allow.txt line: <file under src> <kind> <value> <max> # <reason>
# kind is colour, spacing, radius, media or style; <max> caps that value's raw
# uses in that file, so a pre-scale value can shrink but never spread.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# A file without its comments and without the :root block, which is where a raw
# value belongs.
strip_file() {
    awk '
        BEGIN { comment = 0; root = 0 }
        {
            line = $0
            if (root) { if (line ~ /^}/) root = 0; next }
            if (line ~ /^:root[[:space:]]*{/) { root = 1; next }
            out = ""
            while (length(line) > 0) {
                if (comment) {
                    i = index(line, "*/")
                    if (i == 0) { line = ""; break }
                    line = substr(line, i + 2); comment = 0
                } else {
                    i = index(line, "/*")
                    if (i == 0) { out = out line; line = ""; break }
                    out = out substr(line, 1, i - 1)
                    line = substr(line, i + 2); comment = 1
                }
            }
            if (FILENAME !~ /\.css$/) sub(/(^|[[:space:]])\/\/.*$/, "", out)
            print out
        }' "$1"
}

# Prints "<kind> <value>" per raw use in one file, comments and :root gone.
raw_uses() {
    local f="$1" text
    text="$(strip_file "${f}")"
    grep -oE '#[0-9a-fA-F]{3,8}\b' <<<"${text}" | awk 'length($0) == 4 || length($0) == 5 || length($0) == 7 || length($0) == 9 { print "colour", tolower($0) }'
    grep -oE '\brgba?\([^)]*\)' <<<"${text}" | tr -d ' ' | sed 's/^/colour /'
    if [[ "${f}" == *.css ]]; then
        grep -oE '(^|[^-a-z])(padding|margin)(-[a-z]+)?:[^;}]*|(^|[^-a-z])(row-|column-)?gap:[^;}]*' <<<"${text}" \
            | grep -oE '[0-9.]+px' | sed 's/^/spacing /'
        grep -oE '(^|[^-a-z])border-radius:[^;}]*' <<<"${text}" | grep -oE '[0-9.]+px' | sed 's/^/radius /'
        grep -oE '@media[^{]*' <<<"${text}" | grep -oE '[0-9.]+px' | sed 's/^/media /'
    else
        grep -oE '(padding|margin|gap|[rR]adius)[A-Za-z]*: *["`'"'"'][^"`'"'"']*[0-9]px' <<<"${text}" | grep -oE '[0-9.]+px' | sed 's/^/spacing /'
        grep -E 'matchMedia|@media|max-width: *[0-9]' <<<"${text}" | grep -oE '[0-9.]+px' | sed 's/^/media /'
        grep -oE 'style=\{\{[^}]*\}\}' <<<"${text}" | grep -oE '(padding|margin|gap|borderRadius)[A-Za-z]*: *[0-9]+' | sed -E 's/:.*//; s/^/style /'
    fi
}

# Checks a tree (<src>, <allow>); prints one line per violation.
audit_tree() {
    local src="$1" allow="$2" f rel kind value n max line
    while IFS= read -r -d '' f; do
        rel="${f#"${src}/"}"
        while read -r n kind value; do
            max=0
            if [[ -f "${allow}" ]]; then
                line="$(awk -v r="${rel}" -v k="${kind}" -v v="${value}" '$1 == r && $2 == k && $3 == v { print $4; exit }' "${allow}")"
                max="${line:-0}"
            fi
            (( n > max )) && echo "${rel}: raw ${kind} ${value} used ${n}, allowed ${max}"
        done < <(raw_uses "${f}" | sort | uniq -c)
    done < <(find "${src}" -type f \( -name '*.css' -o -name '*.ts' -o -name '*.tsx' \) -print0)
}

root_tokens() { awk '/^:root/{r=1;next} r&&/^}/{exit} r' "$1" | grep -oE '^[[:space:]]*--[A-Za-z0-9-]+:' | tr -d ' :' | sort -u; }

echo "── the rules, on fixtures ──"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/src"
cat > "${T}/src/a.css" <<'FIX'
:root {
  --bg: #123456;
}
/* #abcdef in a comment is no use */
.a { color: var(--bg); padding: var(--sp-8); }
.b { color: #abcdef; }
.c { padding: 6px 12px; }
.d { border-radius: 3px; }
@media (max-width: 777px) { .e { top: 3px; } }
.f { box-shadow: 0 0 0 rgba(0, 0, 0, .1); }
.g { width: 400px; }
FIX
cat > "${T}/src/b.tsx" <<'FIX'
// the bug (#692) in a comment, and #abcdef
const a = "url(#hatch-mirror)";
const c = "#d64545";
const d = <i style={{ paddingLeft: 4 + n * 14 }} />;
const e = window.matchMedia("(max-width: 700px)");
FIX
found="$(audit_tree "${T}/src" /dev/null)"
want() { grep -qF "$1" <<<"${found}" && ok "flagged: $1" || bad "not flagged: $1"; }
never() { grep -qF "$1" <<<"${found}" && bad "wrongly flagged: $1" || ok "left alone: $1"; }
want "a.css: raw colour #abcdef used 1"
want "a.css: raw spacing 6px"
want "a.css: raw spacing 12px"
want "a.css: raw radius 3px"
want "a.css: raw media 777px"
want "rgba(0,0,0,.1)"
want "b.tsx: raw colour #d64545"
want "b.tsx: raw style paddingLeft"
want "b.tsx: raw media 700px"
never "#123456"
never "#692"
never "400px"
printf 'a.css spacing 6px 1 # a reason\n' > "${T}/allow.txt"
found="$(audit_tree "${T}/src" "${T}/allow.txt")"
never "raw spacing 6px"
printf 'a.css spacing 6px 0 # a reason\n' > "${T}/allow.txt"
found="$(audit_tree "${T}/src" "${T}/allow.txt")"
want "raw spacing 6px used 1, allowed 0"

echo "── the console ──"
WEB="${REPO}/src/foundation/tappaas-cicd/ui/web/src"
SYSTEM="${REPO}/.interface-design/system.md"
ALLOW="${REPO}/.interface-design/allow.txt"
[[ -f "${SYSTEM}" ]] && ok "system.md exists" || bad "system.md is missing"
[[ -f "${ALLOW}" ]] && ok "allow.txt exists" || bad "allow.txt is missing"
head -1 "${SYSTEM}" | grep -q 'src/foundation/tappaas-cicd/ui/web' && ok "system.md says it covers the console only" || bad "system.md's first line does not name ui/web"

found="$(audit_tree "${WEB}" "${ALLOW}")"
if [[ -z "${found}" ]]; then
    ok "no raw colour, spacing, radius or breakpoint beyond the allow-list"
else
    while IFS= read -r line; do bad "${line}"; done <<<"${found}"
fi

noreason="$(grep -vE '^[[:space:]]*(#|$)' "${ALLOW}" | grep -vE '^[^ ]+ (colour|spacing|radius|media|style) [^ ]+ [0-9]+ +# .+' || true)"
[[ -z "${noreason}" ]] && ok "every allow-list line has its reason" || bad "allow.txt lines without a reason: ${noreason}"

gone=""
while read -r rel _; do
    [[ -z "${rel}" || "${rel}" == \#* ]] && continue
    [[ -f "${WEB}/${rel}" ]] || gone+=" ${rel}"
done < "${ALLOW}"
[[ -z "${gone}" ]] && ok "every allow-list file exists" || bad "allow.txt names files that are gone:${gone}"

tokens="$(root_tokens "${WEB}/styles.css")"
named="$(grep -oE -- '--[a-zA-Z][A-Za-z0-9-]*' "${SYSTEM}" | sort -u)"
missing="$(comm -23 <(echo "${tokens}") <(echo "${named}") | tr '\n' ' ')"
[[ -z "${missing// /}" ]] && ok "system.md names every :root token ($(wc -l <<<"${tokens}" | tr -d ' '))" || bad "not in system.md: ${missing}"
stale="$(comm -13 <(echo "${tokens}") <(echo "${named}") | tr '\n' ' ')"
[[ -z "${stale// /}" ]] && ok "every token in system.md exists in styles.css" || bad "not in styles.css: ${stale}"

unused=""
ts_refs="$(grep -rhE 'var\(--' "${WEB}" --include='*.ts' --include='*.tsx' | grep -oE -- '--[A-Za-z0-9-]+' | sort -u)"
for t in ${ts_refs}; do
    case "${t}" in --zone-|--zone-p) continue ;; esac
    grep -qxF -- "${t}" <<<"${tokens}" || unused+=" ${t}"
done
[[ -z "${unused}" ]] && ok "every token the code names exists" || bad "named in code, not on :root:${unused}"

for bp in sm md lg xl; do
    css="$(grep -E -- "--bp-${bp}:" "${WEB}/styles.css" | grep -oE '[0-9]+px' | tr -d 'px')"
    ts="$(grep -oE "\b${bp}: [0-9]+" "${WEB}/breakpoints.ts" | grep -oE '[0-9]+')"
    [[ -n "${css}" && "${css}" == "${ts}" ]] && ok "--bp-${bp} agrees with breakpoints.ts (${css})" || bad "--bp-${bp} is ${css:-none} in CSS, ${ts:-none} in breakpoints.ts"
done

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
