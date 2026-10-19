// Day2.tsx — Setup's second tab: the guided sequences that grow a site once it
// is installed. Each is a card that says in one line what it does, and a
// button that opens its sequence: the Setup wizard's steps (operate.tsx's
// StepView, Change → Preview → Apply → Result) over the schema-driven field
// form where the verb has one. WiFi has a card per client zone (Wifi.tsx).

import { ReactNode, useEffect } from "react";
import { useRead } from "../api";
import { OperateButton } from "../operate";
import { canOperate, useMe } from "../ui";
import { AddNodeButton } from "./AddNode";
import { addEnvironmentSteps } from "./Environments";
import { SiteRead } from "../types";
import { ApIn, ZoneIn, wifiVerb, wifiZones } from "../wizards";
import { SetupDoc, addStackSteps, enrolSteps } from "./Setup";
import { WifiButton } from "./Wifi";
import { BuddyButton } from "./Buddy";
import { SatelliteButton } from "./Satellite";
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

export function Day2({ doc }: { doc: SetupDoc | null }) {
  const me = useMe();
  const zones = useRead<ZoneIn[]>("zones");
  const apsRead = useRead<ApIn[]>("aps");
  const site = useRead<SiteRead>("site").env?.data?.site;
  const aps = apsRead.env?.data ?? [];
  const wifi = wifiZones(zones.env?.data ?? [], aps);
  // /setup/day2#wifi-<zone> (Day 1's WiFi step): that card, once it is there.
  const target = window.location.hash.slice(1);
  const there = target !== "" && (target === "wifi" ? wifi.length > 0 : wifi.some((z) => `wifi-${z.zone}` === target));
  useEffect(() => {
    if (there) document.getElementById(target)?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [there, target]);
  return (
    <>
      {doc && !doc.complete ? (
        <p className="readstate readstate-warn">The installation is not complete yet (Day 1). These sequences work now, but most expect the foundation in place.</p>
      ) : null}
      {me && !canOperate(me) ? <p className="readstate">You read the console as {me.role}: the sequences need an operator.</p> : null}
      <Group title="The site">
        <WizardCard title="Add a node" action={<AddNodeButton label="Add a node…" />}>
          A new machine becomes a Proxmox node of this site: declared, installed over the network, joined, its lan uplink set.
        </WizardCard>
        <WizardCard title="Add a satellite" action={<SatelliteButton />}>
          A rented machine with a public IPv4 gives a site without one public ingress and the admin-VPN relay.
        </WizardCard>
      </Group>
      <Group title="Environments, people and stacks">
        <WizardCard title="Add an environment" action={<OperateButton label="Add an environment…" title="Add an environment" steps={addEnvironmentSteps()} />}>
          A new environment — its record, its zone, its domain — then the reconcile that makes it live.
        </WizardCard>
        <WizardCard title="Add a user" action={<OperateButton label="Add a user…" title="Add a user" steps={() => identitySteps("user", "add")} />}>
          A person who signs in: their name, email, groups and roles, staged and then pushed to Authentik.
        </WizardCard>
        <WizardCard title="Add a stack" action={<OperateButton label="Add a stack…" title="Add a stack" steps={addStackSteps()} />}>
          Every module of a stack installed in dependency order; the preview is the plan.
        </WizardCard>
      </Group>
      <Group title="Access and backup">
        <WizardCard title="Enrol a device" action={<OperateButton label="Enrol a device…" title="Enrol a device in the admin VPN" steps={enrolSteps()} />}>
          A laptop or phone joins the admin VPN; the result is its WireGuard file to download.
        </WizardCard>
        <WizardCard title="Add a backup buddy" action={<BuddyButton />}>
          Another site's PBS keeps an off-site copy — pulled through its own tunnel — or this site keeps theirs.
        </WizardCard>
      </Group>
      <Group title="WiFi" id="wifi">
        {wifi.map((z) => (
          <WizardCard key={z.zone} id={`wifi-${z.zone}`} on={target === `wifi-${z.zone}`} title={`${wifiVerb(z)} WiFi for ${z.zone}`} tag={z.type} action={<WifiButton z={z} aps={aps} site={site?.name ?? ""} />}>
            {z.ssids.length ? (
              <>Broadcast as {z.ssids.map((s) => `${s.name} on ${s.ap}${s.security ? ` (${s.security})` : ""}`).join(", ")}; devices that join land on VLAN {z.vlan ?? "?"}.</>
            ) : (
              <>No SSID yet{z.declared ? ` (zones.json names ${z.declared}, no access point broadcasts it)` : ""}: an SSID that puts devices on VLAN {z.vlan ?? "?"}.</>
            )}
          </WizardCard>
        ))}
        {zones.env?.data && wifi.length === 0 ? <p className="muted small">No active Client or Guest zone.</p> : null}
        {apsRead.env?.error || apsRead.failure ? <p className="readstate readstate-fail">ap-controller list could not be read: {apsRead.env?.error ?? apsRead.failure}</p> : apsRead.env?.data && aps.length === 0 ? <p className="muted small">No access point is registered yet (ap-controller add).</p> : null}
      </Group>
    </>
  );
}
