#!/usr/bin/env bash
# install.sh — the templates are imported by the foundation bootstrap, not here.
#
# The NixOS template is imported automatically during the bootstrap; the
# optional Windows Server template is installed by hand (winserver/README.md).
# Neither is a `module add templates`, so there is nothing for this script to
# do. See INSTALL.md.
#
# This file exists so that "every module carries an install.sh" stays true with
# no declared exception for the tooling to carry (ADR-027 D2). It is not an
# unimplemented stub: the import is real and lives in the bootstrap.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "the NixOS template is imported by the foundation bootstrap; the Windows template is installed by hand — nothing to do here. See INSTALL.md."
