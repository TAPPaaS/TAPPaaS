// reconcile.ts — the environment reconcile engine (ADR-007 P3 cascade).
//
// `environment reconcile <env>`:
//   shallow (default) → trigger a network convergence by shelling out to
//                        network-manager (the network plane owner).
//   --deep            → the above + reconcile EVERY module that consumes this
//                        environment (module reconcile, the leaf re-apply),
//                        shelling out to module-manager per module.
//
// The network half is SYSTEM-WIDE, not per-environment (#461): network-manager
// reconcile has no zone or environment filter, so it converges every zone on
// every plane and this environment's zone is merely included. The plan says so,
// and `--skip-network` lets a caller that has already run the system-wide pass
// (site-manager's --deep cascade) avoid repeating it once per environment.
//
// Each `reconcile` is idempotent, so re-touching a shared dependency (the
// network) is harmless — it is wasteful, not wrong. The engine depends only on
// the NetworkClient / ModuleClient interfaces (injected) — pure planning, then
// apply.

import {
  Action,
  ApplyFailure,
  ApplyResult,
  DnsTlsClient,
  Environment,
  ModuleClient,
  NetworkClient,
  NetworkUnreachable,
  Plan,
} from "./types";

export interface ReconcileOpts {
  // --deep: also reconcile every module that consumes this environment.
  deep: boolean;
  // --skip-network: omit the system-wide network reconcile because the caller
  // already ran it. Only safe when that is actually true — see site-manager.
  skipNetwork: boolean;
  // The organization to adopt when this environment has no ownerOrg. The caller
  // resolves it (and confirms it exists) so the engine stays pure. Undefined =
  // no candidate could be resolved, in which case an empty ownerOrg is reported
  // as a warning rather than silently left alone.
  ownerOrgCandidate?: string;
  // Whether the environment being reconciled is the DEFAULT environment
  // (site.json .defaultEnvironment). The identity module's public self-config
  // tracks the default environment's domain, so a --deep reconcile of the
  // default env must also re-point it (#474). Absent ⇒ false.
  isDefaultEnv?: boolean;
}

// Plan the wildcard DNS + cert-refid runtime state for one environment (#537).
// A no-op for non-wildcard environments and for environments with no primary
// domain set. Pushes into the caller's action/warning/note arrays so it slots
// into computePlan's single plan.
function planWildcardState(
  env: Environment,
  dt: DnsTlsClient | undefined,
  actions: Action[],
  warnings: string[],
  notes: string[],
): void {
  const domains = env.domains;
  if (!domains || domains.dnsMode !== "wildcard") return; // per-service: nothing here

  const domain = domains.primary;
  if (!domain || domain.startsWith("CHANGE")) {
    warnings.push(
      `environment '${env.name}': dnsMode=wildcard but domains.primary is unset — ` +
        `no wildcard DNS/cert to reconcile`,
    );
    return;
  }
  if (!dt) {
    warnings.push(
      `environment '${env.name}': dnsMode=wildcard but no DNS/TLS client available — ` +
        `wildcard DNS and cert refid were NOT reconciled`,
    );
    return;
  }

  // ── TLS: record an issued cert's refid, or issue it (creds permitting) ──
  // Decide this first because ISSUING (via acme-setup.sh) also registers the
  // wildcard DNS itself, so we skip the separate DNS action in that case.
  let issuing = false;
  const issued = dt.issuedCertRefid(domain);
  const recorded = dt.recordedCertRefid(env.name);
  if (issued) {
    if (issued !== recorded) {
      actions.push({
        kind: "record-cert-refid",
        scope: "environment",
        target: `cert-refids.json['${env.name}'] = ${issued}  (*.${domain})`,
        value: issued,
        domain,
      });
    } else {
      notes.push(`cert-refids.json already records ${issued} for '${env.name}' — no change.`);
    }
  } else if (dt.acmeCredsAvailable()) {
    issuing = true;
    actions.push({
      kind: "issue-wildcard-cert",
      scope: "environment",
      target:
        `issue *.${domain} via acme-setup.sh --environment ${env.name} ` +
        `(ACME creds present), then record its refid`,
      domain,
    });
  } else {
    warnings.push(
      `environment '${env.name}': no *.${domain} wildcard cert issued and ` +
        `~/.acme-dns-credentials.txt is absent — run ` +
        `\`acme-setup.sh --environment ${env.name}\` once (needs DNS-API credentials) to issue it.`,
    );
  }

  // ── DNS: converge the split-horizon wildcard override ──
  // Skipped when issuing, because acme-setup.sh registers it as part of issuance.
  if (issuing) {
    notes.push(
      `wildcard DNS for *.${domain} is registered as part of certificate issuance (acme-setup.sh).`,
    );
    return;
  }
  const st = dt.wildcardDnsState(domain, env.network.zone ?? "");
  if (!st.gatewayIp) {
    warnings.push(
      `environment '${env.name}': could not derive a gateway IP for *.${domain} ` +
        `(zone '${env.network.zone}' has no subnet in zones.json, and no dmz fallback) — ` +
        `wildcard DNS not reconciled.`,
    );
    return;
  }
  if (st.currentTarget !== st.gatewayIp || st.collidingHosts.length > 0) {
    const collide =
      st.collidingHosts.length > 0
        ? `; prune ${st.collidingHosts.length} colliding per-service override(s)`
        : "";
    actions.push({
      kind: "register-wildcard-dns",
      scope: "environment",
      target: `*.${domain} -> ${st.gatewayIp} (${st.gatewayZone} gateway, Unbound)${collide}`,
      value: st.gatewayIp,
      domain,
      zone: st.gatewayZone,
    });
  } else {
    notes.push(
      `wildcard *.${domain} already resolves to ${st.gatewayIp} (${st.gatewayZone}) — no DNS change.`,
    );
  }
}

