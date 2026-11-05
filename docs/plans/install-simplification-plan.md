# Install simplification: from bare metal to a finished Day 1

Status: agreed direction from Lars, 2026-11-01. Decisions marked **Open** are his to make; everything else can be picked up by another session. Scope: the install path from `bootstrap-tappaas.sh` through the console's Day 1 wizard, and `src/foundation/INSTALL.md`.

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

**Proven live on 2026-11-02** (lab2): `node storage add` with `--wipe` made the `tanka1` mirror, and `module modify network|tappaas-cicd --set storage=tanka1` moved both guests live. Both then cold-booted from the pool and passed their tests. The first attempt failed because Proxmox will not delete a disk that snapshots hold, and an update always takes one; the rollback restored the firewall cleanly. A guest with snapshots now keeps its old disks until `snapshot-vm.sh --cleanup` finds no snapshot holding them, also proven. `identity` is still on `local-zfs`.

**Known gaps in the move:** a rollback after a successful move leaves the new disks orphaned on the target pool. `node storage add` prints "HA modules on tanka1" from the declared default, even for guests still on `local-zfs`.

**The test bed.** lab2 is at `192.168.14.93` (node), `192.168.14.140` (firewall WAN), `10.0.0.203` (mothership). Boot disk: 500 GB Samsung 870 EVO. Two 2 TB 990 PRO NVMe carry an old exported `rpool-OLD-…`, so a pool on them needs `--wipe`. It follows `main`.

Log in from `~/lab2-install` on the Mac with `proxmox-ve_9.2-1-tappaas-auto.key`, then hop to the mothership with `/root/tappaas/tappaas-cicd.key`. `~/lab2-install` holds the ISO and key: both are credentials. Identity is installed, the identity bootstrap has not run, and setup is open again (§3).

## 1. Boot disk override

**Answer to Lars's question: the override exists, but only as a flag.** `bootstrap-tappaas.sh --disk <size|model|serial>` picks another disk, a second `--disk` mirrors, and `--disk ask` asks on the target's console. It uses the same matching as `node add --boot-disk`. The automatic choice (smallest SSD/NVMe, or both of an identical smallest pair) is the default, and the script's questions never mention it.

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

1. Finish first node configuration
2. Add more nodes (optional)
3. Rest of foundation, including the moves of `tappaas-cicd` and `network`
4. TLS
5. Repositories (optional)
6. Configure switch fabric (optional)
7. Wi-Fi
8. Physical site
9. Admin VPN
10. Stacks

Nodes come before the foundation because backup should sit on a different machine from what it protects, whenever there is one. The switch fabric stays late because its controllers need the foundation and a repository: `unifi-os` is a VM that depends on backup, and both it and `mikrotik` are Community modules. LAN bonding is not part of Day 1 at all; it has its own Day 2 wizard.

**Consequences of this order:**

- **The cut-over is not part of step 3.** The gate cannot be proven until a certificate exists (step 4) and the operator has a way in (step 9). So identity, the bootstrap and publishing the console run in step 3, the token and install LAN stay valid through steps 4 to 9, and the switch to the gate happens at the end of step 9, on a real sign-in. This lengthens the token's life, which the security review must cover.
- **Publishing must not need public DNS.** Decided 2026-11-02: see "Local DNS mode" below. This replaces the order of steps 3 and 4 and the cut-over timing above once built.
- **Wildcard sites.** Identity and the console install before the wildcard exists. Check what each does until step 4 issues it, and whether their module tests fail in between. `per-service` sites get their certificates at install, if ports 80/443 are reachable.
- **Nodes before switches.** A node added at step 2 boots over PXE on a switch TAPPaaS does not manage yet, and lab2's PXE trouble on 2026-11-01 was the port's config. Add a node already prints what a manual switch port needs (`manualTrunkText`). Step 2 must show that, and the operator sets the port by hand. Step 6 then has to take over ports already carrying nodes without cutting them. `interrogate` leaves ports with a link alone, so test that this holds.
- **Nodes before backup.** A node added first has no backup client. The backup install should wire it in through `integratesWith`, but this order has not been run. Add a node has also only been used on a site with identity, so test it under the setup token.

**What counts as finished:** steps 1, 3, 4 and 9 are required. Steps 2, 5, 6, 7, 8 and 10 are optional, and none of them holds back completion.

### Local DNS mode (decided 2026-11-02)

