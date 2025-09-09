# Git Command Cheat Sheet for tappaas NixOS VMs (Cloud‑Init Ready)

This cheat sheet assumes:

- The VM was cloned from the **`tappaas-NIXOS template`** (ID 8100) in PVE.
- The template is **Cloud‑Init enabled** and already has:
  - `/etc/nixos` as a Git clone of the CI/CD repo on `tappaas-CICD`.
  - SSH keys baked in for Git access.
- Cloud‑Init sets the **hostname** and **SSH key** for the admin user at first boot.

---

## **First Boot (Cloud‑Init)**
When you create a new VM in PVE from the template:

1. In the **Cloud‑Init tab**:
   - Set **Hostname** (e.g., `tappaas-vllm`).
   - Set **SSH public key** for your admin user.
   - (Optional) Set static IP in **Network** section.

2. Boot the VM — Cloud‑Init will:
   - Apply the hostname.
   - Inject the SSH key.
   - Keep `/etc/nixos` pointing to the CI/CD repo.

---

## **Daily Git Commands**

```bash
# Go to the NixOS config repo
cd /etc/nixos

# Check current repo status
git status

# See which remote repo is configured
git remote -v

# Fetch latest changes from CI/CD master
git fetch origin

# Pull latest config from main branch
git pull origin main

# Switch to a feature branch for testing changes
git checkout -b feat/<hostname>-update

# Add new or changed files (per-host config + hardware config)
git add hosts/<hostname>.nix hardware/<hostname>-hw.nix

# Commit changes with a clear message
git commit -m "<hostname>: updated config"

# Push changes to main branch (direct deploy)
git push origin main

# Push changes to a feature branch (for review/merge)
git push origin feat/<hostname>-update

# View commit history
git log --oneline --graph --decorate

# Roll back to a previous commit from Git
git checkout <commit-hash>
sudo nixos-rebuild switch

# Roll back to previous NixOS generation (no Git change)
sudo nixos-rebuild switch --rollback
```

---

## **Typical Per‑VM Workflow**

1. **Create VM** from `tappaas-NIXOS template` in PVE.
2. **Cloud‑Init** sets hostname + SSH key.
3. On first login:
   ```bash
   sudo nixos-generate-config
   sudo cp /etc/nixos/hardware-configuration.nix \
           /etc/nixos/hardware/<hostname>-hw.nix
   sudo nano /etc/nixos/hosts/<hostname>.nix
   ```
4. **Test changes**:
   ```bash
   sudo nixos-rebuild dry-build
   sudo nixos-rebuild build
   sudo nixos-rebuild test
   sudo nixos-rebuild switch
   ```
5. **Push to CI/CD**:
   ```bash
   cd /etc/nixos
   sudo git add hosts/<hostname>.nix hardware/<hostname>-hw.nix
   sudo git commit -m "<hostname>: tested and working config"
   sudo git push origin main
   ```

---

## **Best Practices**
- Always commit **both** the host file and hardware file for a new VM.
- Use **feature branches** for risky changes — merge to `main` only after testing.
- Tag stable states in the CI/CD repo:
  ```bash
  sudo git tag -a vllm-stable-2025-09-09 -m "Stable vLLM config"
  sudo git push origin vllm-stable-2025-09-09
  ```
- Never edit `/etc/nixos` outside Git — keep it 100% declarative.