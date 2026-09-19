// placement-reset.ts — `backup-manager placement reset` / `finish-reset` (ADR-012 §2.3, #607).
//
// `external` is sticky, and this is its one deliberate door. The work on the
// cluster (renaming the old storage entry, rewriting backup.json) is the
// module's own bash (`backup-manage.sh reset-external`), as `use-external` is;
// this verb confirms, then runs the steps in the order that never leaves the
// site without a working backup target for longer than it must:
//
//   1. reset-external   the old PBS's storage → <name>_former (still restorable),
//                       placementState → shim, formerExternal recorded. Refused
//                       with nothing changed when there is no tankc pool.
//   2. the pull peer    pull-<peer>.json for the old PBS (config only here)
//   3. the update       `update-module.sh backup`: the shim becomes node:<name>,
//                       the local PBS is installed, the clients move to it
//   4. onboarding       the pull peer, now that a local PBS exists to pull INTO
//                       (prompts for the read credential on the old PBS)
//
// `finish-reset` removes the <name>_former storage entry — after the pull has
// run and a test restore worked (§4.3). Nothing ever touches the old PBS.

import { join } from "path";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { peerScript, writePeerConfig } from "./peers";
import { readPlacement } from "./config";

export interface ResetDeps {
  /** Run a program with the terminal attached; its exit code. */
  run(bin: string, args: string[]): number;
  /** Ask the operator; true on yes. */
  confirm(question: string): boolean;
  info(msg: string): void;
  warn(msg: string): void;
}

export interface ResetOptions {
  configDir: string;
  moduleDir: string;
  peer?: string;
  yes: boolean;
  noUpdate: boolean;
  /** The lifecycle script that promotes the shim (tests override it). */
  updateBin?: string;
}

interface FormerExternal {
  pbsUrl?: string;
  storage?: string;
  datastore?: string;
  namespace?: string;
  peer?: string;
}

function formerExternal(configDir: string): FormerExternal | null {
  const f = readJsonObject(join(configDir, "backup.json"))?.formerExternal;
  return f && typeof f === "object" && !Array.isArray(f) ? (f as FormerExternal) : null;
}

