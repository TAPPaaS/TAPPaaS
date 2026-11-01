// journal.ts — what the flows assert besides the page's text: the fixture
// server's journal (src/fixtures.ts), one {at, kind, argv} line per verb call,
// at /tmp/tappaas-console-fixtures-<port>/journal.jsonl (fixture-server.sh).
// The clock stands still in fixture mode, so a flow takes the lines added
// since its mark (one worker: nothing else writes meanwhile).
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, type APIRequestContext, type Page } from "@playwright/test";

export interface Call { kind: "read" | "preview" | "apply"; argv: string[] }

const port = new URL(process.env.E2E_BASE_URL ?? "http://127.0.0.1:9097").port || "80";
const FILE = process.env.E2E_JOURNAL ?? `/tmp/tappaas-console-fixtures-${port}/journal.jsonl`;

const all = (): Call[] => (existsSync(FILE) ? readFileSync(FILE, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as Call) : []);

export class Journal {
  private from = all().length;
  // The calls since the mark that were not reads.
  jobs(): Call[] {
    return all().slice(this.from).filter((c) => c.kind !== "read");
  }
  // Waits for a job call whose argv starts with `prefix`; all of them.
  async calls(kind: Call["kind"], prefix: string[]): Promise<Call[]> {
    const match = (): Call[] => this.jobs().filter((c) => c.kind === kind && prefix.every((w, i) => c.argv[i] === w));
    await expect.poll(() => match().length, { message: `a ${kind} of ${prefix.join(" ")} in the journal` }).toBeGreaterThan(0);
    return match();
  }
}

// A shell's split of a command line as Command (jobs.tsx quote) prints it:
// words by spaces, '…' quoted, '\'' an escaped quote.
export function shellWords(line: string): string[] {
  const words: string[] = [];
  let w: string | null = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === "'") {
      const end = line.indexOf("'", i + 1);
      w = (w ?? "") + line.slice(i + 1, end < 0 ? line.length : end);
      i = end < 0 ? line.length : end;
    } else if (c === "\\" && i + 1 < line.length) {
      w = (w ?? "") + line[++i];
    } else if (c === " ") {
      if (w !== null) words.push(w);
      w = null;
    } else w = (w ?? "") + c;
  }
  if (w !== null) words.push(w);
  return words;
}

// The browser's clock at the fixtures' capture, as the server's: the
// wizards' "within the hour" and a calendar's tomorrow agree with it.
const CAPTURED = join(dirname(fileURLToPath(import.meta.url)), "../../../test/fixtures/CAPTURED");
export const NOW = process.env.E2E_NOW || readFileSync(CAPTURED, "utf8").split("\n")[0].trim();
export async function atCapture(page: Page): Promise<void> {
  await page.clock.setFixedTime(new Date(NOW));
}

// After each flow, pass or fail: no job of it left running, so the next one's
// change is not queued behind it (changes run one at a time).
export async function stopJobs(request: APIRequestContext): Promise<void> {
  const live = async (): Promise<string[]> => {
    const r = await request.get("/api/v1/jobs?limit=50");
    const jobs = ((await r.json()) as { data?: { jobs?: { id: string; state: string }[] } }).data?.jobs ?? [];
    return jobs.filter((j) => j.state === "queued" || j.state === "running").map((j) => j.id);
  };
  for (const id of await live()) await request.post(`/api/v1/jobs/${encodeURIComponent(id)}/cancel`, { data: {} });
  await expect.poll(async () => (await live()).length, { message: "every job of the flow ended" }).toBe(0);
}
