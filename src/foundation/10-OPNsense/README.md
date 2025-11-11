# OPNSense Installation

# Introduction

There are two ways of installing OPNSense:

1. Installation of an OPNSense image, with manual configuration of OPNsense WAN and LAN ports from the console
2. Restore a vanilla OPNSense proxmox backup of a minimum install

In both case we need to prepare the proxmox environment 

# Preparation

The TAPPaaS OPNSense firewall will have two interfaces: WAN and LAN, bot interfaces will be virtio bridges in Proxmox.

It is assumed that Proxmox is connected to an existing firewall/router on vmbr0 via an ethernet port on the physical server.
It is further assumed that the IP domain for this connection is NOT a 10.x.y.z domain as it will conflict with the OPNSense setup (if it is it will stil be possible to set up TAPPaaS but will need more elaborate bootstrap process)

As preparation we need to set up another bridge on proxmox: vmbr1: this will connect to a secondary ethernet port on the physical server. This will eventually become the LAN interface

in the Proxmox GUI do:

- go to node: tappass1
- select the Network page under system
- take note of the free ethernet ports, and select the one that will be the new lan port. note down the Name
- click "create"
- in the pop up full in
-- Name: lan
-- IPv4/CIDR: 10.0.0.10/24
-- Gateway, ipv6 and ipv6 gateway: leave blank
-- Autostart is checked and VLAN aware is un checked
-- Bridgeport: the name of the chosen ethernet port
- now click create adn click apply Configuration

now create the OPNSense VM: from the command prompt/console of tappaas1:
```

```

## Install OPNsense software

### Method 1: install from image

### Method 2: Restore backup

TODO

## Test and switch

We are now ready to do basic testing of OPNsense and to switch the primary proxmox bridge as well as primary firewall





## downaload iso and create VM

- do google search for opnsense download. on download site select and download dvd image
- in proxmox gui: select local disk and upload iso (you need to decompress it from bz2 if it is compressed)

- create new VM with 8G RAM and 4-8 cores, and HD of 16G to 32G on tank1. use Name OPNsense and UID 666
- attach the ISO as a dvd
- do PCI passthrough of the LAN and WAN ethernet ports
  - use "PVE_NODE=<ip of proxmox server> ./ethernetPCI.sh" to find and configure the PCI pass through
+ set start on boot to true in the proxmox gui
+ set boot order to 1

# Start VM and configure OPNsense

now Start the VM and in the console install OPNsense on the virtual HD
then detach the CD/DVD device after reboot

attach the WAN port to an internet connection (can be you current lan, if you do not have an extra internet connection)
attach a client machine with a web browser to the LAN port and go to the indicated OPNsense configuration web GUI 

## create updates to OPNSense via GUI

### Create VLANs

- go to Interfaces -> Devices -> VLAN and add vlans
- go to the created VLAN as interfaces and configure static IP according to VLAN specs
- go to Services -> ISC DHCPv4 -> <Vlan> and configure IP range for DHCP

### DNS setup

- Enable services -> dnsmask DNS
  - use port 53053
  - Register DHCP Lease enables
- Enable service -> Unbound DNS -> general
- register dnsmask with unbound DNS for lan.internal domain
  - Service -> Unbound DNS -> Query Forwarding
    - register lan.internal to query 127.0.0.1 port 53053
    - register 10.in-addr.arpa to query 102.0.0.1 port 53053
    - press apply
  - 

## IPv6 setup

- create gateway: System -> Gateways -> Configuration
  - add a gateway, on the WAN port, protocol IPv6 give it the gateway address assigned by the ISP
- Interface -> WAN: 
  - IPv6 COnfiguration Type = Static IP
  - IPv6 address: the assigned IP address of you router by the provider it WAN connectivity
  - select gateway: IPv6 gateway rule: select the created gateway
  - SAve and apply changes
- Each of the LAN/VLAN interfaces
  - IPv6 Configuration type = Static IPv6
  - IPv6 address: The assigned IPv6 range potentially subdivided into sub ranges ending in ::1 and handed out as a 64 bit network range
  - save and apply
- create Router advertisement on each local interface LAN/VLAN: Services -> Router advisement -: (V)LAN
  - Router Advertisements = Managed
  - DNS Options, tick the Use the DNS configuration of the DHCPv6 server

## create firewall rules

general for each interface some firewall rules needs to be configured

- WAN: there should be a default rule to NOT pass any traffic. keep that
- DMZ: allow DMZ to communicate to internet, but not locally
  - block LAN, and other VLANs
  - create a pass rule for the rest
- Remaining LAN/VLANs: add rule to allow/pass any to any traffic
- for Guest/client: add first rule to block/reject traffic to LAN (management)
  - for "true guests" block access to other vlans except DMZ

Note: all rules are for both IPv4 and IPv6

## Switch firewall

This is the scary step: There are two parts to this

- move proxmox tappaas node 1 in under the OPNsense firewall
- disable the existing legacy firewall and hook OPNsense directly to the ISP

### Move proxmox node

First change the IP number of proxmox tappaas1 node

- edit: /etc/network/interfaces
- edit: /etc/hosts
- change the DNS resolver, edit: /etc/resolv.conf

now reboot the proxmox tappaas1 node

while rebooting move the network connection of the proxmox node from your exiting network to the lan network of the OPNsense LAN network (you likely need a separate switch for your new lan, see example documentation)

### Replace firewall

There are 3 scenarios for this step:

- Stay with TAPPaaS as a subsystem of existing ISP provided and configured network 
  - in this case there is nothing further to do
- Reconfigure existing ISP provided firewall to be in bridge mode
  - consult ISP on how to do this. once done check OPNSense have the right connection.
  - Potentially you need to reconfigure IPv6
  - Note that if existing legacy firewall provided WIFI then this now need to be set up for TAPPaaS
- Replace the ISP provided firewall: this assumes the ISP is having an ethernet termination for WAN
  - plug in OPNsense wan port instead of legacy firewall
  - see notes above on Wifi and IPv6

