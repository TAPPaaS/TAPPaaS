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

- SMB businees: TAPPaaS should deliver the foundation for regular office work and also be a foundation for deployment of business specific applicaitons.
- Organisations that needs high degree of local resilience, typical critical infrastructure provides parts of public sector and NGO's
- Communities and single family homes

In the follwong we detail each category a bit more and describe the vision for what we solve

## SMB


## Infrastructure Providers


## Public Sector


## NGO's


## Communitis and Homes

Most people have an idea on what a Home is. However the definition is very dependent on the context. As this project is about IT for Homes then it would be appropriate to define what we man by Home.

Here are some definitions:

- A place that you own or rent
- The place you go an sleep when not on vacation
- The place you live together with you family
- A house or an Apartment

For this project it is all of the above, and also a place where you can set your own rules and standard for how to live (typically within some limitation of whatever jurisdiction the Home is in)

For this project I often think about the home as a word for my Private universe. Separate from my Corporate universe, and separate from the Public space.  Extending from this, and very important for the project, is that a Home is now both a Physical and a Virtual construct.

- I might invite guests into my home. They are then under my rules, and generally my friends and relatives understand this. In the same manner I might invite friends into my virtual Home to share holiday pictures.
- The physical home is something that I have selected very carefully and are constantly "sculpting" to my desire. I upgrade my kitchen, I paint the walls and I cultivate my garden. I do it for my own pleasure but also as a way of projecting my self to friends, family and the general society. The virtual home should also be under my control and allow me to model my appearance and functionality
- The physical home in my definition include all it's "content" such as furniture, pictures on the walls, books and other stuff on the bookshelf, you tool collection. Your car in the garage, your bicycles (yes I have several bicycles, I live in Denmark).
- For the Virtual Home it include among many thinks items like:
  - your private email, address book
  - you private papers like insurance policies, bank statements, tax filings, pay slips
  - You private picture and video library
  - you ebooks, music, movie, podcast library

TAPPaaS should all the information technology that is (or should be) in my physical physical home to realize my virtual home.

- all internet connected devices in your home
- tech used to "run" your virtual home and mange you private data and identities.

This include solving the problem:

### I own my data.

- My pictures are owned by me, and should be available to my kids, and grand kids 50 years from now no matter what service provider they have and what mobile phone or compute or tablets or VR headset they own
- My emails are private and should not be owned by a company
- My house configurations are owned by me
- My data should be stored in open formats that do not rely on proprietary codex
- My e-books and podcasts and music downloads are owned by me and should not be reliant on a cloud service that might disappear in 5, 10, 20 years

### I own my devices

My TV talk to a Korean company that pushes SW updates and adverts. my Microwave want to serve me with recipes and track my usage (well it is not as I have blocked that), my Fridge want to talk with a server so that I can remotely control the temperature (why do I need that), the list goes on, is increasingly depending on internet connection and cloud service. 
TAPPaaS should apply you to run every IoT devices in your company/home without relying on outside software.

### TAPPaaS for my Community

Running a full TAPPaaS infrastructure for a single famely can be seen execive, and forming comunities of homes can be a great way of both scaling the resiliense and spread the cost and burden

This can either be neighbors  or a village or friends or extended family

The community provide:

- Backup service for each other
- Community services that are shared
- Community networking (if physically reasonably close together)

#### Community Services:

running a Mastodon service
local DNS across the community
local library service (local instance of wikipedia, ....)

#### Community networking:

Most IT systems in homes tend to stop working if the Internet is down. A lot can be achieved with running a well configured DNS that would work for local services in times of outage. 

However if we hook up with the local community, we can create a redundant local network. with a few internet connection and running at the virtual edge you get
- redundancy
- cheaper connectivity
- local community connectivity when the larger internet is down

This assume you have local routing and dns. and it require familiarity with OSPF

The Community could also host a DNS authoritative nameserver network


