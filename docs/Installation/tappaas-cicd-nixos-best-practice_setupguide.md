
# PVE + NixOS + CI/CD Best Practice Workflow (with Cloud‑Init & Baseline Template Hardware)

## **Summary**
This best practice explains how to manage **NixOS virtual machines** in **Proxmox VE (PVE)** using a **central CI/CD VM** as the single source of truth for configuration.  
It uses a **Cloud‑Init enabled NixOS template** so new VMs can be cloned, configured, and connected to the CI/CD repo automatically.

It ensures:

- **Lifecycle Management (LCM)**: Easy creation, update, and retirement of VMs.
- **Reproducibility**: Any VM can be rebuilt exactly the same way at any time.
- **Data Retention**: System updates do not delete user data in `/home`, `/var/lib`, etc.
- **Consistency**: All VMs follow the same structure, with per‑VM customizations.
- **Rollback Safety**: You can roll back to a previous working config in seconds.

**Objective:**  
To have a **repeatable, safe, and automated** way to create, configure, update, and maintain NixOS VMs in PVE.

**Key Results:**
- New VMs can be deployed in minutes from a Cloud‑Init template.
- All configuration is stored in Git on the CI/CD VM.
- Per‑VM configs are tracked and versioned.
- Updates are atomic and reversible.

**Benefits:**
- **Predictable**: No “snowflake” servers — every VM is defined in code.
- **Safe**: Updates don’t touch user data unless explicitly configured.
- **Fast Recovery**: Roll back to a known good state instantly.
- **Scalable**: Works for 1 VM or 100+ VMs.

---

## **Design Principles**
1. **Single Source of Truth**  
   All NixOS configs live in a Git repo on `tappaas-CICD`.
2. **Separation of Concerns**  
   - `common.nix` → shared settings for all VMs.  
   - `hosts/<hostname>.nix` → per‑VM customizations.  
   - `hardware/<hostname>-hw.nix` → hardware config for that VM.
3. **Immutable Infrastructure Mindset**  
   System state is rebuilt from config, not manually changed.
4. **Safe Defaults**  
   Firewall enabled by default, only open needed ports.
5. **Reproducibility**  
   Pin Nixpkgs version or use flakes for exact builds.
6. **Data Safety**  
   User data is stored outside Nix store paths and not wiped by rebuilds.

---

## **Baseline NixOS Template VM — `tappaas-NIXOS template` (ID 8100)**

**Purpose:**  
A clean, Cloud‑Init enabled NixOS VM that can be cloned for any new role.

**PVE Hardware Settings:**
- **Machine type**: `q35`
- **BIOS**: OVMF (UEFI)
- **CPU**: Host passthrough (`host` type), 2–4 cores (adjust per role)
- **RAM**: 4–8 GB (adjust per role)
- **Disk**: 20–40 GB VirtIO SCSI (expand per role)
- **Network**: VirtIO (bridged to LAN)
- **Display**: Default (can be set to none for GPU passthrough VMs)
- **Cloud‑Init drive**: Added via PVE “Add → CloudInit Drive”
- **Boot order**: Disk first
- **Serial console**: Enabled for headless access

**Template Preparation Steps:**
1. Install NixOS normally.
2. Install `git` and `cloud-init` support:
   ```bash
   sudo nix-env -iA nixos.git
   ```
3. Configure `/etc/nixos` as a Git clone from `tappaas-CICD` (see Step 2 below).
4. Shut down the VM.
5. Convert to template in PVE (`Right‑click → Convert to template`).

---

## **Workflow — Step by Step**

### **Pre‑requisites**
- **PVE environment** with:
  - `tappaas-CICD` VM (Git repo host)
  - `tappaas-NIXOS template` VM (ID 8100, Cloud‑Init enabled)
- SSH key‑based access between VMs.
- Git installed on all NixOS VMs.

---

