// cli.ts — `cmdb`, the verb surface in front of cmdb-controller's API
// (ADR-040 D2). Each verb is one call through lib/ts/src/cmdb.ts; --json
// prints the API's data as it came, otherwise a table for people.

import { readFileSync } from "fs";
import { CmdbRefused, CmdbReport, CmdbUnavailable, cmdbQuery, cmdbReport, cmdbRequest, objectPath, replaySpool } from "../../../lib/ts/src/cmdb";

type Obj = Record<string, unknown>;

const HELP = `cmdb — the CMDB: the actual state of the site (ADR-040)

  cmdb show <object> [--class C] [--at TIME]          an object: attributes, relations, drift
  cmdb query [<class>] [--physical] [--where k=v]... [--at TIME] [--all]
                                                      objects of a class and its subclasses
  cmdb history <object> [--class C] [--at TIME]       every period of every attribute and relation;
                                                      with --at, the object as it was then
  cmdb impact <object> [--class C] [--hops N] [--direction in|out|both]
                                                      everything within N relations (default 2, both)
  cmdb report [--file F]                              a report (JSON) from stdin; spooled if the
                                                      service is down
  cmdb rescan                                         ask every cmdbSource component to report again
  cmdb class list                                     the class tree
  cmdb class show <class>                             a class: fields, keys, relations
  cmdb resolve <otel-attr>=<value>...                 OpenTelemetry resource attributes → object

<object> is an id, a name, or <class>/<name>. Every verb takes --json.
The service: CMDB_SOCKET (default /run/cmdb/cmdb.sock), or CMDB_URL with CMDB_TOKEN_FILE.`;

interface Args {
  pos: string[];
  opts: Map<string, string[]>;
}

const FLAGS = new Set(["json", "physical", "all", "help"]);

function parse(argv: string[]): Args {
  const pos: string[] = [];
  const opts = new Map<string, string[]>();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-h") opts.set("help", ["1"]);
    else if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      const k = eq > 0 ? a.slice(2, eq) : a.slice(2);
      const v = eq > 0 ? a.slice(eq + 1) : FLAGS.has(k) ? "1" : argv[++i];
      if (v === undefined) throw new Error(`--${k} needs a value`);
      opts.set(k, [...(opts.get(k) ?? []), v]);
    } else pos.push(a);
  }
  return { pos, opts };
}

function opt(a: Args, k: string): string | undefined {
  return a.opts.get(k)?.[0];
}

// <class>/<name>, or an id or name with --class.
function objectRef(a: Args, i: number): { ref: string; cls: string | undefined } {
  const raw = a.pos[i];
  if (!raw) throw new Error("which object? an id, a name, or <class>/<name>");
  const slash = raw.indexOf("/");
  if (slash > 0 && !opt(a, "class")) return { ref: raw.slice(slash + 1), cls: raw.slice(0, slash) };
  return { ref: raw, cls: opt(a, "class") };
}

function cell(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  return JSON.stringify(v);
}

function table(rows: string[][], head: string[]): string {
  const all = [head, ...rows];
  const w = head.map((_, i) => Math.max(...all.map((r) => (r[i] ?? "").length)));
  return all.map((r) => r.map((c, i) => (i === r.length - 1 ? c : c.padEnd(w[i]))).join("  ")).join("\n");
}

function print(json: boolean, data: unknown, human: () => string): void {
  console.log(json ? JSON.stringify(data, null, 2) : human());
}

function showText(d: Obj): string {
  const attrs = (d.attributes ?? {}) as Record<string, { value: unknown; source: string; since: string }>;
  const lines = [
    `${String(d.class)} ${String(d.name)}${d.displayName ? ` (${String(d.displayName)})` : ""}${d.ended ? `  — ended ${String(d.ended)}` : ""}`,
    `  id        ${String(d.id)}`,
    `  is a      ${(d.ancestors as string[]).join(" < ")}`,
    `  created   ${String(d.created)}${d.lastSeen ? `   last seen ${String(d.lastSeen)}` : ""}`,
  ];
  if (d.at) lines.push(`  as of     ${String(d.at)}`);
  if (d.drift) lines.push(`  DRIFT     ${JSON.stringify(d.drift)}`);
  const a = Object.entries(attrs).filter(([k]) => k !== "drift");
  if (a.length) {
    lines.push("", table(a.map(([k, v]) => [k, cell(v.value), v.source, v.since]), ["ATTRIBUTE", "VALUE", "SOURCE", "SINCE"]));
  }
  const rels = (d.relations ?? []) as Obj[];
  if (rels.length) {
    lines.push(
      "",
      table(
        rels.map((r) => {
          const o = r.other as Obj;
          return [r.direction === "out" ? `→ ${String(r.type)}` : `← ${String(r.type)}`, `${String(o.class)}/${String(o.name)}`, String(r.source), String(r.since)];
        }),
        ["RELATION", "OBJECT", "SOURCE", "SINCE"],
      ),
    );
  }
  return lines.join("\n");
}

