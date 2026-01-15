# Patching OPNsense 

in order to assign interfaces programatically we need to add an MVC
this is copied from:
  https://gist.github.com/szymczag/df152a82e86aff67b984ed3786b027ba

## This is a description of usage

from https://github.com/szymczag


Hi there,

since I had the same issue (among others), I've put together an endpoint which might be helpful:

https://gist.github.com/szymczag/df152a82e86aff67b984ed3786b027ba

### Usage
Installation

Just place it in

/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/AssignSettingsController.php

via SSH.
### Assign interface

curl -k -X POST -u "YOUR_API_KEY:YOUR_API_SECRET" \
     -H "Content-Type: application/json" \
     -d '{
           "assign": {
             "device": "vlan0.100",
             "description": "assigned vlan via api",
             "enable": true,
             "ipv4Type": "static",
             "ipv4Address": "192.168.100.1",
             "ipv4Subnet": 24
           }
         }' \
     https://OPNSense/api/interfaces/assign_settings/addItem

### Unassign interface

curl -k -X DELETE -u "YOUR_API_KEY:YOUR_API_SECRET" \
     https://OPNSense/api/interfaces/assign_settings/delItem/opt1

Feel free to merge to the main code.

pzdr,
maciek