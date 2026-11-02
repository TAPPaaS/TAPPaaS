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

Log in from `~/lab2-install` on the Mac with `proxmox-ve_9.2-1-tappaas-auto.key`, then hop to the mothership with `/root/tappaas/tappaas-cicd.key`. `~/lab2-install` holds the ISO and key: both are credentials. Identity is installed and the console refuses the install LAN (§3).

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

The new order, Lars's decision of 2026-11-02:

1. Set up disks on the first node
2. Add more nodes
3. Rest of foundation, including the moves of `tappaas-cicd` and `network`
4. TLS
5. Switch setup
6. Wi-Fi
7. Physical site
8. Admin VPN
9. Stacks

Nodes come before the foundation because backup should sit on a different machine from what it protects, whenever there is one.

**Consequences of this order:**

- **The cut-over moves out of step 3.** The gate cannot be proven until a certificate exists (step 4) and the operator has a way in (step 8). So identity, the bootstrap and publishing the console run in step 3, the token and install LAN stay valid through steps 4 to 8, and the switch to the gate happens at the end of step 8, on a real sign-in. This lengthens the token's life, which the security review must cover.
- **Wildcard sites.** Identity and the console install before the wildcard exists. Check what each does until step 4 issues it, and whether their module tests fail in between. `per-service` sites get their certificates at install, if ports 80/443 are reachable.
- **Switch ports before step 5.** A second node boots over PXE on a switch that step 5 has not set up yet, and lab2's PXE trouble on 2026-11-01 was the port's config. The Add nodes step must say what the port needs. **Open:** is that sentence enough, or does a managed-switch site need its switch step before nodes?
- **Pools on added nodes.** HA needs the same pool on both machines, so step 2 must also offer a pool on each new node, using the same form as step 1.
- **Nodes before backup.** A node added first has no backup client. The backup install should wire it in through `integratesWith`, but this order has not been run. Add nodes has also only been used on a site with identity, so test it under the setup token.

### Step 1: Disks on the first node

- First and required, with a real outcome either way: a pool made, or "boot pool only" chosen and recorded.
- Reuse the node pool form in `ui/web/src/physical/nodepools.tsx` (`node storage add`, with `--disks`, `--layout`, `--wipe`). Do not build a second form.
- On a single-disk site (Hetzner with one disk, or no free disks) the step reads as done with a sentence saying why.

### Step 2: Add more nodes

- Reuse the Add node wizard, followed by the pool form for the new node.
- Needs a plain "no more machines" answer, so a single-node site moves on. It reads as done with one node.

### Step 3: Rest of foundation, as one panel and one job

The panel shows, top to bottom:

1. A description of what is about to happen: what gets installed, what gets moved, and that it keeps running if the browser is cut off.
2. The machines in short form: each node with its memory and disks.
3. The five foundation modules, the two installed (`network`, `tappaas-cicd`) and the three to install (`backup`, `identity`, `logging`). Each row has up to three drop-downs:
   - **Machine**: only with more than one machine.
   - **HA machine**: only with more than one machine, and with a "none" choice.
   - **Disk/pool**: always.

**Prefilled values**, from the default placement:

- The values in the module's `.json`.
- Where those are not possible: `tappaas1`, no HA, and `tanka1`, or `rpool` if there is no `tanka1`.
- `backup` has `node: ""` and `storage: tankc1`. It prefers a machine other than the one holding the mothership when one exists, and a `tankc1` pool over `tanka1`. This is the point of doing nodes first.

**An installed module's row is a move.** `network` and `tappaas-cicd` prefill to `tanka1` when the default allows it, so they move unless the operator sets them back to `rpool`. The panel marks each row as Install, Move or Stays.

**Rules for the drop-downs:**

