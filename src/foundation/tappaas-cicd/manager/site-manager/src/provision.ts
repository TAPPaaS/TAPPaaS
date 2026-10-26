// provision.ts — `site-manager node add`: the front door for standing up a
// follow-on TAPPaaS node (docs/design/node-provisioning.md N3/N4; stage-1
// hardware-validated flow, 2026-07-07).
//
// Two entry points sharing one join pipeline:
//
//   adoptNode      `node add tappaasN` — a Proxmox was already installed by
//                  hand (USB, N2 media) at the node's DESIGNATED mgmt IP
//                  (tappaasN → 10.0.0.<9+N>): verify it is that machine,
//                  then run the join pipeline over ssh.
//
//   provisionNode  `node add tappaasN --pxe` — bare machine: PXE-install it
//                  first (node-provisioner trap), then the same pipeline.
//
// The join pipeline (shared):
//   a. interactive: WAN port + pools   (asked HERE, with the node's real
//                                       NICs/disks on screen)
//   b. serve repo on :8090 + node step (install.sh --join --non-interactive;
//                                       the node moves to its standard mgmt
//                                       IP mid-run, so the ssh drop is
//                                       EXPECTED — completion is polled)
//   c. /etc/hosts fix + pvecm add      (ssh trust seeded via tappaas1)
//   d. module adopt                    (the node's pvehost record, with its
//                                       storagePools — written first, then
//                                       read back for the storage entries)
//
// All remote work is plain ssh with the cicd keys (installed by the answer
// file on PXE installs; installed by make-install-media.sh --ssh-key or by
// the operator on manual installs). Every wait has a timeout; the PXE trap
// TTL keeps the boot phase fail-safe.

import { spawnSync } from "child_process";
import { askTerminal } from "../../../lib/ts/src/exec";
import * as fs from "fs";

import { GN, YW, CL, die, info, warn } from "../../../lib/ts/src/cli";
import { mgmtDomain } from "../../../lib/ts/src/cluster";
import { clusterNode } from "../../../lib/ts/src/nodes";
import { clusterScript, defaultConfigDir } from "./config";

const SERVE_UNIT = "tappaas-repo-serve";
const SERVE_PORT = 8090; // open in the cicd firewall; free while trap is down
const REPO_DIR = "/home/tappaas/TAPPaaS";
const SERVE_ROOT = "/tmp/tappaas-serve";

export interface ProvisionOpts {
  name: string;
  bootDisk?: string; // undefined => ask on the node console at boot (PXE)
  bootFilesystem?: string; // zfs (default) | ext4 — the provisioner's --boot-filesystem
  macs: string[];
  pools: string[]; // name=layout:disk[,disk...] — created at join time
  wanPort?: string; // NIC for firewall-HA uplink; undefined => ask; "" => none
  lanPorts?: string; // #40: lan port(s), comma-separated; undefined => ask (empty = auto-detect)
  lanMode?: string; // active-backup | lacp, for two or more lan ports
  lanPrimary?: string; // active-backup: the port that carries traffic when up
  ttlSeconds: number;
  yes: boolean;
}

// ── disks named before the install ──────────────────────────────────────
//
// A kernel disk name (nvme0n1, sda) is only valid for the boot it was read on.
// Given up front with --pxe it was read on ANOTHER boot (or another OS) than
// the installer's and the join's — and NVMe names swap between boots (#729 §3:
// nvme0n1/nvme1n1 traded places, so the declared data disk was the new boot
// disk). Up front, name a disk by what does not move: its serial
// (lsblk -o NAME,SERIAL) or, for a pool, disk/by-id/<id>. Pure.
const KERNEL_DISK = /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$/;

export function isKernelDiskName(d: string): boolean {
  return KERNEL_DISK.test(d);
}

export function pxeDiskProblems(bootDisk: string | undefined, pools: string[]): string[] {
  const out: string[] = [];
  if (bootDisk && isKernelDiskName(bootDisk)) {
    out.push(`--boot-disk ${bootDisk}: a kernel name moves between boots — give the disk's SERIAL ` +
      `(lsblk -o NAME,SERIAL), or omit --boot-disk to choose it on the node console`);
  }
  for (const p of pools) {
    const disks = (p.split(":")[1] ?? "").split(",").filter((d) => d !== "");
    const bad = disks.filter(isKernelDiskName);
    if (bad.length > 0) {
      out.push(`--pool ${p}: ${bad.join(", ")} is a kernel name that moves between boots — use ` +
        `disk/by-id/<id> or the disk's serial, or omit --pool to declare pools after the install`);
    }
  }
  return out;
}

