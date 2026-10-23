// Site — the site as built, in four tabs (physical/views.ts). Overview (/site,
// /site/overview): the racks, the devices and the storage summed up, every
// finding linked to its view, Add node (a guided sequence) and Register joined
// nodes beside the site line; below it the site's records (spike §5.2,
// Appendix A): site.json (site-manager site show / modify), the update
// schedule, `site update` (Update now: the sweep's plan first, then the
// sweep), the release train's preview and status (tappaas-train.sh, text: it
// has no --json), and the repositories (hold / release / sync / stashes).
// Physical (/site/physical): the racks. Device (/site/device): every physical
// device and its connections, a node's uplinks on its card. Storage
// (/site/storage): the nodes, their pools and disks.

import { Read, useRead } from "../api";
import { OperateButton, Step } from "../operate";
import { fieldsStep } from "../fields";
import { SiteRead } from "../types";
import { ReactNode, useEffect } from "react";
import { KV, Link, ReadState, Section, navigate, since, useHash } from "../ui";
import { locationAnchor } from "../locations";
import { publicAddress, publicText } from "../zonegraph";
import { PHYSICAL_TABS, PhysicalView, VIEW_NAME, VIEW_PATH } from "../physical/views";
import { AddNodeButton } from "./AddNode";
import { Physical } from "./Physical";


const sm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "site-manager", verb, ...extra });

// A location as site-manager site show --json gives it (site-fields.json $defs.location).
interface Loc {
  displayName?: string;
  kind?: string;
  country?: string;
  city?: string;
  address?: string;
  timezone?: string;
  latitude?: number;
  longitude?: number;
}

const placeText = (l: Loc): string => [l.address, l.city, l.country?.toUpperCase()].filter(Boolean).join(", ") || "—";

interface Repo {
  name: string;
  url?: string;
  branch?: string;
  path?: string;
  managed?: string;
  hold?: { reason?: string; until?: string } | null;
}

export const SITE_TABS = PHYSICAL_TABS.map((v) => ({ view: v, name: VIEW_NAME[v], path: VIEW_PATH[v] }));

// Beside the Overview's site line: the nodes the site gains.
function NodeActions() {
  return (
    <span className="toolbar">
      <AddNodeButton />
      <OperateButton label="Register joined nodes…" title="site-manager node reconcile" steps={[sm("site-manager node reconcile", "node reconcile")]} />
    </span>
  );
}

// The site's record (site.json, site-fields.json), each part in its card:
// Site — who and where it is, its WAN, and its settings; Updates — the
// schedule, the channel and what an update may do. Each Modify is the schema's
// form, limited to its card's fields. hardware.nodes is drawn by the Device and
// Storage views, backup by the Backup page, the repositories just below. The
// site's locations are site-manager location's: the primary one (where the
// site is, its timezone the site's) on the card, every one in its Locations
// section with the location forms.
const SITE_FIELDS = ["name", "displayName", "version", "defaultEnvironment", "owner", "email", "primaryLocation", "locale", "keyboard", "network"];
const SETTINGS_FIELDS = ["ipv6", "dnssec", "branding", "dnsBlocklists", "diskAutoGrow", "requireSigned"];
const UPDATE_FIELDS = ["updateSchedule", "channel", "automaticReboot", "snapshotRetention"];

// A value as the card shows it: absent is the schema's default, an object its
// fields, a list its items.
function val(v: unknown, absent = "not set"): ReactNode {
  if (v === undefined) return <span className="muted">{absent}</span>;
  if (v === null) return <span className="muted">none</span>;
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (Array.isArray(v)) return v.length ? v.map((x) => (typeof x === "object" ? JSON.stringify(x) : String(x))).join(", ") : <span className="muted">none</span>;
  if (typeof v === "object") {
    const e = Object.entries(v as Record<string, unknown>);
    if (!e.length) return <span className="muted">empty</span>;
    return (
      <span className="kv-inline">
        {e.map(([k, x]) => (
          <span key={k}>
            <span className="muted">{k}</span> {typeof x === "object" && x !== null ? (Array.isArray(x) ? x.join(", ") : JSON.stringify(x)) : String(x)}
          </span>
        ))}
      </span>
    );
  }
  return String(v);
}

const siteModify = (title: string, fields: string[], note: string) => () => [fieldsStep({ title, bin: "site-manager", verb: "site modify", kind: "site", name: null, mode: "modify", fields, note })];

