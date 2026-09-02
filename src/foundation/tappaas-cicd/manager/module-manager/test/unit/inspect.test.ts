// inspect.test.ts — offline unit tests for the read-only inspect report and the
// dependency-service drift check it delegates to (#458).
//
// No cluster, no firewall, no live config: the report builders are pure, the
// service planner takes an injected ServiceFs, and the one test that really
// spawns a verifier writes a throwaway script into a temp dir. Tiny assert
// harness (same style as module.test.ts). Run via the test/unit tsconfig
// (see test.sh).

import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  appliedDefault,
  buildConfigOnlyReport,
  buildVmReport,
  dependsOnOf,
  guestTypeFromDeps,
  parseQmConfig,
  resolveField,
  vmnetParse,
} from "../../src/inspect";
import {
  ServiceCheck,
  ServiceFs,
  buildServiceSection,
  parseDependency,
  planServiceChecks,
  runServiceChecks,
  serviceExitCode,
  serviceSummaryLines,
} from "../../src/services";
import { FakeModuleClient } from "./fake-client";
import { run } from "../../src/main";
import { InspectOptions } from "../../src/types";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}

// Fixtures live in the SOURCE tree (see module.test.ts for the path arithmetic).
const CONFIG =
  process.env.MM_FIXTURES_CONFIG ??
  join(__dirname, "..", "..", "..", "..", "..", "test", "fixtures", "config");

// Report lines as one plain string (colors included — assertions match on text).
function text(lines: { text: string }[]): string {
  return lines.map((l) => l.text).join("\n");
}

// ── 1. dependency coordinate parsing (bash %%:* / ##*: parity) ──────────
{
  check(
    parseDependency("network:rules").provider === "network" &&
      parseDependency("network:rules").service === "rules",
    "parseDependency splits provider:service",
  );
  // A bare provider yields provider === service, exactly as ${dep##*:} did.
  check(
    parseDependency("cluster").provider === "cluster" &&
      parseDependency("cluster").service === "cluster",
    "parseDependency on a bare coordinate yields provider === service",
  );
  check(
    parseDependency("a:b:c").provider === "a" && parseDependency("a:b:c").service === "c",
    "parseDependency takes provider before the FIRST colon, service after the LAST",
  );
}

// ── 2. planServiceChecks classification (injected ServiceFs) ────────────
{
  const fs: ServiceFs = {
    providerDir: (provider) =>
      provider === "ghost"
        ? { module: "ghost", dir: null }
        : { module: provider, dir: `/src/${provider}` },
    // Only network:rules has a verifier in this fake tree.
    exists: (p) => p === "/src/network/services/rules/test-service.sh",
  };
  const checks = planServiceChecks(
    ["network:rules", "network:nat", "ghost:thing"],
    "",
    fs,
  );
  check(checks[0].kind === "checkable", "a dep whose provider ships test-service.sh is checkable");
  check(
    checks[0].script === "/src/network/services/rules/test-service.sh",
    "the checkable dep resolves to <provider>/services/<service>/test-service.sh",
  );
  check(checks[1].kind === "no-script", "a dep whose provider has no test-service.sh is no-script");
  check(checks[2].kind === "provider-missing", "a dep whose provider cannot be located is provider-missing");
}

// ── 3. the environment-aware provider resolution is honoured ────────────
{
  const seen: string[] = [];
  const fs: ServiceFs = {
    providerDir: (provider, environment) => {
      seen.push(`${provider}/${environment}`);
      return { module: provider, dir: `/src/${provider}` };
    },
    exists: () => true,
  };
  planServiceChecks(["network:rules"], "acme", fs);
  check(seen[0] === "network/acme", "the consuming module's environment drives provider resolution (#438)");
}

// ── 4. checks that did NOT run: the summary names what is uncovered ─────
{
  const svc = buildServiceSection(["network:rules", "network:nat"], null);
  check(!svc.checked && svc.lines.length === 0, "an unchecked section contributes no report lines");
  const summary = text(serviceSummaryLines("policyonly", svc));
  check(
    /dependency-service state NOT checked/.test(summary),
    "the unchecked summary says the dependency state was NOT checked",
  );
  check(
    /network:rules/.test(summary) && /network:nat/.test(summary),
    "the unchecked summary NAMES each uncovered dependency",
  );
  check(
    /module-manager test policyonly/.test(summary),
    "the unchecked summary points at the command that does cover it",
  );
  check(
    text(serviceSummaryLines("x", buildServiceSection([], null))) === "",
    "a module with no dependsOn gets no scope note",
  );
}

