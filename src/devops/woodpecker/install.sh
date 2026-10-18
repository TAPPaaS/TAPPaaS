#!/usr/bin/env bash
# TAPPaaS Module: woodpecker — Installation
#
# The VM (cluster:vm), its NixOS configuration (templates:nixos), the route
# (network:proxy), the firewall rules (network:rules) and the Forgejo sign-in
# (forgejo:oauth) come from the dependencies. What is left is update.sh's:
# waiting for the server and its agent.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck source=update.sh
. ./update.sh "$@"
