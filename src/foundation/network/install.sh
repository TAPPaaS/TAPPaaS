#!/usr/bin/env bash
# install.sh — network is provisioned by the foundation bootstrap, not here.
#
# The firewall VM is stood up as step [2/5] of foundation/install.sh, BEFORE
# tappaas-cicd exists, so there is nothing for `module add network` to do; the
# zone/proxy/rules layer is then configured by the tappaas-cicd install. See
# INSTALL.md.
#
# This file exists so that "every module carries an install.sh" stays true with
# no declared exception for the tooling to carry (ADR-027 D2). It is not an
# unimplemented stub: the install is real and lives in the bootstrap.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "network is installed by the foundation bootstrap (foundation/install.sh step [2/5]) — nothing to do here. See INSTALL.md."
