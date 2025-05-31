flowchart TD
    subgraph Core Network
        MGMT[Management VLAN<br>10.0.10.0/24]
        DMZ[DMZ VLAN<br>10.0.20.0/24]
        PROD[Prod-Servers VLAN<br>10.0.30.0/24]
        STORAGE[Prod-Storage VLAN<br>10.0.40.0/24]
        WORK[Workstations VLAN<br>10.0.50.0/24]
        IOT[IoT VLAN<br>10.0.60.0/24]
        GUEST[Guest VLAN<br>10.0.70.0/24]
    end

    MGMT -- "Admin access<br>Provisioning<br>Automation" --> PROD
    MGMT -- "Monitoring<br>Inventory" --> STORAGE
    MGMT -- "Central Logging" --> DMZ
    PROD -- "App/DB traffic" --> STORAGE
    WORK -- "User access" --> PROD
    IOT -- "Internet only" --> DMZ
    GUEST -- "Internet only" --> DMZ

    %% Tool integrations
    MGMT -.-> NetBox["NetBox<br>(Inventory)"]
    MGMT -.-> Ansible["Ansible<br>(Automation)"]
    MGMT -.-> Graylog["Graylog<br>(Logging)"]
    MGMT -.-> Keycloak["Keycloak<br>(IAM)"]
    DMZ -.-> Suricata["Suricata<br>(IDS/IPS)"]
    DMZ -.-> OPNsense["OPNsense<br>(Firewall)"]
    PROD -.-> Monit["Monit<br>(Self-healing)"]
    PROD -.-> Graylog
    STORAGE -.-> TrueNAS["TrueNAS<br>(Storage)"]
    STORAGE -.-> Proxmox["Proxmox Backup<br>Server"]
    WORK -.-> FreeRADIUS["FreeRADIUS<br>(NAC)"]
    IOT -.-> Zeek["Zeek<br>(Network Detection)"]
    GUEST -.-> OpenWRT["OpenWRT<br>(Captive Portal)"]

    %% Descriptions
    classDef vlan fill:#f9f,stroke:#333,stroke-width:2px;
    class MGMT,DMZ,PROD,STORAGE,WORK,IOT,GUEST vlan;