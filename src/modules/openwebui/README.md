# Overview

This will install OPenWebUI as a local chat services.
It require an OpenAI API available either externally or via the TAPPaaS ollama vm

Installation consist of

- getting a VM up and running with Docker
- using docker compose setup
  - openwebui
  - searxng
  - litellm
  - postgresql


bootstrap below is for < 10 concurrent users 

Login to tappaas PVE host.
Select 8000 (tappaas-ubuntu)
Right-click - select clone
  give name, e.g.: tappaas-AI-chat
  mode: full clone
  target storage: tanka1
  select 'clone'


Select VM config of: tappaas-AI-chat
  Tag:
    update: from tappaas to tappaas-ai-chat
  
  Summary:
    update Notes:

      TAPPaaS AI-chat Template
      GitHub Discussions Issues

      This is the template for the generic TAPPaaS AI-chat VM. It is based on Ubuntu Nobel Numbat (24.04 LTS) and includes Docker foundation tools. 

  Hardware:
    update RAM: from 4096 to 8192 (minimum 4096)
    update vCPU: 2 (minimum), 4 preferred
    update Hard Disk (scsi0): from 8GB to 40GB SSD+
  #  update Network Device (net0) 

  update Hard Disk (scsi0):
    Minimum: 20GB
    Recommended: 40GB

    Breakdown per service:
      OpenWebUI: ~2-3GB (base image + data)
      SearXNG: ~500MB
      LiteLLM: ~1GB
      PostgreSQL: ~1-2GB initial
      System + Docker overhead: ~5GB
      Extra space for updates/logs: ~10GB

  update RAM:
    Minimum: 4GB (4096)
    Recommended: 8GB (8192)

    Breakdown:
      OpenWebUI: 1-2GB
      SearXNG: 512MB
      LiteLLM: 512MB-1GB
      PostgreSQL: 1GB
      System + Docker overhead: 1GB

  CPU
    Minimum: 2 cores
    Recommended: 4 cores



start VM
open 'console' to see the progress...

get the IP of the new VM from PVE 'summary'

[ 
  
  connect your visual studio to the tappaas-cicd vm. 
  sync the repository 


  use terminal / test connection with tappaas-ai-chat vm: ssh tappaas@ip-of-tappaas-ai-chat-vm 
  upon successful connection

  'clone' the modules/openwebui to the new VM


  

go to directory: ~/src/modules/openwebui


## **1. Prepare `.env` (Single Source of Truth)**

- Define **only base component values** (ports, DB creds, keys)
- Leave composite vars blank so they are generated:
  ```
  LITELLM_DATABASE_URL=
  DATABASE_URL=
  APP_DATABASES=
  ```

---

## **2. Generate & Persist Dynamic Vars**

Run:

```
source ./load-env.sh
```

This will:
- Load base `.env`
- Generate:
  - `APP_DATABASES`
  - `LITELLM_DATABASE_URL`
  - `DATABASE_URL`
- Export them to shell
- **Persist** them back into `.env`

Example output:
```
[INFO] Environment loaded and persisted
[INFO] APP_DATABASES=litellm|litellm_db|llm_user|...
[INFO] LITELLM_DATABASE_URL=postgresql://llm_user:...
```

---

## **3. Start Clean Stack**

```
docker compose down -v --remove-orphans
docker compose up -d
```

---

## **4. Validate Configuration**

**Check `.env`:**
```
grep -E '^(APP_DATABASES|LITELLM_DATABASE_URL|DATABASE_URL)=' .env
```

**Validate Compose vars:**
```
docker compose config | grep -A3 litellm | grep DATABASE_URL
```

**Test LiteLLM health:**
```
curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     http://localhost:$LITELLM_PORT/health
```
✅ Expect JSON response (no “Missing Environment Variables” page)  

**Optional Logs:**
```
docker compose logs --tail=20 litellm
docker compose logs --tail=20 postgres
```

