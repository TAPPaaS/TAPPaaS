# Securing TAPPaaS

## Introduction

This is not a real module, but a set of activities to lock down TAPPaaS after foundation have been installed

This also set up and explains how to get remote acccess to TAPPaaS using Netbird

### TODO
- lock down root loging with password
- run security test scripts
- setup crowdSec
- change backup user to not allow pruning/delete

## Netbird

Netbird client is installed as default on all TAPPaaS Nodes. This allows us to setup remote access to mgmt.internal in a redundant manner by enabeling the client for all nodes

Setup a Netbird account either in the public netbird.io or as a self hosted module on TAPPaaS. Consider using a selfhosted module on a **different** TAPPaaS system, so that controll plane for Netbird is working even if the TAPPaaS solution have issues. Alternative is to ensure the selfhosted solution is configured for High Availability

On each of the nodes in the TAPPaaS system run the command (you can skip the management url option if you are using netbird.io):

```bash
netbird up --management-url https://<my netbird server>:33073
```

follow the direction and open a web browser on the URL that is provided and activate the netbird client

Alternative is to generate an activation key on your netbird administration console. cut and pase it into this command

```bash
netbird up --setup-key <my key> --management-url https://<my netbird server>:33073
```