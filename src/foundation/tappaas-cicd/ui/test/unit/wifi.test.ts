// wifi.test.ts — the WiFi passphrase through the console (#889): POST
// /secrets/wlan hands the passphrase to `ap-manager ssid set-passphrase <ssid>`
// on stdin (a fake runner here), so ap-manager stores it and marks the SSID for
// the next reconcile. The passphrase is never in argv, the console's log,
// Activity or the answer; ap-manager's refusal comes back without it; and the
// `ssids` read is `ap-manager ssid list --json`.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig } from "../../src/access";
import { ExecResult } from "../../../lib/ts/src/exec";
import { Jobs } from "../../src/jobs";
import { Reads } from "../../src/reads";
import { secretCommand, writeSecret } from "../../src/secrets";
import { ConsoleServer } from "../../src/server";
import { gateHeaders, testGate } from "./gate-fixture";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

async function main(): Promise<void> {
  const PASS = "correct horse battery";

  // ── secrets.ts: wlan is ap-manager's, not written by the console ──
  const cmd = secretCommand("wlan", { ssid: "rossen-home", passphrase: PASS });
  check(typeof cmd === "object" && cmd !== null && JSON.stringify(cmd.args) === '["ssid","set-passphrase","rossen-home"]' && cmd.bin === "ap-manager", "wlan: ap-manager ssid set-passphrase <ssid>");
  check(typeof cmd === "object" && cmd !== null && cmd.input === `${PASS}\n` && !cmd.args.join(" ").includes(PASS), "…the passphrase on stdin, never in argv");
  check(typeof secretCommand("wlan", { ssid: "a=b", passphrase: PASS }) === "string", "an SSID with '=' is refused before anything runs");
  check(typeof secretCommand("wlan", { ssid: "x", passphrase: "short" }) === "string", "a passphrase under 8 characters is refused");
  check(typeof secretCommand("wlan", { ssid: "x", passphrase: "tab\there!" }) === "string", "…and one with a control character");
  check(secretCommand("unifi", { url: "https://x", username: "a", password: "b" }) === null, "unifi is still the console's to write");
  check(!writeSecret("/nonexistent", "wlan", { ssid: "x", passphrase: PASS }).ok, "writeSecret refuses wlan: only ap-manager writes it");

  // ── the route ──
  const dir = mkdtempSync(join(tmpdir(), "console-wifi-"));
  writeFileSync(join(dir, "identity.json"), "{}");
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "tok"), identityFile: join(dir, "identity.json"), trustLocalHeaders: false, gate: testGate() };
  const site = fakeSite();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7 });
  const jobs = new Jobs({ stateDir: join(dir, "state"), configDir: dir, manifests: () => ({ byBin: new Map(), errors: [], loadedAt: "" }), stream: async () => ({ rc: 0, ran: true, error: null }), run: site.run });
  const ran: { bin: string; args: string[]; input: string }[] = [];
  let answer: ExecResult = { rc: 0, stdout: "[Info] passphrase for 'rossen-home' stored\n", stderr: "", ran: true };
  const logs: string[] = [];
  const srv = new ConsoleServer({
    access, webDir: null, mgmtDomain: "mgmt.internal", version: "t", log: (l) => logs.push(l), home: dir,
    runStdin: async (bin, args, input) => {
      ran.push({ bin, args, input });
      return answer;
    },
  }, reads, jobs);
  const call = async (method: string, url: string, groups: string, body?: unknown) => {
    let out = "";
    const res = { statusCode: 200, headersSent: false, setHeader: () => undefined, write: () => true, end: (d?: string) => ((out = d ?? ""), true), on: () => res };
    const req = {
      method,
      url,
      headers: { ...gateHeaders("lars", groups), "content-type": "application/json" },
      socket: { remoteAddress: "10.0.0.1", destroy: () => undefined },
      on: (ev: string, cb: (c?: unknown) => void) => {
        if (ev === "data" && body !== undefined) cb(Buffer.from(JSON.stringify(body)));
        if (ev === "end") cb();
        return req;
      },
    };
    await srv.handle(req as unknown as IncomingMessage, res as unknown as ServerResponse);
    return { status: res.statusCode, body: out };
  };

  let r = await call("POST", "/api/v1/secrets/wlan", "installer", { ssid: "rossen-home", passphrase: PASS });
  check(r.status === 200, `the Installer sets it: 200 (${r.status} ${r.body.slice(0, 120)})`);
  check(ran.length === 1 && ran[0].bin === "ap-manager" && JSON.stringify(ran[0].args) === '["ssid","set-passphrase","rossen-home"]' && ran[0].input === `${PASS}\n`, "…through ap-manager, the passphrase on stdin");
  check(!r.body.includes(PASS) && !logs.join("\n").includes(PASS), "…never in the answer or the console's log");
  check(logs.some((l) => l.includes("secret wlan set by lars") && l.includes("ssid set-passphrase rossen-home")), "…the log names the SSID and the verb");
  const act = jobs.list().find((x) => x.verb === "secret wlan");
  const out = act ? JSON.stringify(jobs.get(act.id)) : "";
  check(!!act && out.includes("ap-manager ssid set-passphrase rossen-home") && !out.includes(PASS), "…Activity records it by SSID and verb, without the passphrase");

  answer = { rc: 1, stdout: "", stderr: `\x1b[01;31m[Error]\x1b[m SSID 'nosuch' not found — declare it first: ap-manager ssid add 'nosuch' --zone <zone> --security wpa2-personal ${PASS}\n`, ran: true };
  r = await call("POST", "/api/v1/secrets/wlan", "installer", { ssid: "nosuch", passphrase: PASS });
  check(r.status === 400 && r.body.includes("not found — declare it first"), "ap-manager's refusal comes back as the form's error");
  check(!r.body.includes(PASS), "…with the passphrase cut out of it, whatever the verb printed");

  const before = ran.length;
  r = await call("POST", "/api/v1/secrets/wlan", "installer", { ssid: "rossen-home", passphrase: "short" });
  check(r.status === 400 && ran.length === before, "a short passphrase: 400, nothing run");
  r = await call("POST", "/api/v1/secrets/wlan", "users", { ssid: "rossen-home", passphrase: PASS });
  check(r.status === 403 && ran.length === before, "a member of users: 403, nothing run");

  // ── the read ──
  const s = await reads.ssids.get();
  check(Array.isArray(s.value) && site.calls.some((c) => c === "ap-manager ssid list --json"), "the ssids read is ap-manager ssid list --json");

  rmSync(dir, { recursive: true, force: true });
  done("wifi");
}

void main();
