// signatures.ts — the signature-status gate (ADR-033 D10).
//
// check-repo-signatures.sh writes ~/config/sbom/signatures.json after every
// repository sync: one row per repository the site tracks, saying whether what
// its checkout runs is a release its owners signed. This gate reads that file.
//
//   verified            pass
//   unsigned-unstable   skip — nothing is signed on an unstable branch, by design
//   unsigned-declared   warn — FAIL when the site sets requireSigned
//   ahead-of-release    warn — the code running is not what was released
//   failed              FAIL — on a signed channel, and not a verified release
//   a key expiring      warn — whatever the status
//
// A gate that FAILs fails `validate`. Only a checkout that claims a signed
// channel and runs something unverified does that; the sync refuses to move
// to such a revision, so seeing it means someone moved the checkout by hand.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { sbomDir } from "./security";
import { CheckResult, CheckRow, CheckStatus } from "./types";

export const SIGNATURES_FILE = "signatures.json";
// Older than this and the file no longer describes what runs (no sync since).
const STALE_DAYS = 3;

export interface RepoSignature {
  name: string;
  branch: string;
  channel?: string;
  status: "verified" | "unsigned-unstable" | "unsigned-declared" | "ahead-of-release" | "failed";
  tag?: string;
  signer?: string;
  reason?: string;
  expiringKeys?: { principal: string; validBefore: string }[];
}

export interface Signatures {
  generated: string;
  requireSigned: boolean;
  repositories: RepoSignature[];
}

export function readSignatures(configDir: string): Signatures | null {
  const f = join(sbomDir(configDir), SIGNATURES_FILE);
  if (!existsSync(f)) return null;
  try {
    const s = JSON.parse(readFileSync(f, "utf8")) as Signatures;
    return Array.isArray(s.repositories) ? s : null;
  } catch {
    return null;
  }
}

const RANK: Record<CheckStatus, number> = { pass: 0, skip: 0, warn: 1, fail: 2 };

function rowFor(r: RepoSignature, requireSigned: boolean): CheckRow {
  const name = r.name.padEnd(16);
  switch (r.status) {
    case "verified":
      return { status: "pass", text: `${name}${r.tag} — signed by ${r.signer ?? "?"}` };
    case "unsigned-unstable":
      return { status: "skip", text: `${name}unsigned — ${r.branch} is unstable` };
    case "unsigned-declared":
      return {
        status: requireSigned ? "fail" : "warn",
        text: `${name}signs no releases${requireSigned ? " — the site requires signed releases (requireSigned)" : ""}`,
      };
    case "ahead-of-release":
      return { status: "warn", text: `${name}${r.reason ?? "ahead of its last verified release"}` };
    default:
      return { status: "fail", text: `${name}NOT a verified release on ${r.branch} — ${r.reason ?? "unknown"}` };
  }
}

export function checkSignatureStatus(configDir: string, now: number): CheckResult {
  const s = readSignatures(configDir);
  if (!s) return { name: "signature-status", status: "skip", detail: "no signature check yet — it runs after every repository sync" };
  const rows: CheckRow[] = [];
  for (const r of s.repositories) {
    rows.push(rowFor(r, s.requireSigned === true));
    for (const k of r.expiringKeys ?? []) {
      rows.push({ status: "warn", text: `${r.name.padEnd(16)}signing key ${k.principal} valid until ${k.validBefore} — enrol its successor` });
    }
  }
  const days = Math.floor((now - Date.parse(s.generated)) / 86_400_000);
  if (days > STALE_DAYS) rows.push({ status: "warn", text: `the last check is ${days} days old — no repository sync since` });
  const status = rows.reduce<CheckStatus>((w, r) => (RANK[r.status] > RANK[w] ? r.status : w), "pass");
  const count = (st: RepoSignature["status"]): number => s.repositories.filter((r) => r.status === st).length;
  const detail =
    `${s.repositories.length} repositor${s.repositories.length === 1 ? "y" : "ies"}: ${count("verified")} verified, ` +
    `${count("unsigned-declared") + count("unsigned-unstable")} unsigned, ${count("ahead-of-release")} ahead, ${count("failed")} failed` +
    (s.requireSigned ? " — requireSigned" : "");
  // Only the rows that need a look; a verified or unstable repository is in the count.
  return { name: "signature-status", status, detail, rows: rows.filter((r) => r.status === "warn" || r.status === "fail") };
}
