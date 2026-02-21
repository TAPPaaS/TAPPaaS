# Dependency management in TAPPAasS

## Introduction

Fundamentally TAPPaaS is a collection of modules that offer services. And for a module to function it also consumes services.

For example a photo module rely on a proxy service to be provided by a firewall in order for the photo application to be accessible from the internet. It also rely on an identity and access service to provide the service in a secure manner. It rely on virtualization service to provide compute nad storage.

When ever a module is designed it is important to understand its dependencies and formally register it so that when it is installed the TAPPaaS system can check if all needed services are present

Further this dependency tracking allow the TAPPaaS installer to ensure the modules that it depends upon is configured to deliver the needed service

## High level design

Each module in TAPPaaS is defined in a <module>.json. This file has two fields:

- dependsOn: a list of services
  - a Service is a <module>:<service> pair so it is clear which module deliver the cservice
- provides: a list of services (in this case no need to specify the module as it is the name of the json)

Each module has a set of scrips for each services it delivers, registered in a subdirectory of the module:

- cap/<name of service>/install.sh: a script which is called when a module consuming the service is installed. It is called with a single argument: the name of the module that will be consuming the service
- cap/<name of service>/update.sh: a script which is called when a module consuming the service is being updated. It is called with a single argument: the name of the module that will be consuming the service

If the "consume.sh" needs more information about the module that will be consuming the service, then it can read the <module>.json. The module-fields.json define the fields that can be relevant for a given service.
    - the fields definition will have a new field:
        - services: list of <module>:<service> pairs that will consume this field. 

### Example

The identity module will have a dependency list of:
  dependsOn: [ {cluster:vm},{cluster:ha},{backup:vm},{firewall:prox}]
and will provide a service:
  provides: {accessControl, identity}

## Details

### Scripts

a module provideing service will have a "services" directory with a subdirectory per service
for each service there is an install.sh and an update.sh script, that takes one argument: the name of a module that depends on the service, and the script will install/update the configuration needed for the module to depend on it

in the above example identity module will have directories and files (in the root of the module directory structure):

- services/accessControl/install-service.sh: a script that will configure the identity module to service accessControl to the calling module (the argument must be the name of a module with a <module>.json file in /home/tappaas/config)
- service/accessControll/update-service.sh: a script that will ensure the configuration of the dependency is kept up to date. 
- services/identity/install-service.sh: a script that configure identity management module to serve identitities for a named module
- services.identity/update-service.sh

#### Module Install

There are two general script in tappaas-cicd/scripts: install-module.sh and update-module.sh

installs-module.sh will validate the json agains the needed services
- it will:
  - . /home/tappaas/bin/copy-update-json.sh
  - . /home/tappaas/bin/common-install-routines.sh
  - check_json /home/tappaas/config/$1.json || exit 1  - copy-update-json.sh
- The check_json will expand to
  - see if the needed fields are there
  - see if the modules are installed and provide the service
  - valdate that the module itself have install.sh and update.sh scripts for the service it provides
install-module.sh for a module will iterate through the dependsOn list and call the coresponding service scripts, in the order they appear in the dependsOn array. then if there is an install.sh in the root of the module then that will be called

#### Module Update


#### System Update

This needs to be reconsidered to ensure updates are done in right order: 
- The update script that update a full installation will compute the dependency graph and update the lowest level first (modules without any dependencies)
- tappaas-cicd first, Firewall second
- probably needs to update all modules regardless of nodes it runs on. 
NOTE: do not change this yet

## Task

1) update module-fields.json with the dependsOn and provide fields
2) create new foundation modules based on the existing ones (do not delete existing ones). do not copy README.md files
  a. cluster: based on 05-ProxmoxNode
    - copy Create-TAPPaaS-VM.sh
    - install.sh will be copied and modified to point to .../cluster/Create-TAPPaaS-VM.sh instead of its old location
    - install.sh will also refer to zones.json to be located in foundation/firewall instead of directly in foundation 
    - create an update.sh, that takes the node update section of the current foundation/tappaas-cicd/update.sh script
    - creaete two services: 
      - "vm": implement an install-service.sh based on the install-vm.sh script, and an empty update-service.sh
      - "ha": implement an install-service.sh that calls update-service.sh, which is based on the update-HA.sh
    - insert an empty dependsOn and a provide: [vm,ha]
  b. firewall: based on 10-firewall
    - json extended with a dependsOn that specify it depends on cluster:vm and cluster:ha
    - also extend with provide: [firewall, proxy]
    - add empty service install-service.sh and update-service.sh for each of the 2 services
    - copy zones.json to foundation/firewall. update the update.sh to run the zones creation as per the section in the 30-tapppaas-cicd/update.sh 
  c. templates: based on 15-tappaas-nixos
    - make it provide a service template:nixos, with an install-service.sh that calls update-service.sh which is doing an update-os.sh 
  d. tappaas-cicd: based on 30-tappaas-cicd
    - depends on cluster:vm and cluster:ha
  e. backup: based on 35-backup
  f. identiy: based on 40-identity
2) create 
  - "dependsOn"  in all app modules. make them dependent on cluster:vm 
  - empty "provide"

