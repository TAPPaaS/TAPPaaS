// manifest.test.ts — the verb manifest (ADR-034 D4, Testing T2): what
// lib/ts help.ts renders for `--help --json` (the defaults and the marks a
// HelpSpec carries), the console's loader, and the argv check every job passes:
// a verb a manifest declares, with options the verb declares, nothing else.
// The bash controllers' declared verbs are checked against their own CLI_SPEC.

import { readFileSync } from "fs";
import { join } from "path";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { Manifests, applyArgv, baseArgv, loadManifests, previewArgv, validateArgv } from "../../src/manifest";
import { Runner } from "../../src/run";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const SPEC: HelpSpec = {
  name: "demo-manager",
  version: "1",
  tagline: "a manager for the tests",
  verbs: [
    { usage: "list [--json]" },
    { usage: "show <module> [--json]" },
    { usage: "test <module> [--deep] [--vmid ID]", options: [["--deep", "The deep suite."], ["--vmid ID", "A VM."]] },
    { usage: "validate [--force]", options: [["--force", "Rewrite the cache."]] },
    { usage: "scan [--deep]", effect: "read", options: [["--deep", "Every image."]], writeWhen: [["--deep", "pulls every image again"]] },
    { usage: "reconcile [<module>] [--apply] [--allow-disruption]", options: [["--apply", "Apply."], ["--allow-disruption", "Reboot it if needed."]] },
    { usage: "add <name> [--check] [--mode a|b]", options: [["--check", "Show; change nothing."], ["--mode a|b", "How."]] },
    { usage: "modify <module> --set field=value...", options: [["--set field=value", "Change a field (repeatable)."], ["--dry-run", "The pre-gate only."]] },
    { usage: "delete <module> [--remove] [--yes]", options: [["--remove", "Remove its config."], ["--yes", "No prompt."]] },
    { usage: "suspend <module>", effect: { noPreview: "stops the guest" } },
    { usage: "wgvpn <setup|add-peer|remove-peer|list> [options]", anyOption: true, readWhen: ["list"] },
    { usage: "key list | export|import --file DIR", verb: "key", name: "key", destructive: ["import"], readWhen: ["list"], options: [["--file DIR", "Where."]] },
    { usage: "snapshot <module> [--restore N]", options: [["--restore N", "Roll back N."]], destructive: ["--restore"] },
    { usage: "forget-disk <module> <disk>", object: { positional: "disk", within: ["module"] } },
  ],
  common: [["--config-dir DIR", "Config root."], ["--json", "JSON."]],
  hidden: ["--variant <env>"],
};

const m = renderManifest(SPEC);
const v = (name: string) => m.verbs.find((x) => x.verb === name)!;

