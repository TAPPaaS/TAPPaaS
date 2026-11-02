// add-stack.spec.ts — Day 2's Add a stack: the plan's modules as a list, the
// installed ones marked, the rest ticked, and what is unticked reaching the
// preview as --skip. Fixtures: reads/module-manager-add-stack-home-…-json.out
// and jobs/module-manager-add-stack-home.preview.txt.
import { expect, test } from "@playwright/test";
import { Journal, atCapture, stopJobs } from "./journal.ts";

test.afterEach(({ request }) => stopJobs(request));

test("add a stack: pick, tick, preview without what was unticked", async ({ page }) => {
  await atCapture(page);
  const journal = new Journal();
  await page.goto("/setup/day2");
  await page.getByRole("button", { name: "Add a stack…" }).click();
  const d = page.getByRole("dialog", { name: "Add a stack" });
  const stacks = await d.getByRole("combobox", { name: /^stack \*/ }).locator("option").allTextContents();
  expect(stacks.filter((s) => /^(test|template|foundation)\b/.test(s))).toEqual([]);
  await d.getByRole("combobox", { name: /^stack \*/ }).selectOption("home");
  await d.getByRole("combobox", { name: /^environment \*/ }).selectOption("rossen");
  await d.getByRole("button", { name: "Continue", exact: true }).click();

  const hass = d.getByRole("checkbox", { name: /^hass/ });
  await expect(hass).toBeChecked();
  await expect(hass).toBeDisabled();
  await expect(d.locator(".stack-modules li", { hasText: "hass" }).getByText("installed", { exact: true })).toBeVisible();
  await expect(d.getByRole("checkbox", { name: /^nomad/ })).toBeChecked();
  await expect(d.getByText("Karakeep — bookmarks and read-later")).toBeVisible();
  await expect(d.locator(".stack-modules li", { hasText: "karakeep" }).getByText(/^\(Repo: TAPPaaS, Maintainer: @\S+, Status: \w+\)$/)).toBeVisible();
  await d.getByRole("checkbox", { name: /^karakeep/ }).uncheck();
  await d.getByRole("button", { name: "Continue", exact: true }).last().click();

  await expect(d.getByText("--dry-run: nothing changed")).toBeVisible();
  const previews = await journal.calls("preview", ["module-manager", "add-stack", "home"]);
  expect(previews.map((c) => c.argv)).toEqual([["module-manager", "add-stack", "home", "--environment", "rossen", "--skip", "karakeep", "--dry-run"]]);
});