function run(argv: string[]): number {
  const a = parse(argv);
  const json = a.opts.has("json");
  const verb = a.pos[0];
  if (!verb || a.opts.has("help") || verb === "help") {
    console.log(HELP);
    return 0;
  }
  switch (verb) {
    case "show": {
      const { ref, cls } = objectRef(a, 1);
      const d = cmdbRequest("GET", objectPath(ref, "", { class: cls, at: opt(a, "at") })) as Obj;
      print(json, d, () => showText(d));
      return 0;
    }
    case "query": {
      const where: Obj = {};
      for (const w of a.opts.get("where") ?? []) {
        const eq = w.indexOf("=");
        if (eq < 1) throw new Error(`--where ${w}: expected key=value`);
        const raw = w.slice(eq + 1);
        let v: unknown = raw;
        try {
          v = JSON.parse(raw); // numbers, booleans, arrays; a bare word stays a string
        } catch {
          v = raw;
        }
        where[w.slice(0, eq)] = v;
      }
      const rows = cmdbQuery({
        class: a.pos[1],
        physical: a.opts.has("physical") ? true : undefined,
        where,
        at: opt(a, "at"),
        includeEnded: a.opts.has("all"),
      });
      print(json, rows, () =>
        rows.length
          ? table(
              rows.map((r) => [String(r.class), String(r.name), cell(r.displayName), r.ended ? `ended ${String(r.ended)}` : "", String(r.id)]),
              ["CLASS", "NAME", "DISPLAY", "STATE", "ID"],
            ) + `\n${rows.length} object(s)`
          : "no objects",
      );
      return 0;
    }
    case "history": {
      const { ref, cls } = objectRef(a, 1);
      const at = opt(a, "at");
      const d = cmdbRequest("GET", objectPath(ref, "history", { class: cls, at })) as Obj;
      print(json, d, () => {
        if (at) return showText(d);
        const rows: string[][] = [];
        for (const x of d.attributes as Obj[]) rows.push([String(x.from), cell(x.to) || "now", String(x.name), cell(x.value), String(x.source)]);
        for (const x of d.relations as Obj[]) {
          const o = x.other as Obj;
          rows.push([String(x.from), cell(x.to) || "now", `${x.direction === "out" ? "→" : "←"} ${String(x.type)}`, `${String(o.class)}/${String(o.name)}`, String(x.source)]);
        }
        rows.sort((p, q) => p[0].localeCompare(q[0]));
        return `${String(d.class)} ${String(d.name)}  ${String(d.id)}\n\n` + table(rows, ["FROM", "TO", "WHAT", "VALUE", "SOURCE"]);
      });
      return 0;
    }
    case "impact": {
      const { ref, cls } = objectRef(a, 1);
      const d = cmdbRequest("GET", objectPath(ref, "impact", { class: cls, hops: opt(a, "hops"), direction: opt(a, "direction") })) as Obj;
      const rows = d.impact as Obj[];
      print(json, d, () =>
        `${String(d.class)} ${String(d.name)}, ${String(d.hops)} hop(s), ${String(d.direction)}\n\n` +
        (rows.length ? table(rows.map((r) => [String(r.depth), String(r.class), String(r.name), String(r.via)]), ["HOP", "CLASS", "NAME", "VIA"]) : "nothing related"),
      );
      return 0;
    }
    case "report": {
      const file = opt(a, "file");
      const text = readFileSync(file ?? 0, "utf8");
      let report: CmdbReport;
      try {
        report = JSON.parse(text) as CmdbReport;
      } catch (e) {
        throw new Error(`the report is not JSON: ${e instanceof Error ? e.message : String(e)}`);
      }
      const out = cmdbReport(report);
      print(json, out, () => {
        if (!out.delivered) return `cmdb-controller is not answering: spooled to ${String(out.spooled)}`;
        const r = out.result as Obj;
        const objs = r.objects as Obj[];
        return (
          `${r.change === null ? "nothing changed" : `change ${String(r.change)}`}\n` +
          table(
            objs.map((o) => [String(o.class), String(o.name), o.created ? "created" : o.ended ? "ended" : (o.changed as string[]).length ? `changed ${(o.changed as string[]).join(",")}` : "unchanged", (o.drift as string[]).length ? `DRIFT ${(o.drift as string[]).join(",")}` : "", String(o.id)]),
            ["CLASS", "NAME", "WHAT", "", "ID"],
          )
        );
      });
      return 0;
    }
    case "rescan": {
      const replay = replaySpool();
      // The sources run one after the other, each a full interrogation of its plane.
      const d = cmdbRequest("POST", "/v1/rescan", {}, { timeoutSeconds: 3600 }) as Obj;
      const asked = d.asked as Obj[];
      print(json, { ...d, spool: replay }, () =>
        (asked.length ? table(asked.map((x) => [String(x.source), x.ok ? "ok" : `failed ${cell(x.exitCode ?? x.error)}`]), ["SOURCE", "RESULT"]) : "no component is marked cmdbSource in components.json") +
        (replay.replayed || replay.refused ? `\nspool: ${replay.replayed} replayed, ${replay.refused} refused` : ""),
      );
      return 0;
    }
    case "class": {
      const sub = a.pos[1] ?? "list";
      if (sub === "list") {
        const rows = cmdbRequest("GET", "/v1/classes") as Obj[];
        print(json, rows, () => {
          const byParent = new Map<string | null, Obj[]>();
          for (const r of rows) byParent.set((r.parent as string) ?? null, [...(byParent.get((r.parent as string) ?? null) ?? []), r]);
          const out: string[] = [];
          const walk = (p: string | null, depth: number): void => {
            for (const r of byParent.get(p) ?? []) {
              const tags = [r.abstract ? "abstract" : "", r.physical ? "physical" : ""].filter(Boolean).join(", ");
              out.push(`${"  ".repeat(depth)}${String(r.name)}${tags ? `  (${tags})` : ""}`);
              walk(String(r.name), depth + 1);
            }
          };
          walk(null, 0);
          return out.join("\n");
        });
        return 0;
      }
      if (sub === "show") {
        const name = a.pos[2];
        if (!name) throw new Error("which class?");
        const d = cmdbRequest("GET", `/v1/classes/${encodeURIComponent(name)}`) as Obj;
        print(json, d, () => {
          const fields = d.fields as Obj[];
          const keys = d.keys as Obj[];
          return [
            `${name}${d.abstract ? " (abstract)" : ""}${d.physical ? " (physical)" : ""} — ${String(d.description)}`,
            `  is a      ${(d.ancestors as string[]).join(" < ")}`,
            `  keys      ${keys.length ? keys.map((k) => `(${(k.components as string[]).join(", ")})`).join(" then ") : "(name), within the class"} in ${String(d.keyScope)}`,
            "",
            table(
              fields.map((f) => [
                String(f.name),
                f.type === "relation" ? `→ ${String((f.spec as Obj).relation)}${(f.spec as Obj).direction === "in" ? " (in)" : ""}` : String(f.type),
                [f.required ? "required" : "", f.immutable ? "immutable" : "", f.key !== null ? `key ${String(f.key)}` : "", (f.spec as Obj).derived ? "derived" : ""].filter(Boolean).join(" "),
                String(f.class),
              ]),
              ["FIELD", "TYPE", "", "FROM"],
            ),
          ].join("\n");
        });
        return 0;
      }
      throw new Error(`cmdb class ${sub}: list or show`);
    }
    case "resolve": {
      const attrs: Obj = {};
      for (const p of a.pos.slice(1)) {
        const eq = p.indexOf("=");
        if (eq < 1) throw new Error(`${p}: expected <otel-attribute>=<value>`);
        attrs[p.slice(0, eq)] = p.slice(eq + 1);
      }
      const d = cmdbRequest("POST", "/v1/resolve", { attributes: attrs }) as Obj;
      print(json, d, () => `${String(d.class)} ${String(d.name)}  ${String(d.id)}`);
      return 0;
    }
    default:
      console.error(`cmdb: unknown verb ${verb}\n\n${HELP}`);
      return 2;
  }
}

function main(): number {
  try {
    return run(process.argv.slice(2));
  } catch (e) {
    if (e instanceof CmdbRefused) {
      const extra = e.body.problems ?? e.body.candidates;
      console.error(`cmdb: ${e.message}${extra ? `\n${JSON.stringify(extra, null, 2)}` : ""}`);
      return e.status === 404 ? 3 : 4;
    }
    if (e instanceof CmdbUnavailable) {
      console.error(`cmdb: ${e.message}`);
      return 5;
    }
    console.error(`cmdb: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
}

if (require.main === module) process.exitCode = main();
