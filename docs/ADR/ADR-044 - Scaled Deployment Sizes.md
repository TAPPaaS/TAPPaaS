# ADR-044 — Scaled Deployment Sizes

| | |
|---|---|
| **Status** | **Proposed** — built on `feat/917-sizing`, not yet live-tested |
| **Version** | 0.4 |
| **Date** | 2026-11-05 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #917. Amends ADR-007c (environments gain `size`), ADR-020 (three policy fields on `cluster:vm` and `cluster:lxc`) and the #207 3-way merge (the release side is sized before it is compared). |
| **Changelog** | v0.1 (2026-11-05): first draft, from the operator's direction of 2026-11-05. v0.2 (2026-11-05): the operator's review. tappaas-cicd tops out at medium (4 cores, 8 GiB). network's medium memory drops to 4 GiB. Immich comes down at every size, with its ML cap a share of the VM. The console lists and edits both sizes (D7), and `make-install-media.sh` asks for the size (D8). v0.3 (2026-11-05): measured on hrossen (D6a). Logging goes up to 2/4/8 GiB, Immich comes down to 3/4/8 GiB, and the minimums for coturn, nomad and litellm move above what those guests use. v0.4 (2026-11-05): the operator's direction. A large site's disk starts at medium and grows as it fills (D2). tappaas-cicd has 4 cores at every size. |

A site, and each environment in it, says how big it is: `small`, `medium` or `large`. A module
states its VM or container size once for `medium` and, optionally, a minimum and a maximum. The
install picks the value that matches the size of the place the module goes into. Foundation plus
the home and office stacks then fit one 32 GB node at `small`.

## Context

- **One size today.** `cores`, `memory` and `diskSize` in a module's `cluster:vm` /
  `cluster:lxc` block are what `Create-TAPPaaS-VM.sh` and `Create-TAPPaaS-LXC.sh` create. The
  values are tuned for a mid-sized site. A test box and a hundred-user site get the same guest.
- **It does not fit small hardware.** Foundation (network, tappaas-cicd, identity, logging)
  declares 22 GB of guest memory. The six home modules declare 25 GB, and the four collaboration
  modules 22 GB, about 70 GB in all. The install capacity gate (`health-manager capacity
  --install`, 95 % of node memory) refuses the second stack on a 32 GB node, and nothing an
  operator can set at site level changes that.
- **It undersizes big sites.** A large site grows each guest by hand (`module modify --set
  memory=…`). That pins the field: later release changes to it are no longer adopted.