### **Step 1 — Prepare the CI/CD VM (`tappaas-CICD`)**
```bash
# On tappaas-CICD
cd /etc/nixos
sudo git init
sudo git add .
sudo git commit -m "Initial commit of NixOS config"

# Create bare repo for sharing
sudo git clone --bare /etc/nixos /srv/git/tappaas-nixos-config.git
sudo chown -R git:git /srv/git/tappaas-nixos-config.git
```

---

### **Step 2 — Configure the NixOS Template VM (`tappaas-NIXOS template`)**
- Replace `/etc/nixos` with a Git clone:
  ```bash
  sudo mv /etc/nixos /etc/nixos.bak
  sudo git clone git@<cicd-vm-ip>:/srv/git/tappaas-nixos-config.git /etc/nixos
  ```
- Add SSH key for Git access to `tappaas-CICD`.
- Shut down and convert to template.

---

### **Step 3 — Create a New VM from Template**
- In PVE, clone `tappaas-NIXOS template` to create `tappaas-nixos-clone`.
- In the **Cloud‑Init tab** of the new VM in PVE:
  - Set **Hostname** (e.g., `tappaas-vllm`).
  - Set **SSH public key** (for your admin user).
  - Optionally set static IP in **Network** section.
- Boot the VM — Cloud‑Init will set hostname and SSH key automatically.

---

### **Step 4 — Add Per‑VM Config**
On `tappaas-nixos-clone`:
```bash
sudo nixos-generate-config
sudo cp /etc/nixos/hardware-configuration.nix \
        /etc/nixos/hardware/tappaas-vllm-hw.nix

sudo nano /etc/nixos/hosts/tappaas-vllm.nix
```
Example:
```nix
{ config, pkgs, ... }:
{
  networking.hostName = "tappaas-vllm";
  networking.firewall.allowedTCPPorts = [ 8000 ];
  environment.systemPackages = with pkgs; [
    git wget python312 python312Packages.vllm cudaPackages.cudatoolkit
  ];
}
```

---

### **Step 5 — Test the Config**
```bash
sudo nixos-rebuild dry-build
sudo nixos-rebuild build
sudo nixos-rebuild test
sudo nixos-rebuild switch
```

---

### **Step 6 — Push to CI/CD Master**
```bash
cd /etc/nixos
sudo git add hosts/tappaas-vllm.nix hardware/tappaas-vllm-hw.nix
sudo git commit -m "Add tappaas-vllm config"
sudo git push origin main
```

---

### **Step 7 — Update Any VM from CI/CD**
```bash
cd /etc/nixos
sudo git pull origin main
sudo nixos-rebuild switch
```




example


**ready‑to‑use `role-vllm.nix` module** 

drop into your `modules/` directory in the `tappaas‑nixos‑config` repo.  
This will let you assign the **vLLM GPU inference server role** to any VM simply by importing the module in its host file.

---

## 📂 Repo Structure (with role module)
```
/etc/nixos
├── configuration.nix
├── common.nix
├── hosts/
│   ├── tappaas-vllm.nix
├── hardware/
│   ├── tappaas-vllm-hw.nix
└── modules/
    ├── role-vllm.nix
```

---

## **modules/role-vllm.nix**
```nix
{ config, pkgs, ... }:

{
  # Hostname will still be set in the host file
  # This module focuses on the vLLM role setup

  # Open firewall for vLLM API
  networking.firewall.allowedTCPPorts = [ 8000 ];

  # NVIDIA GPU passthrough settings
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = false; # Avoid GPU reset issues
    open = false;                    # Use proprietary driver
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Enable OpenGL and CUDA support
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };

  graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Packages needed for vLLM
  environment.systemPackages = with pkgs; [
    python312
    python312Packages.vllm
    cudaPackages.cudatoolkit
    git
    wget
  ];

  # Optional: systemd service to run vLLM on boot
  systemd.services.vllm-api = {
    description = "vLLM OpenAI-Compatible API Server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.python312}/bin/python -m vllm.entrypoints.openai.api_server \
          --model meta-llama/Llama-2-7b-chat-hf \
          --host 0.0.0.0 \
          --port 8000
      '';
      Restart = "always";
      User = "tappaas";
      WorkingDirectory = "/home/tappaas";
    };
  };
}
```

