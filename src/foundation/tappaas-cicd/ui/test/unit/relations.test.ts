// relations.test.ts — the identity graph (web/src/relations.ts): one node per
// object, an edge per reference identity-manager records, and a reference to
// a missing object drawn as a node of its own.

import { identityGraph } from "../../web/src/relations";
import { check, done } from "./check";

const g = identityGraph({
  org: [{ name: "rossen", owner: "lars", parentOrg: null }, { name: "kids", parentOrg: "rossen", owner: "" }],
  group: [{ name: "users", ownerOrg: "rossen", roles: ["user"] }, { name: "authentik Admins", ownerOrg: "rossen", roles: [] }],
  user: [{ name: "lars", memberOf: ["users", "authentik Admins"], roles: ["admin", "user"] }, { name: "root", memberOf: ["ghosts"], roles: [] }],
  role: [{ name: "admin" }, { name: "user" }, { name: "root" }],
});
const has = (s: string, t: string, l: string) => g.edges.some((e) => e.source === s && e.target === t && e.label === l);
check(g.nodes.filter((n) => n.record !== null).length === 9, "one node per object");
check(has("org:rossen", "user:lars", "owner") && has("org:rossen", "org:kids", "parent of"), "an organization's owner and its parent");
check(has("org:rossen", "group:users", "owns") && has("group:users", "role:user", "grants"), "a group's ownerOrg and roles");
check(has("group:users", "user:lars", "member") && has("group:authentik Admins", "user:lars", "member") && has("user:lars", "role:admin", "has role"), "a user's memberOf and roles");
const ghost = g.nodes.find((n) => n.id === "group:ghosts");
check(ghost !== undefined && ghost.record === null && has("group:ghosts", "user:root", "member"), "a reference to a missing group is a node marked missing");
check(!g.edges.some((e) => e.source === "org:kids" && e.label === "owner"), "an empty owner draws nothing");
check(identityGraph({}).nodes.length === 0, "no records: an empty graph");

done("relations");
