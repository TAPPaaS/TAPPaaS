// icons.ts — a module's icon for the console's pages: the file its config
// declares (`icon`, relative to the config directory, as module-fields.json
// describes it), else icon.svg or icon.png in its module directory (its
// moduleSource). SVG and PNG only, at most 512 KiB, and only a file whose real
// path stays inside the config directory or the module's directory: a link or
// a "../" leads nowhere. None found: null, and the page draws a tile with the
// module's initial.

import { existsSync, readFileSync, realpathSync, statSync } from "fs";
import { extname, isAbsolute, join, sep } from "path";

export interface ModuleIcon {
  type: "image/svg+xml" | "image/png";
  body: NodeBuffer;
  file: string;
}

const TYPES: Record<string, ModuleIcon["type"]> = { ".svg": "image/svg+xml", ".png": "image/png" };
export const ICON_MAX = 512 * 1024;

function inside(dir: string, file: string): boolean {
  try {
    const d = realpathSync(dir);
    const f = realpathSync(file);
    return f === d || f.startsWith(d.endsWith(sep) ? d : d + sep);
  } catch {
    return false;
  }
}

function load(file: string, roots: string[]): ModuleIcon | null {
  const type = TYPES[extname(file).toLowerCase()];
  if (!type || !existsSync(file) || !roots.some((r) => inside(r, file))) return null;
  const st = statSync(file);
  if (!st.isFile() || st.size > ICON_MAX) return null;
  const body = readFileSync(file);
  // A PNG is a PNG, an SVG an SVG: the type is checked, not taken from the name.
  if (type === "image/png" && !body.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return null;
  if (type === "image/svg+xml" && !/<svg[\s>]/i.test(body.subarray(0, 4096).toString("utf8"))) return null;
  return { type, body, file };
}

export function moduleIcon(configDir: string, module: string): ModuleIcon | null {
  let cfg: Record<string, unknown>;
  try {
    cfg = JSON.parse(readFileSync(join(configDir, `${module}.json`), "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
  const src = typeof cfg.moduleSource === "string" && isAbsolute(cfg.moduleSource) ? cfg.moduleSource : null;
  const roots = [configDir, ...(src ? [src] : [])];
  if (typeof cfg.icon === "string" && cfg.icon.trim() && cfg.icon !== "auto") {
    const declared = load(isAbsolute(cfg.icon) ? cfg.icon : join(configDir, cfg.icon), roots);
    if (declared) return declared;
  }
  if (!src) return null;
  return load(join(src, "icon.svg"), [src]) ?? load(join(src, "icon.png"), [src]);
}
