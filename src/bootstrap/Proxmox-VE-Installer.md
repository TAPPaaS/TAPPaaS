This is a summary of key Proxmox VE Installer parameters for TAPaaS production node

Target Harddisk
    Select options
        Select filesystem = zfs (RAID1)
            Tab[Disk Setup]
                identify the (enterprise) SSDs for proxmox boot
                deselect all. (for all other harddisks - select "-- do not use--")
                select disk 0 - SSD1
                select disk 1 - SSD2 
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


Analysis of your configuration:
	•	Total disk capacity per SSD: 480.10 GB
	•	ZFS partition size per SSD: 428.42 GB
	•	Unpartitioned space: 480.10 GB - (1.03 MB + 1.07 GB + 428.42 GB) ≈ 49.6 GB
What does this mean?
	•	You are leaving about 49 GB per SSD unused, which is roughly 10% of the total capacity.
	•	This amount of free space is exactly the recommended overprovisioning for a small business environment.
	•	The other partitions (BIOS boot and EFI) are minimal and standard for a modern Proxmox installation with ZFS.
Conclusion:
	•	This layout is correct and optimal:
Your SSDs are well configured for both reliability and longevity, with sufficient overprovisioning according to best practices.
	•	You are utilizing most of the disk space for ZFS, while consciously reserving a significant portion for wear leveling.
In short:
This configuration is perfectly suitable for your Proxmox boot drives in a small business setting.