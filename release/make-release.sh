#!/usr/bin/env bash
#
# release/make-release.sh — guided driver for cutting a TAPPaaS release.
#
# Walks the release runbook (see release/README.md) step by step. Each
# mutating action is echoed and gated by a y/N confirm; --dry-run previews the
# whole flow touching nothing. The un-scriptable steps (deep tests on a live
# cluster, blank-system installs, Codeberg "Sync Now", the announcement) are
# printed as instructions with a confirm gate — the script never pretends to
# have done them.
#
# Release model (RC branch + final tag):
#   main → cut rc/<ver> → test --deep on a blank system → tag v<ver> →
#   fast-forward stable to v<ver> → push → push image tags to GitHub → Sync Now.
#
# Usage: make-release.sh --version <maj.min> [options]
#
# Options:
#   --version <maj.min>    Product version to release (e.g. 2.1). Required.
#   --nixos-tag <ver|tag>  Also (re)build the NixOS template image at this tag
#                          and repoint the config. Accepts "1.4" or the full
#                          "nixos-template-v1.4". Omit if images are unchanged.
#   --opnsense-tag <v|tag> Same for the OPNsense firewall image.
#   --from <ref>           Changelog start ref. Default: previous v* tag.
#   --dry-run              Show every step; execute nothing.
#   --yes                  Skip confirmations (non-interactive). Use with care.
#   -h, --help             Show this help.
#
# Never force-pushes; never pushes to main/stable without an explicit confirm.
# Exit codes: 0 ok · 2 usage/precondition error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

VERSION=""
NIXOS_TAG=""
OPNSENSE_TAG=""
FROM_REF=""
export DRY_RUN=0
export AUTO_YES=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     VERSION="${2:?--version needs maj.min}"; shift 2 ;;
        --nixos-tag)   NIXOS_TAG="${2:?}"; shift 2 ;;
        --opnsense-tag) OPNSENSE_TAG="${2:?}"; shift 2 ;;
        --from)        FROM_REF="${2:?}"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --yes)         AUTO_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version <maj.min> is required (see --help)"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]] || die "--version must look like maj.min (e.g. 2.1)"

require_cmd git
cd "$(repo_root)"
TAG="v${VERSION}"
RC="rc/${VERSION}"

# ── Steps ────────────────────────────────────────────────────────────

preflight() {
    step "Pre-flight checks"
    git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote (expected Codeberg)"
    git remote get-url github >/dev/null 2>&1 || warn "no 'github' remote — image-tag push will be skipped"
    if [[ -n "$(git status --porcelain)" ]]; then
        die "working tree not clean — commit or stash first"
    fi
    local br; br="$(git rev-parse --abbrev-ref HEAD)"
    [[ "${br}" == "main" ]] || warn "not on main (on '${br}') — releases are cut from main"
    if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
        die "tag ${TAG} already exists"
    fi
    run git fetch --tags origin
    info "Latest main: $(git log -1 --oneline main 2>/dev/null || echo '?')"
}

deep_test_gate() {
    step "Deep tests on the current cluster (manual)"
    cat <<EOF
  Run the full deep-test sweep against a live TAPPaaS (on the cicd mothership):
      TAPPAAS_TEST_DEEP=1 ./test.sh          # per foundation component
      test-module.sh --deep <module>         # per app module
  There is no single cross-catalog runner — sweep the modules you ship.
EOF
    confirm "Did the deep tests pass?" || die "aborting — fix failures first"
}

cut_rc() {
    step "Cut the release-candidate branch ${RC} from main"
    if git rev-parse -q --verify "refs/heads/${RC}" >/dev/null; then
        warn "${RC} already exists — reusing it"
    else
        run git branch "${RC}" main
    fi
    confirm "Push ${RC} to origin (so it can be installed on a blank system)?" \
        && run git push -u origin "${RC}"
    return 0
}

blank_install_gate() {
    step "Blank-system install + upgrade test (manual)"
    cat <<EOF
  On a blank test cluster, install the candidate and deep-test it (see INSTALL.md):
      REPO=https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/ ; BRANCH=${RC}
      curl -fsSL \${REPO}\${BRANCH}/src/foundation/install.sh >install.sh
      ./install.sh "\$REPO" "\$BRANCH" --name <org> --domain <domain>   # then test --deep
  Also verify the upgrade path from the current release:
      install previous 'stable', then switch its updateChannel to ${RC}
      (or to 'stable' once promoted) and confirm the GitOps pull upgrades it.
EOF
    confirm "Did the blank-system install and upgrade test pass?" \
        || die "aborting — candidate not verified"
}

