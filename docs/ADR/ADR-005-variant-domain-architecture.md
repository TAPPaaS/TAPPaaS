# ADR-005: Variant & Domain Architecture

**Status:** proposed
**Date:** 2026-06-06
**Deciders:** @LarsRossen + @ErikDaniel007
**Related:** #269, #270, #289, #290, #292, #299

---

## Context

Six issues converge on the same architectural gap: TAPPaaS has no formal concept of **variants** (isolated module instances for tenants/environments) or **multi-domain** support. The current single-domain model with ad-hoc `--variant` naming creates certificate mismatches, dependency resolution failures, and DNS problems.

| Issue | Title | Core Problem |
| ----- | ----- | ------------ |
| #269 | acme-setup: wildcard cert but no split-horizon DNS | Internal clients route via WAN, get 403 from Caddy ACL |
| #270 | caddy-manager: add redir handler support | No way to configure redirects (www → identity) |
| #289 | acme-manager: support extra wildcard SANs | `*.customer1.tappaas.org` needs explicit SAN |
| #290 | install-module.sh: variant deploy fails | Steps 3-5 use source module name instead of effective |
| #292 | check_service_available: variant deploys fail | Dependency check ignores `<module>-<variant>.json` |
| #299 | feat: domain_groups — per-zone domain routing | Different zones need different public domains |

---

## Decision

### 1. Variants as First-Class Entities

Variants are registered in `configuration.json` with their own domain, optional dedicated zone, and TLS certificate:

```json
{
  "tappaas": {
    "email": "admin@example.com",
    "variants": {
      "": {
        "domain": "tappaas.org",
        "tlsCertRefid": "abc123",
        "dnsMode": "wildcard",
        "description": "Default (no variant)"
      },
      "demo": {
        "domain": "demo.tappaas.org",
        "tlsCertRefid": "def456",
        "zone": "demo",
        "dnsMode": "wildcard",
        "description": "Demo/sandbox environment"
      },
      "acme-corp": {
        "domain": "acme-corp.eu",
        "tlsCertRefid": "",
        "zone": "acme-corp",
        "dnsMode": "per-service",
        "description": "ACME Corporation tenant (no DNS API)"
      }
    }
  }
}
```

**Key fields:**

- `""` (empty string) is the default variant — modules without `--variant` use this
- `domain` — the public domain for this variant's services
- `tlsCertRefid` — OPNsense Trust refid for the wildcard cert (empty if `dnsMode=per-service`)
- `zone` — optional dedicated zone; if omitted, modules use their own `zone0`
- `dnsMode` — `wildcard` (default) or `per-service` (see section 5)

### 2. No Default Domain at Install Time

Remove `tappaas.domain` from initial install. The bootstrap flow becomes:

```bash
# Fresh install — no domain yet
curl ... | bash -s -- --branch main

# On tappaas-cicd, register the default variant
variant-manager add "" --domain tappaas.org

# Set up TLS
acme-setup.sh --variant ""

# Continue with rest-of-foundation.sh
```

### 3. Zone Naming and Allocation

Variant zones use the variant name directly (not prefixed):

```json
{
  "acme-corp": {
    "type": "Service",
    "state": "Active",
    "vlantag": 260,
    "ip": "10.2.60.0/24",
    "bridge": "lan",
    "access-to": ["internet"],
    "pinhole-allowed-from": ["dmz"],
    "parent": "srvCust",
    "variant": "acme-corp",
    "description": "ACME Corporation tenant zone"
  }
}
```

**VLAN allocation:**

- Variant zones start at VLAN 260 (10.2.60.0/24)
- Supports up to 39 variants (VLAN 260-298, avoiding 299 reserved)
- Can be overridden: `variant-manager add foo --domain foo.com --add-zone --vlan 275`

### 4. Variant-Aware Dependency Resolution

When `install-module.sh openwebui --variant demo`:

**Same-variant preference:**

```text
dependsOn: ["litellm:api"]
→ Look for litellm-demo.json first (same variant)
→ Fall back to litellm.json (default variant)
```

**Explicit variant reference:**

```json
{
  "dependsOn": ["litellm-demo:api", "cluster:vm"]
}
```

- `litellm-demo:api` → must find `litellm-demo.json`
- `cluster:vm` → foundation service, always variant-agnostic

**Cross-variant dependencies:**

