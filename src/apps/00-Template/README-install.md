# Design of install.sh 

The install.sh script is:

- Called from the `tappaas@tappaas-cicd` account, which has SSH and sudo access to all nodes
- Default implementation creates a VM based on the JSON spec by sourcing `. /home/tappaas/bin/install-vm.sh` which will clones a template or installs an image per `imageType`
- it then do module specific installation tasks, for instance if it will run `nixos-rebuild` for NixOS-based modules
- typically it will end by calling update.sh as regular update tasks are also neded after fressh install

If manual steps are required, document them in an `INSTALL.md` file.

after install the ./test.sh can be run to validate the installation

The install module expect first argument to be the name of the module it is installing (and a .json with that name must exist)
optional arguments can be used to override the json definitions:

- --<json-tag> <value>

example ./install.sh template --node "tappaas2 --cores 6
