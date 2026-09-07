# network:dns service

Registers a module's **DNS record** on the resolver. Absence is meaningful here
rather than merely undeclared: a module with no `ip` has chosen to resolve from
its DHCP lease via masqdns, which is a configuration, not an omission.

Absence is meaningful here rather than merely undeclared: a module with no `ip`
is not misconfigured, it has chosen the DHCP + masqdns path. This is why the
field is reconciled and not `set` — "no static record" is a state the reconcile
can reach, and a scalar diff against an empty desired value could not.

A NIC change on the guest side is what usually moves this: see `mac0` in
[`cluster:vm`](../../../cluster/services/vm/README.md), classed
`in-place-reboot` precisely because a new MAC means a new lease and DNS has to
follow.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`network:dns` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `ip`

Static IPv4 address of the device this module represents. Used by network:dns to create the DNS host override <vmname>.<zone0>.internal -> <ip>. Must be a static reservation OUTSIDE the zone's DHCP pool; network:dns install-service warns (does not fail) if the IP falls inside a configured pool. No default — supply it in the module JSON (typically under config."network:dns".ip) or override at install time with --ip <addr>.

| Attribute | Value |
|---|---|
| Type | `string` |
| Format | `^([0-9]{1,3}\.){3}[0-9]{1,3}$` |
| Example | `10.4.20.25` |
| Required by | `network:dns` |
| Used by | `network:dns` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Hardware modules (no VM) declare this so their DNS entry is provisioned automatically at install time (issue #251). The matching static DHCP reservation (MAC-based) remains a manual prerequisite.

**Why this change class.** The address the module's name resolves to. Re-pointing a record is a resolver update; nothing on the guest changes, so no reboot and no downtime. An absent ip means the module resolves from its DHCP lease via masqdns instead, which is the normal case.

<!-- END GENERATED FIELDS -->
