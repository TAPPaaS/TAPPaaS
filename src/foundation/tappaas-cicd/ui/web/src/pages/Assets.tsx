// Assets — every asset of the site in a tree, by where it stands: location →
// room → rack → asset (by its placement), the ones placed nowhere — in stock,
// ordered, or a device a switch port sees that nobody recorded — under their
// location's Not placed, the disposed ones under Disposed. Each asset with its
// stage, its role, its ports (the cables on them, a port's MAC) and the disks
// in it (by bay, with their health and pool); a disk in stock stands under
// its location's Not placed like any other asset. An asset
// opens its own page (AssetPage.tsx); a location, a room, a rack or a device
// no asset records opens beside the tree with its facts and its operations:
// a room's and a rack's record changed or deleted, a room or a rack added, a
// device recorded or placed. Read from the positions the topology carries
// (asset-manager's record) and the CMDB's allocations: GET assets/tree.

import { ReactNode, useEffect, useMemo, useState } from "react";
import { useRead } from "../api";
import { AssetsSel, STAGES, assetsSelOf, assetsSelText, filterLocation, itemsOf, stageCounts } from "../assetview";
import { assetPath } from "../details";
import { DISK_COLOR, adoptOffer, diskText, healthText } from "../diskview";
import { OperateButton, Step } from "../operate";
import { faceplateAddSteps } from "../physical/faceplateform";
import { AddRoomButton, PlaceActions, RecordDeviceButton, RecordSeenButton, rackAddSteps, rackDeleteSteps, rackModifySteps, roomAddSteps, roomModifySteps } from "../physical/rackops";
import { viewLink } from "../physical/views";
import { LocationLink, locationOption, useSiteLocations } from "../locations";
import { AssetRow, AssetTree, AssetTreeItem, AssetTreeLocation, AssetTreePort, Topology } from "../types";
import { ClassIcon } from "../moduleicon";
import { CLASS_SYMBOL, assetClassOf } from "../classsymbol";
import { Badge, KV, Level, Link, ReadState, Section, canOperate, replacePath, since, useMe } from "../ui";

export const STAGE_LEVEL: Record<string, Level> = { ordered: "info", stock: "skip", placed: "info", operational: "pass", disposed: "unknown" };

export function StageBadge({ a }: { a: { stage: string; faulty?: boolean; faultNote?: string | null } }) {
  return (
    <>
      <Badge level={STAGE_LEVEL[a.stage] ?? "unknown"}>{a.stage}</Badge>
      {a.faulty ? <> <Badge level="warn" title={a.faultNote ?? undefined}>faulty</Badge></> : null}
    </>
  );
}

// A port as one short line: its connector, speed, MAC, role, and where its cables go.
export function portText(p: AssetTreePort): string {
  return [p.kind, p.speed, p.standard, p.bands?.join("/"), p.module, p.role, p.side, p.mac].filter(Boolean).join(" · ");
}

function Ports({ a }: { a: AssetRow }) {
  if (!a.ports.length) return null;
  const cabled = a.ports.filter((p) => p.cables.length).length;
  return (
    <details className="atree-ports">
      <summary>
        {a.ports.length} port{a.ports.length === 1 ? "" : "s"}
        {cabled ? `, ${cabled} cabled` : ""}
      </summary>
      <ul>
        {a.ports.map((p) => (
          <li key={p.name} className="small">
            <span className="mono">{p.name}</span> <span className="muted">{portText(p) || (p.listed ? "" : "only a cable names it")}</span>
            {p.cables.map((c, i) => (
              <span key={i} className="mono"> → {c.to}<span className="muted"> ({c.kind}{c.source === "recorded" ? ", recorded" : ""}{c.label ? `, ${c.label}` : ""}{c.via.length ? `, via ${c.via.join(", ")}` : ""})</span></span>
            ))}
          </li>
        ))}
      </ul>
    </details>
  );
}

