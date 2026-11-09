// focus.ts — what the operator has in view, sent with every question to the
// assistant. Pure, so the unit tests run it without a DOM.

// What is in view, sent with every question.
export interface Focus {
  page: string; // overview, physical, modules, module, activity, …
  kind?: string; // the object in view: module, node, zone, finding, …
  name?: string;
  detail?: string; // e.g. the finding's text
}

// What the operator has in view: the page, and the object on it — a module's
// page, or the CMDB object selected in the Health view (?select=<id>, which the
// backend names in the operator's words).
export function focusOf(path: string, search = ""): Focus {
  const seg = path.split("/").filter((s) => s.length > 0).map((s) => decodeURIComponent(s));
  if (seg.length === 0) return { page: "overview" };
  if (seg[0] === "modules" && seg[1]) return { page: "module", kind: "module", name: seg[1] };
  const m = seg[0] === "health" ? /[?&]select=([^&#]+)/.exec(search) : null;
  const selected = m ? decodeURIComponent(m[1]) : null;
  if (selected) return { page: "health", kind: "object", name: selected };
  return { page: seg[0] };
}

export function focusLabelOf(f: Focus): string {
  return f.kind === "object" ? "the object selected on health" : focusLabel(f);
}

export function focusLabel(f: Focus): string {
  if (f.kind && f.name) return `${f.kind} ${f.name}`;
  return `page ${f.page}`;
}