/** The host a pbsUrl names: "https://pbs.example:8007/x" → "pbs.example". */
export function urlHost(url: string): string {
  return url.replace(/^[a-z]+:\/\//i, "").replace(/\/.*$/, "").replace(/:\d+$/, "");
}

export function placementReset(o: ResetOptions, d: ResetDeps): number {
  const pl = readPlacement(o.configDir);
  if (pl.kind !== "external") {
    d.warn(`placement is '${pl.placementState ?? "unresolved"}', not external — there is nothing to reset`);
    return 1;
  }
  if (formerExternal(o.configDir)) {
    d.warn("backup.json already records a formerExternal — finish that reset first: backup-manager placement finish-reset");
    return 1;
  }
  const manage = join(o.moduleDir, "scripts", "backup-manage.sh");
  if (!o.yes) {
    const ok = d.confirm(
      `Leave the external PBS at ${pl.pbsUrl} for a local PBS on this site's tankc pool?\n` +
        `  - nothing on ${pl.pbsUrl} is touched; its Proxmox storage entry stays, renamed <name>_former\n` +
        `  - it is recorded as a pull peer, so its history is copied into the new PBS\n` +
        `  - the backup module is then updated: the local PBS is installed and the nodes push there\n` +
        `Continue? [y/N] `,
    );
    if (!ok) {
      d.info("Nothing was changed.");
      return 1;
    }
  }

  // 1. the cluster side, refused with nothing changed if there is nowhere to go
  const rc1 = d.run(manage, ["reset-external", ...(o.peer ? ["--peer", o.peer] : [])]);
  if (rc1 !== 0) return rc1;
  const fe = formerExternal(o.configDir);
  if (!fe?.peer || !fe.pbsUrl) {
    d.warn("reset-external reported success but backup.json records no formerExternal — stopping here; look at config/backup.json");
    return 1;
  }

  // 2. the pull peer, config only: there is no local PBS to pull into yet
  const peerFile = writePeerConfig(o.configDir, "pull", {
    name: fe.peer,
    host: urlHost(fe.pbsUrl),
    store: fe.datastore || undefined,
    remoteNamespace: fe.namespace || undefined,
  });
  d.info(`wrote ${peerFile} — the old PBS, to pull its history from`);

  const finish = `Once the pull has run and a test restore from pull/${fe.peer} worked: backup-manager placement finish-reset`;
  if (o.noUpdate) {
    d.warn("--no-update: NOTHING IS BACKED UP until the backup module is updated — run: update-module.sh backup");
    d.info(`Then onboard the pull: backup-manager peer add pull ${fe.peer} --host ${urlHost(fe.pbsUrl)} --force`);
    d.info(finish);
    return 0;
  }

  // 3. the update that turns the shim into a local PBS
  const rc3 = d.run(o.updateBin ?? "update-module.sh", ["backup"]);
  const after = readPlacement(o.configDir);
  if (rc3 !== 0 || after.kind !== "local") {
    d.warn(`the backup update did not leave a local PBS (rc ${rc3}, placement '${after.placementState ?? "unresolved"}') — ` +
      "NOTHING IS BACKED UP until it does: fix the cause, then run update-module.sh backup. " +
      `The history stays restorable from storage ${fe.storage}.`);
    return rc3 !== 0 ? rc3 : 1;
  }
  d.info(`local PBS on ${after.node}; the nodes push there from now on`);

  // 4. onboard the pull (prompts for the credential on the old PBS)
  const rc4 = d.run(peerScript(o.moduleDir, "pull", "onboard"), [fe.peer]);
  if (rc4 !== 0) {
    d.warn(`onboarding the pull from the old PBS failed (rc ${rc4}); backups run locally regardless. ` +
      `Retry: ${peerScript(o.moduleDir, "pull", "onboard")} ${fe.peer}`);
  }
  d.info(`The history stays restorable from storage ${fe.storage} meanwhile.`);
  d.info(finish);
  return rc4;
}

// `placement use-external <url>` (#456): consume a PBS this site already runs —
// on the LAN, at a satellite, or a third party's. The module's own
// `backup-manage.sh use-external` does the work: it refuses a live local PBS,
// PROMPTS for the credential the remote issues (never stored in JSON, §2.5),
// registers the storage, verifies the existing snapshots are listable, then
// records placementState external + pbsUrl. One command, not a `--set` of the
// state followed by a second, easily forgotten registration step.
export interface UseExternalOptions {
  configDir: string;
  moduleDir: string;
  url: string;
  datastore?: string;
  namespace?: string;
  fingerprint?: string;
}

export function placementUseExternal(o: UseExternalOptions, d: ResetDeps): number {
  if (!o.url) {
    d.warn("placement use-external: <url> required — the PBS clients will push to (e.g. pbs.lan.example)");
    return 1;
  }
  const args = ["use-external", o.url];
  if (o.datastore) args.push("--datastore", o.datastore);
  if (o.namespace) args.push("--namespace", o.namespace);
  if (o.fingerprint) args.push("--fingerprint", o.fingerprint);
  return d.run(join(o.moduleDir, "scripts", "backup-manage.sh"), args);
}

export function placementFinishReset(o: ResetOptions, d: ResetDeps): number {
  const fe = formerExternal(o.configDir);
  if (!fe?.storage) {
    d.warn("backup.json records no formerExternal — there is no reset to finish");
    return 1;
  }
  if (!o.yes) {
    const ok = d.confirm(
      `Remove Proxmox storage ${fe.storage} (the old PBS at ${fe.pbsUrl})?\n` +
        `  Do this only after the pull into pull/${fe.peer} has run and a test restore from it worked:\n` +
        `  afterwards the history is reachable only through the local copy. ${fe.pbsUrl} itself is not touched.\n` +
        `Continue? [y/N] `,
    );
    if (!ok) {
      d.info("Nothing was changed.");
      return 1;
    }
  }
  return d.run(join(o.moduleDir, "scripts", "backup-manage.sh"), ["finish-reset"]);
}
