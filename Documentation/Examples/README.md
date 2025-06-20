# Example TAPPaaS deployments

The following give examples of more concrete use cases and the associated hardware suitable for this deployment

## Testing: a minimal system

This assumes that we are not talking performance testing, then a minimum system can be quite small
Pretty much Intel/AMD CPU will do. 

- RAM: 16G byte (likely it will be possible to test in as little as 8G)
- hard disks: only boot and tank1 needed, no resilience is needed. it can be either SSD or traditional HDDs
  - Boot: 256G (might work with less than 100G, still testing)
  - Tank1: 1 TByte (Might work with 512G, depends on number of modules that are enabled)
  - Tank2: optional
- Network: 3 ports of 1 gig.

A recommended setup we use is am Atom C3558 base system: Qotom Q20300G9, with 16G memory, 512 SSD for boot, 2TB tank 1 on SSD and 2Tb 2.5inch DHH for tank2

## Community/Home: low cost but high resilience

The minimum is a primary system and a peer system (another community/home that you mirror to)
A more resilient system will keep the peer, but add Ha capabilities via a second system + a voting server (very small PI based system).



## SMB: Office automation in a box

## SMB: A scalable system for running bespoke software services

## Resilient platform for disaster management

## Private platform for small utility