# Install simplification: from bare metal to a finished Day 1

Status: agreed direction from Lars, 2026-11-01. Decisions marked **Open** are his to make; everything else can be picked up by another session. Scope: the install path from `make-install-media.sh` through the console's Day 1 wizard, and `src/foundation/INSTALL.md`.

The goal: one path for the common case. Answer a few questions, boot the machine, follow one endnote into the console, and let Day 1 finish the site in order, with few forms.

## 0. Where we stand

**Proven live on 2026-11-01** (lab2, spare machine, PXE from the Mac, branch `adr-041`):

- The media script: build, USB write, PXE from a Mac, node discovery, ssh start of the install.
- The unattended install: all five phases, no prompts. It runs detached in tmux on the node and the script follows the log.
- `network` and `tappaas-cicd` end up on the boot pool (`rpool`). No data pool is made.
- The console answers on the install LAN (`http://192.168.14.140:9097/`, 401 until the token).
- The firewall root password lands in `/root/.opnsense-root-password`.

**Written but not yet proven:**

- The new endnote (`5b933ffb`, `9ca26a48`). lab2 ran the old one, so it has never been seen on a real install. Only a render with stand-in values.
- The token command's whole path on a fresh node (the endnote's `accept-new` form). The manual equivalent worked on lab2.
- `install-access.sh` writing `config/console-setup-url`.
- The single-sudo root helper for PXE (`e6d635eb`): tested with stand-ins for `sudo` and `dnsmasq` only.
- The debconf fix (`9e04d046`) and the `repository modify` output (`cb18cf26`).
- Pool creation and moving guests: `node storage add` plus `module modify network|tappaas-cicd --set storage=tanka1` has never run for real. The doc's commands for it are unproven.

**The test bed.** lab2 is at `192.168.14.93` (node), `192.168.14.140` (firewall WAN), `10.0.0.203` (mothership). Boot disk: 500 GB Samsung 870 EVO. Two 2 TB 990 PRO NVMe carry an old exported `rpool-OLD-…`, so a pool on them needs `--wipe`. It follows `adr-041`, whose Codeberg tip stops at `f89cb749`. Move it to `main` before its first update:

```bash
site-manager repository modify TAPPaaS --branch main
```

Log in from `~/lab2-install` on the Mac with `proxmox-ve_9.2-1-tappaas-auto.key`, then hop to the mothership with `/root/tappaas/tappaas-cicd.key`. `~/lab2-install` holds the ISO and key: both are credentials. No identity is installed yet, so the setup token is still valid.

## 1. Boot disk override

**Answer to Lars's question: the override exists, but only as a flag.** `make-install-media.sh --disk <size|model|serial>` picks another disk, a second `--disk` mirrors, and `--disk ask` asks on the target's console. It uses the same matching as `node add --boot-disk`. The automatic choice (smallest SSD/NVMe, or both of an identical smallest pair) is the default, and the script's questions never mention it.

Work:

