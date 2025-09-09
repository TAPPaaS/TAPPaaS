# 🛠️ PVE + NixOS + CI/CD Deployment & Lifecycle Management Guide  
**Zero‑Touch with Cloud‑Init, Self‑Registration, Branch Protection & Role Modules**

---

## 1. Bootstrap & VM Configuration

### **Who is involved**
- **PVE Admin** — Creates/configures VMs in Proxmox, attaches Cloud‑Init drives, sets baseline hardware.
- **NixOS Config Maintainer** — Manages the Git repo on `tappaas‑CICD`, reviews and merges config changes.
- **Service Owner** — Defines per‑VM role (vLLM, LiteLLM, OpenWebUI) and tests after deployment.

---

### **Bootstrap Sequence** (one‑time setup)

#### Step 1 — Create `tappaas‑CICD` VM
- **Purpose**: Host the central NixOS config repo.
- **PVE Settings**:
  - CPU: 2 cores
  - RAM: 2–4 GB
  - Disk: 20 GB
  - Network: VirtIO, bridged
  - OS: NixOS minimal ISO
- **Setup**:
  ```bash
  sudo nix-env -iA nixos.git
  cd /etc/nixos
  sudo git init
  sudo git add .
  sudo git commit -m "Initial commit of NixOS config"
  sudo git clone --bare /etc/nixos /srv/git/tappaas-nixos-config.git
  sudo chown -R git:git /srv/git/tappaas-nixos-config.git
  ```

---

#### Step 2 — Create `tappaas‑NIXOS template` VM (ID 8100)
- **Purpose**: Base image for all tappaas VMs.
- **PVE Settings**:
  - Machine type: `q35`
  - BIOS: OVMF (UEFI)
  - CPU: Host passthrough, 2–4 cores
  - RAM: 4–8 GB
  - Disk: 20–40 GB VirtIO SCSI
  - Network: VirtIO, bridged
  - Cloud‑Init drive: Added
  - Boot order: Disk first
  - Serial console: Enabled
- **Setup**:
  ```bash
  sudo nix-env -iA nixos.git
  sudo mv /etc/nixos /etc/nixos.bak
  sudo git clone git@<cicd-vm-ip>:/srv/git/tappaas-nixos-config.git /etc/nixos
  ```
- Install **first‑boot self‑registration service** (see section 6).
- Shut down and convert to template in PVE.

---

#### Step 3 — First tappaas Service VM
- Clone from template.
- In Cloud‑Init tab:
  - Set hostname (e.g., `tappaas-vllm`).
  - Set SSH public key.
  - (Optional) Set static IP.
- Boot — first‑boot service runs, pushes configs to `registration/<hostname>`.

---

### **Baseline VM Config Table**

| VM Name / Role         | CPU   | RAM     | Disk   | Network | Notes              |
|------------------------|-------|---------|--------|---------|--------------------|
| tappaas‑CICD           | 2c    | 2–4 GB  | 20 GB  | VirtIO  | Git repo host      |
| tappaas‑NIXOS template | 2–4c  | 4–8 GB  | 20–40G | VirtIO  | Cloud‑Init enabled |
| tappaas‑vllm           | 4–8c  | 16–32G  | 40–80G | VirtIO  | GPU passthrough    |
| tappaas‑litellm        | 2–4c  | 4–8 GB  | 20–40G | VirtIO  | API gateway        |
| tappaas‑openwebui      | 2–4c  | 4–8 GB  | 20–40G | VirtIO  | Web UI frontend    |

---

## 2. Why This Is Best Practice

### The Problem
Without structure:
- Configurations drift.
- Updates are inconsistent.
- Rebuilds are slow and risky.
- No single source of truth.

### The Solution
- **GitOps**: All configs in Git on `tappaas‑CICD`.
- **Cloud‑Init template**: Every VM starts from a known baseline.
- **First‑boot automation**: Self‑registers and applies config.
- **Branch protection**: Review before production.
- **Role modules**: Reusable configs for common VM types.

### The Benefits
- **LCM**: Easy to create/update/retire VMs.
- **Reproducibility**: Exact rebuilds.
- **Data safety**: User data untouched unless declared.
- **Consistency**: Shared base + per‑VM overrides.
- **Rollback**: Git or NixOS generations.
- **Scalability**: Works for 1 or 100+ VMs.

---

## 3. Repo Structure
```
/etc/nixos
├── configuration.nix
├── common.nix
├── hosts/
│   ├── tappaas-vllm.nix
│   ├── tappaas-litellm.nix
│   ├── tappaas-openwebui.nix
├── hardware/
│   ├── tappaas-vllm-hw.nix
│   ├── tappaas-litellm-hw.nix
│   ├── tappaas-openwebui-hw.nix
└── modules/
    ├── role-vllm.nix
    ├── role-litellm.nix
    ├── role-openwebui.nix
```

---

## 4. Key Files

### configuration.nix
```nix
{ config, pkgs, ... }:

{
  imports = [
    ./common.nix
    ./hardware/${config.networking.hostName}-hw.nix
    ./hosts/${config.networking.hostName}.nix
  ];
}
```

### common.nix
```nix
{ config, pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;
  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = "Europe/Amsterdam";
  services.openssh.enable = true;
  networking.firewall.enable = true;

  environment.systemPackages = with pkgs; [ git wget ];

  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    openssh.authorizedKeys.keys = [ ];
  };

  system.stateVersion = "25.05";
}
```

---

## 5. Role Modules

### modules/role-vllm.nix
```nix
{ config, pkgs, ... }:

{
  networking.firewall.allowedTCPPorts = [ 8000 ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = false;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };

  graphics = {
    enable = true;
    enable32Bit = true;
  };

  environment.systemPackages = with pkgs; [
    python312
    python312Packages.vllm
    cudaPackages.cudatoolkit
    git
    wget
  ];

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

### modules/role-litellm.nix
```nix
{ config, pkgs, ... }:

{
  networking.firewall.allowedTCPPorts = [ 4000 ];

  environment.systemPackages = with pkgs; [
    python312
    python312Packages.pip
    git
    wget
  ];

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