- The pool list is what the chosen machine has. With an HA machine, it is what both have, because replication needs the same pool on both (`cluster/services/ha/update-service.sh` refuses otherwise).
- The HA list leaves out the chosen machine and any node without the guest's bridges (`cluster/lib/ha-bridge-lib.sh`). `network` needs the WAN bridge on its machine.
- Changing a machine rechecks the row and says what changed. The action stays disabled, with the reason next to it, while a row is invalid.
- Do not write the rules twice. `cluster/lib/storage-placement.sh` (`sp_choose`) already holds the fallback, and `get_default_ha_node` the HA default. One read verb returns the proposal and the choices per row, and the console only draws it.

**The script gets the same thing.** `rest-of-foundation.sh` grows the placement: with no arguments it uses the same default proposal, it can print the proposal, and it takes the operator's choices per module. The panel runs the script (or a verb built on it) with those choices, so the CLI and the console stay one path. Today it installs `backup identity logging` plus the bootstrap, on the module's defaults, and has no move. Preview shows the proposal with each move spelled out, per the preview/apply contract.

**The job's order:** moves first, so `network` and `tappaas-cicd` are on the pool before anything else, then backup, identity, logging, the identity bootstrap, publishing the console. One job with a line per module.

**Risks:**

- Moving `network` carries the firewall. Test it on lab2 alone first, from the install LAN, and watch whether the console session survives. Today's doc claims "without a restart".
- The job runs on the mothership while `tappaas-cicd` itself moves, by pool or by machine. A move to another machine has never been run for either guest.
- Moving between machines and between pools are two different operations. The panel can ask for both on one row, so the job must do them in a safe order.
- **Installing identity locks the operator out of the console. This happened on lab2 on 2026-11-01** (see below). It must be fixed before the step ships, and it is worth fixing first, since today's wizard does it too.
- Keep "Publish the console" inside this step. Today it is a separate button next to Identity, and it cannot be reached once identity is in.

**The identity lockout, as seen on lab2.** Lars installed identity from Day 1 over the install LAN at 21:31. The result:

- `config/identity.json` exists, so the console deleted `console-setup-token` and refuses the install LAN (`refused connection from 192.168.14.91`). The browser gets nothing back. It is not a 401 and there is no message.
- The console module is not installed, so there is no `console.<domain>` route, and the bootstrap of the operator's own user has not run either. The next Day 1 steps are out of reach.
- `install-access.sh` never ran `close`: the firewall forward on wan:9097 and `config/console-setup-allow` are still there, doing nothing. `status` still reports the install LAN as open, and `console-setup-url` is gone only because this site predates that file.
- The service itself is healthy (200 on `127.0.0.1`), and nothing tells the operator what happened or how to get back.

The cause: the switch to the gate keys on `config/identity.json`, written the moment identity is installed. But the gate only works later, once the identity bootstrap has made a user and the console module has published the route, and it is only reachable from `mgmt` or the admin VPN.

What the fix must do:

- Make the cut-over the last thing that happens, not the first. The setup token and install LAN stay valid until the gate is proven: operator's user exists, the console route answers, and a signed-in request succeeded. Key the refusal on that, not on `identity.json`. ADR-034 D10 and `console/INSTALL.md` state the current rule, so update them, and review the security effect of keeping the token alive during this window.
- Step 3 runs identity, bootstrap and the console publish as one job. It keeps running on the mothership if the browser is cut off, and the operator ends on a page that says where to go next.
- Before the cut-over, the operator must have a way in that works: the admin VPN imported and tested. An install-LAN operator today has no reason to have done so.
- The console's refusal should explain itself in the browser: the address to use and why, not a dropped connection.
- `install-access.sh close` runs as part of the cut-over, so no forward is left behind.
- A recovery path for a site already in this state, documented in `console/INSTALL.md`.

**lab2 is still locked out, left as found for study.** Recovery is not yet tried. The likely route is the mothership's CLI: `identity-manager bootstrap` and `reconcile`, then `module-manager add console --proxyDomain console.<domain>`, then reach it over the admin VPN (`/root/tappaas-admin-vpn.conf`). Its domain `lab2.hrossen.dk` must resolve for that route. Run it as the first test of the recovery path, or reinstall.

