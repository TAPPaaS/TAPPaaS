// rescan.ts — `cmdb rescan` (ADR-040 D2): ask every source again, so the
// actual state can be recreated from what the sources see. A source is a verb
// that interrogates and reports what it saw back to this service, as it does
// after its own validate or reconcile (D4).
//
// The list is empty until the managers report (implementation plan step 2);
// each then adds its read-only verb here. The sources run one at a time and
// asynchronously: each reports to this same service while it runs.

import { ChildProcess, spawn } from "child_process";

export interface RescanSource {
  name: string; // the reporter, as it names itself in its reports
  argv: string[]; // its read-only verb, e.g. ["site-manager", "node", "reconcile"]
}

export const RESCAN_SOURCES: RescanSource[] = [];

export interface RescanResult {
  source: string;
  ok: boolean;
  exitCode: number | null;
  error?: string;
}

function run(src: RescanSource): Promise<RescanResult> {
  return new Promise((resolve) => {
    let child: ChildProcess;
    try {
      child = spawn(src.argv[0], src.argv.slice(1), { stdio: "ignore" });
    } catch (e) {
      return resolve({ source: src.name, ok: false, exitCode: null, error: e instanceof Error ? e.message : String(e) });
    }
    child.on("error", (e) => resolve({ source: src.name, ok: false, exitCode: null, error: e.message }));
    child.on("close", (code) => resolve({ source: src.name, ok: code === 0, exitCode: code }));
  });
}

export async function rescan(log: (line: string) => void, sources: RescanSource[] = RESCAN_SOURCES): Promise<{ asked: RescanResult[] }> {
  const asked: RescanResult[] = [];
  for (const src of sources) {
    log(`rescan: asking ${src.name} (${src.argv.join(" ")})`);
    asked.push(await run(src));
  }
  return { asked };
}
