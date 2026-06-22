// planes.ts — CliPlaneClient: the real PlaneClient. Each plane shells out to its
// on-PATH controller bin and maps the exit code to a PlaneStatus per the shared
// convention (rc 0 = in-sync, 2 = drift / needs-manual, 1/other = error).
//
// This is the #335 / #372 / #373 FIX: the old `zone-reconcile` hardcoded STALE
// paths under firewall/scripts/{proxmox,switch,ap}-manager (moved by S0, so it
// was broken). We call the on-PATH bins instead — and crucially we use
// `switch-controller` (the TS bin), NOT the retired `switch-manager`.
//
// Per-plane CLI contracts (from zone-reconcile):
//   opnsense : zone-manager --no-ssl-verify --zones-file <ZONES> --execute   (apply)
//              zone-manager --no-ssl-verify --zones-file <ZONES> --summary   (dry-run)
//   proxmox  : proxmox-controller reconcile [--apply]   (+ bridge-vids [--apply])
//   switch   : switch-controller reconcile [--apply]
//   ap       : ap-controller reconcile [--apply]
//
// NO firewall/scripts/ paths appear here.

import { spawnSync } from "child_process";
import { Plane, PlaneClient, PlaneResult, PlaneStatus } from "./types";

// The bin name for each plane (overridable via env for tests / relocations).
export const PLANE_BIN: Record<Plane, string> = {
  opnsense: process.env.NM_OPNSENSE_BIN ?? "zone-manager",
  proxmox: process.env.NM_PROXMOX_BIN ?? "proxmox-controller",
  switch: process.env.NM_SWITCH_BIN ?? "switch-controller",
  ap: process.env.NM_AP_BIN ?? "ap-controller",
};

export interface RunResult {
  rc: number;
  stdout: string;
  stderr: string;
  ran: boolean; // false ⇒ bin not found / failed to spawn
}

// Run a controller, streaming its output through to the operator's terminal
// (stdio: inherit) so the per-plane detail is visible, exactly as the bash
// orchestrator did. Returns the exit code.
function runStreaming(bin: string, args: string[]): RunResult {
  // The plane controllers read CONFIG_DIR (zones.json / switch+ap config live
  // there). The bash orchestrator got it from common-install-routines.sh;
  // network-manager must pass it explicitly (default the standard target path),
  // otherwise the controllers fail with "CONFIG_DIR is not set".
  const configDir =
    process.env.CONFIG_DIR ?? process.env.TAPPAAS_CONFIG ?? "/home/tappaas/config";
  const env = { ...process.env, CONFIG_DIR: configDir, TAPPAAS_CONFIG: configDir };
  const r = spawnSync(bin, args, { encoding: "utf8", stdio: "inherit", env });
  if (r.error) {
    return { rc: -1, stdout: "", stderr: r.error.message, ran: false };
  }
  return { rc: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "", ran: true };
}

// Map a controller rc → PlaneStatus per the shared convention.
//   0          → in-sync
//   2 (dry)    → drift          (reported, NOT a failure)
//   2 (apply)  → needs-manual   (switch/ap can't self-apply; not a hard error)
//   1 / other  → error
function classify(rc: number, apply: boolean, ran: boolean): PlaneStatus {
  if (!ran) return "error";
  if (rc === 0) return "in-sync";
  if (rc === 2) return apply ? "needs-manual" : "drift";
  return "error";
}

export class CliPlaneClient implements PlaneClient {
  reconcile(plane: Plane, apply: boolean, zonesFile: string): PlaneResult {
    switch (plane) {
      case "opnsense":
        return this.opnsense(apply, zonesFile);
      case "proxmox":
        return this.proxmox(apply);
      case "switch":
        return this.simpleReconcile("switch", apply);
      case "ap":
        return this.simpleReconcile("ap", apply);
    }
  }

  private opnsense(apply: boolean, zonesFile: string): PlaneResult {
    const bin = PLANE_BIN.opnsense;
    const mode = apply ? "--execute" : "--summary";
    const r = runStreaming(bin, ["--no-ssl-verify", "--zones-file", zonesFile, mode]);
    // zone-manager does not use the 0/2/1 convention — it is success/fail.
    let status: PlaneStatus;
    let message: string;
    if (!r.ran) {
      status = "error";
      message = `${bin} not on PATH or failed to spawn (${r.stderr})`;
    } else if (r.rc === 0) {
      status = "in-sync";
      message = apply ? "converged" : "reported (dry-run)";
    } else {
      status = "error";
      message = `${bin} ${mode} failed (rc=${r.rc})`;
    }
    return { plane: "opnsense", status, rc: r.rc, message };
  }

  private proxmox(apply: boolean): PlaneResult {
    const bin = PLANE_BIN.proxmox;
    // reconcile (per-VM trunks) then bridge-vids (node lan bridges). Both use
    // the 0/2/1 convention; aggregate worst.
    const args = apply ? ["--apply"] : [];
    const a = runStreaming(bin, ["reconcile", ...args]);
    if (!a.ran) {
      return {
        plane: "proxmox",
        status: "error",
        rc: a.rc,
        message: `${bin} not on PATH or failed to spawn (${a.stderr})`,
      };
    }
    const b = runStreaming(bin, ["bridge-vids", ...args]);
    const ran = a.ran && b.ran;
    // Worst rc wins (error > needs-manual/drift > in-sync).
    const worst = mergeRc(
      classify(a.rc, apply, a.ran),
      classify(b.ran ? b.rc : -1, apply, b.ran),
    );
    return {
      plane: "proxmox",
      status: worst,
      rc: a.rc !== 0 ? a.rc : b.rc,
      message: statusMessage("proxmox", worst, ran),
    };
  }

  private simpleReconcile(plane: "switch" | "ap", apply: boolean): PlaneResult {
    const bin = PLANE_BIN[plane];
    const args = apply ? ["reconcile", "--apply"] : ["reconcile"];
    const r = runStreaming(bin, args);
    const status = classify(r.rc, apply, r.ran);
    const message = r.ran
      ? statusMessage(plane, status, true)
      : `${bin} not on PATH or failed to spawn (${r.stderr})`;
    return { plane, status, rc: r.rc, message };
  }
}

function rank(s: PlaneStatus): number {
  switch (s) {
    case "in-sync":
      return 0;
    case "drift":
      return 1;
    case "needs-manual":
      return 2;
    case "skipped":
      return 0;
    case "error":
      return 3;
  }
}

function mergeRc(a: PlaneStatus, b: PlaneStatus): PlaneStatus {
  return rank(a) >= rank(b) ? a : b;
}

export function statusMessage(
  plane: Plane,
  status: PlaneStatus,
  ran: boolean,
): string {
  if (!ran) return `${plane}: controller did not run`;
  switch (status) {
    case "in-sync":
      return `${plane} in sync`;
    case "drift":
      return `${plane} reports drift (dry-run) — re-run with --apply`;
    case "needs-manual":
      return `${plane} needs manual application (see output above)`;
    case "error":
      return `${plane} reconcile error`;
    case "skipped":
      return `${plane} skipped`;
  }
}
