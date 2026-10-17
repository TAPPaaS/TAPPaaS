// signatures.test.ts — the signature-status gate (ADR-033 D10): each status's
// row and severity, requireSigned turning an unsigned repository into a failure,
// an expiring key, a stale check, and no check at all.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkSignatureStatus, RepoSignature } from "../../src/signatures";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const NOW = Date.parse("2026-10-17T12:00:00Z");
function dir(repos: RepoSignature[], requireSigned = false, generated = "2026-10-17T03:00:00Z"): string {
  const d = mkdtempSync(join(tmpdir(), "hm-sig-"));
  mkdirSync(join(d, "sbom"));
  writeFileSync(join(d, "sbom", "signatures.json"), JSON.stringify({ generated, requireSigned, repositories: repos }));
  return d;
}
const verified: RepoSignature = { name: "TAPPaaS", branch: "stable", channel: "production", status: "verified", tag: "v2.4", signer: "lars@tappaas.org" };
const unstable: RepoSignature = { name: "Dev", branch: "main", channel: "unstable", status: "unsigned-unstable" };
const unsigned: RepoSignature = { name: "Community", branch: "stable", channel: "production", status: "unsigned-declared" };

{
  const r = checkSignatureStatus(mkdtempSync(join(tmpdir(), "hm-sig-")), NOW);
  check(r.status === "skip", "no signatures.json — skip");
}
{
  const r = checkSignatureStatus(dir([verified, unstable]), NOW);
  check(r.status === "pass", "verified + unstable — pass");
  check(r.detail.startsWith("2 repositories: 1 verified, 1 unsigned"), `detail counts them (${r.detail})`);
  check((r.rows ?? []).length === 0, "no rows when nothing needs a look");
}
{
  const r = checkSignatureStatus(dir([verified, unsigned]), NOW);
  check(r.status === "warn", "an unsigned repository warns by default");
  check(r.rows?.[0]?.text.includes("Community") === true && r.rows[0].text.includes("signs no releases"), "…and names it");
}
{
  const r = checkSignatureStatus(dir([verified, unsigned], true), NOW);
  check(r.status === "fail", "…and fails under requireSigned");
  check(r.detail.endsWith("requireSigned"), "detail says requireSigned");
}
{
  const ahead: RepoSignature = { ...verified, status: "ahead-of-release", reason: "3 commit(s) past the last verified release" };
  const r = checkSignatureStatus(dir([ahead]), NOW);
  check(r.status === "warn" && r.rows?.[0]?.text.includes("3 commit(s)") === true, "ahead-of-release warns with the reason");
}
{
  const bad: RepoSignature = { ...verified, status: "failed", tag: undefined, reason: "abc123 is not a release tag" };
  const r = checkSignatureStatus(dir([bad]), NOW);
  check(r.status === "fail" && r.rows?.[0]?.text.includes("NOT a verified release") === true, "failed fails, with the reason");
}
{
  const exp: RepoSignature = { ...verified, expiringKeys: [{ principal: "erik@tappaas.org", validBefore: "20261201" }] };
  const r = checkSignatureStatus(dir([exp]), NOW);
  check(r.status === "warn" && r.rows?.[0]?.text.includes("erik@tappaas.org valid until 20261201") === true, "an expiring key warns");
}
{
  const r = checkSignatureStatus(dir([verified], false, "2026-10-01T03:00:00Z"), NOW);
  check(r.status === "warn" && r.rows?.[0]?.text.includes("16 days old") === true, "a stale check warns");
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
