## Installing Proxmox Backup server on single node system  

# Introduction

This recipe should only be followed if you plan to have a single node TAPPaaS system
if you plan to have a high available 3 node system then follow the recipe in [version b](../70b-MultiNodeHAandBackup/README.md) 

In a single node system we set up a Proxmox Backup Server in a VM on the single node

We use a dedicated disk for backups that is passed through to the VM

We register the backup server in Pangolin so that it can work with external backup systems for remote copies