bump_images() {
    [[ -n "${NIXOS_TAG}${OPNSENSE_TAG}" ]] || { info "No image rebuild requested — skipping."; return; }
    step "Build images and repoint configs"
    if git remote get-url github >/dev/null 2>&1; then
        [[ -n "${NIXOS_TAG}" ]] && push_image_tag nixos-template-v "${NIXOS_TAG}"
        [[ -n "${OPNSENSE_TAG}" ]] && push_image_tag opnsense-firewall-v "${OPNSENSE_TAG}"
        warn "Wait for the GitHub Actions builds to finish (Releases populated) before continuing."
        confirm "Are the GitHub Releases published?" || die "aborting — images not ready"
    else
        warn "no 'github' remote — build the images manually, then continue"
    fi
    local args=()
    [[ -n "${NIXOS_TAG}" ]]    && args+=(--nixos "${NIXOS_TAG}")
    [[ -n "${OPNSENSE_TAG}" ]] && args+=(--opnsense "${OPNSENSE_TAG}")
    run "${SCRIPT_DIR}/bump-version.sh" "${args[@]}"
    if [[ "${DRY_RUN}" -eq 0 && -n "$(git status --porcelain)" ]]; then
        confirm "Commit the image-pointer bump on ${RC}?" && {
            run git add src/foundation/templates/tappaas-nixos.json src/foundation/network/network.json
            run git commit -m "chore(release): point images at ${VERSION}"
        }
    fi
    return 0
}

push_image_tag() {  # push_image_tag <prefix> <ver|tag>
    local prefix="$1" arg="$2" tag
    [[ "${arg}" == "${prefix}"* ]] && tag="${arg}" || tag="${prefix}${arg}"
    if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        confirm "Create image tag ${tag} at HEAD of ${RC}?" && run git tag "${tag}" "${RC}"
    fi
    confirm "Push ${tag} to GitHub (fires the image-build Action)?" \
        && run git push github "${tag}"
    return 0
}

tag_and_promote() {
    step "Tag ${TAG} and promote stable"
    confirm "Create tag ${TAG} on ${RC}?" || die "aborting before tag"
    run git tag -a "${TAG}" "${RC}" -m "TAPPaaS ${VERSION}"

    # Fast-forward-only promote: stable must be an ancestor of the new tag.
    if git rev-parse -q --verify refs/heads/stable >/dev/null; then
        if [[ "${DRY_RUN}" -eq 0 ]] && ! git merge-base --is-ancestor stable "${TAG}"; then
            die "stable is not an ancestor of ${TAG} — refusing non-fast-forward promote"
        fi
    fi
    confirm "Move stable to ${TAG} (fast-forward)?" || die "aborting before promote"
    run git branch -f stable "${TAG}"
}

push_release() {
    step "Push to Codeberg (origin)"
    confirm "Push main, stable and ${TAG} to origin?" || { warn "skipped origin push"; return; }
    run git push origin main
    run git push origin stable
    run git push origin "${TAG}"
}

sync_and_notes() {
    step "Mirror sync, changelog, announcement"
    cat <<EOF
  Force the Codeberg → GitHub mirror now (else it waits up to a week):
      Codeberg → repo → Settings → Repository → Mirror settings → 'Sync Now'
EOF
    confirm "Triggered the mirror Sync Now?" || warn "remember to sync before announcing"

    local from="${FROM_REF}"
    [[ -z "${from}" ]] && from="$(git describe --tags --abbrev=0 --match 'v*' "${TAG}^" 2>/dev/null || echo stable)"
    step "Generating release notes (${from}..${TAG})"
    run "${SCRIPT_DIR}/changelog.sh" --from "${from}" --to "${TAG}"
    info "Add --enrich to fetch issue titles: release/changelog.sh --from ${from} --to ${TAG} --enrich > NOTES.md"
    info "Then send the announcement (forum / mailing list / channels)."
}

# ── Run ──────────────────────────────────────────────────────────────
echo -e "${BOLD}TAPPaaS release ${VERSION}${CL}$([[ ${DRY_RUN} -eq 1 ]] && echo '  (dry-run)')"
preflight
deep_test_gate
cut_rc
blank_install_gate
bump_images
tag_and_promote
push_release
sync_and_notes
step "Release ${VERSION} complete."
