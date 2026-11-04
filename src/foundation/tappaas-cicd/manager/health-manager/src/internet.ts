// internet.ts — the internet gate: the mothership reaches the internet over IPv4.
//
// The update pulls from the repository host and builds from the NixOS cache;
// a site that cannot reach them updates nothing. An HTTPS HEAD to each, from
// this (cicd) VM through the firewall: the name resolves (the firewall's
// resolver), the route out works (the firewall's WAN and NAT), and TLS answers.
//
//   one answers     pass
//   none answers    fail, naming what was tried

import { spawnGuarded } from "../../../lib/ts/src/exec";
import { CheckResult } from "./types";

export const INTERNET_TARGETS = ["https://codeberg.org/", "https://cache.nixos.org/"];

export type Probe = (url: string) => { ok: boolean; why: string };

const curl: Probe = (url) => {
  const r = spawnGuarded("curl", ["-4", "-sS", "-o", "/dev/null", "-I", "--max-time", "8", url], { encoding: "utf8" });
  return { ok: r.status === 0, why: ((r.stderr as string | undefined) ?? "").trim().split("\n").slice(-1)[0] || `curl exit ${r.status ?? "?"}` };
};

const hostOf = (url: string): string => url.replace(/^[a-z]+:\/\//, "").replace(/[/:].*$/, "");

export function checkInternet(probe: Probe = curl): CheckResult {
  const tried: string[] = [];
  for (const url of INTERNET_TARGETS) {
    const r = probe(url);
    if (r.ok) return { name: "internet", status: "pass", detail: `the mothership reaches ${hostOf(url)}` };
    tried.push(`${hostOf(url)}: ${r.why}`);
  }
  return { name: "internet", status: "fail", detail: `no internet from the mothership — ${tried.join("; ")}. Check the firewall's WAN, its DNS resolver and the upstream router` };
}
