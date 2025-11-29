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
sudo chown tappaas:tappaas /home/tappaas/.ssh/id_ed25519*
sudo chmod 600 /home/tappaas/.ssh/id_ed25519

echo "TODO install public key on proxmox node for tappaas user"

echo "\nTAPPaaS-CICD installation completed successfully."