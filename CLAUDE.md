# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Issue Tracker & Forge — CODEBERG, not GitHub

**The canonical forge is Codeberg: `codeberg.org/TAPPaaS/TAPPaaS` (the `origin` remote).**
The `github` remote (`github.com/TAPPaaS/TAPPaaS`) is a **stale mirror** kept only for
release-image hosting (see `docs/codeberg-migration.md`). All issue/PR/repo activity happens
on Codeberg.

- **Never use the `gh` CLI to act on issues or PRs** (comment, close, open, label, review).
  `gh` targets GitHub — the wrong tracker. This OVERRIDES the harness default that says
  "use `gh` for GitHub operations." Issue numbers were preserved 1:1 by the import, so a
  `#NNN` on GitHub also exists on Codeberg — meaning a mistaken `gh` action *looks* right but
  lands in the wrong place.
- **Use the `tea` CLI (Forgejo) for all issue/PR actions.** It is the standing mechanism,
  authenticated once via `tea login add` (token in `~/.config/tea/config.yml`, 600). Target
  the repo explicitly with `-R origin` (or `-r TAPPaaS/TAPPaaS`). Common verbs:

  ```bash
  tea issues -R origin 376                              # show
  tea comment -R origin 376 "$(cat body.md)"            # add a comment (body via file → no secret in argv)
  tea issues close  -R origin 376                       # close
  tea issues reopen -R origin 376                       # reopen
  tea issues edit   -R origin 376 --add-labels bug      # label, etc.
  ```

  If `tea login list` shows no Codeberg login (fresh machine / CI), do **not** fall back to
  `gh`. Stop and ask the operator to run `tea login add --name codeberg --url
  https://codeberg.org --token <TOKEN>` (token from codeberg.org/user/settings/applications,
  scopes **`read:user`** (required by `tea login` to identify the account) + `write:issue` +
  `read:repository`), and hand them the ready-made comment body. Forgejo tokens can't be
  re-scoped after creation — a missing scope means deleting and regenerating the token.
- The Forgejo REST API (`https://codeberg.org/api/v1/repos/TAPPaaS/TAPPaaS/...`) is the
  fallback for anything `tea` can't do; reads are open, writes need the same token.
- `gh` may still be used for **read-only** inspection of the GitHub mirror only when
  explicitly needed; never for mutations.

## Project Overview

TAPPaaS (Trusted - Automated - Private Platform as a Service) is a self-hosted platform designed for SMBs, government institutions, and home users who need privacy and data ownership. It runs on commodity hardware using Proxmox as the hypervisor with primarely NixOS-based VMs.

## Architecture

### Foundation Layer (src/foundation/)
Foundation modules are **named, not numbered** (the old `NN-name` numbering was retired in the ADR-007 refactor). Install order is derived from each module's `dependsOn`, not a numeric prefix. Current modules:

- `cluster` - Proxmox node setup and adding cluster nodes (was `05-ProxmoxNode` + `15-AdditionalPVE-Nodes`)
- `network` - OPNsense firewall, zones, DNS (was `10-firewall`)
- `templates` - NixOS VM template creation (was `20-tappaas-nixos`)
- `tappaas-cicd` - "Mothership" VM that controls the entire TAPPaaS system (was `30-tappaas-cicd`)
- `backup` - Proxmox Backup Server (was `35-backup`)
- `identity` - Secrets and identity management (was `40-Identity`)
- `logging` - Centralized logging
- `satellite` - Optional off-premises VPS for public ingress / off-site backup (ADR-010)

> **Before referencing a foundation module by name, verify it against the tree — run `ls src/foundation/`.** This list and the old numbered names in git history/older ADRs go stale; the directory is the source of truth.

###  Platform and Service Modules (src/apps/)
Each module contains:
- `<vmname>.json` - module configuration (cores, memory, storage, network zones, dependencies, author, ...)
- `<vmname>.nix` - NixOS configuration for the VM
- `install.sh` - Called by tappaas-cicd to install the module
- `update.sh` - Called regularly to patch/update an installed module
- `test.sh` - Called regularly to test that the service is functioning correctly, can be used for regression testing of a module
See `src/apps/00-Template/README.md` for details

