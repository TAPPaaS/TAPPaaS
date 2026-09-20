# nextcloud:fileservice service

<!-- Describe what this service provides and how a module uses it. This prose is yours; the generated block below is not. -->

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`nextcloud:fileservice` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `connector`

The Nextcloud integration this consumer provides. update-service.sh re-applies 'onlyoffice' (the ADR-COM-0002 document-server wiring for euro-office); 'talk' (coturn) and 'hpb' (nextcloud-hpb) name the consumer's role and are not re-applied by this service.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | *(none)* |
| Format | `^(onlyoffice|talk|hpb)$` |
| Example | `onlyoffice` |
| Required by | *(none)* |
| Used by | `nextcloud:fileservice` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** Which connector the consumer is. update-service.sh reconciles the onlyoffice wiring on every run; changing the value changes what that reconcile does, with no guest downtime.

<!-- END GENERATED FIELDS -->