---

## **Example Host File Using the Role**
`hosts/tappaas-vllm.nix`:
```nix
{ config, pkgs, ... }:

{
  networking.hostName = "tappaas-vllm";

  # Import the vLLM role
  imports = [ ../modules/role-vllm.nix ];

  # Host-specific overrides (optional)
  # environment.systemPackages = with pkgs; [ htop ];
}
```

---

## **How This Fits the Workflow**
- When a new VM is created from the template and named `tappaas-vllm`:
  - First‑boot service generates `hardware/tappaas-vllm-hw.nix` and `hosts/tappaas-vllm.nix`.
  - You edit the host file to import `../modules/role-vllm.nix`.
  - Commit and push to `registration/tappaas-vllm`.
  - After review and merge into `main`, the VM pulls and rebuilds.
- The role module ensures **consistent GPU + vLLM setup** across all inference VMs.

---

**`role-litellm.nix`** module 
 LiteLLM VMs follow the same clean, reusable pattern as the vLLM role. This will let you spin up LiteLLM API gateway VMs with a single import in their host file, keeping the repo DRY and consistent.

---

## 📂 Repo Structure (with LiteLLM role)
```
/etc/nixos
├── configuration.nix
├── common.nix
├── hosts/
│   ├── tappaas-litellm.nix
├── hardware/
│   ├── tappaas-litellm-hw.nix
└── modules/
    ├── role-vllm.nix
    ├── role-litellm.nix   ← new
```

---

## **modules/role-litellm.nix**
```nix
{ config, pkgs, ... }:

{
  # Open firewall for LiteLLM API (adjust port if needed)
  networking.firewall.allowedTCPPorts = [ 4000 ];

  # Base packages for LiteLLM
  environment.systemPackages = with pkgs; [
    python312
    python312Packages.pip
    git
    wget
  ];

  # Optional: install LiteLLM via pip in a virtualenv
  systemd.services.litellm-api = {
    description = "LiteLLM API Gateway";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.python312}/bin/python -m venv /var/lib/litellm-venv
        /var/lib/litellm-venv/bin/pip install --upgrade pip
        /var/lib/litellm-venv/bin/pip install litellm
        /var/lib/litellm-venv/bin/litellm --port 4000 --config /etc/litellm/config.yaml
      '';
      Restart = "always";
      User = "tappaas";
      WorkingDirectory = "/home/tappaas";
    };
  };

  # Ensure /etc/litellm/config.yaml exists (can be managed via NixOS options)
  environment.etc."litellm/config.yaml".text = ''
    # Example LiteLLM config
    model_providers:
      - name: vllm
        base_url: http://tappaas-vllm:8000/v1
        api_key: dummy
    routes:
      - path: /v1
        provider: vllm
  '';
}
```

---

## **Example Host File Using the Role**
`hosts/tappaas-litellm.nix`:
```nix
{ config, pkgs, ... }:

{
  networking.hostName = "tappaas-litellm";

  # Import the LiteLLM role
  imports = [ ../modules/role-litellm.nix ];

  # Host-specific overrides (optional)
  # networking.firewall.allowedTCPPorts = [ 4000 5000 ];
}
```

---

## **How This Fits the Workflow**
- When you create a new LiteLLM VM from the template:
  - First‑boot service generates `hardware/tappaas-litellm-hw.nix` and `hosts/tappaas-litellm.nix`.
  - You edit the host file to import `../modules/role-litellm.nix`.
  - Commit and push to `registration/tappaas-litellm`.
  - After review and merge into `main`, the VM pulls and rebuilds.
- The role module ensures **consistent LiteLLM setup** across all gateway VMs.
