# TAPPaaS CICD setup

## Introduction

Setup runs in these macro steps:

- create a tappaas-cicd VM based on the template 
- update the tappaas-cicd with the git clone and rebuild with right nixos configuration
- configure/install tappaas-cicd tools and pipelines

## create tappaas-cicd

Install cloning config: on the proxmox command prompt, then run the command to create the tappaas-cicd clone

```bash
BRANCH="main"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/30-tappaas-cicd/tappaas-cicd.json >~/tappaas/tappaas-cicd.json
~/tappaas/Create-TAPPaaS-VM.sh tappaas-cicd
```

There should now be a running tappaas-cicd VM. you can ssh into the VM from the proxmox console. However note that the hostname of the machine has not been changed yet, so you need to use the ip number of the machine.

you can see the IP number in the "summary" page of the tappaas-cicd VM in the tappaas1 proxmox GUI

```bash
ssh tappaas@10.0.0.xxx
```

when logged in run the install1.sh script
```bash
BRANCH="main"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/30-tappaas-cicd/install1.sh | bash
```

Reboot the tappaas-cicd VM and check that you can login using domain name
```bash
ssh tappaas@tappaas-cicd.mgmt.internal
```

### Setting up SSH Access to OPNsense Firewall

The tappaas-cicd VM needs SSH access to the firewall for automated updates. Follow these steps to configure SSH key authentication:

1. **Enable SSH on OPNsense**:
   - Log into OPNsense web interface
   - Go to **System > Settings > Administration**
   - Under **Secure Shell**, check **Enable Secure Shell**
   - Check **Permit root user login**
   - Check **Permit password login** (temporarily, for key setup)
   - Press Save to apply

2. **Copy the SSH public key to OPNsense**:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@firewall.mgmt.internal
```

Enter the root password when prompted.

3. **Test SSH access**:

```bash
ssh root@firewall.mgmt.internal "echo 'SSH access configured successfully'"
```

4. **Disable password authentication** (recommended for security):
   - Go back to **System > Settings > Administration**
   - Uncheck **Permit password login**
   - press Save to apply

   SSH key authentication will continue to work after disabling password login.

### Creating API Credentials in OPNsense and install them in ~/.opnsense-credentials

1. Log into OPNsense web interface
2. Go to **System > Access > Users**
3. add a user "tappaas"
   - username is tappaas, password use the same as for the root account of opnsense (or something random you are not going to log in)
   - Group membership: Admin
   - Privileges: "all pages"
   - Save
4. On the same page, in the new user line tappaas, look at the commands section to the rigth. There is a "create and download API keys" button
   - press that and create a key.
   - open the downloaded txt file and copy the two key lines 
5. in a terminal window ssh into the tappaas-cicd and:
   - create a file ~/.opnsense-credentials.txt using you vi or nano. 
   - insert the copied two API key lines
   - save
6. Delete the downloaded key file from your browser pc.

### install the tappaas-cicd programs

on the tappaas-cicd console (via ssh, logged in as tappaas user) do:

```bash
export BRANCH="main"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/30-tappaas-cicd/install2.sh | bash
```

You might be asked for password for root at proxmox node tappaas1

## Configure Reverse Proxy (Caddy)

The install script automatically installs the os-caddy package and creates firewall rules for HTTP/HTTPS traffic. However, some manual configuration is required via the OPNsense web UI.

### Automated Steps (done by install.sh)

The `setup-caddy.sh` script performs:
- Installs os-caddy package on the firewall
- Creates firewall rules for HTTP (port 80) and HTTPS (port 443) on WAN interface

### Manual Configuration Steps

Complete the following steps in the OPNsense web UI (https://firewall.mgmt.internal or https://firewall.mgmt.internal:8443):

#### 1. Move OPNsense Web GUI to Port 8443

This frees up ports 80/443 for Caddy to handle.

1. Go to **System > Settings > Administration**
2. Under **Web GUI**, set **TCP Port** to `8443`
3. Click **Save**
4. Reconnect to OPNsense at https://firewall.mgmt.internal:8443

#### 2. Enable Caddy Service

1. Go to **Services > Caddy Web Server > General**
2. Check **Enable Caddy**
3. Set **ACME Email** to your email address (from configuration.json)
   - This is required for Let's Encrypt SSL certificates
4. Click **Save** then **Apply**

#### 3. Add Your Domain

1. Go to **Services > Caddy Web Server > Reverse Proxy > Domains**
2. Click **+** to add a new domain
3. Configure:
   - **Domain**: Your domain (e.g., `mytappaas.dev`)
   - **Description**: `TAPPaaS Main Domain`
4. Click **Save** then **Apply**

#### 4. Add Reverse Proxy Handlers

For each service you want to expose, add a handler:

1. Go to **Services > Caddy Web Server > Reverse Proxy > Handlers**
2. Click **+** to add a new handler
3. Configure:
   - **Domain**: Select your domain
   - **Upstream Domain**: The internal service address (e.g., `nextcloud.srv.internal`)
   - **Upstream Port**: The service port (e.g., `80` or `443`)
   - **Description**: Service name
4. Click **Save** then **Apply**

### Reference

For more details, see the OPNsense Caddy documentation:
[Caddy Install Guide](https://docs.opnsense.org/manual/how-tos/caddy.html#installation)

Note: As VLANs are created, additional firewall rules may be needed to allow traffic between zones.
