# Introducing the TAPPaaS Architecture

The TAPPaaS architecture has its starting point in defining the [Capabilities](./Capabilities.md) that TAPPaaS will deliver.

We then map the capabilities to a [Software Stack](./TheSoftwareStack.md) of open source applications. each application is called a module in TAPPaaS.

THe capabilities and software stack includes platform and infrastructure services. The intent of TAPPaaS is to run the stack on commodity hardware, which is outlined in more details in the [Hardware](./Hardware.md) document.

For some of the selected applications/module we have a dedicated design documents as the implementation is not straight forward, and design decisions needs to be made. for the rest of the open source module the outline the configuration in the README file of the module installation source code under ../src/module.


The complicated designs are:

- The [Network](./NetworkDesign.md) design: This is primarily being delivered via OPNsense and Proxmox as well as the switching infrastructure
- The [Storage](./StorageDesign.md) design: This is delivered via Proxmox, but require a dedicated design discussion
- The [Single Sign On](./SingleSignOnDesign.md) design



