# TAPPaaS Proxmox Backup Server


This module install PBS from official apt repository onto an existing TAPPaaS node.
the pbs.json define which node, and define the actual apt package to install

Consider editing the json before installing

To install simply run the install.sh from the tappaas-cicd vm

after running the script you need to configure the PBS installation by logging into the PBS gui

1) attach the tankc1 for backups
2) create a pbs backup of the backup through a "friendly TAPPaaS" service 
3) configure retention policies

TODO: code or document these steps in more details
TODO remember encryption