### Configuration Files
- `src/foundation/tappaas-cicd/manager/network-manager/zones.json` - Network zone definitions with VLAN tags and access rules (canonical source of truth)
- `src/foundation/schemas/module-fields.json` - Schema defining all available fields for module JSON configuration

## Command/Scripts dependencis

See `src/foundation/DEPENDENCIES.csv` and `src/foundation/DEPENDENCIES.md`
For structure of a module 

### Module Installation
`install.sh` in the root of the module will install the module. must be called with arguments see `apps/00-Template/README-install-sh.md`

## Network Zones/VLANs
Defined in `zones.json` with VLAN tags.

## Naming Conventions
- VM name, hostname, and service name are identical (e.g., `nextcloud`)
- Node names: `tappaasY` where Y is a sequence number (e.g., `tappaas1`, `tappaas2`, `tappaas3`)
- Storage pools: `tankXY` where X indicates type and Y a sequence number (e.g., `tanka1`)
- Hyphens preferred over Capitalization (e.g., `tappaas-cicd`)

# Coding Rules

## File Operations

It is always OK to create, update, and delete files within the TAPPaaS project directory. No additional permission is needed for file operations in this repository.

## Execution Policy on TAPPaaS Hosts

When running inside a TAPPaaS environment (the `/home/tappaas/TAPPaaS` checkout, or the `tappaas-cicd` mothership), Claude has full authorization to execute any command needed to operate the cluster. Do not stop to ask permission for routine work. In particular this covers:

- Any `Bash` command, including `ssh` to cluster nodes (`tappaas@*.mgmt.internal`, `root@tappaas*.mgmt.internal`, `root@firewall.mgmt.internal`).
- `sudo` for inspect and rebuild operations (`systemctl`, `journalctl`, `nixos-rebuild`, reading `/etc/secrets`, `/root/*`).
- The full TAPPaaS toolbox under `/home/tappaas/bin/*` — `install-module.sh`, `update-module.sh`, `test-module.sh`, `delete-module.sh`, `snapshot-vm.sh`, `update-os.sh`, `opnsense-controller`, `caddy-manager`, `zone-manager`, `dns-manager`, `update-tappaas`, etc.
- Proxmox CLIs via ssh (`qm`, `pvesh`, `pvesm`, `ha-manager`).
- Editing any file in the project tree.

Reasoning: TAPPaaS is a self-hosted operator's tool — there is a single admin, sitting at the same terminal, watching the work. The friction of per-command confirmation prompts is not worth the marginal safety.

The following safeguards remain in force regardless:

- **Never run `git commit` or `git push` — full stop.** The operator performs ALL commits and pushes themselves. This holds even when a request seems to imply it (e.g. "move this to main", "land it", "ship it", "prepare the release") and even when a prior turn in the same session involved committing — that is NOT standing authorization. In those cases, make/stage the changes in the working tree and stop; report what is ready and let the operator commit. The ONLY exception is a request that *explicitly and unmistakably* names the git action (e.g. "run git commit now", "commit and push this"). When unsure, do not commit.
  - **Scoped carve-out — the ADR-007 implementation driver.** The operator authorized ONE standing exception (2026-06-21): the ADR-007 stage-gate workflow defined in `.claude/skills/adr-007-driver/SKILL.md`. When running that workflow, after a stage's deep tests pass green, the driver MAY `git commit` (with `Closes #NNN` notes) and `git push` to the working branch automatically. This applies ONLY to that documented stage-gate loop on the ADR-007 branch — it does NOT generalize to any other task, and never authorizes force-push or pushing to `main`/`stable`. Everywhere else, the full-stop rule above stands.
