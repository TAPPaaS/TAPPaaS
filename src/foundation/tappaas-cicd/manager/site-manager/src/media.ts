// media.ts — `site-manager node media`: the boot medium a new node installs
// from, on the mothership, and `node media prepare`, which builds it.
//
//   node media [--json]            what is staged, and what prepare would run
//   node media prepare [--force]   stage the netboot assets and the stick image
//
// The medium is one tree, /var/lib/tappaas-pxe (node-provisioner's): the
// kernel, initrd and boot script a machine network-boots (PXE), and beside
// them the installer stick image, tappaas-usb.iso, for a machine that cannot.
// Both are built from one ISO, the Proxmox installer prepared to fetch its
// answer from the mothership (scripts/prepare-netboot.sh makes that ISO on a
// cluster node — the assistant needs a PVE box — and keeps it at
// /home/tappaas/pve-tappaas-netboot.iso). The cicd install stages it once;
// this verb is for when that failed, when the staged assets predate this
// version's installer hook (node add would re-stage them on its own, but a
// stick is wanted before node add runs), or for a new Proxmox version.

import { spawnSync } from "child_process";

import { GN, YW, CL, die, info, warn } from "../../../lib/ts/src/cli";

// node-provisioner assets --json.
export interface MediaStatus {
  directory: string;
  staged: boolean; // linux26, initrd and boot.ipxe are there
  current: boolean; // and carry this version's installer hook
  source: string; // the prepared ISO they came from (or would come from)
  sourcePresent: boolean;
  stickImage: { path: string; present: boolean; size: number; modified: string | null };
  xorriso: boolean; // the tool that builds the stick image is installed
}

// What the console shows and what prepare decides from.
export interface MediaReport extends MediaStatus {
  ready: boolean; // staged, current, with the stick image: nothing to prepare
  problems: string[]; // why not, in the operator's words
  prepare: { argv: string[]; minutes: string } | null; // what prepare would run; null when it could do nothing
}

export const PREPARE_NETBOOT = "prepare-netboot.sh";

export function mediaProblems(s: MediaStatus): string[] {
  const p: string[] = [];
  if (!s.staged) p.push(`the netboot assets are not staged (${s.directory})`);
  else if (!s.current) p.push("the netboot assets predate this version's installer hook");
  if (!s.stickImage.present) p.push(`the installer stick image is missing (${s.stickImage.path})`);
  if (!s.xorriso) p.push("xorriso is not installed on the mothership: the stick image cannot be built until an OS update brings it");
  return p;
}

// The command prepare runs, pure: the whole script when nothing usable is
// staged (it fetches the ISO, prepares it on a node, copies it here and
// stages), node-provisioner prepare alone from the ISO already here (a few
// minutes, no download), --force the whole script again.
export function prepareArgv(s: MediaStatus, force: boolean): { argv: string[]; minutes: string } | null {
  const whole = { argv: [PREPARE_NETBOOT, "--force"], minutes: "ten minutes or more: the Proxmox ISO is fetched on a node, prepared there and copied here, then staged" };
  if (force) return whole;
  if (s.staged && s.current && s.stickImage.present) return null;
  if (s.sourcePresent) return { argv: ["sudo", "node-provisioner", "prepare", "--iso", s.source], minutes: "a few minutes: staged again from the prepared ISO already here" };
  // prepare-netboot.sh steps aside when assets are staged: --force when they
  // are there but stale and their ISO is gone.
  return s.staged ? whole : { argv: [PREPARE_NETBOOT], minutes: whole.minutes };
}

export function mediaReport(s: MediaStatus): MediaReport {
  const problems = mediaProblems(s);
  const prepare = prepareArgv(s, false);
  return { ...s, ready: problems.length === 0, problems, prepare: prepare && (s.xorriso || !s.staged || !s.current) ? prepare : null };
}

export function readMediaStatus(): MediaStatus {
  const r = spawnSync("node-provisioner", ["assets", "--json"], { encoding: "utf8" });
  if (r.error) die(`node media: node-provisioner could not be run: ${r.error.message}`);
  if (r.status !== 0) die(`node media: node-provisioner assets --json failed (rc ${r.status}): ${(r.stderr ?? "").trim()}`);
  try {
    const s = JSON.parse(r.stdout ?? "") as MediaStatus;
    if (typeof s.staged !== "boolean" || !s.stickImage) throw new Error("no staged/stickImage");
    return s;
  } catch (e) {
    die(`node media: node-provisioner assets --json gave no status: ${(e as Error).message}`);
  }
}

export function humanGb(bytes: number): string {
  return `${(bytes / 1e9).toFixed(1)} GB`;
}

export function listMedia(json: boolean): void {
  const m = mediaReport(readMediaStatus());
  if (json) {
    process.stdout.write(JSON.stringify(m) + "\n");
    return;
  }
  info(`netboot assets (${m.directory}): ${m.staged ? (m.current ? `${GN}staged${CL}` : `${YW}staged, from before this version${CL}`) : `${YW}not staged${CL}`}`);
  info(`installer stick image: ${m.stickImage.present ? `${GN}${m.stickImage.path}${CL} (${humanGb(m.stickImage.size)}, ${m.stickImage.modified})` : `${YW}missing${CL}`}`);
  info(`prepared ISO: ${m.source}${m.sourcePresent ? "" : ` ${YW}(missing)${CL}`}`);
  for (const p of m.problems) warn(p);
  if (m.ready) info("the boot medium is ready: a machine network-boots, or boots the stick node usb write makes");
  else if (m.prepare) info(`node media prepare would run: ${m.prepare.argv.join(" ")} (${m.prepare.minutes})`);
}

export function prepareMedia(force: boolean, run: (argv: string[]) => number = runStream): void {
  const s = readMediaStatus();
  const step = prepareArgv(s, force);
  if (!step) {
    info("the boot medium is ready: nothing to prepare (--force stages it again, for a new Proxmox version)");
    return;
  }
  if (!s.xorriso) {
    if (s.staged && s.current) die("node media prepare: the netboot assets are current and only the stick image is missing, which needs xorriso — not installed on the mothership until an OS update brings it; nothing to do here");
    warn("xorriso is not installed on the mothership: the netboot assets are staged, but no stick image until an OS update brings it");
  }
  info(`running: ${step.argv.join(" ")} (${step.minutes})`);
  const rc = run(step.argv);
  if (rc !== 0) die(`node media prepare: ${step.argv[0]} failed (rc ${rc})`);
  const after = mediaReport(readMediaStatus());
  for (const p of after.problems) warn(p);
  if (after.ready) info(`${GN}the boot medium is ready${CL}`);
}

function runStream(argv: string[]): number {
  const r = spawnSync(argv[0], argv.slice(1), { stdio: "inherit" });
  if (r.error) return -1;
  return r.status ?? -1;
}
