This is a summary of key Proxmox VE Installer parameters for TAPaaS production node

Target Harddisk
    Select options
        Select filesystem = zfs (RAID1)
            Tab[Disk Setup]
                identify the (enterprise) SSDs for proxmox boot
                for all other harddisks - select "-- do not use--"
                this should result in 2 identical SSDs 
            Tab [Advanced Options]
                ashift = 12
                compress = zstd
                checksum = on
                copies = 1
                ARC max size = (10% of RAM) e.g. 6422 (with 64GB)
                hdsize = 90% of number (overprovision to extend SSD lifespan) e.g. 400GB (with 447 shown = 480GB SSD
            Select OK
        Select Next
            Select Country (e.g. Netherlands)
            Select Time zone (e.g. Europe/Amsterdam)
            Select Keyboard Layout (e.g. U.S. English)
        Select Next
            Create Password and Confirm Password
            Create Email
        Select Next
            Create Hostname (FQDN) - this must be unique e.g. PVE-01.xx.yy
            Confirm IP address (server VLAN segment / fixed IP)
            Confirm Gateway (server VLAN x.x.VLANID.254 or .x.x.1)
            confirm DNS Server
        Select Next
            confirm setting..
        Select Next