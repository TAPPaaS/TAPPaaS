#!/usr/bin/env bash
# TAPPaaS Module: nomad (Project N.O.M.A.D.) — Installation
#
# The VM (cluster:vm), its NixOS configuration (templates:nixos) and the rules
# that let the client networks reach it (network:rules) come from the
# dependencies. What is left is update.sh's: the Command Center's URL. Content
# (Wikipedia and other libraries, courses) and the apps are chosen in the
# Command Center — see INSTALL.md.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck source=update.sh
. ./update.sh "$@"
