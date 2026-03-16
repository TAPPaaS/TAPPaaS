"""TAPPaaS-compatible logging for Python CLI tools.

Mirrors the bash logging conventions from common-install-routines.sh:
  [Info]    — standard messages (suppressed when TAPPAAS_SILENT=1)
  [Debug]   — verbose details (shown only when TAPPAAS_DEBUG=1)
  [Warning] — warnings (always shown)
  [Error]   — errors (always shown, to stderr)

Environment variables:
  TAPPAAS_DEBUG=1   — enable debug output
  TAPPAAS_SILENT=1  — suppress info output
"""

import os
import sys

# ANSI color codes matching common-install-routines.sh
_DGN = "\033[32m"     # Green
_BL = "\033[36m"      # Cyan
_YW = "\033[33m"      # Yellow
_RD = "\033[01;31m"   # Red
_CL = "\033[m"        # Clear


def _is_debug() -> bool:
    return os.environ.get("TAPPAAS_DEBUG", "0") == "1"


def _is_silent() -> bool:
    return os.environ.get("TAPPAAS_SILENT", "0") == "1"


def info(msg: str) -> None:
    """Print an [Info] message (suppressed when TAPPAAS_SILENT=1)."""
    if _is_silent():
        return
    print(f"{_DGN}[Info]{_CL} {msg}")


def debug(msg: str) -> None:
    """Print a [Debug] message (shown only when TAPPAAS_DEBUG=1)."""
    if not _is_debug():
        return
    print(f"{_BL}[Debug]{_CL} {msg}")


def warn(msg: str) -> None:
    """Print a [Warning] message (always shown)."""
    print(f"{_YW}[Warning]{_CL} {msg}")


def error(msg: str) -> None:
    """Print an [Error] message (always shown, to stderr)."""
    print(f"{_RD}[Error]{_CL} {msg}", file=sys.stderr)