// The disks in an asset, by bay: each its own asset (a link to its page),
// with its serial, size, kind, health and the pool it is a member of.
function Disks({ a }: { a: AssetRow }) {
  const adopt = adoptOffer(a);
  if (!a.disks.length && !adopt) return null;
  const bad = a.disks.filter((d) => d.state === "warn" || d.state === "fail").length;
  return (
    <details className="atree-ports">
      <summary>
        {a.disks.length} disk{a.disks.length === 1 ? "" : "s"}
        {bad ? `, ${bad} not healthy` : ""}
        {adopt ? ` · ${adopt.count} the CMDB knows, not recorded` : ""}
      </summary>
      <ul>
        {a.disks.map((d) => (
          <li key={d.name} className="small">
            <i className="st-swatch" style={{ background: DISK_COLOR[d.state] }} title={healthText(d)} />{" "}
            {d.bay ? <span className="muted">bay {d.bay} </span> : null}
            <Link to={assetPath(d.name)}>{d.displayName ?? d.name}</Link>
            {d.displayName ? <span className="muted mono"> {d.name}</span> : null}
            <span className="muted"> {diskText(d)}{d.state !== "ok" && d.ci ? ` · ${healthText(d)}` : ""}</span>
          </li>
        ))}
        {adopt ? <li className="small muted">Not recorded: {adopt.text} — Adopt the disks the CMDB knows… on its page.</li> : null}
      </ul>
    </details>
  );
}

// One row of the tree: an asset (a link to its page), or a device no asset records.
function Item({ tree, it, sel, pick }: { tree: AssetTree; it: AssetTreeItem; sel: AssetsSel | null; pick: (s: AssetsSel) => void }) {
  const a = it.asset ? tree.assets.find((x) => x.name === it.asset) ?? null : null;
  if (!a) {
    const on = sel?.kind === "device" && sel.id === it.device;
    return (
      <li>
        <div className={`atree-row${on ? " row-on" : ""}`}>
          {it.at ? <span className="muted small">{it.at}</span> : null}
          <button className="hlink" onClick={() => pick({ kind: "device", id: it.device })}>{it.device}</button>
          <span className="atree-kind">{it.kind}</span>
          <span className="muted small">{it.seen ? "seen by a switch port, recorded nowhere" : "no asset records it"}</span>
        </div>
      </li>
    );
  }
  return (
    <li>
      <div className="atree-row">
        {it.at ? <span className="muted small">{it.at}</span> : null}
        <ClassIcon cls={assetClassOf(a.kind)} size={18} />
        <Link to={assetPath(a.name)}>{a.displayName ?? a.name}</Link>
        {a.displayName && a.displayName !== a.name ? <span className="muted small mono">{a.name}</span> : null}
        <span className="atree-kind">{a.kind}</span>
        <StageBadge a={a} />
        {a.role ? <span className="small">plays <b>{a.role}</b></span> : null}
        {a.allocationDrift ? <Badge level="warn" title={`the CMDB has it allocated to ${a.cmdb?.allocatedTo ?? "nothing"}`}>CMDB differs</Badge> : null}
        <span className="muted small">{a.asDisk ? diskText(a.asDisk) : [a.vendor, a.model].filter(Boolean).join(" ")}</span>
      </div>
      <Ports a={a} />
      <Disks a={a} />
    </li>
  );
}

function Row({ label, kind, on, onClick, aside }: { label: ReactNode; kind: string; on: boolean; onClick?: () => void; aside?: ReactNode }) {
  return (
    <div className={`atree-row${on ? " row-on" : ""}`}>
      {CLASS_SYMBOL[kind] ? <ClassIcon cls={kind} size={18} /> : null}
      <span className="atree-kind">{kind}</span>
      {onClick ? <button className="hlink" onClick={onClick}>{label}</button> : <b>{label}</b>}
      {aside ? <span className="muted small">{aside}</span> : null}
    </div>
  );
}