```json
{
  "dependsOn": ["nextcloud-acme-corp:caldav", "identity:oidc"]
}
```

- `nextcloud-acme-corp:caldav` → explicit same-tenant dependency
- `identity:oidc` → shared service from default variant

### 5. DNS Mode: Wildcard vs Per-Service

**`dnsMode: "wildcard"` (default)**

- `acme-setup.sh` issues `*.<domain>` + `<domain>` via DNS-01 challenge
- Requires DNS provider API credentials
- Split-horizon: wildcard DNS override points `*.<domain>` to Caddy
- All services share one certificate

**`dnsMode: "per-service"`**

- No wildcard cert; each service gets its own cert via HTTP-01
- **No DNS API required** — works for domains without ACME API support
- Each module's proxy install creates a per-service DNS entry
- Caddy handles Let's Encrypt HTTP-01 challenge per domain
- Trade-off: slightly slower initial cert issuance, more certs to manage

Use cases for `per-service`:

- Customer owns domain but won't share DNS API credentials
- Domain registrar has no supported ACME DNS plugin
- Testing with domains you don't fully control

### 6. Per-Service DNS Registration (Fixes #269)

When `dnsMode: "wildcard"`:

```bash
# Single wildcard entry per variant (registered by acme-setup.sh)
dns-manager add "*" "tappaas.org" "10.6.0.1" --description "TAPPaaS: wildcard"
```

When `dnsMode: "per-service"`:

```bash
# Per-module entry (registered by firewall:proxy install-service.sh)
dns-manager add "nextcloud" "acme-corp.eu" "10.6.0.1" --description "TAPPaaS: nextcloud-acme-corp"
dns-manager add "vaultwarden" "acme-corp.eu" "10.6.0.1" --description "TAPPaaS: vaultwarden-acme-corp"
```

### 7. Redirect Handler Support (Addresses #270)

Add `--redir` support to `caddy-manager` as a standalone capability:

```bash
caddy-manager add-handler www.tappaas.org --redir "https://identity.tappaas.org" --redir-code 301
```

This is a general-purpose feature for URL redirects. The specific use case of `www.<domain>` landing pages and what they should redirect to is **out of scope** for this ADR — that's a separate design concern (likely related to a WordPress or landing-page module).

---

## Variant Lifecycle

```text
┌─────────────────────────────────────────────────────────────────┐
│                     variant-manager.sh                          │
├─────────────────────────────────────────────────────────────────┤
│ variant-manager add <name> --domain <domain>                    │
│   [--zone <existing>]       Use an existing zone                │
│   [--add-zone]              Create a new zone (VLAN 260+)       │
│   [--vlan <num>]            Override auto VLAN selection        │
│   [--dns-mode wildcard|per-service]  Default: wildcard          │
│   [--description "..."]                                         │
│                                                                 │
│ variant-manager list                                            │
│   Shows all registered variants with domain/zone/cert status    │
│                                                                 │
│ variant-manager show <name>                                     │
│   Detailed view of a variant                                    │
│                                                                 │
│ variant-manager remove <name>                                   │
│   Removes variant (fails if modules still deployed)             │
└─────────────────────────────────────────────────────────────────┘
```

---

## Module Installation Flow

```bash
install-module.sh nextcloud --variant acme-corp
```

**Step 2 (copy-update-json.sh):**

