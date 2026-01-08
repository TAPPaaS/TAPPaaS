"""Configuration management for OPNsense connection."""

import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_CREDENTIAL_FILE = Path.home() / ".opnsense-credentials.txt"


def _default_credential_file() -> str | None:
    """Return the default credential file path if it exists."""
    if DEFAULT_CREDENTIAL_FILE.exists():
        return str(DEFAULT_CREDENTIAL_FILE)
    return None


@dataclass
class Config:
    """OPNsense firewall connection configuration."""

    firewall: str
    token: str | None = None
    secret: str | None = None
    credential_file: str | None = field(default_factory=_default_credential_file)
    ssl_verify: bool = True
    ssl_ca_file: str | None = None
    debug: bool = False
    api_timeout: float = 30.0  # Default 30 seconds (upstream default is 2.0)
    api_retries: int = 3  # Retry failed requests (upstream default is 0)

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
            OPNSENSE_API_TIMEOUT: API timeout in seconds (default: 30)
            OPNSENSE_API_RETRIES: Number of retries for failed requests (default: 3)
        """
        firewall = os.environ.get("OPNSENSE_HOST")
        if not firewall:
            raise ValueError("OPNSENSE_HOST environment variable is required")

        credential_file = os.environ.get("OPNSENSE_CREDENTIAL_FILE")
        if credential_file is None:
            credential_file = _default_credential_file()

        return cls(
            firewall=firewall,
            token=os.environ.get("OPNSENSE_TOKEN"),
            secret=os.environ.get("OPNSENSE_SECRET"),
            credential_file=credential_file,
            ssl_verify=os.environ.get("OPNSENSE_SSL_VERIFY", "true").lower() != "false",
            ssl_ca_file=os.environ.get("OPNSENSE_SSL_CA_FILE"),
            debug=os.environ.get("OPNSENSE_DEBUG", "false").lower() == "true",
            api_timeout=float(os.environ.get("OPNSENSE_API_TIMEOUT", "30.0")),
            api_retries=int(os.environ.get("OPNSENSE_API_RETRIES", "3")),
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
