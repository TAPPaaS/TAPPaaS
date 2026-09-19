#!/usr/bin/env bash
#
# TAPPaaS satellite module install (ADR-010 §8.4.1)
#
# Called by `module-manager module add satellite [--instance <name>] --address
# <public-ip> [--roles '[...]'] [--physicalLocation '{...}']`, after that wrote
# config/<instance>.json. Provisions the machine (Debian by default) over the
# operator's forwarded key, wires the tunnel on OPNsense, and — for a managed
# satellite, the default — authorizes the mothership's key so the sweep patches
# it. Run `module add` over `ssh -A`. See INSTALL.md.
#
# Usage: ./install.sh <instance>
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/satellite-lib.sh"

sat_load "${1:?usage: ./install.sh <instance>}"
sat_install
