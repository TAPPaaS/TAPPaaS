# TAPPaaS Taxonomy — Reference (worked example, sample files, evidence, glossary)

> **Living reference, not a decision.** The decisions are in [ADR-007](<../ADR/ADR-007 - TAPPaaS Taxonomy.md>)
> (overview) + 007a–007e + [ADR-009](<../ADR/ADR-009 - Composition Meta-Model.md>). This doc holds the
> *current* tables, the worked example, ready-to-use sample files, and the industry evidence. Other
> docs link here instead of restating the model.

## The model at a glance

**One Site** (container) → **3 buckets** (👥 People · 📦 Apps · 🏠 Environments) + **1 lens** (🩺 Health).

## Worked example — SOHO setup

A founder runs a household, a consulting company, contributes to TAPPaaS, and hosts one paying client,
all on one physical Site:

```
🏢 Site: mysite-soho
 ├ 👥 People
 │   ├ Orgs:   myhome(family) · mybusiness-bv(company) · tappaas-org(foundation) · client-acme(customer→mybusiness-bv)
 │   ├ Groups: myhome__family · mybusiness-bv__staff · tappaas-org__maintainers · client-acme__admins
 │   └ Users:  <owner>(family+staff+maintainers) · person2..4(family)
 ├ 🏠 Environments: myhome · mybusiness · tappaas · client-acme · dev   (each ownerOrg + zone + domain)
 └ 📦 Apps
     ├ foundation/official: firewall · cluster · identity · caddy · backup · tappaas-cicd
     ├ app/official:        openwebui · vaultwarden · nextcloud · ...
     ├ app/community:       some-cool-app
     └ app/private:         consultancy-customer-portal
```

## Secrets — where they live

| Secret type | Bucket | Stored |
|---|---|---|
| Personal credential | 👥 People | Authentik + Vaultwarden |
| Workload secret | 📦 App | App-scoped store, `secretsRef` |
| Infrastructure secret | 🏢 Site | `site.json` references, vault-managed |

Rule: a secret belongs to the *thing that consumes it*; People-bucket RBAC decides who may read/change it.

## Sample files (ready-to-use; replace placeholders)

`site.json`, `people/organizations/*.json`, `people/groups/*.json`, `people/users/*.json`,
`environments/*.json` — see the schema blocks in the corresponding sub-ADR (007a People, 007c
Environments, 007d Site). Minimal `site.json`:

```json
{
  "name": "mysite-soho", "displayName": "My SOHO", "owner": "<owner>",
  "location": { "country": "NL", "timezone": "Europe/Amsterdam", "locale": "nl_NL" },
  "network": { "rootDomain": "myhomedomain.nl" },
  "hardware": { "nodes": ["tappaas1", "tappaas2"], "storagePools": ["tanka1", "tankb2"], "cluster": "tappaas" },
  "identityProvider": { "type": "authentik", "url": "https://id.myhomedomain.nl" },
  "backup": { "target": "backup.myhomedomain.nl", "offsite": "tappaas-backup-buddy" },
  "updateChannel": "stable"
}
```

## Appendix A — Industry evidence (data points)

**A.1 — Top-level concepts across 18 platforms:** Identity/People 18/18; App/Workload 18/18;
Environment 8/10; Project/Site 8/10; Health-as-separate-bucket 7/10 (variably positioned → TAPPaaS
chooses *lens*). → justifies **People · Apps · Environments + Health lens**.

**A.2 — Organization vs Tenant:** "Organization/Org" used by GCP, GitHub, Okta, Salesforce, HashiCorp,
Google Workspace, Apple BM, AWS Orgs, Auth0, Microsoft = **10**; "Tenant" = 4 (architecture term only).

**A.3 — Group vs Team:** 12/12 IAM systems (LDAP, AD, Authentik, Keycloak, AWS/Azure/GCP IAM, Okta,
Auth0, Linux, K8s RBAC, Backstage) use **Group**. Group covers all 7 TAPPaaS use cases; Team does not.

**A.4 — Comparable hierarchies:** Backstage Domain→System→Component; Coolify Server→Project→Env→Resource;
Vercel Team→Project→Env; K8s Cluster→Namespace→Workload; UniFi Account→Site→Devices; AWS Org→Account→Resource;
GCP Org→Folder→Project. TAPPaaS is intentionally flatter (Site → 3 buckets) for prosumer UX.

**A.5 — "Environment" adoption:** de-facto term in every multi-env-capable platform (K8s, Coolify,
Vercel, GCP/AWS/Azure, Heroku); single-env appliances (Synology, YunoHost, Umbrel, CasaOS) omit it.

**A.6 — Multi-Org-on-one-host:** maps to cloud Organizations, MSP multi-tenant, holding-company IT,
indie-hacker domains, Authentik/Keycloak realms. Common at enterprise scale, gap in prosumer FOSS.

**A.7 — Source vs Tier:** 7/9 platforms (Debian, Ubuntu, HACS, Nextcloud, Synology, Umbrel, YunoHost)
model curated-vs-community as **source**, separate from lifecycle **tier**. Both dimensions needed.

## Appendix C — Glossary

| Term | Definition |
|---|---|
| **Site** | The physical + admin perimeter. One TAPPaaS = one Site. |
| **Organization** | A legal/identity entity (family, company, foundation, customer). Owns Envs + Apps. |
| **Group** | A collection of Users for access control. Lives in one Org. The RBAC primitive. |
| **User** | An individual human. Can be in many Groups across many Orgs. |
| **Environment** | Where Apps run. Has zone, domain, update window. Owned by an Org. |
| **App** | A workload (VM, container, service). Has a `tier` and a `source`. |
| **Tier** | App lifecycle class: `foundation` (cannot uninstall) or `app` (user-installable). |
| **Source** | App origin: `official` · `community` · `private` · `local`. |
| **Health** | Cross-cutting observability lens. Not a bucket. |
| **Tenant** | Architecture term for an isolated customer of a multi-tenant system. *Not* a UI term. |
| **Node** | The physical Proxmox host (`tappaas1`). The VM is the **Module**. See ADR-009. |
| **Module / Component / Function / Service / Stack** | Composition meta-model — see ADR-009. |
