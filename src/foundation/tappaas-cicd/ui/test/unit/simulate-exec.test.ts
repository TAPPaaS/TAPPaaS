// simulate-exec.test.ts — the net under a simulated apply (lib/ts exec.ts): with
// TAPPAAS_SIMULATE=1 a command on lib/simulate-mutators.txt is logged and not
// run, a read runs, and a write under the config root is logged and skipped.

import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { writeJsonAtomic } from "../../../lib/ts/src/config-io";
import { cmdbReport } from "../../../lib/ts/src/cmdb";
import { capture, captureResult, isMutator, mutators, stream, streamToFile } from "../../../lib/ts/src/exec";
import { check, done } from "./check";

function logged(fn: () => void): string[] {
  const was = console.error;
  const lines: string[] = [];
  console.error = (...a: unknown[]) => void lines.push(a.join(" "));
  try {
    fn();
  } finally {
    console.error = was;
  }
  return lines;
}

const dir = mkdtempSync(join(tmpdir(), "console-simulate-"));
const mark = join(dir, "ran");

const rules = mutators();
check(rules !== null && rules.some((r) => r.bin === "qm"), "the list is read from lib/simulate-mutators.txt");

const MUTATORS: string[][] = [
  ["pvesh", "set", "/nodes/x"],
  ["pvesh", "create", "/nodes/x/qemu"],
  ["pvesh", "delete", "/nodes/x"],
  ...["start", "stop", "shutdown", "destroy", "set", "clone", "migrate", "snapshot", "rollback"].flatMap((v) => [["qm", v, "100"], ["pct", v, "101"]]),
  ["nixos-rebuild", "switch"],
  ["/run/current-system/sw/bin/nixos-rebuild", "switch"],
  ...["create", "destroy", "set", "snapshot", "rollback"].map((v) => ["zfs", v, "rpool/x"]),
  ["zpool", "create", "tank", "sdb"],
  ["pvesm", "add", "dir", "x"],
  ["vzdump", "100"],
  ["ha-manager", "add", "vm:100"],
  ...["start", "stop", "restart", "enable", "disable"].map((v) => ["systemctl", v, "foo"]),
  ["systemctl", "--no-block", "restart", "foo"],
  ["sudo", "-n", "qm", "stop", "100"],
  ["sudo", "-u", "root", "zfs", "destroy", "a"],
  ["env", "A=1", "qm", "start", "100"],
  ["timeout", "30", "qm", "stop", "100"],
  ["bash", "-c", "cd /tmp && qm stop 100"],
  ["ssh", "-o", "BatchMode=yes", "tappaas@guest", "sudo nixos-rebuild switch"],
  ["ssh", "root@node", "qm", "stop", "100"],
  ["ssh", "root@node", "uptime; qm stop 100"],
  ["ssh", "root@node", "bash -lc 'zfs destroy a/b'"],
  ["ssh", "root@node", "out=$(pct set 101 -onboot 1)"],
];
for (const m of MUTATORS) check(isMutator(m[0], m.slice(1)), `mutator: ${m.join(" ")}`);

const READS: string[][] = [
  ["pvesh", "get", "/nodes"],
  ["qm", "status", "100"],
  ["qm", "list"],
  ["pct", "config", "101"],
  ["zfs", "list"],
  ["zpool", "list", "-H"],
  ["pvesm", "status"],
  ["ha-manager", "status"],
  ["systemctl", "is-active", "foo"],
  ["systemctl", "show", "foo"],
  ["ssh", "root@node", "qm status 100"],
  ["ssh", "-i", "start", "root@node", "uptime"],
  ["sudo", "qm", "list"],
  ["bash", "-c", "zfs list | grep x"],
  ["curl", "-s", "http://x/start"],
  ["jq", "set", "a"],
];
for (const r of READS) check(!isMutator(r[0], r.slice(1)), `runs: ${r.join(" ")}`);
check(isMutator("uptime", [], null), "no list: nothing is taken for a read");

// A stub named qm that leaves a mark.
const qm = join(dir, "qm");
writeFileSync(qm, `#!/bin/sh\necho "$*" >> ${mark}\necho real\n`);
chmodSync(qm, 0o755);

process.env.TAPPAAS_SIMULATE = "1";
const log: string[] = [];
log.push(...logged(() => check(capture(qm, ["stop", "100"]) === "", "capture: empty stdout")));
log.push(...logged(() => {
  const r = captureResult(qm, ["stop", "100"]);
  check(r.rc === 0 && r.ran && r.stdout === "", "captureResult: exit 0, empty");
}));
log.push(...logged(() => check(stream(qm, ["stop", "100"]) === 0, "stream: exit 0")));
log.push(...logged(() => check(streamToFile(qm, ["stop", "100"], join(dir, "out")) === 0, "streamToFile: exit 0")));
check(!existsSync(mark), "the mutator never ran");
check(log.filter((l) => l === `[simulate] ${qm} stop 100`).length === 4, "each is logged as [simulate] <argv>");
check(logged(() => void capture(qm, ["status", "100"])).length === 0 && readFileSync(mark, "utf8") === "status 100\n", "a read runs, and says nothing");
check(capture("echo", ["hello"]) === "hello\n", "an unlisted command runs");

// The config helper: under the config root skipped, elsewhere written.
process.env.TAPPAAS_CONFIG = join(dir, "config");
mkdirSync(join(dir, "config"));
const cfg = join(dir, "config", "site.json");
const lines = logged(() => writeJsonAtomic(cfg, { a: 1 }));
check(!existsSync(cfg) && lines[0] === `[simulate] write ${cfg}`, "writeJsonAtomic under config/: logged, skipped");
writeJsonAtomic(join(dir, "state.json"), { a: 1 });
check(existsSync(join(dir, "state.json")), "writeJsonAtomic elsewhere (the console's state): written");

// The CMDB hears nothing and nothing is spooled.
const out = { r: cmdbReport({ source: "t", kind: "change" }, { socket: join(dir, "none") }) };
check(out.r.off === true && !out.r.spooled && !existsSync(join(dir, "config", ".cmdb-spool")), "cmdbReport: not sent, not spooled");

delete process.env.TAPPAAS_SIMULATE;
writeJsonAtomic(cfg, { a: 1 });
check(existsSync(cfg), "unset: the write happens");
check(capture(qm, ["stop", "100"]) === "real\n", "unset: the mutator runs");

rmSync(dir, { recursive: true, force: true });
done("simulate-exec");
