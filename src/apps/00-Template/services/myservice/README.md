# mymodule:myservice service

<!-- Replace this README when you write the service (ADR-027 D3). A consumer reads it to
learn what it gets and what it must declare. If your module provides no service, delete
services/ and the "provides" entry in the module JSON. -->

What a consumer of this service gets, in a sentence or two.

## What a consumer gets

- What install does for the consumer, and what update keeps true.
- What delete removes again.

## How to use it

```json
"dependsOn": ["mymodule:myservice"]
```

## Fields

`mymodule:myservice` declares no fields. If it comes to own fields, add a `fields.json`
([README-service-provider.md](../../README-service-provider.md)) and run
`scripts/gen-service-fields-doc.py`, which replaces this section with the generated one.
