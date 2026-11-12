// Rules — the health rules the site runs (ADR-049 D10): every rule as one
// sentence, grouped by what it decides, with who released it, what the site did
// to it and how many cases it decides now; one rule's page with its record, its
// state, the three columns of a rule edited here and changed upstream, and the
// changes as jobs like any other: edit, turn off or on, delete, restore, take
// the release, keep the edit, accept a held rule. Each previews first: the
// records that change, the check, and on the site as it is now the roots that
// appear or go, the colours that change, what would go quiet.
//
// The console decides nothing here: health-manager reads and writes the rules.

import { useMemo, useState } from "react";
import { useRead, useVerb } from "../api";
import { OperateButton, Step, Values } from "../operate";
import { HealthRule, HealthRuleDetail, HealthRules } from "../types";
import { Link, ReadState, Section, navigate, since } from "../ui";

const KIND_TITLE: Record<HealthRule["kind"], string> = {
  classify: "What a finding becomes",
  propagate: "How a failure crosses a relation",
  combine: "Relations that back each other up",
  explain: "What explains what",
  follow: "Whose colour an object takes",
  rollup: "How a collection sums up",
  notify: "How a root cause is told",
};
const KINDS = Object.keys(KIND_TITLE) as HealthRule["kind"][];

type Filter = "all" | "edited" | "pending" | "held" | "disabled";
const FILTER_WORD: Record<Filter, string> = { all: "All", edited: "Edited here", pending: "Pending", held: "Held", disabled: "Off" };

export const ruleIs = (r: Pick<HealthRule, "state" | "enabled">, f: Filter): boolean =>
  f === "all" ? true : f === "disabled" ? r.enabled === false : f === "edited" ? /\b(edited|added)\b/.test(r.state) : r.state.includes(f);

export const rulePath = (id: string): string => `/health/rules/${encodeURIComponent(id)}`;

function Origin({ o }: { o: string }) {
  return <span className="tag tag-skip" title={o === "core" ? "released with TAPPaaS" : o === "site" ? "this site's own" : `released with the module ${o}`}>{o === "core" ? "core" : o === "site" ? "this site" : o}</span>;
}

const MERGE: Step = {
  title: "Install the health rules on this site",
  bin: "health-manager",
  verb: "rules merge",
  words: ["rules", "merge"],
  note: "The release's rules are copied into the site's configuration, where they can be edited. Every update after this merges a new release per rule and keeps what this site changed.",
};

export function RulesPage() {
  const r = useRead<HealthRules>("health/rules", 300_000);
  const merge = useVerb("health-manager", "rules merge");
  const [filter, setFilter] = useState<Filter>("all");
  const v = r.env?.data ?? null;
  const shown = useMemo(() => (v?.records ?? []).filter((x) => ruleIs(x, filter)), [v, filter]);
  const count = (f: Filter): number => (v?.records ?? []).filter((x) => ruleIs(x, f)).length;
  return (
    <div className="page">
      <div className="page-head">
        <h1>Health rules</h1>
        <div className="seg" role="tablist" aria-label="which rules">
          {(Object.keys(FILTER_WORD) as Filter[]).map((f) => (
            <button key={f} role="tab" aria-selected={filter === f} className={filter === f ? "seg-on" : ""} onClick={() => setFilter(f)}>
              {FILTER_WORD[f]}{f !== "all" && v ? ` (${count(f)})` : ""}
            </button>
          ))}
        </div>
        <span className="muted">What health-manager decides at each object · read {since(r.env?.at)} · <Link to="/health">Health</Link></span>
      </div>
      <ReadState env={r.env} failure={r.failure} what="the health rules" />
      {v && !v.installed ? (
        <div className="readstate">
          <p>The rules of this release run as shipped. To edit one, install them on this site first.</p>
          <OperateButton label="Install the rules…" title={MERGE.title} steps={[MERGE]} disabled={!merge} hint={merge ? undefined : "health-manager on this site cannot install rules yet"} />
        </div>
      ) : null}
      {v ? (
        <>
          {KINDS.map((k) => {
            const rows = shown.filter((x) => x.kind === k);
            if (!rows.length) return null;
            return (
              <Section key={k} title={KIND_TITLE[k]} aside={`${rows.length}`}>
                <ul className="rules-list">
                  {rows.map((x) => (
                    <li key={x.id} className={`rules-row${x.enabled === false ? " rules-off" : ""}`}>
                      <Link to={rulePath(x.id)} className="rules-sentence">{x.sentence}</Link>
                      <span className="rules-meta muted small">
                        <span className="mono">{x.id}</span> <Origin o={x.origin} />
                        {x.enabled === false ? " · off" : ""}
                        {x.state ? ` · ${x.state}` : ""}
                        {typeof x.decidesNow === "number" ? ` · decides ${x.decidesNow} now` : ""}
                      </span>
                    </li>
                  ))}
                </ul>
              </Section>
            );
          })}
          {!shown.length ? <p className="muted">No rule {filter === "all" ? "" : `is ${FILTER_WORD[filter].toLowerCase()}`}.</p> : null}
          <Scenarios v={v} />
        </>
      ) : null}
    </div>
  );
}

