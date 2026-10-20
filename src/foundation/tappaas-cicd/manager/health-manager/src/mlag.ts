// mlag.ts — the mlag-pairs gate (#847).
//
// switch-manager records an MLAG pair (two switches presenting one LACP
// partner) and the LAGs across it in ~/config/switch-configuration-actual.json:
// each such LAG's ports carry the same `lag` and `mlagId` on both switches, and
// the switches' last read gives each port's `liveMlagId`. Offline: no switch is
// called (`switch-manager mlag-pair list` reads them live).
//
//   no pair                                           skip
//   every LAG has a member on each peer, as on the switches   pass
//   a LAG with no member on one peer, or an mlag-id the switch has otherwise   warn

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { CheckResult, CheckRow } from "./types";

interface Port { lag?: string; mlagId?: number; liveMlagId?: number }
interface Actual {
  mlagPairs?: Record<string, { switches: string[] }>;
  switches?: Record<string, { ports?: Record<string, Port> }>;
}

export function mlagPairsResult(a: Actual): CheckResult {
  const pairs = Object.entries(a.mlagPairs ?? {});
  if (pairs.length === 0) return { name: "mlag-pairs", status: "skip", detail: "no MLAG pair" };
  const rows: CheckRow[] = [];
  let lags = 0;
  for (const [key, pair] of pairs) {
    const byLag = new Map<string, { sw: string; port: string; p: Port }[]>();
    for (const sw of pair.switches) {
      for (const [port, p] of Object.entries(a.switches?.[sw]?.ports ?? {})) {
        if (p.mlagId === undefined || p.mlagId === null || !p.lag) continue;
        byLag.set(p.lag, [...(byLag.get(p.lag) ?? []), { sw, port, p }]);
      }
    }
    for (const [lag, members] of byLag) {
      lags++;
      for (const sw of pair.switches) {
        if (!members.some((m) => m.sw === sw)) {
          rows.push({ status: "warn", subject: { kind: "switch", name: sw },
            text: `${key}: LAG ${lag} has no member on ${sw} — it is not across the pair; switch-manager lag set … --ports <a>:<p>,<b>:<q>` });
        }
      }
      for (const m of members) {
        if (m.p.liveMlagId !== undefined && m.p.liveMlagId !== null && m.p.liveMlagId !== m.p.mlagId) {
          rows.push({ status: "warn", subject: { kind: "port", name: `${m.sw}:${m.port}` },
            text: `${m.sw}:${m.port}: mlag-id ${m.p.liveMlagId} on the switch, ${m.p.mlagId} in its record (LAG ${lag}) — switch-manager reconcile previews the change` });
        }
      }
    }
  }
  const detail = `${pairs.length} MLAG pair(s), ${lags} LAG(s) across them`;
  return rows.length ? { name: "mlag-pairs", status: "warn", detail, rows } : { name: "mlag-pairs", status: "pass", detail };
}

export function checkMlagPairs(configDir: string): CheckResult {
  const f = join(configDir, "switch-configuration-actual.json");
  if (!existsSync(f)) return { name: "mlag-pairs", status: "skip", detail: "no switch inventory" };
  try {
    return mlagPairsResult(JSON.parse(readFileSync(f, "utf8")) as Actual);
  } catch {
    return { name: "mlag-pairs", status: "skip", detail: `${f} is not readable JSON` };
  }
}
