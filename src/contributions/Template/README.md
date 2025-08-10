# Template

This directory contain all needed information and scripting for installing
    * Template *

The module will install

- sw package xxx
- sw package yyy

THe module will integrate 
- SW package xx with the identity management system
- SW package yy will be register for monitoring in the monitoring system
...

The following can be configured:
- what storage pool to use
- if HA should be enabled, and if yes what node to use as HA node
- ...
To enable and configuring the module copy configuration.yaml.default to configuration.yaml and edit this file

To install the module after editing the configuration, run the command:
 ./install.sh

At this time some steps are not automated. After running ./Install.sh please do the following

# Manual Steps for Install

1) do ...
2) do ...
...

