# TAPPaaS Proxmox Backup Server (PBS) 

This module install PBS from official apt repository onto an existing TAPPaaS node.
the pbs.json define which node, and define the actual apt package to install

Consider editing the json before installing

## Install

To install simply run the install.sh from the tappaas-cicd vm

```bash
cd
cd TAPPaaS/src/foundation/35-backup
chmod +x install.sh
./install.sh
```

after running the script you need to configure the PBS installation by logging into the PBS gui

1) attach the tankc1 for backups
2) create a backup user tappaas, and give it rights to do backup (admin privileges)
3) on the tappaas1 node, configure the backup system for use in the datacenter" by adding a PBS node to storage
4) create a pbs backup of the backup through a "friendly TAPPaaS" service 
5) configure retention policies



TODO: code or document these steps in more details
TODO remember encryption

