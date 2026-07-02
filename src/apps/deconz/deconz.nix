# Copyright (c) 2026 Gridtefy / TAPPaaS
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Zigbee gateway (deCONZ engine + diyHue Hue-bridge front-end)
# ============================================================================
# One VM = the Zigbee controller, offering TWO services:
#   - `zigbee`     (native)  : deCONZ REST+websocket  -> Home Assistant
#   - `hue-bridge` (emulated) : diyHue Hue API         -> free@home / SysAP
#
# deCONZ (Dresden Elektronik) is the SOLE Zigbee controller — owns the ConBee II,
# the network, the devices. Native nixpkgs service (services.deconz). BSD-3.
# diyHue has NO radio: it imports deCONZ's lights over the REST API and re-presents
# them as a GENUINE-grade Hue bridge (MAC-derived bridgeid + self-signed cert) —
# the validation that deCONZ's own thin emulation (modelid "deCONZ") cannot pass
# (researched: deCONZ-direct -> free@home is a documented dead end). diyHue is an
# API consumer only -> it never touches the Zigbee network -> migration is safe.
#
# Consumer paths:
#   HA   -> deCONZ native  (srvHome -> iotCloud, 8080/8443)   [richer: sensors/events]
#   SysAP-> diyHue         (intra-zone iotCloud, 80/443/1900) [f@h switches -> lights]
#   diyHue-> deCONZ        (localhost 8080/8443)              [internal]
# So deCONZ is internalised from the SysAP (only diyHue faces it); HA keeps its path.
# deCONZ retains iotCloud internet egress for Zigbee OTA bulb-firmware updates.
#
# Network: iotCloud zone (VMID 213, tappaas1). Ports: 22 (SSH),
#   8080/8443 (deCONZ, HA+diyHue), 80/443 + UDP 1900/2100/1982 (diyHue, SysAP).
# Hardware: ConBee II USB attached by update.sh (qm set -usb0 host=1cf1:0030).
# diyHue: no nixpkgs package (nixpkgs#374133) -> OCI container via podman.
# Backups: covered by the module's backup:vm dependency (full-VM PBS).
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning — bump here only. Pinned by DIGEST (not :latest) since the
  # diyHue deconz.py sleep-patch below is tied to the exact upstream file layout
  # of this image. Digest validated 2026-06-17 (free@home pairing + latency fix).
  # To upgrade: pull the new tag, re-verify lights/protocols/deconz.py still
  # matches the patched copy, then update this digest.
  versions = {
    diyhue = "sha256:97c4a5d21806bbdef110b95277c8f0c46d47ecfb65a161ed874ef177c6278bbd";
  };
  # diyHue bridge identity: bridgeid + self-signed cert derive from this MAC.
  # Start with the VM's own NIC MAC; if free@home is picky about the bridgeid,
  # switch to a Philips-OUI MAC (00:17:88:xx:xx:xx) — must NOT collide with the
  # real Hue bridge (00:17:88:6d:2c:22).
  diyhueMac = "02:dd:1a:88:a5:7e";
  diyhueIp  = "10.4.20.191";