function LocationTree({ tree, l, sel, pick }: { tree: AssetTree; l: AssetTreeLocation; sel: AssetsSel | null; pick: (s: AssetsSel) => void }) {
  const is = (kind: AssetsSel["kind"], id: string) => sel?.kind === kind && sel.id === id;
  const items = (xs: AssetTreeItem[]) => xs.map((it) => <Item key={`${it.device}:${it.asset ?? ""}`} tree={tree} it={it} sel={sel} pick={pick} />);
  return (
    <li>
      <Row kind="location" label={l.name ? l.displayName ?? l.name : "no location"} on={is("location", l.name)} onClick={l.name ? () => pick({ kind: "location", id: l.name }) : undefined} aside={`${itemsOf(l).length} device(s)${l.primary ? " · primary" : ""}`} />
      <ul>
        {l.rooms.map((r) => (
          <li key={r.name || "-"}>
            <Row kind="room" label={r.name ? r.displayName ?? r.name : "in no room"} on={is("room", r.name)} onClick={r.name ? () => pick({ kind: "room", id: r.name }) : undefined} aside={r.name && !r.recorded ? "not recorded" : undefined} />
            <ul>
              {r.racks.map((k) => (
                <li key={k.name}>
                  <Row kind="rack" label={k.displayName ?? k.name} on={is("rack", k.name)} onClick={() => pick({ kind: "rack", id: k.name })} aside={`${k.units}U · ${k.items.length} placed`} />
                  <ul>{items(k.items)}</ul>
                </li>
              ))}
              {r.loose.length ? (
                <li>
                  <Row kind="loose" label="in the room" on={false} />
                  <ul>{items(r.loose)}</ul>
                </li>
              ) : null}
            </ul>
          </li>
        ))}
        {l.unplaced.length ? (
          <li>
            <Row kind="not placed" label="in stock, ordered or unplaced" on={false} aside={`${l.unplaced.length}`} />
            <ul>{items(l.unplaced)}</ul>
          </li>
        ) : null}
        {l.disposed.length ? (
          <li>
            <details>
              <summary><span className="atree-kind">disposed</span> <span className="muted small">{l.disposed.length}</span></summary>
              <ul>{items(l.disposed)}</ul>
            </details>
          </li>
        ) : null}
      </ul>
    </li>
  );
}

