// Day2.tsx — Setup's second tab: the guided sequences that grow a site once it
// is installed. Each is a card that says in one line what it does, and a
// button that opens its sequence: the Setup wizard's steps (operate.tsx's
// StepView, Change → Preview → Apply → Result) over the schema-driven field
// form where the verb has one. WiFi has a card per client zone (Wifi.tsx).
// The physical site is a step with its state (setup.ts physicalStep): the
// rooms at each location, the racks, the nodes and switches placed, and the
// devices the cluster cannot see recorded.

import { ReactNode, useEffect, useState } from "react";
import { useRead } from "../api";
import { Operate, OperateButton } from "../operate";
import { useOpenedBy } from "../opener";
import { RecordDeviceButton, placeSteps, placesFor, rackAddSteps, roomAddSteps } from "../physical/rackops";
import { LocationLink } from "../locations";
import { viewLink } from "../physical/views";
import { Link, canOperate, useMe } from "../ui";
import { AddNodeButton } from "./AddNode";
import { addEnvironmentSteps } from "./Environments";
import { SiteRead, Topology } from "../types";
import { ApIn, SiteSsid, ZoneIn, wifiZones } from "../wizards";
import { SetupDoc, addStackSteps, enrolSteps } from "./Setup";
import { WIFI_TEXT, WifiButton } from "./Wifi";
import { BuddyButton } from "./Buddy";
import { SatelliteButton } from "./Satellite";
import { ADOPT_TEXT, AdoptButton } from "./Adopt";
import { BACKUP_KEYS_TEXT, BackupKeysButton } from "./BackupKeys";
import { identitySteps } from "./Identity";

export function WizardCard({ id, title, tag, on, children, action }: { id?: string; title: string; tag?: string; on?: boolean; children: ReactNode; action: ReactNode }) {
  return (
    <div className={`wizard-card${on ? " wizard-card-on" : ""}`} id={id}>
      <div className="wizard-card-head">
        <b>{title}</b>
        {tag ? <span className="class-tag">{tag}</span> : null}
      </div>
      <p className="small">{children}</p>
      <div className="wizard-card-action">{action}</div>
    </div>
  );
}

function Group({ id, title, children }: { id?: string; title: string; children: ReactNode }) {
  return (
    <section className="wizard-group" id={id}>
      <h2>{title}</h2>
      <div className="wizard-cards">{children}</div>
    </section>
  );
}

// Place a device: one of the devices placed nowhere (the nodes and switches
// first), then its Place form — a rack and its units, or a room at its
// location — with the plate the catalog has for its model.
function PlaceDeviceCard({ t }: { t: Topology | null }) {
  const v = t?.positions ?? null;
  const [device, setDevice] = useState("");
  const [open, setOpen] = useState<{ device: string; prefill: Record<string, string | boolean | string[]> } | null>(null);
  const operator = canOperate(useMe());
  // open_console place-device {device, rack, u, …}: the form for that device.
  useOpenedBy("place-device", undefined, (values) => {
    const d = typeof values.device === "string" ? values.device : "";
    const { device: _d, ...rest } = values;
    if (d) setOpen({ device: d, prefill: rest });
  }, operator && v !== null);
  const first = (k: string) => (k === "node" ? 0 : k === "switch" ? 1 : 2);
  const choices = [...(v?.unplaced ?? [])].filter((u) => !u.seen).sort((a, b) => first(a.kind) - first(b.kind));
  const pick = device || choices[0]?.device || "";
  const here = placesFor(v, pick);
  const core = (t?.nodes.length ?? 0) + (t?.switches.length ?? 0);
  const coreOpen = choices.filter((u) => u.kind === "node" || u.kind === "switch").length;
  return (
    <WizardCard
      title="Place the nodes and switches"
      action={
        operator ? (
          <span className="toolbar">
            <select value={pick} onChange={(e) => setDevice(e.target.value)} disabled={!choices.length}>
              {choices.map((u) => (
                <option key={u.device} value={u.device}>{u.device} · {u.kind}{u.location ? ` at ${u.location}` : ""}</option>
              ))}
            </select>
            <button className="btn" disabled={!pick || (!here.racks.length && !here.rooms.length)} title={pick && !here.racks.length && !here.rooms.length ? `${here.location ?? "its location"} has no room or rack yet` : undefined} onClick={() => setOpen({ device: pick, prefill: {} })}>
              Place…
            </button>
            {open ? (
              <Operate
                title={`Place ${open.device}`}
                steps={placeSteps(open.device, v).map((s) => ({ ...s, prefill: { ...s.prefill, ...open.prefill } }))}
                onClose={() => setOpen(null)}
              />
            ) : null}
          </span>
        ) : null
      }
    >
      {v === null
        ? "The topology carries no positions yet."
        : !v.racks.length && !(v.rooms ?? []).some((r) => r.recorded)
          ? "Add a room or a rack first: a device stands in a rack at its units, or loose in a room."
          : choices.length
            ? <>Where each device stands: a rack and its units, or loose in a room at its own location. {core - coreOpen} of {core} nodes and switches placed; {choices.length} device{choices.length === 1 ? "" : "s"} placed nowhere.</>
            : "Every device is placed."}
    </WizardCard>
  );
}

