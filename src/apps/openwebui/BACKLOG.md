# OpenWebUI TAPPaaS Backlog

**Last Updated:** 2026-02-04  
**Current Version:** 0.9.0
**Author:** Erik Daniel

## Story Format

Stories use MoSCoW prioritization:
- **Must Have:** Critical for next release
- **Should Have:** Important but not blocking
- **Could Have:** Nice to have if time permits
- **Won't Have:** Not planned for this release

## Q1 2026 - Automation & Security

### Must Have Stories

| ID | Story | Module | Priority | Status | Blocker |
|----|-------|--------|----------|--------|---------|
| AUTO-001 | Update Template VM 8080 with dynamic VLAN configuration | tappaas-core | Must | Todo | - |
| AUTO-002 | Implement cloud-init network config injection (ADR-002) | tappaas-core | Must | Todo | AUTO-001 |
| AUTO-003 | Update Create-TAPPaaS-VM.sh with cloud-init support | tappaas-cicd | Must | Todo | AUTO-002 |
| AUTO-004 | Fix openwebui.nix in repository (ens18, cloud-init disabled) | nix-modules | Must | Todo | - |
| AUTO-005 | Create hook script for tap interface VLAN configuration | tappaas-core | Must | Todo | - |
| AUTO-006 | Test end-to-end automated deployment | tappaas-cicd | Must | Todo | AUTO-001,002,003 |

### Should Have Stories

| ID | Story | Module | Priority | Status | Blocker |
|----|-------|--------|----------|--------|---------|
| SEC-001 | Replace PostgreSQL trust authentication with password auth | nix-modules | Should | Todo | - |
| SEC-002 | Generate and store secure secrets (PostgreSQL, Redis, OpenWebUI) | tappaas-core | Should | Todo | - |
| SEC-003 | Document security hardening procedures | docs | Should | Todo | SEC-001,002 |
| OPS-001 | Deploy hook script to all Proxmox nodes | tappaas-core | Should | Todo | AUTO-005 |
| OPS-002 | Audit existing VMs for incorrect VLAN configuration | tappaas-core | Should | Todo | AUTO-005 |
| DOC-001 | Update ADR-001 with final implementation status | docs | Should | Todo | AUTO-006 |
| DOC-002 | Create ADR-002 for cloud-init integration | docs | Should | Todo | AUTO-002 |

### Could Have Stories

| ID | Story | Module | Priority | Status | Blocker |
|----|-------|--------|----------|--------|---------|
| FEAT-001 | Add SSL/TLS support for OpenWebUI web interface | nix-modules | Could | Todo | - |
| FEAT-002 | Create local AI inference app module for local AI inference | nix-modules | Could | Todo | AUTO-006 |
| OPS-003 | Set up monitoring with Prometheus/Grafana | tappaas-ops | Could | Todo | - |
| OPS-004 | Implement log aggregation (Loki/Grafana) | tappaas-ops | Could | Todo | - |
| OPS-005 | Create backup verification and restore testing | tappaas-ops | Could | Todo | - |

### Won't Have (This Quarter)

| ID | Story | Module | Priority | Status | Reason |
|----|-------|--------|----------|--------|--------|
| FEAT-004 | High-availability cluster setup | tappaas-core | Won't | Blocked | Requires multi-node architecture |
| FEAT-005 | Multi-region deployment support | tappaas-core | Won't | Blocked | Not in current scope |
| SEC-004 | LDAP/Active Directory integration | nix-modules | Won't | Deferred | Q2 2026 priority |

## Story Details

### AUTO-001: Update Template VM 8080

**Description:**  
Replace hardcoded network configuration in template VM 8080 with dynamic VLAN configuration that reads from cloud-init generated files.

**Acceptance Criteria:**
- [ ] Template configuration.nix uses ens18 interface (not eth0)
- [ ] Template reads /etc/tappaas/network.nix for VLAN config
- [ ] Template imports /etc/nixos/app-module.nix if it exists
- [ ] Default values work when cloud-init files don't exist
- [ ] services.cloud-init.network.enable = false
- [ ] networking.networkmanager.enable = false
- [ ] Template tested with manual network.nix file

**Files:**
- `/etc/nixos/configuration.nix` on Template VM 8080

