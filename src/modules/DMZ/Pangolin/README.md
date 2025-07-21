# Pangolin installation

## create VM

run the command from tappaas-cicd VM 

```
cd TAPPaaS/src/modules/DMZ/pangolin
export PVE_NODE=<ip of tappas1 node>
./CreatePangolinVM.sh
```

## download and run Pangolin

do 

```
wget -O installer "https://github.com/fosrl/pangolin/releases/download/1.7.3/installer_linux_$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" && chmod +x ./installer
./installer
```