"""
tools.py — Agent Tool Definitions

Defines the tool schemas available to the LangGraph agent, including:
- Script-driven file editing (sed/awk/sponge)
- Terminal task spawning
- Security-validated file operations
"""

from __future__ import annotations

import logging
import os
import subprocess
from typing import Any

from security import SecurityViolation, validate_path

logger = logging.getLogger("wapo.tools")


# ---------------------------------------------------------------------------
# Script-Driven File Editing (sed/awk/sponge)
# ---------------------------------------------------------------------------


def edit_file_with_sed(
    file_path: str,
    pattern: str,
    replacement: str,
    global_replace: bool = True,
) -> dict[str, Any]:
    """
    Apply an in-place sed edit to a file, piped through sponge to preserve
    metadata and permissions. Returns success/error status.
    """
    try:
        safe_path = validate_path(file_path)
    except SecurityViolation as e:
        return {"success": False, "error": str(e)}

    if not os.path.exists(safe_path):
        return {"success": False, "error": f"File not found: {safe_path}"}

    flag = "g" if global_replace else ""
    cmd = f"sed 's|{pattern}|{replacement}|{flag}' '{safe_path}' | sponge '{safe_path}'"

    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return {"success": False, "error": result.stderr}
        return {"success": True, "path": safe_path}
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Edit timed out after 30s"}
    except Exception as e:
        return {"success": False, "error": str(e)}


def edit_file_with_awk(
    file_path: str,
    awk_program: str,
) -> dict[str, Any]:
    """
    Apply an awk transformation to a file, piped through sponge.
    """
    try:
        safe_path = validate_path(file_path)
    except SecurityViolation as e:
        return {"success": False, "error": str(e)}

    if not os.path.exists(safe_path):
        return {"success": False, "error": f"File not found: {safe_path}"}

    cmd = f"awk '{awk_program}' '{safe_path}' | sponge '{safe_path}'"

    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return {"success": False, "error": result.stderr}
        return {"success": True, "path": safe_path}
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Edit timed out after 30s"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ---------------------------------------------------------------------------
# File Read (Security-Validated)
# ---------------------------------------------------------------------------


def read_file(file_path: str) -> dict[str, Any]:
    """Read a file with blocklist validation."""
    try:
        safe_path = validate_path(file_path)
    except SecurityViolation as e:
        return {"success": False, "error": str(e)}

    try:
        with open(safe_path) as f:
            content = f.read()
        return {"success": True, "content": content, "path": safe_path}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ---------------------------------------------------------------------------
# Directory Listing (Security-Validated)
# ---------------------------------------------------------------------------


def list_directory(dir_path: str) -> dict[str, Any]:
    """List directory contents with blocklist validation."""
    try:
        safe_path = validate_path(dir_path)
    except SecurityViolation as e:
        return {"success": False, "error": str(e)}

    try:
        entries = os.listdir(safe_path)
        items = []
        for entry in sorted(entries):
            full = os.path.join(safe_path, entry)
            items.append({
                "name": entry,
                "is_dir": os.path.isdir(full),
                "size": os.path.getsize(full) if os.path.isfile(full) else None,
            })
        return {"success": True, "path": safe_path, "items": items}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ---------------------------------------------------------------------------
# Shell Command Execution (Security-Validated Working Directory)
# ---------------------------------------------------------------------------


def execute_shell(command: str, working_dir: str | None = None) -> dict[str, Any]:
    """
    Execute a shell command with optional working directory validation.
    """
    if working_dir:
        try:
            validate_path(working_dir)
        except SecurityViolation as e:
            return {"success": False, "error": str(e)}

    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=working_dir,
        )
        return {
            "success": result.returncode == 0,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "returncode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Command timed out after 120s"}
    except Exception as e:
        return {"success": False, "error": str(e)}
