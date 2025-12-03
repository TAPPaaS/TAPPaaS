# install tappass-cicd foundation in a barebone nixos vm

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# clone the tappaas-cicd repo
git clone   https://github.com/TAPPaaS/TAPPaaS.git

# go to the tappaas-cicd folder
cd TAPPaaS/src/foundation/15-TAPPaaS-CICD

# rebuild the nixos configuration
sudo nixos-rebuild switch -I nixos-config=./tappaas-cicd.nix

# create ssh keys for the tappaas user
ssh-keygen -t ed25519 -f /home/tappaas/.ssh/id_ed25519 -N "" -C "tappaas-cicd"
# enforce secure permissions on the private key
sudo chown tappaas:users /home/tappaas/.ssh/id_ed25519*
sudo chmod 600 /home/tappaas/.ssh/id_ed25519

# copy the public key to the root account of the proxmox host
ssh-copy-id -i /home/tappaas/.ssh/id_ed25519.pub root@tappaas1.internal
# also make the key available for the tappaas script that configure cloud-init on the vms
ssh root@tappaas1.internal "mkdir -p /root/tappaas"
scp /home/tappaas/.ssh/id_ed25519.pub root@tappaas1.internal:/root/tappaas/tappaas-cicd.pub

echo "\nTAPPaaS-CICD installation completed successfully."