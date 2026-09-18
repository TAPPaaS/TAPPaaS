// instance.ts — instance vs module (ADR-026 D6).
//
// config/<instance>.json names an INSTANCE; the module it belongs to is named
// by its source directory (`.moduleSource`), whose basename is the module's name.
// The instance name equals the module name only by default (D6.4), and `vmname`
// is an instance name too — so neither is ever used to find the module.

import { basename, join } from "path";

/**
 * A deployed config's source directory: `.moduleSource`, or `.location` — its
 * name until #609, still read for a config migration 0006 has not reached.
 * "" when neither is a non-empty string (a site-style `location` object never
 * counts: that is a physical place, not a directory).
 */
export function moduleSourceOf(raw: Record<string, unknown> | null | undefined): string {
  for (const v of [raw?.moduleSource, raw?.location]) {
    if (typeof v === "string" && v !== "") return v;
  }
  return "";
}

/** The module whose source lives at <location>: the directory's basename (D6.3). */
export function moduleOfLocation(location: string): string {
  return basename(location.replace(/\/+$/, ""));
}

/** The release source JSON of the module at <location>: <location>/<module>.json. */
export function moduleSourceJson(location: string): string {
  return join(location, `${moduleOfLocation(location)}.json`);
}