// A location, a room, a rack or a device no asset records: its facts and operations.
function SelPanel({ sel, tree, t, close }: { sel: AssetsSel; tree: AssetTree; t: Topology | null; close: () => void }) {
  const operator = canOperate(useMe());
  const locations = useSiteLocations();
  const v = t?.positions ?? null;
  let title: ReactNode = sel.id;
  let body: ReactNode = <p className="muted">Not in the positions the topology carries.</p>;
  let actions: ReactNode = null;
  if (sel.kind === "location") {
    const l = tree.locations.find((x) => x.name === sel.id);
    const li = v?.locations?.find((x) => x.name === sel.id);
    if (l) {
      title = `${l.displayName ?? l.name} · location`;
      const place = li?.place ? [li.place.address, li.place.city, li.place.country].filter(Boolean).join(", ") : "";
      body = (
        <KV
          rows={[
            ["name", <LocationLink name={l.name}>{l.name}</LocationLink>],
            ["place", place || null],
            ["primary", l.primary ? "yes" : "no"],
            ["rooms", l.rooms.filter((r) => r.name).map((r) => r.name).join(", ") || null],
            ["devices", `${itemsOf(l).length} · ${l.unplaced.length} not placed · ${l.disposed.length} disposed`],
          ]}
        />
      );
      actions = <OperateButton label="Add a room…" title={`Add a room at ${l.name}`} steps={() => roomAddSteps(l.name)} />;
    }
  } else if (sel.kind === "room") {
    const room = v?.rooms?.find((x) => x.name === sel.id);
    if (room) {
      title = `${room.displayName ?? room.name} · room`;
      body = (
        <>
          <KV
            rows={[
              ["name", room.name],
              ["location", room.location ? <LocationLink name={room.location} /> : null],
              ["description", room.description],
              ["recorded", room.recorded ? "yes" : "no — only a rack's text names it"],
              ["racks", room.racks.join(", ") || null],
              ["loose in it", room.loose.map((m) => m.device).join(", ") || null],
            ]}
          />
          <p className="small"><Link to={viewLink("rack", `room:${room.name}`)}>Show in the Physical view →</Link></p>
        </>
      );
      const rmStep = (verb: string, title: string, extra: Partial<Step> = {}): Step => ({ title, bin: "asset-manager", verb, fixed: [room.name], ...extra });
      actions = room.recorded ? (
        <>
          <OperateButton label="Change…" title={`Room ${room.name}`} steps={() => roomModifySteps(room.name)} />
          <OperateButton label="Add a rack…" title="Add a rack" steps={rackAddSteps} />
          <RecordDeviceButton />
          {room.racks.length === 0 && room.loose.length === 0 ? <OperateButton label="Delete…" kind="danger" title={`Delete room ${room.name}`} steps={[rmStep("room delete", `asset-manager room delete ${room.name}`)]} /> : null}
        </>
      ) : /^[a-z][a-z0-9-]{0,62}$/.test(room.name) ? (
        <OperateButton label="Record the room…" title={`Record room ${room.name}`} steps={[rmStep("room add", `asset-manager room add ${room.name}`, locationOption(locations))]} />
      ) : (
        <p className="muted small">
          '{room.name}' is no room name (lower case letters, digits, dashes): record it as{" "}
          <span className="mono">asset-manager room add {room.name.toLowerCase().replace(/[^a-z0-9-]+/g, "-")} --display-name '{room.name}'</span>, then set each rack's room to it ({room.racks.map((r) => `rack modify ${r} --set room=…`).join(", ")}).
        </p>
      );
    }
  } else if (sel.kind === "rack") {
    const r = v?.racks.find((x) => x.name === sel.id);
    if (r) {
      title = `${r.displayName ?? r.name} · rack`;
      const used = r.placements.reduce((n, m) => n + (m.width === "full" ? m.height : 0), 0);
      body = (
        <>
          <KV
            rows={[
              ["name", r.name],
              ["height", `${r.units}U, ${r.width}, numbered ${r.numbering === "bottom-up" ? "from the bottom" : "from the top"}`],
              ["room", r.room],
              ["location", r.location ? <LocationLink name={r.location} /> : null],
              ["description", r.description],
              ["placed", `${r.placements.length} device(s) · ${used} of ${r.units} units at full width`],
            ]}
          />
          <p className="small"><Link to={viewLink("rack", `rack:${r.name}`)}>Show in the Physical view →</Link></p>
        </>
      );
      actions = (
        <>
          <OperateButton label="Change…" title={`Rack ${r.name}`} steps={() => rackModifySteps(r.name)} />
          <RecordDeviceButton />
          {r.placements.length === 0 ? <OperateButton label="Delete…" kind="danger" title={`Delete rack ${r.name}`} steps={() => rackDeleteSteps(r.name)} /> : null}
        </>
      );
    }
  } else {
    // A device the topology knows that no asset records, or one a switch port only sees.
    const seen = t?.devices?.find((x) => x.name === sel.id && x.source === "seen" && x.seen);
    const u = v?.unplaced.find((x) => x.device === sel.id);
    title = seen?.displayName ? `${seen.displayName} · seen` : sel.id;
    if (seen?.seen) {
      const s = seen.seen;
      body = (
        <>
          <p className="small">A switch port sees this device, and no record names it: nothing manages it and asset-manager does not record it yet.</p>
          <KV
            rows={[
              ["seen at", <Link to={assetPath(s.switch, s.port)}>{s.switch} port {s.port}</Link>],
              ["MAC", s.mac ? <span className="mono">{s.mac}</span> : <span className="muted">not reported</span>],
              ["LLDP", s.lldp ? `${s.lldp.name}${s.lldp.port ? ` · port ${s.lldp.port}` : ""}` : null],
              ["lease", s.lease ? [s.lease.hostname, s.lease.address].filter(Boolean).join(" · ") : null],
              ["location", seen.location ?? null],
            ]}
          />
          <p className="muted small">Record… keeps its MAC and records the port's link as its cable; it then has its own page here, where it is placed.</p>
        </>
      );
      actions = <RecordSeenButton d={seen} />;
    } else if (u || t) {
      body = (
        <>
          <KV rows={[["kind", u?.kind ?? null], ["vendor / model", [u?.vendor, u?.model].filter(Boolean).join(" · ") || null], ["location", u?.location ?? null], ["plate", u?.suggestion ?? null]]} />
          <p className="muted small">The topology knows this device and no asset records it: record the asset (Record a device…) and allocate it to {sel.id}, or allocate an asset in stock to it from the asset's page. It can be placed meanwhile.</p>
        </>
      );
      actions = (
        <>
          <PlaceActions device={sel.id} v={v} />
          <RecordDeviceButton />
        </>
      );
    }
  }
  return (
    <aside className="sidepanel">
      <header>
        <h2>{title}</h2>
        <button className="btn-x" onClick={close} aria-label="close">×</button>
      </header>
      {body}
      {actions && operator ? (
        <>
          <h3>Change</h3>
          <div className="toolbar">{actions}</div>
        </>
      ) : null}
    </aside>
  );
}