// Compute the reconcile plan for one environment.
//   deep=false → just the (system-wide) network reconcile.
//   deep=true  → network reconcile + one module reconcile per consuming module.
export function computePlan(
  env: Environment,
  net: NetworkClient,
  mod: ModuleClient,
  opts: ReconcileOpts,
  // #537: the wildcard DNS + cert-refid boundary. Optional so non-wildcard
  // reconciles (and the offline engine tests that use non-wildcard envs) need
  // not inject it; a wildcard-mode environment without it is reported as a
  // warning rather than silently skipped.
  dt?: DnsTlsClient,
): Plan {
  const actions: Action[] = [];
  const warnings: string[] = [];
  const notes: string[] = [];
  // Hard errors: a plan carrying any of these must NOT be applied (ADR-014 D1).
  const errors: string[] = [];

  // ── ADR-014 D1: materialize the service zone, don't just complain ──
  //
  // Before D1 a missing zone was only a WARNING, so an environment could point
  // at a zone that never existed and never converge — the operator had to know
  // to run `network-manager add` first, an undocumented ordering trap.
  //
  // The ADR says "create a missing Service zone, hard-error on a missing
  // non-Service zone". A zone that is missing has no type to inspect, so the
  // check that is actually implementable — and what the ADR's own parenthetical
  // describes ("the operator pointed an environment at a client/IoT zone") — is:
  //   - zone absent          → CREATE it as a Service zone (that is the intent);
  //   - zone present, Service→ nothing to do;
  //   - zone present, other  → HARD ERROR (an environment's zone must be a
  //                            Service zone; pointing it at a client/IoT zone is
  //                            a configuration mistake, not something to fix by
  //                            silently minting a second zone).
  const zone = env.network.zone;
  if (!zone) {
    warnings.push(`environment '${env.name}': no network.zone — nothing to reconcile`);
  } else if (!net.zoneExists(zone)) {
    actions.push({
      kind: "create-service-zone",
      scope: "environment",
      target: `service zone '${zone}' for environment '${env.name}' (absent from zones.json)`,
      value: zone,
    });
    notes.push(
      `zone '${zone}' does not exist and will be authored as a Service zone ` +
        `(ADR-014 D1). It converges in the network pass below.`,
    );
  } else {
    const t = net.zoneType(zone);
    if (t !== undefined && t !== "Service") {
      errors.push(
        `environment '${env.name}': network.zone '${zone}' is a ${t} zone, not a Service zone. ` +
          `An environment binds to a service segment; a client/IoT zone consumes one ` +
          `(bind it with \`network-manager bind ${zone} --environment ${env.name}\`). ` +
          `Re-point the environment with \`environment-manager modify ${env.name} --zone <serviceZone>\`.`,
      );
    }
  }

  if (opts.skipNetwork) {
    notes.push(
      "network reconcile SKIPPED (--skip-network): the system-wide network pass is the caller's " +
        `responsibility this run; zone '${zone || "?"}' converges there, not here.`,
    );
  } else {
    // NOT scoped to this environment — say so in the label itself (#461). The
    // zone is named as what the pass happens to include, never as its extent.
    actions.push({
      kind: "reconcile-network",
      scope: "system-wide",
      target:
        "network — ALL zones, ALL planes (system-wide; " +
        `zone '${zone || "?"}' of environment '${env.name}' converges as part of it)`,
    });
    notes.push(
      "the network reconcile is system-wide: network-manager takes no zone or environment " +
        "filter, so one run converges the whole platform. Running it once per environment " +
        "repeats the identical operation — use --skip-network when a caller already ran it.",
    );
  }

  // ownerOrg backfill. The bootstrap writes "" because it runs before any
  // organization exists; the only other repair (rest-of-foundation.sh) is
  // nested inside a "config/people is empty" guard, so it can fire exactly once
  // and never again. Nothing on the update path checks the field at all, which
  // is how an environment can stay schema-invalid indefinitely. Reconcile is
  // the convergence verb, so it is where the repair belongs.
  if (!env.ownerOrg) {
    if (opts.ownerOrgCandidate) {
      actions.push({
        kind: "backfill-owner-org",
        scope: "environment",
        target: `ownerOrg = '${opts.ownerOrgCandidate}' on environment '${env.name}' (was empty)`,
        value: opts.ownerOrgCandidate,
      });
    } else {
      warnings.push(
        `environment '${env.name}': ownerOrg is empty and no organization could be resolved ` +
          `— create one under people/organizations/, or set it with ` +
          `\`environment-manager modify ${env.name} --owner <org>\``,
      );
    }
  }

  // ── #537: wildcard DNS + cert-refid runtime state (ADR-007c v1.4) ──
  //
  // For a `dnsMode: wildcard` environment two artefacts are reconciler-populated
  // runtime state, not authored config: the split-horizon `*.<primary>` Unbound
  // override (pointed at the env's service-zone gateway) and cert-refids.json's
  // refid for the issued cert. Until #537 both were written ONLY by the manual
  // acme-setup.sh, so an environment created after site bootstrap never got them
  // and its modules failed at runtime. Reconcile is the convergence verb, so it
  // is where materializing them belongs.
  //
  // Scope is always "environment": these touch exactly this env's domain.
  planWildcardState(env, dt, actions, warnings, notes);

  if (opts.deep) {
    const modules = mod.modulesForEnvironment(env.name);
    for (const m of modules) {
      actions.push({ kind: "reconcile-module", scope: "environment", target: `module '${m}'` });
    }
    if (modules.length === 0) {
      warnings.push(`environment '${env.name}': no deployed modules consume it (--deep: nothing downstream)`);
    }
    // The identity module lives in the mgmt zone (environment: null), so it is
    // never in modulesForEnvironment(<app env>) — yet its Authentik self-config
    // (app launch URL, proxy external_host, oauth2 redirect_uris, outpost
    // authentik_host) is built from the DEFAULT environment's domain. Reconcile
    // it here when the default environment is the one changing, so a domain
    // change re-points those objects (#474). Idempotent, guarded on deployment,
    // and de-duplicated in case identity is ever tied to this env directly.
    if (opts.isDefaultEnv && !modules.includes("identity") && mod.moduleDeployed("identity")) {
      actions.push({ kind: "reconcile-module", scope: "environment", target: "module 'identity'" });
      notes.push(
        "identity is reconciled because this is the default environment: its Authentik " +
          "self-config (app launch URL, proxy external_host, oauth2 redirect_uris, outpost " +
          "authentik_host) tracks this environment's domain (#474).",
      );
    }
  }

  return { actions, warnings, notes, errors };
}

