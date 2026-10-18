#!/usr/bin/env bash
# TAPPaaS Module: karakeep — Installation
#
# The VM (cluster:vm), its NixOS configuration (templates:nixos), the proxy
# route (network:proxy), the firewall rules (network:rules) and the Authentik
# sign-in (identity:identity) come from the dependencies; AI tagging from
# litellm:models when the site has the AI stack. What is left is update.sh's:
# waiting for Karakeep to answer.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck source=update.sh
. ./update.sh "$@"
