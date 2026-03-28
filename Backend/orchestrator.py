"""
orchestrator.py — LangGraph DAG with Parallel Fan-Out/Fan-In

Implements the core cognitive engine using LangGraph's Pregel superstep model.
Uses Send() API for dynamic fan-out (no sequential loops) and reducer-safe
state merging for concurrent branch results.
"""

from __future__ import annotations

import json
import time
from typing import Any

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI
from langgraph.graph import END, START, StateGraph
from langgraph.types import RetryPolicy, Send

from prompts import DAG_PROTOCOL_PROMPT, INDEPENDENT_COWORKER_PROMPT, SECURITY_PROMPT
from state import AgentState

# ---------------------------------------------------------------------------
# LLM Configuration
# ---------------------------------------------------------------------------

llm = ChatOpenAI(
    model="gpt-4o",
    temperature=0.3,
    streaming=True,
)

# ---------------------------------------------------------------------------
# System Prompt Assembly
# ---------------------------------------------------------------------------

SYSTEM_MESSAGES = [
    SystemMessage(content=INDEPENDENT_COWORKER_PROMPT),
    SystemMessage(content=DAG_PROTOCOL_PROMPT),
    SystemMessage(content=SECURITY_PROMPT),
]

# ---------------------------------------------------------------------------
# Node: Orchestrator (Planner)
# ---------------------------------------------------------------------------


def orchestrator_node(state: AgentState) -> dict[str, Any]:
    """
    Central planner node. Analyzes the user request, decomposes it into
    parallelizable sub-tasks, and populates active_tasks for fan-out.
    """
    messages = SYSTEM_MESSAGES + [
        HumanMessage(content=msg["content"])
        if msg["role"] == "user"
        else AIMessage(content=msg["content"])
        for msg in state["messages"]
    ]

    planning_prompt = HumanMessage(
        content=(
            "Analyze the latest user request. If it can be decomposed into "
            "independent sub-tasks, output a JSON array of task objects with "
            'keys: "id", "description", "tool". If it\'s a simple query, '
            "respond directly.\n\n"
            "Output format for complex tasks:\n"
            '```json\n[{"id": "task_1", "description": "...", "tool": "..."}]\n```\n\n'
            "Output format for simple queries:\n"
            "Just respond with the answer directly."
        )
    )
    messages.append(planning_prompt)

    start = time.time()
    response = llm.invoke(messages)
    elapsed = round(time.time() - start, 1)

    content = response.content
    status_updates = [
        {"type": "reasoning", "data": f"Planning", "metadata": {"elapsed": str(elapsed)}}
    ]

    # Try to parse as task list for fan-out
    tasks = _try_parse_tasks(content)

    if tasks:
        return {
            "content": "",
            "active_tasks": tasks,
            "findings": [],
            "errors": [],
            "status_updates": status_updates
            + [{"type": "status", "data": f"Dispatching {len(tasks)} parallel tasks"}],
        }
    else:
        # Simple response — no fan-out needed
        return {
            "content": content,
            "active_tasks": [],
            "findings": [],
            "errors": [],
            "status_updates": status_updates
            + [{"type": "content", "data": content}],
        }


def _try_parse_tasks(content: str) -> list[dict] | None:
    """Attempt to extract a JSON task array from LLM output."""
    try:
        # Try to find JSON block in markdown code fence
        if "```json" in content:
            json_str = content.split("```json")[1].split("```")[0].strip()
        elif "```" in content:
            json_str = content.split("```")[1].split("```")[0].strip()
        else:
            json_str = content.strip()

        parsed = json.loads(json_str)
        if isinstance(parsed, list) and len(parsed) > 0 and "id" in parsed[0]:
            return parsed
    except (json.JSONDecodeError, IndexError, KeyError):
        pass
    return None


# ---------------------------------------------------------------------------
# Node: Worker (Parallel Executor)
# ---------------------------------------------------------------------------