**Superseded for design by [ADR-043](../ADR/ADR-043%20-%20Site%20Certificates.md) (draft).** The CA is not a mode: every site has one, and `ca-manager` owns it. The proofs below still stand. The build list below is replaced by the ADR's Delivery section.

A site works with no public DNS and no public certificate, and can go public later without renaming anything. The VPN needs only an IP address, so it comes first and everything after it uses local names.

**Proven on lab2, 2026-11-02, by hand:** a site CA and a `*.lab2.hrossen.dk` certificate in the firewall's trust store, `cert-refids.json` pointing at it, `dnsMode: wildcard`, and an Unbound wildcard to the DMZ gateway. With no public record, identity and the console got Caddy routes with that certificate, and `console.lab2.hrossen.dk` redirected through the gate to Authentik's login page. So the existing wildcard path carries this. The network-manager resolver treated those names as unpublished; that is fixed. The gate step on lab2 used a temporary bypass until that fix reaches it.

**Proven on lab2, 2026-11-02, later the same day:** without the CA, the logging VM failed OIDC discovery (`curl` exit 60), and the mothership failed its Grafana calls. The install still ended in congratulations. With `config/site-ca.pem` in place, `site-locale.sh` puts the CA in each guest's `tappaas-site.nix`, and logging then passed all its tests, its OIDC configured and `/login` redirecting to SSO. Lars then signed in to Grafana over the VPN, in Firefox with the site CA imported, so SSO and browser trust are both proven. The admin VPN needed one fix on the way: a proxy list with `mgmt` now also allows the `admin` zone. The Debian path is written but has not run on a guest. Apps inside containers are not covered: a container has its own trust store.

Found on the way: a mothership update refuses to run while Codeberg is unreachable. Rebuilding by hand needs `render_site_nix` and `tappaas-rebuild@tappaas-cicd.service`. A mothership needs that rebuild before its own calls trust the CA.

**To build:**

- `dnsMode: local` in the schema, environment-manager and the proxy scripts, behaving as `wildcard` with the certificate from the site CA instead of ACME.
- A verb that makes the CA and the wildcard, records the refid and adds the Unbound wildcard. Today's `environment-manager modify` refuses a site with no `ownerOrg`, so it must work before the identity bootstrap. Check the certificate's renewal, since `lifetime` is 397 days.
- The install: no domain given defaults to `<site>.home.arpa`. Use `local` by default.
- CA trust in containers that call Authentik, and on Proxmox nodes. The verb must write `config/site-ca.pem`. Fail the install, not congratulate, when an app's SSO could not be wired.
- The admin VPN step offers the CA file to the browser.
- An `internet` route in `local` mode says it is not reachable from the internet.
- New Day 1 order: first node, more nodes, VPN, foundation with publish and sign-in (setup closes here), then repositories, switches, Wi-Fi, physical, stacks, and an optional "Make it public" step replacing TLS. Lars confirmed this order on 2026-11-02.
- ADR for all of this, amending ADR-021 and ADR-034 D2, D10 and A15.
- Publishing must never report success with no route, whichever mode.

### Step 1: Finish first node configuration

- Disks only: `NodePools` (`ui/web/src/physical/nodepools.tsx`), the same part as stage 4 of Add a node. Do not build a second form. It already takes a `node` prop.
- The outcome is a pool made, or "boot pool only" chosen and recorded. On a machine with no free disks it reads as done with a sentence saying why.

### Step 2: Add more nodes (optional)

- Reuse the Day 2 Add a node wizard, from a button in the step. Its data pool stage gives HA its pools with no extra work.
- "No more machines" is a plain answer, and the step reads as done.
- **Two stages come out of the wizard, also on Day 2:**
  - Stage 6, "Place the machine correctly in the physical view". Placing belongs to Physical site.
  - Stage 5a, the LAN bond. It moves to the bonding wizard below.
- What remains is stages 0 to 4 and the WAN port, which becomes stage 5. Stage 1's text ("to be placed in stage 6"), `addNodeStage` and its `lan` and `done` stages, `STAGE_NUMBER`, `nodeadd.test.ts` and `flows/add-node.spec.ts` follow. Check that `addNodeStage` still has an end, because resuming a session depends on it. The wizard ends with a line saying where to find the machine and that bonding is on Day 2.

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

