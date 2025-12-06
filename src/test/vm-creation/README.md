# Testing VM creation scripts 

This directory has some test vm creation jsons 

run the commands from the tappass-cicd command prompt (assuming that you are testing the "experiment" branch)
```
cd
cd TAPPaaS
git pull experiment
scp src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh root@tappaas1.internal:/root/tappaas/Create-TAPPaaS-VM.sh
cd src/test/vm-creation
chmod 755 install.sh
./install.sh
```

TODO automate tests

if everything is OK, then in the proxmox GUI you can delete vm: testvm1
