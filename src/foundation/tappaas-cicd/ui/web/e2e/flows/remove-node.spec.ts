// remove-node.spec.ts — Day 2's Remove a node, from the pick to step 3. The
// bugs it stands for: step 1 collapsing as soon as a node was picked; the
// removal running with another way than the one chosen (--shutdown for a
// wipe) after that collapse; a Remove button disabled with no word why.
// Fixtures: jobs/site-manager-node-delete-tappaas4.preview.txt (the check:
// nothing holds it, its machine record srv-04) and …-tappaas4-erase.apply.txt
// (paced, so the running status line and output can be seen).
import { expect, test } from "@playwright/test";
import { Journal, atCapture, stopJobs } from "./journal.ts";

const NODE = "tappaas4";

test.afterEach(({ request }) => stopJobs(request));

test("remove a node: pick, Continue, check, asset, typed name, Remove", async ({ page }) => {
  await atCapture(page);
  const journal = new Journal();
  await page.goto("/setup/day2");
  await page.getByRole("button", { name: "Remove a node…" }).click();
  const d = page.getByRole("dialog", { name: "Remove a node" });
  const head = (n: string) => d.getByRole("button", { name: new RegExp(`^\\S+ ${n} · `) });

  // 1 · picked, the way chosen: the step stays open, with Continue.
  await d.getByRole("combobox", { name: /^node \*/ }).selectOption(NODE);
  await d.getByRole("radio", { name: /^wipe its disks, power it off, then remove it/ }).check();
  await expect(head("1")).toHaveAttribute("aria-expanded", "true");
  await expect(head("2")).toHaveAttribute("aria-expanded", "false");
  await expect(d.getByRole("radio", { name: /^wipe its disks/ })).toBeChecked();
  // The list's own Continue: a removal found again offers one above it.
  const go = d.locator("ol.setup").getByRole("button", { name: "Continue", exact: true });
  await expect(go).toBeEnabled();
  expect(journal.jobs().filter((c) => c.kind === "preview"), "nothing is checked before Continue").toEqual([]);
  await go.click();

  // 2 · the check runs on what was decided.
  await expect(head("2")).toHaveAttribute("aria-expanded", "true");
  await expect(d.getByText(`${NODE} can be removed: nothing runs on it, nothing is kept on it.`)).toBeVisible();
  await expect(d.getByText("Its disks are wiped first, then it is powered off and removed.")).toBeVisible();
  const checks = await journal.calls("preview", ["site-manager", "node", "delete", NODE]);
  expect(checks.map((c) => c.argv)).toEqual([["site-manager", "node", "delete", NODE, "--erase"]]);

  // The machine's record: removed with it.
  await d.getByRole("radio", { name: /^remove the machine's asset record/ }).check();

  // The button waits for the exact name, and says so.
  const remove = d.getByRole("button", { name: `Remove ${NODE}` });
  const hint = d.getByText(`type ${NODE} exactly to enable the button`);
  await expect(remove).toBeDisabled();
  await expect(hint).toBeVisible();
  const typed = d.getByRole("textbox", { name: `Type ${NODE} to confirm` });
  await typed.fill(NODE.slice(0, -1));
  await expect(remove).toBeDisabled();
  await expect(hint).toBeVisible();
  await expect(d.getByText(`not yet: exactly ${NODE}`)).toBeVisible();
  await typed.fill(NODE);
  await expect(remove).toBeEnabled();
  await expect(hint).toBeHidden();
  await remove.click();

  // What runs: the way and the record chosen.
  const applies = await journal.calls("apply", ["site-manager", "node", "delete", NODE]);
  expect(applies.map((c) => c.argv)).toEqual([["site-manager", "node", "delete", NODE, "--erase", "--asset", "remove", "--yes", "--apply"]]);

  // Running: the status line with Stop, and the output as it comes.
  const status = d.locator("p.job-status").filter({ hasText: `Removing ${NODE}: wiping its disks, powering it off, then taking it out of the cluster` });
  await expect(status).toBeVisible();
  await expect(status).toContainText("running…");
  await expect(status.getByRole("button", { name: "Stop" })).toBeVisible();
  await expect(d.locator("pre.output").filter({ hasText: `Step 3: Wipe ${NODE}'s disks` })).toBeVisible();

  // 3 · afterwards, in the way that was chosen.
  await expect(head("3")).toHaveAttribute("aria-expanded", "true", { timeout: 20_000 });
  await expect(d.getByText("Its disks were wiped before it was removed: nothing of the site is on the machine.")).toBeVisible();
  await expect(d.getByText("The machine's asset record srv-04 is removed, with its place and cables: it has left the site. Its history stays.")).toBeVisible();
  await expect(d.getByText("Its switch port is parked:")).toBeVisible();
});