**Done on `main`, 2026-11-02:** the token file alone says setup is open, and the first installer through the gate deletes it and runs `install-access.sh close`. The closed address answers with a page saying where to go, and `install-access.sh reopen` recovers a site. ADR-034 v1.4 records it. Publishing the console no longer closes anything.

Still to do:

- Security review of the longer token life. It has no expiry and travels over plain HTTP on those networks. The token expiry answer belongs here.
- Step 3 runs identity, bootstrap and the console publish as one job. It keeps running on the mothership if the browser is cut off, and the operator ends on a page that says where to go next.
- Before the cut-over, the operator must have a way in that works: the admin VPN imported and tested. An install-LAN operator today has no reason to have done so.

**lab2, 2026-11-02:** on `main`, recovery proven: the closed address answered 403 with its page, and `install-access.sh reopen` brought back the token and the install LAN with one forward. It now runs the local DNS test setup by hand (above). **Proven live, same day:** the first gate sign-in over the admin VPN closed setup: the token is gone, no 9097 forward is left on the firewall, and the install-LAN address no longer answers. Getting there needed `blockpriv` removed from lab2's WAN by hand, and the password set from Day 2 (notes 1 and 4 below).

### Step 4: TLS (needs design)

Today: `dnsMode` per environment, `per-service` by default (Caddy over HTTP-01) or `wildcard` (OPNsense ACME, DNS-01). In `per-service` the step reads done with nothing done, and the wildcard path shows a provider, key name and value form plus a `dns_cf_token`-style hint.

Problems to solve:

- The operator chooses a strategy without knowing what it implies. `per-service` needs ports 80/443 reachable and public DNS records, so a home site behind NAT or an internal-only site fails later and far from this step.
- A wildcard needs a DNS provider API key, which is the step people get stuck on.
- `dnsMode` can only be changed elsewhere, and the wizard doesn't offer it.
- "Done" means nothing was tested. Nothing checks that a certificate was actually issued.

