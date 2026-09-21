# identity:identity service

Wires a module into **single sign-on** — the OIDC client, its redirect URIs and
the groups allowed to use it. Changes are applied at the provider and reloaded;
sessions already issued keep working until they expire.

## A module that is not published gets no SSO

The redirect URI is built from the module's public domain: `proxyDomain` if it
names one, otherwise `<vmname>.<environment domain>`. An environment need not
have a domain — `mgmt` is the standard internal-only case, its modules reached at
`<vmname>.<zone>.internal` and published nowhere — and then there is no URL a
browser could be redirected back to. The service says so and **skips**, leaving
the module on its own login; it does not fail the update of the module that
depends on it (#698). `identity:accessControl` skips on the same fact, and
`network:proxy` has done so since #438.

"Published" deliberately includes a domain the module does not spell out: the
proxy publishes an app at `<vmname>.<environment domain>` whether or not the
module sets `proxyDomain`, so treating a derived domain as "unpublished" would
leave a reachable app with forward-auth switched off.

To give an internal module SSO, publish it: set `proxyDomain` on the module, or
give its environment a `domains.primary`.

## One field carrying a whole subsystem

`identity` is a single object holding the module's entire SSO configuration —
client id, redirect URIs, group mappings, the lot. Changing any part of it is one
drift record on one field, so the converge cannot say *what* changed and an
operator cannot `--set` one piece without restating the whole object.

It is `in-place` because the reconcile rewrites the OIDC client at the provider
and reloads; sessions already issued keep working until they expire.
Recommendation 5 proposes breaking the object into declared sub-fields so drift
is legible.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`identity:identity` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `identity`

OIDC integration contract for a module that dependsOn identity:identity (ADR-006). Consumed by services/identity/install-service.sh. Omit for forward-auth modules (those use identity:accessControl).

| Attribute | Value |
|---|---|
| Type | `object` |
| Default |  |
| Required by | *(none)* |
| Used by | `identity:identity` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** The whole SSO block — provider type, redirect URIs, the groups bound to the application. Re-applying it updates Authentik; sessions already issued keep working, so there is no downtime to authorize.

<!-- END GENERATED FIELDS -->