**Related:**
- ADR-001 (VLAN trunk mode)
- RCA-2025-02-03-VLAN-SRV-FIX

---

### AUTO-002: Cloud-Init Network Config Injection

**Description:**  
Implement cloud-init user-data template that writes network.nix and app-module.nix files, then triggers nixos-rebuild.

**Acceptance Criteria:**
- [ ] Cloud-init user-data template created in /var/lib/vz/snippets/
- [ ] Template writes /etc/tappaas/network.nix with VLAN ID and gateway
- [ ] Template writes /etc/nixos/app-module.nix with app-specific config
- [ ] Cloud-init runs nixos-rebuild switch on first boot
- [ ] Template supports variable substitution (VLAN, gateway, app)
- [ ] Error handling for failed nixos-rebuild

**Files:**
- `/var/lib/vz/snippets/tappaas-template.yml` (new)
- `/root/tappaas/generate-cloudinit.sh` (new helper script)

**Related:**
- ADR-002 (cloud-init integration - to be created)

---

### AUTO-003: Update Create-TAPPaaS-VM.sh

**Description:**  
Update VM creation script to use cloud-init templates and remove hardcoded VLAN tag parameter.

**Acceptance Criteria:**
- [ ] Script reads VLAN from zones.json
- [ ] Script generates cloud-init user-data from template
- [ ] Script uses qm cloudinit with cicustom parameter
- [ ] Script does NOT set vlan tag on network device (trunk mode)
- [ ] Script includes app-specific module in cloud-init
- [ ] Script validates VM starts successfully
- [ ] Script waits for cloud-init completion before returning

**Files:**
- `/root/tappaas/Create-TAPPaaS-VM.sh` on Proxmox nodes

**Related:**
- RCA-2025-02-03-VLAN-SRV-FIX (Change 1)

---

### AUTO-004: Fix openwebui.nix Repository

**Description:**  
Update openwebui.nix in repository to fix interface names and cloud-init settings discovered during manual deployment.

**Acceptance Criteria:**
- [ ] All eth0 references changed to ens18
- [ ] services.cloud-init.network.enable = false
- [ ] networking.networkmanager.enable = false
- [ ] Version number updated to 0.9.1
- [ ] File committed to nix-modules/apps/
- [ ] Documentation updated with changes

**Files:**
- `TAPPaaS/nix-modules/apps/openwebui.nix`

**Related:**
- Current deployment learnings from 2026-02-04

---

### AUTO-005: Tap Interface Hook Script

**Description:**  
Create and deploy hook script that automatically configures tap interface VLAN membership when VM starts, removing the need for manual bridge VLAN configuration.

**Acceptance Criteria:**
- [ ] Hook script created: /etc/qemu-server/vm-network-hook.sh
- [ ] Script parses VM config to extract tap interface
- [ ] Script reads VLAN from VM JSON config
- [ ] Script removes default VLAN 1 PVID Egress Untagged
- [ ] Script adds correct VLAN in tagged mode
- [ ] Hook triggers on VM post-start event
- [ ] Script tested with existing VM 999
- [ ] Script deployed to all Proxmox nodes

**Files:**
- `/etc/qemu-server/vm-network-hook.sh` (new)
- `/etc/pve/qemu-server/<vmid>.conf` (hook configuration)

**Related:**
- RCA-2025-02-03-VLAN-SRV-FIX (Change 0)

---

### AUTO-006: End-to-End Testing

**Description:**  
Test complete automated deployment flow from install.sh to running OpenWebUI application.

**Acceptance Criteria:**
- [ ] Fresh template VM 8080 with dynamic config works
- [ ] ./install.sh openwebui completes without errors
- [ ] VM gets correct IP on VLAN 210
- [ ] All services start automatically (PostgreSQL, Redis, OpenWebUI)
- [ ] Web interface accessible after deployment
- [ ] PostgreSQL database initialized with tables
- [ ] Redis connections active
- [ ] Backup timers configured and scheduled
- [ ] No manual intervention required
- [ ] Deployment time: <30 minutes

**Test Cases:**
1. Deploy to clean Proxmox node
2. Deploy second instance (test reusability)
3. Deploy with different VLAN (test flexibility)
4. Verify backup restoration works

**Related:**
- All AUTO stories (dependencies)

---

### SEC-001: Password Authentication

