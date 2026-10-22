// Site — the site as built, in four tabs (physical/views.ts). Overview (/site,
// /site/overview): the racks, the devices and the storage summed up, every
// finding linked to its view, and Add node (a guided sequence) beside the site
// line. Physical (/site/physical): the racks. Device (/site/device): every
// physical device and its connections. Storage (/site/storage): the nodes,
// their pools and disks.

import { OperateButton } from "../operate";
import { useRead } from "../api";
import { SiteRead } from "../types";
import { navigate } from "../ui";
import { PHYSICAL_TABS, PhysicalView, VIEW_NAME, VIEW_PATH } from "../physical/views";
import { AddNodeButton } from "./AddNode";
import { Physical } from "./Physical";

export const SITE_TABS = PHYSICAL_TABS.map((v) => ({ view: v, name: VIEW_NAME[v], path: VIEW_PATH[v] }));

// Beside the Overview's site line: the nodes the site gains.
function NodeActions() {
  return (
    <span className="toolbar">
      <AddNodeButton />
      <OperateButton label="Register joined nodes…" title="site-manager node reconcile" steps={[{ title: "site-manager node reconcile", bin: "site-manager", verb: "node reconcile" }]} />
    </span>
  );
}

export function Site({ view = "overview" }: { view?: PhysicalView }) {
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
          <button key={t.view} role="tab" aria-selected={view === t.view} className={view === t.view ? "tab tab-on" : "tab"} onClick={() => navigate(t.path)}>
            {t.name}
          </button>
        ))}
      </div>
      <Physical embedded view={view} aside={view === "overview" ? <NodeActions /> : undefined} />
    </div>
  );
}
