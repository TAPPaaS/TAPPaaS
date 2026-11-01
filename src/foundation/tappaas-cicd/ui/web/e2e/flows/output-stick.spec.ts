// output-stick.spec.ts — a job's output panel (jobs.tsx Output) follows its
// last line; the reader's own scroll up stops that, and a new line does not
// pull the view back; scrolling to the bottom again resumes it. Fixture:
// jobs/module-manager-update-litellm.apply.txt, 341 lines, the first 300 at
// once, then one every 400 ms (.pace). The bug it stands for: a panel that
// did not follow, or froze, or jumped back while being read.
import { expect, test, type Locator } from "@playwright/test";
import { Journal, atCapture, stopJobs } from "./journal.ts";

const lines = (pre: Locator) => pre.evaluate((e) => e.textContent!.split("\n").length);
const fromBottom = (pre: Locator) => pre.evaluate((e) => e.scrollHeight - e.scrollTop - e.clientHeight);
const top = (pre: Locator) => pre.evaluate((e) => e.scrollTop);

test.afterEach(({ request }) => stopJobs(request));

test("the output follows its last line until the reader scrolls up", async ({ page }) => {
  await atCapture(page);
  const journal = new Journal();
  await page.goto("/modules/litellm");
  await page.getByRole("button", { name: "Update (release)" }).click();
  const d = page.getByRole("dialog", { name: "Update litellm to its release" });
  await d.getByRole("button", { name: "Apply" }).click();
  const status = d.locator("p.job-status");
  await expect(status).toContainText("running…");
  const pre = d.locator("pre.output");

  // Loaded: 300 lines, the view at the last.
  await expect.poll(() => lines(pre)).toBeGreaterThanOrEqual(300);
  await expect.poll(() => pre.evaluate((e) => e.scrollHeight > e.clientHeight * 3)).toBe(true);
  await expect.poll(() => fromBottom(pre)).toBeLessThan(24);
  const n0 = await lines(pre);
  await expect.poll(() => lines(pre)).toBeGreaterThan(n0);
  await expect.poll(() => fromBottom(pre), { message: "a new line: still at the last" }).toBeLessThan(24);

  // The reader scrolls up: it stays there while lines come.
  const box = (await pre.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.wheel(0, -800);
  await expect.poll(() => fromBottom(pre)).toBeGreaterThan(400);
  const at = await top(pre);
  const n1 = await lines(pre);
  await expect.poll(() => lines(pre), { timeout: 5_000 }).toBeGreaterThanOrEqual(n1 + 2);
  expect(await top(pre), "a new line does not scroll the reader back").toBe(at);
  expect(await fromBottom(pre)).toBeGreaterThan(400);

  // Back at the bottom: it follows again.
  await page.mouse.wheel(0, 100_000);
  await expect.poll(() => fromBottom(pre)).toBeLessThan(24);
  const n2 = await lines(pre);
  await expect.poll(() => lines(pre), { timeout: 5_000 }).toBeGreaterThanOrEqual(n2 + 2);
  await expect.poll(() => fromBottom(pre), { message: "following again" }).toBeLessThan(24);

  // Done with it: Stop.
  await status.getByRole("button", { name: "Stop" }).click();
  await status.getByRole("button", { name: "Stop the job" }).click();
  await expect(d.getByText("It did not finish: the job was stopped.")).toBeVisible();
  expect((await journal.calls("apply", ["module-manager", "update", "litellm"])).length).toBe(1);
});
