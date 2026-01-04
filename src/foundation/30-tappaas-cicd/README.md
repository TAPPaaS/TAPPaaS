# TAPPaaS CICD setup

## Introduction

Setup runs in these macro steps:

- create a tappaas-cicd VM based on the template 
- update the tappaas-cicd with the git clone and rebuild with right nixos configuration
- configure/install tappaas-cicd tools and pipelines


## create tappaas-cicd

Install cloning config: on the proxmox command prompt, then run the command to create the tappaas-cicd clone
```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/30-tappaas-cicd/tappaas-cicd.json >~/tappaas/tappaas-cicd.json
~/tappaas/Create-TAPPaaS-VM.sh tappaas-cicd
```

There should now be a running tappaas-cicd VM. you can ssh into the VM from the proxmox console
```
ssh tappaas@tappaas-cicd.tappaas.internal
```

on the tappaas-cicd console (via ssh, logged in as tappaas user) do:
```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/30-tappaas-cicd/install.sh | bash
```
You might be asked for password for root at proxmox node tappaas1