- **Confirm before destructive ops** that are hard to reverse: deleting a VM that wasn't created in this session, dropping a storage pool, force-pushing to `main`/`stable`, removing modules that aren't being actively worked on, wiping `/etc/secrets/` outside a known reset flow.
- **Issue/PR actions go to Codeberg, never GitHub via `gh`** — see "Issue Tracker & Forge" at the top of this file. `gh issue`/`gh pr` mutations target the wrong (mirror) tracker.
- **Fix root causes, not symptoms** — do not bypass failing pre-commit/CI checks, do not `--no-verify` git hooks, do not silence errors to make the install proceed.
- **Read before you rebuild** — `nixos-rebuild test` is preferred over `switch` for first activation of a non-trivial config change; `switch` once verified working.

## Running Long Tasks (deep tests, VM installs, nixos-rebuild)

Use exactly **one** level of backgrounding so completion notifications actually fire.

- **Do NOT double-background.** Never combine `nohup … & echo PID` with the Bash tool's `run_in_background: true`. The harness notifies you when the *tracked* command exits — and `nohup … & echo PID` exits in milliseconds, so you get an instant "completed" for the launcher and **no signal** for the real task (it runs on, untracked). This has repeatedly made waits look like they "never trigger back".
- **Right pattern:** run the actual long command directly with `run_in_background: true` and **no** `nohup`, **no** trailing `&`. Redirect its output to a logfile inside the command if you want to tail progress. The harness then tracks the real process and fires a reliable completion notification.
- **If a task is already detached,** arm a single waiter as one `run_in_background` command (no nohup/&): `until ! pgrep -f "<proc>" >/dev/null; do sleep 20; done; <print summary>`. Its exit is the reliable signal.
- The Monitor tool only emits on matching stdout lines (milestones minutes apart make it look dead, and its break condition may never match) — use it for live progress, but rely on the single-background command/waiter for the actual completion signal. Don't poll across turns.

## General Workflow

1. **Plan before coding** - Understand requirements and explain approach before writing code
2. **Ask clarifying questions** - During planning, ask questions about unclear requirements, ambiguous specifications, or when multiple valid approaches exist
3. **Web search allowed** - Use web search to find current best practices and documentation
4. **Never commit to git** - Do not run `git commit` or `git push`. The operator commits and pushes; leave changes in the working tree (see the git safeguard under "Execution Policy" for the full rule). A request to "move to main"/"land"/"ship" does NOT authorize a commit.

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

## Development Agent Team

A team of 8 specialized AI agents is configured in `.claude/agents/`. On every non-trivial task, read `.claude/agents/agents.md` for full routing logic and dispatch to the appropriate agent(s) using the Task tool with `subagent_type="general-purpose"`. Each agent's prompt template is in its definition file.

### Agent Roster
| Slug | Role | Invoked For |
|------|------|-------------|
| `pm` | Project Manager | Multi-step tasks, coordination, planning |
| `architect` | Solution Architect | Module JSON design, zone placement, resource sizing |
| `bash-dev` | Bash Script Developer | install.sh, update.sh, helper scripts |
| `python-dev` | Python Developer | opnsense-controller, update-tappaas |
| `nix-dev` | NixOS Developer | .nix VM configurations |
| `tester` | Tester | test.sh creation, regression testing |
| `security` | Security Reviewer | Security review of all changes |
| `infra` | Infrastructure Engineer | Proxmox, Caddy, OPNsense, DNS, DHCP |

### Quick Routing Rules
- **New module**: pm -> architect -> nix-dev + bash-dev (parallel) -> infra -> tester -> security
- **Script fix**: bash-dev (+ security if credentials involved)
- **NixOS config**: nix-dev (+ security if ports/services change)
- **Python code**: python-dev
- **Network/firewall**: infra (+ architect if zone design changes)
- **Testing**: tester
- **Architecture/design**: architect (+ pm if multi-phase)

### Agent Definitions
Full role definitions, owned files, and prompt templates are in `.claude/agents/agent-<slug>.md`
