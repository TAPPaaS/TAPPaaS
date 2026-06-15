# ADR-007a — People

| | |
|---|---|
| **Status** | Proposed |
| **Version** | 1.0 |
| **Date** | 2026-06-15 |
| **Author** | Erik Daniel |
| **Parent** | [ADR-007 Taxonomy (Overview)](<ADR-007 - TAPPaaS Taxonomy.md>) |
| **Related** | #320; ADR-006 (identity — users, roles, SSO) |

The **👥 People** bucket — one of ADR-007's three buckets.

## Decision

People is a **3-level hierarchy**: `Organization → Group → User`. A User can belong to many Groups
across many Organizations. Maps 1:1 onto Authentik primitives (Tenant · Group · User). RBAC is built on
**Group** (the universal IAM primitive); role/SSO provisioning is ADR-006.

## The three levels

| Level | Definition | `type` values | Authentik |
|-------|------------|---------------|-----------|
| **Organization** | legal/identity entity; owns Environments + Apps | `family` · `company` · `foundation` · `customer` | Tenant (1:1) |
| **Group** | collection of Users within one Org; the RBAC primitive | `team` · `department` · `family-members` · `access-set` · `ad-hoc` | Group (1:1) |
| **User** | an individual human; belongs to ≥1 Group | — | User (1:1) |

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

### Group — schema (`config/people/groups/{org}__{name}.json`)

```json
{
  "name": "mybusiness-bv__staff",
  "type": "team",
  "displayName": "MyBusiness Staff",
  "ownerOrg": "mybusiness-bv",
  "members": ["<owner>", "person2"],
  "authentikGroup": "mybusiness-bv-staff",
  "roles": ["editor"]
}
```

### User — schema (`config/people/users/{name}.json`)

```json
{
  "name": "<owner>",
  "displayName": "<Site Administrator>",
  "primaryEmail": "<owner>@myhomedomain.nl",
  "memberOf": ["myhome__family", "mybusiness-bv__staff", "tappaas-org__maintainers"],
  "authentikUser": "<owner>"
}
```

The same User shows contextual UI labels per Group (`family-members`→"Family Member", `team`→"Staff"/
"Maintainer", global→"User").

## Why Group (not Team) as the primitive

12/12 IAM systems (LDAP, AD, Authentik, Keycloak, AWS/Azure/GCP IAM, Okta, Auth0, K8s RBAC, Backstage)
use **Group**; Team is a collaboration-tool label. Group covers all 7 TAPPaaS use cases; Team does
not. Evidence: [Architecture/taxonomy.md](<../Architecture/taxonomy.md>) → A.3.

## Acceptance

- [ ] Sample `organizations/`, `groups/`, `users/` files created and validated.
- [ ] Consistent with ADR-006 (role profiles, SSO provisioning).
