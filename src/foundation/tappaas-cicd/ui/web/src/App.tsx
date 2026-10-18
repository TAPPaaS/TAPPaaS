// App.tsx — the shell of the mockups: the left navigation, a header with the
// site, the reader and a refresh, and the page. Security is a later phase; it
// is shown in the navigation and marked as later.

import { useState } from "react";
import { refreshAll, useRead } from "./api";
import { Activity } from "./pages/Activity";
import { Backup } from "./pages/Backup";
import { Environments } from "./pages/Environments";
import { Identity } from "./pages/Identity";
import { Setup } from "./pages/Setup";
import { Site } from "./pages/Site";
import { ModulePage } from "./pages/ModulePage";
import { Modules } from "./pages/Modules";
import { Overview } from "./pages/Overview";
import { OwnerOverview } from "./pages/OwnerOverview";
import { Physical } from "./pages/Physical";
import { Me, SiteRead } from "./types";
import { Link, MeContext, usePath } from "./ui";

const NAV: { to: string; label: string; live: boolean }[] = [
  { to: "/setup", label: "Setup", live: true },
  { to: "/", label: "Overview", live: true },
  { to: "/physical", label: "Physical", live: true },
  { to: "/modules", label: "Modules", live: true },
  { to: "/environments", label: "Environments", live: true },
  { to: "/identity", label: "Identity", live: true },
  { to: "/backup", label: "Backup", live: true },
  { to: "/site", label: "Site", live: true },
  { to: "/security", label: "Security", live: false },
  { to: "/activity", label: "Activity", live: true },
];

function active(path: string, to: string): boolean {
  return to === "/" ? path === "/" : path === to || path.startsWith(`${to}/`);
}

export function App() {
  const path = usePath();
  const me = useRead<Me>("me", 300_000);
  const site = useRead<SiteRead>("site");
  const user = me.env?.data ?? null;
  // status.<domain>: the owner's view, read-only, three pages (D2, spike §5.11).
  const owner = user?.route === "status";
  // While the site is incomplete the Setup wizard is shown first (D10).
  const setup = useRead<{ complete: boolean }>(user && !owner && user.role !== "read" ? "setup" : null, 600_000);
  const incomplete = setup.env?.data?.complete === false;
  const nav = owner ? NAV.filter((n) => ["/", "/physical", "/modules"].includes(n.to)) : NAV;
  const [busy, setBusy] = useState(false);
  const s = site.env?.data?.site;

  let page;
  if ((path === "/" || path === "") && owner) page = <OwnerOverview />;
  else if (owner && !["/physical", "/modules"].some((p) => path === p || path.startsWith(`${p}/`))) page = <OwnerOverview />;
  else if ((path === "/" || path === "") && incomplete) page = <Setup />;
  else if (path === "/" || path === "") page = <Overview />;
  else if (path === "/setup") page = <Setup />;
  else if (path === "/physical") page = <Physical />;
  else if (path === "/modules") page = <Modules />;
  else if (path.startsWith("/modules/")) page = <ModulePage name={decodeURIComponent(path.slice("/modules/".length))} />;
  else if (path === "/activity") page = <Activity />;
  else if (path === "/environments") page = <Environments />;
  else if (path === "/identity") page = <Identity />;
  else if (path === "/backup") page = <Backup />;
  else if (path === "/site") page = <Site />;
  else {
    const n = NAV.find((x) => active(path, x.to));
    page = (
      <div className="page">
        <h1>{n?.label ?? "Not found"}</h1>
        <p className="muted">{n ? "This page comes with a later phase of the console (ADR-034 P4)." : "No such page."}</p>
      </div>
    );
  }

  const refresh = () => {
    setBusy(true);
    void refreshAll().finally(() => setTimeout(() => setBusy(false), 2500));
  };

  return (
    <MeContext.Provider value={user}>
    <div className="shell">
      <nav className="nav">
        <div className="brand">
          <div className="brand-name">TAPPaaS</div>
          <div className="brand-site">{s?.displayName ?? s?.name ?? "…"}</div>
        </div>
        <ul>
          {nav.map((n) => (
            <li key={n.to}>
              {n.live ? (
                <Link to={n.to} className={active(path, n.to) ? "nav-item nav-active" : "nav-item"}>
                  {n.label}
                </Link>
              ) : (
                <span className="nav-item nav-later" title="later phase">
                  {n.label}
                </span>
              )}
            </li>
          ))}
        </ul>
        <div className="nav-foot">
          <div>{s?.channel ? `channel ${s.channel}` : ""}</div>
          <div>tappaas-cicd · console P2</div>
        </div>
      </nav>
      <div className="main">
        <header className="topbar">
          <span className="topbar-site">
            site <b>{s?.name ?? "…"}</b>
          </span>
          <span className="spacer" />
          <button className="btn" onClick={refresh} disabled={busy || owner} title="Ask the console to re-run its reads now (changes nothing on the site)">
            {busy ? "Refreshing…" : "Refresh"}
          </button>
          <span className="user" title={user ? `via ${user.via}${user.groups.length ? ` · ${user.groups.join(", ")}` : ""}` : ""}>
            {user ? `${user.user ?? "local"} · ${user.role}${user.route === "status" ? " (status)" : ""}` : "…"}
          </span>
        </header>
        {page}
      </div>
    </div>
    </MeContext.Provider>
  );
}
