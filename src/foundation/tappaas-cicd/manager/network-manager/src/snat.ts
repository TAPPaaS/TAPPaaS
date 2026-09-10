// snat.ts — the source-NAT read surface on network-manager (ADR-016 D3 v0.3).
//
// Three verbs, all read-only:
//
//   snat list              live rules + owning module + reason + the mode
//   snat verify <module>   declared == live AND enforced
//   snat mode              the firewall-wide outbound-NAT mode
//
// There is deliberately no `snat add|delete` here. Adding or removing a
// module's source NAT is a consequence of adding, modifying or deleting a
// MODULE — `module-manager module add|modify|delete` drives the network:snat
// hooks through dependsOn. A second path to the same state, reachable without
// the module's declaration, could only ever disagree with it.
//
// And there is deliberately no `mode --set`. The mode is DERIVED: an operator
// declares that a module masquerades into a zone, and `hybrid` follows because
// apply-module ensures it. A setter here would invite the mode and the
// declarations to drift apart, which is the failure class ADR-016 exists to
// close. The escape hatch lives one layer down (`snat-manager mode --set`) for
// the operator who genuinely needs it.
//
// The implementation is snat-manager (Python), beside rules_manager, which
// enforces the analogous pinhole-allowed-from gate in exactly that layer. This
// file is presentation: one implementation, one answer.

import { captureResult } from "../../../lib/ts/src/exec";
import { CL, GN, RD, YW, die, info, warn } from "../../../lib/ts/src/cli";

// Overridable for tests / relocations, matching PLANE_BIN in planes.ts.
export const SNAT_BIN = process.env.NM_SNAT_BIN ?? "snat-manager";

export interface SnatRuleView {
  uuid: string;
  description: string;
  enabled: boolean;
  interface: string;
  source_net: string;
  destination_net: string;
  target: string;
}

export interface SnatListView {
  mode: string;
  enforcing: boolean;
  rules: SnatRuleView[];
}

export interface SnatVerifyView {
  module: string;
  ok: boolean;
  mode: string;
  enforcing: boolean;
  missing: string[];
  orphaned: string[];
  present: string[];
}

// Run snat-manager and parse its JSON. A non-zero exit is NOT automatically an
// error: `verify-module` exits 1 to report drift, and its JSON body is the
// answer we want. So the caller decides, and only an unparseable body or a
// failure to spawn is fatal here.
function runSnat(args: string[]): { rc: number; json: unknown } {
  const r = captureResult(SNAT_BIN, [...args, "--json", "--no-ssl-verify"]);
  if (!r.ran) {
    die(`${SNAT_BIN} not found or failed to start: ${r.stderr.trim()}`);
  }
  const body = r.stdout.trim();
  if (!body) {
    die(`${SNAT_BIN} ${args.join(" ")} produced no output: ${r.stderr.trim()}`);
  }
  try {
    return { rc: r.rc, json: JSON.parse(body) };
  } catch {
    die(`${SNAT_BIN} ${args.join(" ")} returned unparseable output:\n${body}`);
  }
  return { rc: r.rc, json: null }; // unreachable; die() throws
}

function modeLine(mode: string, enforcing: boolean): string {
  const colour = enforcing ? GN : YW;
  return `Outbound-NAT mode: ${colour}${mode}${CL}`;
}

// The sentence that matters. A rule can be present in config and carry no
// traffic; saying only "mode: automatic" leaves the reader to know why that
// is fatal, and #239 is three weeks of evidence that they do not.
function notEnforcedNote(mode: string): string {
  return (
    `custom source-NAT rules are NOT enforced while the mode is '${mode}' — ` +
    `they are accepted into config and excluded from the generated ruleset`
  );
}

