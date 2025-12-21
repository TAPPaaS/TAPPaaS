# TAPPaaS Proxmox Backup Server


This module install PBS from official iso
the pbs.json define the size of the machine, and where it runs. consider editing the json before installing

To install simply run the install.sh from the tappaas-cicd vm

after running the script you need to configure the PBS installation from the console, followed by logging into the PBS gui

Steps after installing the PBS

1) attach the tankc1 for backups
2) create a pbs backup of the backup through a "friendly TAPPaaS" service 
3) configure retension policies

TODO: code or document these steps in more details

