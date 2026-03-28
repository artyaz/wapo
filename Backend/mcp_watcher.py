"""
mcp_watcher.py — Dynamic MCP Configuration Watcher

Monitors the MCP configuration directory for changes and dynamically
loads/unloads MCP server connections and Composio plugin integrations
in real-time. Uses watchfiles for efficient filesystem event detection.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

logger = logging.getLogger("wapo.mcp_watcher")

MCP_CONFIG_DIR = Path.home() / ".wapo" / "mcp_servers"
COMPOSIO_CONFIG = Path.home() / ".wapo" / "composio.json"


# ---------------------------------------------------------------------------
# MCP Server Registry
# ---------------------------------------------------------------------------


class MCPRegistry:
    """Tracks active MCP server configurations and their capabilities."""

    def __init__(self) -> None:
        self.servers: dict[str, dict[str, Any]] = {}
        self.composio_apps: dict[str, dict[str, Any]] = {}

    def load_server(self, config_path: Path) -> None:
        """Load an MCP server configuration from a JSON file."""
        try:
            config = json.loads(config_path.read_text())
            server_id = config.get("id", config_path.stem)
            self.servers[server_id] = {
                "id": server_id,
                "name": config.get("name", server_id),
                "command": config.get("command"),
                "args": config.get("args", []),
                "env": config.get("env", {}),
                "capabilities": config.get("capabilities", []),
                "config_path": str(config_path),
            }
            logger.info(f"Loaded MCP server: {server_id} ({len(config.get('capabilities', []))} capabilities)")
        except Exception as e:
            logger.error(f"Failed to load MCP config {config_path}: {e}")

    def unload_server(self, server_id: str) -> None:
        """Remove an MCP server from the registry."""
        if server_id in self.servers:
            del self.servers[server_id]
            logger.info(f"Unloaded MCP server: {server_id}")

    def load_composio_config(self) -> None:
        """Load Composio plugin integrations for SaaS OAuth handling."""
        if not COMPOSIO_CONFIG.exists():
            return

        try:
            config = json.loads(COMPOSIO_CONFIG.read_text())
            for app in config.get("apps", []):
                app_id = app.get("id", app.get("name", "unknown"))
                self.composio_apps[app_id] = {
                    "id": app_id,
                    "name": app.get("name"),
                    "auth_type": app.get("auth_type", "oauth2"),
                    "scopes": app.get("scopes", []),
                    "enabled": app.get("enabled", True),
                }
            logger.info(f"Loaded {len(self.composio_apps)} Composio integrations")
        except Exception as e:
            logger.error(f"Failed to load Composio config: {e}")

    def get_all_capabilities(self) -> list[str]:
        """Return a flat list of all available capabilities across servers."""
        caps = []
        for server in self.servers.values():
            caps.extend(server.get("capabilities", []))
        for app in self.composio_apps.values():
            if app.get("enabled"):
                caps.append(f"composio:{app['id']}")
        return caps

    def get_context_summary(self) -> str:
        """Generate a summary for injection into the LLM context window."""
        lines = ["Available MCP Tools and Integrations:\n"]
        for sid, server in self.servers.items():
            caps = ", ".join(server.get("capabilities", [])) or "none"
            lines.append(f"  - {server['name']} ({sid}): {caps}")
        for aid, app in self.composio_apps.items():
            status = "enabled" if app.get("enabled") else "disabled"
            lines.append(f"  - Composio/{app['name']} ({aid}): {status}")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# File Watcher
# ---------------------------------------------------------------------------

registry = MCPRegistry()


def initial_load() -> None:
    """Load all existing MCP configs on startup."""
    MCP_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    for config_file in MCP_CONFIG_DIR.glob("*.json"):
        registry.load_server(config_file)

    registry.load_composio_config()
    logger.info(f"Initial load: {len(registry.servers)} MCP servers, {len(registry.composio_apps)} Composio apps")


async def watch_config_changes() -> None:
    """
    Watch the MCP config directory for file changes.
    When a new server config is added/modified, reload it instantly.
    """
    from watchfiles import awatch, Change

    initial_load()

    logger.info(f"Watching {MCP_CONFIG_DIR} for configuration changes")

    async for changes in awatch(MCP_CONFIG_DIR, COMPOSIO_CONFIG.parent):
        for change_type, path in changes:
            path = Path(path)

            if path == COMPOSIO_CONFIG:
                registry.load_composio_config()
                continue

            if not path.suffix == ".json":
                continue

            if change_type in (Change.added, Change.modified):
                registry.load_server(path)
            elif change_type == Change.deleted:
                registry.unload_server(path.stem)

            logger.info(f"Config change detected: {change_type.name} {path.name}")
