*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# AI design for TAPPaaS

The current world of AI is moving at a fast phase so it is difficult to create a stable design

However there are some patterns that emerges that allow us to make some hopefully sensible design decisions

## AI Server

1. AI models especially LLMs comes in many variants, and typically you need to specialize what models you are running.
2. The models needs access to GPU resources
3. and the models will serve a number of use cases across TAPPaaS

For that reason we design with an LLM server setup: 

- one VM on a machine with resources for AI. This will run ollama and be the central point for loading and accessing LLMs
- no users will directly interact with this server. Interactions is done via AI client programs

## AI clients

There are several kinds of clients:

- chat clients: TAPPaaS will install opwnwebui as default in a dedicated VM. This will also have a RAG, in terms of Searxng
- workflow: This will be a n8n
- regular clients that needs openAPI access
  - Home Assistant (home butler function)
  - Immich (picture classification and search)
