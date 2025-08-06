*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# Related work

## [Proxmox Helper scripts](https://community-scripts.github.io/ProxmoxVE/)
We have taken inspiration and code from this project, thank you

*Why did we not just contribute to this project:* 
The helper scripts is trying to create a consolidated list of all possible proxmox configurations scripts. We are trying to consolidate into a single coherent and integrated systems. So we need a subset of the scripts and some overall orchestration, as well as a lot of inter module integrations
Further the helper scripts are typically asking a lot of questions up front on what the script should do. Again in TAPPaaS we aim at ensuring this is predetermined

## [Garage by Deuxfleur](https://garagehq.deuxfleurs.fr/)
This is perfect for TAPPaaS: Data resiliency for everyone
We plan to including Garage in TAPPaaS, thoug the build in Ceph file system in Proxmox is competing in the S3 space.
The core principle and philosophy of Deuxfleurs is very aligned with TAPPaaS

## [CASAOS](https://casaos.zimaspace.com/)
Your Personal Cloud OS

CASAOS is focused on Personal use of cloud services. Its point and click installation of many Open source product into a single environment is inspirational.

*Why did we not just contribute to this project:*
This is a "Personal" OS not an OS/Platform for a community or business
It is focused on bringing up containers on a personal server/pc
It is not focused on creating a resilient IT backbone
It helps connect a lot of cloud services (google drive, dropbox, icloud, ...). TAPPaaS on the other hand is focused on removing reliance of these services


## [Frappe](https://frappe.io/framework)

Frappe delivers an application framework as well as interesting business applications build on the Frappe Framework. The ease of installation of a complex application stack is inspirational. 

*Why did we not just contribute to this project:*
It is not focused on creating a resilient infrastructure platform, nor is it pursuing the goal of delivering other application that already exists. As such Frappe applications on the Frappa Framework can be deployed in TAPPaas and become optional modules in TAPPaaS

## [Dokku](https://dokku.com/)
Similar in goals to Frappa. as with Frappa we see Dokku as a potential module in TAPPaaS


## [QUBES OS](https://www.qubes-os.org/)
Great securit model, on TAPPaaS we implement something similar (trying to get it to a zero trust model). Qubes OS is aimed at the desktop, and can be a worthy alternative to Macos or windows if you care for security (as you should)

## [HEXOS](https://hexos.com/)
There seems to be some interesting core ideas in Hexos that is overlapping with TAPPaaS. Right now HexOS is still closed beta, so har to tell exactly what it will deliver, and it is unclear how much of it will be open Source and what kind of open source


# inspirational youtubers

* [Techno Tim](https://www.youtube.com/@TechnoTim)
* [Brandon Lee: VirtualizationHowto](https://www.youtube.com/@VirtualizationHowto) 
* [Tech The Lazy Automator](https://www.youtube.com/@Tech-TheLazyAutomator)
* [Jim's Garage](https://www.youtube.com/@Jims-Garage)
* [Patric at ServeTheHome](https://www.youtube.com/@ServeTheHomeVideo)
* [Tech Tutorials by David](https://www.youtube.com/@TechTutorialsDavidMcKone)
* [Digital Spaceport](www.youtube.com/@DigitalSpaceport)
* [Home Network Guy](https://www.youtube.com/@homenetworkguy)
* [Apalrd's Adventures](https://www.youtube.com/@apalrdsadventures)
* [Lawrence Systems](https://www.youtube.com/@LAWRENCESYSTEMS)
* [NASCompares](https://www.youtube.com/@nascompares)


# relevant videos to consider
* [A Homelabbers Networking Playground with Opnsense, Proxmox, VLANs and Tailscale](https://youtu.be/XXx7NDgDaRU)
