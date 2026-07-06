"""node-provisioner — PXE provisioning service for follow-on TAPPaaS nodes.

Implements Phase N3 of docs/design/node-provisioning.md (#404 item 2): a
controller on tappaas-cicd that netboots the Proxmox VE automated installer
for registered pending nodes.

Verbs (see cli.py):
  register / unregister / list — the pending-node allowlist
  prepare  — stage netboot assets from a PVE ISO
  serve    — HTTP asset + answer server (foreground)
  enable   — transient systemd units + DHCP PXE options (TTL-limited)
  disable  — tear everything down
  status   — units / registrations / DHCP state

Security model (design §4): OFF by default, TTL-limited, mgmt-VLAN-bound
(by deployment placement — see README), registrations are the allowlist,
answers are one-shot.
"""

__version__ = "0.1.0"
