# Install a multi node local TAPPaaS cluster

Three or more machines you own, a switch between them, separate data disks and backup. The same
install as a single node, with more done on Day 1. Each stage links to its appendix for the
detail.

## 1. Choose the hardware

Pick a size (small, medium, large), the number of machines, and whether you want local AI, local
backup and a public address. → [Appendix B — Hardware selection](HARDWARE.md)

**Done when:** the machines are on the bench, each with a boot disk and data disks.

## 2. Prepare

The network (the first machine needs two ports: one to your router, one to the switch), a
domain if you want to go public, your admin email and root password, the branch and the site's
name. → [Appendix D — Preparation](PREPARATION.md)

**Done when:** every box in Appendix D is ticked.

## 3. Install the first machine

From a Mac or Linux PC beside it (Windows: [Appendix A](WINDOWS.md)):

```bash
curl -fsSL "https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/stable/src/foundation/cluster/bootstrap-tappaas.sh" -o bootstrap-tappaas.sh && chmod +x bootstrap-tappaas.sh
```

```bash
./bootstrap-tappaas.sh
```

Choose **2** (USB stick) or **4** (network boot), answer the questions (size **medium** or
**large**; your domain, or none), and boot the machine. The install runs to the end on its own and
prints the console's address. Compare the release signer it prints with
[the published fingerprints](FOUNDATION.md#compare-the-release-signer).
→ [Appendix E — The foundation install in detail](FOUNDATION.md)

**Done when:** the console opens at the printed address.

## 4. Day 1 in the console

1. **Finish the first node's setup:** the LAN port cabled to the switch, and a data pool on the
   free disks (the firewall and the management VM move onto it, live).
2. **Add more nodes:** one at a time, with the **Add node** wizard: it writes an installer stick
   or opens a network boot, the machine installs and joins the cluster, then its data pool.
   A managed switch needs its trunk ports first (step 6 below).
3. **The admin VPN:** enrol your computer.
4. **Rest of foundation:** sign-in, logging and backup, your organisation and you.
5. **Status and health checks:** including the VLANs across the machines.

**Done when:** the Day 1 page says **you have a working system**.

## 5. Take the backup keys off the site

With a USB stick in the first machine, on the Day 2 page: **Write the backup keys to a USB
stick**. Make two sticks and keep them at
two places, away from the site. Without them, a lost site cannot be restored.

## 6. Day 2

Optional, in any order, from the console's Day 2 page:

- **Switch fabric:** register managed switches; TAPPaaS sets their VLANs, or lists what to set.
- **Make it public:** certificates for your domain (wildcard, or one per service).
  → [Appendix E](FOUNDATION.md#make-it-public)
- **Environments:** separate worlds on one platform (production, family, a client).
  → [Appendix F — Environments](ENVIRONMENTS.md)
- **A satellite:** a public address, off-site backup or admin VPN, for a site without its own.
  → [Appendix C — Adding a satellite](SATELLITE.md)
- **Stacks:** the applications (AI, collaboration, home, security).
- **Wi-Fi and the physical site:** access points, rooms and racks.

## 7. Operate

From here the managers keep the site updated, backed up and checked. See
[Operate](https://tappaas.org/operate/).
