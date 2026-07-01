#!/usr/bin/env bash
#
# sat-hello — disposable ADR-010 test module installer.
#
# No post-install steps: the VM is created by the cluster:vm install-service and
# its NixOS config (sat-hello.nix, declarative nginx on :80) is applied by the
# framework nixos-rebuild before this script runs. The public HTTPS endpoint is
# wired by the network:proxy install-service (binds the wildcard cert). Safe to delete.
#
# Usage: ./install.sh <vmname>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "${BOLD}sat-hello: no post-install steps (declarative nginx test fixture)${CL}"
