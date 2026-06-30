# ADR-007a — People

| | |
|---|---|
| **Status** | Accepted — **implemented** (P1/S2 on the `ADR007` branch) |
| **Version** | 1.2 |
| **Date** | 2026-06-30 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #56, #320; ADR-006 (identity — users, roles, SSO); realized by `people-manager` (TS) → `identity-controller` (Python/Authentik) |
| **Changelog** | v1.2 — **as-built (2026-06-30):** **Role is now a first-class People entity** (`config/people/roles/*.json`), not deferred to ADR-006 — so the domain is the 3-level hierarchy **plus** a cross-cutting Role. Added the Role schema, `Group.roles`/`User.roles`, the User lifecycle field, and the Authentik realization (`people-manager reconcile` → `identity-controller`; a Role is a marked Authentik group). v1.1 — applied Erik⟷Lars review: attribute-discipline rule (CR-01); membership modeled on User, removed from Group (CR-02) |

The **👥 People** classification domain — one of ADR-007's three classification domains.

## Decision

People is a **3-level hierarchy** — `Organization → Group → User` — **plus a cross-cutting `Role`**.
A User can belong to many Groups across many Organizations and hold Roles (directly or inherited via a
Group). It maps onto Authentik primitives (Organization ≈ org-scoped group prefix · Group · User · Role).
RBAC is built on **Group** (the universal IAM primitive) with **Role** as the permission label; the actual
permissions/policies behind a Role are configured in Authentik (ADR-006).

> **As-built (realization).** The model is reconciled by **`people-manager`** (the TypeScript orchestrator
> for the People domain — owns `config/people/{organizations,groups,users,roles}/` CRUD + validation) which
> calls **`identity-controller`** (Python; the Authentik reconcile engine). A **Role is realized as an
> Authentik core group marked `attributes.tappaas.kind="role"`**, so "assign role" = group membership; an
> ordinary Group is an unmarked group. `people-manager reconcile` converges the config to Authentik
> idempotently (the verb was `sync` → renamed `reconcile`).

## The model — three levels + a cross-cutting Role

| Entity | Definition | `type` values | Authentik (as built) |
|-------|------------|---------------|-----------|
| **Organization** | legal/identity entity; owns Environments + Apps | `family` · `company` · `foundation` · `customer` | org-scoped group prefix (`{org}__…`) |
| **Group** | collection of Users within one Org; the RBAC primitive; carries inheritable `roles` | `team` · `department` · `family-members` · `access-set` · `ad-hoc` | Group (1:1) |
| **User** | an individual human; belongs to ≥1 Group; holds direct + inherited Roles; has a lifecycle | — | User (1:1) |
| **Role** | a cross-cutting permission label (e.g. `root`/`admin`/`user`); standalone, not nested | — | a Group marked `attributes.tappaas.kind="role"` |

`type` drives UI labels only (e.g. `family-members` → "Members", `team` → "Team", default → "Group").

### Organization — schema (`config/people/organizations/{name}.json`)

```json
{
  "name": "mybusiness-bv",
  "type": "company",
  "displayName": "MyBusiness BV",
  "owner": "<owner>",
  "legalEntity": "MyBusiness BV",
  "jurisdiction": "NL",
  "primaryDomain": "mybusiness.nl",
  "aliasDomains": ["mybusiness.com"],
  "aliasMode": "redirect",
  "authentikTenant": "id.mybusiness.nl",
  "dataResidency": "eu-only",
  "parentOrg": null
}
```

A **customer** adds `parentOrg`, `billing.invoicedBy`, `billing.contractRef`, `dpaSigned`.

> **Attribute discipline (rule).** Every attribute must justify itself — state its **reason**,
> **default**, and **operational impact**. This schema exists to *set up and run* TAPPaaS, **not** to
> become a CRM. **Avoid info-only attributes** (data with no operational impact).

### Group — schema (`config/people/groups/{org}__{name}.json`)

```json
{
  "name": "mybusiness-bv__staff",
  "type": "team",
  "displayName": "MyBusiness Staff",
  "ownerOrg": "mybusiness-bv",
  "authentikGroup": "mybusiness-bv-staff",
  "roles": ["editor"]
}
```

Membership is modeled on the **User** (`memberOf`), not duplicated on the Group.

### User — schema (`config/people/users/{name}.json`)

```json
{
  "name": "<owner>",
  "displayName": "<Site Administrator>",
  "primaryEmail": "<owner>@myhomedomain.nl",
  "status": "active",
  "memberOf": ["myhome__family", "mybusiness-bv__staff", "tappaas-org__maintainers"],
  "roles": ["admin"]
}
```

A User's **effective roles** = its direct `roles` ∪ every `roles` entry of the Groups it is in
(`memberOf`). `status` is the lifecycle field — only `active` users get access; `suspended` strips all
roles/memberships in Authentik; `terminated` is the one governed deletion. The same User shows contextual
UI labels per Group (`family-members`→"Family Member", `team`→"Staff"/"Maintainer", global→"User").

### Role — schema (`config/people/roles/{name}.json`)

A **Role** is a standalone, cross-cutting permission label — **not** nested under Org/Group/User. It is
assigned directly on a User (`User.roles`) or inherited by every member of a Group (`Group.roles`). The
actual permissions/policies behind it are configured in Authentik (ADR-006); TAPPaaS owns only the
label + its assignments.

```json
{
  "name": "admin",
  "description": "Platform administrator (manage modules, environments, people)."
}
```

The minimal bootstrap install creates three roles — `root`, `admin`, `user` — and one Group, `users`.

## Why Group (not Team) as the primitive

12/12 IAM systems (LDAP, AD, Authentik, Keycloak, AWS/Azure/GCP IAM, Okta, Auth0, K8s RBAC, Backstage)
use **Group**; Team is a collaboration-tool label. Group covers all 7 TAPPaaS use cases; Team does
not. Evidence: [Architecture/taxonomy.md](<../Architecture/taxonomy.md>) → A.3.

## Acceptance

- [ ] Sample `organizations/`, `groups/`, `users/` files created and validated.
- [ ] Consistent with ADR-006 (role profiles, SSO provisioning).