- Add one question to the build: `Boot disk [auto: the smallest SSD/NVMe]:`. Enter keeps `auto`; a size, model or serial goes to the existing `--disk`. Mirror stays a flag unless the first answer is a named disk, then ask `Second disk to mirror [none]:`.
- The script cannot see the target's disks at build time, so the question must explain what can be typed. `--disk ask` remains the way to see them.
- The answer is baked into the image, so `--use` cannot change it. Say that in the question.
- Test: a build with a named size, on a machine with disks of two sizes (lab2's spare has them).

## 2. The endnote, and landing in Day 1

Work:

- Reinstall lab2 from scratch once, after §5 or whenever convenient, to prove §0's new endnote end to end.
- The endnote's URL opens the console, and after the token the first page must be Day 1. Today `/` goes to Overview, with a one-line link to setup (`ui/web/src/App.tsx`, `setupIncomplete`). While Day 1 is incomplete, `/` should redirect to `/setup/day1`.
- Could the script show the token itself? Over ssh it is one command, and printing it would put it in the log, which ADR-034 D10 rules out. Keep it out of the log. **Open:** have the media script offer `ssh` to read it on request, without logging, or leave the command in the endnote.
- A reinstall changes the node's host key, so `ssh root@<node>` from the operator's machine fails with `REMOTE HOST IDENTIFICATION HAS CHANGED`. Lars hit this. The endnote's `ssh root@<node>` needs the media key and a word on this, or the media script should run the token command for the operator, which settles the previous point too.

## 3. Day 1 wizard rework

Today's order (`ui/src/setup.ts`): TLS, backup, identity, logging, identity bootstrap, nodes, switch, admin VPN, then the optional stacks, Wi-Fi and physical. There is no disk step. The page body is in `ui/web/src/pages/Setup.tsx`.

The new order:

### Step 1: Disks

- First and required, with a real outcome either way: a pool made, or "boot pool only" chosen and recorded.
- Reuse the node pool form in `ui/web/src/physical/nodepools.tsx` (`node storage add`, with `--disks`, `--layout`, `--wipe`). Do not build a second form.
- On a single-disk site (Hetzner with one disk, or no free disks) the step reads as done with a sentence saying why.

### Step 2: Foundation, as one step

- One action installs identity, logging and backup, runs the identity bootstrap, and moves `tappaas-cicd` and `network` to `tanka1` if Step 1 made a pool. No separate install form per module.
- The defaults come from the records. Ask only what has no default. Show one job with a line per module; a module's fields stay reachable behind an Advanced link.
- `rest-of-foundation.sh` already does most of this in one run. The step should run it (or a verb built on it), so the CLI and the console stay one path. It lacks the storage move.
- **Order inside the step:** the move should come first, so the later modules land on the pool, unless a test shows otherwise. Backup's placement on one node needs a look.
- Moving `network` carries the firewall, so this is where the live move is most dangerous. Test it on lab2 alone first, from the install LAN, and watch whether the console session survives. Today's doc claims "without a restart".
- **Token expiry.** Installing identity ends the setup token: the console refuses it and deletes the file, and the install-LAN forward closes when the console module is published. A one-click step will hit this mid-run. Decide how the operator gets back in: the admin VPN and `console.<domain>` behind the gate, and who the first user is. This must be solved before the step ships; otherwise the page dies halfway through.
- Keep "Publish the console" inside this step.

### Step 3: TLS (needs design)

Today: `dnsMode` per environment, `per-service` by default (Caddy over HTTP-01) or `wildcard` (OPNsense ACME, DNS-01). In `per-service` the step reads done with nothing done, and the wildcard path shows a provider, key name and value form plus a `dns_cf_token`-style hint.

Problems to solve:

- The operator chooses a strategy without knowing what it implies. `per-service` needs ports 80/443 reachable and public DNS records, so a home site behind NAT or an internal-only site fails later and far from this step.
- A wildcard needs a DNS provider API key, which is the step people get stuck on.
- `dnsMode` can only be changed elsewhere, and the wizard doesn't offer it.
- "Done" means nothing was tested. Nothing checks that a certificate was actually issued.

Direction: ask one plain question first (internal only, public services on this machine's own address, or a DNS provider with an API), set the mode from the answer, and make "done" a real check. **Open:** whether "internal only" is a supported end state with no certificates (`INSTALL.md` Step 4 says it is), and what the console itself then uses. Needs a short design note before code.

### Step 4: Switches

- The step registers a UniFi controller only: the form is `unifi`, and `add-controller` has `--vendor unifi` prefilled. Lars's point: it implies UniFi, while MikroTik and manual switches exist too.
- It is also **required**, and done only when a switch has discovered ports. A site with an unmanaged or manual switch can never finish Day 1. `completed` stays false for good. Fix that first: make it optional or give it a "no managed switch" answer.
- Start with a choice: UniFi, MikroTik, manual (`switch-manager add-switch --managed manual`, which prints the steps), or none. Check what each vendor supports today before promising it (`src/foundation/network/scripts/switch-controller`, `docs/plans/mikrotik-mlag-test-plan.md`). The site's own firewall VLANs must not depend on this step.

### The rest

Admin VPN, nodes, stacks, Wi-Fi and physical stay, after the above. **Open:** is one required node step useful on a single-node site (it reads done at once), and is the VPN required on a LAN site? The install's first peer already exists (`/root/tappaas-admin-vpn.conf`), so it may read done from the start.

Rule for the whole page: each step states what it will do, shows a real result, and has a way out when it does not apply. Follow `docs/plans/console-gui-pipeline.md` for how to develop and test console changes.

## 4. `INSTALL.md`

`src/foundation/INSTALL.md` is 931 lines: six steps with several options each, appendices, and detail that belongs in component docs. It still describes the CLI path as the main one.

Restructure around one opening choice:

- **Simple single-node install**: one short section. Media script, boot, endnote, console. Everything hands-off, with the disk override as a note.
- **Hetzner single-node install**: a hosted machine with one public address, no USB and no install LAN. The console is reached only over the admin VPN.
- **Full n-node production install**: planning first (disks, network, switches, domain, TLS), then the options that are there today: stock ISO, PXE, more nodes, CLI steps.

Move the rest (SSH appendix, hand PXE, Cloudflare scope) to the full path or to component docs. Published docs describe what is done, with no ADR or issue history. Update the "site code" wording to "Site name" with the media script (`f722271e`), including `--name` help, and settle `main` versus `stable` in the Step 2 commands.

**The Hetzner section is not writable yet.** It is the 2.4 install theme (`docs/ADR/ADR-037 - Install.md`) and has never been run. Unknowns: how the installer gets onto a machine with no USB (rescue system, or KVM with an ISO), one NIC with no LAN side, a public `wan` address (what `config-network.sh` does with one NIC and `--no-wan`), and the firewall's WAN address on the same interface. Needs a real test machine. **Open:** which Hetzner product and when.

## 5. Order of work

1. Boot disk question (§1). Small, independent.
2. Day 1 landing page (§2), and make the switch step not block completion (§3 Step 4). Small, and it unblocks everything else.
3. Prove the pool and move commands by hand on lab2: move lab2 to `main`, make `tanka1` with `--wipe`, move `tappaas-cicd` and `network` from the CLI, and fix what breaks. Everything in Step 1 and 2 depends on this. Then `rest-of-foundation.sh` on lab2.
4. Day 1 Step 1 (disks).
5. Day 1 Step 2 (foundation as one step), including the token expiry answer.
6. TLS design note, Lars's decisions, then the step.
7. Switch step choices.
8. Fresh install of lab2 through the finished path, reviewing the doc as it goes. It proves the endnote too.
9. `INSTALL.md` restructure, from what that run shows.
10. Hetzner, on a real machine.

Steps 2 and 3 can run side by side. Hold the doc restructure until step 8, so it describes what works.

## 6. Also open

- `install.sh`'s hand path still re-launches in full-screen tmux and hides the scroll. Only the media script follows the log. Unify if the hand path stays in the simple guide.
- WAN and LAN ports are now auto-detected on the media-script path. On a machine with several spare NICs the LAN pick can be wrong. **Open:** add a question, or leave it to `node network set`.
- `dist-upgrade` during the install keeps its terminal in a detached tmux pane, so a dpkg prompt would hang unseen. It did not happen on lab2. Check for `DEBIAN_FRONTEND` and conffile options in `cluster/install.sh`.
- The media script's stick write prints `dd` record noise.
- hrossen's mothership reports a changed host key for `tappaas2`. Not investigated; do not clear it blindly.
- `release/bump-version.sh --check` caught the v1.4 tag loss, but nothing runs it at a boundary yet.
- `ui/web/e2e/run.sh` defaults its base to `adr-041`. Change to `main` before that branch goes.

## 7. Working rules for whoever picks this up

- Branch work in a new worktree from `main`. Never switch or stage in `~/src/TAPPaaS`; other sessions commit there.
- The operator pushes. Fast-forward local `main` and hand over the push command.
- Commit subject at most 72 characters, body at most 3 lines, no Claude co-author, by pathspec.
- Export `SSH_AUTH_SOCK` from launchctl before ssh or git calls.
- hrossen is on `main` again. Check for other sessions' tests before a live phase there, and end live tests with a teardown. makerfloss is read-only.
- Mac: `/bin/bash` is 3.2 and BSD tools. Test the media script with `/bin/bash`; other suites with `/opt/homebrew/bin/bash`.
- Test against the real path, and gate a commit on the test result. This session reported two things as working that only a real run disproved.
