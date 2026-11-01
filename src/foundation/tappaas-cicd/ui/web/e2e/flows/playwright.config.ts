// flows/playwright.config.ts — the flows (*.spec.ts): the wizards and operate
// buttons clicked through against a console in fixture mode, at the phone and
// laptop viewports. run.sh starts the server and sets E2E_BASE_URL and E2E_NOW;
// alone: ui/fixture-server.sh --port 9097 &, then from web/
//   npx playwright test -c e2e/flows/playwright.config.ts
// One worker: changes run one at a time on the server, and each flow reads the
// lines the journal gained while it ran.
import { defineConfig } from "@playwright/test";
import { USE, VIEWPORTS } from "../playwright.config.ts";

export default defineConfig({
  testDir: ".",
  testMatch: "*.spec.ts",
  outputDir: process.env.E2E_RESULTS ?? "../test-results",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  use: { ...USE, actionTimeout: 10_000 },
  projects: (["phone", "laptop"] as const).map((name) => ({ name, use: { viewport: VIEWPORTS[name] } })),
});