// Above the Overview's physical summary: the Site card and the Updates card.
function SiteTop({ r }: { r: Read<SiteRead> }) {
  const d = r.env?.data;
  const s = (d?.site ?? {}) as Record<string, unknown> & {
    locations?: Record<string, Loc>;
    primaryLocation?: string;
    network?: { isp?: string | null; publicIp?: string };
    updateSchedule?: { frequency?: string; weekday?: string; hour?: number };
  };
  const sched = s.updateSchedule;
  const last = d?.lastSweep;
  const repos = (d?.repositories ?? []) as Repo[];
  const locations = Object.entries(s.locations ?? {}).map(([name, l]) => ({ ...l, name }));
  const primary = locations.find((l) => l.name === s.primaryLocation) ?? null;
  const others = locations.filter((l) => l !== primary).sort((a, b) => a.name.localeCompare(b.name));
  const pub = publicText(publicAddress({ network: { publicIp: s.network?.publicIp ?? null } }, d?.wan ?? null));
  return (
    <div className="site-records">
      <ReadState env={r.env} failure={r.failure} what="site" />
      <div className="grid2">
        <Section title="Site" aside={<OperateButton label="Modify…" title="The site" steps={siteModify("site-manager site modify (the site)", [...SITE_FIELDS, ...SETTINGS_FIELDS], "Writes site.json: one modify for every field changed.")} />}>
          <KV
            rows={[
              ["name", val(s.name)],
              ["display name", val(s.displayName)],
              ["version", val(s.version)],
              ["default environment", val(s.defaultEnvironment)],
              ["owner", val(s.owner)],
              ["email", val(s.email)],
            ]}
          />
          <h3>Location</h3>
          {primary ? (
            <KV
              rows={[
                ["primary location", primary.displayName && primary.displayName !== primary.name ? `${primary.displayName} (${primary.name})` : primary.name],
                ["place", placeText(primary)],
                ["timezone", val(primary.timezone, "not set — every node and guest falls back to UTC")],
                ...(primary.latitude !== undefined || primary.longitude !== undefined ? [["coordinates", `${primary.latitude ?? "?"}, ${primary.longitude ?? "?"}`] as [string, ReactNode]] : []),
                ["locale", val(s.locale)],
                ["keyboard", val(s.keyboard)],
              ]}
            />
          ) : (
            <p className="muted">No primary location: add the site's own below, with its timezone.</p>
          )}
          <h3>Network</h3>
          <KV rows={[["ISP", val(s.network?.isp)], ["public IP", val(s.network?.publicIp)], ["WAN", pub]]} />
          <h3>Settings</h3>
          <KV
            rows={[
              ["IPv6", val(s.ipv6, "off (default)")],
              ["DNSSEC", val(s.dnssec, "default")],
              ["branding", val(s.branding, "the generated logo")],
              ["DNS blocklists", val(s.dnsBlocklists, "none")],
              ["disk auto-grow", val(s.diskAutoGrow, "on, the defaults")],
              ["require signed", val(s.requireSigned, "no (default)")],
            ]}
          />
        </Section>
        <Section title="Updates and repositories" aside={<OperateButton label="Change…" title="Updates" steps={siteModify("site-manager site modify (updates)", UPDATE_FIELDS, "The schedule, the channel, automatic reboot and the snapshots kept.")} />}>
          <KV
            rows={[
              ["frequency", val(sched?.frequency)],
              ["weekday", val(sched?.weekday, "—")],
              ["hour", sched?.hour !== undefined ? `${sched.hour}:00` : val(undefined)],
              ["channel", val(s.channel)],
              ["automatic reboot", val(s.automaticReboot)],
              ["snapshots kept", val(s.snapshotRetention)],
              ["last sweep", last ? `${last.end_time ?? "?"} · ${last.succeeded ?? "?"} of ${last.total ?? "?"} ${last.ok ? "ok" : "with failures"}` : val(undefined, "none yet")],
            ]}
          />
          <div className="toolbar">
            <OperateButton label="Release train: preview" title="tappaas-train.sh preview" steps={[{ title: "tappaas-train.sh preview — the last release against 'if released now'", bin: "tappaas-train.sh", verb: "preview", note: "Nothing built, nothing moved; it writes config/train-preview.json. Text output: the train has no --json yet." }]} />
            <OperateButton label="Release train: status" title="tappaas-train.sh status" steps={[{ title: "tappaas-train.sh status", bin: "tappaas-train.sh", verb: "status" }]} />
            <OperateButton label="Reconcile repositories…" title="site-manager repository reconcile" steps={[sm("site-manager repository reconcile", "repository reconcile")]} />
          </div>
          <table className="table compact">
            <thead>
              <tr><th>repository</th><th>branch</th><th>managed</th><th>hold</th><th /></tr>
            </thead>
            <tbody>
              {repos.map((x) => (
                <tr key={x.name}>
                  <td className="mono" title={x.url}>{x.name}</td>
                  <td className="mono">{x.branch ?? ""}</td>
                  <td>{x.managed ?? ""}</td>
                  <td>{x.hold ? `held${x.hold.until ? ` until ${x.hold.until}` : ""}${x.hold.reason ? ` — ${x.hold.reason}` : ""}` : ""}</td>
                  <td className="toolbar">
                    <OperateButton label="Sync…" title={`site-manager repository sync ${x.name}`} steps={[sm(`site-manager repository sync ${x.name}`, "repository sync", { fixed: [x.name], note: "The preview (--dry-run) reports the commits, any pending migration and the modules it would move." })]} />
                    {x.hold ? (
                      <OperateButton label="Release" title={`site-manager repository release ${x.name}`} steps={[sm(`site-manager repository release ${x.name}`, "repository release", { fixed: [x.name] })]} />
                    ) : (
                      <OperateButton label="Hold…" title={`site-manager repository hold ${x.name}`} steps={[sm(`site-manager repository hold ${x.name}`, "repository hold", { fixed: [x.name] })]} />
                    )}
                    <OperateButton label="Stashes" title={`site-manager repository stash list ${x.name}`} steps={[{ ...sm(`site-manager repository stash list ${x.name}`, "repository stash"), words: ["repository", "stash", "list"], fixed: [x.name] }]} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="muted small">
            The nodes are the Device and Storage views', and the backup target the <Link to="/backup">Backup</Link> page's.
          </p>
        </Section>
      </div>
      <Locations primary={primary?.name ?? null} rows={primary ? [primary, ...others] : others} />
    </div>
  );
}

// Every place the site cares about (site-manager location): its own buildings,
// a provider's data centre, a buddy's site. Add and Modify are the schema's
// location form; Delete is refused by site-manager for the primary location and
// for one a peer or device names, and needs the name typed.
function Locations({ primary, rows }: { primary: string | null; rows: (Loc & { name: string })[] }) {
  // /site#location-<name> (a device's location line): that row, once it is there.
  const hash = useHash();
  const there = rows.some((l) => locationAnchor(l.name) === hash);
  useEffect(() => {
    // Down to the row only: in a narrow window the table is wider than the
    // page, and scrollIntoView would also scroll it sideways off the menu.
    const el = there ? document.getElementById(hash) : null;
    if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY - window.innerHeight / 2, behavior: "smooth" });
  }, [there, hash]);
  const loc = (verb: string, name: string | null, title: string, note: string): Step =>
    fieldsStep({ title, bin: "site-manager", verb: `location ${verb}`, fixed: name ? [name] : [], kind: "location", name, mode: name ? "modify" : "add", keep: verb === "add" ? ["--primary"] : [], note });
  return (
    <div>
      <Section
        title="Locations"
        aside={<OperateButton label="Add location…" title="Add a location" steps={() => [loc("add", null, "site-manager location add", "A place by name: the name is how peers, rooms and devices name it, and cannot change. --primary makes it the site's own, whose timezone every node and guest takes.")]} />}
      >
        {rows.length === 0 ? (
          <p className="muted">No locations yet.</p>
        ) : (
          <table className="table compact">
            <thead>
              <tr><th>location</th><th>kind</th><th>place</th><th>timezone</th><th /></tr>
            </thead>
            <tbody>
              {rows.map((l) => (
                <tr key={l.name} id={locationAnchor(l.name)} className={hash === locationAnchor(l.name) ? "row-target" : undefined}>
                  <td className="mono" title={l.displayName}>{l.name}{l.name === primary ? <span className="muted"> · primary</span> : null}</td>
                  <td>{l.kind ?? "site"}</td>
                  <td>{placeText(l)}</td>
                  <td className="mono">{l.timezone ?? ""}</td>
                  <td className="toolbar">
                    <OperateButton label="Modify…" title={`Modify location ${l.name}`} steps={() => [loc("modify", l.name, `site-manager location modify ${l.name}`, l.name === primary ? "The primary location: its timezone is the site's, and the next update sets every node and guest to it." : "Its place: what an off-site copy kept there is compared with.")]} />
                    {l.name !== primary ? (
                      <OperateButton label="Delete…" kind="danger" title={`Delete location ${l.name}`} steps={[sm(`site-manager location delete ${l.name}`, "location delete", { fixed: [l.name], note: "Refused while a backup peer, room or device names it. Deleting needs its name typed after the preview." })]} />
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p className="muted small">The primary location is where the site is; make another one primary in the Site card's Modify. A backup buddy's place is a location of kind remote.</p>
      </Section>
    </div>
  );
}

export function Site({ view = "overview" }: { view?: PhysicalView }) {
  const r = useRead<SiteRead>("site");
  const s = (r.env?.data?.site ?? {}) as Record<string, unknown>;
  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Site</h1>
        <span className="muted">{s.displayName ? String(s.displayName) : String(s.name ?? "")} as built{view === "overview" ? ` · site-manager read ${since(r.env?.at)}` : ""}</span>
        <span className="spacer" />
        {view === "overview" ? (
          <OperateButton
            label="Update now…"
            kind="primary"
            title="site-manager update"
            steps={[
              sm("site-manager update — the whole-site sweep, now", "update", {
                hide: ["--no-git-pull"],
                note: "The preview is the sweep's plan (update-tappaas --dry-run): nothing starts. Apply starts update-tappaas.service; while it runs the console starts no job, and its journal lands in Activity.",
              }),
            ]}
          />
        ) : null}
      </div>
      <div className="tabs" role="tablist">
        {SITE_TABS.map((t) => (
          <button key={t.view} role="tab" aria-selected={view === t.view} className={view === t.view ? "tab tab-on" : "tab"} onClick={() => navigate(t.path)}>
            {t.name}
          </button>
        ))}
      </div>
      {view === "overview" ? <SiteTop r={r} /> : null}
      <Physical embedded view={view} aside={view === "overview" ? <NodeActions /> : undefined} />
    </div>
  );
}
