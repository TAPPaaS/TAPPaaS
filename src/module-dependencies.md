# TAPPaaS Module Dependency Model

Computed from every module's `<module>.json` (`dependsOn: "provider:service"`).
Three views: the platform plumbing every module uses, the application topology
worth drawing, and the complete per-module reference.

_Generated: 2026-10-06 by generate-module-dependencies.sh from 26 modules / 104 dependencies — do not edit by hand._

## 1. Platform plumbing

These foundation services are consumed near-universally; drawing them would
bury the interesting structure. A module uses them unless its entry in the
reference below says otherwise.

| Service | Consumers (of 26 modules) |
|---------|----------|
| `cluster:vm` | 18 |
| `backup:vm` | 17 |
| `network:proxy` | 16 |
| `templates:nixos` | 13 |
| `network:rules` | 12 |
| `identity:identity` | 6 |
| `cluster:ha` | 6 |

## 2. Application topology

Everything that is *not* plumbing — the dependencies that shape the platform.
Multiple services between the same pair are merged into one labeled edge;
providers marked `(external)` have no module in this repo yet.

```mermaid
graph TD
    coturn -->|"fileservice"| nextcloud
    coturn -->|"nat"| network
    euro-office -->|"fileservice"| nextcloud
    hass -->|"audio, airplay"| sonos
    hass -->|"rtsp"| reolink
    hass -->|"ui, discovery, modbus"| alfen
    jellyfin -->|"nfs"| storage
    netbird-client -->|"debian"| templates
    nextcloud-hpb -->|"fileservice"| nextcloud
    nextcloud-hpb -->|"turn"| coturn
    openwebui -->|"models"| litellm
    vllm-amd -->|"lxc"| cluster
    windows-server -->|"windows"| templates
    alfen["alfen (external)"]:::ext
    classDef ext stroke-dasharray: 5 5
    reolink["reolink (external)"]:::ext
    sonos["sonos (external)"]:::ext
```

## 3. Complete reference

Every dependency of every module, verbatim from the json contracts.

| Module | Depends on |
|--------|------------|
| **backup** | — |
| **cluster** | — |
| **coturn** | `backup:vm` `cluster:vm` `network:nat` `network:rules` `nextcloud:fileservice` `templates:nixos`  |
| **debianhost** | — |
| **deconz** | `cluster:vm` `templates:nixos` `backup:vm` `network:proxy` `network:rules`  |
| **euro-office** | `cluster:vm` `templates:nixos` `backup:vm` `network:proxy` `network:rules` `nextcloud:fileservice`  |
| **forgejo** | `cluster:vm` `templates:nixos` `backup:vm` `network:proxy` `network:rules`  |
| **hass** | `cluster:vm` `backup:vm` `network:proxy` `network:rules` `alfen:ui` `alfen:discovery` `alfen:modbus` `sonos:audio` `sonos:airplay` `reolink:rtsp`  |
| **identity** | `cluster:vm` `cluster:ha` `templates:nixos` `backup:vm` `network:proxy`  |
| **immich** | `cluster:vm` `cluster:ha` `templates:nixos` `backup:vm` `network:proxy` `network:rules` `identity:identity`  |
| **jellyfin** | `cluster:vm` `backup:vm` `network:proxy` `network:rules` `storage:nfs` `templates:nixos`  |
| **litellm** | `cluster:vm` `templates:nixos` `backup:vm` `network:proxy` `network:rules` `identity:identity`  |
| **logging** | `cluster:vm` `templates:nixos` `backup:vm` `network:proxy` `identity:identity`  |
| **netbird-client** | `cluster:vm` `cluster:ha` `templates:debian` `backup:vm` `identity:identity` `network:proxy`  |
| **network** | `cluster:vm` `cluster:ha` `network:proxy`  |
| **nextcloud** | `cluster:vm` `templates:nixos` `backup:vm` `network:proxy` `network:rules` `identity:identity`  |
| **nextcloud-hpb** | `backup:vm` `cluster:vm` `coturn:turn` `network:proxy` `network:rules` `nextcloud:fileservice` `templates:nixos`  |
| **openwebui** | `cluster:vm` `templates:nixos` `backup:vm` `network:proxy` `litellm:models` `network:rules` `identity:identity`  |
| **pvehost** | — |
| **satellite** | — |
| **storage** | — |
| **tappaas-cicd** | `cluster:vm` `cluster:ha`  |
| **templates** | — |
| **vaultwarden** | `cluster:vm` `cluster:ha` `templates:nixos` `backup:vm` `network:proxy` `network:rules`  |
| **vllm-amd** | `cluster:lxc` `backup:vm`  |
| **windows-server** | `cluster:vm` `templates:windows` `backup:vm` `network:proxy`  |
