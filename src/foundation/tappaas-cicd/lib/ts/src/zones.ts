// zones.ts — constants of the zone model that more than one manager needs.
//
// CONTROL_PLANE_ZONE started in network-manager/src/archetypes.ts with the
// comment "encoded here rather than inline so the two checks cannot disagree
// about who is exempt". That instinct was right and the number of consumers has
// since grown past two — environment-manager needs the same answer for its own
// exemption — so it lives in the shared lib rather than being transcribed a
// second time. network-manager re-exports it, so its existing importers are
// unaffected.

// The management zone: TAPPaaS's control plane, tier 0.
//
// It is the standing exception to the zone-model invariants, because every one
// of them describes a boundary the control plane is defined to cross:
//
//   I1 (monotonic access-to) — mgmt reaches every zone for operational
//      visibility, which is by definition an upward edge from tier 0.
//   I2 (isolation floor)     — mgmt may list an isolated zone; nobody else may.
//   I5 (no zone-wide DMZ)    — mgmt keeps its full visibility list (ADR-021 D3b).
//   ADR-014 D1 service-zone  — an environment must bind a Service zone, because
//      a Client/IoT zone *consumes* one. The control plane is neither: the mgmt
//      environment's modules live in the mgmt zone, so it IS its own segment.
//
// There is exactly one control plane per site by construction, which is why the
// exemption is by NAME rather than by type: a second `type: Management` zone
// backing an environment would be a mistake, and naming the zone keeps that
// mistake reportable.
export const CONTROL_PLANE_ZONE = "mgmt";
