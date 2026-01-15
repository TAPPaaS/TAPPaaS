# TAPPaaS CICD setup

## Introduction

Setup runs in these macro steps:

- create a tappaas-cicd VM based on the template 
- update the tappaas-cicd with the git clone and rebuild with right nixos configuration
- configure/install tappaas-cicd tools and pipelines

## create tappaas-cicd

Install cloning config: on the proxmox command prompt, then run the command to create the tappaas-cicd clone

```bash
BRANCH="main"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/30-tappaas-cicd/tappaas-cicd.json >~/tappaas/tappaas-cicd.json
~/tappaas/Create-TAPPaaS-VM.sh tappaas-cicd
```

There should now be a running tappaas-cicd VM. you can ssh into the VM from the proxmox console

```bash
ssh tappaas@tappaas-cicd.mgmt.internal
```

### Creating API Credentials in OPNsense and install them in ~/.opnsense-credentials

1. Log into OPNsense web interface
2. Go to **System > Access > Users**
3. add a user "tappaas", add all priviliges and accces, save
4. Under **API keys**, click **+** to generate a key (in the screen with a line for each user)
5. copy the key
6. Save the key and secret in ~/.opnsense-credentials.txt using you vi or nano

### install the tappaas-cicd programs

on the tappaas-cicd console (via ssh, logged in as tappaas user) do:

```bash
export BRANCH="main"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/30-tappaas-cicd/install.sh | bash
```

You might be asked for password for root at proxmox node tappaas1

## TODO

automate setting up caddy

## Configure Reverse Proxy

we use the OPNsense os-caddy plugin for https proxy

In the opnsense console, use option 8 to get a command line shell and install caddy

```bash
pkg install os-caddy
```

follow the OPNsense manual to configure Caddy: [Caddy Install](https://docs.opnsense.org/manual/how-tos/caddy.html#installation)
Only do the "Prepare OPNsense for Caddy After Installation":

- re configure opnsense gui to 8443
- Create http and https firewall rules for wan and lan to caddy
- then configure email address and enable caddy

note as we create VLANs we need to create firewall rules as well
