// add-node.spec.ts — Add a node, stage 1: the form, Declare, then one line in
// place of the form while the wizard moves on to stage 2, the job's status
// and Stop a click away on stage 1's head. Fixture: jobs/site-manager-node-
// add-tappaas5.apply.txt, paced (the job keeps running until it is stopped).
import { expect, test } from "@playwright/test";
import { Journal, atCapture, stopJobs } from "./journal.ts";

const NODE = "tappaas5";
const MAC = "58:47:ca:7a:12:34";

test.afterEach(({ request }) => stopJobs(request));

test("add a node: declare, one line, stage 2, Stop", async ({ page }) => {
  await atCapture(page);
  const journal = new Journal();
  await page.goto("/setup/day2");
  await page.getByRole("button", { name: "Add a node…" }).click();
  const d = page.getByRole("dialog", { name: "Add a node" });
  const steps = d.locator("ol.setup");
  const head = (n: string) => steps.getByRole("button", { name: new RegExp(`^\\S+ ${n} · `) });
  const stage1 = steps.locator("li.setup-step").nth(1);

  // The name typed: an add found again would move the proposal on.
  await stage1.getByRole("textbox", { name: /^node name \*/ }).fill(NODE);
  await stage1.getByRole("textbox", { name: /^MAC address/ }).fill(MAC);
  await stage1.getByRole("button", { name: `Declare ${NODE}` }).click();

  // Stage 2 opens: getting ready, then boot now.
  await expect(head("2")).toHaveAttribute("aria-expanded", "true");
  await expect(head("1")).toHaveAttribute("aria-expanded", "false");
  await expect(steps.getByText(/^Getting ready — do not boot yet\. Stage 1's job is on: /)).toBeVisible();
  await expect(steps.getByText("Ready: boot the machine now.")).toBeVisible({ timeout: 20_000 });

  // Stage 1, opened again: one line for the job, with Stop; no form, no output.
  await head("1").click();
  const line = stage1.locator("p.job-status");
  await expect(line).toHaveCount(1);
  await expect(line).toContainText(`${NODE} is declared: boot it now, from the network or the USB stick.`);
  await expect(line).toContainText("running…");
  await expect(stage1.locator("pre.output")).toHaveCount(0);
  await expect(stage1.getByRole("button", { name: `Declare ${NODE}` })).toHaveCount(0);
  await expect(head("2")).toHaveAttribute("aria-expanded", "true");

  // Stop reaches the job; the line says so.
  await line.getByRole("button", { name: "Stop" }).click();
  await line.getByRole("button", { name: "Stop the job" }).click();
  await expect(line).toContainText("stopped");
  await expect(line).toContainText(`${NODE} is declared; its job has ended: stage 3 has its output.`);

  const applies = await journal.calls("apply", ["site-manager", "node", "add", NODE]);
  expect(applies.map((c) => c.argv)).toEqual([["site-manager", "node", "add", NODE, "--mac", MAC, "--no-wan", "--yes"]]);
});
