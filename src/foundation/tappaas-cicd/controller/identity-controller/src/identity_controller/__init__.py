"""Identity controller for TAPPaaS — Authentik runtime control.

Reconciles Authentik (users, groups, bindings, proxy/OIDC applications and the
embedded forward-auth outpost). Extracted from opnsense-controller (ADR-007
S2b-1); move + repackage only.
"""

from .authentik_manager import (
    AuthentikConfig,
    AuthentikManager,
    OidcApp,
    ProxyApp,
    EMBEDDED_OUTPOST_NAME,
    DEFAULT_AUTHORIZATION_FLOW_SLUG,
    DEFAULT_INVALIDATION_FLOW_SLUG,
)

__all__ = [
    "AuthentikConfig",
    "AuthentikManager",
    "OidcApp",
    "ProxyApp",
    "EMBEDDED_OUTPOST_NAME",
    "DEFAULT_AUTHORIZATION_FLOW_SLUG",
    "DEFAULT_INVALIDATION_FLOW_SLUG",
]
