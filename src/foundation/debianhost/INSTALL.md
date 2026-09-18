# debianhost — install

Primary audience: TAPPaaS admin. What the automation cannot do for you.

> `module-manager module adopt <address>` (ADR-026 D8.1) will do steps 1–3 for you: it reads the
> machine's hostname, OS and zone itself. Until it exists, register a machine by hand as below.

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

Nothing else on the machine changes. Check it from the mothership:

```bash
ssh -o BatchMode=yes root@<address> true && echo ok
```

## 2. Register it

Name the instance after the machine, give its address, and the zone its network interface is on:

```bash
module-manager module add debianhost --instance <hostname> --address <ip-or-fqdn> --zone0 <zone>
```

`install.sh` verifies it can log in and that the machine runs Debian — and changes nothing.

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
