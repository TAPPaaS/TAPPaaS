#!/usr/bin/env bash
# TAPPaaS Module: lazysite — Installation
#
# The VM (cluster:vm), its NixOS configuration (templates:nixos), the public
# route (network:proxy), the firewall rules (network:rules) and the content
# repository with the VM's deploy key (forgejo:repo) come from the
# dependencies. What is left is update.sh's: waiting for the first pages.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck source=update.sh
. ./update.sh "$@"
