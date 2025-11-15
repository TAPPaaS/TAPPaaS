Here’s a concise, step-by-step guide to configuring GPU passthrough in Proxmox VE:
1. Prerequisites
	•	Your hardware must support VT-d/AMD-Vi (IOMMU) and UEFI.
	•	Enable IOMMU and (optionally) Above 4G Decoding in your BIOS/UEFI settings.
2. Edit GRUB to Enable IOMMU
    Edit `/etc/default/grub`:
        nano /etc/default/grub
    Find the line starting with `GRUB_CMDLINE_LINUX_DEFAULT` and change it to:
        GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt pcie_acs_override=downstream,multifunction nofb nomodeset video=vesafb:off,efifb:off"

       Note! For AMD CPUs, use `amd_iommu=on` instead of `intel_iommu=on`.

    Save and update GRUB:
        update-grub

    3. Load VFIO Modules
        Edit `/etc/modules` (or `/etc/modules-load.d/modules.conf`):

        nano /etc/modules

        Add these lines:
            vfio
            vfio_iommu_type1
            vfio_pci
            vfio_virqfd

    4. Blacklist Host GPU Drivers
        Create or edit `/etc/modprobe.d/blacklist.conf` and (Adjust for your GPU type as needed!) add:

        blacklist nouveau
        blacklist nvidia
        blacklist radeon
        blacklist amdgpu

    5. Bind GPU to VFIO
	•	Find your GPU’s PCI IDs with:

         lspci -nn | grep -i nvidia

         (or AMD/other vendor)
	•	Note both the GPU and its audio device IDs (e.g., `10de:1b81,10de:10f0`).
	•	    Create `/etc/modprobe.d/vfio.conf`:

            echo "options vfio-pci ids=10de:1b81,10de:10f0 disable_vga=1" > /etc/modprobe.d/vfio.conf

    6. Update Initramfs and Reboot

        update-initramfs -u
        reboot      

    7. Add GPU to VM
	•	In the Proxmox web UI, select your VM.
	•	Go to Hardware > Add > PCI Device.
	•	Select your GPU (and audio device if needed).
	•	Enable “All Functions” and “Primary GPU” if required.

    8. (Optional) Windows VM Tweaks
	•	For Windows VMs, add the following to the VM’s configuration (`/etc/pve/qemu-server/<VMID>.conf`):

        machine: q35
        cpu: host,hidden=1,flags=+pcid
        args: -cpu 'host,+kvm_pv_unhalt,+kvm_pv_eoi,hv_vendor_id=NV43FIX,kvm=off'

    References
	•	Proxmox PCI Passthrough Wiki
	•	Step-by-step guides