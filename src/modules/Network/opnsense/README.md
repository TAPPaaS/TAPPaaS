This directory contain automation and instructions for installing the OPNsense software

TODO: recode to be automated directly using opentufu and ansible.

The steps are:

1) Validate and configure proxmox and underpinning hardware for pci passthrough
2) download Iso and create VM
3) start VM and configure OPNsense
4) perform updates to OPNsense via GUI
5) SWitch out firewall

## PCI passthrough

Run ./validate.sh

## downaload iso and create VM

- do google search for opnsense download. on download site select and download dvd image
- in proxmox gui: select local disk and upload iso (you need to decompress it from bz2 if it is compressed)

- create new VM with 8G RAM and 4-8 cores, and HD of 16G to 32G on tank1. use Name OPNsense and UID 666
- attach the ISO as a dvd
- do PCI passthrough of the LAN and WAN ethernet ports
  - use "PVE_NODE=<ip of proxmox server> ./ethernetPCI.sh" to find and configure the PCI pass through

# Start VM and configure OPNsense

now Start the VM and in the console install opnsense on the virtual HD
then detach the CD/DVD device after reboot

attach the WAN port to an internet connection (can be you currentl lan, if you do not have an extra internet connection)
attach a client machine with a web browser to the LAN port and go to the indicated opnsense configuration web GUI 

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
- register dnsmask with unbound DNS for lan.intenral domain
  - Service -> Unbound DNS -> Query Forwarding
    - register lan.intenral to query 127.0.0.1 port 53053
    - register 10.in-addr.arpa to query 102.0.0.1 port 53053
    - press apply
  - 

## IPv6 setup

- create gateway: System -> Gateways -> Configuration
  - add a gateway, on the WAN port, protocol IPv6 give it the gateway adress assigned by the ISP
- Interface -> WAN: 
  - IPv6 COnfiguration Type = Static IP
  - IPv6 address: the assigned IP adress of you router by the provider it WAN connectivity
  - select gateway: IPv6 gateway rule: select the created gateway
  - SAve and apply changes
- Each of the LAN/VLAN interafces
  - IPv6 Configuration type = Static IPv6
  - IPv6 adress: The assigned IPv6 range potentially subdivided into sub ranges ending in ::1 and handed out as a 64 bit netwok range
  - save and apply
- create Router advertisment on each local interface LAN/VLAN: Services -> Routeradtisments -: (V)LAN
  - Router Advertisments = Managed
  - DNS Options, tich the USe the DNS configuration of the DHCPv6 server


## Switch firewall



