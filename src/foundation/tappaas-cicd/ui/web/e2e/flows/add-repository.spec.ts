// add-repository.spec.ts — Add a repository on the Site page: the URL looked
// at (repository probe), the branch it would take filled in, and the signing
// choices only for a verified branch: --signer gone once --unsigned is ticked.
// Fixture: reads/site-manager-repository-probe-codeberg.org-example-modules-json.out
// (synthetic: a repository that signs its stable branch).
import { expect, test } from "@playwright/test";
import { atCapture, stopJobs } from "./journal.ts";

test.afterEach(({ request }) => stopJobs(request));

test("add a repository: probe, branch, unsigned before signer", async ({ page }) => {
  await atCapture(page);
  await page.goto("/site");
  await page.getByRole("button", { name: "Add a repository…" }).click();
  const d = page.getByRole("dialog", { name: /repository add/ });
  const url = d.getByRole("textbox", { name: /^repository URL/ });
  await expect(url).toHaveValue(""); // Community is on the site already
  await expect(d.getByText("--unsigned")).toHaveCount(0);
  await url.fill("codeberg.org/example/modules");
  await expect(d.getByText(/stable is a production branch, its releases are checked/)).toBeVisible();
  await expect(d.getByRole("combobox", { name: /^--branch/ })).toHaveValue("stable");
  await expect(d.getByRole("textbox", { name: /^--signer/ })).toBeVisible();
  await d.getByRole("checkbox", { name: /^--unsigned/ }).check();
  await expect(d.getByRole("textbox", { name: /^--signer/ })).toHaveCount(0);
  await d.getByRole("combobox", { name: /^--managed/ }).selectOption("tracked");
  await expect(d.getByRole("textbox", { name: /^--catalog/ })).toHaveCount(0);
});
