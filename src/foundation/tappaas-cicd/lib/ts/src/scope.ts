// scope.ts — a module's scope (ADR-022e v1.1), the TypeScript side of
// module_scope_of in lib/module-catalog-lib.sh. The two MUST agree.
//
// `site` — the module belongs to the Site, serves every Environment and installs
// in mgmt; `environment` — it belongs to one Environment. Scope is DERIVED, not
// stored: a module is site-scoped exactly when its stack is `foundation`, and
// becomes so by moving into that stack (#676 retired module.tier, which said the
// same thing a second time and could disagree).
//
// For the release that retires `tier`, a module with no `stack` falls back to
// it — a deployed config the merge has not yet given a stack, or a module from
// a repository whose module JSONs carry none. The fallback goes with the release
// after. `zone.tier` (ADR-014) is a different field and is untouched.

export type Scope = "site" | "environment";

export function moduleScope(raw: { stack?: unknown; tier?: unknown } | null | undefined): Scope {
  const stack = typeof raw?.stack === "string" ? raw.stack : "";
  if (stack) return stack === "foundation" ? "site" : "environment";
  return raw?.tier === "foundation" ? "site" : "environment";
}
