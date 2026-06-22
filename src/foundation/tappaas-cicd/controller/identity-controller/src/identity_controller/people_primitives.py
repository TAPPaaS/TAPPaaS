"""Low-level Authentik PRIMITIVES for People (users/groups/roles/memberships).

S2b-2 — this is the layer the TypeScript ``people-manager`` calls. It contains
**primitives only**: each function does ONE thing on EXACTLY the entity named,
idempotent where natural (ensure = create-if-missing-else-noop). There is NO
reconcile policy, NO managed-set logic, NO lifecycle decisions here — all of
that lives in the people-manager (built later).

Role mapping (decision)
=======================
ADR-007a models a **Role** as a cross-cutting label "assignable to users,
directly or via group membership". We had two candidate Authentik mechanisms:

1. **RBAC roles** (``/api/v3/rbac/roles/``). Inspecting the LIVE identity VM
   showed Authentik's RBAC roles can ONLY be bound to **groups**
   (``group.roles``) — there is no direct user→role assignment endpoint. So an
   RBAC role can never be "assigned to a user directly", which ADR-007a
   explicitly requires. Rejected.

2. **Core groups marked as roles** (``/api/v3/core/groups/``). A Role becomes a
   regular Authentik group carrying the marker attribute
   ``attributes.tappaas.kind = "role"``. "Assign role to user" is then just
   adding the user to that group's membership (the user's ``groups`` field) —
   which works DIRECTLY on the user, satisfies ADR-007a, surfaces in the OIDC
   ``groups`` claim, and reuses the exact same membership mechanism as ordinary
   group membership. **Chosen.**

To keep the User model's two distinct concepts (``memberOf`` vs ``roles``)
cleanly separated in Authentik, role-groups are tagged with the marker and
ORDINARY group listings EXCLUDE them, while role listings return ONLY them. The
two therefore share Authentik's group-membership plumbing without their
namespaces colliding.

All functions take a connected :class:`AuthentikManager` and act on names. They
raise on API error (the CLI maps that to a non-zero exit + stderr message).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover - typing only
    from .authentik_manager import AuthentikManager


# Marker that distinguishes a "role" group from an ordinary group.
ROLE_MARKER_PATH = ("tappaas", "kind")
ROLE_MARKER_VALUE = "role"


def _is_role_group(group: dict) -> bool:
    attrs = group.get("attributes") or {}
    return (attrs.get("tappaas") or {}).get("kind") == ROLE_MARKER_VALUE


def _display_name(entity: dict) -> str:
    """Display name for a group/role. Authentik core groups have no separate
    display field, so we store it under ``attributes.tappaas.displayName`` and
    fall back to the group ``name``.
    """
    attrs = entity.get("attributes") or {}
    return (attrs.get("tappaas") or {}).get("displayName") or entity.get("name", "")


def _set_role_marker(attributes: dict | None, *, role: bool, display: str | None) -> dict:
    """Return a copy of ``attributes`` with the tappaas marker block set."""
    out = dict(attributes or {})
    tappaas = dict(out.get("tappaas") or {})
    if role:
        tappaas["kind"] = ROLE_MARKER_VALUE
    if display is not None:
        tappaas["displayName"] = display
    out["tappaas"] = tappaas
    return out


# ── listings ────────────────────────────────────────────────────────────

def list_users(mgr: "AuthentikManager") -> list[dict]:
    """Return all users as primitive dicts.

    Each: ``{name, active, email, displayName, groups:[name], roles:[name]}``.
    ``groups`` excludes role-marked groups; ``roles`` is exactly the
    role-marked groups the user is a member of.
    """
    role_pks = {g["pk"] for g in mgr.groups_list() if _is_role_group(g)}
    out: list[dict] = []
    for u in mgr.users_list():
        groups_obj = u.get("groups_obj") or []
        groups = [g["name"] for g in groups_obj if not _is_role_group(g)]
        roles = [g["name"] for g in groups_obj if _is_role_group(g)]
        # Defensive: if groups_obj is absent, fall back to pk membership.
        if not groups_obj and u.get("groups"):
            roles = []  # cannot resolve names without groups_obj
        out.append({
            "name": u.get("username"),
            "active": bool(u.get("is_active")),
            "email": u.get("email", ""),
            "displayName": u.get("name", ""),
            "groups": groups,
            "roles": roles,
        })
    return out


def list_groups(mgr: "AuthentikManager") -> list[dict]:
    """Return ordinary (non-role) groups as ``{name, displayName}``."""
    return [
        {"name": g["name"], "displayName": _display_name(g)}
        for g in mgr.groups_list()
        if not _is_role_group(g)
    ]


def list_roles(mgr: "AuthentikManager") -> list[dict]:
    """Return role-marked groups as ``{name, displayName}``."""
    return [
        {"name": g["name"], "displayName": _display_name(g)}
        for g in mgr.groups_list()
        if _is_role_group(g)
    ]


def get_user(mgr: "AuthentikManager", name: str) -> dict | None:
    """Return the primitive dict for one user, or ``None`` if absent."""
    for u in list_users(mgr):
        if u["name"] == name:
            return u
    return None


# ── users ───────────────────────────────────────────────────────────────

def ensure_user(
    mgr: "AuthentikManager",
    *,
    name: str,
    email: str,
    display: str,
    inactive: bool = False,
) -> dict:
    """Create the user if missing; do NOT modify attributes of an existing one.

    The ONLY field reconciled on an existing user is the active flag — it is
    forced to match ``not inactive`` (the manager owns enable/disable; attribute
    drift is the manager's warn-only concern, never silently overwritten here).
    Returns the primitive user dict.
    """
    want_active = not inactive
    existing = mgr.user_get(name)
    if existing is None:
        mgr._post_json("/core/users/", {  # noqa: SLF001
            "username": name,
            "name": display or name,
            "email": email,
            "type": "internal",
            "is_active": want_active,
            "path": "users",
            "groups": [],
        })
    elif bool(existing.get("is_active")) != want_active:
        mgr._patch_json(  # noqa: SLF001
            f"/core/users/{existing['pk']}/", {"is_active": want_active}
        )
    result = get_user(mgr, name)
    assert result is not None  # just ensured it exists
    return result


def disable_user(mgr: "AuthentikManager", name: str) -> dict:
    """Set ``is_active=False`` (idempotent). Raises if the user is absent."""
    existing = mgr.user_get(name)
    if existing is None:
        raise RuntimeError(f"user {name!r} not found")
    if existing.get("is_active"):
        mgr._patch_json(f"/core/users/{existing['pk']}/", {"is_active": False})  # noqa: SLF001
    result = get_user(mgr, name)
    assert result is not None
    return result


def delete_user(mgr: "AuthentikManager", name: str) -> bool:
    """Delete the user. Returns ``False`` if it was already absent (no-op)."""
    return mgr.user_delete(name)


# ── groups & roles (both are core groups; roles carry the marker) ─────────

def _ensure_group(
    mgr: "AuthentikManager",
    *,
    name: str,
    display: str,
    role: bool,
) -> dict:
    existing = mgr.group_get(name)
    if existing is None:
        attrs = _set_role_marker(None, role=role, display=display)
        created = mgr._post_json(  # noqa: SLF001
            "/core/groups/", {"name": name, "is_superuser": False, "attributes": attrs}
        )
        return created
    # Idempotent: ensure marker + displayName are present without clobbering
    # other operator-set attributes. Patch only when something would change.
    attrs = _set_role_marker(existing.get("attributes"), role=role, display=display)
    if attrs != (existing.get("attributes") or {}):
        return mgr._patch_json(f"/core/groups/{existing['pk']}/", {"attributes": attrs})  # noqa: SLF001
    return existing


def ensure_group(mgr: "AuthentikManager", *, name: str, display: str) -> dict:
    """Create the group if missing (idempotent). Returns ``{name, displayName}``."""
    g = _ensure_group(mgr, name=name, display=display, role=False)
    return {"name": g["name"], "displayName": _display_name(g)}


def ensure_role(mgr: "AuthentikManager", *, name: str, display: str) -> dict:
    """Create the role (a marked group) if missing (idempotent).

    Returns ``{name, displayName}``.
    """
    g = _ensure_group(mgr, name=name, display=display, role=True)
    return {"name": g["name"], "displayName": _display_name(g)}


# ── memberships (group) & role assignment (role-group) ────────────────────

def _membership(
    mgr: "AuthentikManager", *, user: str, group: str, add: bool, label: str
) -> dict:
    """Add/remove a user to/from a group by membership (idempotent)."""
    u = mgr.user_get(user)
    if u is None:
        raise RuntimeError(f"user {user!r} not found")
    g = mgr.group_get(group)
    if g is None:
        raise RuntimeError(f"{label} {group!r} not found")
    have = set(u.get("groups", []))
    if add and g["pk"] not in have:
        mgr._patch_json(  # noqa: SLF001
            f"/core/users/{u['pk']}/", {"groups": sorted(have | {g["pk"]})}
        )
    elif not add and g["pk"] in have:
        mgr._patch_json(  # noqa: SLF001
            f"/core/users/{u['pk']}/", {"groups": sorted(have - {g["pk"]})}
        )
    result = get_user(mgr, user)
    assert result is not None
    return result


def add_member(mgr: "AuthentikManager", *, user: str, group: str) -> dict:
    """Add the user to the group (idempotent)."""
    return _membership(mgr, user=user, group=group, add=True, label="group")


def remove_member(mgr: "AuthentikManager", *, user: str, group: str) -> dict:
    """Remove the user from the group (idempotent)."""
    return _membership(mgr, user=user, group=group, add=False, label="group")


def assign_role(mgr: "AuthentikManager", *, user: str, role: str) -> dict:
    """Assign the role to the user directly (membership of the role-group)."""
    return _membership(mgr, user=user, group=role, add=True, label="role")


def unassign_role(mgr: "AuthentikManager", *, user: str, role: str) -> dict:
    """Remove the role from the user (idempotent)."""
    return _membership(mgr, user=user, group=role, add=False, label="role")
