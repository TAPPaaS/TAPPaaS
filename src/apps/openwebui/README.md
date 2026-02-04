# Overview

TAPPaaS 
Name: Open WebUI 
Type: Application Module: Open WebUI 
Role: local AI chat service.

Embedded products:
  - openwebui
  - litellm
  - postgresql

Depdends on:
  - litellm 

For installation of the module see [INSTALL.md](./INSTALL.md)


VM Sizing: 
  ~10 concurrent users 

  Hardware:
    vCPU: 4 (2 minimum)

    RAM: 4096 (recommended 8192)
      OpenWebUI: 1-2GB
      (SearXNG: 512MB)
      LiteLLM: 512MB-1GB
      PostgreSQL: 1GB
      System: 1GB

    STORAGE (scsi0): 32GB SSD (minimum 20GB)
      OpenWebUI: ~2-3GB (base image + data)
      LiteLLM: ~1GB
      PostgreSQL: ~1-2GB initial
      System: ~5GB
      Space for updates/logs: ~10GB