# templates:debian service

The Debian (or Ubuntu) base for a module's VM: the VM is cloned from a Debian cloud
image, and this service keeps its packages current.

## What a consumer gets

- **An updated OS.** Install and update both run the OS update for the consumer
  (`update-os.sh`, apt), with a reboot when one is needed and allowed.
- **Delete** has nothing to remove: everything this service does lives in the
  consumer's own VM, which is deleted with it. Its script says so.

## How to use it

```json
"dependsOn": ["cluster:vm", "templates:debian"]
```

The image the VM is cloned from is chosen with the `cluster:vm` fields (`imageType`,
`image`, `imageLocation`).

## Fields

`templates:debian` declares no fields.
