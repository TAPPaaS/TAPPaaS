# woodpecker — Woodpecker CI

Primary audience: TAPPaaS admin.

[Woodpecker CI](https://woodpecker-ci.org/) (Apache-2.0) runs the pipelines of the site's Forgejo
repositories: a push to a repository with a `.woodpecker/` folder runs the pipelines in it, in
containers, and Forgejo shows the result on the commit and the pull request.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| The web UI: pipelines, logs, secrets, repositories | anywhere, for members of the Authentik group `users` | `https://woodpecker.<domain>` (or its tile in Authentik) — then Login with Forgejo |
| Pipelines on every push, tag and pull request | — | `.woodpecker/*.yaml` in a Forgejo repository enabled in Woodpecker |
| Status on commits and pull requests | Forgejo | Woodpecker reports back to Forgejo |
| The Woodpecker CLI and API | from the site: `woodpecker.<zone>.internal:8000`; from outside, through the gate with an Authentik service account | a personal token from the UI (your user → Personal access token) |

## How it is built

- A NixOS VM in Forgejo's zone with the Woodpecker server and one agent (Woodpecker from the
  release's nixpkgs). The server serves the UI, the API and Forgejo's webhooks on port 8000;
  the agent connects to it on `127.0.0.1:9000` and is the only agent (users cannot register
  their own).
- **The Authentik gate** (`identity:accessControl`) is in front of the public name: a visitor
  signs in with Authentik first, and only members of `users` get through. Woodpecker has its
  own tile in Authentik. The route is open to the internet; the gate, not the network, decides.
- **Login with Forgejo** (`forgejo:oauth`). Forgejo gets an OAuth2 application for Woodpecker,
  and Woodpecker's VM its client. Forgejo signs in with Authentik, so a person signs in to
  Woodpecker with their site account; there are no Woodpecker passwords. Anyone with a Forgejo
  account may sign in and run the pipelines of the repositories they may write to. The
  administrators are the Forgejo usernames in `woodpeckerAdmins`.
- **Forgejo calls Woodpecker inside the zone** (webhooks to `woodpecker.<zone>.internal:8000`);
  Woodpecker calls Forgejo at its own address, like a browser. Neither passes the gate, and
  the agent is on the VM, so the gate stands only in front of people.
- **Pipelines run as Docker containers** on the VM, at most two workflows at a time. No plugin
  may run privileged, so a pipeline cannot take over the VM through Docker.
- **A pipeline reaches the internet, the site's DNS and Forgejo (to clone) — nothing else on
  the site's networks.** Pipelines run code from repositories; the VM refuses their traffic to
  every private address except those two (`woodpecker-egress`), so a pipeline cannot reach
  the site's other services, even in its own zone.
- Data: Woodpecker's database (repositories, pipelines, logs, secrets) on the VM's disk, in its
  backup. Docker images are pruned weekly.

### Making someone an administrator

```bash
module-manager module modify woodpecker --set 'woodpeckerAdmins=["lars"]'
```

The name is their Forgejo username.

## What is not included

- **Privileged plugins** (Docker-in-Docker image builds, `plugins/docker`). Allow one by name
  with `WOODPECKER_PLUGINS_PRIVILEGED` when it is needed; it gives that plugin root on the VM.
- **Agents that need KVM** (the TAPPaaS image builds, #415), and agents on other machines.
- **Pipelines that reach the site's own services** (a deploy step that calls another module):
  the fence refuses it; such a step belongs to the module's own update.

## Requirements

- 4 cores, 4 GB RAM, 64G thin disk (pipeline images and caches).
- Forgejo (`src/devops/forgejo`) installed.

## Dependencies

| Service | Why |
|---|---|
| `cluster:vm`, `templates:nixos` | the VM and its NixOS configuration |
| `backup:vm` | the VM and Woodpecker's database, backed up |
| `network:proxy` | `woodpecker.<domain>` through Caddy, open to the internet |
| `identity:accessControl` | the Authentik gate in front of it (group `users`) and its tile |
| `network:rules` | the firewall rules for port 8000 |
| `forgejo:oauth` | Login with Forgejo: the OAuth2 application and its client |
| `logging:logs` (optional) | the VM's logs in Loki |