// ── what --help --json renders ────────────────────────────────────────
check(m.manifest === 1 && m.name === "demo-manager" && m.verbs.length === SPEC.verbs.length, "one manifest entry per declared verb");
check(v("list").effect === "read" && v("list").preview.kind === "read", "a reading verb (list) is a read");
check(v("show").positionals.length === 1 && v("show").positionals[0].name === "module" && !v("show").positionals[0].optional, "positionals come from the usage line");
const rec = v("reconcile");
check(rec.preview.kind === "apply-flag" && rec.effect === "write", "a verb with --apply previews without it");
check(rec.disruptions.some((d) => d.flag === "--allow-disruption" && d.consequence === "Reboot it if needed."), "--allow-disruption is a disruption, with its description as the consequence");
check(v("add").preview.kind === "dry-run-flag" && (v("add").preview as { flag: string }).flag === "--check", "a verb with --check previews with it");
check(JSON.stringify(v("add").options.find((o) => o.flag === "--mode")?.choices) === '["a","b"]', "an option's fixed values are its choices");
check(renderManifest({ name: "x", version: "1", tagline: "t", verbs: [{ usage: "set <n> [--ports <a,b>]", options: [["--ports <a,b>", "Ports."]] }] }).verbs[0].options[0].arg === "<a,b>", "a placeholder with a comma stays whole (<a,b>)");
check(v("modify").preview.kind === "dry-run-flag" && v("modify").options.find((o) => o.flag === "--set")?.repeatable === true, "--set field=value... is repeatable; --dry-run previews");
check(v("delete").destructive && v("delete").preview.kind === "none", "delete is destructive by its name and has no dry run");
check(v("suspend").preview.kind === "none" && (v("suspend").preview as { touches: string }).touches === "stops the guest", "a declared no-preview carries what it touches");
check(v("wgvpn").destructiveWhen.includes("remove-peer") && v("wgvpn").readWhen.includes("list") && v("wgvpn").open, "remove-peer makes wgvpn destructive, list makes it a read");
check(v("key").destructiveWhen.join() === "import" && !v("key").destructive, "key import is destructive by its mark");
check(v("snapshot").destructiveWhen.includes("--restore"), "an option can be the destructive mark");
check(!v("list").options.some((o) => o.flag === "--variant"), "a hidden legacy spelling is not in the manifest");
check(JSON.stringify(v("forget-disk").object) === '{"positional":"disk","within":["module"]}', "a verb names the positional its object is, and what it is within (#855)");
check(!("object" in v("delete")) && m.verbs.filter((x) => "object" in x).length === 1, "…a verb that does not declare one has no object field: --help --json as before");
check(v("test").effect === "read" && v("test").preview.kind === "read" && JSON.stringify(v("test").writeWhen) === '[{"flag":"--deep","touches":"runs the deep suite: creates and removes zztest guests"}]', "test is a read; --deep makes a call a write with no dry run, and says what it touches");
check(v("validate").writeWhen.length === 1 && v("validate").writeWhen[0].flag === "--force" && v("validate").writeWhen[0].touches === "Rewrite the cache.", "a disruption option on a read verb is a write mark too, with its description");
check(v("scan").writeWhen[0].touches === "pulls every image again", "a declared writeWhen says what it touches");
check(v("reconcile").writeWhen.length === 0 && v("list").writeWhen.length === 0, "a write verb, and a read verb with no such option, carry none");

