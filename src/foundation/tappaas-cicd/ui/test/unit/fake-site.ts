// fake-site.ts — a Runner that answers the managers' verbs from hrossen's
// captured outputs, and records what was run: the console's fixture mode
// (src/fixtures.ts) with its hand-written answers. The tests assert on what the
// site held then, so they read the set frozen in test/fixtures/2026-10-17, not
// the one capture.sh refreshes.

import { readFileSync } from "fs";
import { join } from "path";
import { FixtureSite, fixtureSite } from "../../src/fixtures";

export const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";
export const PIN = join(FIX, "2026-10-17");
export const pinned = <T>(f: string): T => JSON.parse(readFileSync(join(PIN, f), "utf8")) as T;

export type FakeSite = FixtureSite;

export function fakeSite(): FakeSite {
  return fixtureSite(PIN);
}
