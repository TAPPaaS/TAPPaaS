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
//   d. node reconcile --apply          (site.json capture)
//
// All remote work is plain ssh with the cicd keys (installed by the answer
// file on PXE installs; installed by make-install-media.sh --ssh-key or by
// the operator on manual installs). Every wait has a timeout; the PXE trap
// TTL keeps the boot phase fail-safe.

import { spawnSync } from "child_process";
import * as fs from "fs";

import { GN, YW, CL, die, info, warn } from "../../../lib/ts/src/cli";
import { mgmtDomain } from "../../../lib/ts/src/cluster";
import { defaultConfigDir } from "./config";

const SERVE_UNIT = "tappaas-repo-serve";
const SERVE_PORT = 8090; // open in the cicd firewall; free while trap is down
const REPO_DIR = "/home/tappaas/TAPPaaS";
const SERVE_ROOT = "/tmp/tappaas-serve";

export interface ProvisionOpts {
  name: string;
  bootDisk?: string; // undefined => ask on the node console at boot (PXE)
  macs: string[];
  pools: string[]; // name=layout:disk[,disk...] — created at join time
  wanPort?: string; // NIC for firewall-HA uplink; undefined => ask; "" => none
  ttlSeconds: number;
  yes: boolean;
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

function sleep(seconds: number): void {
  spawnSync("sleep", [String(seconds)], {});
}

// Interactive prompt on the operator's terminal (sync, /dev/tty — the
// site-manager main loop is synchronous like all TS managers).
function prompt(question: string): string {
  const r = spawnSync(
    "bash",
    ["-c", `printf '%s' "$1" > /dev/tty; IFS= read -r v < /dev/tty; printf '%s' "$v"`, "--", question],
    { encoding: "utf8" },
  );
  if (r.status !== 0) die("cannot read from the terminal (non-interactive session? pass the value as a flag)");
  return (r.stdout ?? "").trim();
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
    step("capturing the node in site.json (node reconcile --apply)");
    runStream("site-manager", ["node", "reconcile", "--apply"]);
    return;
  }

  joinAndCapture(o, stdIp, stdIp, step);
}

// ── PXE: bare machine, install first ────────────────────────────────────

export function provisionNode(o: ProvisionOpts): void {
  const stdIp = stdIpOf(o.name);
  const provisionDir = `${defaultConfigDir()}/provision`;
  const step = stepper();

  // register --------------------------------------------------------------
  step(`register '${o.name}' (standard mgmt IP ${stdIp})`);
  // A consumed marker from a PREVIOUS provisioning of this name would make
  // the answer-wait fire instantly — clear it before arming.
  fs.rmSync(`${provisionDir}/${o.name}.json.consumed`, { force: true });
  const regArgs = ["register", o.name];
  if (o.bootDisk) regArgs.push("--boot-disk", o.bootDisk);
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
    for (;;) {
      const r = sshTo(installIp, "hostname", 5);
      if (r.rc === 0 && r.out.includes(o.name)) break;
      if (r.rc === 0) die(`a machine at ${installIp} answers but claims '${r.out.trim()}' — expected '${o.name}'; not touching it`);
      if (Date.now() > sshDeadline) die(`timed out waiting for ssh at ${installIp} — check the node's console`);
      sleep(15);
    }
    info(`  ${GN}✓${CL} ${o.name} is up at ${installIp}`);

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
  const pools = [...o.pools];
  if (pools.length === 0) {
    const disks = sshTo(nodeIp, "lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v '^sr\\|^loop\\|^zd'").out.trimEnd();
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
    // Cluster ssh/cert plumbing for the NEW member (also refreshes the
    // shared known_hosts — a REUSED node name otherwise leaves stale host
    // keys that silently break inter-node root ssh; stage-2 finding).
    sshTo(stdIp, "pvecm updatecerts >/dev/null 2>&1 || true");
  } finally {
    run("sudo", ["systemctl", "stop", SERVE_UNIT]);
  }

  // capture ------------------------------------------------------------------
  step("capturing the node in site.json (node reconcile --apply)");
  runStream("site-manager", ["node", "reconcile", "--apply"]);

  // storage registration ------------------------------------------------------
  // The node's pools were CREATED pre-join (config-storage in the node
  // step), but joining replaced /etc/pve — dropping this node from every
  // pool's cluster storage nodes-list, which pvesm shows as 'disabled'
  // (stage-2 finding: tappaas2 AND the earlier tappaas4 were silently
  // missing). Re-add the node per its CAPTURED pools (site.json, which the
  // reconcile above just refreshed from the live zpools).
  step("registering the node in its pools' cluster storage entries");
  let capturedPools: string[] = [];
  try {
    const site = JSON.parse(fs.readFileSync(`${defaultConfigDir()}/site.json`, "utf8"));
    const entry = (site.hardware?.nodes ?? []).find((n: { name: string }) => n.name === o.name);
    capturedPools = entry?.storagePools ?? [];
  } catch { /* leave empty */ }
  if (capturedPools.length === 0) {
    info("  no pools captured for this node — nothing to register");
  }
  for (const pool of capturedPools) {
    const r = sshTo(`tappaas1.${domain}`,
      `cur=$(sed -n "/zfspool: ${pool}\$/,/^\$/s/^\\s*nodes //p" /etc/pve/storage.cfg | head -1); ` +
      `case ",\${cur}," in *,${o.name},*) echo "already" ;; ` +
      `*) pvesm set ${pool} --nodes "\${cur:+\${cur},}${o.name}" && echo "added" ;; esac`);
    if (/added/.test(r.out)) info(`  ${GN}✓${CL} ${o.name} added to storage '${pool}' nodes`);
    else if (/already/.test(r.out)) info(`  storage '${pool}' already lists ${o.name}`);
    else warn(`  could not register ${o.name} on storage '${pool}': ${r.out.trim()} — fix with: pvesm set ${pool} --nodes <list>`);
  }

  info(`\n${GN}✓ node '${o.name}' is in the cluster and captured${CL}`);
  info(`  next: run ${YW}update-tappaas --force${CL} to fold HA + replication over the new topology.`);
}