export function cmdSnatMode(asJson: boolean): number {
  const { json } = runSnat(["mode"]);
  const view = json as { mode: string; enforcing: boolean };

  if (asJson) {
    // Echo the controller's answer verbatim rather than re-deriving it.
    console.log(JSON.stringify(view, null, 2));
    return 0;
  }

  info(modeLine(view.mode, view.enforcing));
  if (!view.enforcing) {
    warn(`  ${notEnforcedNote(view.mode)}`);
    info(
      "  The mode is derived, not set here: declare a module's snatFrom and " +
        "network:snat moves it to 'hybrid' on apply.",
    );
  }
  return 0;
}

export function cmdSnatList(asJson: boolean): number {
  const { json } = runSnat(["list-rules"]);
  const view = json as SnatListView;

  if (asJson) {
    console.log(JSON.stringify(view, null, 2));
    return 0;
  }

  info(modeLine(view.mode, view.enforcing));
  if (view.rules.length === 0) {
    info("No source-NAT rules.");
    return 0;
  }

  for (const r of view.rules) {
    // The description IS the ownership marker (tappaas-snat:<module>:<from>-><zone0>),
    // so the owning module is read from it rather than guessed. A rule that
    // does not carry the prefix was not written by TAPPaaS and is named as
    // such — never silently adopted, never silently deleted.
    const owner = r.description.startsWith("tappaas-snat:")
      ? r.description.split(":")[1]
      : `${YW}unowned${CL}`;
    const state = r.enabled ? "" : ` ${YW}(disabled)${CL}`;
    info(
      `  ${r.source_net} -> ${r.destination_net} via ${r.target} on ${r.interface}` +
        `  [${owner}]${state}`,
    );
    info(`      ${r.description}`);
  }
  if (!view.enforcing) {
    warn(`  ${notEnforcedNote(view.mode)}`);
  }
  return 0;
}

export function cmdSnatVerify(module: string, asJson: boolean): number {
  if (!module) die("snat verify: expected <module>");
  const { rc, json } = runSnat(["verify-module", module]);
  const view = json as SnatVerifyView;

  if (asJson) {
    console.log(JSON.stringify(view, null, 2));
    return rc === 0 ? 0 : 1;
  }

  for (const d of view.present) info(`  ${GN}present${CL}  ${d}`);
  for (const d of view.missing) info(`  ${RD}MISSING${CL}  ${d}`);
  for (const d of view.orphaned) info(`  ${RD}ORPHANED${CL} ${d} (declared nowhere)`);

  if (!view.enforcing && (view.present.length > 0 || view.missing.length > 0)) {
    // Presence is not enforcement. This is the whole reason verify exists.
    warn(`  NOT ENFORCED: ${notEnforcedNote(view.mode)}`);
  }
  if (view.ok) {
    info(`${GN}network:snat verified for ${module}${CL}`);
  } else {
    warn(`network:snat drift for ${module}`);
  }
  return view.ok ? 0 : 1;
}

// Dispatch for `network-manager snat <sub> [module]`.
export function cmdSnat(rest: string[], asJson: boolean): number {
  const sub = rest[0];
  switch (sub) {
    case "list":
      return cmdSnatList(asJson);
    case "mode":
      return cmdSnatMode(asJson);
    case "verify":
      return cmdSnatVerify(rest[1] ?? "", asJson);
    case undefined:
      die("snat: expected one of list | verify <module> | mode");
      return 1;
    default:
      // Named explicitly: an operator reaching for `snat add` is reaching for
      // the wrong tool, and should be told which one is right.
      if (sub === "add" || sub === "delete" || sub === "remove") {
        die(
          `snat ${sub}: not a network-manager verb. A module's source NAT follows its ` +
            `declaration — use 'module-manager module add|modify|delete <module>', which ` +
            `drives the network:snat hooks.`,
        );
      }
      if (sub === "set") {
        die(
          "snat set: the outbound-NAT mode is derived, not set. Declare snatFrom on a " +
            "module and network:snat ensures 'hybrid' on apply.",
        );
      }
      die(`snat: unknown subcommand '${sub}' — expected list | verify <module> | mode`);
      return 1;
  }
}