// The rooms at each location, and Add a room… with the location dropdown.
function RoomsCard({ t }: { t: Topology | null }) {
  const v = t?.positions ?? null;
  const locs = (v?.locations ?? []).filter((l) => l.kind === "site" || l.rooms.length);
  return (
    <WizardCard title="Record the rooms" action={<OperateButton label="Add a room…" title="Add a room" steps={() => roomAddSteps()} />}>
      {v === null ? (
        "The topology carries no positions yet."
      ) : (
        <>
          Where the hardware stands, at one of the site's locations (the primary unless you choose another; a location the site lacks is added in the Site page's <Link to="/site#locations">Locations</Link>).{" "}
          {locs.map((l, i) => (
            <span key={l.name}>
              {i ? "; " : ""}
              <LocationLink name={l.name}>{l.displayName ?? l.name}</LocationLink>:{" "}
              {l.rooms.length
                ? l.rooms.map((r, j) => (
                    <span key={r}>
                      {j ? ", " : ""}
                      <Link to={viewLink("rack", `room:${r}`)}>{v.rooms?.find((x) => x.name === r)?.displayName ?? r}</Link>
                    </span>
                  ))
                : "no room"}
            </span>
          ))}
          {locs.length ? "." : null}
        </>
      )}
    </WizardCard>
  );
}

// What the cluster cannot see: the modem, a patch panel, a UPS.
function RecordCard({ t }: { t: Topology | null }) {
  const rec = (t?.devices ?? []).filter((d) => d.recorded);
  return (
    <WizardCard title="Record what the cluster cannot see" action={<RecordDeviceButton />}>
      A device nothing manages — the ISP's modem, an ONT, a UPS, a patch panel — with its kind, ports and location; then place it.{" "}
      {rec.length ? <>Recorded: {rec.map((d) => d.name).join(", ")}.</> : "Nothing recorded yet."}
    </WizardCard>
  );
}

// The physical site: a step with its state from positions.json (every node
// and switch placed), its cards in the order the work goes.
function PhysicalSite({ doc }: { doc: SetupDoc | null }) {
  const t = useRead<Topology>("topology").env?.data ?? null;
  const step = doc?.steps.find((s) => s.id === "physical");
  return (
    <section className="wizard-group" id="physical">
      <h2>The physical view</h2>
      <div className="wizard-cards">
        <RoomsCard t={t} />
        <WizardCard title="Add a rack" action={<OperateButton label="Add a rack…" title="Add a rack" steps={rackAddSteps} opens={{ wizard: "add-rack" }} />}>
          A rack the site's hardware stands in: its height in units, its width, how its units are numbered, and its room.
        </WizardCard>
        <PlaceDeviceCard t={t} />
        <RecordCard t={t} />
      </div>
      <p className="small muted">
        {step?.detail ? <>{step.detail} · </> : null}Done when every node and switch is placed. The <Link to={viewLink("rack")}>Physical view</Link> draws the result by location, room and rack.
      </p>
    </section>
  );
}

