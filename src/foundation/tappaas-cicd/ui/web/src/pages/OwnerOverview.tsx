// OwnerOverview — what status.<domain> opens on (spike §5.11, mockup 7): one
// sentence about the site, the services with their state and backup in plain
// words, the site in numbers, the operator's address. Nothing can be changed
// from here, and the page says so.

import { useRead } from "../api";
import { Dot, Link, ReadState, Section, since } from "../ui";

interface OwnerService {
  name: string;
  displayName: string;
  address: string | null;
  state: string;
  notes: string[];
  level: "pass" | "warn" | "fail";
}
interface Owner {
  site: string;
  sentence: string;
  facts: string[];
  services: OwnerService[];
  numbers: string;
  offsite: string[];
  release: string;
  operator: string | null;
}

export function OwnerOverview() {
  const r = useRead<Owner>("owner");
  const o = r.env?.data;
  return (
    <div className="page">
      <div className="page-head">
        <h1>Your site{o ? `: ${o.site}` : ""}</h1>
        <span className="muted">read-only · {since(r.env?.at)}</span>
      </div>
      <ReadState env={r.env} failure={r.failure} what="the site" />
      {o ? (
        <>
          <p className="owner-sentence">{o.sentence}</p>
          <p className="muted">{o.facts.join(" · ")}</p>
          <div className="grid2">
            <Section title="Services">
              <ul className="owner-services">
                {o.services.map((s) => (
                  <li key={s.name}>
                    <Dot level={s.level} />
                    <span>
                      <b>{s.displayName}</b>
                      <br />
                      <span className="muted small">{s.address ?? "—"}</span>
                    </span>
                    <span className="small">{[s.state, ...s.notes].join(" · ")}</span>
                  </li>
                ))}
              </ul>
            </Section>
            <div>
              <Section title="The site">
                <p>{o.numbers}</p>
                {o.offsite.map((x) => (
                  <p key={x}>{x}</p>
                ))}
                <p>{o.release}</p>
                {o.operator ? <p>Operator: <a href={`mailto:${o.operator}`}>{o.operator}</a></p> : null}
                <p><Link to="/site/physical">Open the physical view (read-only) →</Link></p>
              </Section>
              <Section title="What you can do here">
                <p className="small">See which services run and whether they are backed up, and the site as it is cabled.</p>
                <p className="small muted">Nothing can be changed from this address: operating the site needs the management network or the admin VPN, and the Installer or Admin role.</p>
              </Section>
            </div>
          </div>
        </>
      ) : null}
    </div>
  );
}