**Description:**  
Replace PostgreSQL trust authentication with proper password-based authentication using scram-sha-256.

**Acceptance Criteria:**
- [ ] Generate secure PostgreSQL password
- [ ] Store password in NixOS secrets
- [ ] Update pg_hba.conf to use scram-sha-256
- [ ] Update OpenWebUI DATABASE_URL with real password
- [ ] Test connection with new credentials
- [ ] Document password rotation procedure
- [ ] Update backup scripts to use authentication

**Files:**
- `/etc/nixos/configuration.nix` (postgresql.authentication)
- `/etc/secrets/openwebui.env` (DATABASE_URL)
- `/etc/secrets/postgres.env` (new)

**Security Impact:**
- High: Prevents unauthorized local access
- Low: Limited to localhost only

---

### SEC-002: Secure Secrets Generation

**Description:**  
Replace all REPLACE_PASSWORD and placeholder values with cryptographically secure generated secrets.

**Acceptance Criteria:**
- [ ] Generate PostgreSQL password (32 chars)
- [ ] Generate OpenWebUI WEBUI_SECRET_KEY (32 chars)
- [ ] Generate Redis password if needed (32 chars)
- [ ] Store secrets securely in /etc/secrets/
- [ ] Update all config files with real secrets
- [ ] Document secret management procedure
- [ ] Create secret rotation guide

**Generation Method:**
```bash
openssl rand -base64 32
```

**Files:**
- `/etc/secrets/openwebui.env`
- `/etc/secrets/postgres.env`
- `/etc/secrets/redis.env`

---

### OPS-001: Deploy Hook Script

**Description:**  
Deploy vm-network-hook.sh to all Proxmox nodes in the cluster and verify operation.

**Acceptance Criteria:**
- [ ] Script deployed to pve (primary node)
- [ ] Script deployed to tappaas2 (secondary node)
- [ ] Script permissions set correctly (755)
- [ ] Script tested on each node with existing VMs
- [ ] Monitoring configured for hook failures
- [ ] Rollback procedure documented

**Deployment Order:**
1. Test on tappaas2 (fewer VMs)
2. Verify with VM 999
3. Deploy to pve
4. Verify with production VMs

---

### OPS-002: VLAN Configuration Audit

**Description:**  
Audit all existing VMs for incorrect VLAN configuration caused by bridge-vids and fix issues.

**Acceptance Criteria:**
- [ ] List all VMs on all Proxmox nodes
- [ ] Check each VM tap interface VLAN membership
- [ ] Identify VMs with excessive VLAN memberships (4093 entries)
- [ ] Document affected VMs
- [ ] Create fix procedure
- [ ] Apply fix to affected VMs
- [ ] Verify networking still works after fix

**Audit Script:**
```bash
# Check all tap interfaces
for tap in $(ip link | grep tap | cut -d: -f2); do
  echo "=== $tap ==="
  bridge vlan show dev $tap | wc -l
done
```

---

### DOC-001: Update ADR-001

**Description:**  
Update ADR-001 (VLAN trunk mode) with final implementation status and lessons learned.

**Acceptance Criteria:**
- [ ] Add implementation status section
- [ ] Document bridge-vids discovery
- [ ] Document cloud-init conflicts
- [ ] Document interface naming (ens18 vs eth0)
- [ ] Add references to hook script
- [ ] Update decision outcome
- [ ] Add metrics from production use

**File:**
- `TAPPaaS/docs/_ADR/ADR-001__Use_Trunk_Mode_for_TAPPaaS_VM_VLAN_Connectivity.md`

---

### DOC-002: Create ADR-002

**Description:**  
Create new ADR documenting cloud-init integration decision and implementation.

**Acceptance Criteria:**
- [ ] Document context (manual deployment pain)
- [ ] Document decision (cloud-init approach)
- [ ] Document alternatives considered
- [ ] Document consequences (pros/cons)
- [ ] Include implementation examples
- [ ] Add testing procedures
- [ ] Reference AUTO-002 story

**File:**
- `TAPPaaS/docs/_ADR/ADR-002__Cloud_Init_Integration_for_VM_Bootstrap.md` (new)

---

### FEAT-001: SSL/TLS Support

**Description:**  
Add SSL/TLS termination for OpenWebUI web interface using Let's Encrypt or self-signed certificates.

