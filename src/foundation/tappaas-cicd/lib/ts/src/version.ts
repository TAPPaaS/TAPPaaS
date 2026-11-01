// version.ts — the TAPPaaS version a checkout runs (ADR-028 D13).
//
// A version is a release tag, vMAJOR.MINOR (an urgent fix: vMAJOR.MINOR.N), and
// tags travel with every clone. So a site's version is read from its checkout
// at the moment it is asked, never stored: a stored copy is right on the day it
// was written and wrong after the first update — which is what site.json's
// `version` is: the release the site was installed from, kept as that.
// site-manager site show prints it; the console's site read carries it.

import { spawnGuarded } from "./exec";

export const DESCRIBE_ARGS = ["describe", "--tags", "--long", "--match", "v[0-9]*"];

// `git describe --tags --long --match 'v[0-9]*'` → the version. "v2.1-0-g…" is
// exactly 2.1; "v2.1-14-g…" is 14 commits past it, shown "2.1+14" (an unstable
// site between boundaries). A tag that is not a release (v2.0-rc) is null.
export function versionFromDescribe(described: string): string | null {
  const m = /^v(\d+\.\d+(?:\.\d+)?)-(\d+)-g[0-9a-f]+$/.exec(described.trim());
  if (!m) return null;
  return m[2] === "0" ? m[1] : `${m[1]}+${m[2]}`;
}

export function runningVersion(repoPath: string): string | null {
  const r = spawnGuarded("git", ["-C", repoPath, ...DESCRIBE_ARGS], { encoding: "utf8" });
  return r.status === 0 ? versionFromDescribe(r.stdout ?? "") : null;
}