1. Lookup variant `acme-corp` in `configuration.json`
2. If not found → error: `Variant 'acme-corp' not registered. Run: variant-manager add acme-corp --domain ...`
3. Get `domain = "acme-corp.eu"`
4. Get `zone = "acme-corp"` (or module's default if variant has no zone)
5. Auto-derive `proxyDomain = "nextcloud.acme-corp.eu"`
6. Write config as `nextcloud-acme-corp.json`

**Step 5 (firewall:proxy install-service.sh):**

1. Read `variant` from module config (or `""`)
2. Lookup variant in `configuration.json`
3. Get `dnsMode` for that variant
4. If `wildcard`: use variant's `tlsCertRefid`
5. If `per-service`: let Caddy issue via HTTP-01, register per-module DNS entry
6. Create Caddy domain and handler

---

## Data Model Changes

### configuration.json

```diff
 {
   "tappaas": {
-    "domain": "tappaas.org",
-    "tlsCertRefid": "abc123",
     "email": "admin@example.com",
+    "variants": {
+      "": {
+        "domain": "tappaas.org",
+        "tlsCertRefid": "abc123",
+        "dnsMode": "wildcard",
+        "description": "Default"
+      }
+    }
   }
 }
```

### Module JSON (when --variant used)

```json
{
  "vmname": "nextcloud-acme-corp",
  "variant": "acme-corp",
  "zone0": "acme-corp",
  "proxyDomain": "nextcloud.acme-corp.eu",
  "dependsOn": ["cluster:vm", "firewall:proxy"]
}
```

### zones.json (variant zones)

```json
{
  "acme-corp": {
    "type": "Service",
    "state": "Active",
    "vlantag": 260,
    "ip": "10.2.60.0/24",
    "bridge": "lan",
    "parent": "srvCust",
    "variant": "acme-corp",
    "access-to": ["internet"],
    "pinhole-allowed-from": ["dmz"],
    "description": "ACME Corporation tenant zone"
  }
}
```

---

## Migration Path

### Phase 1: Bug Fixes (No Breaking Changes)

1. Fix #290: Use `effective_module` in steps 3-5 of `install-module.sh`
2. Fix #292: `check_service_available` scans `<provider>-*.json` for variant matches
3. Add `tappaas.variants` structure alongside existing `tappaas.domain`
4. Existing `tappaas.domain` + `tappaas.tlsCertRefid` become aliases for `variants[""]`

### Phase 2: Variant Manager

1. Create `variant-manager.sh` CLI
2. Add `--add-zone` with VLAN 260+ allocation
3. Update `copy-update-json.sh` to lookup variant registry
4. Update `acme-setup.sh` to accept `--variant`

### Phase 3: DNS Mode Support

1. Add `dnsMode` field to variants
2. Update `firewall:proxy install-service.sh` for per-service DNS
3. Add `caddy-manager add-handler --redir` (#270)

### Phase 4: Deprecation

1. Deprecate `tappaas.domain` (log warning if used)
2. Migration script to convert existing installs
3. Remove alias in next major version

---

## Files to Modify

| File | Changes |
| ---- | ------- |
| `configuration.json.template` | Remove domain, add variants structure |
| `create-configuration.sh` | Support variants; domain becomes optional |
| `acme-setup.sh` | Accept `--variant`, write to `variants[].tlsCertRefid` |
| `copy-update-json.sh` | Lookup variant for domain/zone derivation |
| `install-module.sh` | Validate variant exists before install |
| `common-install-routines.sh` | `check_service_available` variant-aware resolution |
| `firewall:proxy install-service.sh` | Per-module DNS for `dnsMode=per-service` |
| `caddy_cli.py` | Add `--redir` and `--redir-code` to `add-handler` |
| `zones.json` | Support `parent`/`variant` fields |
| NEW: `variant-manager.sh` | Variant registry CLI |

---

## Consequences

### Positive

- Multi-tenant support with proper isolation
- Multiple domains per cluster
- Works with DNS providers that lack ACME API
- Variant dependencies are explicit and traceable
- Fixes all six issues in a coherent architecture

### Negative

- More complex initial setup (must register default variant)
- Migration required for existing single-domain installs
- `per-service` mode issues more certs (Let's Encrypt rate limits)

### Neutral

- Zone naming changes from `srvCust-foo` to just `foo`
- VLAN allocation moves to 260+ range for variants

---

## Implementation Plan

### Sprint 1: Bug Fixes & Foundation (No Breaking Changes)

**Goal:** Fix existing variant bugs, add variants structure without breaking current installs.

#### 1.1 Fix #290: `effective_module` in install-module.sh

- **File:** `src/foundation/tappaas-cicd/scripts/install-module.sh`
- **Change:** Replace `${module}` with `${effective_module}` in steps 3-5
- **Test:** `install-module.sh nextcloud --variant demo` completes step 3

#### 1.2 Fix #292: Variant-aware `check_service_available`

- **File:** `src/foundation/tappaas-cicd/scripts/common-install-routines.sh`
- **Change:** When exact provider config not found, scan `<provider>-*.json` for variant matches
- **Test:** `euro-office --variant demo` finds `nextcloud-demo.json` as provider

#### 1.3 Add `tappaas.variants` structure (backwards compatible)

- **File:** `src/foundation/tappaas-cicd/scripts/create-configuration.sh`
- **Change:** When `--domain` provided, create both legacy `tappaas.domain` AND `tappaas.variants[""]`
- **Test:** Existing installs continue to work; new installs have both structures

#### 1.4 Add helper function to read variant config

- **File:** `src/foundation/tappaas-cicd/scripts/common-install-routines.sh`
- **Add:** `get_variant_config <variant-name>` that reads from `tappaas.variants[name]`, falls back to legacy `tappaas.domain`
- **Test:** Works with both old and new configuration.json formats

---

### Sprint 2: Variant Manager CLI

**Goal:** Create the `variant-manager` CLI for registering variants.

#### 2.1 Create `variant-manager.sh` skeleton

- **File:** NEW `src/foundation/tappaas-cicd/scripts/variant-manager.sh`
- **Commands:** `add`, `list`, `show`, `remove`
- **Symlink:** `/home/tappaas/bin/variant-manager`

#### 2.2 Implement `variant-manager add`

- **Validation:** Domain format, variant name (alphanumeric + hyphen)
- **Write:** Add entry to `configuration.json` under `tappaas.variants`
- **Options:** `--domain` (required), `--zone`, `--dns-mode`, `--description`

#### 2.3 Implement `variant-manager add --add-zone`

- **File:** Also modifies `zones.json`
- **Logic:** Find next free VLAN starting at 260, create zone entry with `parent: "srvCust"`, `variant: <name>`
- **Option:** `--vlan <num>` to override auto-allocation
- **Calls:** `zone-manager` to activate the new zone

#### 2.4 Implement `variant-manager list/show/remove`

- **list:** Table of variants with domain, zone, cert status, module count
- **show:** Detailed view of single variant
- **remove:** Fails if modules still deployed to this variant

---

### Sprint 3: Variant-Aware Module Installation

**Goal:** `copy-update-json.sh` and `install-module.sh` use variant registry.

#### 3.1 Update `copy-update-json.sh` to lookup variant registry

- **File:** `src/foundation/tappaas-cicd/scripts/copy-update-json.sh`
- **Change:** When `--variant` provided:
  1. Lookup variant in `configuration.json`
  2. Error if not registered
  3. Get domain from variant, derive `proxyDomain`
  4. Get zone from variant (if set), override `zone0`

#### 3.2 Update `install-module.sh` variant validation

- **File:** `src/foundation/tappaas-cicd/scripts/install-module.sh`
- **Change:** Before step 2, validate variant exists in registry
- **Error:** Clear message: `Variant 'foo' not registered. Run: variant-manager add foo --domain ...`

#### 3.3 Update `acme-setup.sh` to accept `--variant`

- **File:** `src/foundation/tappaas-cicd/scripts/acme-setup.sh`
- **Change:**
  - Accept `--variant <name>` (default: `""`)
  - Read domain from `tappaas.variants[name].domain`
  - Write refid to `tappaas.variants[name].tlsCertRefid`
- **Backwards compat:** Also write to legacy `tappaas.tlsCertRefid` if variant is `""`

---

### Sprint 4: DNS Mode Support

**Goal:** Implement `wildcard` vs `per-service` DNS modes.

#### 4.1 Add `dnsMode` field to variant schema

- **Default:** `"wildcard"`
- **Values:** `"wildcard"` | `"per-service"`

#### 4.2 Update `acme-setup.sh` for wildcard DNS registration

- **File:** `src/foundation/tappaas-cicd/scripts/acme-setup.sh`
- **Change:** After cert issuance, if `dnsMode=wildcard`:

  ```bash
  dns-manager add "*" "${DOMAIN}" "${CADDY_IP}" --description "TAPPaaS: ${VARIANT} wildcard"
  ```

#### 4.3 Update `firewall:proxy install-service.sh` for per-service mode

- **File:** `src/foundation/firewall/services/proxy/install-service.sh`
- **Change:**
  - Read variant from module config
  - Lookup `dnsMode` from variant
  - If `per-service`: register per-module DNS entry, skip `--custom-certificate`
  - If `wildcard`: use variant's `tlsCertRefid` (existing behavior)

#### 4.4 Add `caddy-manager add-handler --redir` (#270)

- **File:** `src/foundation/tappaas-cicd/opnsense-controller/src/opnsense_controller/caddy_cli.py`
- **Add:** `--redir <url>` and `--redir-code <301|302|307|308>` options
- **File:** `src/foundation/tappaas-cicd/opnsense-controller/src/opnsense_controller/caddy_manager.py`
- **Add:** `create_redir_handler()` method

---

### Sprint 5: Migration & Deprecation

**Goal:** Migrate existing installs, deprecate legacy fields.

#### 5.1 Create migration script

- **File:** NEW `src/foundation/tappaas-cicd/scripts/migrate-to-variants.sh`
- **Logic:**
  1. Read `tappaas.domain` and `tappaas.tlsCertRefid`
  2. Create `tappaas.variants[""]` with those values
  3. Set `dnsMode: "wildcard"`
  4. Optionally remove legacy fields (with `--remove-legacy` flag)

#### 5.2 Add deprecation warnings

- **Files:** All scripts that read `tappaas.domain` directly
- **Change:** Log warning: `tappaas.domain is deprecated. Run migrate-to-variants.sh`
- **Timing:** Warn for 2 releases before removal

#### 5.3 Update documentation

- **Files:** `INSTALL.md`, `README.md`, module docs
- **Change:** Document new bootstrap flow with `variant-manager`

---

## Milestones

| Milestone | Sprints | Issues Closed | Breaking Changes |
| --------- | ------- | ------------- | ---------------- |
| v0.1 | Sprint 1 | #290, #292 | None |
| v0.2 | Sprint 2 | — | None |
| v0.3 | Sprint 3 | #289 (partial) | None (but requires variant registration) |
| v0.4 | Sprint 4 | #269, #270, #289, #299 | None |
| v1.0 | Sprint 5 | — | `tappaas.domain` removed |

---

## Testing Strategy

All variant tests are implemented in `src/foundation/tappaas-cicd/test-variants/` and activated
via `test-module.sh tappaas-cicd --deep` (sets `TAPPAAS_TEST_DEEP=1`).

### Test Suite Structure

```text
src/foundation/tappaas-cicd/
├── test.sh                          # Main test runner
├── test-variants/
│   ├── test.sh                      # Variant test suite orchestrator
│   ├── test-variant-manager.sh      # Unit tests for variant-manager CLI
│   ├── test-variant-install.sh      # Integration tests for --variant installs
│   ├── test-variant-deps.sh         # Dependency resolution tests
│   ├── test-variant-dns.sh          # DNS mode tests (wildcard vs per-service)
│   └── fixtures/
│       ├── test-variant-base.json   # Base module for variant testing
│       ├── test-variant-dep.json    # Module with variant dependencies
│       └── zones-test.json          # Test zones fixture
```

### Unit Tests (test-variant-manager.sh)

**Offline tests, no cluster required.**

| Test | Description |
| ---- | ----------- |
| VM-01 | `variant-manager add "" --domain foo.org` creates default variant |
| VM-02 | `variant-manager add demo --domain demo.foo.org` creates named variant |
| VM-03 | `variant-manager add x --add-zone` allocates VLAN 260, creates zone |
| VM-04 | `variant-manager add y --add-zone` allocates VLAN 261 (next free) |
| VM-05 | `variant-manager add z --add-zone --vlan 275` uses explicit VLAN |
| VM-06 | `variant-manager add dup --domain dup.org` fails if variant exists |
| VM-07 | `variant-manager add bad!name` fails on invalid characters |
| VM-08 | `variant-manager list` shows all variants with status |
| VM-09 | `variant-manager show demo` shows single variant details |
| VM-10 | `variant-manager remove demo` fails if modules deployed |
| VM-11 | `variant-manager remove demo --force` removes even with modules |
| VM-12 | `get_variant_config ""` returns default variant |
| VM-13 | `get_variant_config "demo"` returns demo variant |
| VM-14 | `get_variant_config` falls back to legacy `tappaas.domain` |

### Integration Tests (test-variant-install.sh)

**Requires cluster access. Creates and destroys test VMs.**

| Test | Description |
| ---- | ----------- |
| VI-01 | Install variant without base: `install-module.sh test-variant-base --variant demo` succeeds |
| VI-02 | Install base after variant: `install-module.sh test-variant-base` succeeds, coexists |
| VI-03 | Verify both VMs exist: `test-variant-base` (VMID X) and `test-variant-base-demo` (VMID X+1) |
| VI-04 | Verify proxyDomain derived correctly: `test-variant-base.demo.<domain>` |
| VI-05 | Verify zone0 from variant registry overrides module default |
| VI-06 | Install with unregistered variant fails with clear error message |
| VI-07 | Reinstall variant: `install-module.sh test-variant-base --variant demo --reinstall` |
| VI-08 | Delete variant module: `delete-module.sh test-variant-base-demo` |
| VI-09 | Delete base module: `delete-module.sh test-variant-base` |

### Dependency Resolution Tests (test-variant-deps.sh)

**Tests same-variant preference and cross-variant dependencies.**

| Test | Description |
| ---- | ----------- |
| VD-01 | Same-variant preference: `test-dep --variant demo` finds `test-base-demo` first |
| VD-02 | Fallback to default: `test-dep --variant demo` falls back to `test-base` if no `test-base-demo` |
| VD-03 | Explicit variant dep: `dependsOn: ["test-base-demo:svc"]` requires exact match |
| VD-04 | Cross-variant dep: `test-dep-acme` can depend on `identity:oidc` (default variant) |
| VD-05 | Missing variant dep fails: `dependsOn: ["test-base-missing:svc"]` errors clearly |
| VD-06 | Foundation deps are variant-agnostic: `cluster:vm` always resolves to foundation |

### DNS Mode Tests (test-variant-dns.sh)

**Tests wildcard vs per-service DNS registration.**

| Test | Description |
| ---- | ----------- |
| VN-01 | Wildcard mode: `acme-setup.sh --variant ""` registers `*.<domain>` in Unbound |
| VN-02 | Wildcard mode: proxy install uses variant's `tlsCertRefid` |
| VN-03 | Per-service mode: proxy install registers `<module>.<domain>` in Unbound |
| VN-04 | Per-service mode: Caddy issues cert via HTTP-01 (no custom cert) |
| VN-05 | DNS entry cleanup: `delete-module.sh` removes per-service DNS entry |

### End-to-End Scenario Tests

**Full lifecycle tests combining multiple operations.**

| Test | Description |
| ---- | ----------- |
| VE-01 | **Fresh cluster bootstrap**: `variant-manager add "" --domain test.org` → `acme-setup.sh` → `install-module.sh identity` |
| VE-02 | **Multi-tenant setup**: Add 3 variants (default, demo, customer), install same module to each, verify isolation |
| VE-03 | **Variant zone creation**: `variant-manager add tenant1 --add-zone`, verify zone active, install module, verify VM in correct VLAN |
| VE-04 | **Migration**: Legacy install → `migrate-to-variants.sh` → verify `tappaas.variants[""]` created → existing modules still work |

### Test Fixtures

**test-variant-base.json:**

```json
{
  "vmname": "test-variant-base",
  "vmid": 8900,
  "node": "tappaas1",
  "cores": 1,
  "memory": "1024",
  "diskSize": "4G",
  "zone0": "mgmt",
  "dependsOn": ["cluster:vm"],
  "provides": ["test-variant:svc"]
}
```

**test-variant-dep.json:**

```json
{
  "vmname": "test-variant-dep",
  "vmid": 8910,
  "node": "tappaas1",
  "cores": 1,
  "memory": "1024",
  "diskSize": "4G",
  "zone0": "mgmt",
  "dependsOn": ["cluster:vm", "test-variant-base:svc"],
  "provides": []
}
```

### Test Execution

```bash
# Run all variant tests (deep mode)
test-module.sh tappaas-cicd --deep

# Run only variant tests
TAPPAAS_TEST_DEEP=1 ./test-variants/test.sh

# Run specific test file
./test-variants/test-variant-manager.sh

# Verbose output
TAPPAAS_DEBUG=1 ./test-variants/test.sh
```

### Cleanup

All test VMs use VMID range 8900-8999 (reserved for testing).
Test cleanup removes:

- VMs in the 8900-8999 range
- Module configs matching `test-variant-*.json`
- Variant entries matching `test-*` in configuration.json
- Test zones matching `test-*` in zones.json

### CI Integration

The variant tests are gated behind `--deep` to avoid running on every commit.
They run in:

- Nightly CI builds
- Pre-release validation
- Manual `test-module.sh tappaas-cicd --deep` runs
