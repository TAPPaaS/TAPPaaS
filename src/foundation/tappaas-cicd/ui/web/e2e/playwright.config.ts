// playwright.config.ts — the visual capture (capture.ts) against a console in
// fixture mode (ui/fixture-server.sh). run.sh sets the environment:
//   E2E_BASE_URL  the server (default http://127.0.0.1:9097)
//   E2E_NOW       the server's CONSOLE_NOW; the browser's clock stands there too
//   E2E_OUT       where shots/<viewport>/<id>.{png,txt} go (default e2e/shots)
//   E2E_ROUTES    id,… to capture only those routes
// Four projects, one per viewport of docs/plans/console-gui-pipeline.md §4.
// The flows (flows/*.spec.ts) have a config of their own beside them.
import { defineConfig, type PlaywrightTestConfig } from "@playwright/test";

export const VIEWPORTS = {
  phone: { width: 390, height: 844 },
  tablet: { width: 820, height: 1180 },
  laptop: { width: 1366, height: 768 },
  desktop: { width: 1920, height: 1080 },
} as const;

// What every run shares, the flows' too (flows/playwright.config.ts).
export const USE: PlaywrightTestConfig["use"] = {
  baseURL: process.env.E2E_BASE_URL ?? "http://127.0.0.1:9097",
  browserName: "chromium",
  reducedMotion: "reduce",
  colorScheme: "light",
  locale: "en-GB",
  timezoneId: "Europe/Copenhagen",
  deviceScaleFactor: 1,
  extraHTTPHeaders: { "X-Console-Actor": "operator" },
  trace: "off",
  screenshot: "off",
  video: "off",
};

export default defineConfig({
  testDir: ".",
  testMatch: "capture.ts",
  outputDir: process.env.E2E_RESULTS ?? "test-results",
  fullyParallel: true,
  workers: Number(process.env.E2E_WORKERS ?? 4),
  retries: 0,
  timeout: 60_000,
  reporter: [["list"]],
  use: USE,
  projects: Object.entries(VIEWPORTS).map(([name, viewport]) => ({ name, use: { viewport } })),
});
