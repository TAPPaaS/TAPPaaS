# ca-manager

The site's certificate authorities and the certificates they issue ([ADR-043](../../../../../docs/ADR/ADR-043%20-%20Site%20Certificates.md)).

| | |
|---|---|
| Owns | `config/certificates.json` (each CA and certificate, never a key), `config/site-ca.pem` (the trust bundle) |
| Keys | `TAPPAAS_CA_DIR`, default `/home/tappaas/.tappaas-ca`, mode 700: `ca/<id>.key|pem`, `certs/<name>.key|pem` |
| Runs | `openssl`, on its PATH from its nix build |

## The CAs

| CA | id | May sign | Made by |
|---|---|---|---|
| Internal | `internal` | names under `internal` | `ca-manager init`, once, in the install |
| Domain | `domain-<domain>` | `<domain>` and its subdomains | `ca-manager domain add <domain>` |

Each is a self-signed root valid for 10 years, with a critical name constraint: a stolen key can
sign nothing outside its names. A domain an existing domain CA covers gets no CA of its own
(`test.my-org.tld` under `my-org.tld`); an unrelated domain gets a separate one.

## Verbs

```
ca-manager init [--check]
ca-manager domain add <domain> [--check]
ca-manager cert issue <name> --dns <n>[,<n>…] [--check]
ca-manager cert renew [<name>] [--within <days>] [--force] [--check]
ca-manager status [--json]
ca-manager validate
```

`cert issue` picks the one CA whose constraint covers every name; internal and domain names go in
separate certificates. Certificates last a year, and `cert renew` renews what expires within 60
days. `validate` checks the record against the files: fingerprints, key modes, and that the bundle
holds exactly the recorded CAs.

## Not yet

From ADR-043's delivery list: the DNS providers, `rotate`, the CMDB report (D11), and delivering
certificates to guests.

## Who calls it

- The mothership's install runs `init` before any guest but the firewall and itself is built, and
  its pre-update runs it again, so a site installed earlier gets its internal CA at its next update.
- `site-locale.sh` puts the bundle on every NixOS guest (`tappaas-site.nix`) and every Debian guest;
  the cluster update puts it on every node. Debian hosts get one file per CA under
  `/usr/local/share/ca-certificates/tappaas/`.
- A bundle holding a CA ca-manager did not make is never overwritten: `init` refuses, and says how
  to take it over (`--replace-bundle`).

## Testing

`./test.sh`: the rules as unit tests, then the CLI with real openssl in a temp config and key dir,
with openssl verifying every certificate it signs.
