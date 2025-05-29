*© 2024. This work is openly licensed via [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).*

# Vision Introduction

TAPPaaS, that is The Automated Private Platform as a Service, is being designed to solve a problem. A big problem

## The Problem Part One: The Internet is broken!

The internet was designed as a connection of local nets. The IP protocols were invented with the design goal of having no central point of failure.

With the advent of large hyper scalers we increasingly rely on these companies manage our information technology. Those companies do have the resources to create a very fault tolerant and secure environment with deep integration across the services they offer, however it does imply that you are giving up your freedom of choice, and you are essentially moving from an interaction form of many to many to centralized hup and spoke approach.

You can compare the centralized approach of hyper scalers with the original distributed and open standards approach of the internet to what it would look like in the physical world:

- **Centralized approach**: There is one mall in town, is only one mall , you can only get what is in that mall. You are actively discouraged from dining at home, and there is only one way of meeting with friends: go to the mall, as this is also the only transport available. If you own a business then there is only one inbound and one outboud supply chain. 
- **Distributed approach to cities, business and homes:**  You can chose what food to buy, what friend to invite, how to move around, where to dine out, with or without friends. You business can trive and compete in an open eco system.

## The Problem Part Two: Todays IT world is complex

The big 5, the hyper scalers, are very easy to consume, and they deliver high quality. Designing and deploying a reliable, resillient, secure and easy to use Platform is for most smaller organisaitons, let alone individual famelies and comuniites almost insurmountable. You need to stand up firewalls, identity management security monitoring, basic infrastructure services, backup processes. you need to currate the most important standard applications for your busines and integrate the lot. Then you need to constantly patch and upgrade. And by the way how do I run AI without selling my soul and data to the hyperscaler.

Large enterprises can afford solving this. Not so much with Small Business, NGO's, communities, ...

## But there is hope

Our Vision with TAPPaaS it to solve problem two, and in the process also repair the internet aka problem one/

The reason we believe we can solve problem two is that all the needed software to stand up a platform for you home/comunity/ngo/small-business exist as open source today. Further the quality of the open source solutions is very high individually.

what is missing are three things:

- Curration of the right software: There are 3 major open source firewalls, countless linux server os varians. document collaboration and storage exists in many flavours, and on and on. Most organisations and individuals actually do not care that much. someone just need to make the decition
- Configuraiton and Integration of all the chosen software: So we decide to use NextCloud and run it virtualized on Proxmox. just that in and by itself can be done in dozend of different ways. Again most people do not care, just tell me
- Automation of the installation. 

This is not insurmountable if we can create a small community around TAPPaaS

# Target audinece and Design Goals

We have been looking at 3 primary use cases for TAPPaaS

- SMB businees 
- Organisations that needs high degree of local resilience, typical critical infrastructure provides parts of public sector and NGO's
- Private communities down to single family homes



## I own my data.

- My pictures are owned by me, and should be available to my kids, and grand kids 50 years from now no matter what service provider they have and what mobile phone or compute or tablets or VR headset they own
- My emails are private and should not be owned by a company
- My house configurations are owned by me
- My data should be stored in open formats that do not rely on proprietary codex
- My e-books and podcasts and music downloads are owned by me and should not be reliant on a cloud service that might disappear in 5, 10, 20 years

## I own my devices

My TV talk to a Korean company that pushes SW updates and adverts. my Microwave want to serve me with recipes and track my usage (well it is not as I have blocked that), my Fridge want to talk with a server so that I can remotely control the temperature (why do I need that), the list goes on, is increasingly depending on internet connection and cloud service. 
TAPPaaS should apply you to run every IoT devices in your company/home without relying on outside software.

## My business/community/ngo/home should work without connectivity

Local WiFi still allowm me to connect to my private date/pictures and libraries. My employees can still operate the ERP, read and prepare emails, and the factory will continue to operate.
When I press the light switch the light should come on regardless of the state of the rest of the world. 

