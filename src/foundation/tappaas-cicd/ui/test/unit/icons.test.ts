// icons.test.ts — a module's icon (src/icons.ts): the file its config
// declares, else icon.svg / icon.png in its module directory; SVG and PNG
// only, checked by content, and nothing outside the config or module
// directory.

import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { ICON_MAX, moduleIcon } from "../../src/icons";
import { check, done } from "./check";

const root = mkdtempSync(join(tmpdir(), "console-icons-"));
const cfg = join(root, "config");
const repo = join(root, "TAPPaaS", "src", "home");
mkdirSync(cfg, { recursive: true });
const mod = (name: string, files: Record<string, string | NodeBuffer>, extra: Record<string, unknown> = {}): void => {
  const dir = join(repo, name);
  mkdirSync(dir, { recursive: true });
  for (const [f, b] of Object.entries(files)) typeof b === "string" ? writeFileSync(join(dir, f), b) : writeFileSync(join(dir, f), b);
  writeFileSync(join(cfg, `${name}.json`), JSON.stringify({ moduleSource: dir, ...extra }));
};
const SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>';
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]);

mod("immich", { "icon.svg": SVG });
mod("photos", { "icon.png": PNG });
mod("plain", {});
mod("branded", { "icon.svg": SVG }, { icon: "branding/brand.svg" });
mkdirSync(join(cfg, "branding"));
writeFileSync(join(cfg, "branding", "brand.svg"), SVG.replace("rect", "circle"));
mod("escape", { "icon.svg": SVG }, { icon: "../../../etc/passwd.svg" });
mod("fake", { "icon.png": "<html>not a png</html>", "icon.svg": "#!/bin/sh\necho no" });
mod("huge", { "icon.svg": `<svg>${" ".repeat(ICON_MAX)}</svg>` });
mod("linked", {});
writeFileSync(join(root, "outside.svg"), SVG);
symlinkSync(join(root, "outside.svg"), join(repo, "linked", "icon.svg"));

check(moduleIcon(cfg, "immich")?.type === "image/svg+xml" && moduleIcon(cfg, "immich")!.body.toString() === SVG, "icon.svg in the module's directory");
check(moduleIcon(cfg, "photos")?.type === "image/png", "else icon.png");
check(moduleIcon(cfg, "plain") === null && moduleIcon(cfg, "nosuch") === null, "no icon, or no module: none (the page draws the initial)");
check(/circle/.test(moduleIcon(cfg, "branded")?.body.toString() ?? ""), "a declared icon (relative to the config directory) wins");
check(moduleIcon(cfg, "escape")?.file.endsWith(join("escape", "icon.svg")) === true, "a declared path outside the config directory is ignored: the module's own icon");
check(moduleIcon(cfg, "fake") === null, "a file that is not what its name says is no icon");
check(moduleIcon(cfg, "huge") === null, "too large: no icon");
check(moduleIcon(cfg, "linked") === null, "a link out of the module's directory is no icon");
done("icons");
