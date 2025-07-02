TODO: still work in progress. The actual choice should be documented and the alternatives should be listed with a reason for why they were deselected

## Open Source SSO: Options and the Keycloak + Bitwarden Combination

### What is SSO and Why Use It?
Single Sign-On (SSO) allows users to access multiple applications with one set of credentials. This improves user experience, centralizes security (easier 2FA, policy enforcement), and simplifies user management.

---

### Most Popular Open Source SSO Solutions

Here are the leading open source SSO providers, all suitable for self-hosting:

| Solution      | Highlights                                                                                         |
|---------------|---------------------------------------------------------------------------------------------------|
| **Keycloak**  | Most popular and widely adopted; supports OIDC, SAML, OAuth2, LDAP, social logins, user federation, fine-grained authorization, and a large ecosystem. Ideal for both small and enterprise setups.[3][6][7][8] |
| **Authentik** | Modern, user-friendly, supports OIDC, SAML, LDAP. Easy to set up, gaining popularity for its flexibility and UI.[4][5][7][8] |
| **Authelia**  | Lightweight, acts as a secure authentication portal in front of other services. Focuses on MFA and access policies; less full-featured for SSO than Keycloak or Authentik.[4][5][7][8] |
| **Gluu**      | Enterprise-ready, supports OIDC, SAML, LDAP, strong federation features. More complex to set up and manage.[2][6][8] |
| **Zitadel**   | Modern, developer-friendly, supports OIDC, SAML. Focus on cloud-native and scalable deployments.[2][7][8] |
| **IdentityServer** | Popular in .NET environments, supports OIDC/OAuth2, good for API and microservices SSO.[3][6][8] |
| **CAS (Apereo CAS)** | Mature, focused on web SSO, strong in academic/enterprise settings.[2][3] |

---

### Why is Keycloak the Best Option?

- **Most widely adopted:** Keycloak is the global open source standard for SSO and IAM, with the largest user base and community support.[3][6][7][8]
- **Comprehensive protocol support:** Full support for OIDC, SAML, OAuth2, LDAP, and social logins, making it highly versatile.[3][6][7][8]
- **Enterprise features:** User federation, identity brokering, multi-factor authentication, fine-grained authorization, and extensive admin controls.[3][6][7][8]
- **Extensive integrations:** Works with a huge range of apps and services, including Nextcloud, Gitea, Bitwarden, and modern AI tools.
- **Scalable and robust:** Suitable for both small teams and large enterprises; can be deployed on-premises, in containers, or in the cloud.
- **Open source and free:** No license fees, full control, and active development.

**In summary:** Keycloak is the most flexible, feature-rich, and future-proof open source SSO platform, making it the best choice for most self-hosted environments.

---

### How does Bitwarden fit in?

- **Bitwarden** is an open source password manager for securely storing and sharing passwords, secrets, and sensitive data.
- **Integration:** Bitwarden can use Keycloak as an SSO provider via SAML 2.0 or OpenID Connect.
    - Users log in to Bitwarden with their Keycloak (SSO) account.
    - All authentication and 2FA policies are centrally managed in Keycloak.
    - Users enjoy one login for all apps and their password vault.

---

### How do Keycloak and Bitwarden complement each other?

| Keycloak                         | Bitwarden                                    |
|-----------------------------------|----------------------------------------------|
| Central SSO & user management    | Secure password and secret management        |
| MFA/2FA, policies, groups        | MFA/2FA, password generator, health checks   |
| Used as identity provider (IdP)  | Uses IdP (like Keycloak) for SSO login       |
| SSO for all compatible apps      | Secure storage for non-SSO credentials       |

- **Keycloak** acts as the central gatekeeper for authentication and authorization.
- **Bitwarden** acts as the secure vault for passwords, API keys, and credentials—especially for legacy apps or services that don't support SSO.

**Analogy:**  
Keycloak is like the main access badge for your entire office (SSO), while Bitwarden is the safe where you keep sensitive keys and documents.

---

### Why use both?

- For modern apps, use SSO via Keycloak for seamless, secure access.
- For legacy apps or external services, use Bitwarden to store and share credentials securely.
- By integrating Bitwarden with Keycloak, you get one login for everything and a secure vault for anything that can't use SSO yet.

---

**Summary:**  
Keycloak and Bitwarden together provide a robust, open source identity and password management solution for your self-hosted stack. Use Keycloak for centralized SSO and Bitwarden as your secure vault, with seamless integration between the two.
