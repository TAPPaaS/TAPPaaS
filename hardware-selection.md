
# Hardware Selection

Choosing TAPPaaS hardware is a **two-axis decision**:

1. **Axis A — size tier**: how big is the platform (who is it for, how much redundancy)?
2. **Axis B — capability options**: three independent yes/no choices — **local AI**,
   **local backup**, **local public IP** — each with a well-defined alternative if you
   answer "no".

This replaces guessing at one monolithic spec: the axes are genuinely orthogonal.
An SMB may skip local AI; a home may have no public IP; an evaluator may want neither
backup nor ingress.

---

## Axis A — pick a size tier

| Tier | For whom | Topology | Per-node baseline | Redundancy |
|------|----------|----------|-------------------|------------|
| **Evaluation** | Trying/testing TAPPaaS, dev, labs | 1 node (min spec; nested virt OK) | 4 cores / 16 GB RAM / 256 GB boot + 500 GB `tanka1` | none — disposable |
| **Home** | Technically-capable household | 1 strong node | 8+ cores / 32 GB RAM / 512 GB SSD boot + 2×2 TB mirror `tanka1` | disk mirror; single box |
| **SMB** | Business / NGO, uptime matters | 3-node HA cluster | ~8 cores / 32 GB **ECC** each | HA + ZFS mirror; 3-2-1 backup |
| **Scale-out** | Many users/tenants, growth | 3 → N nodes, dedicated roles | as SMB, plus role nodes (compute / GPU / storage) | HA + role separation |

**Storage roles** (used throughout the install): `tanka1` = VMs and critical data,
`tankb1` = bulk/non-critical data, `tankc1` = backup target.

- In a 3-node **SMB** cluster the classic shape is: Node 1 = foundation, Node 2 = AI/HA
  (holds the GPU if you choose local AI), Node 3 = backup node (small box, big `tankc1`).
- **Scale-out** extends SMB by adding role-dedicated nodes and separating tenants with
  **environments** — see the worked multi-tenant example in
  [Add an Environment](INSTALL-ENVIRONMENT.md).
- For large bulk storage, consider ZFS raidz2 on spinning disks with an SSD cache;
  prefer ECC RAM from SMB tier upward.

---

## Axis B — toggle the capability options

Each option is an independent yes/no, layered on any tier. The recurring theme: **the
satellite is the escape hatch** when a capability can't or shouldn't live locally.

| Option | "With" (local) | "Without" → alternative |
|--------|----------------|--------------------------|
| **Local AI** | Add a **GPU or unified-memory APU** (sizing below); vLLM runs models locally — full sovereignty | Omit the GPU; either no AI, or LiteLLM/OpenWebUI fronting a **remote** model (convenient, less sovereign) |
| **Local backup** | Size `tankc1` / add a backup node (PBS on-site) | **Satellite `backup` role** — off-site PBS pull, client-side encrypted, immutable (S3 Object-Lock), or a buddy's PBS |
| **Local public IP** | Direct WAN ingress: Caddy on OPNsense on a routable IP | **Satellite `reverse-proxy` role** — public ingress via a small VPS when behind CGNAT / dynamic IP / no-inbound |

### The satellite — the gap filler

A **satellite** is a small operator-owned node with a stable public IP — typically a
low-cost EU VPS. It is **optional and non-invasive** (a site with a public IP and local
backup needs none) and can carry any combination of three roles:

- **`reverse-proxy`** — the answer to *no local public IP*: blind L4 TLS-passthrough to
  your local Caddy over WireGuard (your site dials out, so CGNAT is fine; TLS keys stay
  home).
- **`backup`** — the answer to *no local backup*: an off-site PBS your local PBS is
  pulled into.
- **`admin-vpn`** — public admin reach into the management plane without a public IP.

One satellite can carry all three.