// Apply a plan via the clients. Returns the count applied plus any targets that
// ran and failed.
//
// Module failures are COLLECTED, not thrown (#454): a module that fails to
// converge is recorded and the cascade continues with the next one, so one bad
// module no longer strands every module planned after it. Two failures still
// abort the whole pass, because neither is a fault of the target:
//   - NetworkUnreachable — a manager binary is missing on PATH, so every
//     remaining target would fail identically; the caller dies with the
//     "unreachable" message instead of reporting N identical failures.
//   - a failing network reconcile — the shared prerequisite for everything
//     planned after it.
export function applyPlan(
  env: Environment,
  plan: Plan,
  net: NetworkClient,
  mod: ModuleClient,
  apply: boolean,
  // Persist the environment after an in-memory field change. Injected so the
  // engine stays free of filesystem access, exactly like the two clients.
  // Omitted → a planned backfill is reported as a failure rather than silently
  // dropped, because the caller asked for a repair and did not get one.
  writeEnv?: (env: Environment) => void,
  // #537: the wildcard DNS + cert-refid boundary. Omitted → a planned DNS/TLS
  // action is reported as a failure rather than silently dropped.
  dt?: DnsTlsClient,
): ApplyResult {
  let applied = 0;
  const failures: ApplyFailure[] = [];
  for (const a of plan.actions) {
    if (a.kind === "reconcile-network") {
      net.reconcileNetwork(apply);
      applied++;
    } else if (a.kind === "reconcile-module") {
      // target is `module '<name>'` — recover the name.
      const m = a.target.replace(/^module '/, "").replace(/'$/, "");
      try {
        mod.reconcileModule(m, apply);
        applied++;
      } catch (e) {
        if (e instanceof NetworkUnreachable) throw e;
        failures.push({ target: m, error: e instanceof Error ? e.message : String(e) });
      }
    } else if (a.kind === "create-service-zone") {
      if (!a.value) {
        failures.push({ target: "create-service-zone", error: "no zone in the planned action" });
        continue;
      }
      try {
        net.createServiceZone(a.value);
        applied++;
      } catch (e) {
        if (e instanceof NetworkUnreachable) throw e;
        failures.push({ target: `zone '${a.value}'`, error: e instanceof Error ? e.message : String(e) });
      }
    } else if (a.kind === "backfill-owner-org") {
      if (!a.value) {
        failures.push({ target: `ownerOrg on '${env.name}'`, error: "no organization in the planned action" });
        continue;
      }
      if (!writeEnv) {
        failures.push({
          target: `ownerOrg on '${env.name}'`,
          error: "no environment writer available — backfill planned but not applied",
        });
        continue;
      }
      try {
        env.ownerOrg = a.value;
        writeEnv(env);
        applied++;
      } catch (e) {
        failures.push({
          target: `ownerOrg on '${env.name}'`,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    } else if (a.kind === "register-wildcard-dns") {
      if (!dt) {
        failures.push({ target: `*.${a.domain ?? "?"}`, error: "no DNS/TLS client available" });
        continue;
      }
      if (!a.value || !a.domain) {
        failures.push({ target: "register-wildcard-dns", error: "no gateway/domain in the planned action" });
        continue;
      }
      try {
        dt.registerWildcard(a.domain, a.value, a.zone ?? "", env.name);
        applied++;
      } catch (e) {
        if (e instanceof NetworkUnreachable) throw e;
        failures.push({ target: `*.${a.domain}`, error: e instanceof Error ? e.message : String(e) });
      }
    } else if (a.kind === "record-cert-refid") {
      if (!dt) {
        failures.push({ target: `cert-refids['${env.name}']`, error: "no DNS/TLS client available" });
        continue;
      }
      if (!a.value) {
        failures.push({ target: `cert-refids['${env.name}']`, error: "no refid in the planned action" });
        continue;
      }
      try {
        dt.writeCertRefid(env.name, a.value);
        applied++;
      } catch (e) {
        failures.push({ target: `cert-refids['${env.name}']`, error: e instanceof Error ? e.message : String(e) });
      }
    } else if (a.kind === "issue-wildcard-cert") {
      if (!dt) {
        failures.push({ target: `*.${a.domain ?? "?"}`, error: "no DNS/TLS client available" });
        continue;
      }
      try {
        // acme-setup.sh issues, registers the wildcard DNS, and writes
        // cert-refids.json; issueWildcardCert returns the resulting refid.
        dt.issueWildcardCert(env.name);
        applied++;
      } catch (e) {
        if (e instanceof NetworkUnreachable) throw e;
        failures.push({ target: `*.${a.domain ?? "?"}`, error: e instanceof Error ? e.message : String(e) });
      }
    }
  }
  return { applied, failures };
}
