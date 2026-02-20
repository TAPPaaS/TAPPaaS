"""Configuration management for OPNsense connection."""

import os
import socket
import ssl
import sys
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_CREDENTIAL_FILE = Path.home() / ".opnsense-credentials.txt"
DEFAULT_PORTS = [443, 8443]
PROBE_TIMEOUT = 5  # seconds


def _default_credential_file() -> str | None:
    """Return the default credential file path if it exists."""
    if DEFAULT_CREDENTIAL_FILE.exists():
        return str(DEFAULT_CREDENTIAL_FILE)
    return None


def probe_opnsense_port(
    firewall: str,
    ports: list[int] | None = None,
    ssl_verify: bool = True,
    ssl_ca_file: str | None = None,
    timeout: float = PROBE_TIMEOUT,
) -> int:
    """Probe OPNsense to determine which HTTPS port it is listening on.

    Tries each port in order and returns the first one that accepts
    an HTTPS connection.

    Args:
        firewall: Firewall hostname or IP address
        ports: List of ports to try (default: [443, 8443])
        ssl_verify: Whether to verify SSL certificates
        ssl_ca_file: Path to custom CA certificate file
        timeout: Connection timeout in seconds per port

    Returns:
        The first port that responds

    Raises:
        ConnectionError: If no port responds
    """
    if ports is None:
        ports = list(DEFAULT_PORTS)

    ctx = ssl.create_default_context()
    if not ssl_verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    elif ssl_ca_file:
        ctx.load_verify_locations(ssl_ca_file)

    errors = []
    for port in ports:
        try:
            with socket.create_connection((firewall, port), timeout=timeout) as sock:
                with ctx.wrap_socket(sock, server_hostname=firewall):
                    return port
        except (OSError, ssl.SSLError) as e:
            errors.append((port, e))

    tried = ", ".join(str(p) for p in ports)
    details = "; ".join(f"port {p}: {e}" for p, e in errors)
    raise ConnectionError(
        f"Cannot reach OPNsense at {firewall} on any port ({tried}). {details}"
    )


@dataclass
class Config:
    """OPNsense firewall connection configuration."""

    firewall: str
    port: int | None = None  # None = auto-detect by probing 443, then 8443
    token: str | None = None
    secret: str | None = None
    credential_file: str | None = field(default_factory=_default_credential_file)
    ssl_verify: bool = True
    ssl_ca_file: str | None = None
    debug: bool = False
    api_timeout: float = 30.0  # Default 30 seconds (upstream default is 2.0)
    api_retries: int = 3  # Retry failed requests (upstream default is 0)

    def resolve_port(self) -> int:
        """Resolve the API port, probing if not explicitly set.

        When port is None, probes the firewall on ports 443 and 8443
        (in that order) and caches the result.

        Returns:
            The resolved port number
        """
        if self.port is not None:
            return self.port

        if self.debug:
            print(f"Auto-detecting OPNsense port on {self.firewall}...", file=sys.stderr)

        self.port = probe_opnsense_port(
            self.firewall,
            ssl_verify=self.ssl_verify,
            ssl_ca_file=self.ssl_ca_file,
        )

        if self.debug:
            print(f"Detected OPNsense on port {self.port}", file=sys.stderr)

        return self.port

    @classmethod
    def from_env(cls) -> "Config":
        """Create config from environment variables.

        Environment variables:
            OPNSENSE_HOST: Firewall IP/hostname (required)
            OPNSENSE_PORT: API port (default: auto-detect 443 or 8443)
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

        port_str = os.environ.get("OPNSENSE_PORT")
        port = int(port_str) if port_str else None

        credential_file = os.environ.get("OPNSENSE_CREDENTIAL_FILE")
        if credential_file is None:
            credential_file = _default_credential_file()

        return cls(
            firewall=firewall,
            port=port,
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
