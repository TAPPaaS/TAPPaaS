```
# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
```

# OpenWebUI on TAPPaaS - Installation Guide

**Version:** 0.9.0  
**Author:** Erik Daniel
**Release Date:** 2026-02-04  
**Status:** Development

## Overview

This guide shows how to install OpenWebUI on TAPPaaS infrastructure with PostgreSQL database, Redis cache, and automated backups.

## Known limitations
Steps 2-4 will be replaced by ./install.sh openwebui - when the trunk issue is resolved!
pfSense router --> OPNsense
192.168 range --> 10. range
configuration.nix not modular --> flake based structure


**Target Setup:**
- VM on Proxmox in (VLAN) zone: SRV
- OpenWebUI v0.7.2 in Podman container
- PostgreSQL 15 database
- Redis 7 for resource management
- Automated daily backups

## Prerequisites

- Proxmox VE host with bridge (vmbr0)
- VLAN 210 configured (srv zone)
- Firewall with DHCP on VLAN 210
- Template VM 8080 with NixOS installed

## Network Requirements

### VLAN Configuration

OpenWebUI runs on VLAN 210 (srv zone) 

### Firewall Rules

Required firewall rules on SRV interface:
```
Action: Pass
Source: SRV subnets
Destination: This Firewall (self)
Port: 53 (DNS)

Action: Pass  
Source: SRV subnets
Destination: Any
Port: Any (Internet access)
```

## Installation Steps

### Step 1: Create VM & Deploy Configuration

use ./install.sh openwebui

**Expected build time:** 10-20 minutes (first time)

**What happens:**
1. Downloads packages (PostgreSQL, Redis, Podman)
2. Pulls OpenWebUI container image (~500MB-1GB)
3. Configures services
4. Starts containers

### Database Connection

PostgreSQL uses trust authentication for localhost (no password required):
```bash
# Connection string in /etc/secrets/openwebui.env
DATABASE_URL=postgresql://openwebui:REPLACE_PASSWORD@127.0.0.1:5432/openwebui
```
**Note:** Password is ignored due to trust auth. This is safe for localhost-only connections.

### Step 2: Verify Installation
[NOTE: ErikDaniel 260205 - this is moved to separate test.sh / backlog ]


Run health check:
```bash
# Check services
systemctl status postgresql redis-openwebui openwebui-wrapper

# Check container (run as root)
sudo podman ps

# Check network
ip addr show ens18.210

# Test web interface
curl http://localhost:8080
```

**Expected results:**
- All services: active (running)
- Container: Up X minutes
- IP: x.x.210.x/24
- HTTP: 200 OK

### Step 3: Access Web Interface

**From browser:**
```
http://openwebui.srv.internal:8080
```

**First login:**
1. Create admin account [NOTE: ErikDaniel - 260205 - this will be integrated into TAPPaaS core: Authentic / baclog]
2. Configure AI backend 
  a) Open WebUI stand-alone with direct connection to AI API providers (optional)
  b) Open WebUI integrated with LiteLLM (TAPPaaS recommended)
3. Test interface

## Configuration


### OpenAI-Compatible Servers (stand-alone)

For stand-alone use of Open WebUI with OpenAI-compatible servers, follow the documentation. 

https://docs.openwebui.com/getting-started/quick-start/starting-with-openai-compatible

Obtain API key (pay on use) from e.g.:
Mistral AI - European AI provider https://mistral.ai/pricing#api
AI gateway - multi-SOTA (state of the art) AI models with single API key: https://openrouter.ai/ 





### LiteLLM Integration (TAPPaaS preferred)
[ ErikDaniel - NOTE: 260205 NOT IMPLEMENTED YET / BACKLOG ]

To connect to LiteLLM backend:

**Manual - Via Web UI:**
```
Settings → Connections → OpenAI API
- API Base URL: http://litellm.srv.internal:4000/v1
- API Key: [your-litellm-virtual-key]
- Save
```

**Automated - Via TAPPaaS Config File:** 
```nix
environment.etc."secrets/openwebui.env".text = ''
  # ... existing config ...
  OPENAI_API_BASE_URL=http://litellm.srv.internal:4000/v1
  OPENAI_API_KEY=sk-your-key-here
'';
```

Then rebuild: `sudo nixos-rebuild switch && sudo systemctl restart openwebui-wrapper`

### Backup Configuration

Automated backups run daily:

| Service | Time | Location | Retention |
|---------|------|----------|-----------|
| PostgreSQL | 02:00 | /var/backup/postgresql/ | 30 days |
| Redis | 02:30 | /var/backup/redis/ | 30 days |
| Container data | 02:45 | /var/backup/openwebui-data/ | 30 days |
| Environment files | 02:50 | /var/backup/openwebui-env/ | 30 days |

Cleanup runs monthly (removes files older than 30 days).

---

**Document Version:** 1.0  
**Last Updated:** 2026-02-04  
**Tested On:** NixOS 25.05, Proxmox VE 9.x