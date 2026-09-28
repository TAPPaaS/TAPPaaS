# templates:nixos service

The NixOS base for a module's VM: the VM is cloned from the NixOS template, and this
service applies and updates the module's NixOS configuration.

## What a consumer gets

- **Its NixOS configuration applied.** Install and update both run the OS update for the
  consumer (`update-os.sh`): the module's `<module>.nix` is rebuilt on the VM, against the
  estate's pinned nixpkgs (ADR-028). A release move is staged for the next boot, never
  switched into a running machine (#728).
- **Delete** has nothing to remove: the configuration lives in the consumer's own VM,
  which is deleted with it. Its script says so.

## How to use it

```json
"dependsOn": ["cluster:vm", "templates:nixos"]
```

The module ships `<module>.nix` beside its JSON; `00-Template/template.nix` is the
starting point.

## Fields

`templates:nixos` declares no fields.
