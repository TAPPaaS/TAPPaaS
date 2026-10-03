# Design of install.sh 

The install.sh script is:

- Called from the `tappaas@tappaas-cicd` account, which has SSH and sudo access to all nodes
- It does **not** create the VM itself. VM creation is delegated to the `cluster:vm` install-service (`src/foundation/cluster/services/vm/install-service.sh`), which `install-module.sh` runs — before `install.sh` — for any module that lists `"cluster:vm"` in its `dependsOn`. It clones a template or installs an image per `imageType`. (The legacy `/home/tappaas/bin/install-vm.sh` helper no longer exists; do not source it — see issue #166.)
- `install.sh` therefore only does module-specific installation tasks, for instance running `nixos-rebuild` for NixOS-based modules
- typically it ends by calling `update.sh`, as regular update tasks are also needed after a fresh install

If manual steps are required, document them in an `INSTALL.md` file.

after install the ./test.sh can be run to validate the installation

The install module expect first argument to be the name of the module it is installing (and a .json with that name must exist)
optional arguments can be used to override the json definitions:

- --<json-tag> <value>

example ./install.sh template --node "tappaas2 --cores 6
