// keys.ts — where `key export` / `key import` put and find the keys (ADR-012 §2.5.1).
//
//   --file <dir>   a directory: the plain copy, written and read by pbs-controller.
//                  The files are NOT encrypted — whatever holds them must be guarded.
//   --usb          a USB stick in a node: encrypted with a password, verified by reading
//                  it back, ejected (export); or decrypted and imported (import). The
//                  mothership is a VM with no USB port, so the stick goes into a node.
//                  A stick written before keeps everything but its keys; --format
//                  erases it instead (export only).
//
// The USB path is the backup module's own scripts (scripts/keys-to-usb.sh,
// scripts/keys-from-usb.sh) — an implementation detail: the operator's command is
// backup-manager. They run interactively (stick choice, the erase confirmation, the
// password), so they stream on the operator's terminal: `ssh -t` when remote.

import { existsSync } from "fs";
import { join } from "path";
import { stream } from "../../../lib/ts/src/exec";
import { moduleScriptDir } from "./restore";

export type KeyTarget =
  | { kind: "file"; dir: string }
  | { kind: "usb"; node: string | null; format: boolean };

// keyTarget — what `key export|import <args>` asks for. Pure.
// A bare directory (`key export <dir>`, the original form) is --file.
export function keyTarget(verb: "export" | "import", args: string[]): KeyTarget | { error: string } {
  let file: string | null = null;
  let usb = false;
  let node: string | null = null;
  let format = false;
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--usb") usb = true;
    else if (a === "--format") format = true;
    else if (a === "--file") {
      const v = args[++i];
      if (!v || v.startsWith("--")) return { error: `key ${verb} --file: a directory is required` };
      file = v;
    } else if (a === "--node") {
      const v = args[++i];
      if (!v || v.startsWith("--")) return { error: `key ${verb} --node: a node name is required` };
      node = v;
    } else positional.push(a);
  }
  if (positional.length > 1) return { error: `key ${verb}: one directory at most, got ${positional.join(" ")}` };
  if (positional.length === 1) {
    if (file !== null) return { error: `key ${verb}: a directory is given twice` };
    file = positional[0];
  }
  if (usb && file !== null) return { error: `key ${verb}: --usb or --file, not both` };
  if (!usb && file === null) {
    return { error: `key ${verb}: say where — --usb (a stick in a node, encrypted) or --file <dir>` };
  }
  if (node !== null && !usb) return { error: `key ${verb}: --node goes with --usb (the node holding the stick)` };
  if (format && (!usb || verb !== "export")) return { error: `key ${verb}: --format goes with export --usb (erase the stick instead of rewriting its keys)` };
  return usb ? { kind: "usb", node, format } : { kind: "file", dir: file as string };
}

// keysUsb — run the module's USB script, on this terminal. Returns its exit code.
export function keysUsb(
  verb: "export" | "import", node: string | null, configDir?: string,
  run: (bin: string, args: string[]) => number = stream,
  format = false,
): number {
  const script = join(moduleScriptDir(configDir), "scripts", verb === "export" ? "keys-to-usb.sh" : "keys-from-usb.sh");
  if (!existsSync(script)) {
    console.error(`key ${verb} --usb: ${script} not found — check config/backup.json .moduleSource`);
    return 1;
  }
  return run(script, [...(node ? ["--node", node] : []), ...(format ? ["--format"] : [])]);
}