!!! warning "Status: in development on the 2.0 branch"
    The satellite module and its manager exist on the 2.0 branch but are **early-stage
    (ADR-010 phase 1 scaffolding — not yet functional)**. Plan for it; don't depend on
    it today. Track readiness via the synced [Satellite README](src/foundation/satellite/README.md)
    and [Satellite INSTALL](src/foundation/satellite/INSTALL.md); design background:
    [ADR-010](https://codeberg.org/TAPPaaS/TAPPaaS/src/branch/main/docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md).

---

## The decision flow — four steps

1. **Pick a size tier** — Evaluation / Home / SMB / Scale-out (Axis A table).
2. **Local AI?** If yes, add a GPU or unified-memory APU to the node hosting the AI
   stack (a dedicated AI node at SMB/Scale-out) — size it with the table below.
3. **Local backup?** If yes, size `tankc1` / a backup node. If no, plan a satellite
   `backup` role.
4. **Local public IP?** If yes, standard WAN ingress. If no (CGNAT / dynamic /
   no-inbound), plan a satellite `reverse-proxy` (+ `admin-vpn`).

!!! example "Worked example"
    *Home tier, with local AI, without local backup, without public IP* →
    one 32 GB node with a unified-memory APU and mirrored `tanka1`, plus **one
    satellite** carrying `backup` + `reverse-proxy` + `admin-vpn`.

---

## Sizing local AI — GPU / VRAM guidance

Local AI is sized by the **memory available to the accelerator** and the
**model size × quantization** you want — not by GPU brand. Two hardware paths, both
served by the AI stack (vLLM serving → LiteLLM gateway → OpenWebUI):

- **Unified-memory APU** *(the TAPPaaS reference)* — an AMD Ryzen AI MAX+ 395
  ("Strix Halo") with **128 GB unified LPDDR5x**: the iGPU shares system memory, so
  "VRAM" is a large slice of RAM — which is what lets one inexpensive box reach very
  large models. Caveats: no FP8 on gfx1151 (use AWQ/GPTQ quantization); ROCm support
  for this silicon is still maturing.
- **Discrete GPU** — a dedicated card with its own VRAM (NVIDIA/AMD); size by the table.

| AI ambition | Example models (as tested) | Accelerator memory | Fits which path |
|-------------|----------------------------|--------------------|-----------------|
| **Entry** | 7–8B FP16 (Qwen2.5-7B ≈ 50 tok/s); ~14B AWQ | **12–16 GB** | Entry discrete GPU, or any APU |
| **Solid / general** | up to ~30B 4-bit (Qwen3-30B GPTQ ≈ 20 tok/s, ~24 GB) | **24–32 GB** | 24 GB-class GPU, or 32 GB+ APU |
| **Large** | 70B–120B AWQ (gpt-oss-120B tested) | **64–128 GB unified** | Strix-Halo-class 128 GB APU |

Rules of thumb: **4-bit quantization (AWQ/GPTQ) roughly quarters** memory use vs FP16
and is the practical choice above ~14B; leave headroom for KV-cache/context on top of
the weights. Where a big model matters more than raw speed, the unified-memory APU
gives the most capability per euro; where latency matters most, a discrete GPU wins at
a given model size.

!!! info "Where these numbers come from"
    Model and throughput figures are as tested on the reference
    [`vllm-amd` module](https://codeberg.org/TAPPaaS/TAPPaaS/src/branch/main/src/apps/vllm-amd/README.md)
    (verified against its README 2026-07-10). They will move to an automated WS0 sync
    so they stay current.

---

## Reference: what the platform itself needs

Budget for the foundation services on top of your workloads:

| Service | RAM | Storage |
|---------|-----|---------|
| Proxmox host | 2 GB | 32 GB |
| OPNsense firewall | 2 GB | 16 GB |
| TAPPaaS CICD | 4 GB | 50 GB |
| NixOS template | 1 GB | 10 GB |
| Identity | 4 GB | 20 GB |
| Backup server | 2 GB | sized by `tankc1` |

| Stack | RAM | Storage | GPU |
|-------|-----|---------|-----|
| AI (OpenWebUI) | 4–8 GB | 50 GB | optional |
| AI (vLLM) | 8–32 GB | 100+ GB | see AI sizing above |
| Productivity (n8n) | 2–4 GB | 20 GB | — |
| Home (Home Assistant) | 2 GB | 32 GB | — |

Network: 2×1 Gbps minimum; 1 Gbps + 2.5 Gbps recommended for production.

---

## Next steps

Hardware chosen? Continue with the install:

1. [Preparation](preparation.md) — network plan, DNS, credentials.
2. [Install Foundation](src/foundation/INSTALL.md) — first node, firewall, CICD.