function Scenarios({ v }: { v: HealthRules }) {
  const write = useVerb("health-manager", "rules scenario retire|restore");
  if (!v.installed || !v.scenarios.length) return null;
  const step = (id: string, sub: "retire" | "restore"): Step => ({
    title: sub === "retire" ? `Retire the scenario ${id}` : `Hold to the scenario ${id} again`,
    bin: "health-manager",
    verb: "rules scenario retire|restore",
    words: ["rules", "scenario", sub],
    fixed: [id],
    only: sub === "retire" ? ["--note"] : [],
    labels: { "--note": "why" },
    placeholders: { "--note": "why this site no longer holds to it" },
    descriptions: { "--note": "Required. Kept with the scenario; support reads it." },
    note: sub === "retire" ? "A retired scenario is not run by the checks, and an update never brings it back." : "The scenario as released is run by every check again.",
  });
  return (
    <Section title="Contract scenarios" aside={`${v.scenarios.length}`}>
      <p className="muted small">What the rules must keep doing: a few objects, a failure, and what must come out. Every change to the rules runs them.</p>
      <ul className="rules-list">
        {v.scenarios.map((s) => (
          <li key={s.id} className={`rules-row${s.retired ? " rules-off" : ""}`}>
            <span className="rules-sentence">{s.description || s.id}</span>
            <span className="rules-meta muted small">
              <span className="mono">{s.id}</span>
              {s.retired ? ` · retired by ${s.retired.by}: ${s.retired.note}${s.upstream ? " · changed upstream since" : ""}` : ""}
            </span>
            <OperateButton label={s.retired ? "Hold to it again…" : "Retire…"} steps={[step(s.id, s.retired ? "restore" : "retire")]} disabled={!write} hint={write ? undefined : "health-manager on this site cannot change scenarios"} />
          </li>
        ))}
      </ul>
    </Section>
  );
}

// ── one rule ──────────────────────────────────────────────────────────

const WRITE = "rules add|edit|enable|disable|delete|restore|take|keep|accept";

function action(id: string, word: string, title: string, note: string, extra: Partial<Step> = {}): Step {
  return {
    title,
    bin: "health-manager",
    verb: WRITE,
    words: ["rules", word],
    fixed: [id],
    only: ["--note", "--force"],
    labels: { "--note": "why", "--force": "write it though a contract scenario no longer holds" },
    placeholders: { "--note": "why, for the record" },
    note,
    ...extra,
  };
}

