// AddRepository.tsx — Add a repository (Day 1's Repositories, Day 2's Site):
// site-manager repository add, its form shaped by what the URL holds
// (repository probe): the branch add checks out, and the signing choices only
// where the branch's releases are checked.

import { useEffect, useState } from "react";
import { useRead } from "../api";
import { OperateButton, Step } from "../operate";
import { Values } from "../argv";
import { COMMUNITY_URL, RepositoryProbe, repositoryChoices, repositoryPrefill } from "../wizards";

const str = (v: Values[string]): string => (typeof v === "string" ? v.trim() : "");

// The URL settles before it is looked up: one probe, not one per key.
function useSettled(v: string, ms = 700): string {
  const [s, setS] = useState(v);
  useEffect(() => {
    const t = setTimeout(() => setS(v), ms);
    return () => clearTimeout(t);
  }, [v]);
  return s;
}

function RepositoryForm({ values, set }: { values: Values; set: (v: Values) => void }) {
  const url = useSettled(str(values["@url"]));
  const branch = str(values["--branch"]);
  // The first look names the branch add would take; a branch the operator picks is looked at again.
  const [auto, setAuto] = useState<string | null>(null);
  const asked = branch && branch !== auto ? `&branch=${encodeURIComponent(branch)}` : "";
  const read = useRead<RepositoryProbe>(url ? `repository-probe?url=${encodeURIComponent(url)}${asked}` : null, 600_000);
  const probe = read.env?.data ?? null;
  const managed = str(values["--managed"]) || "full";
  const unsigned = values["--unsigned"] === true;
  const show = repositoryChoices(probe, managed, unsigned);

  useEffect(() => {
    if (!probe) return;
    const next: Values = { ...values };
    if (!branch && probe.branch) {
      next["--branch"] = probe.branch;
      setAuto(probe.branch);
    }
    if (!show.unsigned) delete next["--unsigned"];
    if (!show.signer) delete next["--signer"];
    if (!show.catalog) delete next["--catalog"];
    if (JSON.stringify(next) !== JSON.stringify(values)) set(next);
  }, [probe, show.unsigned, show.signer, show.catalog]);

  const lookup = !url ? null
    : read.failure ? `Could not look at it: ${read.failure}`
    : read.env?.error ? read.env.error.replace(/^.*— /, "")
    : !probe ? "looking at the repository…"
    : probe.installed ? `${probe.name} is already on this site.`
    : !probe.branchFound ? `It has no branch ${probe.branch ?? ""}.`
    : `${probe.name}: ${probe.catalog ? "a repository of modules" : "no module catalog"}; ${probe.branch} is ${probe.verified ? `a ${probe.channel} branch, its releases are checked` : "not a staging or production branch, its releases are not checked"}.`;

  return (
    <div className="form">
      <label className="form-row">
        <span>repository URL *</span>
        <input type="text" placeholder="codeberg.org/owner/repository" value={typeof values["@url"] === "string" ? values["@url"] : ""} onChange={(e) => set({ ...values, "@url": e.target.value, "--branch": "" })} />
        {lookup ? <small className="muted">{lookup}</small> : null}
        {url === COMMUNITY_URL ? <small className="muted">Community: modules maintained outside the core project, such as UniFi OS and MikroTik.</small> : null}
      </label>
      <label className="form-row">
        <span className="mono">--branch</span>
        {probe && probe.branches.length ? (
          <select value={branch} onChange={(e) => set({ ...values, "--branch": e.target.value })}>
            {probe.branches.map((b) => <option key={b} value={b}>{b}</option>)}
          </select>
        ) : (
          <input type="text" placeholder="stable" value={branch} onChange={(e) => set({ ...values, "--branch": e.target.value })} />
        )}
        <small className="muted">The branch to check out: stable when the repository has one, else its default branch{probe?.defaultBranch ? ` (${probe.defaultBranch})` : ""}.</small>
      </label>
      <label className="form-row">
        <span className="mono">--managed</span>
        <select value={managed} onChange={(e) => set({ ...values, "--managed": e.target.value === "full" ? "" : e.target.value })}>
          <option value="full">full — a repository of modules</option>
          <option value="tracked">tracked — kept up to date, no modules</option>
        </select>
        <small className="muted">full: the repository holds modules; its module catalog is checked and its modules can be installed. tracked: a repository without modules (documents, settings); the nightly update keeps it current like the others, and nothing is installed from it.</small>
      </label>
      {show.catalog ? (
        <label className="form-row">
          <span className="mono">--catalog</span>
          <input type="text" placeholder={probe?.catalog ?? "src/module-catalog.json"} value={str(values["--catalog"]) ? String(values["--catalog"]) : ""} onChange={(e) => set({ ...values, "--catalog": e.target.value })} />
          <small className="muted">Where the module catalog is in the repository. Leave it blank for {probe?.catalog ?? "src/module-catalog.json"}.</small>
        </label>
      ) : null}
      {show.unsigned ? (
        <label className="form-check">
          <input type="checkbox" checked={unsigned} onChange={(e) => set({ ...values, "--unsigned": e.target.checked })} />
          <span className="mono">--unsigned</span>{" "}
          <small className="muted">
            {probe?.signs
              ? "Add it without its owners' fingerprints: later releases are checked against the keys of the revision cloned now."
              : `Required: ${probe?.branch} is a ${probe?.channel} branch and ${probe?.name} signs no releases, so it is added unverified.`}
          </small>
        </label>
      ) : null}
      {show.signer ? (
        <label className="form-row">
          <span className="mono">--signer</span>
          <textarea rows={2} placeholder="one fingerprint per line" value={Array.isArray(values["--signer"]) ? values["--signer"].join("\n") : ""} onChange={(e) => set({ ...values, "--signer": e.target.value.split("\n") })} />
          <small className="muted">The fingerprint of the key the repository's owners sign releases with; get it from them, out of band. One line per key. If a site runs in trusted mode, only stable/staging branches with matching key fingerprints are accepted.</small>
        </label>
      ) : null}
    </div>
  );
}

// One button for any repository: the form opens on Community until the site has it.
export function AddRepositoryButton({ installed }: { installed: string[] }) {
  const step: Step = {
    title: "site-manager repository add <url>",
    bin: "site-manager",
    verb: "repository add",
    initial: { "@url": repositoryPrefill(installed) },
    only: [],
    render: (values, set) => <RepositoryForm values={values} set={set} />,
  };
  return <OperateButton label="Add a repository…" title="site-manager repository add" steps={[step]} />;
}
