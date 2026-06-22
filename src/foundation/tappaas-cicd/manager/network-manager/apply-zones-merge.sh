#!/usr/bin/env bash
#
# apply-zones-merge.sh — 3-way drift detection / reconciliation for
# ${CONFIG_DIR}/zones.json against the upstream source template (#209).
#
# The same machinery as apply-json-merge.sh (#207), tailored to zones.json:
#   - The file is a single global object keyed by zone name.
#   - Per-leaf merge inside each shared zone:
#       AUTO_FIELDS (operator-pinned, never adopted):  ["state"]
#       Otherwise: current==orig → adopt source; else → pin current.
#   - Zone-level rules:
#       Zone in source but absent in current → ADD (release brings new zones)
#       Zone in current but absent in source → KEEP and warn (operator-added
#                                                or release-removed but
#                                                operator still wants it)
#       Same vlantag in both, different name → flag as possible rename;
#                                              do not auto-rename
#
# Backfill: if zones.json.orig does not exist, cp source → orig (matches the
# #207 decision — operator customizations stay pinned on the first merge).
#
# Usage:
#   apply-zones-merge.sh           # run merge, write current + advance .orig
#   apply-zones-merge.sh --diff    # show what would change, do not write
#
# Exit codes:
#   0  success (zero or more changes applied)
#   1  source missing / IO failure
#   2  bad arguments
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# Resolve repo source. site.json .repositories (fallback configuration.json
# .tappaas.repositories, via get_repo_path) tells us where the canonical TAPPaaS
# checkout is; fall back to the conventional path.
default_source() {
    local repos_dir
    repos_dir="$(get_repo_path TAPPaaS 2>/dev/null || true)"
    [[ -z "${repos_dir}" ]] && repos_dir="/home/tappaas/TAPPaaS"
    echo "${repos_dir}/src/foundation/tappaas-cicd/manager/network-manager/zones.json"
}

ZONES_CURRENT="${CONFIG_DIR}/zones.json"
ZONES_ORIG="${CONFIG_DIR}/zones.json.orig"
ZONES_SOURCE="${TAPPAAS_ZONES_SOURCE:-$(default_source)}"

# Operator-pinned fields per zone — never adopt from the release source (#209).
AUTO_FIELDS='["state"]'

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--diff]

Reconcile ${ZONES_CURRENT} against the upstream source at:
    ${ZONES_SOURCE}

Per-leaf rule:
    1. AUTO_FIELDS ("state"): always keep current.
    2. Path absent in source, present in current: keep current.
    3. Path absent in current: adopt source.
    4. current == orig: adopt source.
    5. else: keep current (pinned).

Zone-level rules:
    - New zone in source: added (with release defaults).
    - Zone missing in source: kept; warning emitted.
    - Same vlantag, different name: flagged as possible rename;
      no automatic rename (operator decides).

Options:
    --diff   Show what would change; do not write.
    -h, --help

Exit codes:
    0  success
    1  source missing / IO failure
    2  bad arguments
EOF
}

# ── Arguments ────────────────────────────────────────────────────────

OPT_DIFF=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --diff)    OPT_DIFF=1; shift ;;
        *)         error "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# ── Validate inputs ──────────────────────────────────────────────────

if [[ ! -f "${ZONES_CURRENT}" ]]; then
    die "Installed zones.json not found: ${ZONES_CURRENT}"
fi
if [[ ! -f "${ZONES_SOURCE}" ]]; then
    die "Upstream zones.json source not found: ${ZONES_SOURCE}"
fi
for f in "${ZONES_CURRENT}" "${ZONES_SOURCE}"; do
    if ! jq empty "${f}" 2>/dev/null; then
        die "Invalid JSON: ${f}"
    fi
done

# ── Backfill .orig (first run after #209 lands) ──────────────────────

backfilled=0
if [[ ! -f "${ZONES_ORIG}" ]]; then
    info "  No zones.json.orig present — backfilling from upstream source"
    if [[ "${OPT_DIFF}" -eq 0 ]]; then
        cp "${ZONES_SOURCE}" "${ZONES_ORIG}"
    fi
    backfilled=1
fi

