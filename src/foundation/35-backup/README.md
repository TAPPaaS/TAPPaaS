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

Register the backup server as a permanent dns record in opnsense:
- in Opnsense go to Services -> Dnsmasq DNS & DHCP -> Hosts
    - add a host (plus sign)
    - hostname: backup
    - domain: mgmt.internal
    - IP address: the ip of the host. if it is tappaas3 then 10.0.0.12
    - click apply

After running the script you need to configure the PBS installation by logging into the PBS gui using root and the password you have for the tappaas node. note you must select "Linux PAM standard authentication"

1) Add a datastore to the backup server. assuming the configured datastore for backup is tankc1 then create the datastore:
    - name: tappaas_backup 
    - Backup PAth: /tankc1/tappaas_backup
2) Create a backup user tappaas (under configuration -> Access controll, User Management tab)
3) go to "permission" tab and add User  Permission
    - path /datastore/tappaas_backup
    - user: tappaas@pam
    - role: Admin
4) on the tappaas1 node, configure the backup system for use in the datacenter": Under Storage do an "add"
    - select "proxmox Backup Server"
        - ID: tappaas_backup
        - Server: backup.mgmt.internal
        - username: tappaas@pbs
        - password: your tappaas password
        - datastore: tappaas_backup
        - Fingerprint: cut and paste the fingerprint you get from PBS GUIDashboard "Show Fingerprint"
    - click "Add"
5) Add a backup job: Datacenter -> Backup: "Add"
    - Storage: tappaas_backup
    - Schedule: 21:00
    - selection: all
    - click OK
4) create a pbs backup of the backup through a "friendly TAPPaaS" service 
5) configure retention policies

# TODO
add Encryption
more details on backup of backup
more details on retention
automate creation of backup based on jsons
