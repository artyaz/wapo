"""
heartbeat.py — Proactive Background Heartbeat Protocol

Implements the cron-triggered heartbeat that wakes the agent periodically.
The agent evaluates its task queue, checks environmental context, and
either takes autonomous action or returns HEARTBEAT_OK.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime
from pathlib import Path

logger = logging.getLogger("wapo.heartbeat")

WORKSPACE_DIR = Path(os.path.expanduser("~/.wapo"))
HEARTBEAT_FILE = WORKSPACE_DIR / "HEARTBEAT.md"


# ---------------------------------------------------------------------------
# Heartbeat Checklist Management
# ---------------------------------------------------------------------------


def ensure_heartbeat_file() -> Path:
    """Create the HEARTBEAT.md workspace file if it doesn't exist."""
    WORKSPACE_DIR.mkdir(parents=True, exist_ok=True)

    if not HEARTBEAT_FILE.exists():
        HEARTBEAT_FILE.write_text(
            "# Wapo Heartbeat Checklist\n\n"
            "## Recurring Background Duties\n\n"
            "- [ ] Check pending task queue\n"
            "- [ ] Monitor designated email inboxes\n"
            "- [ ] Review calendar for upcoming conflicts\n"
            "- [ ] Check watched file system paths for changes\n"
            "- [ ] Poll active tmux panes for completed tasks\n"
            "- [ ] Review MCP server health\n\n"
            "## Last Heartbeat\n\n"
            f"- {datetime.now().isoformat()}: Initialized\n"
        )
        logger.info(f"Created HEARTBEAT.md at {HEARTBEAT_FILE}")

    return HEARTBEAT_FILE


def read_heartbeat_tasks() -> list[str]:
    """Parse incomplete tasks from HEARTBEAT.md."""
    ensure_heartbeat_file()
    tasks = []
    for line in HEARTBEAT_FILE.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("- [ ]"):
            tasks.append(stripped[6:].strip())
    return tasks


def log_heartbeat(status: str, details: str = "") -> None:
    """Append a heartbeat log entry to HEARTBEAT.md."""
    ensure_heartbeat_file()
    timestamp = datetime.now().isoformat()
    entry = f"- {timestamp}: {status}"
    if details:
        entry += f" — {details}"

    content = HEARTBEAT_FILE.read_text()
    # Insert after "## Last Heartbeat" section
    marker = "## Last Heartbeat\n\n"
    if marker in content:
        parts = content.split(marker, 1)
        content = parts[0] + marker + entry + "\n" + parts[1]
    else:
        content += f"\n{entry}\n"

    HEARTBEAT_FILE.write_text(content)


# ---------------------------------------------------------------------------
# Heartbeat Execution
# ---------------------------------------------------------------------------


async def execute_heartbeat(agent_graph, terminal_manager=None) -> dict:
    """
    Execute a single heartbeat cycle:
    1. Read pending tasks from HEARTBEAT.md
    2. Poll tmux panes for completed background tasks
    3. Evaluate whether action is required
    4. Return HEARTBEAT_OK or action results
    """
    import asyncio

    tasks = read_heartbeat_tasks()
    logger.info(f"Heartbeat: {len(tasks)} pending duties")

    results = {
        "status": "HEARTBEAT_OK",
        "tasks_checked": len(tasks),
        "actions_taken": [],
        "timestamp": datetime.now().isoformat(),
    }

    # Poll tmux panes if terminal manager is available
    if terminal_manager:
        active_panes = terminal_manager.list_active_panes()
        for pane_info in active_panes:
            pane_result = terminal_manager.poll_pane(pane_info["pane_id"])
            if pane_result and not pane_result.is_running:
                results["actions_taken"].append({
                    "type": "task_completed",
                    "pane_id": pane_info["pane_id"],
                    "output_tail": pane_result.output[-500:] if pane_result.output else "",
                })

    # If actions were taken, update status
    if results["actions_taken"]:
        results["status"] = "HEARTBEAT_ACTION"
        log_heartbeat("HEARTBEAT_ACTION", f"{len(results['actions_taken'])} actions taken")
    else:
        log_heartbeat("HEARTBEAT_OK")

    return results


# ---------------------------------------------------------------------------
# Heartbeat Cron Trigger (called by OpenClaw Gateway)
# ---------------------------------------------------------------------------


def handle_heartbeat_webhook(payload: dict) -> dict:
    """
    Handle an incoming heartbeat trigger from the OpenClaw Gateway.
    This is called via the Gateway's cron scheduler.
    """
    trigger_type = payload.get("trigger", "cron")
    logger.info(f"Heartbeat triggered: {trigger_type}")

    # Return the heartbeat status for the Gateway to process
    # HEARTBEAT_OK is suppressed by the Gateway (no user notification)
    # HEARTBEAT_ACTION triggers a proactive push to the user
    return {
        "trigger": trigger_type,
        "timestamp": datetime.now().isoformat(),
        "status": "pending",
    }