// ── plumbing ────────────────────────────────────────────────────────────

function run(cmd: string, args: string[]): { rc: number; out: string } {
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) return { rc: -1, out: r.error.message };
  return { rc: r.status ?? -1, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
}

// Streamed variant (operator watches node-provisioner/install chatter live).
function runStream(cmd: string, args: string[]): number {
  const r = spawnSync(cmd, args, { stdio: "inherit" });
  return r.status ?? -1;
}

function sshTo(host: string, remote: string, timeoutSec = 10): { rc: number; out: string } {
  return run("ssh", [
    "-o", `ConnectTimeout=${timeoutSec}`,
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    `root@${host}`,
    remote,
  ]);
}

// bootFromDiskFirst — the entry the node just booted from (its new disk) goes
// first in the UEFI boot order. A machine set up for the install with network
// boot first would otherwise PXE on every reboot (#729 §3: the first reboot after
// the install came up in PXE). Not UEFI, or no efibootmgr: say so and go on.
export const BOOT_FIRST_CMD =
  "cur=$(efibootmgr | sed -n 's/^BootCurrent: //p'); ord=$(efibootmgr | sed -n 's/^BootOrder: //p'); " +
  "[ -n \"$cur\" ] && [ -n \"$ord\" ] || exit 3; " +
  "new=$(printf '%s\\n' \"$cur\" $(echo \"$ord\" | tr , ' ') | awk '!seen[$0]++' | paste -sd, -); " +
  "[ \"$new\" = \"$ord\" ] && { echo \"unchanged $ord\"; exit 0; }; " +
  "efibootmgr -o \"$new\" >/dev/null && echo \"set $new\"";

// Proxmox installs and runs without hardware virtualisation, but then every VM
// refuses to start ("KVM virtualisation configured, but not available") — and
// HA would still move guests there. Refused before the join; reported for a
// node that is already a member.
const KVM_CMD = "test -c /dev/kvm && echo KVM || echo NOKVM";
function kvmProblem(name: string, host: string): string {
  const r = sshTo(host, KVM_CMD, 10);
  if (r.rc !== 0 || !r.out.includes("NOKVM")) return "";
  return `${name} has no hardware virtualisation (/dev/kvm is missing): no VM can run on it. ` +
    "Enable Intel VT-x / AMD-V (SVM) in its firmware setup, boot it, and run node add again";
}

function bootFromDiskFirst(host: string): void {
  const r = sshTo(host, BOOT_FIRST_CMD, 10);
  if (r.rc === 0) info(`  ${GN}✓${CL} boot order: the installed disk first (${r.out.trim()})`);
  else warn(`  could not put the installed disk first in the boot order (not UEFI?) — check the firmware boot order so a reboot does not network-boot`);
}

// The root password node-provisioner generated for <name> (the operator's, 0600;
// older ones root-owned — read through sudo then).
export const NODE_SECRETS_DIR = "/home/tappaas/.node-secrets";
const CICD_PUBKEY = "/home/tappaas/.ssh/id_ed25519.pub";

