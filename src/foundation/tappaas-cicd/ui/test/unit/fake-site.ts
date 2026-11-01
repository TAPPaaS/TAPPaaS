// fake-site.ts — a Runner that answers the managers' verbs from hrossen's
// captured outputs (test/fixtures), and records what was run: the console's
// fixture mode (src/fixtures.ts) with its hand-written answers.

import { FixtureSite, fixtureSite } from "../../src/fixtures";

export const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";

export type FakeSite = FixtureSite;

export function fakeSite(): FakeSite {
  return fixtureSite(FIX);
}
