// Site — the site as built. Overview (/site, /site/overview): the racks, the
// devices and the storage summed up, every finding linked to its view, and
// Add node (a guided sequence) beside the site line. Physical: the site's
// racks, devices and storage (/site/physical).

import { OperateButton } from "../operate";
import { useRead } from "../api";
import { SiteRead } from "../types";
import { navigate } from "../ui";
import { AddNodeButton } from "./AddNode";
import { Physical, PhysicalView } from "./Physical";

export const SITE_TABS = [
  { name: "Overview", path: "/site/overview" },
  { name: "Physical", path: "/site/physical" },
] as const;

// Beside the Overview's site line: the nodes the site gains.
function NodeActions() {
  return (
    <span className="toolbar">
      <AddNodeButton />
      <OperateButton label="Register joined nodes…" title="site-manager node reconcile" steps={[{ title: "site-manager node reconcile", bin: "site-manager", verb: "node reconcile" }]} />
    </span>
  );
}

export function Site({ tab = "Overview", view }: { tab?: "Overview" | "Physical"; view?: PhysicalView }) {
  const r = useRead<SiteRead>("site");
  const s = (r.env?.data?.site ?? {}) as Record<string, unknown>;
  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Site</h1>
        <span className="muted">{s.displayName ? String(s.displayName) : String(s.name ?? "")} as built</span>
      </div>
      <div className="tabs" role="tablist">
        {SITE_TABS.map((t) => (
          <button key={t.name} role="tab" aria-selected={tab === t.name} className={tab === t.name ? "tab tab-on" : "tab"} onClick={() => navigate(t.path)}>
            {t.name}
          </button>
        ))}
      </div>
      {tab === "Overview" ? <Physical embedded view="overview" aside={<NodeActions />} /> : <Physical embedded view={view && view !== "overview" ? view : "rack"} />}
    </div>
  );
}
