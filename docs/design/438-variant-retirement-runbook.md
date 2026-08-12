# #438 — `.variant` retirement: migration runbook

Operator runbook for bringing an existing TAPPaaS site onto the `.variant`
retirement (issue #438). A site that follows this ends up in the state a
from-scratch install produces: `.environment` only, no `.variant` anywhere.

Applies to the branch `fix/438-variant-to-environment`.

---

## What changed, in one paragraph

`resolve_provider_module` picks the provider serving a consumer's environment
(`<provider>-<env>.json`), falling back to the shared `<provider>.json`.
`install-module.sh` never passed it the environment — it blanked the value
(`variant=""`) and forwarded that — so every consumer resolved its dependencies
against the *shared* provider regardless of which environment it was being
installed into. That was masked on current installs because `copy-update-json.sh`
mirrored `--environment` into a legacy `.variant` field, which the app service
scripts read independently. The mirror is now gone, `install-module.sh` forwards
`${environment}`, and everything that read `.variant` reads `.environment`.

Two symptoms this fixes:

| Shared `<provider>.json` | Before | After |
| --- | --- | --- |
| exists | consumer silently used the **shared** provider instead of its environment's | uses its environment's provider |
| absent | install **died** `provider module 'X' is not installed` | installs correctly |

---

## Two repos, not one

The Community repo (`~/Community`, registered in `site.json .repositories`) also
had a `.variant` reader — `mailserver-hub`'s mailbox install-service. Both repos
carry a branch of the same name and **both must be switched together**:

```bash
site-manager repository modify TAPPaaS   --branch fix/438-variant-to-environment
site-manager repository modify Community --branch fix/438-variant-to-environment
```

If you do not run `mailserver-hub`, the Community branch is a no-op for you — but
switch it anyway so the two repos stay in step.

---

## Order matters

**Switch the branch first, then migrate.** Not the other way round.

The new code reads `.environment`. Your configs already carry it (persisted since
`2ecfcc3`, 2026-06-22), so switching is safe on its own — `.variant` simply stops
being read. The migration then removes the now-vestigial field.

Doing it in the other order — stripping `.variant` while still on `main` — would
remove the only field the old code reads, and resolution would break.

One caveat: a config that has `.variant` but **no** `.environment` (installed
before June 2026) loses its environment signal the moment you switch branches,
until the migration adopts `.environment` for it. The migration reports these as
`adopt` rows. **Do not run any `install`/`update`/`reconcile` between switching
the branch and finishing step 3.** Nothing runs automatically, so just do the
steps back to back.

---

## Steps

### 1. Switch both repos to the branch

```bash
site-manager repository modify TAPPaaS   --branch fix/438-variant-to-environment
site-manager repository modify Community --branch fix/438-variant-to-environment
```

`repository modify --branch` fetches and checks out in place. Foundation scripts
are symlinked from `~/bin` into the checkout, so the new code is live
immediately. If the TS managers need rebuilding on your site:

```bash
~/TAPPaaS/src/foundation/tappaas-cicd/manager/module-manager/install.sh
```

### 2. Dry-run the migration

Read-only. Prints a per-config plan and writes nothing.

```bash
~/TAPPaaS/src/foundation/tappaas-cicd/scripts/migrate-drop-variant.sh
```

Each module config is classified:

| Row | Meaning | Action taken by `--apply` |
| --- | --- | --- |
| `drop` | `.environment` present and equal to `.variant` | remove `.variant` |
| `adopt` | no `.environment`, but the filename suffix `<base>-<variant>.json` proves the environment | set `.environment`, then remove `.variant` |
| `blocked` | see below | **skipped** — needs your decision |

`blocked` covers three cases:

- **CONFLICT** — `.environment` and `.variant` disagree. Decide which is correct.
  The filename suffix is usually the tiebreaker: `litellm-tenant1.json` is the
  `tenant1` instance whatever `.variant` claims.
- **unregistered environment** — no `config/environments/<env>.json`. Either
  register it with `environment-manager`, or the config is stale.
- **unsuffixed filename with no `.environment`** — cannot prove which environment
  this deployment belongs to. Inspect it by hand; if it is genuinely in the
  default environment or mgmt, just delete the `.variant` key yourself.

Exit code is `1` if anything is blocked, `0` if the plan is fully safe.

### 3. Apply

```bash
~/TAPPaaS/src/foundation/tappaas-cicd/scripts/migrate-drop-variant.sh --apply
```

It prompts before writing (`--yes` to skip), backs up every changed file to
`~/config/.variant-migration-<timestamp>/`, and migrates only the safe rows.

Afterwards it re-checks **every** module's `dependsOn` and reports any dependency
that no longer resolves to a deployed provider. That check must come back clean:

```text
Verifying dependency resolution
  ✓ every dependency resolves to a deployed provider
```

If it does not, stop and report — do not run an update on top of it.

Resolve any `blocked` rows by hand, then re-run. The script is idempotent.

### 4. Confirm the gate

The ADR-007 gate that could not previously be met — no config carries `.variant`:

```bash
jq -e 'has("variant")' ~/config/*.json 2>/dev/null && echo "STILL PRESENT" || echo "clean"
```

Spot-check that consumers now pair with their own environment's provider. For a
consumer in environment `<env>` depending on `<provider>`:

```bash
jq -r '.environment' ~/config/<consumer>.json          # -> <env>
ls ~/config/<provider>-<env>.json                      # the intended provider
```

### 5. General update

```bash
update-tappaas --dry-run
update-tappaas --force
```

Watch a module that previously mis-resolved — your `litellm-tenant1` consumer, or
a test-tier consumer of `nextcloud`/`coturn`. In `Update Step 4: Call dependency
service updaters` the provider named should be the environment's instance, not
the shared one.

To exercise a single module instead of the whole site:

```bash
module-manager modify <module>
```

### 6. Report back

Say which modules moved from shared to dedicated providers, and paste anything
`blocked` you had to resolve by hand. Then the branch is merged to `main` and
both sites go back:

```bash
site-manager repository modify TAPPaaS   --branch main
site-manager repository modify Community --branch main
```

---

## Rolling back

```bash
cp ~/config/.variant-migration-<timestamp>/*.json ~/config/
site-manager repository modify TAPPaaS   --branch main
site-manager repository modify Community --branch main
```

Restores both the configs and the code. Safe because the migration only ever
removes `.variant` and (for `adopt` rows) adds `.environment` — no other field is
touched.

---

## What was changed in the code

| Area | Files |
| --- | --- |
| resolver + dependency check | `lib/common-install-routines.sh` |
| forwarding (the actual defect) | `manager/module-manager/install-module.sh` |
| stopped writing the mirror | `manager/module-manager/copy-update-json.sh` |
| name-suffix stripping | `lib/apply-json-merge.sh`, `manager/health-manager/update-os.sh`, `manager/module-manager/update-module.sh` |
| provider pairing | `apps/{litellm,coturn,nextcloud,nextcloud-hpb,euro-office}/**` |
| **environment domain / dnsMode / TLS refid** | `foundation/network/services/proxy/{install,update,delete,test}-service.sh` |
| **OIDC redirect derivation** | `foundation/identity/services/identity/install-service.sh` |
| environment domain (apps) | `apps/nextcloud/install.sh`, `apps/hass/lib/config.sh` |
| TS reconcile | `manager/module-manager/src/{config,reconcile}.ts` |
| schema | `foundation/schemas/module-fields.json` |
| tests | `test-variants/test-variant-{config,install,provider-resolution}.sh` |
| Community repo | `AndreasJe/mailserver-hub/mailserver/services/mailbox/install-service.sh` |

The two bold rows are the ones with the widest blast radius, and they were nearly
missed: they read the field **indirectly** via `get_config_value 'variant'`,
which no `.variant` grep matches. `network:proxy` uses it to pick the
environment's domain, DNS mode and TLS certificate refid; `identity` uses it to
build OIDC redirect URIs. Left unconverted, dropping `.variant` would have
silently given every non-default-environment module the **default** environment's
domain and certificate.

`test-variant-provider-resolution.sh` PR-09 now sweeps the whole tree for both
read forms — direct and indirect — so this class of miss fails a test rather than
reaching a site.

`test-variant-provider-resolution.sh` is new and covers the defect directly: the
old suite exercised `resolve_provider_module` in isolation and passed throughout,
because the bug was never in the resolver — it was in what the caller forwarded.
