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


[ connect your visual studio to the tappaas-cicd vm. 
  ]