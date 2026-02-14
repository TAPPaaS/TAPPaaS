# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TAPPaaS (Trusted - Automated - Private Platform as a Service) is a self-hosted platform designed for SMBs, government institutions, and home users who need privacy and data ownership. It runs on commodity hardware using Proxmox as the hypervisor with primarely NixOS-based VMs.

## Architecture

### Foundation Layer (src/foundation/)
Foundation modules must be installed in numbered order:
1. `05-ProxmoxNode` - First Proxmox node setup
2. `10-firewall` - OPNsense firewall configuration
3. `15-AdditionalPVE-Nodes` - Add cluster nodes
4. `20-tappaas-nixos` - NixOS VM template creation
5. `30-tappaas-cicd` - "Mothership" VM that controls the entire TAPPaaS system
6. `35-backup` - Proxmox Backup Server
7. `40-Identity` - Secrets and identity management

###  Platform and Service Modules (src/apps/)
Each module contains:
- `<vmname>.json` - module configuration (cores, memory, storage, network zones, dependencies, author, ...)
- `<vmname>.nix` - NixOS configuration for the VM
- `install.sh` - Called by tappaas-cicd to install the module
- `update.sh` - Called regularly to patch/update an installed module
- `test.sh` - Called regularly to test that the service is functioning correctly, can be used for regression testing of a module
See `src/apps/00-Template/README.md` for details

### Configuration Files
- `src/foundation/zones.json` - Network zone definitions with VLAN tags and access rules
- `src/foundation/module-fields.json` - Schema defining all available fields for module JSON configuration

## Command/Scripts dependencis

See `src/foundation/DEPENDENCIES.csv` and `src/foundation/DEPENDENCIES.md`
For structure of a module 

### Module Installation
`install.sh` in the root of the module will install the module. must be called with arguments see `apps/00-Template/README-install.md`

## Network Zones/VLANs
Defined in `zones.json` with VLAN tags.

## Naming Conventions
- VM name, hostname, and service name are identical (e.g., `nextcloud`)
- Node names: `tappaasY` where Y is a sequence number (e.g., `tappaas1`, `tappaas2`, `tappaas3`)
- Storage pools: `tankXY` where X indicates type and Y a sequence number (e.g., `tanka1`)
- Hyphens preferred over Capitalization (e.g., `tappaas-cicd`)

# Coding Rules

## General Workflow

1. **Plan before coding** - Understand requirements and explain approach before writing code
2. **Ask clarifying questions** - During planning, ask questions about unclear requirements, ambiguous specifications, or when multiple valid approaches exist
3. **Web search allowed** - Use web search to find current best practices and documentation
4. **Never commit to git** - Do not run `git commit` or `git push` unless explicitly requested

## Testing Requirements

1. **Create testable code** - Add or expand `test.sh` with test cases for new functionality
2. **Propose tests first** - Describe what you want to test and ask for approval before running
3. **Use coded tests** - Run tests via `test.sh` rather than ad-hoc manual testing

## Shell Script Standards

When writing or modifying bash scripts for TAPPaaS, **always use** the installed skills:

- `bash-script-generator` - For creating new scripts with proper structure, error handling, and logging
- `bash-script-validator` - For validating scripts with ShellCheck and security checks

All scripts must follow:

- Strict mode: `set -euo pipefail`
- Proper logging functions (debug, info, warn, error)
- Argument validation and help/usage text
- Cleanup trap handlers for signals
- Quoted variables and secure input handling