// ── the loader and the argv check (T2) ────────────────────────────────
async function main(): Promise<void> {
  const run: Runner = async (bin, args) =>
    bin === "demo-manager" && args.join(" ") === "--help --json"
      ? { rc: 0, stdout: JSON.stringify(m), stderr: "", ran: true }
      : { rc: 1, stdout: "", stderr: "no", ran: true };
  const bash = join(FIX, "..", "..", "manifest", "bash-verbs.json");
  const ms: Manifests = await loadManifests(run, bash, ["demo-manager", "ghost-manager"]);
  check(ms.byBin.has("demo-manager") && ms.byBin.has("switch-controller") && ms.byBin.has("ap-controller"), "the managers' and the bash verbs' manifests are loaded");
  check(ms.errors.length === 1 && ms.errors[0].bin === "ghost-manager", "a manager that does not answer is reported, not fatal");

  const ok = (argv: string[]) => validateArgv(ms, argv);
  const bad = (argv: string[], needle: string) => {
    const r = validateArgv(ms, argv);
    return !r.ok && r.reason.includes(needle);
  };
  check(ok(["demo-manager", "reconcile", "immich", "--apply"]).ok, "a declared verb with declared options passes");
  check(bad(["rm", "-rf", "/"], "not a manager"), "a binary without a manifest is refused");
  check(bad(["demo-manager", "frobnicate", "x"], "not a verb"), "an undeclared verb is refused (T2)");
  check(bad(["demo-manager", "reconcile", "--purge"], "unknown option '--purge'"), "an undeclared option is refused before any job exists (T2)");
  check(bad(["demo-manager", "list", "--variant", "x"], "unknown option"), "a hidden legacy spelling is refused");
  check(bad(["demo-manager", "list", "--config-dir", "/tmp/x"], "not something a job carries"), "--config-dir is never a job's");
  check(bad(["demo-manager", "show", "a", "--help"], "not something a job carries"), "a help request is not a job");
  check(bad(["demo-manager", "add", "x", "--mode", "c"], "one of a, b"), "a value outside an option's choices is refused");
  check(bad(["demo-manager", "add", "x", "--mode"], "needs a value"), "an option without its value is refused");
  check(bad(["demo-manager", "show"], "expected <module>"), "a missing positional is refused");
  check(bad(["demo-manager", "show", "a", "b"], "unexpected argument 'b'"), "a surplus positional is refused");
  check(bad(["demo-manager", "show", "a\nb"], "control character"), "an argument with a newline is refused");
  check(ok(["demo-manager", "wgvpn", "add-peer", "--name", "laptop", "--pubkey", "k="]).ok, "an open verb forwards its options");

  const del = ok(["demo-manager", "delete", "deconz-test", "--remove"]);
  check(del.ok && del.destructive && del.object === "deconz-test", "delete: destructive, the typed name is the module");
  const wl = ok(["demo-manager", "wgvpn", "list"]);
  check(wl.ok && wl.read && !wl.destructive, "wgvpn list is a read");
  const wr = ok(["demo-manager", "wgvpn", "remove-peer", "--name", "laptop"]);
  check(wr.ok && wr.destructive && wr.object === "laptop", "wgvpn remove-peer: destructive, the object is the peer's --name");
  const ki = ok(["demo-manager", "key", "import", "--file", "/k"]);
  check(ki.ok && ki.destructive, "key import is destructive");
  const tf = ok(["demo-manager", "test", "immich"]);
  check(tf.ok && tf.read && tf.preview.kind === "read", "test <module> is a read");
  const td = ok(["demo-manager", "test", "immich", "--deep", "--vmid", "9"]);
  check(td.ok && !td.read && !td.destructive && td.preview.kind === "none" && /zztest/.test((td.preview as { touches: string }).touches), "test --deep is a write with no dry run: creates and removes guests");
  check(td.ok && previewArgv(td) === null && applyArgv(td).join(" ") === "demo-manager test immich --deep --vmid 9" && baseArgv(td).join(" ") === applyArgv(td).join(" "), "…its preview runs nothing; apply runs the argv as given");
  const vf = ok(["demo-manager", "validate", "--force"]);
  check(vf.ok && !vf.read && vf.preview.kind === "none", "validate --force is a write too");

  // ── preview and apply argv (T3) ──
  const r = ok(["demo-manager", "reconcile", "immich", "--apply"]);
  if (r.ok) {
    check(previewArgv(r)?.join(" ") === "demo-manager reconcile immich", "apply-flag: the preview is the argv without --apply");
    check(applyArgv(r).join(" ") === "demo-manager reconcile immich --apply", "…and the apply is the preview plus --apply");
    const r2 = ok(["demo-manager", "reconcile", "immich"]);
    check(r2.ok && baseArgv(r2).join(" ") === baseArgv(r).join(" "), "with or without --apply, the base is the same");
  }
  const md = ok(["demo-manager", "modify", "deconz-test", "--set", "memory=2048"]);
  if (md.ok) {
    check(previewArgv(md)?.join(" ") === "demo-manager modify deconz-test --set memory=2048 --dry-run", "dry-run-flag: the preview adds --dry-run");
    check(applyArgv(md).join(" ") === "demo-manager modify deconz-test --set memory=2048", "…and the apply is without it");
  }
  const sp = ok(["demo-manager", "suspend", "x"]);
  check(sp.ok && previewArgv(sp) === null, "no dry run: the preview runs nothing");

  // ── the bash verbs: their keys, and their options against CLI_SPEC ──
  const port = ok(["switch-controller", "update-port", "USW Pro XG 10 PoE", "1", "--type", "device", "--mode", "access", "--zone", "iotCams"]);
  check(port.ok && !port.read && port.verb.preview.kind === "none", "switch-controller update-port: a write with no dry run");
  check(bad(["switch-controller", "update-port", "s", "1", "--mode", "hybrid"], "one of trunk, access"), "…its --mode is trunk or access");
  const swr = ok(["switch-controller", "reconcile", "--apply"]);
  check(swr.ok && previewArgv(swr)?.join(" ") === "switch-controller reconcile", "switch-controller reconcile previews without --apply");
  const ssid = ok(["ap-controller", "ssid", "Nano HD", "add", "home", "--zone", "home"]);
  check(ssid.ok && ssid.verb.verb === "ssid add" && ssid.object === "home", "ap-controller ssid <ap> add <ssid>: a '*' key word takes the AP");
  check(ok(["acme-setup.sh", "--no-save-creds"]).ok, "acme-setup.sh is its own verb (an empty key)");
  check(bad(["switch-controller", "remove-switch", "a", "--force"], "unknown option"), "remove-switch takes no option");
  // #855: the typed name is the object, not the first positional.
  const rp = ok(["switch-controller", "remove-port", "USW Pro XG 10 PoE", "1"]);
  check(rp.ok && rp.destructive && rp.object === "1" && rp.objectLabel === "USW Pro XG 10 PoE:1", "remove-port: the object is the port, shown as <switch>:<port>");
  const lr = ok(["switch-controller", "lag", "remove", "USW Pro XG 10 PoE", "tappaas1-lan", "--apply"]);
  check(lr.ok && lr.destructive && lr.object === "tappaas1-lan" && lr.objectLabel === "USW Pro XG 10 PoE:tappaas1-lan", "lag remove: the object is the aggregate");
  const rs = ok(["switch-controller", "remove-switch", "USW Pro XG 10 PoE"]);
  check(rs.ok && rs.object === "USW Pro XG 10 PoE" && rs.objectLabel === rs.object, "remove-switch: the default, its first positional");
  const fd = ok(["demo-manager", "forget-disk", "immich", "scsi1"]);
  check(fd.ok && fd.object === "scsi1" && fd.objectLabel === "immich:scsi1", "a TypeScript manager's declared object works the same");
  check(del.ok && del.objectLabel === del.object, "an undeclared verb: the label is the typed name");
  check(ok(["switch-controller", "update-port", "s", "2", "--park"]).ok && ok(["switch-controller", "remove-port", "s", "2", "--park-zone", "guest"]).ok, "update-port --park and remove-port --park-zone are declared (#853)");

  const tree = join(FIX, "..", "..", "..", "controller");
  for (const [bin, file] of [["switch-controller", "switch-controller/switch-controller"], ["ap-controller", "ap-controller/ap-controller"]]) {
    const src = readFileSync(join(tree, file), "utf8");
    const spec = /CLI_SPEC=["']([\s\S]*?)["']\n/.exec(src)?.[1] ?? "";
    const ports = /PORT_OPTS='([^']*)'/.exec(src)?.[1] ?? "";
    const declared = new Map<string, Set<string>>();
    for (const line of spec.replace(/\$\{PORT_OPTS\}/g, ports).split("\n")) {
      const mm = /^([a-z* -]+):(.*)$/.exec(line.trim());
      if (!mm) continue;
      const head = mm[1].split(/\s+/)[0];
      const set = declared.get(head) ?? new Set<string>();
      for (const o of mm[2].trim().split(/\s+/).filter((x) => x)) set.add(o.replace(/=$/, ""));
      declared.set(head, set);
    }
    let fine = true;
    for (const vb of ms.byBin.get(bin)!.verbs) {
      const head = vb.keys[0][0];
      const allowed = declared.get(head);
      if (!allowed) {
        fine = false;
        console.log(`    ${bin} ${vb.verb}: not in CLI_SPEC`);
        continue;
      }
      for (const o of vb.options) {
        if (!allowed.has(o.flag)) {
          fine = false;
          console.log(`    ${bin} ${vb.verb}: ${o.flag} not in CLI_SPEC`);
        }
      }
    }
    check(fine, `${bin}: every declared verb and option is in the script's CLI_SPEC`);
  }
  done("manifest");
}

void main();
