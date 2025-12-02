# Identity and secrets VM for TAPPaaS

The Identity module is Authentic and the secrets module is valutwarden
The identity.nix file contain the configurations

do the following steps

- register authentik.<mydomain> and vaultwarden.<mydomain> in your DNS provider
- configure caddy to pass through the authentik service to identity.intern port 80
- configure caddy to pass through the vaultwarden service to identity.intenral port 8080
- run the install.sh script from the tappaas-cicd command line to create the identity VM
- create firewall rule to allow access from caddy to identity.internal TCP port 80 and 8080

#Test the identity and secrets solution