export function Day2({ doc }: { doc: SetupDoc | null }) {
  const me = useMe();
  const zones = useRead<ZoneIn[]>("zones");
  const apsRead = useRead<ApIn[]>("aps");
  const site = useRead<SiteRead>("site").env?.data?.site;
  const ssidsRead = useRead<SiteSsid[]>("ssids");
  const wifi = wifiZones(zones.env?.data ?? [], ssidsRead.env?.data ?? []);
  // /setup/day2#wifi-<zone> (Day 1's WiFi step): that card, once it is there.
  const target = window.location.hash.slice(1);
  const there = target !== "" && (target.startsWith("wifi") ? wifi.length > 0 : target === "physical" ? doc !== null : false);
  useEffect(() => {
    if (there) document.getElementById(target.startsWith("wifi") ? "wifi" : target)?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [there, target]);
  return (
    <>
      {doc && !doc.complete ? (
        <p className="readstate readstate-warn">The installation is not complete yet (Day 1). These sequences work now, but most expect the foundation in place.</p>
      ) : null}
      {me && !canOperate(me) ? <p className="readstate">You read the console as {me.role}: the sequences need an operator.</p> : null}
      <Group title="The site">
        <WizardCard title="Add a node" action={<AddNodeButton label="Add a node…" />}>
          Adding a new physical machine as a Proxmox node of this site. This includes defining its connectivity and its boot disk, configuring it in the cluster, and setting up its data pools.
        </WizardCard>
        <WizardCard title="Adopt a machine" action={<AdoptButton />}>
          {ADOPT_TEXT}
        </WizardCard>
        <WizardCard title="Add a satellite" action={<SatelliteButton />}>
          A rented machine with a public IPv4 gives a site without one public ingress and the admin-VPN relay.
        </WizardCard>
      </Group>
      <PhysicalSite doc={doc} />
      <Group title="Environments, people and stacks">
        <WizardCard title="Add an environment" action={<OperateButton label="Add an environment…" title="Add an environment" steps={addEnvironmentSteps()} opens={{ wizard: "add-environment" }} />}>
          A new environment — its record, its zone, its domain — then the reconcile that makes it live.
        </WizardCard>
        <WizardCard title="Add a user" action={<OperateButton label="Add a user…" title="Add a user" steps={() => identitySteps("user", "add")} opens={{ wizard: "add-user" }} />}>
          A person who signs in: their name, email, groups and roles, staged and then pushed to Authentik.
        </WizardCard>
        <WizardCard title="Add a stack" action={<OperateButton label="Add a stack…" title="Add a stack" steps={addStackSteps()} opens={{ wizard: "add-stack" }} />}>
          Every module of a stack installed in dependency order; the preview is the plan.
        </WizardCard>
      </Group>
      <Group title="Access and backup">
        <WizardCard title="Enrol a device" action={<OperateButton label="Enrol a device…" title="Enrol a device in the admin VPN" steps={enrolSteps()} opens={{ wizard: "enrol-device" }} />}>
          A laptop or phone joins the admin VPN; the result is its WireGuard file to download.
        </WizardCard>
        <WizardCard title="Add a backup buddy" action={<BuddyButton />}>
          Another site's PBS keeps an off-site copy — pulled through its own tunnel — or this site keeps theirs.
        </WizardCard>
        <WizardCard title="Write the backup keys to a USB stick" action={<BackupKeysButton />}>
          {BACKUP_KEYS_TEXT}
        </WizardCard>
      </Group>
      <Group title="WiFi" id="wifi">
        {wifi.length > 0 ? (
          <WizardCard id="wifi-card" on={target.startsWith("wifi")} title="Add WiFi to a zone" action={<WifiButton zones={wifi} zone={target.startsWith("wifi-") ? target.slice(5) : null} site={site?.name ?? ""} />}>
            {WIFI_TEXT}
          </WizardCard>
        ) : null}
        {zones.env?.data && wifi.length === 0 ? <p className="muted small">No active Client, Guest or IoT zone.</p> : null}
        {ssidsRead.env?.error || ssidsRead.failure ? <p className="readstate readstate-fail">ap-manager ssid list could not be read: {ssidsRead.env?.error ?? ssidsRead.failure}</p> : null}
        {apsRead.env?.error || apsRead.failure ? <p className="readstate readstate-fail">ap-manager list could not be read: {apsRead.env?.error ?? apsRead.failure}</p> : null}
      </Group>
    </>
  );
}