### Step 4: TLS (needs design)

Today: `dnsMode` per environment, `per-service` by default (Caddy over HTTP-01) or `wildcard` (OPNsense ACME, DNS-01). In `per-service` the step reads done with nothing done, and the wildcard path shows a provider, key name and value form plus a `dns_cf_token`-style hint.

Problems to solve:

- The operator chooses a strategy without knowing what it implies. `per-service` needs ports 80/443 reachable and public DNS records, so a home site behind NAT or an internal-only site fails later and far from this step.
- A wildcard needs a DNS provider API key, which is the step people get stuck on.
- `dnsMode` can only be changed elsewhere, and the wizard doesn't offer it.
- "Done" means nothing was tested. Nothing checks that a certificate was actually issued.

Direction: ask one plain question first (internal only, public services on this machine's own address, or a DNS provider with an API), set the mode from the answer, and make "done" a real check. **Open:** whether "internal only" is a supported end state with no certificates (`INSTALL.md` Step 4 says it is), and what the console itself then uses. Needs a short design note before code.

### Step 5: Switches

- The step registers a UniFi controller only: the form is `unifi`, and `add-controller` has `--vendor unifi` prefilled. Lars's point: it implies UniFi, while MikroTik and manual switches exist too.
- It is also **required**, and done only when a switch has discovered ports. A site with an unmanaged or manual switch can never finish Day 1. `completed` stays false for good. Fix that first: make it optional or give it a "no managed switch" answer.
- Start with a choice: UniFi, MikroTik, manual (`switch-manager add-switch --managed manual`, which prints the steps), or none. Check what each vendor supports today before promising it (`src/foundation/network/scripts/switch-controller`, `docs/plans/mikrotik-mlag-test-plan.md`). The site's own firewall VLANs must not depend on this step.

### The rest

Wi-Fi and physical stay as they are, optional, in steps 6 and 7. Stacks are last.

Step 8, the admin VPN, is required: the gate is reachable only from `mgmt` and the VPN, so this step tests the VPN and ends with the sign-in that does the cut-over. The install's first peer already exists (`/root/tappaas-admin-vpn.conf`), so existing is not enough to read as done.

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
2. Day 1 landing page (§2), make the switch step not block completion (§3 Step 5), and fix the identity lockout (§3 Step 3). The lockout comes first: until it is fixed, Day 1 cannot be completed from the install LAN.
3. Prove the pool and move commands by hand on lab2: move lab2 to `main`, make `tanka1` with `--wipe`, move `tappaas-cicd` and `network` from the CLI, and fix what breaks. Everything in Steps 1 to 3 depends on this. Then `rest-of-foundation.sh` on lab2.
4. Day 1 Step 1 (disks).
5. Day 1 Step 2 (add nodes, with a pool on each).
6. Day 1 Step 3 (the placement read, the script, the panel), including the token expiry answer.
7. TLS design note, Lars's decisions, then the step.
8. Switch step choices.
9. Step 8: the VPN test and the sign-in cut-over.
10. Fresh install of lab2 through the finished path, reviewing the doc as it goes. It proves the endnote too.
11. `INSTALL.md` restructure, from what that run shows.
12. Hetzner, on a real machine.

Steps 2 and 3 can run side by side. Hold the doc restructure until step 10, so it describes what works.

## 6. Also open

- `install.sh`'s hand path still re-launches in full-screen tmux and hides the scroll. Only the media script follows the log. Unify if the hand path stays in the simple guide.
- WAN and LAN ports are now auto-detected on the media-script path. On a machine with several spare NICs the LAN pick can be wrong. **Open:** add a question, or leave it to `node network set`.
- `dist-upgrade` during the install keeps its terminal in a detached tmux pane, so a dpkg prompt would hang unseen. It did not happen on lab2. Check for `DEBIAN_FRONTEND` and conffile options in `cluster/install.sh`.
- The media script's stick write prints `dd` record noise.
- hrossen's mothership reports a changed host key for `tappaas2`. Not investigated; do not clear it blindly.
- `release/bump-version.sh --check` caught the v1.4 tag loss, but nothing runs it at a boundary yet.

## 7. Building the Day 1 pages with the console-gui skill

The `console-gui` skill (`~/.claude/skills/console-gui/SKILL.md`, a symlink into `tappaas-claude`) is the working guide for any change under `ui/`. A session started before the skill existed cannot load it by name, so it reads the file instead. `docs/plans/console-gui-pipeline.md` has the reasons, `.interface-design/system.md` the tokens and wording.

Tried on `main` on 2026-11-02, in a fresh worktree:

- `ui/web/e2e/run.sh --routes setup-day1 --viewports phone,laptop --no-flows` passed. The first run took 2 minutes, including `npm ci`, the baseline and the build.
- `scripts/test/test-console-design.sh` passed (27 checks).
- `ui/test.sh` passed (57), but only with the web app's `tsc` on PATH. Without it, all three stages fail at once with a misleading "type errors":

```bash
PATH="$PWD/web/node_modules/.bin:/opt/homebrew/bin:$PATH" /opt/homebrew/bin/bash ./test.sh
```

**The trap to expect:**

- **The fixtures show a finished site.** They are captured from hrossen, so `/setup/day1` shows every step done. No page of the new wizard can be seen in its real state with them. This has to be solved first.

**The work order for the wizard:**

1. Make a fresh-site fixture set: one node, `network` and `tappaas-cicd` only, no identity. `ui/test/fixtures/capture.sh --host <lab2's mothership> --out <dir>` captures a real one, ideally right after the next lab2 reinstall. Add a hand-made two-node variant, since the panel behaves differently with more than one machine.
2. Teach `run.sh` to serve another set. `fixture-server.sh --fixtures <dir>` can already; `run.sh` has no such option. Add `setup-day1-fresh` routes in `e2e/routes.json`.
3. Build the placement read first, with unit tests over the fixtures. The rules live there, not in the page.
4. Build the panel from the shared parts (`wizard.tsx`, `flows.tsx`, `stepform.tsx`, `jobs.tsx`). A new step, confirm or output panel is a review finding.
5. Add `web/e2e/flows/foundation.spec.ts`, as with `add-node.spec.ts`: click through it, and assert on the verb the server's journal recorded. Cover one machine (pool drop-down only), two machines (three drop-downs), an invalid HA and pool pair (button disabled, with the reason), and a row set back to `rpool` (no move).
6. Check at phone width. Three drop-downs on a row will need to stack.
7. Run it on hrossen with `TAPPAAS_SIMULATE=1`, then for real only on lab2.

A session never commits a Mac-built `web/dist`. It builds on hrossen's nix as the skill says, and only one session writes the console sources at a time.

## 8. Working rules for whoever picks this up

- `adr-041` is merged, and work happens on `main` in `~/src/TAPPaaS`. Other sessions commit there too, so commit by pathspec and never switch branch or stage unrelated files.
- The operator pushes. Fast-forward local `main` and hand over the push command.
- Commit subject at most 72 characters, body at most 3 lines, no Claude co-author, by pathspec.
- Export `SSH_AUTH_SOCK` from launchctl before ssh or git calls.
- hrossen is on `main` again. Check for other sessions' tests before a live phase there, and end live tests with a teardown. makerfloss is read-only.
- Mac: `/bin/bash` is 3.2 and BSD tools. Test the media script with `/bin/bash`; other suites with `/opt/homebrew/bin/bash`.
- Test against the real path, and gate a commit on the test result. This session reported two things as working that only a real run disproved.
