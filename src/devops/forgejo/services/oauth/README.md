# forgejo:oauth service

Sign in to a module with Forgejo: its users sign in with their Forgejo account, which is
their Authentik account (Forgejo signs in with Authentik).

## What a consumer gets

- **An OAuth2 application** in Forgejo, `tappaas-<vmname>`, confidential. Its redirect URIs
  are the consumer's address with each of its `oauthRedirectPaths`. The address is the
  consumer's published name (`https://…`) when the proxy serves it, else
  `http://<vmname>.<zone>.internal:<proxyPort>`; a name published later moves them on the
  next update.
- **`/etc/secrets/forgejo-oauth.env`** on the consumer's VM: `FORGEJO_URL` (the address
  Forgejo builds its links from — its published name), `FORGEJO_CLIENT_ID`,
  `FORGEJO_CLIENT_SECRET`.
- The application belongs to the local Forgejo user the forgejo services act as
  (`tappaas-sites`, no admin rights). Forgejo shows a secret only once, so it is kept on
  tappaas-cicd (`/home/tappaas/secrets/forgejo-oauth-<vmname>.env`); a lost one is replaced.
- **Delete** removes the application (nobody can sign in to the consumer with Forgejo any
  more), the kept secret and the consumer's file.

## How to use it

```json
"dependsOn": ["network:proxy", "forgejo:oauth"],
"config": { "forgejo:oauth": { "oauthRedirectPaths": ["/authorize"] } }
```

The consumer reaches Forgejo at `FORGEJO_URL`, through the firewall's Caddy like a browser
does; no pinhole is needed.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`forgejo:oauth` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `oauthRedirectPaths`

The paths on the consumer's address Forgejo may redirect to after a sign-in (the OAuth2 redirect URIs, without the address). The address is the consumer's published name (https) when the proxy serves it, else <vmname>.<zone>.internal:<proxyPort>.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `/authorize` |
| Required by | `forgejo:oauth` |
| Used by | `forgejo:oauth` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Set by the consumer's module JSON (Woodpecker's is /authorize); an operator rarely changes it.

**Why this change class.** Moves the application's redirect URIs; Forgejo gives the application a new secret, written to the consumer's VM.

<!-- END GENERATED FIELDS -->
