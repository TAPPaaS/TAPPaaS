# Install a multi node TAPPaaS cluster in Hetzner

*In development, not ready.* Several rented dedicated servers joined into one cluster. The
first server's public address becomes the firewall's internet side. The servers reach each
other over Hetzner's private network between them (the vSwitch). That network carries a single
VLAN, so the site's own networks (management, services, clients and so on) will run tunnelled
inside it rather than as VLANs on a switch you own. Until it is ready, use a [local cluster](CLUSTER-LOCAL.md).
