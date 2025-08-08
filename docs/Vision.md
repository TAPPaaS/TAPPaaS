*© 2025. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# Vision Introduction

TAPPaaS: The Trusted Automated Private Platform as a Service, is designed to solve a problem. A big problem

## The Problem Part One: The Internet is broken!

The internet was designed as a connection of local nets. The IP protocols were invented with the design goal of having no central point of failure.

With the advent of large hyper scalers we increasingly rely on these companies manage our information technology. Those companies do have the resources to create a very fault tolerant and secure environment with deep integration across the services they offer, however it does imply that you are giving up your freedom of choice, and you are essentially moving from an interaction form of many to many to centralized hup and spoke approach.

You can compare the centralized approach of hyper scalers with the original distributed and open standards approach of the internet to what it would look like in the physical world:

- **Centralized approach**: There is one mall in town, it is the only mall, you can only get what is in that mall. You are actively discouraged from dining at home, and there is only one way of meeting with friends: go to the mall, as this is also the only transport available. If you own a business then there is only one inbound and one outbound supply chain. 
- **Distributed approach to cities, business and homes:**  You can chose what food to buy, what friend to invite, how to move around, where to dine out, with or without friends. You business can thrive and compete in an open eco system.

We need to move towards the distributed approach again, but that requires an alternative to the hyperscalers

## The Problem Part Two: Todays IT world is complex

The big 5, the hyper scalers, are very easy to consume, and they deliver high quality. Designing and deploying a reliable, resilient, secure and easy to use Platform is for most smaller organizations, let alone individual families and communities almost insurmountable. You need to stand up firewalls, identity management security monitoring, basic infrastructure services, backup processes. you need to curate the most important standard applications for your business and integrate the lot. Then you need to constantly patch and upgrade. 

And by the way how do I run AI without selling my soul and data to the hyperscaler.

Large enterprises can afford solving this. Not so much with Small Business, NGO's, communities, ...

## But there is hope

Our Vision with TAPPaaS it to solve problem two, and in the process also repair the internet aka problem one

The reason we believe we can solve problem two is that all the needed software to stand up a platform for you 
home/community/ngo/small-business exist as open source today. Further the quality of the individual open source solutions is very high.

what is missing are three things:

- Curation of the right software: There are 3 great open source firewalls, countless linux server OS variant. document collaboration and storage exists in many flavours, and on and on. Most organizations and individuals actually do not care that much. someone just need to make the decision
- Configuration and Integration of all the chosen software: So we decide to use NextCloud and run it virtualized on Proxmox. just that in and by itself can be done in many of different ways. Again most people do not care, just tell me what to do.
- Automation of the installation. Even with the decisions taken it can take weeks to install and configure everything, as each individual open source package tries to cater for every possible integration use case, implying that there are endless places where you can make choices that are inconsistent for your scenario. We need to automate all that.

This is not insurmountable. We are creating a small community around TAPPaaS. The community  function as a [Platform Democracy](https://www.cncf.io/blog/2025/05/23/platform-democracy-rethinking-who-builds-and-consumes-your-internal-platform/), implying that the producers of the platform should also be consumers of the platform.

# Target audience and Design Goals

We have been looking at 3 primary consumers of TAPPaaS

- Communities and single family homes: People that care about not having control over your own private data. People that want their smarthome and community IT to work even when their service provider is not working.
- SMB business: TAPPaaS should deliver the foundation for regular office work and also be a foundation for deployment of business specific applications.
- Organizations that needs high degree of local resilience, typical critical infrastructure provides parts of public sector and NGO's

# End Note

Overall TAPPaaS is able to give you [Digital Sovereignty](./Digital%20Sovereignty.md)
