// add-switch.spec.ts — Add a switch, the way managed outside TAPPaaS: the four
// ways as a choice, the switch's name, its record with --managed manual, then
// the ports stage. The record has no dry run: Apply runs it as previewed.
import { expect, test } from "@playwright/test";
import { Journal, atCapture, stopJobs } from "./journal.ts";

test.afterEach(({ request }) => stopJobs(request));

test("add a switch: choose, name it, record it as managed outside TAPPaaS", async ({ page }) => {
  await atCapture(page);
  const journal = new Journal();
  await page.goto("/setup/day2");
  await page.getByRole("button", { name: "Add a switch…" }).click();
  const d = page.getByRole("dialog", { name: "Add a switch" });
  await expect(d.getByRole("radio")).toHaveCount(4);
  await d.getByRole("radio", { name: /A switch managed outside TAPPaaS/ }).check();
  await d.getByRole("button", { name: "Continue", exact: true }).click();

  await d.getByRole("textbox", { name: /^its name in TAPPaaS/ }).fill("office-sw");
  await d.getByRole("button", { name: "Continue", exact: true }).click();
  await d.getByRole("textbox", { name: /^brand/ }).fill("netgear");
  await d.getByRole("button", { name: "Record office-sw" }).click();

  const applies = await journal.calls("apply", ["switch-manager", "add-switch", "office-sw"]);
  expect(applies.map((c) => c.argv)).toEqual([["switch-manager", "add-switch", "office-sw", "--vendor", "netgear", "--managed", "manual"]]);
  // The record's stage closes as it is done; the ports' stage opens.
  await expect(d.getByRole("button", { name: /2 · The switch done/ })).toBeVisible();
  await expect(d.getByRole("button", { name: "Continue without recording a port" })).toBeVisible();
});
