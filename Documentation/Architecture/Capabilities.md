*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# A Capability Model for TAPPaaS

## Introduction

TAPPaaS is designed both top down and bottom up. Top down we looked at the capabilities needed to address the needs described in the [Vision](../Vision.md). The bottom up have been looking at real software and real implementations to determine what is possible and what makes sense

We are trying to bring this together in a structured manner. This is a description of WHAT we want TAPPaaS to deliver. The HOW to deliver it is in the [SoftwareStack](TheSoftwareStack.md)

## TAPPaaS high level structure

As with most complex IT solutions you can divide the capabilities of the solution into some dependent sub system.
At the very high level we structure the capabilities into the following groups

```mermaid
classDiagram
  TAPPaaS *-- Security
  TAPPaaS *-- Services
  TAPPaaS *-- Management
	Security ..> Foundation
	Services ..> Foundation
  Management ..> Foundation
```

In the following we decompose the high level capabilities

## Services

Services is what this is all about: Providing IT functions to the users of TAPPaaS. all the other parts like Foundation, Management and Security is just there to ensure that you can get the IT you need working in a stable, scalable, integrated, secure, private and maintainable way.

What services are essential to each deployment of TAPPaaS will differ, but we define a set of services that TAPPaaS should support based on the typical deployment. You can configure what is relevant for you deployment.

These examples of deployments are just examples, where we try and highlight the essential functionality that you need for that kind of deployment. 

```mermaid
classDiagram
  A Home ..> TAPPaaS Services
  Small Community ..> TAPPaaS Services
  Small Business Owner ..> TAPPaaS Services
  Small SW Development Organization ..> TAPPaaS Services
  Small Utility Company ..> TAPPaaS Service
  NGO ..> TAPPaaS Services
  
```

Note we are using the word "small" a lot. Make no mistake, TAPPaaS as a core architecture can scale up, but our initial design criteria is to cater for the SMB/Home out of the box.

### Capabilities needed by a home

Services can be grouped into functionality that is linked to a physical home, and thus stays with home and functionality that is linked to a user but is not bound to the physical home (except through the foundation layer and possible integrations)

```mermaid
classDiagram
		A Home *-- PhysicalHome
		A Home *-- Household Member
```

#### Physical Home Related

So the functions we are aiming at:

- smart lighting
- smart heat system
- Smart Sprinkler system
- Weather monitoring
- Smart AVR
- House Butler (AI)

#### household Member Related

- Email: you want to own you emails and email address
- Address book
- Calendering: need to be sharable within home and community and externally
- Note taking: must be sharable
- photo upload, storage and sharing: Need to have good indexing and sharing functionality
- music library: own your music, need to be stream-able. and sharable
- video library
- podcast library
- Document store: Can be very private or shared across a user group
- Offline web: ability to remember interesting parts of the web, and store for later (offline) reading.
- Virtual Assistant: you personal AI in a box
- eBook bookshelf


### Small Community

Note a small community can start with a single home, and will contain all the functionality of a Home deployment of TAPPaaS

However with a Community deployment you would want to add a few more functionalities

- WiFi rooming: Make it possible to move around the community and preserve access to same Wifi
- Internet sharing (with redundancy): 10 households having 10 Internet connections is overkill
- Public book shelf: Local hosted Wikipedia, Project Gutenberg, .... Ensure access to information in case of internet outage
- Community Social
- Video Conferencing

### SMB

- Corporate email
- Office Suite: document, presentation and spreadsheet with collaboration features and Microsoft compatibility
- Corporate web site
- ERP system
- Office WiFi: Ensure there is a dedicated WiFi for SMB workers and guests
- Corporate VPN
- Video Conferencing
- Chat

### Software Development

- Git Repository
- CI-CD
- Chat
- Backlog management
- Application Platform
- Reverse Proxy

### Small Utility

- Industrial Strength Firewall
- Network separation (VLANs)
- VPN

### NGO

Generally an NGO need the same functionality out of the box as the SMB, but there are important design criteria
- Strict Privacy
- Easy to setup and maintain
- Cost efficient
- Remote deployment and backup
- must function without internet access

## Security

We separate between the physical security and virtual security measures we need in a Home.
The Physical security can be considered a Business function. 

#### Physical Security

- Video Surveillance
- Electronic locks
- Door Camera and Ring
- Neighborhood Threat monitoring

#### Virtual Security

- User and Access Management: Includes 2FA
- Password and key management: For end users, ensure the organization is not relying on postIT notes
- Backup - Restore
- Firewall
- Encryption of private data at rest and in transit
- Remote access and VPN services
- Threat detection
- Threat monitoring
- DMZ with Reverse Proxy

## Management

- Dashboard
- Operational monitoring
- Update and patch management

## Foundation

- Unbreakable Power
- Compute
- Storage
- Connectivity 
  - VLAN separations
  - WAN and Firewall
  - Switch and Access Points
  - DHCP and DNS
- CICD for configuring and installing TAPPaaS
