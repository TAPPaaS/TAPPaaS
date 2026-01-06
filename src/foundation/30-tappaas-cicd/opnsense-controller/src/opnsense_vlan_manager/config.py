"""Configuration management for OPNsense connection."""

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Config:
    """OPNsense firewall connection configuration."""

    firewall: str
    token: str | None = None
    secret: str | None = None
    credential_file: str | None = None
    ssl_verify: bool = True
    ssl_ca_file: str | None = None
    debug: bool = False

    @classmethod
    def from_env(cls) -> "Config":
        """Create config from environment variables.

        Environment variables:
            OPNSENSE_HOST: Firewall IP/hostname (required)
            OPNSENSE_TOKEN: API token
            OPNSENSE_SECRET: API secret
            OPNSENSE_CREDENTIAL_FILE: Path to credentials file
            OPNSENSE_SSL_VERIFY: Set to 'false' to disable SSL verification
            OPNSENSE_SSL_CA_FILE: Path to custom CA certificate
            OPNSENSE_DEBUG: Set to 'true' to enable debug logging
        """
        firewall = os.environ.get("OPNSENSE_HOST")
        if not firewall:
            raise ValueError("OPNSENSE_HOST environment variable is required")

        return cls(
            firewall=firewall,
            token=os.environ.get("OPNSENSE_TOKEN"),
            secret=os.environ.get("OPNSENSE_SECRET"),
            credential_file=os.environ.get("OPNSENSE_CREDENTIAL_FILE"),
            ssl_verify=os.environ.get("OPNSENSE_SSL_VERIFY", "true").lower() != "false",
            ssl_ca_file=os.environ.get("OPNSENSE_SSL_CA_FILE"),
            debug=os.environ.get("OPNSENSE_DEBUG", "false").lower() == "true",
        )

    @classmethod
    def from_credential_file(cls, firewall: str, credential_file: str, **kwargs) -> "Config":
        """Create config using a credential file.

        The credential file should contain two lines:
            Line 1: API token
            Line 2: API secret
        """
        path = Path(credential_file)
        if not path.exists():
            raise FileNotFoundError(f"Credential file not found: {credential_file}")

        return cls(
            firewall=firewall,
            credential_file=credential_file,
            **kwargs,
        )
