// ack.spec.ts — the Health panel's Ack dialog on a warning: the condition's
// type passed, not a field; the note blank (no "<n>" from the help); until
// blank with its grey default, a calendar once used; the command shown
// quoted as a shell splits it, and that is what runs. Bugs it stands for: an
// editable --type, a note prefilled with a placeholder, a command line whose
// values are not quoted.
import { expect, test } from "@playwright/test";
import { Journal, atCapture, shellWords, stopJobs } from "./journal.ts";

const DISK = "f21239ae-6212-48fb-b0b4-0f19402fc40a"; // dsk-09: operational warning (ZFS DEGRADED)
const NOTE = "swap ordered, see the ticket";
const UNTIL = "2026-11-20";

test.afterEach(({ request }) => stopJobs(request));

test("ack a warning: type fixed, note blank, until a date, the command quoted", async ({ page }, info) => {
  await atCapture(page);
  const journal = new Journal();
  await page.goto(`/health?select=${DISK}`);
  // A phone opens the panel, a drawer, by itself when the address selects an
  // object; by Details when it does not.
  if (info.project.name === "phone" && (await page.locator(".health-panel").count()) === 0) await page.getByRole("button", { name: "Details", exact: true }).click();
  const row = page.locator("li.att").filter({ hasText: "operational" }).filter({ hasText: "ZFS DEGRADED" });
  await row.getByRole("button", { name: "Ack…" }).click();
  const d = page.getByRole("dialog", { name: /^Acknowledge operational on / });

  // The type: passed, shown, not a field.
  await expect(d.getByRole("heading", { level: 3 })).toContainText("--type operational");
  await expect(d.getByRole("textbox", { name: /type/i })).toHaveCount(0);
  await expect(d.getByRole("combobox")).toHaveCount(0);
  await expect(d.locator("input")).toHaveCount(3); // note, until, sticky

  // The note: blank, its placeholder in words.
  const note = d.getByRole("textbox", { name: /^note/ });
  await expect(note).toHaveValue("");
  await expect(note).toHaveAttribute("placeholder", "why, for the record");

  // Until: blank, the grey default says what blank means.
  const until = d.getByRole("textbox", { name: /^until/ });
  await expect(until).toHaveValue("");
  await expect(until).toHaveAttribute("placeholder", "when the condition recovers");

  const apply = d.getByRole("button", { name: "Apply" });
  await expect(apply).toBeDisabled();
  await expect(d.getByText("fill in note first")).toBeVisible();

  await note.fill(NOTE);
  await until.click();
  const date = d.locator("input[type=date]");
  await expect(date).toHaveAttribute("min", "2026-11-02"); // tomorrow, by the capture's clock
  await date.fill(UNTIL);
  await date.blur();

  const want = ["health-manager", "ack", DISK, "--type", "operational", "--note", NOTE, "--until", UNTIL];
  const command = d.locator(".command code");
  await expect(command).toHaveText(`$ health-manager ack ${DISK} --type operational --note '${NOTE}' --until ${UNTIL}`);
  expect(shellWords((await command.textContent())!.replace(/^\$ /, "")), "the command splits back into what runs").toEqual(want);

  await expect(apply).toBeEnabled();
  await apply.click();
  await expect(d.locator("p.job-status")).toContainText("ok");
  const applies = await journal.calls("apply", ["health-manager", "ack"]);
  expect(applies.map((c) => c.argv)).toEqual([want]);
});
