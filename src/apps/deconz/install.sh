#!/usr/bin/env bash
#
# TAPPaaS deCONZ module — install
#
# Install == update at first run: the engine has already cloned the NixOS golden
# template (cluster:vm, image 8080) and applied deconz.nix. update.sh does the
# module-specific post-install (ConBee USB attach + reporting).
#
# It assumes you are in the install directory.

. ./update.sh

echo ""
info "${GN}✓${CL} deCONZ VM installation completed successfully."
