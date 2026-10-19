// Day2.tsx — Setup's second tab: the guided sequences that grow a site once it
// is installed. Each is a card that says in one line what it does, and a
// button that opens its sequence: the Setup wizard's steps (operate.tsx's
// StepView, Change → Preview → Apply → Result) over the schema-driven field
// form where the verb has one.

import { ReactNode } from "react";
import { useRead } from "../api";
import { OperateButton } from "../operate";
import { canOperate, useMe } from "../ui";
import { AddNodeButton } from "./AddNode";
import { addEnvironmentSteps } from "./Environments";
import { SecretForm, SecretStatus, SetupDoc, addStackSteps, enrolSteps } from "./Setup";

export function WizardCard({ id, title, tag, children, action }: { id?: string; title: string; tag?: string; children: ReactNode; action: ReactNode }) {
  return (
    <div className="wizard-card" id={id}>
      <div className="wizard-card-head">
        <b>{title}</b>
        {tag ? <span className="class-tag">{tag}</span> : null}
      </div>
      <p className="small">{children}</p>
      <div className="wizard-card-action">{action}</div>
    </div>
  );
}

function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="wizard-group">
      <h2>{title}</h2>
      <div className="wizard-cards">{children}</div>
    </section>
  );
}

export function Day2({ doc }: { doc: SetupDoc | null }) {
  const me = useMe();
  const secrets = useRead<SecretStatus[]>("secrets", 600_000);
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
      </Group>
      <Group title="Environments and stacks">
        <WizardCard title="Add an environment" action={<OperateButton label="Add an environment…" title="Add an environment" steps={addEnvironmentSteps()} />}>
          A new environment — its record, its zone, its domain — then the reconcile that makes it live.
        </WizardCard>
        <WizardCard title="Add a stack" action={<OperateButton label="Add a stack…" title="Add a stack" steps={addStackSteps()} />}>
          Every module of a stack installed in dependency order; the preview is the plan.
        </WizardCard>
      </Group>
      <Group title="Access">
        <WizardCard title="Enrol a device" action={<OperateButton label="Enrol a device…" title="Enrol a device in the admin VPN" steps={enrolSteps()} />}>
          A laptop or phone joins the admin VPN; the result is its WireGuard file to download.
        </WizardCard>
        <WizardCard title="A WiFi passphrase" action={null}>
          The WPA passphrase of an SSID, kept where the access point plugin reads it.
        </WizardCard>
      </Group>
      <SecretForm name="wlan" status={(secrets.env?.data ?? []).find((x) => x.name === "wlan")} onSaved={secrets.reload} fields={[{ key: "ssid", label: "SSID" }, { key: "passphrase", label: "WPA passphrase", secret: true }]} />
    </>
  );
}