**Acceptance Criteria:**
- [ ] Choose certificate approach (Let's Encrypt vs self-signed)
- [ ] Configure nginx/caddy as reverse proxy
- [ ] Obtain/generate SSL certificate
- [ ] Configure HTTP → HTTPS redirect
- [ ] Update firewall for port 443
- [ ] Test certificate renewal
- [ ] Document certificate management

**Options:**
- Option A: nginx reverse proxy with Let's Encrypt
- Option B: Caddy with automatic HTTPS
- Option C: Self-signed for internal use

---

### FEAT-002: Nextcloud App Module

**Description:**  
Create Nextcloud application module following the OpenWebUI pattern as proof of composability.

**Acceptance Criteria:**
- [ ] Create nextcloud.nix in nix-modules/apps/
- [ ] Configure PostgreSQL database for Nextcloud
- [ ] Configure Redis for Nextcloud caching
- [ ] Set up container or native installation
- [ ] Configure storage volumes
- [ ] Document installation procedure
- [ ] Test deployment via automated flow

**File:**
- `TAPPaaS/nix-modules/apps/nextcloud.nix` (new)

---

### OPS-003: Monitoring Setup

**Description:**  
Set up monitoring infrastructure using Prometheus and Grafana for OpenWebUI stack.

**Acceptance Criteria:**
- [ ] Deploy Prometheus server
- [ ] Configure exporters (node, postgres, redis)
- [ ] Deploy Grafana
- [ ] Create OpenWebUI dashboard
- [ ] Configure alerts (disk, memory, service down)
- [ ] Set up notification channels
- [ ] Document dashboard usage

**Metrics to Monitor:**
- Container status and uptime
- PostgreSQL connections and queries
- Redis memory and commands
- System resources (CPU, memory, disk)
- Backup success/failure

## Sprint Planning

### Sprint 1 (Week 1-2)
Focus: Foundation & Critical Fixes

**Stories:**
- AUTO-004 (Fix openwebui.nix)
- AUTO-001 (Template VM update)
- DOC-001 (Update ADR-001)

**Goal:** Working dynamic template

---

### Sprint 2 (Week 3-4)
Focus: Automation

**Stories:**
- AUTO-002 (Cloud-init implementation)
- AUTO-003 (Update script)
- DOC-002 (Create ADR-002)

**Goal:** Automated deployment working

---

### Sprint 3 (Week 5-6)
Focus: Testing & Polish

**Stories:**
- AUTO-005 (Hook script)
- AUTO-006 (End-to-end testing)
- OPS-001 (Deploy hook script)

**Goal:** Production-ready automation

---

### Sprint 4 (Week 7-8)
Focus: Security & Operations

**Stories:**
- SEC-001 (Password auth)
- SEC-002 (Secure secrets)
- OPS-002 (VLAN audit)
- SEC-003 (Security docs)

**Goal:** Security hardened

## Definition of Done

A story is "Done" when:

- [ ] Code written and tested
- [ ] Documentation updated
- [ ] Peer review completed
- [ ] Integration tests pass
- [ ] Deployed to test environment
- [ ] User acceptance criteria met
- [ ] Known issues documented
- [ ] Committed to repository

## Dependencies
```
AUTO-001 (Template) ─┬─> AUTO-002 (Cloud-init) ──> AUTO-003 (Script) ──> AUTO-006 (Testing)
                     │
                     └─> AUTO-004 (Fix nix) ──────────────────────────────┘
                     
AUTO-005 (Hook) ──> OPS-001 (Deploy hook) ──> OPS-002 (Audit)

SEC-001 (Passwords) ──> SEC-002 (Secrets) ──> SEC-003 (Docs)
```

## Story Points Estimate

| Priority | Total Stories | Est. Story Points | Est. Days |
|----------|---------------|-------------------|-----------|
| Must Have | 6 | 34 | 20-25 |
| Should Have | 7 | 28 | 15-20 |
| Could Have | 6 | 42 | 25-30 |
| **Total** | **19** | **104** | **60-75** |

**Team Velocity:** ~15 points/week (1 developer)

**Timeline:** Q1 2026 (10-12 weeks)

---

**Backlog Version:** 1.0  
**Last Review:** 2026-02-04  
**Next Review:** 2026-02-11