Direction: ask one plain question first (internal only, public services on this machine's own address, or a DNS provider with an API), set the mode from the answer, and make "done" a real check. **Open:** whether "internal only" is a supported end state with no certificates (`INSTALL.md` Step 4 says it is), and what the console itself then uses. Needs a short design note before code.

### Step 5: Repositories (optional)

- Today a fresh site has only the TAPPaaS repository. The install does not add Community, and repositories appear only on the Site page.
- The step lists what is registered and offers Community as one choice, prefilled, plus any other repository by URL. `site-manager repository add <url>` is the verb, with its branch and fingerprint handling; the step adds no logic of its own.
- "TAPPaaS only" is a plain answer, and the step reads as done.
- Say what Community is: modules maintained outside the core project. **Open:** the default branch for Community, and whether its trust check shows anything an operator must decide.

### Step 6: Configure switch fabric (optional)

Replaces today's "The switch", which is required, UniFi only, and can never finish on a site without a managed switch.

The help text at the top says, in plain words:

- It is fine not to have switches under management. TAPPaaS then works with what is there, and you set the VLANs on your switches by hand. The console tells you which VLANs each port needs. Skip this step if so.
- Managing them lets TAPPaaS set each port for you, and lets the bonding wizard set up switch ports.

Then:

- **Choose:** MikroTik, UniFi, or both. "None" is a clear answer that moves on and is recorded, so the step reads as done.
- **For each chosen vendor, run the basic setup and discovery:** install its module if needed, credentials and address, register, read the switches and ports (`switch-manager interrogate`), show what was found, then program trunks and park free ports (`reconcile`) with its preview.
- Reuse `manager/switch-manager/setup-switches.sh`'s logic where it fits. It already knows a brand's architecture: UniFi has a controller, MikroTik registers each switch by address.
- A switch we don't support stays `switch-manager add-switch --managed manual`, which prints the steps. Offer it behind the "none" answer.

**To solve:**

- **Needs Community.** If step 5 was skipped, say so and link back to it.
- **Credentials.** The console's declared secrets cover UniFi only. MikroTik's `setup-credentials.sh` needs a form, as a fourth declared secret, which changes ADR-034 D10's list of three.
- **Reachability.** The mothership must reach the controller or switch from `mgmt`. A factory-fresh switch, or a controller on the install LAN, may not be reachable. Check this on lab2, whose firewall WAN sits on that LAN.
- **`reconcile` on a live site.** It parks free ports and programs trunks while the operator and the nodes run through those switches. The preview must make that plain, and the operator's own port must not be parked.

Check what each vendor supports today before promising it (`src/foundation/network/scripts/switch-controller`, `docs/plans/mikrotik-mlag-test-plan.md`). The site's own firewall VLANs must not depend on this step.

### The rest

Wi-Fi and physical stay as they are, optional, in steps 7 and 8. Physical site is now the one place a machine gets its room and rack, so it must list nodes added in step 2 as still to be placed.

Step 9, the admin VPN, is required: the gate is reachable only from `mgmt` and the VPN, so this step tests the VPN and ends with the sign-in that does the cut-over. The install makes no peer: the step is done when the operator has enrolled a device, or has answered that their computer is on the site's LAN (enrolling stays open for the way in from outside).

Stacks are last.

### New Day 2 wizard: Bond a node's LAN

- A button "Bond a node's LAN…" on Day 2, with its route in `e2e/routes.json`. Pick a node, then run `LanUplink` (`ui/web/src/pages/NodeUplinks.tsx`), which already does the port, the mode, the switch port and the failover test, and already takes a `node` prop. It only needs a wizard around it.
- It covers every node, including the first. Add a node's copy goes (Step 2 above).
- Without a managed switch, `active-backup` is the choice that needs nothing from the switch. `lacp` needs the two switch ports set as one LAG first; the component already says so.
- **Risk:** a node can carry the firewall and the mothership, so a bond change touches the path the console itself runs on. It has only been done on a node holding neither. Test on lab2 first, from the install LAN, and have the wizard warn when the node holds them.

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
2. Day 1 landing page (§2), make the switch step optional with a "none" answer (§3 Step 6), take stages 5a and 6 out of Add a node with the bonding wizard in place (§3), and fix the identity lockout (§3 Step 3). The lockout comes first: until it is fixed, Day 1 cannot be completed from the install LAN.
3. Prove the pool and move commands by hand on lab2: move lab2 to `main`, make `tanka1` with `--wipe`, move `tappaas-cicd` and `network` from the CLI, and fix what breaks. Everything in Steps 1 to 3 depends on this. Then `rest-of-foundation.sh` on lab2.
4. Day 1 Step 1 (first node disks).
5. Day 1 Step 2 (Add a node in the wizard).
6. Day 1 Step 3 (the placement read, the script, the panel), including the token expiry answer.
7. TLS design note, Lars's decisions, then the step.
8. Day 1 Step 5 (repositories).
9. Day 1 Step 6 (switch fabric).
10. Step 9: the VPN test and the sign-in cut-over.
11. Fresh install of lab2 through the finished path, reviewing the doc as it goes. It proves the endnote too.
12. `INSTALL.md` restructure, from what that run shows.
13. Hetzner, on a real machine.

Steps 2 and 3 can run side by side. Hold the doc restructure until step 11, so it describes what works.

## 6. Also open

**Notes from the lab2 VPN and sign-in test, 2026-11-02:**

1. **Private addresses reach the firewall in the standard setup.** Done: `blockpriv` is out of the firewall template, and `network`'s update clears it, because the image carries the template and an installed site needs the change too. A VPN client on the same LAN as a private WAN used to get no handshake and no error.
2. **The identity bootstrap runs in Rest of foundation.** Done for now: Day 1's bootstrap step is a Rest of foundation wizard that runs `rest-of-foundation.sh` as one job, which also backfills `ownerOrg`. The placement panel of Step 3 is still to build, and will take this job over. The module rows stay until then.
3. **A better explanation of setting up WireGuard.** Done for the wording: the Enrol wizard and `ADMIN-VPN.md` say the file has a blank for the key, that Active is no proof, and what a dead tunnel does to names. The wider rethink of how the tunnel is set up is still open. **Found 2026-11-03:** with the tunnel's file setting `DNS = 10.0.0.1`, a Mac whose tunnel could not come up after a restart had no DNS at all, until it was set to 1.1.1.1 by hand. Rethink: send only the site's names (`.internal` and the site's domains) to 10.0.0.1, as per-domain resolvers, and leave every other lookup where it was.
4. **The identity bootstrap sets the user's password.** Done: the script asks up front at a terminal, or takes it on stdin (`--owner-password-stdin`) from the wizard, and sets it after the reconcile.

**Not yet proven on lab2:** notes 1, 2 and 4 passed unit tests and a stubbed script run only. They need a console dist built on hrossen, then a fresh identity bootstrap.

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
