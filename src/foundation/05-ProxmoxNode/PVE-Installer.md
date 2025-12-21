This is a summary of key Proxmox VE Installer parameters for TAPPaaS production node

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


Recommended ZFS Parameters for Proxmox Boot on SSDs
Parameter	Recommended Value	Explanation
ashift	12	Sets block size to 4K (2^12). Ideal for SSDs which use 4K internally.
compression	lz4	Fast compression with minimal CPU overhead. Saves space and improves performance.
atime	off	Disables access time updates on reads. Reduces unnecessary writes.
relatime	on (optional)	If you need access time updates but want to reduce write load.
xattr	sa	Stores extended attributes in inodes (faster and more efficient).
dedup	off	Deduplication is memory-intensive and not recommended for boot pools.
sync	standard	Default is safest. Only change if you know what you're doing.
copies	1	No need for extra copies on mirrored SSDs.
zfs_arc_max	~50% of RAM	Limit ARC size to avoid starving Proxmox and VMs of memory. Set in /etc/modprobe.d/zfs.conf.

