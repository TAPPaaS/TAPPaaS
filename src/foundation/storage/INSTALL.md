# storage — Installation

Primary audience: TAPPaaS admin.

`storage` is a virtual module: nothing is installed on any machine. It is
registered by the tappaas-cicd install (`copy-update-json.sh storage`); on a Site
installed before it existed, register it once from the mothership:

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/foundation/storage
install-module.sh storage
```

`storage-manager` arrives with the control plane (`refresh-control-plane.sh`
builds every manager).

## Prerequisites

- The cluster nodes registered as `pvehost` instances (ADR-026) — they are the
  servers.
- A pool to serve from on the chosen node; a `tankb` pool (no HA replication) is
  the usual home for re-creatable data such as media.

## First share

```bash
storage-manager nfs share add <name> --server <node> --pool <pool> --quota <size> --backup true|false
storage-manager nfs grant <name> <consumer> ro|rw
storage-manager nfs show
```

The consumer then mounts `share: "<name>"` under `config."storage:nfs".mounts` and
lists `storage:nfs` (after `network:rules`) in `dependsOn`. See
[services/nfs](services/nfs/README.md).

## Verify

```bash
./test.sh                     # unit suite, validation, aliases
./test.sh --deep              # end to end on a node (~25 min, leaves nothing behind)
```
