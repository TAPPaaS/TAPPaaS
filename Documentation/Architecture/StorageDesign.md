*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# Storage design for TAPPaaS

The starting point for storage design in TAPPaaS is to ensure that the system can grow and that data is secured against failure and finally that we cate for at least to kinds of data w.r.t. availability and redundancy. In more details we have the design constraints:

- Storage is delivered to the application via Proxmox ZFS data pools
- We create growth flexibility through:
  - adding disks to zfs data pools
  - adding data pools to proxmox systems/node
  - adding more proxmox systems/nodes
- We deliver redundancy to cater for issues/faults through:
  - zfs RAID design
  - snapshot and replication between proxmox systems/nodes
  - Backup between local and remote TAPPaaS systems

TODO describe tank1/2/... design


