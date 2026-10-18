#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm

# Strict mode: exit on error, undefined vars, pipe failures
set -euo pipefail

# Helper functions for output.
# This runs over SSH from install-platform.sh, so keep the console quiet:
# bootstrap's own status lines go to [Debug] (shown only when TAPPAAS_DEBUG=1),
# the noisy git/keygen output is redirected to $BOOTSTRAP_LOG, and the
# nixos-rebuild output is rendered as a row of progress dots (one per line).
BOOTSTRAP_LOG="${BOOTSTRAP_LOG:-/tmp/tappaas-bootstrap.log}"
: >"$BOOTSTRAP_LOG" 2>/dev/null || BOOTSTRAP_LOG=/dev/null
msg_info() { if [ "${TAPPAAS_DEBUG:-0}" = "1" ]; then echo "DEBUG: $*"; fi; }
msg_ok()   { if [ "${TAPPAAS_DEBUG:-0}" = "1" ]; then echo "DEBUG: $*"; fi; }

# Find the repo version of TAPPaaS to use
msg_info "Determining TAPPaaS repo to use"
if [ -z "${1:-}" ]; then
  REPOTOCLONE="https://codeberg.org/TAPPaaS/TAPPaaS.git"
else
  REPOTOCLONE="$1"
fi
msg_ok "Determined TAPPaaS repo to use: ${REPOTOCLONE}"

# Find the branch version of TAPPaaS to use
msg_info "Determining TAPPaaS branch to use"
if [ -z "${2:-}" ]; then
  BRANCH="stable"
else
  BRANCH="$2"
fi
msg_ok "Determined TAPPaaS branch to use: ${BRANCH}"

# ADR-033 D5: the fingerprints of the TAPPaaS release keys, exactly as published
# in INSTALL.md ("Compare the release signer"). The operator compares them with
# that page by hand — this is the one thing an install takes on trust. Empty
# until the owners' release keys are enrolled: TAPPaaS then signs nothing yet,
# and the install proceeds unverified. A third argument, or
# TAPPAAS_RELEASE_SIGNERS, replaces them (space-separated SHA256:... values).
TAPPAAS_RELEASE_SIGNERS_PUBLISHED=""
SIGNERS="${3:-${TAPPAAS_RELEASE_SIGNERS:-${TAPPAAS_RELEASE_SIGNERS_PUBLISHED}}}"
TRUST_DIR="/home/tappaas/config/.trust"