export function RulePage({ id }: { id: string }) {
  const r = useRead<HealthRuleDetail>(`health/rules/${encodeURIComponent(id)}`, 300_000);
  const can = !!useVerb("health-manager", WRITE);
  const d = r.env?.data ?? null;
  const rec = d?.show.record ?? null;
  const released = d?.show.released ?? null;
  const st = d?.show.state ?? "";
  const pending = st.includes("pending");
  const held = st.includes("held");
  const local = d?.show.local?.local;
  const hint = can ? undefined : "health-manager on this site cannot change rules yet";
  return (
    <div className="page">
      <div className="page-head">
        <h1>{d?.show.sentence ?? id}</h1>
        <span className="muted"><Link to="/health/rules">Health rules</Link> · read {since(r.env?.at)}</span>
      </div>
      <ReadState env={r.env} failure={r.failure} what="this rule" />
      {d ? (
        <>
          <div className="rules-actions">
            {rec ? <OperateButton label="Edit…" kind="primary" title={`Edit ${id}`} steps={[editStep(rec)]} disabled={!can} hint={hint} /> : null}
            {rec ? (
              rec.enabled === false
                ? <OperateButton label="Turn on…" steps={[action(id, "enable", `Turn ${id} on`, "It decides again from the next assess, which runs at once.")]} disabled={!can} hint={hint} />
                : <OperateButton label="Turn off…" steps={[action(id, "disable", `Turn ${id} off`, "It stays in the set, off; an update keeps it off.")]} disabled={!can} hint={hint} />
            ) : null}
            {held ? <OperateButton label="Accept…" kind="primary" steps={[action(id, "accept", `Run the held rule ${id}`, "It was installed held; accepting runs it from the next assess, which runs at once.")]} disabled={!can} hint={hint} /> : null}
            {released && (local || !rec) ? <OperateButton label="Restore as released…" steps={[action(id, "restore", `Restore ${id} as released`, "What this site changed is dropped; the release's rule runs.")]} disabled={!can} hint={hint} /> : null}
            {rec && released ? <OperateButton label="Delete…" kind="danger" steps={[action(id, "delete", `Delete ${id}`, "A released rule deleted here stays deleted: an update never brings it back. Restore takes it back.")]} disabled={!can} hint={hint} /> : null}
            {rec && !released ? <OperateButton label="Delete…" kind="danger" steps={[action(id, "delete", `Delete ${id}`, "This site's own rule goes.")]} disabled={!can} hint={hint} /> : null}
          </div>
          {pending ? (
            <Section title="Edited here, changed upstream" aside="as released when edited · as it is here · as released now">
              <ThreeColumns rows={d.diff} />
              <div className="rules-actions">
                <OperateButton label="Take the release…" steps={[action(id, "take", `Take ${id} as released now`, "The rule as released now replaces this site's edit.")]} disabled={!can} hint={hint} />
                <OperateButton label="Keep mine…" steps={[action(id, "keep", `Keep ${id} as edited here`, "It stays as this site edited it, marked as looked at: no longer pending.")]} disabled={!can} hint={hint} />
              </div>
            </Section>
          ) : null}
          <Section title="Details">
            <ul className="plain">
              <li><span className="muted">id</span> <span className="mono">{id}</span></li>
              <li><span className="muted">released by</span> <Origin o={d.show.origin} /></li>
              <li><span className="muted">state</span> {st}{d.show.local?.by ? ` · by ${d.show.local.by}${d.show.local.at ? ` ${since(d.show.local.at)}` : ""}` : ""}{d.show.local?.note ? ` · ${d.show.local.note}` : ""}</li>
              {typeof d.show.decidesNow === "number" ? <li><span className="muted">decides</span> {d.show.decidesNow} case(s) on the site now</li> : null}
              {d.show.overrides.length ? <li><span className="muted">overrides</span> {d.show.overrides.map((o) => <Link key={o} to={rulePath(o)} className="mono">{o} </Link>)}</li> : null}
              {d.show.overriddenBy.length ? <li><span className="muted">overridden by</span> {d.show.overriddenBy.map((o) => <Link key={o} to={rulePath(o)} className="mono">{o} </Link>)}</li> : null}
              {rec?.description ? <li><span className="muted">why</span> {rec.description}</li> : null}
            </ul>
          </Section>
          {!pending && d.diff.some((x) => x.mark) ? (
            <Section title="Changed here" aside="as released · as it is here">
              <ThreeColumns rows={d.diff} />
            </Section>
          ) : null}
          <Section title="The record">
            <pre className="output">{JSON.stringify(rec ?? released, null, 2)}</pre>
          </Section>
        </>
      ) : null}
    </div>
  );
}

function ThreeColumns({ rows }: { rows: HealthRuleDetail["diff"] }) {
  const marked = rows.filter((x) => x.mark);
  if (!marked.length) return <p className="muted">No field differs.</p>;
  const MARK = { here: "changed here", upstream: "changed upstream", both: "changed in both", "": "" };
  return (
    <div className="rules-diff">
      {marked.map((x) => (
        <div key={x.field} className="rules-diff-row">
          <span className="mono rules-diff-field">{x.field}</span>
          <span className="mono" data-col="as released when edited">{x.released ?? "—"}</span>
          <span className="mono" data-col="as it is here">{x.here ?? "—"}</span>
          <span className="mono" data-col="as released now">{x.now ?? "—"}</span>
          <span className="muted small">{MARK[x.mark]}</span>
        </div>
      ))}
    </div>
  );
}

// ── the edit form: the record's own fields, not a JSON box ────────────

