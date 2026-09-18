# debianhost — install

Primary audience: TAPPaaS admin. What the automation cannot do for you.

## 1. Authorise the mothership's key on the machine

On the mothership, print its public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

On the machine (its console, or an SSH session you already have), as root:

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '<the key printed above>' >> /root/.ssh/authorized_keys
```

If root already has an entry for the same key with a `command="…"` restriction — Debian's cloud
images add one that answers *"Please login as the user "debian" rather than the user "root""* —
appending is not enough: `sshd` uses the first line that matches. Replace the file instead:

```bash
install -d -m 700 /root/.ssh && echo '<the key printed above>' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
```

Nothing else on the machine changes. Check it from the mothership:

```bash
ssh -o BatchMode=yes root@<address> true && echo ok
```

## 2. Adopt it

```bash
module-manager module adopt <ip-or-fqdn>
```

`adopt` logs in, reads the machine's hostname and OS, names the instance after the hostname,
takes the zone from the address, and registers it — changing nothing on the machine. If the key
does not work yet, it prints the command from step 1 and waits for it (`--wait <seconds>`,
default 300). Two cases it will not decide for you:

- **The hostname is already an instance name** (another machine is called the same): name
  this one with `--instance <name>`.
- **The address is in no active zone** — the machine is off-site, reached through a tunnel, or
  outside TAPPaaS altogether. If it belongs, name its zone with `--zone <zone>`.

## 3. Choose how reboots happen

A kernel or library upgrade can leave a reboot pending. By default it waits, and each update
reports it as deferred. Either allow it for one run:

```bash
module-manager module update <hostname> --allow-disruption
```

or let the scheduled pass take it:

```bash
module-manager module modify <hostname> --set rebootOk=true
```

## Removing it

```bash
module-manager module delete <hostname>
```

unregisters the machine. It keeps running exactly as it is; TAPPaaS simply stops managing it.
