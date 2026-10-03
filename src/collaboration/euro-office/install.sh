#!/usr/bin/env bash
# TAPPaaS Module: euro-office — Installation
#
# Euro-Office DocumentServer — collaborative document editing platform
#
# Creates the euro-office VM in Proxmox and applies initial configuration.
# It assumes that you are in the install directory.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh euro-office

# cluster:vm already created the VM (install-module Step 5); the module install.sh
# does only module-specific post-install. Source the shared routines for logging
# helpers + get_config_value (modern pattern — not the deprecated install-vm.sh,
# which re-runs VM creation and expects /root/tappaas/<vm>.json on the node).
. /home/tappaas/bin/common-install-routines.sh

# run the update script as all update actions is also needed at install time
. ./update.sh

# ── Nextcloud connector — owned by Nextcloud, NOT here (ADR-COM-0002) ─────────
# euro-office does ONLY its own layer (the document server + its auto-generated JWT
# in euro-office.nix). The euro-office <-> Nextcloud connector is wired by NEXTCLOUD:
# its services/nextcloud/install-service.sh (N4) fires because this module declares
#   dependsOn nextcloud:fileservice  +  config["nextcloud:fileservice"].connector = "onlyoffice"
# and reads euro-office's JWT, writes /etc/secrets/onlyoffice.env on the Nextcloud VM,
# and restarts nextcloud-configure-eurooffice. No cross-VM SSH from this module.
# The document-server -> Nextcloud return path is declared here as `egress` (network:rules).

echo ""
info "${GN}✓${CL} euro-office installation completed successfully."
