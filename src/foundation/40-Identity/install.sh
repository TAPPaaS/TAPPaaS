# install the identity foundation: create VM, run nixos-rebuil, for vm
# It assume that you are in the install directoy

. /home/tappaas/bin/common-install-rutines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
VLANTAG0NAME="$(get_config_value 'vlantag0' 'tappaas')"

# clone the nixos template
scp $VMNAME.json root@${NODE}.tappaas.internal:/root/tappaas/$VMNAME.json
ssh root@${NODE}.tappaas.internal "/root/tappaas/Create-TAPPaaS-VM.sh $VMNAME"

# rebuild the nixos configuration
nixos-rebuild --target-host tappaas@$VMNAME.$VLANTAG0NAME.internal --use-remote-sudo switch -I nixos-config=./$VMNAME.nix

echo "\nIdentity VM installation completed successfully."