# Compute the merge in a single jq pass. Inputs come in via --argjson so we
# stay in one process. Output is { merged, report }.
ORIG_FOR_MERGE="${ZONES_ORIG}"
if [[ "${backfilled}" -eq 1 ]]; then
    # When backfilling under --diff, we won't have written the file. Use source
    # for the in-memory baseline so the report matches the post-write state.
    ORIG_FOR_MERGE="${ZONES_SOURCE}"
fi

merged_report=$(jq -n \
    --slurpfile cur "${ZONES_CURRENT}" \
    --slurpfile orig "${ORIG_FOR_MERGE}" \
    --slurpfile src "${ZONES_SOURCE}" \
    --argjson auto "${AUTO_FIELDS}" '
    ($cur[0]) as $c | ($orig[0]) as $o | ($src[0]) as $s |

    # Per-leaf paths inside a single zone object (paths are arrays of strings
    # only — arrays compared whole, as in apply-json-merge.sh).
    def leaves:
        paths(type != "object") | select(all(.[]; type == "string"));

    # Merge a single zone (the operator zone vs orig zone vs source zone).
    # Inputs are object values; outputs the merged object.
    def merge_zone($cz; $oz; $sz):
        ( ($cz | [leaves]) + (($oz // {}) | [leaves]) + (($sz // {}) | [leaves]) | unique ) as $paths
        | reduce $paths[] as $p (
            {};
            ($p[0]) as $top
            | ($cz | [paths] | map(. == $p) | any) as $in_c
            | (($sz // {}) | [paths] | map(. == $p) | any) as $in_s
            | (($oz // {}) | [paths] | map(. == $p) | any) as $in_o
            | (try ($cz | getpath($p)) catch null) as $cv
            | (try (($sz // {}) | getpath($p)) catch null) as $sv
            | (try (($oz // {}) | getpath($p)) catch null) as $ov
            | if ($auto | index($top)) != null then
                if $in_c then setpath($p; $cv) else . end
              elif ($in_s | not) and $in_c then setpath($p; $cv)
              elif ($in_c | not) and $in_s then setpath($p; $sv)
              elif $in_o and ($cv == $ov) then setpath($p; $sv)
              elif $in_c then setpath($p; $cv)
              else . end
          );

    # Zone-name set union.
    (($c | keys) + ($s | keys) | unique) as $names |

    # Walk every zone name and decide what happens.
    reduce $names[] as $z (
        { merged: {}, added: [], kept_orphan: [], pinned: {}, adopted_in: [] };
        if ($c | has($z)) and ($s | has($z)) then
            # Both have it — per-leaf merge.
            (merge_zone($c[$z]; ($o[$z] // null); $s[$z])) as $mz
            | .merged[$z] = $mz
            # Track diff vs current for the report.
            | (
                [ ($mz | leaves) ]
                | reduce .[] as $p (
                    {pinned: [], adopted: []};
                    if ($mz | getpath($p)) != (($c[$z] // {}) | getpath($p)) then
                        # Source-driven change adopted.
                        .adopted += [$p | join(".")]
                    elif ($s[$z] // {}) | getpath($p) as $sv
                         | $sv != ($mz | getpath($p)) then
                        # Source had a different value, but merged kept current → pinned.
                        .pinned += [$p | join(".")]
                    else . end
                  )
              ) as $d
            | (if ($d.adopted | length) > 0 then .adopted_in += [{zone: $z, paths: $d.adopted}] else . end)
            | (if ($d.pinned  | length) > 0 then .pinned[$z]  = $d.pinned else . end)
        elif ($c | has($z)) then
            # Only in current — kept (operator-added or release-removed).
            .merged[$z] = $c[$z] | .kept_orphan += [$z]
        else
            # Only in source — added.
            .merged[$z] = $s[$z] | .added += [$z]
        end
    )
    | . as $m

    # Rename detection: same vlantag in source and current under different names.
    | (
        [ $c | to_entries[] | {name: .key, vlantag: (.value.vlantag // null)} | select(.vlantag != null and .vlantag > 0) ] as $cv
        | [ $s | to_entries[] | {name: .key, vlantag: (.value.vlantag // null)} | select(.vlantag != null and .vlantag > 0) ] as $sv
        | [ $cv[] as $ce | $sv[] as $se | select($ce.vlantag == $se.vlantag and $ce.name != $se.name)
            | {vlantag: $ce.vlantag, current: $ce.name, source: $se.name} ]
      ) as $renames
    | . + { renames: $renames }
')

# Pull components out of the report.
merged_zones=$(jq -c '.merged' <<<"${merged_report}")
n_added=$(jq -r '.added | length' <<<"${merged_report}")
n_orphan=$(jq -r '.kept_orphan | length' <<<"${merged_report}")
n_pinned=$(jq -r '[.pinned | to_entries[] | .value | length] | add // 0' <<<"${merged_report}")
n_adopted=$(jq -r '[.adopted_in[] | .paths | length] | add // 0' <<<"${merged_report}")
n_renames=$(jq -r '.renames | length' <<<"${merged_report}")

info "  Merge: ${n_adopted} adopted, ${n_pinned} pinned, ${n_added} added, ${n_orphan} kept (orphan), ${n_renames} possible rename(s)"

# Human-friendly per-zone report.
if [[ "${n_added}" -gt 0 ]]; then
    info "    added (new in release): $(jq -r '.added | join(", ")' <<<"${merged_report}")"
fi
if [[ "${n_orphan}" -gt 0 ]]; then
    warn "    kept (in current but not in source — operator-added or release-removed):"
    jq -r '.kept_orphan[]' <<<"${merged_report}" | sed 's/^/      - /'
fi
if [[ "${n_pinned}" -gt 0 ]]; then
    info "    pinned (operator customizations preserved):"
    jq -r '.pinned | to_entries[] | "      \(.key): \(.value | join(", "))"' <<<"${merged_report}"
fi
if [[ "${n_adopted}" -gt 0 ]]; then
    info "    adopted (release changes applied):"
    jq -r '.adopted_in[] | "      \(.zone): \(.paths | join(", "))"' <<<"${merged_report}"
fi
if [[ "${n_renames}" -gt 0 ]]; then
    warn "    possible rename(s) — same vlantag, different zone name:"
    jq -r '.renames[] | "      vlantag=\(.vlantag): source=\(.source) vs current=\(.current)"' <<<"${merged_report}"
    warn "      (no auto-rename — review and rename manually if appropriate)"
fi

# ── Diff mode: stop here ─────────────────────────────────────────────

if [[ "${OPT_DIFF}" -eq 1 ]]; then
    info "  --diff: no changes written"
    exit 0
fi

# ── Write merged zones.json + advance .orig ──────────────────────────

# Pretty-print to match the existing 4-space indent of zones.json so the diff
# stays small for operators who eyeball the file.
#
# Crash-safe write (incident 2026-06-09: an unclean VM stop mid-update lost
# config/zones.json because the temp file was on /tmp — a DIFFERENT filesystem —
# so `mv` was a non-atomic copy+unlink with no fsync). Fixes:
#   1. temp file in the SAME directory as zones.json → `mv` is an atomic rename;
#   2. `sync` after the rename so the write is durable before we move on.
tmp_current=$(mktemp "${ZONES_CURRENT}.merge.XXXXXX")
if ! jq --indent 4 '.' <<<"${merged_zones}" > "${tmp_current}" \
   || ! jq empty "${tmp_current}" 2>/dev/null; then
    rm -f "${tmp_current}"
    die "  Merge produced invalid JSON — leaving ${ZONES_CURRENT} unchanged"
fi

# Only write if content actually changed (avoid pointless mtime churn).
if ! diff -q "${tmp_current}" "${ZONES_CURRENT}" >/dev/null 2>&1; then
    mv "${tmp_current}" "${ZONES_CURRENT}"   # atomic: same filesystem
    sync                                     # durable: flush before continuing
    info "  ${GN}✓${CL} Wrote merged ${ZONES_CURRENT}"
    info "    Apply on OPNsense via:"
    info "      ${BL}zone-manager --no-ssl-verify --zones-file ${ZONES_CURRENT} --execute${CL}"
else
    rm -f "${tmp_current}"
fi

# Advance baseline regardless: future merges compare against the new release.
cp "${ZONES_SOURCE}" "${ZONES_ORIG}" && sync

if [[ "${backfilled}" -eq 1 ]]; then
    info "  Backfilled ${ZONES_ORIG} from upstream source"
fi

exit 0
