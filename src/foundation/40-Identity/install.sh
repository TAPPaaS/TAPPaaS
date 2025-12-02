# install the identity foundation: create VM, run nixos-rebuil, for vm
# It assume that you are in the install directoy

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# clone the nixos template
ssh root@tappaas1.internal "bash -s" < bin/CloneTAPPaaSNixOS.sh identity

# rebuild the nixos configuration
nixos-rebuild --target-host tappaas@identity.internal --use-remote-sudo switch -I nixos-config=./identity.nix


echo "\nIdentity VM installation completed successfully."