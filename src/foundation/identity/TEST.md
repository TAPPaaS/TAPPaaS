# identity — tests

## How to run
- Fast (offline + Authentik API assertions): `./test.sh` (optionally `./test.sh <vmname>`).
- Deep (live VM integration): `./test.sh --deep`.
- Commands default to `~/bin` (`authentik-manager`, `install-module.sh`, `delete-module.sh`); override for pre-deploy testing via `AUTHENTIK_MANAGER=…`, `INSTALL_MODULE=…`, `DELETE_MODULE=…`.
- Requires `~/.authentik-credentials.txt` (provides `url=` / `token=`); exits 2 (fatal) if missing or if Authentik is unreachable.

## Standard (fast) tests
- Section 1 — Connectivity: asserts `authentik-manager test` succeeds (can reach Authentik); fatal exit 2 otherwise.
- Section 2 — Role groups present: for each of `user`, `admin`, `root`, runs `group-ensure` then asserts the group exists in Authentik (`/core/groups/`). These are the people-manager-reconciled role groups.
- Section 3 — OIDC allow-list (offline grep of `services/identity/install-service.sh`):
  - asserts default `ALLOW_GROUPS=("users")` (the org membership group);
  - asserts no retired group names remain (`tappaas-installers`, `${PREFIX}-users`, `${PREFIX}-admins`);
  - asserts `install-service.sh` no longer invokes `roles-ensure`;
  - fails if `install-service.sh` is not found.

## Deep tests (live; --deep)
- Sections 6+7 install two throwaway fixture webserver VMs under `test-fixtures/` and verify the observable behavioural difference between the two identity modes. Skipped (with a warning, not a fail) if the default domain or `install-module.sh`/`delete-module.sh` are unavailable.
- Section 6 — forward-auth (`identity:accessControl`) GATES the webserver: installs `test-idfa`, asserts an unauthenticated `curl` is redirected to an Authentik login (Authentik markup present, app marker `tappaas-idfa-ok` withheld), asserts the Authentik proxy app `test-idfa` exists, then tears the VM down. Live resources: VM install/teardown via install-module, HTTPS through Caddy, Authentik API.
- Section 7 — OIDC (`identity:identity`) passthrough + provider + env delivery: installs `test-idoidc`, asserts Caddy passthrough (marker `tappaas-idoidc-ok` reachable, NOT gated), asserts the Authentik OIDC application, OAuth2/OpenID provider, and an access binding all exist, then SSHes into the VM (`tappaas@test-idoidc.srvWork.internal`) to assert the OIDC env was delivered (`client_id=` present in `/var/lib/test-idoidc/oidc-verified`) and configure-service ran. Discovery-document reachability from the VM is a warn-only check (split-horizon DNS tolerated). Tears the VM down. Live resources: VM install/teardown, Caddy, Authentik API, SSH into the fixture VM.
- Cleanup trap removes throwaway groups (`zzzmod-admins`, `test-idoidc-admins`) and, in deep mode, force-deletes `test-idfa`/`test-idoidc` as a safety net.

## Coverage notes
- Has a real `test.sh` with both fast and deep tiers — the best-covered of the four modules.
- Section 3 is a static grep of `install-service.sh` source, not a behavioural test — it verifies the allow-list literal is correct, not that Authentik actually enforces it (that is left to the deep tier).
- The legacy `roles-ensure.sh` variant-scope and `user.sh` lifecycle test tiers (formerly sections 4+5) were removed; role/user lifecycle is now owned by `people-manager` and is NOT exercised by this module's tests.
- Deep tier depends on a working install/delete pipeline, default domain config, Caddy, and split-horizon DNS; it self-skips rather than failing when prerequisites are absent, so a green fast run does NOT imply the live OIDC/forward-auth path was verified.