def worker_node(state: AgentState) -> dict[str, Any]:
    """
    Executes a single sub-task from the fan-out. Each worker runs in its own
    parallel branch during the same Pregel superstep.
    """
    # The task is passed via Send() — it's in active_tasks[0] for this branch
    tasks = state.get("active_tasks", [])
    if not tasks:
        return {"findings": [], "errors": ["Worker received no task"], "status_updates": []}

    task = tasks[0]
    task_id = task.get("id", "unknown")
    description = task.get("description", "")

    status_updates = [
        {"type": "status", "data": f"Working on: {description}"}
    ]

    try:
        start = time.time()
        messages = SYSTEM_MESSAGES + [
            HumanMessage(
                content=f"Execute this specific sub-task:\n\n{description}\n\n"
                f"Provide a concise, structured result."
            )
        ]
        response = llm.invoke(messages)
        elapsed = round(time.time() - start, 1)

        finding = {
            "task_id": task_id,
            "result": response.content,
            "elapsed": elapsed,
        }

        status_updates.append(
            {"type": "task_update", "data": f"Completed: {task_id} ({elapsed}s)"}
        )

        return {
            "findings": [finding],
            "errors": [],
            "status_updates": status_updates,
        }

    except Exception as e:
        return {
            "findings": [],
            "errors": [f"Worker {task_id} failed: {str(e)}"],
            "status_updates": [{"type": "error", "data": f"Task {task_id} failed: {str(e)}"}],
        }


# ---------------------------------------------------------------------------
# Node: Reducer (Fan-In Synthesizer)
# ---------------------------------------------------------------------------


def reducer_node(state: AgentState) -> dict[str, Any]:
    """
    Merges all parallel worker findings into a single coherent response.
    Runs after all worker branches have completed their superstep.
    """
    findings = state.get("findings", [])
    errors = state.get("errors", [])

    if not findings and errors:
        error_summary = "\n".join(f"- {e}" for e in errors)
        return {
            "content": f"Some tasks encountered errors:\n{error_summary}",
            "status_updates": [
                {"type": "content", "data": f"Completed with {len(errors)} error(s)"}
            ],
        }

    # Synthesize findings
    findings_text = "\n\n".join(
        f"**{f['task_id']}** ({f.get('elapsed', '?')}s):\n{f['result']}"
        for f in findings
    )

    synthesis_prompt = (
        f"Synthesize these parallel task results into a single coherent response "
        f"for the user. Be concise but comprehensive.\n\n{findings_text}"
    )

    start = time.time()
    response = llm.invoke(SYSTEM_MESSAGES + [HumanMessage(content=synthesis_prompt)])
    elapsed = round(time.time() - start, 1)

    return {
        "content": response.content,
        "active_tasks": [],
        "status_updates": [
            {"type": "reasoning", "data": "Synthesizing", "metadata": {"elapsed": str(elapsed)}},
            {"type": "content", "data": response.content},
        ],
    }


# ---------------------------------------------------------------------------
# Routing: Dynamic Fan-Out via Send()
# ---------------------------------------------------------------------------


def route_after_orchestrator(state: AgentState) -> list[Send] | str:
    """
    Conditional edge after orchestrator. If tasks exist, fan-out to parallel
    workers using Send() API. Otherwise, go directly to END.
    """
    tasks = state.get("active_tasks", [])
    if not tasks:
        return END

    # Dynamic fan-out: each Send() spawns a parallel worker branch
    return [
        Send("worker", {**state, "active_tasks": [task]})
        for task in tasks
    ]


# ---------------------------------------------------------------------------
# Graph Assembly
# ---------------------------------------------------------------------------


def build_graph() -> StateGraph:
    """Construct and compile the LangGraph DAG."""
    graph = StateGraph(AgentState)

    # Add nodes with retry policies for transient failures
    retry = RetryPolicy(max_attempts=3)
    graph.add_node("orchestrator", orchestrator_node, retry=retry)
    graph.add_node("worker", worker_node, retry=retry)
    graph.add_node("reducer", reducer_node, retry=retry)

    # Edges
    graph.add_edge(START, "orchestrator")
    graph.add_conditional_edges("orchestrator", route_after_orchestrator, ["worker", END])
    graph.add_edge("worker", "reducer")
    graph.add_edge("reducer", END)

    return graph.compile()


# Singleton compiled graph
agent_graph = build_graph()
