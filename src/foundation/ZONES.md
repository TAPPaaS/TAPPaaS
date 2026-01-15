# Zone definitions in TAPPaaS

## Introduction

The zones.json define the security zones of the TAPPaaS solution.
Each record in the .json define a zone

The individual modules of TAPPaaS will be connected to a zone, based on their respective module.json

as part of installing the firewall and the tappaas-cicd modules the administrator will be given the option to modify a copy of the zones file


## Fields


- "type": what kind of security zone this zone is. 
    - Posible values:
        - "Mananagement": this is where TAPPaaS nodes and self management is connected. Must be locked down with no access from other nodes or access from the Internet. typically there is only on managemetn zone called mgmt (mandatory)
        - "Service": this is where services modules lives. There can be several seperate service zones, each will serve services to a different user base (say a single TAPPaaS system serves several business or both a busines and a home use)
        - "Client": a zone that serve client devices. There can be several Client zones if there are different user bases served by the TAPPaaS system
        - "IoT": zone that server IoT devices. typically there will be several for differnet kind of (often unsecure) devices 
        - "Guest": security zones for un authorized clients
        - "DMZ": Demiliritarized zones
- "state": is the zone active, that is is it configured in a given instance of TAPPaaS
    - Possible Values:
        - "Active" or "Mandatory": Zone is created and configured by zone-manager (VLANs, DHCP)
        - "Inactive" or "Disabled": Zone is not created; if it exists it will be removed by zone-manager
        - "Manual": Zone is managed manually; zone-manager will neither create nor remove it    -  
- "typeId": a uniques number per "type" of service
    - possible values: 0 for Management, 2 for Service, 3 for Client, 4 for IoT, 5 for Guest, 6 for DMZ 
- "subId": a unique number between 0 and 99 that identify the zone inside its zone type
- "vlantag": a unique vlan tag for the zone. it can be computed as the typeId*100+subId
- "ip": the ip range associated with the zone
    - can be computed as 10.typeId.subId.0/24
- "bridge": the interface the zone is associated with (the trunk forthe vlan), typically lan or wan
- "access-to": a list of zones that this zone can connect to. When zone-manager is run with --firewall-rules, pass rules are created for each target.
    - Special values:
        - "internet": allows traffic to any destination (outbound internet access)
        - "all": creates a wildcard pass rule (destination: any)
    - Zone names: allows traffic to that zone's network (e.g., "srv", "dmz")
- "pinhole-allowed-from": a list of zones that would allow to have a connection on to a dedicated port inside this zone. It is used to check module specific firewall rules to be validated against zone policies
- "DHCP-start": (optional) the starting offset for DHCP range within the subnet. Default: 50 (e.g., .50)
- "DHCP-end": (optional) the ending offset for DHCP range within the subnet. Default: 250 (e.g., .250)
- "description": descriptive text for hte zone



## Example

    "tappaas": {
        "type": "Management",
        "state": "Manadatory",
        "typeId": "0",
        "subId": "0",
        "vlantag": 0,
        "ip": "10.0.0.0/24",
        "bridge": "lan",
        "access-to": ["internet", "dmz", "srv", "client", "guest", "iot"],
        "description": "Internal self management network, untagged traffic"
    }