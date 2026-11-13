// App.tsx — the shell: the left navigation (the site's name at its top, the
// reader and a refresh at its foot) and the page. The Assistant drawer (P3)
// opens on every page when the backend says the assistant is available.

import { useEffect, useState } from "react";
import { refreshAll, useRead } from "./api";
import { AssistantApi, AssistantContext, AssistantDrawer, Focus, focusOf } from "./assistant";
import { Activity } from "./pages/Activity";
import { AssetPage } from "./pages/AssetPage";
import { Assets } from "./pages/Assets";
import { Backup } from "./pages/Backup";
import { Environments } from "./pages/Environments";
import { Health } from "./pages/Health";
import { RulePage, RulesPage } from "./pages/Rules";
import { ZonesPage } from "./pages/Zones";
import { Identity } from "./pages/Identity";
import { Setup } from "./pages/Setup";
import { Site } from "./pages/Site";
import { ModulePage } from "./pages/ModulePage";
import { Modules } from "./pages/Modules";
import { Security } from "./pages/Security";
import { Overview } from "./pages/Overview";
import { Performance, perfTabOf } from "./pages/Performance";
import { MOVED_PATHS, viewOfPath } from "./physical/views";
import { AssistantStatus, Me, SiteRead } from "./types";
import { Link, MeContext, replacePath, usePath } from "./ui";