- **What already exists.**
  - The 3-way merge (`apply-json-merge.sh`) adopts a release value when the deployed value
    equals `.orig`, and pins it otherwise.
  - Update converges `cores` and `memory` in place, and grows disks without ever shrinking them.
  - Memory growth that does not fit a node is held (#891).
  - `diskSizeMax` caps automatic disk growth. It is a different thing from the install-time
    sizing here.

## Decision

### D1. `size` on the site and on each environment

- `site.json` gets `size`: `small` | `medium` | `large`, default `medium`.
- `environments/<name>.json` gets `size`, with no default of its own. Absent, the environment is
  the site's size.

| Size | Meant for |
|---|---|
| `small` | A few users. One node, or up to three small ones. A test or lab system. |
| `medium` | The default. Up to about 50 concurrent users, many modules in one or two environments. |
| `large` | 100+ users. Three or more large nodes, possibly many environments. |

A size is a sizing hint, not a limit: nothing refuses an install because of it. How to set it:

- at site creation: `install.sh --size`, or `create-site.sh --size`;
- on a running site: `site-manager site modify --size`;
- per environment: `environment-manager add --size` / `modify --size`;
- in the console's site and environment forms, which are schema-driven.

### D2. Min/max pairs beside the medium value

`cluster:vm` and `cluster:lxc` gain three optional fields, each a pair `[min, max]`:

| Field | Sizes | Example |
|---|---|---|
| `coresMinMax` | `cores` | `[1, 4]` |
| `memoryMinMax` | `memory` (MiB) | `[1024, 8192]` |
| `diskMinMax` | `diskSize` | `["16G", "128G"]` |

- The plain `cores` / `memory` / `diskSize` stay the **medium** value, so existing modules,
  docs and tooling read as before.
- **The disk does not take its max at large** (v0.4). A large site's disk starts at the medium
  value and auto-grow takes it further as it fills, so nothing is reserved that may never be
  used. `diskMinMax`'s max is the largest the module expects to need. It is not a growth limit:
  that is `diskSizeMax` when set, and otherwise the pool's room.
- **Cores are a ceiling, not a reservation.** Proxmox does not hold a VM's cores for it, so a
  module whose work comes when the others are idle keeps its cores at every size.
  tappaas-cicd builds and sweeps while the apps are quiet, so it has 4 at every size.
- A field without a pair is the same at every size.
- The pair is validated as `min ≤ medium ≤ max` (medium being the plain value, or the schema
  default when the module does not state one).
- A disk minimum is never below the image the VM is cloned from (16 GB for the NixOS template),
  because Proxmox cannot shrink a disk.

### D3. Which size applies

The size of the place a module goes into:

- A **site-scoped** module (the foundation stack) takes `site.json` `size`.
- An **environment-scoped** module takes its environment's `size`, else the site's.
- With nothing set anywhere, the size is `medium`.

`TAPPAAS_SIZE` in the environment overrides the lookup. It exists for tests and for a one-off
install, and is not recorded.

### D4. Install resolves the size; an operator's value wins

`copy-update-json.sh` (the one path every installed config is written through) applies the
size right after it copies the release JSON:

- `small` sets each sized field to its min;
- `medium` leaves the plain value;
- `large` sets cores and memory to their max, and leaves the disk at medium.

Explicit `--cores`, `--memory` and `--diskSize` (or `--set`) are applied after that, so they
win. The pairs stay in the deployed config, so a later update can size again.

The `.orig` baseline is the **sized** release, not the raw one. Otherwise every sized value
would look like an operator edit and be pinned forever.

### D5. Update sizes the release again

`apply-json-merge.sh` sizes the new release source with the instance's current size before the
3-way compare, and advances `.orig` to that sized source. The existing rules then apply
unchanged:

- An unpinned field follows a release change at the instance's size.
- A field the operator set stays pinned.
- **Changing a size takes effect on the next update** for every unpinned field. `cores` and
  `memory` move in place, in both directions. Memory growth that does not fit is held, as
  today (#891). A disk grows to the new size, and a smaller size never shrinks it (grow-only, as
  today).

A site that never sets a size is `medium` everywhere, so its sized source is the release
source and nothing changes for it.

### D6. Values for this repository's modules

Medium is today's value, except the three in bold (v0.2). The minimums are set so that foundation
plus home plus office fits **about 25 GiB of guest memory** at `small`, leaving a 32 GB node about 6 GB for Proxmox, the ZFS
ARC (10 % of RAM by the installer's default) and the gate's 5 % margin.

| Module | cores (min / med / max) | memory MiB (min / med / max) | disk (min / med / max; large starts at med) |
|---|---|---|---|
| network | 2 / 4 / 8 | 2048 / **4096** / 8192 | — |
| tappaas-cicd | **4 / 4 / 4** | 3072 / 8192 / 8192 | 32G / 64G / 128G |
| identity | 2 / 2 / 4 | 2048 / 4096 / 8192 | 16G / 32G / 64G |
| logging | 1 / 2 / 4 | 2048 / **4096** / 8192 | 16G / 32G / 128G |
| deconz | 1 / 2 / 2 | 1024 / 4096 / 4096 | — |
| hass | 2 / 2 / 4 | 2048 / 4096 / 8192 | 16G / 32G / 64G |
| immich | 2 / **2** / 4 | 3072 / **4096** / 8192 | 64G / **250G** / 1000G |
| jellyfin | 2 / 4 / 8 | 1536 / 2048 / 8192 | 16G / 32G / 64G |
| karakeep | 1 / 2 / 4 | 1536 / 3072 / 6144 | 16G / 64G / 128G |
| nomad | 1 / 2 / 4 | 1536 / 4096 / 8192 | 32G / 128G / 512G |
| nextcloud | 2 / 4 / 8 | 2048 / 8192 / 16384 | 32G / 80G / 500G |
| euro-office | 2 / 4 / 8 | 2048 / 8192 / 16384 | — |
| coturn | 1 / 2 / 4 | 768 / 2048 / 4096 | — |
| nextcloud-hpb | 2 / 4 / 8 | 1024 / 4096 / 8192 | — |
| litellm | 2 / 4 / 8 | 4096 / 8192 / 16384 | 16G / 32G / 64G |
| openwebui | 1 / 2 / 4 | 2048 / 4096 / 8192 | 16G / 32G / 64G |
| forgejo | 1 / 2 / 4 | 1024 / 4096 / 8192 | — |
| woodpecker | 2 / 4 / 8 | 2048 / 4096 / 8192 | 32G / 64G / 256G |
| vaultwarden | 1 / 1 / 2 | 1024 / 1536 / 3072 | — |
| netbird-client | 1 / 1 / 2 | 512 / 1024 / 2048 | — |
| lazysite | 1 / 1 / 2 | 512 / 1024 / 2048 | 16G / 16G / 64G |
| windows-server | 2 / 4 / 8 | 4096 / 4096 / 16384 | 64G / 64G / 256G |

- Not sized: `vllm-amd` (its size is the GPU and model it is built for) and the templates
  (a template's disk is the floor every clone starts from).
- `network`'s disk stays at its image size, and `euro-office`, `coturn` and `nextcloud-hpb`
  keep theirs.
- Small budget, guest memory: foundation 9 GiB, home 10.5 GiB, office 5.75 GiB, together
  25.25 GiB. `test-module-sizing.sh` asserts at most 26 GiB.
- **tappaas-cicd** does not grow past medium. Its load is the site's builds and sweeps, not the
  number of users.
- **network** at 4 GiB medium. OPNsense with Caddy, Unbound and the rule set stays well inside
  that; a large site gets 8 GiB.
- **Immich** comes down at every size. Machine learning, always on, is capped at a share of the
  VM (MemoryHigh 50 %, MemoryMax 60 %), not at a fixed 4/5 GiB, so the cap follows the size. The
  models unload after five idle minutes, so the share bounds an import's peak. Postgres takes
  768 MB of shared buffers at every size. The disk is thin, so a smaller default size costs
  nothing that auto-grow cannot give back.
- A changed medium value reaches an existing medium site at its next update, like any release
  change: network and Immich shrink in memory, unless the operator set it. Immich's 500G disk
  stays, because disks only grow.
- The small minimums are a first estimate. Each one is to be confirmed by a live install at
  `small`, and lowered or raised from what the guests use under load.

### D7. The console lists and edits both sizes

- The Site page's card shows the site's size, "medium (the default)" when none is set. The
  card's Modify form changes it.
- Each environment's card, and its panel, show its size, or "medium (the site's)" when it has
  none of its own.
- The add and modify forms offer small, medium and large, with "the site's size" as the default.
- Both forms come from the schemas and the managers' `--size` flags, as every other field does.

### D8. The install media asks for the size

- `make-install-media.sh --size small|medium|large` passes it on to `install.sh --size`.
- Without the option, when the script starts the install, it asks, with medium as the default.
- Unattended (no terminal), medium.

### D9. Where it is documented

- Install overview, Install Foundation (`--size`, the table, "choose small on one 32 GB
  machine"), the single-machine install and Configure Environments.
- The schemas README ("Sizes"), the module-manager README ("How big a guest is"), the
  site-manager and environment-manager READMEs (`--size`).
- The module template (how an author states the pairs), and the generated `cluster:vm` /
  `cluster:lxc` field references.

### D6a. What hrossen showed (2026-11-05)

Read inside each guest about 9 hours after the night's update rebooted them all: memory used
(total minus MemAvailable), swap, memory pressure (PSI), OOM kills, and each service's anonymous
memory. The host's own figure counts page cache and says nothing about need. The 14-day Loki
report (`guest-memory-report.sh`) could not run: Loki timed out.

- **Logging is the one guest short of memory.** It runs in 2 GiB, with memory pressure at 33 %
  over five minutes and swap 65 % used. Since boot Loki peaked at 1.5 GiB, and its range queries
  time out. Medium goes to 4 GiB, and small cannot be below 2 GiB.
- **Immich** uses 0.8 GiB with machine learning idle: the server 574 MiB, ML 110 MiB with no
  model loaded, Postgres under 150 MiB. hrossen's library has 999 items and ran no ML since boot.
  The peak is therefore estimated from the default models (CLIP ViT-B-32 and buffalo_l, about
  1.5 GiB loaded): about 2.7 GiB in all during an import. So small is 3 GiB with ML capped at
  1.5 GiB, medium 4 GiB, and large 8 GiB for several people importing at once. To measure on a
  site with a real library before this is accepted.
- **No pressure, no OOM kill** anywhere else. Used memory against the small minimum:

| Guest | Used | Small min |
|---|---|---|
| identity | 1.4 GiB | 2 GiB |
| tappaas-cicd | 0.9 GiB | 3 GiB (builds) |
| network | 1.2 GiB (FreeBSD: active plus wired) | 2 GiB |
| nextcloud | 0.8 GiB | 2 GiB |
| euro-office | 1.3 GiB | 2 GiB |
| coturn | 0.33 GiB | 0.75 GiB (was 0.5) |
| nextcloud-hpb | 0.45 GiB | 1 GiB |
| jellyfin | 0.47 GiB, no transcode | 1.5 GiB |
| karakeep | 0.82 GiB, some swap | 1.5 GiB |
| nomad | 1.2 GiB | 1.5 GiB (was 1) |
| deconz | 0.5 GiB | 1 GiB |
| litellm | 3.6 GiB | 4 GiB (was 2) |
| openwebui | 1.1 GiB | 2 GiB |
| forgejo, woodpecker | 0.4, 0.5 GiB | 1, 2 GiB |
| vaultwarden, lazysite | 0.3, 0.33 GiB | 1, 0.5 GiB |

- Nine hours is not a week. Before Accepted, the 14-day report runs once logging has its 4 GiB.

## Consequences

- A one-node home or small-office site installs foundation, home and office at `small` without
  a hand-edit per module.
- A large site gets bigger guests from the first install, and they still follow release
  changes, because sizing is not a pin.
- Changing `size` on a running site resizes at the next update, which can restart guests for
  memory. Disks only grow.
- Module authors state two more numbers per field when a module scales. A module that does not
  scale states nothing.

## Alternatives considered

- **A size per stack or per module instead of per environment.** Rejected: the operator thinks
  in "this is a small office" or "this is a test environment", not per app. A per-install
  override already exists (`--memory` / `--set`).
- **A percentage scale (small = 50 % of medium).** Rejected: services do not scale linearly.
  coturn needs almost nothing at any size, and Immich's ML needs about 4 GB even at one user.
  Only the module's author knows its floor.
- **Memory ballooning to overcommit a small node.** Not instead of this: the capacity gate
  counts declared memory, so a small site still needs smaller declarations. Ballooning can come
  later on top.
- **Resolving the size at create time only (`Create-TAPPaaS-VM.sh`).** Rejected: the deployed
  config would then say `medium` while the guest is `small`. Drift detection, the capacity gate
  and the console all read the config.

## Implementation

- **Schema:**
  - `site-fields.json` and `environment-fields.json` get `size`.
  - `cluster/fields.json` gets the three pairs; `services/{vm,lxc}/fields.json` gives them
    change classes (`in-place`, `reconcile`: a policy read at install and update).
- **Library:** `tappaas-cicd/lib/module-sizing.sh` provides two functions:
  - `module_size_for <config-json>` (D3);
  - `apply_module_size <size>` (a jq filter, flat or Pattern A, D4).
- **Install:** `copy-update-json.sh` sizes the copy and the `.orig`.
- **Update:** `apply-json-merge.sh` sizes the source before the compare and advances `.orig`
  with it.
- **Site and environment:** `create-site.sh` / `install.sh` / `site-manager` /
  `environment-manager` take `--size`; the console's forms list it.
- **Module JSONs:** the D6 values.
- **Tests:** `scripts/test/test-module-sizing.sh` checks:
  - every pair is ordered and the disk floor holds;
  - each size resolves as D2 to D4 say, the merge as D5 says;
  - foundation + home + office at `small` stays at or under 26 GiB.
- **Console:** `Site.tsx` and `Environments.tsx` show the size. The forms take `size` from the
  schemas and the `setfields.ts` shortcut tables.
- **Install media:** `make-install-media.sh --size`, asked when not given.
- **Live test (open):** a fresh `--size small` install on a 32 GB node with foundation, home
  and office, run under load. Then a size change from small to medium and an update.
