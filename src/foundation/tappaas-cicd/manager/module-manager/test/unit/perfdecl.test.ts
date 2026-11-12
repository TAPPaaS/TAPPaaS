// perfdecl.test.ts — a module's performance declaration (ADR-046 D5, O8):
// foundation modules only, well formed; the instance's own keys always allowed.

import { readFileSync } from "fs";
import { join } from "path";
import { declares, perfDeclarationFindings } from "../../../../lib/ts/src/perf-declaration";
import { validateModules } from "../../src/validate";
import { ModuleConfig } from "../../src/types";

let pass = 0;
let fail = 0;
const check = (cond: boolean, name: string): void => {
  if (cond) pass++;
  else {
    fail++;
    console.log(`FAIL: ${name}`);
  }
};

const exp = { name: "authentik", port: 9301, path: "/metrics", level: "service", keep: ["authentik_*_total"] };
const ok = (p: unknown, source?: string) => perfDeclarationFindings({ source, performance: p });

check(ok(undefined).errors.length === 0, "no block: nothing to say");
check(ok({ level: "service", resolution: "fine" }, "community").errors.length === 0, "the instance's own level, any source");
check(!declares({ level: "service" }) && declares({ exporters: [] }), "declares: exporters, traces or thresholds");
check(ok({ exporters: [exp], traces: { otlp: true, level: "trace" }, thresholds: [{ signal: "http_p95_seconds", warning: 1.5, critical: 5, for: "15m" }] }).errors.length === 0, "D5's example is valid");
const comm = ok({ exporters: [exp] }, "community");
check(comm.errors.length === 1 && /community module may not declare/.test(comm.errors[0]), "a Community module's block is refused, and why");
check(ok({ thresholds: [{ signal: "x", warning: 1 }] }, "private").errors.length === 1, "a private module's too");
check(ok({ exporters: [{ ...exp, keep: ["*"] }] }).errors.some((e) => /keeps everything/.test(e)), "keep ['*'] is refused");
check(ok({ exporters: [{ ...exp, keep: [] }] }).errors.some((e) => /keep must list/.test(e)), "an empty keep-list is refused");
check(ok({ exporters: [{ ...exp, keep: ["a b"] }] }).errors.some((e) => /not a metric name/.test(e)), "a keep entry that is not a name");
check(ok({ exporters: [{ ...exp, port: "9301" }] }).errors.some((e) => /port must be/.test(e)), "a port as text");
check(ok({ exporters: [exp, { ...exp, port: 9302 }] }).errors.some((e) => /declared twice/.test(e)), "a name declared twice");
check(ok({ exporters: [{ ...exp, path: "metrics" }] }).errors.some((e) => /path/.test(e)), "a path without its slash");
check(ok({ exporters: [{ ...exp, level: "trace" }] }).errors.some((e) => /basic or service/.test(e)), "an exporter at trace");
check(ok({ exporters: [{ ...exp, extra: 1 }] }).errors.some((e) => /not an exporter key/.test(e)), "an unknown exporter key");
check(ok({ traces: { otlp: "yes" } }).errors.length === 1, "traces.otlp is a boolean");
check(ok({ thresholds: [{ signal: "p95" }] }).errors.some((e) => /warning or a critical/.test(e)), "a threshold needs a value");
check(ok({ thresholds: [{ signal: "p95", warning: 5, critical: 1 }] }).warnings.length === 1, "warning above critical: a warning");
check(ok({ thresholds: [{ signal: "p95", warning: 1, for: "soon" }] }).errors.some((e) => /duration/.test(e)), "for is a duration");
check(ok({ dashboards: true }).errors.some((e) => /not a performance key/.test(e)), "an unknown performance key");
check(ok("service").errors.length === 1, "performance must be an object");

// Through `module validate`.
const mod = (raw: Record<string, unknown>): ModuleConfig => ({ name: "m", stack: "ai", source: (raw.source as string) ?? undefined, raw } as unknown as ModuleConfig);
const r = validateModules([mod({ source: "community", performance: { exporters: [exp] } })], {});
check(r.findings.some((f) => f.severity === "error" && /may not declare performance/.test(f.message)), "module validate refuses a Community declaration");
const g = validateModules([mod({ performance: { exporters: [exp] } })], {});
check(!g.findings.some((f) => /performance/.test(f.message)), "and passes an official one");

// The foundation modules' own declarations.
const FOUNDATION = join(__dirname, "..", "..", "..", "..", "..", "..", "..", "..");
for (const m of ["identity", "logging"]) {
  const doc = JSON.parse(readFileSync(join(FOUNDATION, m, `${m}.json`), "utf8")) as { source?: string; performance?: unknown };
  const f = perfDeclarationFindings(doc);
  check(declares(doc.performance) && f.errors.length === 0 && f.warnings.length === 0, `${m}.json's declaration is valid: ${f.errors.join("; ")}`);
}

// P6: traces.otlp where the software is known not to emit warns; a note is allowed.
{
  const t = (otlp: boolean, extra: Record<string, unknown> = {}) =>
    perfDeclarationFindings({ name: "identity", source: "official", performance: { traces: { otlp, ...extra } } });
  check(t(true).warnings.some((w) => /authentik ships no OpenTelemetry/.test(w)) && t(true).errors.length === 0, "identity declaring traces.otlp true warns, not refuses");
  check(t(false, { note: "no exporter" }).warnings.length === 0 && t(false, { note: "no exporter" }).errors.length === 0, "false with a note is clean");
  check(t(false, { colour: "red" }).errors.some((e) => /not a traces key/.test(e)), "an unknown traces key is refused");
  check(perfDeclarationFindings({ name: "nextcloud", source: "official", performance: { traces: { otlp: true } } }).warnings.length === 0, "another module's otlp true is its own word");
}

console.log(`\nperfdecl: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exitCode = 1;
