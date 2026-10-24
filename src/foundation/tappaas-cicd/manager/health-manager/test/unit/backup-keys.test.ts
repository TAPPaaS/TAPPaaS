// backup-keys.test.ts — the backup-keys gate: `backup-manager key status --json`
// says whether the last key stick holds the escrow's keys as they are now; a
// stick that does not, or none at all, is a WARN that stays until one is
// written. Offline: backupKeysResult over status documents, and checkBackupKeys
// against a fake backup-manager.

import { chmodSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { backupKeysResult, checkBackupKeys } from "../../src/checks";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const stick = { fingerprint: "a".repeat(64), written: "2026-10-20T10:00:00+02:00", label: "tappaas1: SanDisk Cruzer" };

const cur = backupKeysResult({ escrowed: 5, fingerprint: "a".repeat(64), stick, current: true });
check(cur.status === "pass", "a stick holding the keys as they are passes");
check(/2026-10-20/.test(cur.detail) && /5 key/.test(cur.detail), "it names the stick's date and the key count");

const stale = backupKeysResult({ escrowed: 6, fingerprint: "b".repeat(64), stick, current: false });
check(stale.status === "warn", "keys changed after the stick: WARN, never FAIL");
check(/2026-10-20/.test(stale.detail) && /key export --usb/.test(stale.detail), "it names the stale stick and the command that fixes it");
check(stale.findings?.[0]?.subject?.kind === "module" && stale.findings[0].subject.name === "backup", "the finding is on the backup module");

const never = backupKeysResult({ escrowed: 3, fingerprint: "c".repeat(64), stick: null, current: false });
check(never.status === "warn" && /no key stick/.test(never.detail), "no stick ever written: WARN");

check(backupKeysResult({ escrowed: 0, fingerprint: null, stick: null, current: true }).status === "skip", "no keys escrowed: skip");
check(backupKeysResult({}).status === "skip", "no document: skip");
check(backupKeysResult(null).status === "skip", "null: skip");

// checkBackupKeys against a fake backup-manager.
const dir = mkdtempSync(join(tmpdir(), "hm-bk-"));
const fake = join(dir, "backup-manager");
writeFileSync(fake, `#!/usr/bin/env bash
[[ "$1 $2" == "key status" ]] || exit 2
echo '{"escrowed":2,"fingerprint":"${"d".repeat(64)}","stick":null,"current":false}'
`);
chmodSync(fake, 0o755);
const prev = process.env.BACKUP_MANAGER_BIN;
process.env.BACKUP_MANAGER_BIN = fake;
const live = checkBackupKeys(dir);
check(live.status === "warn" && /no key stick/.test(live.detail), "checkBackupKeys reads backup-manager key status --json");
process.env.BACKUP_MANAGER_BIN = join(dir, "missing");
check(checkBackupKeys(dir).status === "skip", "no backup-manager: skip");
if (prev === undefined) delete process.env.BACKUP_MANAGER_BIN;
else process.env.BACKUP_MANAGER_BIN = prev;

console.log(`backup-keys: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