# bootstrap_signed_release <branch> <fingerprints>
# Before anything from the clone runs (nixos-rebuild runs it as root): on a
# staging/production branch the checked-out tip must carry a release tag signed
# by a key with one of <fingerprints>, listed in the tip's own allowed_signers.
# git and ssh-keygen only — the template image has no jq or python3; the full
# check (tree hash, trust record) follows the rebuild, from lib/repo-sync.sh.
# Sets INTRO_TAG / INTRO_FP. 0 = go on, 1 = refuse.
bootstrap_signed_release() {
  local branch="$1" fps="$2" flat signers t name out fp
  INTRO_TAG="" INTRO_FP=""
  flat="$(tr -d ' \t\n' < channels.json 2>/dev/null || true)"
  [[ "${flat}" =~ \"(production|staging)\":\[[^]]*\"${branch}\" ]] || return 0   # unstable: not signed (D1)
  signers="$(mktemp)"
  git show HEAD:.tappaas/allowed_signers >"${signers}" 2>/dev/null || : >"${signers}"
  if ! grep -qvE '^[[:space:]]*(#|$)' "${signers}"; then
    rm -f "${signers}"
    if [[ -n "${fps}" ]]; then
      echo "ERROR: ${branch} lists no release keys, but signers are published (${fps}) — refusing an unsigned TAPPaaS" >&2
      return 1
    fi
    msg_info "TAPPaaS signs no releases yet — installing unverified"
    return 0
  fi
  if [[ -z "${fps}" ]]; then
    rm -f "${signers}"
    if [[ "${TAPPAAS_UNSIGNED:-0}" == "1" ]]; then
      echo "WARN: TAPPaaS signs its releases, but no signer fingerprint was given — installing unverified (TAPPAAS_UNSIGNED=1)" >&2
      return 0
    fi
    echo "ERROR: TAPPaaS signs its releases, but no signer fingerprint was given to check them with." >&2
    echo "       Pass the fingerprints published in INSTALL.md as the third argument." >&2
    return 1
  fi
  for t in $(git tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -rV); do
    [[ "$(git cat-file -t "refs/tags/${t}")" == tag ]] || continue
    name="$(git cat-file tag "refs/tags/${t}" | sed -n 's/^tag //p' | head -1)"
    [[ "${name}" == "${t}" ]] || continue
    out="$(git -c gpg.ssh.allowedSignersFile="${signers}" verify-tag --raw "${t}" 2>&1)" || continue
    fp="$(printf '%s\n' "${out}" | sed -n 's/^Good "git" signature for .* with .* key \(SHA256:[^ ]*\).*/\1/p' | head -1)"
    case " ${fps} " in *" ${fp} "*) INTRO_TAG="${t}" INTRO_FP="${fp}"; break ;; esac
  done
  rm -f "${signers}"
  if [[ -z "${INTRO_TAG}" ]]; then
    echo "ERROR: ${branch} ($(git rev-parse --short HEAD)) is not a release signed by ${fps} — refusing to install it" >&2
    return 1
  fi
  echo "TAPPaaS ${INTRO_TAG}: signed by ${INTRO_FP} — compare it with the fingerprint in INSTALL.md"
}

# clone the tappaas-cicd repo (idempotent: reuse an existing checkout so this
# script can be safely re-run, e.g. by install-platform.sh's Phase B retry).
if [ -d TAPPaaS/.git ]; then
  msg_info "TAPPaaS already cloned — reusing existing checkout"
  git -C TAPPaaS fetch origin --tags >>"$BOOTSTRAP_LOG" 2>&1 || true
else
  msg_info "Cloning TAPPaaS repository $REPOTOCLONE ..."
  git clone "$REPOTOCLONE" >>"$BOOTSTRAP_LOG" 2>&1
fi
msg_info "switching to branch $BRANCH..."
cd TAPPaaS || exit 1
# Force the switch, onto the remote tip: a reused checkout may carry
# working-tree changes that block a branch switch — notably nix `result`
# build-output symlinks regenerated by pre-update.sh (some were committed
# before being .gitignored). They are regenerable, so discarding them is safe.
git checkout -f -B "$BRANCH" "origin/$BRANCH" >>"$BOOTSTRAP_LOG" 2>&1 \
  || git checkout -f "$BRANCH" >>"$BOOTSTRAP_LOG" 2>&1
bootstrap_signed_release "$BRANCH" "$SIGNERS" || exit 1

# go to the tappaas-cicd folder
msg_info "Changing to TAPPaaS-CICD directory and rebuilding the NixOS configuration..."
cd src/foundation/tappaas-cicd || exit 1

# The cicd VM is cloned from the PREBUILT NixOS template image, which has no
# /etc/nixos/hardware-configuration.nix (the image was built declaratively, not
# via the NixOS installer). tappaas-cicd.nix imports that file for the machine's
# real disk/boot layout, so generate it now from the running hardware. (Use
# --show-hardware-config so we write only hardware-configuration.nix and never
# touch configuration.nix — the system is built from the flake regardless.)
if [ ! -f /etc/nixos/hardware-configuration.nix ]; then
  msg_info "Generating /etc/nixos/hardware-configuration.nix from running hardware"
  sudo mkdir -p /etc/nixos
  sudo nixos-generate-config --show-hardware-config 2>>"$BOOTSTRAP_LOG" | sudo tee /etc/nixos/hardware-configuration.nix >/dev/null 2>>"$BOOTSTRAP_LOG"
  msg_ok "Generated /etc/nixos/hardware-configuration.nix"
fi

# rebuild the nixos configuration. NixOS version is pinned in ./flake.lock
# (declared in git); --impure only to read /etc/nixos/hardware-configuration.nix.
# The very verbose build output is rendered as a row of progress dots (one per
# line) and captured in full to $BOOTSTRAP_LOG; on failure its tail is shown.
msg_info "Rebuilding NixOS (nixos-rebuild switch) — progress dots follow"
if sudo nixos-rebuild switch --flake .#tappaas-cicd --impure 2>&1 \
     | tee -a "$BOOTSTRAP_LOG" \
     | { while IFS= read -r _; do printf '.'; done; printf '\n'; }; then
  msg_ok "NixOS rebuild complete"
else
  echo "ERROR: nixos-rebuild switch failed — tail of ${BOOTSTRAP_LOG}:" >&2
  tail -n 40 "$BOOTSTRAP_LOG" >&2
  exit 1
fi

# ADR-033 D5, the full check now the rebuild has brought jq and python3: the
# introduction verifies (tag, signer, tree-sha256), the trust record that later
# updates start from is written, and the anchor create-site.sh puts in
# site.json beside it.
if [[ -n "${INTRO_TAG}" ]]; then
  # shellcheck source=lib/repo-sync.sh
  . /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/repo-sync.sh
  REPO_SYNC_TRUST_DIR="${TRUST_DIR}"
  if ! repo_sync_introduce /home/tappaas/TAPPaaS "$BRANCH" TAPPaaS "$INTRO_TAG" "" "$INTRO_FP" 0 >>"$BOOTSTRAP_LOG" 2>&1; then
    echo "ERROR: TAPPaaS ${INTRO_TAG} does not verify against its introduction — tail of ${BOOTSTRAP_LOG}:" >&2
    tail -n 5 "$BOOTSTRAP_LOG" >&2
    exit 1
  fi
  jq -n --arg t "$REPO_SYNC_INTRO_TAG" --arg c "$REPO_SYNC_INTRO_COMMIT" --arg s "$REPO_SYNC_INTRO_SIGNER" \
    '{introduction: $t, introductionCommit: $c, signer: $s}' >"${TRUST_DIR}/TAPPaaS.introduction.json"
  msg_ok "TAPPaaS ${INTRO_TAG} verified; trust anchor in ${TRUST_DIR}/TAPPaaS.introduction.json"
fi

# create ssh keys for the tappaas user (idempotent: keep an existing keypair).
msg_info "Creating SSH keys for the tappaas user and installing them for the proxmox host..."
if [ ! -f /home/tappaas/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f /home/tappaas/.ssh/id_ed25519 -N "" -C "tappaas-cicd" >>"$BOOTSTRAP_LOG" 2>&1
fi
# enforce secure permissions on the private key
sudo chown tappaas:users /home/tappaas/.ssh/id_ed25519*
sudo chmod 600 /home/tappaas/.ssh/id_ed25519
# add the public key to authorized_keys so that tappaas user can ssh to itself
# (idempotent: only append if not already present).
touch /home/tappaas/.ssh/authorized_keys
grep -qxF "$(cat /home/tappaas/.ssh/id_ed25519.pub)" /home/tappaas/.ssh/authorized_keys \
  || cat /home/tappaas/.ssh/id_ed25519.pub >> /home/tappaas/.ssh/authorized_keys
chmod 600 /home/tappaas/.ssh/authorized_keys

# The console's setup token (ADR-034 D10). Until identity is installed there is
# no Authentik gate in front of the console, so it accepts mgmt and the admin VPN
# with this token instead; install.sh's summary prints it. Written once, and only
# before identity exists; the console refuses it once config/identity.json does.
CONSOLE_TOKEN=/home/tappaas/config/console-setup-token
if [ ! -f /home/tappaas/config/identity.json ] && [ ! -s "$CONSOLE_TOKEN" ]; then
  mkdir -p /home/tappaas/config
  (umask 077 && head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$CONSOLE_TOKEN")
  msg_info "Wrote the console setup token to $CONSOLE_TOKEN"
fi

chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/bootstrap.sh
chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/install.sh

msg_info "Please reboot tappaas-cicd VM."