// restoreRootKey — log in as root with the node's generated password (ssh's
// askpass reads it via sudo: it never reaches a command line, the environment
// or a file of ours) and append the cicd key to root's authorized_keys.
function restoreRootKey(name: string, host: string): boolean {
  const pw = `${NODE_SECRETS_DIR}/${name}.pw`;
  if (run("test", ["-s", pw]).rc !== 0 && run("sudo", ["-n", "test", "-s", pw]).rc !== 0) {
    warn(`  ${host} refuses our key and there is no stored password (${pw}) to put it back with`);
    return false;
  }
  let key: string;
  try { key = fs.readFileSync(CICD_PUBKEY, "utf8").trim(); } catch { return false; }
  warn(`  ${host} is up but refuses our key — putting it back with the stored root password`);
  const dir = fs.mkdtempSync("/tmp/tappaas-askpass.");
  const askpass = `${dir}/askpass`;
  fs.writeFileSync(askpass, `#!/bin/sh\ncat ${pw} 2>/dev/null || exec sudo -n cat ${pw}\n`);
  fs.chmodSync(askpass, 0o700);
  try {
    const r = spawnSync("ssh", [
      "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new",
      "-o", "PreferredAuthentications=password,keyboard-interactive",
      "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
      `root@${host}`,
      'IFS= read -r k; mkdir -p -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; ' +
      'grep -qxF "$k" /root/.ssh/authorized_keys || printf "%s\\n" "$k" >> /root/.ssh/authorized_keys',
    ], {
      input: `${key}\n`, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, SSH_ASKPASS: askpass, SSH_ASKPASS_REQUIRE: "force", DISPLAY: process.env.DISPLAY ?? ":0" },
    });
    if (r.status === 0) {
      info(`  ${GN}✓${CL} key restored on ${host}`);
      return true;
    }
    warn(`  password login to ${host} failed too: ${(r.stderr ?? "").trim().split("\n").pop()}`);
    return false;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function sleep(seconds: number): void {
  spawnSync("sleep", [String(seconds)], {});
}

// Interactive prompt on the operator's terminal (sync, /dev/tty — the
// site-manager main loop is synchronous like all TS managers).
function prompt(question: string): string {
  const a = askTerminal(question);
  if (a === null) die("cannot read from the terminal (non-interactive session? pass the value as a flag)");
  return a!;
}

// Sequential step banners across whichever phases a flow runs.
function stepper(): (text: string) => void {
  let n = 0;
  return (text: string) => {
    n += 1;
    info(`\n${GN}[node add ${n}]${CL} ${text}`);
  };
}

function stdIpOf(name: string): string {
  const m = /^tappaas([1-9])$/.exec(name);
  if (!m) die(`node add: name must be tappaas1..tappaas9 (got '${name}') — the firewall reserves mgmt IPs/DNS for exactly those`);
  return `10.0.0.${9 + Number(m[1])}`;
}

function readSiteName(): string {
  try {
    const site = JSON.parse(fs.readFileSync(`${defaultConfigDir()}/site.json`, "utf8"));
    if (site.name) return String(site.name);
  } catch { /* fall through */ }
  die("cannot read site name from site.json — is this a bootstrapped cicd?");
}

// A joined node becomes a module instance: config/<name>.json, module pvehost
// (ADR-026 D4 stage 1) — the node's record, the only list of nodes there is
// (ADR-036 D6). `module adopt` does it — the same path the cluster module's
// update uses for nodes that joined before this existed — recording the pools
// named with --storage-pools, else the zpools on the node. A failure is a
// warning, never a failed join: the node is in the cluster already, and the
// next cluster update registers it anyway.
function registerNode(name: string, pools: string[]): void {
  const addr = `${name}.${mgmtDomain()}`;
  // A --pxe pool is name=layout:disk; its record keeps the name.
  const names = [...new Set(pools.map((p) => p.split("=")[0]).filter((p) => /^tank/.test(p)))];
  const args = [addr, "--wait", "0", ...(names.length ? ["--set", `storagePools=${JSON.stringify(names)}`] : [])];
  if (runStream("adopt-module.sh", args) !== 0) {
    warn(`  ${name} is not registered as a module yet — run ${YW}module-manager module adopt ${addr}${CL}, ` +
         `or let the next cluster update do it`);
    return;
  }
  // #40: the lan uplink the node step built becomes its declaration, so a
  // later drift — or a rebuild under this name — has something to go by.
  const lu = clusterScript("lan-uplink.sh");
  if (!lu || runStream(lu, ["capture", name]) !== 0) {
    warn(`  ${name}'s lan uplink is not recorded yet — the next cluster update records it`);
  }
}

// ── adopt: a Proxmox already runs at the designated IP ─────────────────

export function adoptNode(o: ProvisionOpts): void {
  const stdIp = stdIpOf(o.name);
  const step = stepper();

  step(`probing for an existing Proxmox at ${stdIp} (designated IP of '${o.name}')`);
  run("ssh-keygen", ["-R", stdIp]);
  const probe = sshTo(stdIp, "hostname -s; pveversion 2>/dev/null | head -1", 8);
  if (probe.rc !== 0) {
    die(`no ssh at root@${stdIp} — for a bare machine use 'node add ${o.name} --pxe'; ` +
        `for a manual install make sure it is at ${stdIp} with the cicd key authorized`);
  }
  const [host, pve] = probe.out.trim().split("\n");
  if (host?.trim() !== o.name) die(`the machine at ${stdIp} calls itself '${host?.trim()}' — expected '${o.name}'; not touching it`);
  if (!pve || !pve.includes("pve-manager")) die(`${o.name} at ${stdIp} does not look like a Proxmox node (pveversion failed)`);
  info(`  ${GN}✓${CL} found ${o.name}: ${pve.trim()}`);

  const clustered = sshTo(stdIp, "pvecm status >/dev/null 2>&1 && echo IN-CLUSTER || echo STANDALONE");
  if (clustered.out.includes("IN-CLUSTER")) {
    info(`  ${o.name} is already in a cluster — skipping straight to capture`);
    const noKvm = kvmProblem(o.name, stdIp);
    if (noKvm) warn(`  ${noKvm}`);
    step("registering the node as a pvehost module instance (ADR-026 D4, #665)");
    registerNode(o.name, o.pools);
    return;
  }

  joinAndCapture(o, stdIp, stdIp, step);
}

// ── PXE: bare machine, install first ────────────────────────────────────

export function provisionNode(o: ProvisionOpts): void {
  const stdIp = stdIpOf(o.name);
  const provisionDir = `${defaultConfigDir()}/provision`;
  const step = stepper();
  const diskProblems = pxeDiskProblems(o.bootDisk, o.pools);
  if (diskProblems.length > 0) die(diskProblems.join("\n"));

  // register --------------------------------------------------------------
  step(`register '${o.name}' (standard mgmt IP ${stdIp})`);
  // A consumed marker from a PREVIOUS provisioning of this name would make
  // the answer-wait fire instantly — clear it before arming.
  fs.rmSync(`${provisionDir}/${o.name}.json.consumed`, { force: true });
  const regArgs = ["register", o.name];
  if (o.bootDisk) regArgs.push("--boot-disk", o.bootDisk);
  if (o.bootFilesystem) regArgs.push("--boot-filesystem", o.bootFilesystem);
  for (const mac of o.macs) regArgs.push("--mac", mac);
  if (runStream("node-provisioner", regArgs) !== 0) die("node-provisioner register failed");

  // arm the trap ------------------------------------------------------------
  step(`arm the PXE trap (TTL ${o.ttlSeconds}s)`);
  if (runStream("sudo", ["node-provisioner", "enable", "--ttl", String(o.ttlSeconds)]) !== 0) {
    die("node-provisioner enable failed");
  }

  let installIp = stdIp;
  try {
    // wait for the answer to be served ---------------------------------------
    step("PXE-boot the machine now (UEFI network boot, e.g. F11)");
    if (!o.bootDisk) {
      info(`  ${YW}the node's console will ask ONE question: the boot disk${CL}`);
    }
    info(`  waiting for the installer to fetch its answer (Ctrl-C aborts; trap auto-off in ${o.ttlSeconds}s)...`);
    const consumed = `${provisionDir}/${o.name}.json.consumed`;
    const answerDeadline = Date.now() + o.ttlSeconds * 1000;
    while (!fs.existsSync(consumed)) {
      if (Date.now() > answerDeadline) die("timed out waiting for the node to fetch its answer — trap TTL reached");
      sleep(5);
    }
    try {
      const rec = JSON.parse(fs.readFileSync(consumed, "utf8"));
      if (rec.install_ip) installIp = String(rec.install_ip);
    } catch { /* fall back to the standard IP (MAC-pinned reservation) */ }
    info(`  ${GN}✓${CL} answer served — installing; node will boot at ${installIp} (installer bakes its lease statically)`);

    // disarm ------------------------------------------------------------------
    step("install underway — disarming the PXE trap");
    runStream("sudo", ["node-provisioner", "disable"]);

    // wait for the installed node ---------------------------------------------
    step(`waiting for ssh at ${installIp} (install + reboot, typically 5-10 min)`);
    run("ssh-keygen", ["-R", installIp]);
    const sshDeadline = Date.now() + 30 * 60 * 1000;
    let refused = 0;
    let keyTries = 0;
    for (;;) {
      const r = sshTo(installIp, "hostname", 5);
      if (r.rc === 0 && r.out.includes(o.name)) break;
      // Up, but our key is not accepted: the answer's root-ssh-keys did not
      // survive (#729 §3: a reset during first boot left authorized_keys at 0
      // bytes). A few in a row — not one during sshd's start — and the root
      // password the provisioner generated puts the key back.
      if (r.rc !== 0 && /Permission denied/.test(r.out) && ++refused >= 3 && keyTries < 2) {
        keyTries++;
        refused = 0;
        if (restoreRootKey(o.name, installIp)) continue;
      }
      if (r.rc === 0) die(`a machine at ${installIp} answers but claims '${r.out.trim()}' — expected '${o.name}'; not touching it`);
      if (Date.now() > sshDeadline) die(`timed out waiting for ssh at ${installIp} — check the node's console`);
      sleep(15);
    }
    info(`  ${GN}✓${CL} ${o.name} is up at ${installIp}`);
    bootFromDiskFirst(installIp);

    joinAndCapture(o, installIp, stdIp, step);
  } finally {
    // Never leave a network-boot trap armed on ANY exit path.
    run("sudo", ["node-provisioner", "disable"]);
  }
}

// ── the shared join pipeline ────────────────────────────────────────────

function joinAndCapture(
  o: ProvisionOpts,
  nodeIp: string,
  stdIp: string,
  step: (text: string) => void,
): void {
  const domain = mgmtDomain();
  const siteName = readSiteName();

  const noKvm = kvmProblem(o.name, nodeIp);
  if (noKvm) die(noKvm);

  // gather the join-time answers (with the node's real hardware) ----------
  step("join-time configuration");
  let wanPort = o.wanPort;
  if (wanPort === undefined) {
    const nics = sshTo(nodeIp, "ip -br link | grep -v '^lo'").out.trimEnd();
    info(`  NICs on ${o.name}:\n${nics.replace(/^/gm, "    ")}`);
    const nicNames = new Set(
      nics.split("\n").map((l) => l.trim().split(/\s+/)[0]).filter(Boolean));
    for (;;) {
      wanPort = prompt("  WAN NIC for firewall-HA uplink (empty = none): ");
      if (!wanPort || nicNames.has(wanPort)) break;
      // Validate against the node's REAL NICs: a typo here aborts
      // config-network deep inside the node step (stage-2 finding:
      // 'emp98s0' for enp98s0 cost a full re-run).
      warn(`  '${wanPort}' is not a NIC on ${o.name} — pick one from the list above (or empty for none)`);
    }
  }
  // #40: the lan port(s). One port is what config-network.sh auto-detects; two
  // or more bond under lan, so a port or switch failure does not take the
  // node's management, corosync and guests down with it.
  // Asked only where the WAN port is asked too: a scripted add (--wan-port,
  // --yes) keeps today's auto-detected single port.
  let lanPorts = o.lanPorts;
  if (lanPorts === undefined && o.wanPort === undefined && !o.yes) {
    const nics = sshTo(nodeIp,
      "for d in /sys/class/net/*; do [ -e $d/device ] || continue; n=${d##*/}; " +
      "printf '%-16s %s  %s  %s\\n' $n $(cat $d/address) $(cat $d/operstate) \"$(cat $d/speed 2>/dev/null || echo -)Mb/s\"; done").out.trimEnd();
    info(`  physical ports on ${o.name}:\n${nics.replace(/^/gm, "    ")}`);
    const nicNames = new Set(nics.split("\n").map((l) => l.trim().split(/\s+/)[0]).filter(Boolean));
    for (;;) {
      lanPorts = prompt("  LAN port(s), comma-separated — two to two switches for a redundant uplink (empty = auto-detect one): ");
      const bad = (lanPorts ?? "").split(",").map((p) => p.trim()).filter((p) => p && !nicNames.has(p));
      if (bad.length === 0) break;
      warn(`  ${bad.join(", ")} not a physical port on ${o.name} — pick from the list above`);
    }
    if (lanPorts && lanPorts.includes(",") && o.lanMode === undefined) {
      const m = prompt("  bond mode — active-backup (any switches, any speeds) or lacp (equal speeds, switch-side LAG) [active-backup]: ");
      o.lanMode = m || "active-backup";
    }
  }
  if (lanPorts && wanPort && lanPorts.split(",").map((p) => p.trim()).includes(wanPort)) {
    die(`${wanPort} cannot be both the WAN port and a LAN port`);
  }
  const pools = [...o.pools];
  if (pools.length === 0) {
    const disks = sshTo(nodeIp, "lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN | grep -v '^sr\\|^loop\\|^zd'").out.trimEnd();
    info(`  disks on ${o.name} (boot disk is protected automatically):\n${disks.replace(/^/gm, "    ")}`);
    info("  declare data pools as name=layout:disk[,disk...] — e.g. tanka1=single:nvme0n1 (empty line to finish)");
    for (;;) {
      const spec = prompt(`  pool ${pools.length + 1}> `);
      if (!spec) break;
      pools.push(spec);
    }
  }
  if (pools.length === 0) warn("no data pools declared — the platform layer expects tanka1; declare later via config-storage.sh");

  // serve the repo + run the node step -------------------------------------
  step(`node step on ${o.name} (repo served from cicd:${SERVE_PORT}, branch state = last commit)`);
  const branch = run("git", ["-C", REPO_DIR, "rev-parse", "--abbrev-ref", "HEAD"]).out.trim() || "main";
  run("rm", ["-rf", SERVE_ROOT]);
  fs.mkdirSync(`${SERVE_ROOT}/${branch}`, { recursive: true });
  if (run("bash", ["-c", `git -C ${REPO_DIR} archive ${branch} | tar -x -C ${SERVE_ROOT}/${branch}`]).rc !== 0) {
    die(`git archive ${branch} failed — is ${REPO_DIR} a clean checkout?`);
  }
  run("sudo", ["systemctl", "stop", SERVE_UNIT]);
  run("sudo", ["systemctl", "reset-failed", SERVE_UNIT]);
  const py = run("bash", ["-c", "command -v python3"]).out.trim();
  if (run("sudo", ["systemd-run", "--collect", `--unit=${SERVE_UNIT}`, `--working-directory=${SERVE_ROOT}`, py, "-m", "http.server", String(SERVE_PORT)]).rc !== 0) {
    die("could not start the transient repo server");
  }
  try {
    const cicdIp = run("bash", ["-c", `ip -4 route get 10.0.0.1 | grep -oE 'src [0-9.]+' | cut -d' ' -f2`]).out.trim() || "10.0.0.183";
    const repoUrl = `http://${cicdIp}:${SERVE_PORT}/`;
    const joinArgs = [`--join`, `--non-interactive`, `--name`, siteName];
    if (wanPort) joinArgs.push("--wan-port", wanPort);
    if (lanPorts) joinArgs.push("--lan-port", lanPorts.replace(/\s+/g, ""));
    if (o.lanMode) joinArgs.push("--lan-mode", o.lanMode);
    if (o.lanPrimary) joinArgs.push("--lan-primary", o.lanPrimary);
    for (const p of pools) joinArgs.push("--pool", p);
    const nodeCmd =
      `cd /root && curl -fsSO ${repoUrl}${branch}/src/foundation/install.sh && chmod +x install.sh && ` +
      `(./install.sh ${repoUrl} ${branch} ${joinArgs.join(" ")} > /root/tappaas-install.log 2>&1 &) && echo LAUNCHED`;
    const launch = sshTo(nodeIp, nodeCmd, 15);
    if (!launch.out.includes("LAUNCHED")) die(`could not launch the node step on ${nodeIp}: ${launch.out.trim()}`);
    info(`  node step launched (log: /root/tappaas-install.log on the node)`);
    if (nodeIp !== stdIp) info(`  the node moves to ${stdIp} mid-run — waiting for completion there...`);

    run("ssh-keygen", ["-R", stdIp]);
    run("ssh-keygen", ["-R", `${o.name}.${domain}`]);
    const joinDeadline = Date.now() + 30 * 60 * 1000;
    let completedAt = stdIp;
    for (;;) {
      // A wide tail: the success marker sits ABOVE a multi-line epilogue
      // (a 3-line window watched the epilogue forever — e2e-test finding).
      let host = stdIp;
      let r = sshTo(stdIp, "tail -50 /root/tappaas-install.log 2>/dev/null", 5);
      if (r.rc !== 0 && nodeIp !== stdIp) {
        // The IP has not moved yet — a failure BEFORE the network reshape
        // strands the log at the install IP; watch it there too so we die
        // fast instead of timing out (e2e-test finding).
        host = nodeIp;
        r = sshTo(nodeIp, "tail -50 /root/tappaas-install.log 2>/dev/null", 5);
      }
      if (r.rc === 0 && /Node step complete/.test(r.out)) { completedAt = host; break; }
      if (r.rc === 0 && /✗/.test(r.out)) die(`node step FAILED on ${o.name}:\n${r.out.split("\n").slice(-8).join("\n")} — full log: ssh root@${stdIp} (or ${nodeIp}) cat /root/tappaas-install.log`);
      if (Date.now() > joinDeadline) die(`timed out waiting for the node step — check ssh root@${stdIp} tail /root/tappaas-install.log (or at ${nodeIp} if the IP never moved)`);
      sleep(15);
    }
    if (completedAt !== stdIp) {
      // Completion seen at the INSTALL ip = the step finished but the node
      // never moved to its standard IP — the network reshape failed inside
      // the node step (stage-2 finding: a WAN-port typo aborted
      // config-network and the step still reported complete).
      die(`node step completed but ${o.name} never appeared at ${stdIp} — ` +
          `the network reshape failed (check: ssh root@${completedAt} ` +
          `grep network /root/tappaas-install.log). Fix on the node with ` +
          `'~/tappaas/config-network.sh --non-interactive', then re-run ` +
          `'site-manager node add ${o.name}'.`);
    }
    info(`  ${GN}✓${CL} node step complete — ${o.name} is at its standard IP ${stdIp}`);

    // cluster join ------------------------------------------------------------
    step(`joining the Proxmox cluster via tappaas1.${domain}`);
    // The installer bakes the INSTALL ip into /etc/hosts; pvecm resolves
    // the local node from there and refuses a mismatch (stage-1 finding).
    // Normalize UNCONDITIONALLY on the hostname's line: in adopt mode
    // nodeIp === stdIp yet /etc/hosts can still carry a stale install IP
    // (bit the MS-S1 Max join — stage-2 finding).
    sshTo(stdIp, `sed -i 's/^[0-9.]\\+\\(\\s\\+${o.name}\\.\\)/${stdIp}\\1/' /etc/hosts`);
    // Seed node→tappaas1 root ssh trust (pvecm add is password-interactive
    // without it): reuse the node's keypair, authorize it on tappaas1.
    sshTo(stdIp, "[ -f /root/.ssh/id_rsa.pub ] || ssh-keygen -t rsa -b 2048 -N '' -f /root/.ssh/id_rsa >/dev/null");
    const pub = sshTo(stdIp, "cat /root/.ssh/id_rsa.pub").out.trim();
    if (!pub.startsWith("ssh-")) die(`could not read ${o.name}'s root public key`);
    const auth = sshTo(`tappaas1.${domain}`, `grep -qF '${pub.split(" ")[1].slice(0, 40)}' /root/.ssh/authorized_keys || echo '${pub}' >> /root/.ssh/authorized_keys; echo AUTHORIZED`);
    if (!auth.out.includes("AUTHORIZED")) die(`could not authorize ${o.name} on tappaas1: ${auth.out.trim()}`);
    const joinCmd =
      `ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@tappaas1.${domain} true && ` +
      `pvecm add tappaas1.${domain} --link0 ${stdIp} --use_ssh`;
    const joined = sshTo(stdIp, joinCmd, 15);
    if (!/successfully added node/.test(joined.out) && !/already a member/.test(joined.out)) {
      die(`pvecm add failed on ${o.name}:\n${joined.out.trim()}`);
    }
    info(`  ${GN}✓${CL} ${o.name} joined the cluster`);
    // HA must not place guests here until its pools are storage the cluster
    // knows: #729 §3 — failback migrated a guest onto the rejoined node a
    // minute after the join, before its pool existed (four aborts, then a race
    // won). Maintenance until the storage step below; on any failure it stays.
    const maint = sshTo(`tappaas1.${domain}`, `ha-manager crm-command node-maintenance enable ${o.name} && echo MAINT`);
    if (maint.out.includes("MAINT")) info(`  ${o.name} held in HA maintenance until its storage is registered`);
    else warn(`  could not put ${o.name} in HA maintenance — HA may move guests onto it before its pools are registered`);
    // Cluster ssh/cert plumbing for the NEW member (also refreshes the
    // shared known_hosts — a REUSED node name otherwise leaves stale host
    // keys that silently break inter-node root ssh; stage-2 finding).
    sshTo(stdIp, "pvecm updatecerts >/dev/null 2>&1 || true");
  } finally {
    run("sudo", ["systemctl", "stop", SERVE_UNIT]);
  }

  // capture ------------------------------------------------------------------
  // The pvehost record first: it is the node, and it carries the pools the
  // storage registration below reads.
  step("registering the node as a pvehost module instance (ADR-026 D4, #665)");
  registerNode(o.name, pools);

  // storage registration ------------------------------------------------------
  // The node's pools were CREATED pre-join (config-storage in the node
  // step), but joining replaced /etc/pve — dropping this node from every
  // pool's cluster storage nodes-list, which pvesm shows as 'disabled'
  // (stage-2 finding: tappaas2 AND the earlier tappaas4 were silently
  // missing). Re-add the node per its CAPTURED pools (its pvehost record,
  // written above from the live zpools).
  step("registering the node in its pools' cluster storage entries");
  const capturedPools = clusterNode(defaultConfigDir(), o.name)?.storagePools ?? [];
  if (capturedPools.length === 0) {
    info("  no pools captured for this node — nothing to register");
  }
  let storageOk = capturedPools.length > 0;
  for (const pool of capturedPools) {
    const r = sshTo(`tappaas1.${domain}`,
      `cur=$(sed -n "/zfspool: ${pool}\$/,/^\$/s/^\\s*nodes //p" /etc/pve/storage.cfg | head -1); ` +
      `case ",\${cur}," in *,${o.name},*) echo "already" ;; ` +
      `*) pvesm set ${pool} --nodes "\${cur:+\${cur},}${o.name}" && echo "added" ;; esac`);
    if (/added/.test(r.out)) info(`  ${GN}✓${CL} ${o.name} added to storage '${pool}' nodes`);
    else if (/already/.test(r.out)) info(`  storage '${pool}' already lists ${o.name}`);
    else {
      storageOk = false;
      warn(`  could not register ${o.name} on storage '${pool}': ${r.out.trim()} — fix with: pvesm set ${pool} --nodes <list>`);
    }
  }
  const lift = `ha-manager crm-command node-maintenance disable ${o.name}`;
  if (storageOk && sshTo(`tappaas1.${domain}`, `${lift} && echo LIFTED`).out.includes("LIFTED")) {
    info(`  ${GN}✓${CL} HA maintenance lifted — ${o.name} takes guests`);
  } else {
    warn(`  ${o.name} stays in HA maintenance (no guests placed on it) until its pools are registered — then: ` +
         `ssh root@tappaas1.${domain} ${lift}`);
  }

  // backup client on the new node ------------------------------------------
  // ADR-012 §2.4 (#382): the per-node proxmox-backup-client is an idempotent
  // reconcile keyed on CURRENT cluster membership, and the backup module's
  // update runs it. A node that joins after backup was installed therefore has
  // no client until something triggers that reconcile — which is why this is an
  // automatic step here and NOT a line in a runbook: a missed manual step means
  // every VM on the new node silently has no backup.
  //
  // A failure is a warning, never a failed join: the node IS in the cluster by
  // now, and the remedy is one idempotent command the operator can re-run.
  step("reconciling the backup client onto the new node (ADR-012 §2.4)");
  if (runStream("module-manager", ["modify", "backup", "--silent"]) !== 0) {
    warn(`  could not reconcile the backup client onto ${o.name} — ` +
         `run ${YW}module-manager modify backup${CL} once it is reachable, ` +
         `or its VMs will not be backed up`);
  }

  // key-only SSH now, not at the next sweep (#19; #729 §3 — the rejoined node
  // took root passwords over ssh for hours). Same drop-in and guard as the
  // cluster update's Step 5: fed over the key login, so it cannot lock us out.
  step("key-only SSH on the new node (#19)");
  const keyOnly = `${REPO_DIR}/src/foundation/tappaas-cicd/scripts/ssh-key-only.sh`;
  const hard = fs.existsSync(keyOnly)
    ? spawnSync("ssh", ["-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "ConnectTimeout=10",
        `root@${o.name}.${domain}`, "bash -s -- apply"], { input: fs.readFileSync(keyOnly, "utf8"), encoding: "utf8" })
    : null;
  if (hard?.status === 0) info(`  ${GN}✓${CL} ${o.name} refuses password logins over ssh (console and GUI keep the root password)`);
  else warn(`  key-only SSH not enforced on ${o.name} yet — the next ${YW}site-manager update${CL} does it (cluster Step 5)`);

  info(`\n${GN}✓ node '${o.name}' is in the cluster and captured${CL}`);
  info(`  next: run ${YW}site-manager update${CL} to fold HA + replication over the new topology.`);
  twoNodeWarning(nodeIp);
}

// Two nodes are two votes and a quorum of two: when one is down the survivor is
// not quorate, and HA fences it — the whole site, the firewall with it (#835).
// A third vote (a QDevice) is what keeps a two-node cluster running.
export function quorumAdvice(expectedVotes: number, qdevice: boolean): string {
  if (expectedVotes !== 2 || qdevice) return "";
  return "the cluster has two votes: when one node is down the other loses quorum and HA fences it, " +
    "firewall included. Add a third vote — site-manager node qdevice add <host> on a small always-on " +
    "Debian machine — or a third node";
}

function twoNodeWarning(nodeIp: string): void {
  const r = sshTo(nodeIp, "pvecm status", 10);
  if (r.rc !== 0) return;
  const votes = Number(/Expected votes:\s*(\d+)/.exec(r.out)?.[1] ?? "0");
  const advice = quorumAdvice(votes, /Qdevice/i.test(r.out));
  if (advice) warn(`  ${advice}`);
}
