# TAPPaaS Module Dependency Graph

This document shows the service dependencies between TAPPaaS foundation and application modules.
Each arrow points from a **consumer** module to the **provider** module it depends on, labeled with the service name.

Generated: 2026-02-22

## Dependency Graph

```mermaid
graph TD
    subgraph Applications
        litellm[litellm]
        openwebui[openwebui]
        vaultwarden[vaultwarden]
        netbird-client[netbird-client]
        unifi[unifi]
    end

    subgraph Foundation
        firewall[firewall]
        tappaas-cicd[tappaas-cicd]
        identity[identity]
        backup[backup]
        template[template]
        cluster[cluster]
    end

    %% firewall depends on cluster
    firewall -->|vm| cluster
    firewall -->|ha| cluster

    %% tappaas-cicd depends on cluster
    tappaas-cicd -->|vm| cluster
    tappaas-cicd -->|ha| cluster

    %% backup depends on cluster
    backup -->|vm| cluster

    %% template depends on cluster
    template -->|vm| cluster

    %% identity depends on cluster, template, backup, firewall
    identity -->|vm| cluster
    identity -->|ha| cluster
    identity -->|nixos| template
    identity -->|vm| backup
    identity -->|proxy| firewall

    %% litellm depends on cluster, template, backup, identity, firewall
    litellm -->|vm| cluster
    litellm -->|ha| cluster
    litellm -->|nixos| template
    litellm -->|vm| backup
    litellm -->|identity| identity
    litellm -->|proxy| firewall

    %% openwebui depends on cluster
    openwebui -->|vm| cluster

    %% vaultwarden depends on cluster, template, backup, identity, firewall
    vaultwarden -->|vm| cluster
    vaultwarden -->|ha| cluster
    vaultwarden -->|nixos| template
    vaultwarden -->|vm| backup
    vaultwarden -->|identity| identity
    vaultwarden -->|proxy| firewall

    %% netbird-client depends on cluster, template, backup, identity, firewall
    netbird-client -->|vm| cluster
    netbird-client -->|ha| cluster
    netbird-client -->|debian| template
    netbird-client -->|vm| backup
    netbird-client -->|identity| identity
    netbird-client -->|proxy| firewall

    %% unifi depends on cluster, template, backup
    unifi -->|vm| cluster
    unifi -->|nixos| template
    unifi -->|vm| backup
```

## Module Summary

| Module | Category | Provides | Depends On |
|--------|----------|----------|------------|
| cluster | Foundation | vm, ha | _(none)_ |
| firewall | Foundation | firewall, proxy | cluster:vm, cluster:ha |
| tappaas-cicd | Foundation | _(none)_ | cluster:vm, cluster:ha |
| identity | Foundation | accessControl, identity | cluster:vm, cluster:ha, template:nixos, backup:vm, firewall:proxy |
| backup | Foundation | vm | cluster:vm |
| template | Foundation | nixos, debian | cluster:vm |
| litellm | Application | models | cluster:vm, cluster:ha, template:nixos, backup:vm, identity:identity, firewall:proxy |
| openwebui | Application | _(none)_ | cluster:vm |
| vaultwarden | Application | _(none)_ | cluster:vm, cluster:ha, template:nixos, backup:vm, identity:identity, firewall:proxy |
| netbird-client | Application | _(none)_ | cluster:vm, cluster:ha, template:debian, backup:vm, identity:identity, firewall:proxy |
| unifi | Application | _(none)_ | cluster:vm, template:nixos, backup:vm |

## Service Provider Summary

| Service | Provider | Consumed By |
|---------|----------|-------------|
| vm | cluster | firewall, tappaas-cicd, identity, backup, template, litellm, openwebui, vaultwarden, netbird-client, unifi |
| ha | cluster | firewall, tappaas-cicd, identity, litellm, vaultwarden, netbird-client |
| nixos | template | identity, litellm, vaultwarden, unifi |
| debian | template | netbird-client |
| vm | backup | identity, litellm, vaultwarden, netbird-client, unifi |
| proxy | firewall | identity, litellm, vaultwarden, netbird-client |
| identity | identity | litellm, vaultwarden, netbird-client |
| models | litellm | _(no consumers yet)_ |
| firewall | firewall | _(no consumers yet)_ |
| accessControl | identity | _(no consumers yet)_ |
