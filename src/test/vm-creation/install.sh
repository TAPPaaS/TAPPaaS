# install the identity foundation: create VM
# It assume that you are in the install directoy

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

# make sure we have the latest version of the configuration files
# git pull

# clone the nixos template
scp test-clone.json root@tappaas1.internal:/root/tappaas/test-clone.json
scp test-iso.json root@tappaas1.internal:/root/tappaas/test-iso.json
scp test-img.json root@tappaas1.internal:/root/tappaas/test-img.json
ssh root@tappaas1.internal "/root/tappaas/Create-TAPPaaS-VM.sh test-clone"
ssh root@tappaas1.internal "/root/tappaas/Create-TAPPaaS-VM.sh test-iso"
ssh root@tappaas1.internal "/root/tappaas/Create-TAPPaaS-VM.sh test-img"

# rebuild the nixos configuration
# nixos-rebuild --target-host tappaas@identity.internal --use-remote-sudo switch -I nixos-config=./test.nix


echo "Identity VM installation completed successfully."