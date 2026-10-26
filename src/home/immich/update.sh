#!/usr/bin/env bash
# TAPPaaS Module: immich -- Update
#
# Nothing to do here, by design. The NixOS configuration (immich.nix) is built
# and applied by the templates:nixos dependency (update-os.sh) on every install
# and update -- against the release's pinned nixpkgs, with release moves staged
# for the next boot (#728) and the build done on the mothership (#774). A
# rebuild here would build again against the VM's own channel and could undo a
# release move.
#
# The public URL the mobile OAuth redirect needs comes from immich.json, which
# update-os.sh deploys beside immich.nix; immich-configure-oidc is part of the
# build and re-runs when it changes.
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

debug "immich: nothing to update beyond templates:nixos (immich.nix is applied there)"