// ── 5. outcome rendering + exit-code contract ───────────────────────────
{
  const mk = (dep: string): ServiceCheck => ({
    dep,
    provider: dep.split(":")[0],
    service: dep.split(":")[1],
    script: `/src/${dep.replace(":", "/services/")}/test-service.sh`,
    kind: "checkable",
  });

  const clean = buildServiceSection(
    ["network:rules"],
    [{ check: mk("network:rules"), status: "clean", rc: 0, detail: "" }],
  );
  check(
    /network:rules/.test(text(clean.lines)) && /no drift/.test(text(clean.lines)),
    "a clean check renders a no-drift line",
  );
  check(
    clean.drift === 0 && serviceExitCode(clean) === 0,
    "a clean check exits 0",
  );

  const drifted = buildServiceSection(
    ["network:rules"],
    [
      {
        check: mk("network:rules"),
        status: "drift",
        rc: 1,
        detail: "rule 'allow 443' missing from OPNsense",
      },
    ],
  );
  check(/DRIFT/.test(text(drifted.lines)), "a drifted check renders a DRIFT line");
  check(
    /rule 'allow 443' missing/.test(text(drifted.lines)),
    "a drifted check surfaces the verifier's own output",
  );
  check(drifted.drift === 1, "drift is counted");
  // DECISION (#458): drift is a REPORT, not a failure — `list --diff` and the
  // reconcile --deep cascade propagate this rc, so it stays 0.
  check(serviceExitCode(drifted) === 0, "detected drift still exits 0");
  check(
    /reconcile policyonly --apply/.test(text(serviceSummaryLines("policyonly", drifted))),
    "the drift summary points at the converge that fixes it",
  );

  const unknown = buildServiceSection(
    ["network:rules"],
    [{ check: mk("network:rules"), status: "unknown", rc: null, detail: "EACCES" }],
  );
  check(unknown.unknown === 1, "an unrunnable check is counted as unknown");
  // A check that could not RUN leaves the state undetermined — the one condition
  // that fails the verb, like an unreachable Proxmox node.
  check(serviceExitCode(unknown) === 1, "a check that could not run exits 1");

  const skipped = buildServiceSection(
    ["backup:remote"],
    [
      {
        check: { ...mk("backup:remote"), kind: "no-script", script: "" },
        status: "skipped",
        rc: null,
        detail: "no test-service.sh",
      },
    ],
  );
  check(
    /NOT checked \(no test-service.sh\)/.test(text(skipped.lines)),
    "a provider without a verifier is reported as NOT checked, not as clean",
  );
  check(
    /NOT covered/.test(text(serviceSummaryLines("x", skipped))),
    "the summary warns that a verifier-less dependency is not covered",
  );
  check(serviceExitCode(skipped) === 0, "a skipped check does not fail the verb");
}

// ── 6. config-only report (the policy-only module of #458) ──────────────
{
  const cfg = {
    vmname: "policyonly",
    zone0: "acme",
    tier: "app",
    source: "official",
    dependsOn: ["network:rules", "network:nat"],
  };
  check(
    JSON.stringify(dependsOnOf(cfg)) === JSON.stringify(["network:rules", "network:nat"]),
    "dependsOnOf reads the coordinates off a normalized config",
  );

  // Fields identical to git AND no service check → must NOT read as clean.
  const unchecked = buildConfigOnlyReport("policyonly", cfg, cfg);
  const out = text(unchecked.lines);
  check(
    !/no config-vs-git discrepancies found/.test(out),
    "a field-clean policy-only report no longer claims 'no discrepancies found' (#458)",
  );
  check(/Config fields match git/.test(out), "it states the field verdict it actually has");
  check(
    /dependency-service state NOT checked/.test(out) && /network:nat/.test(out),
    "it names the dependency state it did not check",
  );

  // A module with NO dependsOn keeps the historical wording (nothing uncovered).
  const bare = buildConfigOnlyReport("templates", { vmname: "templates" }, { vmname: "templates" });
  check(
    /no config-vs-git discrepancies found/.test(text(bare.lines)),
    "a dependency-less module keeps the original clean summary",
  );

  // Checked + drifted: the drift is reported and folded into the error count.
  const svc = buildServiceSection(
    ["network:rules"],
    [
      {
        check: {
          dep: "network:rules",
          provider: "network",
          service: "rules",
          script: "/src/network/services/rules/test-service.sh",
          kind: "checkable",
        },
        status: "drift",
        rc: 1,
        detail: "2 declared rules missing",
      },
    ],
  );
  const checked = buildConfigOnlyReport("policyonly", cfg, cfg, svc);
  check(
    /DRIFT/.test(text(checked.lines)) && /2 declared rules missing/.test(text(checked.lines)),
    "a checked policy-only report surfaces dependency-service drift",
  );
  check(checked.errors === 1, "service drift is folded into the report's error count");
}

