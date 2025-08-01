# Pangolin installation

## pre requstic:

create a domain name in a public DNS registra. 
register the DNS entries mydeomain.tld and sub entry pangolin.mydomain.tld to point to your public IP

create firewall NAT rules to pass through TCP port, 80, 443 and UDP port 51820 to pangolin static ip which will be 10.1.0.2

- First disable automatic reflection options in firewall settings advanced
- create an alias for pangolin to 10.1.0.2
- for the firewall NAT rules we use reflection NAT and hairpin NAT so for each port we need two rules one Port forward and one Outbound NAT rule
  - see [OpnSense NAT Reflection](https://docs.opnsense.org/manual/how-tos/nat_reflection.html)
  - use method 1


## create VM

run the command from tappaas-cicd VM 

```
cd TAPPaaS/src/modules/DMZ/pangolin
export PVE_NODE=<ip of tappas1 node>
./CreatePangolinVM.sh
```

## download and run Pangolin

from tappaas1 console do an ssh to tappaas@10.1.0.2 and do the following commands 

```
wget -O installer "https://github.com/fosrl/pangolin/releases/download/1.7.3/installer_linux_$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" && chmod +x ./installer
sudo ./installer
```

TODO: make command work from tappas-cicd and in clude in Create Pangolin VM shell script

###

TODO: create a pangolin local name in DNS (and do that for tappas1 and other nodes as well)