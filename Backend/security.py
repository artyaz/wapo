"""
security.py — Hardcoded Path Blocklist Engine

Implements canonical path validation using os.path.realpath to resolve
symlinks and prevent traversal attacks. Every file operation is validated
against the blocklist before execution.
"""

from __future__ import annotations

import os
from pathlib import Path


# ---------------------------------------------------------------------------
# Hardcoded Blocklist — NEVER modify at runtime
# ---------------------------------------------------------------------------

_BLOCKLIST_PREFIXES: tuple[str, ...] = (
    # Local Login Keychain — AES-256-GCM encrypted credentials
    os.path.expanduser("~/Library/Keychains/"),
    # System-level credential store
    "/Library/Keychains/",
    # System config & TCC database
    "/private/var/db/",
    # iMessage SQLite database (chat.db)
    os.path.expanduser("~/Library/Messages/"),
    # System LaunchDaemons — privilege escalation vector
    "/System/Library/LaunchDaemons/",
)


class SecurityViolation(Exception):
    """Raised when an operation targets a blocklisted path."""

    def __init__(self, path: str, matched_prefix: str) -> None:
        self.path = path
        self.matched_prefix = matched_prefix
        super().__init__(
            f"SECURITY VIOLATION: Access to '{path}' blocked. "
            f"Matched blocklist prefix: '{matched_prefix}'"
        )


def validate_path(target: str | Path) -> str:
    """
    Validate that a target path does not resolve to any blocklisted directory.

    Uses os.path.realpath to resolve all symlinks and '..' traversals,
    preventing bypass via symbolic links or relative path tricks.

    Returns:
        The canonical (resolved) absolute path if safe.

    Raises:
        SecurityViolation: If the resolved path matches any blocklist prefix.
    """
    # Resolve to canonical absolute path
    canonical = os.path.realpath(os.path.expanduser(str(target)))

    # Ensure trailing separator for prefix matching
    for prefix in _BLOCKLIST_PREFIXES:
        canonical_prefix = os.path.realpath(prefix)
        if canonical.startswith(canonical_prefix) or canonical == canonical_prefix.rstrip("/"):
            raise SecurityViolation(canonical, prefix)

    return canonical


def is_path_safe(target: str | Path) -> bool:
    """Non-throwing version of validate_path. Returns True if path is safe."""
    try:
        validate_path(target)
        return True
    except SecurityViolation:
        return False


def get_blocklist() -> list[str]:
    """Return the current blocklist (for display/logging purposes only)."""
    return list(_BLOCKLIST_PREFIXES)
