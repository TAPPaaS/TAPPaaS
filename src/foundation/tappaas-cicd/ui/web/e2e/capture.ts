// capture.ts — every route of routes.json at the project's viewport: load it,
// open what its `open` steps click, wait for the network and the `settle`
// text, then write shots/<viewport>/<id>.png (the full page; the viewport
// when `open` opened a dialog) and <id>.txt (the
// accessibility tree: role "name": value, one node per line, indented).
// A console error or a non-2xx response fails the route, except the 404 of
// /api/v1/modules/<name>/icon, which a module without an icon answers.
// Run through run.sh (it starts the fixture server and sets E2E_*).
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test, type Page } from "@playwright/test";

interface Step { role: Parameters<Page["getByRole"]>[0]; name: string; exact?: boolean }
interface Route { id: string; path: string; open?: Step[]; settle?: string }

const HERE = dirname(fileURLToPath(import.meta.url));
const ROUTES: Route[] = JSON.parse(readFileSync(join(HERE, "routes.json"), "utf8"));
const ONLY = (process.env.E2E_ROUTES ?? "").split(",").filter(Boolean);
const OUT = resolve(process.env.E2E_OUT ?? join(HERE, "shots"));
const NOW = process.env.E2E_NOW;
const ICON = /\/api\/v1\/modules\/[^/]+\/icon$/;

// What the capture holds still: no animation, transition or caret, and no
// scrollbar to come and go with a page's height.
const STILL = `*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; scroll-behavior: auto !important; }
html { scrollbar-width: none; } ::-webkit-scrollbar { display: none; }`;

const unknown = ONLY.filter((id) => !ROUTES.some((r) => r.id === id));
if (unknown.length) throw new Error(`routes.json has no ${unknown.join(", ")}`);

for (const r of ROUTES.filter((x) => !ONLY.length || ONLY.includes(x.id))) {
  test(r.id, async ({ page }, info) => {
    const vp = info.project.name;
    const t0 = Date.now();
    const problems: string[] = [];
    let watching = true;
    page.on("console", (m) => {
      if (!watching || m.type() !== "error") return;
      if (ICON.test(m.location().url) && m.text().includes("404")) return;
      problems.push(`console: ${m.text()}`);
    });
    page.on("pageerror", (e) => watching && problems.push(`page error: ${e.message}`));
    page.on("response", (res) => {
      const s = res.status();
      if (!watching || (s >= 200 && s < 300) || s === 304) return;
      if (s === 404 && ICON.test(new URL(res.url()).pathname)) return;
      problems.push(`HTTP ${s} ${res.request().method()} ${new URL(res.url()).pathname}`);
    });
    page.on("requestfailed", (req) => watching && problems.push(`failed: ${req.method()} ${new URL(req.url()).pathname} ${req.failure()?.errorText ?? ""}`));

    if (NOW) await page.clock.setFixedTime(new Date(NOW));
    await page.goto(r.path);
    await page.addStyleTag({ content: STILL });
    await page.waitForLoadState("networkidle");
    for (const s of r.open ?? []) {
      // exact: false matches a name that holds more than its words, a step's header
      // with its state beside its title.
      await page.getByRole(s.role, { name: s.name, exact: s.exact ?? true }).click();
      await page.waitForLoadState("networkidle");
    }
    if (r.settle) await page.getByText(r.settle).first().waitFor({ state: "visible" });
    const still = await settle(page);

    const dir = join(OUT, vp);
    mkdirSync(dir, { recursive: true });
    // A dialog covers the viewport, not the page under it: the viewport then.
    const png = await page.screenshot({ fullPage: !r.open?.length, animations: "disabled", caret: "hide" });
    writeFileSync(join(dir, `${r.id}.png`), png);
    writeFileSync(join(dir, `${r.id}.txt`), `${await page.locator("body").ariaSnapshot()}\n`);
    watching = false;
    const size = `${png.readUInt32BE(16)}x${png.readUInt32BE(20)}`;
    const line = `${problems.length ? "FAIL" : "ok  "} ${vp}/${r.id} ${size} ${Date.now() - t0}ms${still ? "" : " (the page kept changing for 8 s)"}`;
    console.log(problems.length ? `${line}\n  ${problems.join("\n  ")}` : line);
    if (problems.length) throw new Error(`${r.id} at ${vp}: ${problems.join("; ")}`);
  });
}

// Quiet: no request in flight, the fonts loaded, the images decoded, the DOM
// unchanged for 400 ms (React Flow measures its nodes, then draws the edges
// and fits the view, after the data has come), and two frames drawn after.
async function settle(page: Page): Promise<boolean> {
  await page.waitForLoadState("networkidle");
  return page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all(Array.from(document.images, (i) => (i.complete ? null : i.decode().catch(() => null))));
    const still = await new Promise<boolean>((done) => {
      let quiet = setTimeout(stop, 400, true);
      const cap = setTimeout(stop, 8000, false);
      const mo = new MutationObserver(() => { clearTimeout(quiet); quiet = setTimeout(stop, 400, true); });
      function stop(ok: boolean): void { clearTimeout(quiet); clearTimeout(cap); mo.disconnect(); done(ok); }
      mo.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    });
    await new Promise((f) => requestAnimationFrame(() => requestAnimationFrame(() => f(null))));
    return still;
  });
}
