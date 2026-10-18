# Woodpecker CI — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. The foundation: `cluster:vm`, `templates:nixos`, `backup:vm`, `network:proxy`,
   `network:rules`.
2. Forgejo (`src/devops/forgejo`), installed first (`module-manager add-stack devops` does
   that order).
3. A DNS name for Woodpecker under the environment's domain (`woodpecker.<domain>` by
   default), for sign-in from a browser.

## Install

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/devops/woodpecker
install-module.sh woodpecker
```

This creates the VM, applies its NixOS configuration (Docker, the server and the agent),
registers Woodpecker with Forgejo as an OAuth2 application, and publishes
`woodpecker.<domain>` to the site's internal zones.

## Post-install

1. Make yourself an administrator: `module-manager module modify woodpecker --set 'woodpeckerAdmins=["<forgejo username>"]'`.
2. Open `https://woodpecker.<domain>` and **Login** — Forgejo asks once to authorise
   Woodpecker.
3. **Add repository**, pick one, and push a `.woodpecker/ci.yaml`, for example:

   ```yaml
   steps:
     - name: hello
       image: docker.io/library/alpine:3.22
       commands:
         - echo "hello from $CI_REPO"
   ```

## Verification

```bash
./test.sh woodpecker
```

| Check | Expect |
|---|---|
| docker, the server, the agent, `woodpecker-egress` | active |
| the server's and the agent's `/healthz` | 200; gRPC on 127.0.0.1 only |
| `/authorize` | hands over to Forgejo |
| privileged plugins | none |
| a pipeline container | reaches the internet and Forgejo; refused by Forgejo's VM, which the VM reaches |
| `https://woodpecker.<domain>/healthz` | 200 through Caddy |

## Troubleshooting

**Login fails with "invalid redirect".** Woodpecker's address changed (a name published since
install): `module-manager module update woodpecker` moves the application's redirect URI.

**A push starts no pipeline.** In Forgejo, the repository's Settings → Webhooks shows the
delivery to Woodpecker and its answer.

**A step cannot reach a site service.** That is the fence (see README); the internet and
Forgejo are reachable.
