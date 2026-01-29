# Instruction for accessing the TAPPaaS installation remotely 

# Introduction

To access TAPPAaS remotely for management we use Netbird

To develop on the TAPPAaS git code we remotely connect via ssh to the tappaas-cicd over Netbird

You can configure say visual studio to work remotely on this ssh channel

## Netbird Setup

Step 1: create a netbird account
Step 2: enable netbird for each tappaas node. This establish a peer group for access to TAPPaaS
Step 3: configure a TAPPaaS netbird overlay network

The setup is a variation of this setup [Netbird Home to Network Access](https://docs.netbird.io/manage/networks/homelab/access-home-network)

also install Netbird on your machine you will be using to access the TAPPaaS installation:
- go to netbird.io
- select install menu
- follow the install instructions

### Step 1: create a netbird account

TODO: when a tested netbird controll plane module is availalbe in TAPPaaS then change the recipie to use this

On the netbird.io register for an account. For this a free account is enough. Register so that the admin of TAPPaaS have access

As this is giving access to managemetn of TAPPaaS then setting up 2FA is highly recommended

in the control plane of the netbird: go to: Setup Keys. Select Create setup Key.
- Give it a Name: TAPpaaS-Keys (or the name of your tappaas instance)
- Make key reusable: yes
- click create keys
- copy the key to a safe place.

Now create a TAPPaaS management user group (this is not intuitive in the user interface!)
- Click Teams , and users
- Select the tappaas managemetn user
- under group click +1 and click edit
- click selection box and in the "search groups" write: TAPPAaaS-mgmt (this creates a new group)
- click Save Groups


### Step 2: enable netbird for each tappaas node. This establish a peer group for access to TAPPaaS

for each tappass node you need to do the command
```bash
netbird up --setup-key <paste the key you just created>
```

In the netbird control plane you can now go to: Peers and see all you nodes (in Netbird a peer is a machine conencted to Netbird)

### Step 3: configure a TAPPaaS netbird overlay network

Go to "Networks" and "Add Network"
- Name: TAPPaaSLan
- click Add Network
- click add resource
- Name: TAPPaaS Mgmt
- Address: 10.0.0.0/24
- click Add Resource
- click Add Routing peers
- add each of the tappaas nodes
- click save
- Add policy that TAPPAas-mgmt users as source can access the peers in the network

Test that from a terminal on the management PC you can ping 10.0.0.10

Optional step:

Follow this guide to setup mgmt.internal for 10.0.0.0/24

[Netbird DNS Aliases](https://docs.netbird.io/manage/dns/dns-aliases-for-routed-networks)

Test that from a terminal on the management PC you can ping tappaas1.mgmt.internal

## SSH setup for tappaas-cicd access

## Visual studio remote access setup


