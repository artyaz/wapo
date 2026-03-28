"""
terminal.py — Stateful Terminal Orchestration via libtmux

Manages persistent tmux sessions for long-running background tasks.
The agent can spawn commands, detach, and later reattach to read output
during heartbeat polling cycles.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import libtmux

logger = logging.getLogger("wapo.terminal")

# ---------------------------------------------------------------------------
# Session Manager
# ---------------------------------------------------------------------------

WAPO_SESSION_PREFIX = "wapo-"


@dataclass
class PaneResult:
    """Captured output from a tmux pane."""

    pane_id: str
    output: str
    is_running: bool


class TerminalManager:
    """Manages tmux sessions and panes for background task execution."""

    def __init__(self) -> None:
        self.server = libtmux.Server()
        self._ensure_base_session()

    def _ensure_base_session(self) -> libtmux.Session:
        """Get or create the base Wapo tmux session."""
        session_name = f"{WAPO_SESSION_PREFIX}main"
        try:
            session = self.server.find_where({"session_name": session_name})
            if session:
                return session
        except Exception:
            pass

        return self.server.new_session(session_name=session_name, detach=True)

    # MARK: - Spawn Background Task

    def spawn_task(self, command: str, task_id: str | None = None) -> str:
        """
        Spawn a command in a new tmux pane and return the pane ID.
        The command runs independently — the agent can detach and poll later.
        """
        session = self._ensure_base_session()
        window = session.attached_window

        pane = window.split_window(attach=False)
        pane.send_keys(command, enter=True)

        pane_id = pane.pane_id
        logger.info(f"Spawned task '{task_id or command[:40]}' in pane {pane_id}")
        return pane_id

    # MARK: - Poll Pane Output

    def poll_pane(self, pane_id: str, lines: int = 100) -> PaneResult | None:
        """
        Read the last N lines of stdout from a tmux pane.
        Used during heartbeat events to check on long-running tasks.
        """
        try:
            pane = self.server.find_where({"pane_id": pane_id})
            if not pane:
                return None

            output = pane.cmd("capture-pane", "-p", f"-S-{lines}").stdout
            output_text = "\n".join(output) if isinstance(output, list) else str(output)

            # Check if pane is still running a command
            pane_pid = pane.cmd("display-message", "-p", "#{pane_pid}").stdout
            is_running = bool(pane_pid)

            return PaneResult(
                pane_id=pane_id,
                output=output_text,
                is_running=is_running,
            )
        except Exception as e:
            logger.error(f"Failed to poll pane {pane_id}: {e}")
            return None

    # MARK: - Kill Task

    def kill_pane(self, pane_id: str) -> bool:
        """Kill a tmux pane (terminate the background task)."""
        try:
            pane = self.server.find_where({"pane_id": pane_id})
            if pane:
                pane.cmd("kill-pane")
                logger.info(f"Killed pane {pane_id}")
                return True
        except Exception as e:
            logger.error(f"Failed to kill pane {pane_id}: {e}")
        return False

    # MARK: - List Active Panes

    def list_active_panes(self) -> list[dict]:
        """List all active Wapo tmux panes with their current commands."""
        panes = []
        try:
            for session in self.server.sessions:
                if not session.session_name.startswith(WAPO_SESSION_PREFIX):
                    continue
                for window in session.windows:
                    for pane in window.panes:
                        panes.append({
                            "pane_id": pane.pane_id,
                            "session": session.session_name,
                            "current_command": pane.pane_current_command,
                        })
        except Exception as e:
            logger.error(f"Failed to list panes: {e}")
        return panes

    # MARK: - Cleanup

    def cleanup(self) -> None:
        """Kill all Wapo tmux sessions."""
        try:
            for session in self.server.sessions:
                if session.session_name.startswith(WAPO_SESSION_PREFIX):
                    session.kill_session()
                    logger.info(f"Killed session {session.session_name}")
        except Exception as e:
            logger.error(f"Cleanup error: {e}")
