In the following we detail each category a bit more and describe the vision for what we solve


## Communities and Homes

Most people have an idea on what a Home is. However the definition is very dependent on the context. TAPPaaS targets all IT in a home then it would be appropriate to define what we man by Home.

Here are some definitions: "A place that you own or rent", "The place you go an sleep when not on vacation", "The place you live together with you family", "A house" or "an Apartment"

For this project it is all of the above, and also a place where you can set your own rules and standard for how to live (typically within some limitation of whatever jurisdiction the Home is in)

For this project we often think about the home as a word for my Private universe. Separate from my Corporate universe, and separate from the Public space.  Extending from this, and very important for the project, is that a Home is now both a Physical and a Virtual construct.

- I might invite guests into my home. They are then under my rules, and generally my friends and relatives understand this. In the same manner I might invite friends into my virtual Home to share holiday pictures.
- The physical home is something that I have selected very carefully and are constantly "sculpting" to my desire. I upgrade my kitchen, I paint the walls and I cultivate my garden. I do it for my own pleasure but also as a way of projecting my self to friends, family and the general society. The virtual home should also be under my control and allow me to model my appearance and functionality
- The physical home in my definition include all it's "content" such as furniture, pictures on the walls, books and other stuff on the bookshelf, you tool collection. Your car in the garage, your bicycles (yes I have several bicycles, I live in Denmark).
- For the Virtual Home it include among many thinks items like:
  - your private emails and address book
  - you private papers like insurance policies, bank statements, tax filings, pay slips
  - You private picture and video library
  - you ebooks, music, movie, podcast library

TAPPaaS aim to control/deliver all the information technology that is (or should be) in my physical physical home to realize my virtual home.

- all internet connected devices in your home
- tech used to "run" your virtual home and mange you private data and identities.

This include solving the problem:

### I own my data.

- My pictures are owned by me, and should be available to my kids, and grand kids 50 years from now no matter what service provider they have and what mobile phone or compute or tablets or VR headset they own
- My emails are private and should not be owned by a company
- My "intelligent house" configurations are owned by me, and work even when the Internet is dow
- My data should be stored in open formats that do not rely on proprietary software. Data should be stored locally and be available regardless of the state of the internet
- My e-books and podcasts and music downloads are owned by me and should not be reliant on a cloud service that might disappear in 5, 10, 20 years

### I own my devices

My TV talk to a Korean company that pushes SW updates and adverts. my Microwave want to serve me with recipes and track my usage (well it is not as I have blocked that), my Fridge want to talk with a server so that I can remotely control the temperature (why do I need that), the list goes on, is increasingly depending on internet connection and cloud service. 
TAPPaaS should help you get back control of your devices. Either by blocking external access, isolating access or offer alternatives to cloud services.

### TAPPaaS for my Community

Running a full TAPPaaS infrastructure for a single family can be seen excessive, and forming communities of homes can be a great way of both scaling the resilience and spread the cost and burden

This can either be neighbors  or a village or friends or extended family

The community provide:

- Backup service for each other
- Community services that are shared
- Community networking (if physically reasonably close together)

#### Community Services:

running a Mastodon and/or Matrix service
local DNS across the community
local library service (local instance of wikipedia, ....)

#### Community networking:

Most IT systems in homes tend to stop working if the Internet is down. A lot can be achieved with running a well configured DNS that would work for local services in times of outage. 

However if we hook up with the local community, we can create a redundant local network. with a few internet connection and running at the virtual edge you get
- redundancy
- cheaper connectivity
- local community connectivity when the larger internet is down


## SMB

The challenges with the broken internet and the complexity of IT is also true for Small and medium sized business. But the immediate challenge is seems through a slightly different lense. This include:

- Hyperscalers and SaaS/SW providers are creating lock-in resulting support and upgrade bills that keeps rising
- In case of an Internet outage or service provider outage then the SMB will be blocked for working
- increasingly small companies are worried that their data and their customers data is going to be used harvested by the service providers. This is even more problematic with the advent of generative AI solutions

Many of the same solution modules that TAPPaaS needs to implement for Communities and homes will be directly reusable in an SMB setting


## Public Sector and NGO's

Some public sector and and some NGO's can be viewed as just another Medium sized business.
