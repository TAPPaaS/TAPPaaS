#!/usr/bin/env bash
#
# test-grafana-oidc.sh — Grafana's Authentik login, as a contract (ADR-006).
#
# Two claims, both checkable without a VM:
#
#   1. The provider appears ONLY where the site publishes Grafana. The redirect
#      URI is built from the public domain, so on a site with no proxyDomain
#      there is nothing Authentik could call back to — and `root_url` and
#      `cookie_secure` have to move with it, because a secure cookie over plain
#      http://logging.<zone>.internal:3000 is never stored and the login bounces
#      back to /login looking like a credentials problem.
#
#   2. logging-configure-oidc survives every state identity:identity can leave
#      it in: not yet wired (do nothing, let Grafana boot), wired but with no
#      discovery URI (fail loudly), wired properly (write the five files Grafana
#      reads through $__file{} and restart it).
#
# Needs nix to evaluate the module; exits 77 ("cannot run here") without it, as
# the tabletop sweep expects.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The module under test, from this suite's place in the tree.
LOGGING="$(cd "${HERE}/../../../logging" 2>/dev/null && pwd)"
[[ -n "${LOGGING}" && -f "${LOGGING}/logging.nix" ]] || {
    echo "logging.nix not found beside this suite — cannot run here."; exit 77; }

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (no '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

command -v nix-instantiate >/dev/null 2>&1 || {
    echo "nix-instantiate not found — this suite evaluates logging.nix and cannot run here."
    exit 77
}
command -v jq >/dev/null 2>&1 || { echo "jq not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/grafana-oidc.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# Two copies of the module: one as shipped (no proxyDomain), one as a site that
# publishes Grafana would have it after update-os.sh deployed its config.
cp -r "${LOGGING}" "${TMP}/unpub"
cp -r "${LOGGING}" "${TMP}/pub"
jq '. + {proxyDomain: "logging.example.org"}' "${LOGGING}/logging.json" > "${TMP}/pub/logging.json"

# ── 1. the provider follows the public domain ───────────────────────────────
cat > "${TMP}/ev.nix" <<'EOF'
let pkgs = import <nixpkgs> {};
    lib  = pkgs.lib;
    load = dir: import (dir + "/logging.nix")
                 { config = {}; inherit lib pkgs; modulesPath = ""; system = "x86_64-linux"; };
    g    = dir: (load dir).services.grafana.settings;
in {
  unpub_oauth  = (g ./unpub) ? "auth.generic_oauth";
  unpub_cookie = (g ./unpub).security.cookie_secure;
  unpub_root   = (g ./unpub).server ? root_url;
  pub_oauth    = (g ./pub) ? "auth.generic_oauth";
  pub_cookie   = (g ./pub).security.cookie_secure;
  pub_root     = (g ./pub).server.root_url;
  pub_cid      = (g ./pub)."auth.generic_oauth".client_id;
  pub_auth     = (g ./pub)."auth.generic_oauth".auth_url;
  pub_scopes   = (g ./pub)."auth.generic_oauth".scopes;
  pub_role     = (g ./pub)."auth.generic_oauth".role_attribute_path;
  # logging.json names logging-configure-oidc as its identity.configureService,
  # and identity:identity checks the unit is there. A contract stated in config
  # cannot hold only on sites that publish Grafana.
  # `? unit` is useless here: lib.mkIf still creates the attribute, and the
  # module system resolves it later. What distinguishes them is the wrapper —
  # a mkIf value carries _type = "if", an unconditional one does not.
  unpub_unit_conditional = (load ./unpub).systemd.services.logging-configure-oidc ? _type;
  pub_unit_conditional   = (load ./pub).systemd.services.logging-configure-oidc ? _type;
  # The placeholder is different: it exists only to satisfy the $__file{}
  # targets the provider block references, so it stays tied to publication.
  unpub_ph_conditional   = (load ./unpub).systemd.services.generate-logging-oidc-placeholder ? _type;
}
EOF
EV="$(cd "${TMP}" && nix-instantiate --eval --strict --json ev.nix 2>"${TMP}/ev.err")"
if [[ -z "${EV}" ]]; then
    echo "  FAIL: logging.nix did not evaluate"; sed 's/^/    /' "${TMP}/ev.err" | tail -5; exit 1
fi
j() { jq -r "$1" <<< "${EV}"; }

ck "unpublished: no Authentik provider"        "false" "$(j .unpub_oauth)"
ck "unpublished: the cookie stays non-secure"  "false" "$(j .unpub_cookie)"
ck "unpublished: root_url is left to Grafana"  "false" "$(j .unpub_root)"
ck "published: the Authentik provider appears" "true"  "$(j .pub_oauth)"
ck "published: the cookie is secure"           "true"  "$(j .pub_cookie)"
ck "published: root_url is the public domain"  "https://logging.example.org/" "$(j .pub_root)"
# The values Grafana must not have baked in: they are minted (client id) or
# belong to the site's own Authentik (endpoints), so both arrive via $__file{}.
ckin "the client id is read from a file"   "\$__file{/etc/secrets/logging-oidc-client-id}" "$(j .pub_cid)"
ckin "the auth endpoint is read from a file" "\$__file{/etc/secrets/logging-oidc-auth-url}" "$(j .pub_auth)"
ck   "no scope beyond what Authentik's profile already emits" "openid email profile" "$(j .pub_scopes)"
ckin "logging-admins maps to GrafanaAdmin" "logging-admins" "$(j .pub_role)"
ck "the configure unit is unconditional where published"       "false" "$(j .pub_unit_conditional)"
ck "…and where NOT — identity checks for it either way"       "false" "$(j .unpub_unit_conditional)"
ck "the placeholder stays tied to publication"                "true"  "$(j .unpub_ph_conditional)"

# ── 2. the configure unit, in each state identity can leave it in ───────────
SCRIPT="$(cd "${TMP}" && nix-build --no-out-link -E '
  let pkgs = import <nixpkgs> {}; lib = pkgs.lib;
      m = import ./pub/logging.nix { config = {}; inherit lib pkgs; modulesPath = ""; system = "x86_64-linux"; };
      s = m.systemd.services.logging-configure-oidc;
  in (s.content or s).serviceConfig.ExecStart' 2>"${TMP}/build.err" | tail -1)"
if [[ ! -x "${SCRIPT}" ]]; then
    echo "  FAIL: logging-configure-oidc did not build"; tail -5 "${TMP}/build.err" | sed 's/^/    /'
    echo "── ${PASS} passed, $((FAIL+1)) failed ──"; exit 1
fi
ck "the configure unit builds" "yes" "yes"

OUT="${TMP}/secrets"; mkdir -p "${OUT}"
run_cfg() { LOGGING_OIDC_ENV="$1" LOGGING_OIDC_SECRETS_DIR="${OUT}" "${SCRIPT}" 2>&1; }

# (a) identity has not wired this module — Grafana must still boot, so this is
#     a clean no-op, not a failure.
: > "${TMP}/empty.env"
out="$(run_cfg "${TMP}/empty.env")"; rc=$?
ck   "unwired: exits 0"                  0 "${rc}"
ckin "unwired: says why"                 "has not wired this module" "${out}"
ck   "unwired: writes nothing"           0 "$(find "${OUT}" -type f | wc -l | tr -d ' ')"

# (b) wired, but no discovery URI: the endpoints cannot be resolved and guessing
#     them would bake in Authentik's current URL layout.
printf 'OIDC_CLIENT_ID=abc\nOIDC_CLIENT_SECRET=shh\n' > "${TMP}/nodisc.env"
out="$(run_cfg "${TMP}/nodisc.env")"; rc=$?
[[ "${rc}" -ne 0 ]] && ck "no discovery URI: fails" ok ok || ck "no discovery URI: fails" ok "rc=${rc}"
ckin "…and names what is missing" "OIDC_DISCOVERY_URI" "${out}"

# (c) wired properly. curl reads the discovery document over file://, so the
#     happy path is exercised without an Authentik.
cat > "${TMP}/openid.json" <<'EOF'
{ "authorization_endpoint": "https://id.example.org/application/o/authorize/",
  "token_endpoint":         "https://id.example.org/application/o/token/",
  "userinfo_endpoint":      "https://id.example.org/application/o/userinfo/" }
EOF
printf 'OIDC_CLIENT_ID=the-client\nOIDC_CLIENT_SECRET=the-secret\nOIDC_DISCOVERY_URI=file://%s\n' \
    "${TMP}/openid.json" > "${TMP}/good.env"
out="$(run_cfg "${TMP}/good.env")"; rc=$?
ck "wired: exits 0"                   0 "${rc}"
ck "wired: writes all five files"     5 "$(find "${OUT}" -type f | wc -l | tr -d ' ')"
ck "wired: the client id is the minted one"  "the-client" "$(cat "${OUT}/logging-oidc-client-id" 2>/dev/null)"
ck "wired: the secret is the minted one"     "the-secret" "$(cat "${OUT}/logging-oidc-client-secret" 2>/dev/null)"
ck "wired: the endpoints come from the document, not from string surgery" \
   "https://id.example.org/application/o/authorize/" "$(cat "${OUT}/logging-oidc-auth-url" 2>/dev/null)"
ck "wired: the userinfo endpoint too" \
   "https://id.example.org/application/o/userinfo/" "$(cat "${OUT}/logging-oidc-api-url" 2>/dev/null)"
ck "wired: secrets are not world-readable" "600" "$(stat -c '%a' "${OUT}/logging-oidc-client-secret" 2>/dev/null || stat -f '%Lp' "${OUT}/logging-oidc-client-secret" 2>/dev/null)"

# (d) a discovery document that answers, but says nothing useful.
echo '{"issuer":"https://id.example.org"}' > "${TMP}/empty-doc.json"
printf 'OIDC_CLIENT_ID=a\nOIDC_CLIENT_SECRET=b\nOIDC_DISCOVERY_URI=file://%s\n' \
    "${TMP}/empty-doc.json" > "${TMP}/emptydoc.env"
out="$(run_cfg "${TMP}/emptydoc.env")"; rc=$?
[[ "${rc}" -ne 0 ]] && ck "a document with no endpoints fails" ok ok || ck "a document with no endpoints fails" ok "rc=${rc}"
ckin "…and says which endpoints it wanted" "userinfo" "${out}"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
