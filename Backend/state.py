"""
state.py — LangGraph Shared State Schema

Defines the TypedDict state schema with explicit Reducer Functions
for concurrent branch safety. Uses operator.add for append-merge
semantics on parallel-written keys.
"""

from __future__ import annotations

import operator
from typing import Annotated, TypedDict


class AgentState(TypedDict):
    """
    Shared state flowing through the LangGraph DAG.

    Reducer semantics:
    - content:          Overwrite (default) — primary conversational output
    - messages:         Append/Merge — full conversation history
    - findings:         Append/Merge — accumulated results from parallel workers
    - active_tasks:     Overwrite — current task queue for fan-out
    - errors:           Append/Merge — isolated error logs from branches
    - status_updates:   Append/Merge — streamed to frontend via WebSocket
    """

    # Core conversational content (overwrite semantics)
    content: str

    # Full message history (append via operator.add)
    messages: Annotated[list[dict], operator.add]

    # Parallel worker findings — safely accumulated across concurrent branches
    findings: Annotated[list[dict], operator.add]

    # Active task queue for dynamic fan-out (overwrite — set by orchestrator)
    active_tasks: list[dict]

    # Error logs from individual branches (append — prevents single-branch crash)
    errors: Annotated[list[str], operator.add]

    # Status updates streamed to the frontend
    status_updates: Annotated[list[dict], operator.add]
