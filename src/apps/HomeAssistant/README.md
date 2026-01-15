# installing Home Assistant

create VM and install HAOS, using proxmox helper scripts. 
use advanced options.
change hostname to: homeassistant
add VLAN: 200
rest of question answer with default answer

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/vm/haos-vm.sh)"
```

Now Do:

- go to the HA web: 10.2.0.xxx:8123
- enable the advanced mode
- search for and add the "Terminal & SSH" addon in the add on store
- open terminal web UI

- Now go to pangolin web UI and create a new site: homeassistant
- copy the newt configuration command to the HA terminal web UI

