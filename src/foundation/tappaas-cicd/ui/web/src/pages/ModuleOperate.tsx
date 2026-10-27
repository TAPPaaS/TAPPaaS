// ModuleOperate.tsx — a module's operate column (spike mockup 4, Appendix A):
// every module-manager verb on one module, each through the operate dialog.
// Changing a field is on the Config tab, card by card.

import { OperateButton, Step } from "../operate";
import { ModuleSummary } from "../types";
import { Section, canOperate, useMe } from "../ui";

export function ModuleOperate({ m, onConfig }: { m: ModuleSummary; onConfig: () => void }) {
  const operator = canOperate(useMe());
  const name = m.name;
  const fixed = [name];
  const guest = m.vmid !== null;
  const machine = m.kind === "machine";
  const step = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "module-manager", verb, fixed, hide: ["--environment", "--vmid"], ...extra });
  const suspended = m.status === "suspended" || m.running === "stopped";
  if (!operator) return null;
  return (
    <Section title="Operate — every verb runs through module-manager" aside="Change → Preview → Apply → Result">
      <div className="operate">
        <div className="op">
          <OperateButton label="Update (release)" title={`Update ${name} to its release`} steps={[step(`module-manager update ${name}`, "update")]} />
          <small>module update {name} — snapshot, 3-way merge, converge</small>
        </div>
        <div className="op">
          <button className="btn" onClick={onConfig}>Modify fields…</button>
          <small>on the Config tab: the module and each service as a card, every field typed</small>
        </div>
        <div className="op">
          <OperateButton label="Reconcile" title={`Reconcile ${name}`} steps={[step(`Reconcile ${name}: the drift, then the converge`, "reconcile", { hide: ["--environment", "--vmid", "--fail-fast"] })]} />
          <small>preview = the three-way drift; apply = --apply</small>
        </div>
        <div className="op">
          <span className="toolbar">
            <OperateButton label="Test" title={`Test ${name}`} steps={[step(`module-manager test ${name}`, "test", { hide: ["--environment", "--vmid", "--zone0", "--deep"] })]} />
            <OperateButton label="Test --deep" title={`Deep test ${name}`} steps={[step(`module-manager test ${name} --deep`, "test", { hide: ["--environment", "--vmid", "--zone0"], initial: { "--deep": true } })]} />
          </span>
          <small>fast · --deep (a read: runs at once)</small>
        </div>
        {guest ? (
          <div className="op">
            <OperateButton label="Snapshot VM" title={`Snapshot ${name}`} steps={[step(`module-manager snapshot-vm ${name}`, "snapshot-vm")]} />
            <small>a VM snapshot now (--list to see them)</small>
          </div>
        ) : null}
        {guest && !machine ? (
          <div className="op">
            {suspended ? (
              <OperateButton label="Resume" title={`Resume ${name}`} steps={[step(`module-manager resume ${name}`, "resume")]} />
            ) : (
              <OperateButton label="Suspend" title={`Suspend ${name}`} steps={[step(`module-manager suspend ${name}`, "suspend")]} />
            )}
            <small>{suspended ? "start it and clear the mark" : "stop it and keep it stopped"}</small>
          </div>
        ) : null}
        <div className="op">
          <OperateButton
            label="Delete…"
            kind="danger"
            title={`Delete ${name}`}
            steps={[
              step(`Delete module ${name}`, "delete", {
                hide: ["--environment", "--vmid", ...(machine ? [] : ["--decommission"])],
                // The typed name is the confirmation; the manager's own prompt cannot be answered here.
                initial: { "--yes": true },
                note: (
                  <>
                    Backups in PBS stay until purged: <span className="mono">backup-manager purge {name}</span> is a second, separate confirmation on the Backup page — never a side effect of this delete.
                  </>
                ),
              }),
            ]}
          />
          <small>--archive (default) · --remove · typed name</small>
        </div>
      </div>
    </Section>
  );
}