// The site as built and its assets are the Site page's tabs (physical/views.ts);
// the zones are a tab of Environments, Day 1 and Day 2 the tabs of Wizards.
const NAV: { to: string; label: string; live: boolean }[] = [
  { to: "/", label: "Overview", live: true },
  { to: "/setup", label: "Wizards", live: true },
  { to: "/health", label: "Health", live: true },
  { to: "/security", label: "Security", live: true },
  { to: "/performance", label: "Performance", live: true },
  { to: "/site", label: "Site", live: true },
  { to: "/environments", label: "Environments", live: true },
  { to: "/modules", label: "Modules", live: true },
  { to: "/identity", label: "Identity", live: true },
  { to: "/backup", label: "Backup", live: true },
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
  // While the site is incomplete the Overview says so in one line and links
  // to the Day 1 setup wizard (D10); only /setup/day1 shows the wizard itself.
  const setup = useRead<{ complete: boolean }>(user && user.role === "installer" ? "setup" : null, 600_000);
  const incomplete = setup.env?.data?.complete === false;
  // The views' earlier addresses keep working (bookmarks, ?select=).
  useEffect(() => {
    const to = MOVED_PATHS[path.replace(/\/+$/, "")];
    if (to) replacePath(`${to}${window.location.search}`);
    // A zone's earlier address: Environments with ?zone=.
    if (path === "/environments" && new URLSearchParams(window.location.search).has("zone")) replacePath(`/environments/zones${window.location.search}`);
    // An asset's earlier address: /assets/<name>, now a page of Site's Assets tab.
    if (path.startsWith("/assets/")) replacePath(`/site${path}${window.location.search}${window.location.hash}`);
    // The Operations page is gone: its root causes are Health's list, its sweep is on Assets.
    if (path === "/operations") replacePath(`/health${window.location.search}`);
  }, [path]);
  const view = viewOfPath(path);
  const [busy, setBusy] = useState(false);
  const s = site.env?.data?.site;
  // The assistant (D7): only when LiteLLM answers with the console's key.
  const astatus = useRead<AssistantStatus>(user ? "assistant/status" : null, 120_000).env?.data ?? null;
  const [drawer, setDrawer] = useState(false);
  const [asked, setAsked] = useState<{ question: string; focus: Focus; n: number } | null>(null);
  const assistant: AssistantApi = {
    available: astatus?.available === true,
    open: drawer && astatus?.available === true,
    setOpen: setDrawer,
    ask: (question, focus) => {
      setDrawer(true);
      setAsked((a) => ({ question, focus: focus ?? focusOf(path, window.location.search), n: (a?.n ?? 0) + 1 }));
    },
  };

  let page;
  if (path === "/" || path === "") page = <Overview setupIncomplete={incomplete} />;
  else if (path === "/setup") page = <Setup />;
  else if (path === "/setup/day1") page = <Setup tab="Day 1" />;
  else if (path === "/setup/day2") page = <Setup tab="Day 2" />;
  else if (path === "/health") page = <Health />;
  else if (path === "/health/rules") page = <RulesPage />;
  else if (path.startsWith("/health/rules/")) page = <RulePage id={decodeURIComponent(path.slice("/health/rules/".length))} />;
  else if (path === "/performance" || path.startsWith("/performance/")) page = <Performance tab={perfTabOf(path)} />;
  else if (path === "/operations") page = null; // on its way to /health
  else if (view) page = <Site view={view} />;
  else if (path === "/modules") page = <Modules />;
  else if (path.startsWith("/modules/")) page = <ModulePage name={decodeURIComponent(path.slice("/modules/".length))} />;
  else if (path === "/activity") page = <Activity />;
  else if (path === "/environments") page = <Environments />;
  else if (path === "/environments/zones") page = <ZonesPage />;
  else if (path === "/identity") page = <Identity />;
  else if (path === "/site/assets") page = <Assets />;
  else if (path.startsWith("/site/assets/")) page = <AssetPage name={decodeURIComponent(path.slice("/site/assets/".length))} />;
  else if (path === "/backup") page = <Backup />;
  else if (path === "/security") page = <Security />;
  else {
    const n = NAV.find((x) => active(path, x.to));
    page = (
      <div className="page">
        <h1>{n?.label ?? "Not found"}</h1>
        <p className="muted">{n ? "This page comes with a later version of the console." : "No such page."}</p>
      </div>
    );
  }

  const refresh = () => {
    setBusy(true);
    void refreshAll().finally(() => setTimeout(() => setBusy(false), 2500));
  };

  return (
    <MeContext.Provider value={user}>
    <AssistantContext.Provider value={assistant}>
    <div className={`shell${assistant.open ? " with-drawer" : ""}`}>
      <nav className="nav">
        <div className="brand">
          <a className="brand-name" href="https://tappaas.org/operate/" target="_blank" rel="noreferrer" title="The operator documentation, tappaas.org">TAPPaaS Site:</a>
          <div className="brand-site">{s?.displayName ?? s?.name ?? "…"}</div>
        </div>
        <ul>
          {NAV.map((n) => (
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
        {assistant.available ? (
          <button className={`nav-item nav-assistant${assistant.open ? " nav-active" : ""}`} onClick={() => setDrawer(!drawer)} title={astatus?.reason}>
            ✦ Assistant <span className="nav-sub">via LiteLLM</span>
          </button>
        ) : null}
        <div className="nav-foot">
          <div className="nav-user" title={user ? `via ${user.via}${user.groups.length ? ` · ${user.groups.join(", ")}` : ""}` : ""}>
            {user ? `${user.user ?? "local"} · ${user.role}` : "…"}
          </div>
          <button className="nav-refresh" onClick={refresh} disabled={busy} title="Ask the console to re-run its reads now (changes nothing on the site)">
            {busy ? "Refreshing…" : "Refresh"}
          </button>
          <div>{s?.channel ? `channel ${s.channel}` : ""}</div>
          <div>tappaas-cicd · console P3</div>
        </div>
      </nav>
      <div className="main">
        {page}
      </div>
      {/* Mounted while available, so a conversation survives closing the drawer. */}
      {assistant.available && astatus ? <AssistantDrawer status={astatus} focus={focusOf(path, window.location.search)} site={s?.name ?? "…"} asked={asked} open={assistant.open} onClose={() => setDrawer(false)} /> : null}
    </div>
    </AssistantContext.Provider>
    </MeContext.Provider>
  );
}
