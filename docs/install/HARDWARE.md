# Appendix B — Hardware selection

Choosing TAPPaaS hardware is two decisions:

1. **The size**: how big the site is, how many machines, how much redundancy.
2. **Three options**: **local AI**, **local backup** and a **local public address**, each a
   yes or no, and each with an alternative when the answer is no.

## 1. Pick a size

The size you give the install (`small`, `medium` or `large`) sets the cores, memory and disk of
every module, so it follows from the hardware you choose here.

| Size | For whom | Machines | Per machine | Redundancy |
|------|----------|----------|-------------|------------|
| **small** | Trying TAPPaaS, a lab, a household | 1 (or up to 3 small ones) | 4+ cores, 32 GB, one 0.5 TB SSD/NVMe | none |
| **medium** | A household that relies on it, a small business or NGO, up to about 50 users | 3 | 8+ cores, 32–64 GB (ECC), a small boot disk + two data disks | HA, ZFS mirrors, backup on another machine |
| **large** | 100+ users, many environments | 3 or more, some with a role (compute, GPU, storage) | as medium, more memory | HA and role separation |

**Disks and pools.** The boot disk holds Proxmox and, on a single disk machine, everything else.
On a machine with data disks, TAPPaaS builds pools on them from the console:

| Pool | Holds |
|------|-------|
| `tanka1` | the VMs and their important data, mirrored |
| `tankb1` | bulk data that can be lost or rebuilt |
| `tankc1` | backup, on a different machine from what it backs up |

In a three machine cluster a common shape is: machine 1 the foundation, machine 2 the
applications (with the GPU if you run local AI), machine 3 the backup machine with a big
`tankc1`. For large bulk storage, consider raidz2 on spinning disks with an SSD cache. Prefer ECC
memory from medium up.

**Network.** One port is enough for a single machine. In a cluster, the first machine needs two
(one to your router, one to the switch) and the others one each; 2.5 Gbit or faster between the
machines is recommended. An unmanaged switch passes the site's VLANs as they are; a managed one
must have its ports set as trunks, which TAPPaaS does for supported switches.

**In Hetzner.** The machines are rented dedicated servers (Robot or Server Auction) with the same
per machine sizes; Hetzner's cloud servers cannot run TAPPaaS. See [Appendix G](HETZNER.md).

## 2. The three options

| Option | Yes: local | No: the alternative |
|--------|------------|---------------------|
| **Local AI** | A GPU, or an APU with unified memory (sizing below); models run on the site | No AI, or the AI stack in front of a remote model (convenient, less sovereign) |
| **Local backup** | `tankc1` on another machine of the site | A **satellite** or a **backup buddy** (another TAPPaaS site) holds the copy |
| **Local public address** | The firewall's WAN has a public address; services are published on it | A **satellite** gives the site a public address over a tunnel the site dials out |

### The satellite

A satellite is a small server with a stable public address that you rent, typically a low cost EU
cloud server. It is optional: a site with a public address and local backup needs none. One
satellite can carry any of:

- **reverse-proxy**: public HTTPS for a site behind CGNAT or a dynamic address, passed through
  to the site's own reverse proxy (the certificates stay at home);
- **admin-vpn**: your admin VPN reaches the site through it;
- **backup**: an off-site copy of the site's backups, which the site cannot delete.

It is added from the console's Day 2 page: [Appendix C](SATELLITE.md).

### Worked example

*A household, with local AI, without local backup, without a public address:* one 64 GB machine
with a unified memory APU, a mirrored `tanka1`, size small or medium, plus one satellite carrying
reverse-proxy, admin-vpn and backup.

## 3. Sizing local AI

Local AI is sized by the memory the accelerator has and the model size and quantisation you want,
not by GPU brand. Two paths, both served by the AI stack (vLLM, LiteLLM, OpenWebUI):

- **Unified memory APU**, the TAPPaaS reference: an AMD Ryzen AI MAX+ 395 ("Strix Halo") with
  128 GB unified memory. The GPU shares system memory, which lets one inexpensive machine run very
  large models. No FP8 on this chip (use AWQ or GPTQ); its ROCm support is still maturing.
- **Discrete GPU**: a card with its own memory, sized by the table.

| AI ambition | Example models (as tested) | Accelerator memory | Path |
|-------------|----------------------------|--------------------|------|
| **Entry** | 7–8B FP16 (Qwen2.5-7B ≈ 50 tok/s); ~14B AWQ | 12–16 GB | entry GPU, or any APU |
| **General** | up to ~30B 4-bit (Qwen3-30B GPTQ ≈ 20 tok/s, ~24 GB) | 24–32 GB | 24 GB GPU, or a 32 GB+ APU |
| **Large** | 70B–120B AWQ (gpt-oss-120B tested) | 64–128 GB unified | a 128 GB APU |

4-bit quantisation uses about a quarter of the memory of FP16 and is the practical choice above
about 14B; leave room for the context on top of the weights. A unified memory APU gives the most
model per euro; a discrete GPU is faster at a given model size. The figures are as tested on the
[`vllm-amd` module](https://codeberg.org/TAPPaaS/TAPPaaS/src/branch/main/src/ai/vllm-amd/README.md).

## 4. What the platform itself needs

Memory per module, at each size (what the VM is given; Proxmox reserves it whether used or not):

| Module | small | medium | large | Disk (small / medium / large) |
|--------|-------|--------|-------|-------------------------------|
| Proxmox itself (with the ZFS cache) | 2–4 GB | 4 GB | 4 GB+ | 32 GB |
| Firewall (`network`) | 2 GB | 4 GB | 8 GB | 32 GB |
| Management VM (`tappaas-cicd`) | 4 GB | 8 GB | 8 GB | 32 / 64 / 256 GB |
| Sign-in (`identity`) | 2 GB | 4 GB | 8 GB | 32 / 32 / 64 GB |
| Logging | 2 GB | 4 GB | 8 GB | 16 / 32 / 256 GB |
| Backup server | 2 GB | 2 GB | 2 GB | the `tankc1` pool |

That is about 16 GB for the foundation at small, 26 GB at medium and 38 GB at large. At small,
the foundation plus the home and office stacks fit on one 32 GB machine.

An update refuses to run when a machine would commit more than 95% of its memory with every VM at
its size (`health-manager capacity` shows the numbers), so a machine that cannot hold its VMs is
named before it runs out of memory. A single module can be given more or less by hand
(`module-manager module modify <module> --set memory=<MiB>`); the whole site moves with
`site-manager site modify --size <size>`.

Application stacks, at medium:

| Stack | Memory | Disk | GPU |
|-------|--------|------|-----|
| AI (OpenWebUI, LiteLLM) | 4–8 GB | 50 GB | optional |
| AI (vLLM) | 8–32 GB | 100+ GB | see above |
| Collaboration (Nextcloud, EURO Office, Talk) | about 22 GB | 80 GB + files | — |
| Home (Home Assistant, deCONZ) | 8 GB | 32 GB | — |

Next: [Appendix D — Preparation](PREPARATION.md).
