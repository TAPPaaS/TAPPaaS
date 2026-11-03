// switchadd.ts — Add a switch's words and pure parts (pages/AddSwitch.tsx).

export const ADD_SWITCH_TEXT = "A switch the site's machines are cabled to: TAPPaaS programs its ports through a UniFi controller or RouterOS, or records one managed outside TAPPaaS and says what to set on it by hand.";

export type SwitchKind = "unifi-existing" | "unifi-install" | "mikrotik" | "manual";

export const SWITCH_KINDS: { id: SwitchKind; label: string; text: string }[] = [
  { id: "unifi-existing", label: "Register an existing UniFi controller", text: "A UniFi Network or UniFi OS controller that runs already: TAPPaaS logs in to it and reads every switch and access point it has adopted." },
  { id: "unifi-install", label: "Install a UniFi controller", text: "TAPPaaS installs UniFi OS Server on the cluster (the unifi-os module); you adopt the switches and access points in it, and TAPPaaS reads them from there." },
  { id: "mikrotik", label: "Add a MikroTik RouterOS switch", text: "A CRS3xx or CRS5xx on RouterOS 7: TAPPaaS logs in to its API and programs the VLANs on its ports (the mikrotik module)." },
  { id: "manual", label: "A switch managed outside TAPPaaS", text: "TAPPaaS machines are cabled to it, but someone else sets its ports: TAPPaaS records it, and says which VLANs each of those ports needs." },
];

// The address part of a URL: what switch-manager records as the controller's.
export function hostOf(url: string): string {
  return url.replace(/^[a-z]+:\/\//i, "").replace(/[/:].*$/, "");
}

