# <module name> Instalation Guide

## Installation Steps

### 1. Confirm Configuration

<edit as appropiate for this module>

look at ./<module-name>.json. If this file is not correctly reflecting how you want this module to be installed in your environments. For instance if:

- you want to have the module to run on a different node than the default "tappaass1" 
- you want the VM to e on a different storage node than "tanka1"
- you want to make it a member of a different LAN zone (VLAN)
Then copy the json to /home/tappaas/config and edit the file to reflect your choices

Then as tappaas use on the tappaas-cicd: run the command:

```bash
./install.sh <modulename>
```

## Verification Tests

Once installd verify the installation worked by executiong

```bash
./test.sh <modulename>
```

## Common Issues

