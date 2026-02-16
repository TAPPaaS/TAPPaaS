# Dependency management in TAPPAasS

## Introduction

Fundamentally TAPPaaS is a collection of modules that offer capabilities. And for a module to function it also consumes capabilities.

For example a photo module rely on a proxy capability to be provided by a firewall in order for the photo application to be accessible from the internet. It also rely on an identity and access capability to provide the service in a secure manner. It rely on virtualization capability to provide compute nad storage.

When ever a module is designed it is important to understand its dependencies and formally register it so that when it is installed the TAPPaaS system can check if all needed capabilities are present

Further this dependency tracking allow the TAPPaaS installer to ensure the modules that it depends upon is configured to deliver the needed capability

## High level design

Each module in TAPPaaS is defined in a <module>.json. This file has two fields:

- dependsOn: a list of capabilities
  - a capability is a <module>:<capability> pair so it is clear which module deliver the capability
- provides: a list of capabilities (in this case no need to specify the module as it is the name of the json)

Each module has a set of scrips for each capabilities it delivers, registered in a subdirectory of the module:

- cap/<name of capability>/install.sh: a script which is called when a module consuming the capability is installed. It is called with a single argument: the name of the module that will be consuming the capability
- cap/<name of capability>/update.sh: a script which is called when a module consuming the capability is being updated. It is called with a single argument: the name of the module that will be consuming the capability

If the "consume.sh" needs more information about the module that will be consuming the service, then it can read the <module>.json. The module-fields.json define the fields that can be relevant for a given capability.
    - the fields definition will have a new field:
        - capabilities: list of <module>:<capability> pairs that will consume this field. 

### Example

The identity module will have a dependency list of:
TODO: find json form
  dependsOn: {PVE:VM,PVE:HA,backup:vm,firewall:proxy}
and will provide a service:
  provides: {accessControl, identity}

## Details

### Scripts

#### Install and Update

it will validate the json agains the needed capabilities
  - see if the needed fields is there
  - see if the modules are installed
install.sh for a module will iterate through the dependsOn list and call the coresponding capability scripts

#### Update

The update script that update a full installation will compute the dependency graph and update the lowest level first (modules without any dependencies)

## Task