const selFromUrl = (): AssetsSel | null => assetsSelOf(new URLSearchParams(window.location.search).get("select"));

export function Assets() {
  const r = useRead<AssetTree>("assets/tree");
  const topo = useRead<Topology>("topology");
  const operator = canOperate(useMe());
  const tree = r.env?.data ?? null;
  const t = topo.env?.data ?? null;
  const [q, setQ] = useState("");
  const [sel, setSel] = useState<AssetsSel | null>(selFromUrl);
  useEffect(() => {
    const on = () => setSel(selFromUrl());
    window.addEventListener("popstate", on);
    return () => window.removeEventListener("popstate", on);
  }, []);
  const pick = (s: AssetsSel | null) => {
    setSel(s);
    replacePath(s ? `/assets?select=${encodeURIComponent(assetsSelText(s))}` : "/assets");
  };
  const counts = useMemo(() => (tree ? stageCounts(tree) : null), [tree]);
  const shown = tree ? tree.locations.map((l) => filterLocation(tree, l, q)).filter((l): l is AssetTreeLocation => l !== null) : [];
  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Assets</h1>
        <span className="muted">
          {tree ? `${tree.assets.length} asset(s) · ${STAGES.filter((s) => counts?.[s]).map((s) => `${counts![s]} ${s}`).join(" · ")}` : "…"}
          {r.env?.at ? ` · read ${since(r.env.at)}` : ""}
        </span>
        <span className="spacer" />
        {operator ? (
          <span className="toolbar">
            <AddRoomButton />
            <OperateButton label="Add a rack…" title="Add a rack" steps={rackAddSteps} />
            <RecordDeviceButton />
            <OperateButton label="Add a faceplate…" title="Add a faceplate" steps={faceplateAddSteps} hint="A plate for a device model the catalog lacks" />
          </span>
        ) : null}
      </div>
      <ReadState env={r.env} failure={r.failure} what="the assets (asset-manager's record, through the topology)" />
      {tree?.allocationsError ? <div className="readstate readstate-warn">The CMDB's allocations were not read: {tree.allocationsError}. The roles shown are asset-manager's record.</div> : null}
      {tree?.disksError && !tree.allocationsError ? <div className="readstate readstate-warn">The CMDB's disks were not read: {tree.disksError}. The disks are listed from asset-manager's record, without their health or pool.</div> : null}
      <div className="assets-view">
        <div className="assets-tree">
          <Section title="By location, room and rack" aside={<input className="search" type="search" placeholder="filter: name, kind, model, serial, role…" value={q} onChange={(e) => setQ(e.target.value)} />}>
            {tree && tree.assets.length === 0 && !tree.locations.some((l) => itemsOf(l).length) ? <p className="muted">No asset is recorded yet: Record a device… records one; a node, switch or access point the topology sees is listed here once an asset is allocated to it.</p> : null}
            {tree && q && shown.length === 0 ? <p className="muted">Nothing matches '{q}'.</p> : null}
            <ul className="atree">
              {tree ? shown.map((l) => <LocationTree key={l.name || "-"} tree={tree} l={l} sel={sel} pick={pick} />) : null}
            </ul>
          </Section>
        </div>
        {sel && tree ? <SelPanel sel={sel} tree={tree} t={t} close={() => pick(null)} /> : null}
      </div>
    </div>
  );
}
