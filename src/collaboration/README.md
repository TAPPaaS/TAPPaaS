# Collaboration stack

Files, calendars, office documents and calls for your organisation: Nextcloud with document
editing, and the Talk call stack (signalling and TURN). On the website:
[Collaboration Stack](https://tappaas.org/stacks/collaboration/).

**Planned:** Karakeep — bookmarking and read-it-later (no module yet).

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

| Module | What it is | Status |
|---|---|---|
| [lazysite](lazysite/README.md) | lazysite — the site owner's public website: Markdown pages in a Forgejo repository, served as HTML, with no build step or database. | Development |
| [nextcloud](nextcloud/README.md) | Nextcloud file sharing and collaboration platform with Authentik SSO support. | Testing |
| [coturn](coturn/README.md) | coturn TURN/STUN server for Nextcloud Talk WebRTC audio/video calls. | Testing |
| [euro-office](euro-office/README.md) | Euro-Office DocumentServer — collaborative document editing for Nextcloud. | Testing |
| [nextcloud-hpb](nextcloud-hpb/README.md) | Nextcloud Talk High-Performance Backend - dedicated WebSocket signaling server (nextcloud-spreed-signaling) with a Janus SFU for group calls. | Testing |

Install them as [INSTALL.md](INSTALL.md) says.

<!-- END GENERATED MODULES -->

## Architecture view

```kroki-plantuml
@startuml
!include <archimate/Archimate>

title TAPPaaS Collaboration Stack

' Business Actor
Business_Actor(user, "Platform User")

' Application Components
Application_Component(nextcloud, "Nextcloud")
Application_Component(office, "EURO Office")
Application_Component(hpb, "Nextcloud HPB")
Application_Component(coturn, "coturn")

' Application Services
Application_Service(fileSvc, "Files, calendars, contacts")
Application_Service(editSvc, "Document editing")
Application_Service(callSvc, "Talk calls")

' Technology Artifacts (Data)
Technology_Artifact(files, "Files")
Technology_Artifact(db, "Database")

' Components realize services
Rel_Realization(nextcloud, fileSvc)
Rel_Realization(office, editSvc)
Rel_Realization(hpb, callSvc)
Rel_Realization(coturn, callSvc)

' User uses services
Rel_Serving(fileSvc, user)
Rel_Serving(editSvc, user)
Rel_Serving(callSvc, user)

' Editing and calls work inside Nextcloud
Rel_Serving(office, nextcloud)
Rel_Serving(hpb, nextcloud)
Rel_Serving(coturn, hpb)

' Data access
Rel_Access(nextcloud, files)
Rel_Access(nextcloud, db)

@enduml
```

How modules are grouped into stacks: [ADR-004](../../docs/ADR/ADR-004-module-catalog-config-cascade.md),
*Where a module's directory is*. The module lists here and in [INSTALL.md](INSTALL.md) are generated
by `src/foundation/tappaas-cicd/scripts/gen-stack-readme.py` from `src/module-catalog.json`.
