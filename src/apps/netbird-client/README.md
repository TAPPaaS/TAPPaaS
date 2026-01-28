# Netbird client

This module installs a netbird client in TAPPaaS

You can have several jsons if you want to have clients in several TAPPaaS zones

## TODO

convert to NisOS
also right now it does not work

## installation

rin

```bash
./install netbird-client
```

##  setup netbird 

Before we configure NetBird, we are going to want to generate a one-off setup key to use with our VM
while NetBird's documentation offers comprehensive guidance on this process, let's quickly review the essential steps:

    Access your NetBird dashboard
    Navigate to the Setup Keys section
    Click the Create Setup Key button on the right
    Name your key (e.g., "ProxmoxLXC")
    Set an expiration date (recommended for enhanced security)
    Configure auto-assigned groups if needed (e.g., "Homelab")
    Click Create Setup Key to generate the setup key

Now we can connect our client to our account using the setup key we generated earlier.

  netbird up --setup-key <SETUP KEY>