type Leaf = { path: string; value: unknown };
const isPred = (v: unknown): boolean => typeof v === "object" && v !== null && !Array.isArray(v) && ("exists" in v || "glob" in v || "over" in v);

/** The record's `when` as path → value, down to each predicate. */
export function leaves(o: unknown, at: string): Leaf[] {
  if (typeof o !== "object" || o === null || Array.isArray(o) || isPred(o)) return [{ path: at, value: o }];
  return Object.entries(o as Record<string, unknown>).flatMap(([k, v]) => leaves(v, `${at}.${k}`));
}

/** A value as the form shows it, and back: plain text for a word, JSON otherwise. */
export const showValue = (v: unknown): string => (typeof v === "string" ? v : JSON.stringify(v));
export function readValue(s: string): unknown {
  const t = s.trim();
  if (/^[-\w.:/*]+$/.test(t) && !/^(true|false|null|-?\d+(\.\d+)?)$/.test(t)) return t;
  try {
    return JSON.parse(t);
  } catch {
    return t;
  }
}

/** The --set and --unset tokens that turn `was` into `now`, by path. */
export function editTokens(was: Leaf[], now: Leaf[]): string[] {
  const out: string[] = [];
  const before = new Map(was.map((l) => [l.path, JSON.stringify(l.value)]));
  const after = new Map(now.map((l) => [l.path, l.value]));
  for (const [p, v] of after) if (before.get(p) !== JSON.stringify(v)) out.push("--set", `${p}=${typeof v === "string" ? v : JSON.stringify(v)}`);
  for (const p of before.keys()) if (!after.has(p)) out.push("--unset", p);
  return out;
}

const SELECTORS: Record<HealthRule["kind"], string[]> = {
  classify: ["finding", "object"],
  propagate: ["relation", "provider", "dependant", "from", "to", "edge", "condition"],
  combine: ["relation", "provider", "dependant", "edge"],
  explain: ["cause", "condition", "object"],
  follow: ["object"],
  rollup: ["object", "condition"],
  notify: ["object", "condition"],
};
const FIELDS: Record<string, string[]> = {
  object: ["class", "name", "module", "zone", "environment", "attr."], provider: ["class", "name", "module", "zone", "environment", "attr."], dependant: ["class", "name", "module", "zone", "environment", "attr."],
  from: ["class", "name", "module", "attr."], to: ["class", "name", "module", "attr."], condition: ["type", "status", "reason"], finding: ["source", "type", "status", "reason", "labels.", "age"],
  cause: ["type", "status", "sameType"], edge: ["attr."], relation: [""],
};
const STATUS = ["warning", "critical"];
const OUTCOME: Record<HealthRule["kind"], { path: string; label: string; choices?: string[] }[]> = {
  classify: [{ path: "set.status", label: "becomes (status)", choices: ["", ...STATUS] }, { path: "set.type", label: "becomes (type)" }, { path: "set.reason", label: "with reason" }, { path: "quiet", label: "kept and quiet", choices: ["", "true"] }, { path: "aggregate", label: "a sum of others, never a root", choices: ["", "true"] }],
  propagate: [{ path: "as.status", label: "crosses as", choices: ["warning", "critical"] }, { path: "as.type", label: "as the type" }],
  combine: [{ path: "steps", label: "steps (down: as)" }],
  explain: [{ path: "effect", label: "the arriving failure", choices: ["derived", "covered", "none"] }],
  follow: [{ path: "relation", label: "follows over" }, { path: "types", label: "in the types" }],
  rollup: [{ path: "fn", label: "sums up as", choices: ["worst", "own"] }],
  notify: [{ path: "notify", label: "a root is told", choices: ["at-once", "digest", "none"] }],
};

function RuleForm({ rec, values, set }: { rec: HealthRule; values: Values; set: (v: Values) => void }) {
  const base = useMemo(() => [...leaves(rec.when, "when"), ...OUTCOME[rec.kind].map((o) => ({ path: o.path, value: o.path.split(".").reduce<unknown>((x, k) => (x as Record<string, unknown> | undefined)?.[k], rec) })).filter((l) => l.value !== undefined), { path: "description", value: rec.description ?? "" }, ...(rec.enabled === false ? [{ path: "enabled", value: false }] : [])], [rec]);
  const cur: Leaf[] = typeof values["@leaves"] === "string" ? (JSON.parse(values["@leaves"]) as Leaf[]) : base;
  const put = (next: Leaf[]): void => set({ ...values, "@leaves": JSON.stringify(next), "@fields": editTokens(base, next.filter((l) => !(l.path === "description" && l.value === "" && !rec.description))) });
  const change = (path: string, value: unknown): void => put(cur.some((l) => l.path === path) ? cur.map((l) => (l.path === path ? { path, value } : l)) : [...cur, { path, value }]);
  const drop = (path: string): void => put(cur.filter((l) => l.path !== path));
  const [sel, setSel] = useState(SELECTORS[rec.kind][0]);
  const [field, setField] = useState(FIELDS[SELECTORS[rec.kind][0]][0]);
  const [extra, setExtra] = useState("");
  const [val, setVal] = useState("");
  const when = cur.filter((l) => l.path.startsWith("when."));
  return (
    <div className="form">
      <h4>When</h4>
      {when.length === 0 ? <p className="muted small">It matches every case of its kind.</p> : null}
      {when.map((l) => (
        <label key={l.path} className="form-row">
          <span className="mono small">{l.path.slice(5)}</span>
          <span className="rules-field">
            <input value={showValue(l.value)} onChange={(e) => change(l.path, readValue(e.target.value))} aria-label={l.path} />
            <button type="button" className="btn-x" onClick={() => drop(l.path)} aria-label={`remove ${l.path}`}>×</button>
          </span>
        </label>
      ))}
      <div className="form-row">
        <span>Add a match</span>
        <span className="rules-field">
          <select value={sel} onChange={(e) => { setSel(e.target.value); setField(FIELDS[e.target.value][0]); }} aria-label="selector">
            {SELECTORS[rec.kind].map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
          {FIELDS[sel][0] !== "" ? (
            <select value={field} onChange={(e) => setField(e.target.value)} aria-label="field">
              {FIELDS[sel].map((f) => <option key={f} value={f}>{f.endsWith(".") ? `${f}…` : f}</option>)}
            </select>
          ) : null}
          {field.endsWith(".") ? <input value={extra} onChange={(e) => setExtra(e.target.value)} placeholder="name" aria-label="attribute or label name" /> : null}
          <input value={val} onChange={(e) => setVal(e.target.value)} placeholder={'value, or ["a","b"]'} aria-label="value" />
          <button type="button" className="btn" disabled={!val.trim() || (field.endsWith(".") && !extra.trim())} onClick={() => { change(`when.${sel}${field ? `.${field}${field.endsWith(".") ? extra.trim() : ""}` : ""}`, readValue(val)); setVal(""); setExtra(""); }}>Add</button>
        </span>
      </div>
      <h4>Then</h4>
      {OUTCOME[rec.kind].map((o) => {
        const l = cur.find((x) => x.path === o.path);
        return (
          <label key={o.path} className="form-row">
            <span>{o.label}</span>
            {o.choices ? (
              <select value={l ? showValue(l.value) : ""} onChange={(e) => (e.target.value === "" ? drop(o.path) : change(o.path, readValue(e.target.value)))} aria-label={o.label}>
                {o.choices.map((c) => <option key={c} value={c}>{c === "" ? "—" : c}</option>)}
              </select>
            ) : (
              <input value={l ? showValue(l.value) : ""} onChange={(e) => (e.target.value === "" ? drop(o.path) : change(o.path, readValue(e.target.value)))} aria-label={o.label} />
            )}
          </label>
        );
      })}
      <label className="form-row">
        <span>Description</span>
        <input value={showValue(cur.find((l) => l.path === "description")?.value ?? "")} onChange={(e) => change("description", e.target.value)} aria-label="description" />
      </label>
    </div>
  );
}

export function editStep(rec: HealthRule): Step {
  return {
    title: `Edit ${rec.id}`,
    bin: "health-manager",
    verb: WRITE,
    words: ["rules", "edit"],
    fixed: [rec.id],
    only: ["--note", "--force"],
    labels: { "--note": "why", "--force": "write it though a contract scenario no longer holds" },
    placeholders: { "--note": "why this site changes it" },
    previewOnOpen: false,
    render: (values, set) => <RuleForm rec={rec} values={values} set={set} />,
    note: rec.origin === "site" ? "This site's own rule." : "Kept as edited across updates; an update that changes it upstream marks it pending, for you to take or keep.",
  };
}

// The Health page links here; a direct link opens a rule's page.
export function openRule(id: string): void {
  navigate(rulePath(id));
}
