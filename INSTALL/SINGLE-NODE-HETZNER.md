# Install a single node TAPPaaS system in Hetzner

*In development, not ready.* One rented Hetzner dedicated server with one public address, with
no USB stick and no local network beside it. Hetzner's cloud servers cannot run TAPPaaS: they
do not let a server run virtual machines of its own.

How it will work:

- The install script runs on your computer and reaches the server through Hetzner's rescue
  system: it installs Proxmox from there, with the server's own address.
- During the install the firewall reaches the internet through the server; at the end the
  firewall takes the server's public address, and nothing but the firewall answers on it.
- Your computer gets its WireGuard key from the install script, and the install enrols it in the
  site's admin VPN: the console and the server are reached through it, from anywhere.
- Day 1 is the same as for a single machine at home: the machine alone, the boot pool only, no
  switches or Wi-Fi.

Until it is ready, use a [single node at home](SINGLE-NODE-LOCAL.md).