// ── 7. the VM three-way path carries the same section ───────────────────
{
  const cfg = {
    vmname: "policyvm",
    vmid: 42,
    node: "tappaas1",
    dependsOn: ["network:rules"],
  };
  const base = {
    module: "policyvm",
    vmid: "42",
    cfg,
    git: cfg,
    zones: null,
    actual: {},
    vmStatus: "running",
    actualNode: "tappaas1",
  };
  const unchecked = buildVmReport(base);
  check(
    /VM inspection passed — no config\/VM field discrepancies found/.test(text(unchecked.lines)),
    "a field-clean VM report scopes its verdict to fields when the services were not checked",
  );
  check(
    /dependency-service state NOT checked/.test(text(unchecked.lines)),
    "the VM path names its uncovered dependency state too",
  );

  const svcClean = buildServiceSection(
    ["network:rules"],
    [
      {
        check: {
          dep: "network:rules",
          provider: "network",
          service: "rules",
          script: "/s/test-service.sh",
          kind: "checkable",
        },
        status: "clean",
        rc: 0,
        detail: "",
      },
    ],
  );
  const clean = buildVmReport({ ...base, svc: svcClean });
  check(
    /VM inspection passed — no discrepancies found/.test(text(clean.lines)),
    "with the services checked and clean, the VM verdict is unqualified again",
  );
  check(
    /1 dependency service\(s\) report no drift/.test(text(clean.lines)),
    "the VM report states how many dependency services were verified",
  );

  // #526: node drift — the VM runs on a node other than config.node (a migrate
  // or HA failover deliberately leaves .node unchanged) — is reported as an
  // ordinary node drift row (config vs actual) and counted as an error, the
  // same as any other actual-vs-config field. (The runInspect fetch path,
  // fixed alongside, now reads `qm config` from actualNode so this row is even
  // reachable instead of the whole report dying with "Failed to get VM config".)
  const nodeDrift = buildVmReport({ ...base, actualNode: "tappaas2" });
  const ndText = text(nodeDrift.lines).replace(/\[[0-9;]*m/g, "");
  check(
    /node\s+tappaas1\s+\S*\s*tappaas1\s+tappaas2/.test(ndText) ||
      (/node/.test(ndText) && /tappaas1/.test(ndText) && /tappaas2/.test(ndText)),
    "#526: node change shows as a node drift row (config tappaas1 vs actual tappaas2)",
  );
  check(
    nodeDrift.errors === buildVmReport(base).errors + 1,
    "#526: node drift counts as an error, like any actual-vs-config field",
  );
}

// ── 7b. #550: schema-driven defaults, <angle brackets>, .orig 3-way ─────
{
  // A trimmed module-fields.json .fields: real defaults gated by usedBy, plus a
  // "<computed>" placeholder (never applied) and a section field for network:proxy.
  const schema = {
    cputype: { default: "host", usedBy: ["cluster:vm"] },
    cores: { default: 2, usedBy: ["cluster:vm", "cluster:lxc"] },
    memory: { default: 4096, usedBy: ["cluster:vm", "cluster:lxc"] },
    vmname: { default: "<computed from module name + environment>", usedBy: ["cluster:vm"] },
    proxyPort: { default: 80, usedBy: ["network:proxy"] },
    status: { default: "Development", usedBy: ["general"] },
  };

  // ── pure resolver ──
  check(appliedDefault("cputype", ["cluster:vm"], schema) === "host",
    "#550: a usedBy-matched default applies (cputype→host for cluster:vm)");
  check(appliedDefault("cputype", ["cluster:lxc"], schema) === "",
    "#550: a default whose usedBy does not match the deps does NOT apply (cputype on LXC)");
  check(appliedDefault("proxyPort", ["cluster:vm"], schema) === "",
    "#550: a section default only applies when the module declares that dependency");
  check(appliedDefault("proxyPort", ["network:proxy"], schema) === "80",
    "#550: a dependsOn-section field defaults in for a module that declares it");
  check(appliedDefault("vmname", ["cluster:vm"], schema) === "",
    "#550: a '<computed>' placeholder default is never applied");
  check(appliedDefault("status", [], schema) === "Development",
    "#550: a usedBy:general default applies regardless of deps");
  check(resolveField({ cputype: "kvm64" }, "cputype", ["cluster:vm"], schema).defaulted === false,
    "#550: a declared value is used verbatim (not defaulted)");
  check(resolveField({}, "cputype", ["cluster:vm"], schema).value === "host" &&
    resolveField({}, "cputype", ["cluster:vm"], schema).defaulted === true,
    "#550: an unset field resolves to the schema default, flagged defaulted");

  // ── table rendering ──
  const strip = (r: { lines: { text: string }[] }): string =>
    text(r.lines).replace(/\[[0-9;]*m/g, "");
  const base = {
    module: "demo",
    vmid: "410",
    cfg: { vmname: "demo", vmid: 410, node: "tappaas1", dependsOn: ["cluster:vm"] },
    git: null,
    zones: null,
    vmStatus: "running",
    actualNode: "tappaas1",
    schema,
  };

  // Unset cputype → Desired '<host>' (angle-bracketed default), and since Actual
  // is host too, no drift.
  const matching = buildVmReport({
    ...base,
    actual: parseQmConfig(["name: demo", "cores: 2", "cpu: host"].join("\n")),
  });
  check(/cputype\s+.*<host>\s+host/.test(strip(matching)),
    "#550: an unset cputype renders Desired '<host>' (bracketed default), not '-'");
  check(matching.errors === 0, "#550: actual matching the defaulted desired is no drift");

  // Actual differs from the default → drift (the update path would qm-set it).
  const drifting = buildVmReport({
    ...base,
    actual: parseQmConfig(["name: demo", "cores: 2", "cpu: x86-64-v2"].join("\n")),
  });
  check(drifting.errors >= 1, "#550: actual differing from the defaulted desired reports drift");

  // Without a schema, behaviour is unchanged (no defaults, no brackets).
  const noSchema = buildVmReport({ ...base, schema: undefined,
    actual: parseQmConfig(["name: demo", "cpu: host"].join("\n")) });
  check(!/<host>/.test(text(noSchema.lines)),
    "#550: no schema → no defaulting (back-compat, literal values only)");

  // ── .orig 3-way (on `node`, which always renders): an install-time override
  //    is annotated, not flagged. cfg node=tappaas2 ≠ orig/release node=tappaas1.
  const overridden = buildVmReport({
    module: "demo", vmid: "410",
    cfg: { vmname: "demo", vmid: 410, node: "tappaas2", dependsOn: ["cluster:vm"] },
    git: { vmname: "demo", vmid: 410, node: "tappaas1", dependsOn: ["cluster:vm"] }, // release says tappaas1
    orig: { vmname: "demo", vmid: 410, node: "tappaas1", dependsOn: ["cluster:vm"] }, // pre-image said tappaas1
    zones: null,
    actual: parseQmConfig(["name: demo"].join("\n")),
    vmStatus: "running", actualNode: "tappaas2", schema,
  });
  check(/not tracking release state on purpose/.test(strip(overridden)),
    "#550: a field overwritten at install (desired≠orig) is annotated as intentional");
  check(overridden.warnings === 0,
    "#550: the intentional override does not count as config drift (yellow suppressed)");

  // Same release divergence but desired==orig → ordinary config drift (yellow),
  // NOT annotated (the operator did not override; release moved under them).
  const tracked = buildVmReport({
    module: "demo", vmid: "410",
    cfg: { vmname: "demo", vmid: 410, node: "tappaas2", dependsOn: ["cluster:vm"] },
    git: { vmname: "demo", vmid: 410, node: "tappaas1", dependsOn: ["cluster:vm"] },
    orig: { vmname: "demo", vmid: 410, node: "tappaas2", dependsOn: ["cluster:vm"] }, // pre-image already tappaas2
    zones: null,
    actual: parseQmConfig(["name: demo"].join("\n")),
    vmStatus: "running", actualNode: "tappaas2", schema,
  });
  check(tracked.warnings >= 1 && !/not tracking release/.test(strip(tracked)),
    "#550: desired==orig but ≠release is ordinary config drift (yellow), not annotated");
}

// ── 7b. the LXC guest path reads pct-shaped keys (#465) ────────────────
{
  check(
    guestTypeFromDeps({ dependsOn: ["cluster:lxc", "backup:vm"] }) === "lxc",
    "a cluster:lxc module falls back to the pct path",
  );
  check(
    guestTypeFromDeps({ dependsOn: ["cluster:vm", "cluster:ha"] }) === "qemu" &&
      guestTypeFromDeps({ dependsOn: ["backup:vm"] }) === "qemu" &&
      guestTypeFromDeps({}) === "qemu",
    "cluster:vm, cluster:ha and a module with no cluster:* dep all stay on qm",
  );

  // Verbatim `pct config 312` output for the vllm-amd container (#465): an LXC
  // names the guest `hostname`, keeps its root volume in `rootfs` (no disk
  // bus), carries the MAC as hwaddr=, and has no bios/cpu key at all.
  const actual = parseQmConfig(
    [
      "arch: amd64",
      "cores: 24",
      "features: nesting=1",
      "hostname: vllm-amd",
      "memory: 47104",
      "net0: name=eth0,bridge=lan,hwaddr=02:C5:EC:06:CD:22,ip=dhcp,tag=200,type=veth",
      "onboot: 1",
      "ostype: debian",
      "rootfs: tanka1:subvol-312-disk-0,size=32G",
      "swap: 0",
    ].join("\n"),
  );
  check(
    vmnetParse(actual.net0, "mac") === "02:C5:EC:06:CD:22" &&
      vmnetParse(actual.net0, "bridge") === "lan" &&
      vmnetParse(actual.net0, "tag") === "200",
    "vmnetParse reads the LXC hwaddr= NIC form as well as the QEMU model= one",
  );

  const cfg = {
    vmname: "vllm-amd",
    vmid: 312,
    node: "tappaas2",
    cores: 24,
    memory: 47104,
    diskSize: "32G",
    bridge0: "lan",
    mac0: "02:C5:EC:06:CD:22",
    dependsOn: ["cluster:lxc"],
  };
  const lxc = text(
    buildVmReport({
      module: "vllm-amd",
      vmid: "312",
      cfg,
      git: cfg,
      zones: null,
      actual,
      vmStatus: "running",
      actualNode: "tappaas2",
      guest: "lxc",
    }).lines,
  );
  check(
    /vmname\s+vllm-amd\s+.*vllm-amd.*vllm-amd/.test(lxc.replace(/\u001b\[[0-9;]*m/g, "")),
    "the LXC report fills vmname from `hostname`, not the absent `name` key",
  );
  check(/diskSize.*32G/.test(lxc), "the LXC report reads diskSize out of rootfs");
  check(/mac0.*02:C5:EC:06:CD:22/.test(lxc), "the LXC report reads mac0 out of hwaddr=");
  check(!/seabios/.test(lxc), "a container is never given a fabricated seabios firmware");

  // A container with a bios in config: the empty Actual cell must NOT read as
  // drift — the whole point of not defaulting to seabios. Compared against the
  // same report without the bios field, so only the bios row's contribution is
  // measured (the fixture's other rows drift or not on their own merits).
  const lxcInputs = {
    module: "vllm-amd",
    vmid: "312",
    cfg,
    git: cfg,
    zones: null,
    actual,
    vmStatus: "running",
    actualNode: "tappaas2",
    guest: "lxc" as const,
  };
  const biosCfg = { ...cfg, bios: "ovmf" };
  const withBios = buildVmReport({ ...lxcInputs, cfg: biosCfg, git: biosCfg });
  check(
    withBios.errors === buildVmReport(lxcInputs).errors,
    "an LXC module declaring bios reports no phantom firmware drift",
  );

  // The QEMU shape is untouched: same report, qm-shaped keys, guest omitted.
  const qemu = text(
    buildVmReport({
      module: "network",
      vmid: "110",
      cfg: { vmname: "network", vmid: 110, node: "tappaas1", diskSize: "32G" },
      git: null,
      zones: null,
      actual: parseQmConfig(
        ["name: network", "cores: 4", "scsi0: tanka1:vm-110-disk-0,size=32G"].join("\n"),
      ),
      vmStatus: "running",
      actualNode: "tappaas1",
    }).lines,
  );
  check(
    /name.*network|vmname.*network/.test(qemu) && /32G/.test(qemu) && /seabios/.test(qemu),
    "the QEMU path is unchanged when guest is omitted (name, disk bus, seabios default)",
  );
}

// ── 8. runServiceChecks against real (throwaway) scripts ───────────────
{
  const dir = mkdtempSync(join(tmpdir(), "mm-svc-test."));
  try {
    const okScript = join(dir, "ok.sh");
    writeFileSync(okScript, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(okScript, 0o755);
    const driftScript = join(dir, "drift.sh");
    writeFileSync(driftScript, "#!/usr/bin/env bash\necho \"rule missing for $1\"\nexit 1\n");
    chmodSync(driftScript, 0o755);
    const notExec = join(dir, "notexec.sh");
    writeFileSync(notExec, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(notExec, 0o644);

    const mk = (dep: string, script: string): ServiceCheck => ({
      dep,
      provider: "network",
      service: dep.split(":")[1],
      script,
      kind: "checkable",
    });
    const outcomes = runServiceChecks("policyonly", [
      mk("network:rules", okScript),
      mk("network:nat", driftScript),
      mk("network:discovery", notExec),
    ]);
    check(outcomes[0].status === "clean", "exit 0 from test-service.sh → clean");
    check(outcomes[1].status === "drift" && outcomes[1].rc === 1, "non-zero from test-service.sh → drift");
    check(
      /rule missing for policyonly/.test(outcomes[1].detail),
      "the verifier is passed the module name and its output is captured",
    );
    check(outcomes[2].status === "unknown", "a verifier that cannot be executed → unknown, not clean");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── 9. CLI wiring: who pays for the service checks ─────────────────────
{
  const opts = (c: FakeModuleClient): InspectOptions =>
    (c.log[0].opts ?? {}) as InspectOptions;

  const c1 = new FakeModuleClient();
  run(["reconcile", "nextcloud", "--config-dir", CONFIG], c1);
  check(
    c1.log.length === 1 && c1.log[0].verb === "inspect" && opts(c1).checkServices === true,
    "`reconcile <module>` (no --apply) checks the dependency services by default",
  );

  const c2 = new FakeModuleClient();
  run(["reconcile", "nextcloud", "--no-services", "--config-dir", CONFIG], c2);
  check(opts(c2).checkServices === false, "--no-services opts the inspect out");

  // The fleet rollup must not pay one round-trip per dependency per module.
  const c3 = new FakeModuleClient();
  run(["list", "--diff", "--config-dir", CONFIG], c3);
  check(
    c3.log.length > 0 && c3.log.every((l) => (l.opts as InspectOptions).checkServices === false),
    "`list --diff` skips the service checks by default",
  );

  const c4 = new FakeModuleClient();
  run(["list", "--diff", "--services", "--config-dir", CONFIG], c4);
  check(
    c4.log.length > 0 && c4.log.every((l) => (l.opts as InspectOptions).checkServices === true),
    "`list --diff --services` opts the whole rollup in",
  );

  // --apply is the converge, not the inspect: no service checks there.
  const c5 = new FakeModuleClient();
  run(["reconcile", "nextcloud", "--apply", "--config-dir", CONFIG], c5);
  check(
    c5.log.length === 1 && c5.log[0].verb === "reconcile",
    "--apply still routes to the leaf converge",
  );
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
