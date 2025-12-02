# install the identity foundation: create VM, run nixos-rebuil, for vm
# It assume that you are in the install directoy

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# clone the nixos template
ssh root@tappaas.internal "bash -s" < bin/CloneTAPPaaSNixOS.sh 102 identity 2 8G 16G 0 "Identity VM for TAPPaaS"

# rebuild the nixos configuration
nixos-rebuild switch -I nixos-config=./identity.nix


echo "\nIdentity VM installation completed successfully."