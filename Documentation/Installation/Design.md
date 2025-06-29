# Design your TAPPaaS system

Note this is not about the design of TAPPaaS itself but how to design your instance of TAPPaaS

There are 4 steps involved:

- Identify what problem you expect your TAPPaaS system should do
- Size the installation: how much compute and storage is needed, what will the Network look like
- Define and allocate/procure the Hardware needed
- Capture some essential information needed for standing up TAPPaaS

# Identifying the problem:

look at the examples in [Examples folder](../Examples/README.md)
based on this define the modules you what to include in TAPPaaS.


# Sizing

## Storage and Memory
 
Based on the above assessment on what your TAPPaaS should look like 
fill in the following table, based on the metrics in [TheSoftwareStack](../Architecture/TheSoftwareStack.md) Document
how many nodes and how many tanks you configure is based on either the example you take as the starting point or your own design.
If a Module is deemed critical and your system is designed as having dual nodes then each of these nodes need to allocate space on two nodes

| Capability | Software | Node1-RAM | Node1/tank1 | Node1/tank2 | Node2-RAM | Node2/tank1 | Node2/tank2 |
|------------|----------|-----------|-------------|-------------|-----------|-------------|-------------|
| | | | | | | | |
|------------|----------|-----------|-------------|-------------|-----------|-------------|-------------|
| TOTAL      |          |   Add up  | Add up      | | | | |
|------------|----------|-----------|-------------|-------------|-----------|-------------|-------------|


## Networking

TODO


# Capture essential information for your TAPPaaS

In addition to identifying and sizing the hardware for your TAPPaaS system you need to make a few important decisions before starting the bootstrapping process

1) An internet connection with a wired connection
2) A domain name for your system. if possible this is a domain name that you register with a DNS provider.
3) a good long strong password to be used for the root of the physical servers (proxmox virtual environments) and root of the Firewall (OPNsense)

