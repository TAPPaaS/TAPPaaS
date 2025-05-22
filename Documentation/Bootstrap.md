# These are the steps to get a minimal TAPaaS system up and running.

## Prerequsite

1. An internet connection and a wired acces point for the TAPaaS server
2. A fully qualified name (FQN) of the first proxmox server
  - preferably the domain name of the FQN should be owned by you like "mydomain.org" 
  - preferably you have DNS set up for the domain and you have a public IPv4 adress for setup
    (note this is not a hard requirement)
  - note the name of the proxmox server is going to stick with you for a long time. it is dificult to change later
    - clasical names are "node1.mydomain.org" or "server1.mydomain.org" 
2. a good long strong password to be used for the root of proxmox and root of the Firewall


### Hardware: 

- Allocate a single PC with a minimum specificaition of:
  - Intel/ADM architecture
  - 8G ram
  - 3 network ports
  - 3 physical disks
It is practical to have a small screen and keyboard connected to the server, but it will only be used in the initial step of installing the base proxmox os. Alternative is to have a KVM or ILO/remote management connection

See Example.md for proposals

### assumptions


## Proxmox install:

- download a Proxmox PVE image from: 
- create a boot USB (on windows use rufus)
- boot the machine into the USB and do an install: use ZFS for the boot disk.
- once it is rebooted go to management console and add the two other HD's as tank1 and tank2
(if sufficinet hw resources are avaialble then use mirror on boot and tank1)
- run the TAPaaSPostPVEInstall.sh script in the proxmox node
```
GITTOKEN=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
curl -fsSL -H "Authorization: token $GITTOKEN" https://raw.githubusercontent.com/larsrossen/TAPaaS/refs/heads/main/src/bootstrap/TAPaaSPostPVEInstall.sh | bash
```
(note the -H token stuff is only needed as long as the script is in a private repository, the togen gives read access)

- after reboot check that it all looks fine!!
- run the TAPaaSBootstrap script from the root console
```
GITTOKEN=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
curl -fsSL -H "Authorization:token $GITTOKEN https>//raw/githubusercontent.com/larsrossen/TAPaaS/refs/heads/main/src/bootstrap/TAPaaSBootstrap.sh | bash
```
You should now have a PVE node with a TAPaaS template and a TAPaaS CICD VM

## TAPaaS CICD bootstrap

Setting up the CICD toolchain and git repository. This is done in the TAPaaS-CICD VM

The only way to access the VM is through ssh from the proxmox node console.

You need the IP of the VM: look it up in the summary of the TAPaaS CICD VM in the proxmox gui

Now Do:

- Log into TAPaaS CICD VM using ssh from a host teminal: ssh tapaas@<insert ip of CICD VM>
- In the shell of the TAPaaS CICD VM do:
  - create ssh keys: ssh-keygen -t ed25519
  - add ssh keys to your github: copy and paste the output of cat ~/.ssh/id_ed25519.pub (not needed when TAPaas is public)
  - clone the tapaas repository: git clone git@github.com:larsrossen/TAPaaS.git
  - run the final bootstrap code: ./TAPaaS/src/bootstrap/TAPaaS-CICD-bootstrap.sh
  - set the git user name: git config --global user.name <your name> 
  - set the git user email: git config --global user.email <your email>

## Intermediate step:

Set up a coding environment connected to the CICD

- Install Visual code on your personal developer machine (MacOS, Linux, Windows)
- Install the Visual Code Remote Development extension pack (search in VC and install in VC)
- ensure you ahve ssh installed on your development machine and you have keys generated
- upload keys to the tapas@tapas-cicd VM users, authorized keys.
- test that you can ssh into tapaas@tapaas-cicd from the development machine
you can now connect to the CICD VM using the connection buttom in the lower left corner of VC

Next you need to set up tokens for Opentofu (terraform)
- in proxmox menu: Datacenter->Permision->API tokens: add a token with id: tapaas-token associated with root@pam
- copy the token and write it into a file : cat >.ssh/tapaas-token
- make the file read/write for owner only: chmod 600 .ssh/tapaas-token


## Firewall and network setup

## Define your TAPaaS

## Run the updater