in
{
  # ── IMPORTS ────────────────────────────────────────────────────────────────
  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # ── BOOT ─────────────────────────────────────────────────────────────────--
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # ── CLOUD-INIT ───────────────────────────────────────────────────────────--
  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # ── NETWORKING ───────────────────────────────────────────────────────────--
  networking.hostName = let
    cfg = if builtins.pathExists ./deconz.json
          then builtins.fromJSON (builtins.readFile ./deconz.json)
          else {};
  in lib.mkDefault (cfg.vmname or "deconz");
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      8080  # deCONZ REST + Phoscon UI (consumed by HA + diyHue@localhost)
      8443  # deCONZ websocket (HA deconz integration)
      80    # diyHue Hue API (SysAP / free@home)
      443   # diyHue Hue API TLS (genuine Hue-app/SysAP path)
    ];
    allowedUDPPorts = [
      1900  # SSDP discovery — diyHue advertises the bridge to the SysAP
      2100  # diyHue Hue Entertainment streaming
      1982  # diyHue
    ];
  };

  # ── TIME ─────────────────────────────────────────────────────────────────--
  time.timeZone = lib.mkDefault "UTC";

  # ── USERS & SECURITY ─────────────────────────────────────────────────────--
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "dialout" ];  # dialout = serial (ConBee)
  };
  security.sudo.wheelNeedsPassword = false;

  # ── PACKAGES ─────────────────────────────────────────────────────────────--
  environment.systemPackages = with pkgs; [
    vim wget curl htop git jq usbutils
  ];

  # ── NIX SETTINGS ─────────────────────────────────────────────────────────--
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
  nix.optimise = { automatic = true; dates = [ "weekly" ]; };

  # ── ESSENTIAL SERVICES ───────────────────────────────────────────────────--
  services.qemuGuest.enable = true;
  services.openssh = {
    enable = true;
    settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };
  };
  programs.ssh.startAgent = true;

  # ── deCONZ ─────────────────────────────────────────────────────────────────
  # The ConBee II is attached to this VM by update.sh (qm set -usb0 host=1cf1:0030).
  # `device` MUST be a stable by-id path (NOT /dev/ttyACM0 — renumbers on replug).
  # TODO (deploy): confirm the exact by-id path on this VM with:
  #   ls -l /dev/serial/by-id/   (look for ...ConBee_II_<serial>-if00)
  services.deconz = {
    enable = true;
    device = "/dev/serial/by-id/usb-dresden_elektronik_ingenieurtechnik_GmbH_ConBee_II_DE2149039-if00";
    listenAddress = "0.0.0.0";  # bind all interfaces — HA reaches it cross-zone (srvHome->iotCloud)
                                # and diyHue reaches it on localhost. Default 127.0.0.1 (loopback-only)
                                # would break HA. SysAP no longer talks to deCONZ directly (diyHue fronts it);
                                # the SysAP->deCONZ pinhole is dropped at the module/firewall layer.
    httpPort = 8080;        # REST + Hue-compat API + Phoscon UI
    wsPort = 8443;          # websocket (HA deconz integration)
    openFirewall = false;   # firewall handled explicitly above
    allowRestartService = true;  # let the OTA/maintenance flow restart deCONZ via API
    # Disable deCONZ's own SSDP/UPnP: it's internalised (HA uses explicit IP, diyHue
    # uses localhost) and must NOT contend with diyHue for UDP 1900 / advertise a
    # duplicate Hue bridge at the same IP (the SysAP dedups by IP -> locks onto deCONZ).
    # Authoritative community fix for diyHue+deCONZ coexistence: deconz-rest-plugin#274 / #754.
    extraArgs = [ "--upnp=0" ];
  };

  # ── CONTAINER RUNTIME (podman) ───────────────────────────────────────────────
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ── diyHue — `hue-bridge` service (front-end for free@home / SysAP) ───────────
  # Genuine-grade Hue bridge in front of deCONZ. --network=host so SSDP (1900) +
  # the standard Hue ports (80/443) reach the SysAP intra-zone. Imports lights
  # from deCONZ over the REST API (configured post-start, see the link service
  # below) — never touches the ConBee/Zigbee network.
  virtualisation.oci-containers.containers.diyhue = {
    image = "docker.io/diyhue/core@${versions.diyhue}";
    extraOptions = [
      "--network=host"          # SSDP/mDNS + Hue ports 80/443/1900/2100/1982
      "--log-driver=journald"
    ];
    environment = {
      MAC   = diyhueMac;        # bridge identity (bridgeid + cert derive from this)
      IP    = diyhueIp;
      DEBUG = "false";
      # TZ MUST match diyHue's config.yaml `timezone` (and the user's browser tz),
      # else the Hue link-button timestamp check fails (press never registers ->
      # cannot pair the SysAP). RCA: container defaulted to UTC + config to Europe/London.
      TZ    = "Europe/Amsterdam";
    };
    volumes = [
      "/var/lib/diyhue:/opt/hue-emulator/config"
      # LATENCY PATCH (see environment.etc below): override the deconz protocol
      # adapter so on/off/dim is ~ms instead of 0.7s/light (group of 24: 0.1s vs 17s).
      "/etc/diyhue/deconz.py:/opt/hue-emulator/lights/protocols/deconz.py:ro"
      # GROUP ACTION FIX (see environment.etc below): patch genStreamEvent IndexError
      # when dead weakrefs cause enumerate() index to exceed actual list length.
      "/etc/diyhue/Group.py:/opt/hue-emulator/HueObjects/Group.py:ro"
    ];
  };

  systemd.tmpfiles.rules = [ "d /var/lib/diyhue 0750 root root -" ];

  # ── diyHue LATENCY PATCH — deconz protocol adapter ───────────────────────────
  # RCA 2026-06-17: upstream lights/protocols/deconz.py does an UNCONDITIONAL
  # `sleep(0.7)` after the state PUT, before an (often empty) colour PUT. It was
  # meant to let a lamp power on before a colour is applied, but it fires on EVERY
  # on/off/dim (the wall-switch path) even when no colour follows -> 1 light = 0.7s,
  # a 24-light group action = 24 x 0.7 = ~16.9s (diyHue iterates per-light; it does
  # NOT groupcast). MEASURED: single 0.707s->0.007s, group/0 16.9s->0.10s after the
  # fix; colour change stays 0.71s (delay preserved). The patched file is bind-
  # mounted over the image path above. Pinned digest (versions.diyhue) keeps the
  # upstream file layout stable. Upstream candidate: make the sleep conditional.
  environment.etc."diyhue/deconz.py".text = ''
    import json
    import logManager
    import requests
    from time import sleep
    logging = logManager.logger.get_logger(__name__)

    def _base(cfg):
        # TAPPaaS: protocol_cfg.deconzType == "group" -> target the deCONZ GROUP action
        # endpoint = ONE Zigbee groupcast (atomic, fast). Otherwise the per-light state
        # endpoint as upstream does. Lets a synthetic "group light" front a whole fixture.
        if cfg.get("deconzType") == "group":
            return "http://" + cfg["ip"] + "/api/" + cfg["deconzUser"] + "/groups/" + str(cfg["deconzId"]) + "/action"
        return "http://" + cfg["ip"] + "/api/" + cfg["deconzUser"] + "/lights/" + str(cfg["deconzId"]) + "/state"

    def set_light(light, data):
        url = _base(light.protocol_cfg)
        payload = {}
        payload.update(data)
        color = {}
        if "xy" in payload:
            color["xy"] = payload["xy"]
            del(payload["xy"])
        elif "ct" in payload:
            color["ct"] = payload["ct"]
            del(payload["ct"])
        elif "hue" in payload:
            color["hue"] = payload["hue"]
            del(payload["hue"])
        elif "sat" in payload:
            color["sat"] = payload["sat"]
            del(payload["sat"])
        if len(payload) != 0:
            requests.put(url, json=payload, timeout=3)
            if len(color) != 0:          # TAPPaaS: only wait when a colour PUT follows
                sleep(0.7)
        if len(color) != 0:
            requests.put(url, json=color, timeout=3)

    def get_light_state(light):
        cfg = light.protocol_cfg
        if cfg.get("deconzType") == "group":
            group = requests.get("http://" + cfg["ip"] + "/api/" + cfg["deconzUser"] + "/groups/" + str(cfg["deconzId"]), timeout=3).json()
            state = dict(group.get("action", {}))
            state["on"] = group.get("state", {}).get("any_on", False)
            state["reachable"] = True
            return state
        state = requests.get("http://" + cfg["ip"] + "/api/" + cfg["deconzUser"] + "/lights/" + cfg["deconzId"], timeout=3)
        return state.json()["state"]

    def discover(detectedLights, credentials):
        if "deconzUser" in credentials and credentials["deconzUser"] != "":
            logging.debug("deconz: <discover> invoked!")
            try:
                response = requests.get("http://" + credentials["deconzHost"] + ":" + str(credentials["deconzPort"]) + "/api/" + credentials["deconzUser"] + "/lights", timeout=3)
                if response.status_code == 200:
                    logging.debug(response.text)
                    lights = json.loads(response.text)
                    for id, light in lights.items():
                        modelid = "LCT015"
                        if light["type"] == "Dimmable light":
                            modelid = "LWB010"
                        elif light["type"] == "Color temperature light":
                            modelid = "LTW001"
                        elif light["type"] == "On/Off plug-in unit":
                            modelid = "LOM001"
                        elif light["type"] == "Color light":
                            modelid = "LLC010"
                        detectedLights.append({"protocol": "deconz", "name": light["name"], "modelid": modelid, "protocol_cfg": {"ip": credentials["deconzHost"] + ":" + str(credentials["deconzPort"]), "deconzUser": credentials["deconzUser"], "modelid": light["modelid"], "deconzId": id, "uniqueid": light["uniqueid"]}})
            except Exception as e:
                logging.info("Error connecting to Deconz: %s", e)
  '';

  # ── diyHue GROUP ACTION FIX — Group.py patch ─────────────────────────────────
  # RCA 2026-06-20: upstream HueObjects/Group.py:genStreamEvent() used
  # enumerate()+insert(num)+data[num].update() to build the SSE stream message.
  # When lights are pruned from diyHue their Group.lights weakrefs go dead; dead refs
  # are skipped (if light(): ...) but `num` keeps incrementing, so after the first skip
  # `num` exceeds the actual list length -> IndexError -> 500 {"message":"Internal
  # Server Error"} on any PUT /groups/0/action or PUT /groups/<id>/action.
  # Symptom: Hue Essentials showed "Onverwachte reactie van bridge" on group actions.
  # Fix: replace enumerate+insert(num)+data[num] with a plain for-loop+append+update —
  # same output, no index arithmetic, dead weakrefs simply skipped without side effects.
  # Upstream candidate: submit to diyHue/diyhue (GitHub).
  environment.etc."diyhue/Group.py".text = ''
    import uuid
    import logManager
    import weakref
    from datetime import datetime, timezone
    from HueObjects import genV2Uuid, v1StateToV2, v2StateToV1, setGroupAction, StreamEvent

    logging = logManager.logger.get_logger(__name__)

    class Group():

        def __init__(self, data):
            self.name = data["name"] if "name" in data else "Group " + \
                data["id_v1"]
            self.id_v1 = data["id_v1"]
            self.id_v2 = data["id_v2"] if "id_v2" in data else genV2Uuid()
            if "owner" in data:
                self.owner = data["owner"]
            self.icon_class = data["class"] if "class" in data else data["icon_class"] if "icon_class" in data else "Other"
            self.lights = []
            self.action = {"on": False, "bri": 100, "hue": 0, "sat": 254, "effect": "none", "xy": [
                0.0, 0.0], "ct": 153, "alert": "none", "colormode": "xy"}
            self.sensors = []
            self.type = data["type"] if "type" in data else "LightGroup"
            self.state = {"all_on": False, "any_on": False}
            self.dxState = {"all_on": None, "any_on": None}

            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [self.getV2Room() if self.type == "Room" else self.getV2Zone()],
                             "id": str(uuid.uuid4()),
                             "type": "add"
                             }
            StreamEvent(streamMessage)

        def groupZeroStream(self, rooms, lights):
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [{"children": [], "id": str(uuid.uuid5(uuid.NAMESPACE_URL, self.id_v2 + 'bridge_home')),  "id_v1":"/groups/0", "type": "bridge_home"}],
                             "id": str(uuid.uuid4()),
                             "type": "update"
                             }
            for room in rooms:
                streamMessage["data"][0]["children"].append(
                    {"rid": room, "rtype": "room"})
            for light in lights:
                streamMessage["data"][0]["children"].append(
                    {"rid": light, "rtype": "light"})
            StreamEvent(streamMessage)

        def __del__(self):
            # Groupper light
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [{"id": self.id_v2,  "id_v1": "/groups/" + self.id_v1, "type": "grouped_light"}],
                             "id": str(uuid.uuid4()),
                             "type": "delete"
                             }
            streamMessage["id_v1"] = "/groups/" + self.id_v1
            StreamEvent(streamMessage)
            ### room / zone ####
            elementId = self.getV2Room(
            )["id"] if self.type == "Room" else self.getV2Zone()["id"]
            elementType = "room" if self.type == "Room" else "zone"
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [{"id": elementId,  "id_v1": "/groups/" + self.id_v1, "type": elementType}],
                             "id": str(uuid.uuid4()),
                             "type": "delete"
                             }
            StreamEvent(streamMessage)
            logging.info(self.name + " group was destroyed.")

        def add_light(self, light):
            self.lights.append(weakref.ref(light))
            elementId = self.getV2Room(
            )["id"] if self.type == "Room" else self.getV2Zone()["id"]
            elementType = "room" if self.type == "Room" else "zone"
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [{"alert": {"action_values": ["breathe"]}, "id": self.id_v2, "id_v1": "/groups/" + self.id_v1, "on":{"on": self.action["on"]}, "type": "grouped_light", }],
                             "id": str(uuid.uuid4()),
                             "type": "add"
                             }
            StreamEvent(streamMessage)
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [{"grouped_services": [{"rid": self.id_v2, "rtype": "grouped_light"}], "id": elementId, "id_v1": "/groups/" + self.id_v1, "type": elementType}],
                             "id": str(uuid.uuid4()),
                             "type": "update"
                             }

            StreamEvent(streamMessage)
            groupChildrens = []
            groupServices = []
            for light in self.lights:
                if light():
                    groupChildrens.append(
                        {"rid": light().getDevice()["id"], "rtype": "device"})
                    groupServices.append({"rid": light().id_v2, "rtype": "light"})
            groupServices.append({"rid": self.id_v2, "rtype": "grouped_light"})
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [{"children": groupChildrens, "id": elementId, "id_v1": "/groups/" + self.id_v1, "services": groupServices, "type": elementType}],
                             "id": str(uuid.uuid4()),
                             "type": "update"
                             }
            StreamEvent(streamMessage)

        def add_sensor(self, sensor):
            self.sensors.append(weakref.ref(sensor))

        def update_attr(self, newdata):
            if "lights" in newdata:  # update of the lights must be done using add_light function
                del newdata["lights"]
            if "class" in newdata:
                newdata["icon_class"] = newdata.pop("class")
            for key, value in newdata.items():
                updateAttribute = getattr(self, key)
                if isinstance(updateAttribute, dict):
                    updateAttribute.update(value)
                    setattr(self, key, updateAttribute)
                else:
                    setattr(self, key, value)

            streamMessage = {"creationtime": datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [self.getV2Room() if self.type == "Room" else self.getV2Zone()],
                             "id": str(uuid.uuid4()),
                             "type": "update"
                             }
            StreamEvent(streamMessage)

        def update_state(self):
            all_on = True
            any_on = False
            bri = 0
            lights_on = 0
            if len(self.lights) == 0:
                all_on = False
            for light in self.lights:
                if light():
                    if light().state["on"]:
                        any_on = True
                        if "bri" in light().state:
                            bri = bri + light().state["bri"]
                            lights_on = lights_on + 1
                    else:
                        all_on = False
            if any_on:
                bri = (((bri/lights_on)/254)*100) if bri > 0 else 0
            return {"all_on": all_on, "any_on": any_on, "avr_bri": int(bri)}

        def setV2Action(self, state):
            v1State = v2StateToV1(state)
            setGroupAction(self, v1State)
            self.genStreamEvent(state)

        def setV1Action(self, state, scene=None):
            setGroupAction(self, state, scene)
            v2State = v1StateToV2(state)
            self.genStreamEvent(v2State)

        def genStreamEvent(self, v2State):
            # TAPPaaS fix 2026-06-20: upstream used enumerate()+insert(num)+data[num] which
            # crashes with IndexError when dead weakrefs are skipped (num advances past actual
            # list length). Replaced with append+inline update — dead refs are simply skipped.
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                   "data": [],
                                     "id": str(uuid.uuid4()),
                                     "type": "update"
                                     }
            for light in self.lights:
                if light():
                    item = {
                        "id": light().id_v2,
                        "id_v1": "/lights/" + light().id_v1,
                        "owner": {
                            "rid": light().getDevice()["id"],
                            "rtype": "device"
                        },
                        "service_id": light().protocol_cfg["light_nr"]-1 if "light_nr" in light().protocol_cfg else 0,
                        "type": "light"
                    }
                    item.update(v2State)
                    streamMessage["data"].append(item)
            StreamEvent(streamMessage)

            if "on" in v2State:
                v2State["dimming"] = {"brightness": self.update_state()["avr_bri"]}
            streamMessage = {"creationtime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "data": [{"id": self.id_v2,"id_v1": "/groups/" + self.id_v1, "type": "grouped_light",
                                       "owner": {
                                           "rid": self.getV2Room()["id"] if self.type == "Room" else self.getV2Zone()["id"],
                                           "rtype": "room" if self.type == "Room" else "zone"
                                       }
                                       }],
                             "id": str(uuid.uuid4()),
                             "type": "update"
                             }
            streamMessage["data"][0].update(v2State)
            StreamEvent(streamMessage)

        def getV1Api(self):
            result = {}
            result["name"] = self.name
            if hasattr(self, "owner"):
                result["owner"] = self.owner.username
            lights = []
            for light in self.lights:
                if light():
                    lights.append(light().id_v1)
            sensors = []
            for sensor in self.sensors:
                if sensor():
                    sensors.append(sensor().id_v1)
            result["lights"] = lights
            result["sensors"] = sensors
            result["type"] = self.type.capitalize()
            result["state"] = self.update_state()
            result["recycle"] = False
            if self.id_v1 == "0":
                result["presence"] = {
                    "state": {"presence": None, "presence_all": None, "lastupdated": "none"}}
                result["lightlevel"] = {"state": {"dark": None, "dark_all": None, "daylight": None, "daylight_any": None,
                                                  "lightlevel": None, "lightlevel_min": None, "lightlevel_max": None, "lastupdated": "none"}}
            else:
                result["class"] = self.icon_class.capitalize() if len(self.icon_class) > 2 else self.icon_class.upper()
            result["action"] = self.action
            return result

        def getV2Room(self):
            result = {"children": [], "services": []}
            for light in self.lights:
                if light():
                    result["children"].append({
                        "rid": str(uuid.uuid5(
                            uuid.NAMESPACE_URL, light().id_v2 + 'device')),
                        "rtype": "device"
                    })

            #result["grouped_services"].append({
            #    "rid": self.id_v2,
            #    "rtype": "grouped_light"
            #})
            result["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, self.id_v2 + 'room'))
            result["id_v1"] = "/groups/" + self.id_v1
            result["metadata"] = {
                "archetype": self.icon_class.replace(" ", "_").replace("'", "").lower(),
                "name": self.name
            }
            for light in self.lights:
                if light():
                    result["services"].append({
                        "rid": light().id_v2,
                        "rtype": "light"
                    })

            result["services"].append({
                "rid": self.id_v2,
                "rtype": "grouped_light"
            })

            result["type"] = "room"
            return result

        def getV2Zone(self):
            result = {"children": [], "services": []}
            for light in self.lights:
                if light():
                    result["children"].append({
                        "rid": light().id_v2,
                        "rtype": "light"
                    })

            #result["grouped_services"].append({
            #    "rid": self.id_v2,
            #    "rtype": "grouped_light"
            #})
            result["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, self.id_v2 + 'zone'))
            result["id_v1"] = "/groups/" + self.id_v1
            result["metadata"] = {
                "archetype": self.icon_class.replace(" ", "_").replace("'", "").lower(),
                "name": self.name
            }
            for light in self.lights:
                if light():
                    result["services"].append({
                        "rid": light().id_v2,
                        "rtype": "light"
                    })

            result["services"].append({
                "rid": self.id_v2,
                "rtype": "grouped_light"
            })

            result["type"] = "zone"
            return result

        def getV2GroupedLight(self):
            result = {}
            result["alert"] = {
                "action_values": [
                    "breathe"
                ]
            }
            result["color"] = {}
            result["dimming"] = {"brightness": self.update_state()["avr_bri"]}
            result["dimming_delta"] = {}
            result["dynamics"] = {}
            result["id"] = self.id_v2
            result["id_v1"] = "/groups/" + self.id_v1
            result["on"] = {"on": self.update_state()["any_on"]}
            result["type"] = "grouped_light"
            if hasattr(self, "owner"):
                result["owner"] = {"rid": self.owner.username, "rtype": "device"}
            else:
                result["owner"] = {"rid": self.id_v2, "rtype": "device"}
            result["signaling"] = {"signal_values": [
                "no_signal",
                "on_off"]}

            return result

        def getObjectPath(self):
            return {"resource": "groups", "id": self.id_v1}

        def save(self):
            result = {"id_v2": self.id_v2, "name": self.name, "class": self.icon_class,
                      "lights": [], "action": self.action, "type": self.type}
            if hasattr(self, "owner"):
                result["owner"] = self.owner.username
            for light in self.lights:
                if light():
                    result["lights"].append(light().id_v1)
            return result
  '';

  # diyHue starts after deCONZ (its backend) is up.
  # restartTriggers: recreate the container when the bind-mounted adapter changes —
  # otherwise the running container keeps the OLD nix-store file resolved at create
  # time (changing environment.etc content alone does NOT restart an oci-container).
  systemd.services.podman-diyhue = {
    after = [ "deconz.service" ];
    requires = [ "deconz.service" ];
    restartTriggers = [
      config.environment.etc."diyhue/deconz.py".source
      config.environment.etc."diyhue/Group.py".source
    ];
  };

  # ── diyHue <- deCONZ backend link (authoritative method) ─────────────────────
  # diyHue config (persisted in the /var/lib/diyhue volume) `config.deconz`:
  #   deconzHost: 127.0.0.1   deconzPort: 8080   deconzUser: <deCONZ api-key>
  #   (websocketport is auto-fetched from deCONZ /config). Lights+sensors import;
  #   GROUPS are NOT imported (rooms are defined in free@home / diyHue, not deCONZ).
  # Out-of-the-box registration (diyHue docs): unlock the deCONZ gateway, then open
  #   http://<this-vm>/deconz  -> diyHue auto-registers + imports. The settings FORM
  #   is the flaky path (2s UI timeout) — use /deconz (or seed config.deconz directly).
  # SSDP: deCONZ runs with --upnp=0 (above) so ONLY diyHue advertises on UDP 1900.

  # ── SYSTEM STATE VERSION — DO NOT CHANGE after initial install ──────────────
  system.stateVersion = "25.05";
}
