// site-decisions.ts — what a site adds to the central CVE decisions: whether a
// record's assumptions hold here, and the operator's acceptances.

import { ComponentRecord, SiteView } from "../../../lib/ts/src/cve-decisions";

export type SiteDecider = (unit: string, component: string, record: ComponentRecord | undefined, id: string) => SiteView;

export function siteDecisions(_configDir: string): SiteDecider {
  return () => ({});
}
