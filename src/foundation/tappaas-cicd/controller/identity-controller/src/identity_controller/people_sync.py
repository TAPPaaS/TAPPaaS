"""People-sync reconcile engine for TAPPaaS (ADR-007 P1, "S2b-2").

Reconciles a ``config/people/`` directory (roles / organizations / groups /
users JSON) into a running Authentik instance, implementing EXACTLY the three
sync concerns from ADR-007 §"Sync semantics":

  (1) **Entity existence** — additive & non-destructive. A managed entity that
      is missing is created (ensure-exists); one that exists but whose
      *attributes* differ (displayName / email) is **not** overwritten — a
      WARNING is emitted instead. Removing a user file is **not** a delete.

  (2) **Access reconciliation** (managed ``active`` users) — group membership
      and role assignment are *authoritative*: links present in the JSON but
      missing in Authentik are ADDED, and managed links in Authentik but no
      longer in the JSON are REMOVED. Removal is **scoped to the managed set**:
      a user's membership in a FOREIGN group (one not in ``config/people/``) is
      never removed.

  (3) **User lifecycle** (``state``) —
        planned    → not created (no Authentik presence)
        active     → present; memberships + roles reconciled per (2)
        suspended  → account retained but DISABLED and stripped of all roles +
                     role-conferring managed group memberships
        terminated → REMOVED from Authentik (the single governed deletion)

SAFETY: every destructive action (membership-remove, role-remove, suspend,
terminate) is gated on the entity being in the *managed set* — the exact set of
names present in the loaded config. A foreign Authentik user / group / role is
never modified, disabled, deleted, or flagged as drift. If it is uncertain
whether an entity is managed, it is treated as foreign (left alone).

Roles reach a user two ways — inherited via a Group's ``roles`` or assigned
directly on the User's ``roles`` — and a user holds the *union*. In Authentik
these are reconciled separately (group.roles for inheritance, user direct
roles), which together realise the union.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from .authentik_manager import AuthentikManager


# ── config model ────────────────────────────────────────────────────────────


@dataclass
class Role:
    name: str
    displayName: str = ""
    description: str = ""


@dataclass
class Organization:
    name: str
    displayName: str = ""
    type: str = "company"
    owner: str = ""
    parentOrg: str | None = None


@dataclass
class Group:
    name: str
    displayName: str = ""
    type: str = "team"
    ownerOrg: str = ""
    roles: list[str] = field(default_factory=list)


@dataclass
class User:
    name: str
    displayName: str = ""
    primaryEmail: str = ""
    state: str = "active"
    memberOf: list[str] = field(default_factory=list)
    roles: list[str] = field(default_factory=list)


@dataclass
class PeopleConfig:
    """The loaded, typed config. The *managed set* is exactly these names."""

    roles: dict[str, Role] = field(default_factory=dict)
    organizations: dict[str, Organization] = field(default_factory=dict)
    groups: dict[str, Group] = field(default_factory=dict)
    users: dict[str, User] = field(default_factory=dict)


# ── plan model ───────────────────────────────────────────────────────────────


@dataclass
class Plan:
    """A structured, side-effect-free description of what ``apply`` would do.

    Every list is named for an Authentik primitive. The mock tests assert on
    this object directly, so its shape is part of the engine's contract.
    """

    # (1) existence (ensure-exists creates)
    create_roles: list[str] = field(default_factory=list)
    create_groups: list[str] = field(default_factory=list)
    create_users: list[str] = field(default_factory=list)

    # (2) access reconciliation (per user / per group)
    membership_adds: list[tuple[str, str]] = field(default_factory=list)     # (user, group)
    membership_removes: list[tuple[str, str]] = field(default_factory=list)  # (user, group) — managed only
    user_role_adds: list[tuple[str, str]] = field(default_factory=list)      # (user, role) — direct
    user_role_removes: list[tuple[str, str]] = field(default_factory=list)   # (user, role) — direct, managed only
    group_role_adds: list[tuple[str, str]] = field(default_factory=list)     # (group, role)
    group_role_removes: list[tuple[str, str]] = field(default_factory=list)  # (group, role) — managed only

    # (3) lifecycle
    suspends: list[str] = field(default_factory=list)      # users disabled + stripped
    terminations: list[str] = field(default_factory=list)  # users deleted (governed)

    # advisory
    drift_warnings: list[str] = field(default_factory=list)  # attribute drift — never auto-fixed
    skipped_foreign: list[str] = field(default_factory=list)  # foreign entities observed, left alone
    skipped_planned: list[str] = field(default_factory=list)  # planned users — no Authentik presence
    notes: list[str] = field(default_factory=list)            # informational (e.g. orgs)

    def is_empty(self) -> bool:
        """True when applying the plan would change nothing in Authentik.

        Drift warnings / skipped-foreign / notes are advisory and do NOT count
        as changes — an idempotent re-run carries them but mutates nothing.
        """
        return not any((
            self.create_roles, self.create_groups, self.create_users,
            self.membership_adds, self.membership_removes,
            self.user_role_adds, self.user_role_removes,
            self.group_role_adds, self.group_role_removes,
            self.suspends, self.terminations,
        ))


# ── current Authentik state (read once, planned against) ─────────────────────


@dataclass
class AuthentikState:
    """A snapshot of the relevant Authentik state, keyed for planning.

    Roles/groups/users keyed by NAME (username for users). Each value is the raw
    Authentik row; we read out the fields we reconcile.
    """

    roles: dict[str, dict] = field(default_factory=dict)   # name -> row
    groups: dict[str, dict] = field(default_factory=dict)  # name -> row
    users: dict[str, dict] = field(default_factory=dict)   # username -> row

    @classmethod
    def fetch(cls, mgr: AuthentikManager) -> "AuthentikState":
        roles = {r["name"]: r for r in mgr.roles_list()}
        groups = {g["name"]: g for g in mgr.groups_list()}
        users = {u["username"]: u for u in mgr.users_list()}
        return cls(roles=roles, groups=groups, users=users)


# ── the engine ───────────────────────────────────────────────────────────────


class PeopleSync:
    """Load people config, plan a reconcile against Authentik, optionally apply.

    ``plan()`` is the pure decision step the mock tests exercise; ``apply()``
    turns a plan into AuthentikManager calls; ``sync()`` wires load → fetch →
    plan → (apply) together.
    """

    def __init__(self, mgr: AuthentikManager):
        self.mgr = mgr

    # ── load ─────────────────────────────────────────────────────────────

    @staticmethod
    def _load_dir(d: Path) -> list[dict]:
        if not d.is_dir():
            return []
        out = []
        for f in sorted(d.glob("*.json")):
            out.append(json.loads(f.read_text()))
        return out

    @classmethod
    def load_config(cls, config_dir: str | Path) -> PeopleConfig:
        """Read roles/organizations/groups/users JSON into typed dicts.

        The managed set is exactly the entity *names* present in these files.
        Unknown JSON keys are ignored (forward-compat with schema additions).
        """
        base = Path(config_dir)
        cfg = PeopleConfig()

        for raw in cls._load_dir(base / "roles"):
            r = Role(
                name=raw["name"],
                displayName=raw.get("displayName", ""),
                description=raw.get("description", ""),
            )
            cfg.roles[r.name] = r

        for raw in cls._load_dir(base / "organizations"):
            o = Organization(
                name=raw["name"],
                displayName=raw.get("displayName", ""),
                type=raw.get("type", "company"),
                owner=raw.get("owner", ""),
                parentOrg=raw.get("parentOrg"),
            )
            cfg.organizations[o.name] = o

        for raw in cls._load_dir(base / "groups"):
            g = Group(
                name=raw["name"],
                displayName=raw.get("displayName", ""),
                type=raw.get("type", "team"),
                ownerOrg=raw.get("ownerOrg", ""),
                roles=list(raw.get("roles", [])),
            )
            cfg.groups[g.name] = g

        for raw in cls._load_dir(base / "users"):
            u = User(
                name=raw["name"],
                displayName=raw.get("displayName", ""),
                primaryEmail=raw.get("primaryEmail", ""),
                state=raw.get("state", "active"),
                memberOf=list(raw.get("memberOf", [])),
                roles=list(raw.get("roles", [])),
            )
            cfg.users[u.name] = u

        return cfg

    # ── plan ─────────────────────────────────────────────────────────────

    def plan(self, cfg: PeopleConfig, state: AuthentikState) -> Plan:
        """Compute the reconcile actions WITHOUT applying them.

        Pure function of (cfg, state) — no Authentik calls. This is the heart of
        the engine and what the offline mock tests assert against.
        """
        p = Plan()

        # Stash the fetched state rows on cfg so the name↔pk helpers can resolve
        # group/role pks back to names (works whether called via plan() directly
        # — as the mock tests do — or via sync()).
        cfg._state_group_rows = state.groups   # type: ignore[attr-defined]
        cfg._state_role_rows = state.roles     # type: ignore[attr-defined]

        managed_role_names = set(cfg.roles)
        managed_group_names = set(cfg.groups)
        managed_user_names = set(cfg.users)

        # Organizations have no Authentik primitive in this controller (they map
        # to brands/tenants, out of scope for the people reconcile). Record them
        # so the plan is transparent, but never create/modify anything for them.
        for name in cfg.organizations:
            p.notes.append(f"organization '{name}': no Authentik object reconciled (config-only)")

        # ── (1) existence: roles ──────────────────────────────────────────
        for name in cfg.roles:
            if name not in state.roles:
                p.create_roles.append(name)
            # roles carry no reconcilable attributes beyond name → no drift check

        # ── (1) existence + (2) group.roles inheritance ───────────────────
        # group→role pk lookup helper (managed roles only; resolved post-create)
        role_pk = {n: r.get("pk") for n, r in state.roles.items()}

        for name, g in cfg.groups.items():
            existing = state.groups.get(name)
            if existing is None:
                p.create_groups.append(name)
                # All managed roles on a to-be-created group are "adds".
                for rn in self._managed(g.roles, managed_role_names):
                    p.group_role_adds.append((name, rn))
                continue
            # attribute drift (displayName) — warn, never overwrite.
            # Authentik core group has no displayName field; we stash ours under
            # attributes.displayName at create time and drift-check against that.
            self._maybe_warn_attr(
                p, "group", name, "displayName",
                want=g.displayName,
                have_raw=(existing.get("attributes") or {}).get("displayName"),
            )
            # (2) reconcile group's role set (authoritative, managed-scoped)
            want_roles = set(self._managed(g.roles, managed_role_names))
            have_roles = self._group_managed_role_names(existing, role_pk, managed_role_names)
            for rn in sorted(want_roles - have_roles):
                p.group_role_adds.append((name, rn))
            for rn in sorted(have_roles - want_roles):
                p.group_role_removes.append((name, rn))

        # ── (1) existence + (3) lifecycle + (2) access: users ─────────────
        for name, u in cfg.users.items():
            if u.state == "planned":
                p.skipped_planned.append(name)
                # planned → no Authentik presence. We do NOT create, and we do
                # NOT touch an account even if one somehow exists (existence is
                # additive; we never implicitly delete). Nothing to plan.
                continue

            existing = state.users.get(name)

            if u.state == "terminated":
                # the one governed deletion — only if it actually exists
                if existing is not None:
                    p.terminations.append(name)
                continue

            if existing is None:
                # ensure-exists (active or suspended both materialise an account)
                p.create_users.append(name)

            else:
                # attribute drift (displayName / email) — warn, never overwrite
                self._maybe_warn_attr(
                    p, "user", name, "displayName",
                    want=u.displayName, have_raw=existing.get("name"),
                )
                self._maybe_warn_attr(
                    p, "user", name, "email",
                    want=u.primaryEmail, have_raw=existing.get("email"),
                )

            if u.state == "suspended":
                self._plan_suspend(p, name, u, existing, cfg, managed_group_names, managed_role_names)
                continue

            # state == active → full access reconciliation (2)
            self._plan_active_access(
                p, name, u, existing, cfg, managed_group_names, managed_role_names,
            )

        # ── foreign entities: observe, never touch, never warn ────────────
        for name in sorted(set(state.roles) - managed_role_names):
            p.skipped_foreign.append(f"role:{name}")
        for name in sorted(set(state.groups) - managed_group_names):
            p.skipped_foreign.append(f"group:{name}")
        for name in sorted(set(state.users) - managed_user_names):
            p.skipped_foreign.append(f"user:{name}")

        return p

    # ── planning helpers ──────────────────────────────────────────────────

    @staticmethod
    def _managed(names: list[str], managed: set[str]) -> list[str]:
        """Filter ``names`` to the managed set (preserve order, dedupe)."""
        seen: set[str] = set()
        out = []
        for n in names:
            if n in managed and n not in seen:
                seen.add(n)
                out.append(n)
        return out

    @staticmethod
    def _maybe_warn_attr(p: Plan, kind: str, name: str, attr: str, *,
                         want, have_raw, have=None) -> None:
        """Emit a drift warning if a managed entity's attribute differs.

        Only warns when BOTH sides are non-empty and differ — a blank desired
        value (or a brand-new entity) is not drift. Never mutates Authentik.
        """
        cur = have_raw if have_raw is not None else have
        if want and cur and want != cur:
            p.drift_warnings.append(
                f"{kind} '{name}': {attr} drift — config={want!r} authentik={cur!r} "
                "(NOT overwritten)"
            )

    @staticmethod
    def _group_managed_role_names(group_row: dict, role_pk: dict[str, str],
                                  managed_roles: set[str]) -> set[str]:
        """The names of *managed* roles currently attached to an Authentik group.

        Authentik stores group.roles as a list of role pks; map back to names and
        keep only managed ones (so we never plan to remove a foreign role)."""
        pk_to_name = {pk: n for n, pk in role_pk.items() if pk is not None}
        have = set()
        for rpk in group_row.get("roles", []) or []:
            n = pk_to_name.get(rpk)
            if n is not None and n in managed_roles:
                have.add(n)
        return have

    def _plan_active_access(self, p: Plan, name: str, u: User, existing: dict | None,
                            cfg: PeopleConfig, managed_groups: set[str],
                            managed_roles: set[str]) -> None:
        """Concern (2): reconcile a managed ACTIVE user's memberships + direct roles.

        Bidirectional, but removal is scoped to managed links only.
        """
        # ── group membership ──────────────────────────────────────────────
        want_groups = set(self._managed(u.memberOf, managed_groups))
        have_groups = self._user_managed_group_names(existing, cfg, managed_groups)
        for gn in sorted(want_groups - have_groups):
            p.membership_adds.append((name, gn))
        for gn in sorted(have_groups - want_groups):
            # only managed groups are eligible for removal (scope guard)
            p.membership_removes.append((name, gn))

        # ── direct roles (User.roles) ─────────────────────────────────────
        want_roles = set(self._managed(u.roles, managed_roles))
        have_roles = self._user_managed_direct_role_names(existing, cfg, managed_roles)
        for rn in sorted(want_roles - have_roles):
            p.user_role_adds.append((name, rn))
        for rn in sorted(have_roles - want_roles):
            p.user_role_removes.append((name, rn))

    def _plan_suspend(self, p: Plan, name: str, u: User, existing: dict | None,
                      cfg: PeopleConfig, managed_groups: set[str],
                      managed_roles: set[str]) -> None:
        """Concern (3) suspended: disable + strip all roles + role-conferring
        managed group memberships. Foreign / non-role managed groups are kept.
        """
        p.suspends.append(name)

        if existing is None:
            # account was just created above; nothing to strip yet, but the
            # apply step will disable it and leave it empty.
            return

        # remove the user from every MANAGED group that confers a role
        have_groups = self._user_managed_group_names(existing, cfg, managed_groups)
        for gn in sorted(have_groups):
            g = cfg.groups.get(gn)
            if g and self._managed(g.roles, managed_roles):
                p.membership_removes.append((name, gn))

        # strip all managed DIRECT roles
        have_roles = self._user_managed_direct_role_names(existing, cfg, managed_roles)
        for rn in sorted(have_roles):
            p.user_role_removes.append((name, rn))

    @staticmethod
    def _user_managed_group_names(user_row: dict | None, cfg: PeopleConfig,
                                  managed_groups: set[str]) -> set[str]:
        """Names of *managed* groups the Authentik user is currently in.

        Maps the user's group pks back to names via the (managed) group rows we
        already fetched; foreign group memberships are intentionally dropped so
        they are never planned for removal."""
        if not user_row:
            return set()
        # build pk->name only for managed groups present in state
        pk_to_name = {}
        for gn in managed_groups:
            row = cfg._state_group_rows.get(gn) if hasattr(cfg, "_state_group_rows") else None
            if row and row.get("pk") is not None:
                pk_to_name[row["pk"]] = gn
        have = set()
        for gpk in user_row.get("groups", []) or []:
            n = pk_to_name.get(gpk)
            if n is not None:
                have.add(n)
        return have

    @staticmethod
    def _user_managed_direct_role_names(user_row: dict | None, cfg: PeopleConfig,
                                        managed_roles: set[str]) -> set[str]:
        if not user_row:
            return set()
        pk_to_name = {}
        for rn in managed_roles:
            row = cfg._state_role_rows.get(rn) if hasattr(cfg, "_state_role_rows") else None
            if row and row.get("pk") is not None:
                pk_to_name[row["pk"]] = rn
        have = set()
        for rpk in user_row.get("roles", []) or []:
            n = pk_to_name.get(rpk)
            if n is not None:
                have.add(n)
        return have

    # ── apply ─────────────────────────────────────────────────────────────

    def apply(self, cfg: PeopleConfig, plan: Plan) -> None:
        """Execute the plan via AuthentikManager primitives.

        Order matters: roles → groups (+ their roles) → users (create) →
        membership/role reconcile → suspends → terminations. Everything here is
        already managed-scoped because the plan only contains managed names.
        """
        mgr = self.mgr

        # (1) roles first (groups/users reference them)
        for rn in plan.create_roles:
            mgr.role_ensure(rn)

        # (1) groups (store displayName under attributes so we can drift-check it)
        for gn in plan.create_groups:
            g = cfg.groups[gn]
            mgr.group_ensure(gn, attributes={"displayName": g.displayName} if g.displayName else None)

        # (2) group → role sets (authoritative replace, managed-scoped)
        touched_groups = {g for g, _ in plan.group_role_adds} | {g for g, _ in plan.group_role_removes}
        touched_groups |= set(plan.create_groups)
        for gn in sorted(touched_groups):
            g = cfg.groups.get(gn)
            if g is not None:
                mgr.group_set_roles(gn, list(g.roles))

        # (1) users (create active/suspended accounts; never planned/terminated)
        for un in plan.create_users:
            u = cfg.users[un]
            mgr.user_ensure(un, email=u.primaryEmail, name=u.displayName or None)

        # (3) suspends — disable, then the membership/role removes below strip them
        for un in plan.suspends:
            mgr.user_set_active(un, False)

        # (2)/(3) membership reconcile — apply each managed add/remove with the
        # ADDITIVE primitives so FOREIGN memberships are inherently preserved
        # (the plan only ever names managed groups, so these never touch foreign
        # links — the scope guard is structural).
        adds_by_user: dict[str, list[str]] = {}
        removes_by_user: dict[str, list[str]] = {}
        for un, gn in plan.membership_adds:
            adds_by_user.setdefault(un, []).append(gn)
        for un, gn in plan.membership_removes:
            removes_by_user.setdefault(un, []).append(gn)
        for un in sorted(adds_by_user):
            mgr.user_add_to_groups(un, adds_by_user[un])
        for un in sorted(removes_by_user):
            mgr.user_remove_from_groups(un, removes_by_user[un])

        # (2)/(3) direct role reconcile — authoritative final set per user
        # (Authentik's user.roles is a flat list; we set it to the union target).
        users_with_role_change = {u for u, _ in plan.user_role_adds} | {u for u, _ in plan.user_role_removes}
        for un in sorted(users_with_role_change):
            target = self._final_direct_roles(cfg, plan, un)
            mgr.user_set_roles(un, target)

        # (3) terminations — the one governed deletion, last
        for un in plan.terminations:
            mgr.user_delete(un)

    def _final_direct_roles(self, cfg: PeopleConfig, plan: Plan, username: str) -> list[str]:
        """Final MANAGED direct-role set for a user (empty when suspended).

        NB: ``AuthentikManager.user_set_roles`` replaces the user's direct-role
        list. Direct user roles are "use sparingly" per ADR-007 and are treated
        as wholly managed; foreign direct-role pks are not preserved (foreign
        access is expected to come through groups, which ARE preserved)."""
        u = cfg.users[username]
        if u.state == "suspended":
            return []
        return sorted(set(self._managed(u.roles, set(cfg.roles))))

    # ── sync (load → fetch → plan → apply) ────────────────────────────────

    def sync(self, config_dir: str | Path, *, dry_run: bool = False) -> Plan:
        """Full reconcile: load config, fetch Authentik, plan, optionally apply.

        Returns the computed Plan (also printed). With ``dry_run=True`` nothing
        is changed in Authentik — only ``users_list``/``groups_list``/
        ``roles_list`` reads happen (via the state fetch).
        """
        cfg = self.load_config(config_dir)
        state = AuthentikState.fetch(self.mgr)
        plan = self.plan(cfg, state)  # plan() stashes state rows on cfg
        if not dry_run:
            self.apply(cfg, plan)
        return plan


# ── plan rendering ────────────────────────────────────────────────────────────


def format_plan(plan: Plan, *, dry_run: bool) -> str:
    """Human-readable summary of a plan (used by the CLI)."""
    lines: list[str] = []
    head = "DRY-RUN (no changes applied)" if dry_run else "reconcile plan"
    lines.append(f"==> people-sync {head}")

    def section(title: str, items: list, fmt) -> None:
        if items:
            lines.append(f"  {title} ({len(items)}):")
            for it in items:
                lines.append(f"    {fmt(it)}")

    section("create roles", plan.create_roles, lambda x: x)
    section("create groups", plan.create_groups, lambda x: x)
    section("create users", plan.create_users, lambda x: x)
    section("membership add", plan.membership_adds, lambda t: f"{t[0]} → {t[1]}")
    section("membership remove", plan.membership_removes, lambda t: f"{t[0]} ✗ {t[1]}")
    section("user role add", plan.user_role_adds, lambda t: f"{t[0]} → {t[1]}")
    section("user role remove", plan.user_role_removes, lambda t: f"{t[0]} ✗ {t[1]}")
    section("group role add", plan.group_role_adds, lambda t: f"{t[0]} → {t[1]}")
    section("group role remove", plan.group_role_removes, lambda t: f"{t[0]} ✗ {t[1]}")
    section("suspend", plan.suspends, lambda x: x)
    section("terminate", plan.terminations, lambda x: x)
    section("DRIFT (warning, not changed)", plan.drift_warnings, lambda x: x)
    section("skipped planned", plan.skipped_planned, lambda x: x)
    section("skipped foreign (left untouched)", plan.skipped_foreign, lambda x: x)
    section("notes", plan.notes, lambda x: x)

    if plan.is_empty():
        lines.append("  (no changes — Authentik already matches config)")
    return "\n".join(lines)
