*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# Hardware

## Introduction

Hardware is going to be controversial and constantly it will be outdated. But let us nail down some boundary conditions, that hopefully can be a bit more stable and be the defining frame for actual selections. see [Examples](../Examples/README.md) for concrete examples.

The general design principles is that most of IT4HOME should be delivered as an appliance. think something like a Fritzbox <https://en.avm.de/products/fritzbox/> or the Unify Dream machine <https://store.ui.com/us/en/collections/unifi-dream-machine/products/udm-pro>

However the ambition of delivered functionality is larger so design become more complicated.

Let us first differentiate between what is "in the appliance" vs what needs to be outside:

### Inside the appliance:

- Compute for everything
- Storage: with Raid
- Firewall as a virtualized function: so several ethernet ports
- Possibility to scale storage
- Possibility to deliver redundancy by having 2 or 3 boxes
- Possibility to have a "satellite" for the extended home

### Outside the appliance

- Cameras
- All the home appliances. (strictly speaking not part of the solution itself, but manged by the IT4HOME solution)
- The sprinkler controller
- The weather controller
- THe WAN termination

### The Problematic ones

- L2 switching, including PoE and LAN support
- Wifi access points
- IoT radios (zigbee, .Matter) as with Wifi it might be build in

## Design constrains and discussion

Generally we are after generic hardware, so that it can be replaced even if vendor goes out of business, and be upgraded without depending on a particular vendor

### Appliance

Three options considered: 
- a bunch of Pi's: Fun but not really easy to work with as a single appliance and likely not cost efficient for scaling
- a proper server: Is typically expensive, and power hungry (and noisy)
- a virtual network appliances server: a lot of interesting options exist based on the Intel Atom series. They have server features but low power consumption and price point

Memory: For a good system: use ECC for "satellite" and test non ECC

Disk: SSD in Raid for main server, SSD in non raid for Satellite. Main appliance complemented with spinning disks in Raid for application storage. (ZFS)

At least 4 Ethernet ports (one for server, two for virtual firewall and one for HA sync, alternative for WiFi in Satellite mode). likely 2.5 or 10 G

### Networking

In its simple form we plug WAN into the Appliance server port for firewall uplink
We plug the LAN into the Server port, and we use the secondary LAN into a wifi Access Point (AP).

For larger/normal installation we need a switch. 
- several 2.5 G PoE ports to power WiFi and Cameras
- a few 10G ports to connect Servers
- and some spare ports to route to stuff we want or need to keep off WiFi
- switch must support VLAN switching

We need WiFi APs that support VLANs.

Ideally we want something that is standardized and easy to replace
but we also want something that is easy to manage and automate

Unify is a great solution for switches and wifi with a great set of integrated management capabilities. Unfortunately it is a closed eco system
(This is what I have at the moment)

So let us go low cost instead

### The rest

## Proposals for HW builds

With this we can define three kinds of appliance boxes:

### Standard

complete needs for a "standard home

### Large

extension allowing the home to be more resilient and solution to be more powerful
Ideally the Large model is just adding components form the Standard setup

### Satelite

A minimum solution relevant to a secondary home, or yong family member living in another building, etc
It does not have all functionality and rely on a standard or large installation that it can connect to (via VPN)
