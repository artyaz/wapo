"""
testing_engine.py — backend-side fake streaming engine for protocol testing.

Emits typed, logically ordered events that simulate:
- planning / reasoning
- task breakdown
- interleaved "parallel" tool activity
- streamed assistant text
"""

from __future__ import annotations

import asyncio
import hashlib
import random
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

EventSender = Callable[[dict[str, object]], Awaitable[None]]


@dataclass(frozen=True)
class ToolSimulation:
    name: str
    title: str
    task_label: str
    args_text: str
    output_chunks: tuple[str, ...]
    completion_text: str


@dataclass(frozen=True)
class Scenario:
    planning_text: str
    reasoning_steps: tuple[str, ...]
    tasks: tuple[str, ...]
    tools: tuple[ToolSimulation, ...]
    interleave_parallel: bool
    final_text: str


async def run_testing_engine(prompt: str, send_event: EventSender) -> None:
    """Stream a fake but realistic agent run for UI development."""
    scenario, rng = _build_scenario(prompt)
    message_id = str(uuid.uuid4())

    await _emit(send_event, "status", scenario.planning_text)
    await _pause(rng, 0.16, 0.3)

    await _emit(
        send_event,
        "reasoning",
        scenario.reasoning_steps[0],
        {"elapsed": f"{rng.uniform(0.6, 1.4):.1f}"},
    )
    await _pause(rng, 0.12, 0.24)

    if scenario.tasks:
        await _emit(
            send_event,
            "status",
            f"Breaking the request into {len(scenario.tasks)} live task(s)…",
        )
        await _pause(rng, 0.12, 0.22)

        for task in scenario.tasks:
            await _emit(send_event, "task_update", task)
            await _pause(rng, 0.08, 0.18)

    await _emit(
        send_event,
        "reasoning",
        scenario.reasoning_steps[1],
        {"elapsed": f"{rng.uniform(0.7, 1.6):.1f}"},
    )
    await _pause(rng, 0.12, 0.22)

    if scenario.interleave_parallel and len(scenario.tools) > 1:
        await _run_parallel_style_tools(send_event, scenario.tools, rng)
    else:
        for tool in scenario.tools:
            await _run_tool(send_event, tool, rng)

    await _emit(
        send_event,
        "reasoning",
        scenario.reasoning_steps[2],
        {"elapsed": f"{rng.uniform(0.6, 1.3):.1f}"},
    )
    await _pause(rng, 0.1, 0.2)

    await _emit(send_event, "message_start", "", {"message_id": message_id})
    await _pause(rng, 0.06, 0.12)

    for delta in _chunk_text(scenario.final_text, rng):
        await _emit(send_event, "text_delta", delta, {"message_id": message_id})
        await _pause(rng, 0.035, 0.08)

    await _emit(send_event, "message_end", "", {"message_id": message_id})


async def _run_parallel_style_tools(
    send_event: EventSender,
    tools: tuple[ToolSimulation, ...],
    rng: random.Random,
) -> None:
    call_ids = {tool.name: f"call_{uuid.uuid4().hex[:10]}" for tool in tools}

    await _emit(send_event, "status", "Dispatching parallel workers…")
    await _pause(rng, 0.1, 0.18)

    for tool in tools:
        await _emit(
            send_event,
            "tool_start",
            tool.title,
            {"call_id": call_ids[tool.name], "tool": tool.name},
        )
        await _pause(rng, 0.06, 0.14)

    for tool in tools:
        await _emit(
            send_event,
            "tool_args",
            tool.args_text,
            {"call_id": call_ids[tool.name], "tool": tool.name},
        )
        await _pause(rng, 0.08, 0.16)

    max_chunks = max(len(tool.output_chunks) for tool in tools)
    for index in range(max_chunks):
        for tool in tools:
            if index >= len(tool.output_chunks):
                continue
            await _emit(
                send_event,
                "tool_output",
                tool.output_chunks[index],
                {"call_id": call_ids[tool.name], "tool": tool.name},
            )
            await _pause(rng, 0.08, 0.16)

    for tool in tools:
        await _emit(
            send_event,
            "tool_end",
            tool.completion_text,
            {
                "call_id": call_ids[tool.name],
                "tool": tool.name,
                "status": "success",
            },
        )
        await _pause(rng, 0.08, 0.18)


async def _run_tool(
    send_event: EventSender,
    tool: ToolSimulation,
    rng: random.Random,
) -> None:
    call_id = f"call_{uuid.uuid4().hex[:10]}"

    await _emit(
        send_event,
        "tool_start",
        tool.title,
        {"call_id": call_id, "tool": tool.name},
    )
    await _pause(rng, 0.12, 0.22)

    await _emit(
        send_event,
        "tool_args",
        tool.args_text,
        {"call_id": call_id, "tool": tool.name},
    )
    await _pause(rng, 0.12, 0.22)

    for chunk in tool.output_chunks:
        await _emit(
            send_event,
            "tool_output",
            chunk,
            {"call_id": call_id, "tool": tool.name},
        )
        await _pause(rng, 0.1, 0.18)

    await _emit(
        send_event,
        "tool_end",
        tool.completion_text,
        {"call_id": call_id, "tool": tool.name, "status": "success"},
    )
    await _pause(rng, 0.14, 0.24)


async def _emit(
    send_event: EventSender,
    event_type: str,
    data: str,
    metadata: dict[str, str] | None = None,
) -> None:
    await send_event({
        "type": event_type,
        "data": data,
        "metadata": metadata,
    })


async def _pause(rng: random.Random, minimum: float, maximum: float) -> None:
    await asyncio.sleep(rng.uniform(minimum, maximum))


def _build_scenario(prompt: str) -> tuple[Scenario, random.Random]:
    cleaned_prompt = prompt.strip()
    attachments = _extract_attachment_names(cleaned_prompt)
    normalized_prompt = cleaned_prompt.lower()

    seed = int(hashlib.sha256(cleaned_prompt.encode("utf-8")).hexdigest()[:16], 16)
    rng = random.Random(seed)

    tools: list[ToolSimulation] = []

    if attachments:
        tools.append(_attachment_tool(attachments))

    if any(word in normalized_prompt for word in ("calendar", "meeting", "schedule")):
        tools.append(_calendar_tool(cleaned_prompt))
    if any(word in normalized_prompt for word in ("inbox", "email", "mail")):
        tools.append(_inbox_tool(cleaned_prompt))
    if any(word in normalized_prompt for word in ("browser", "search", "website", "web")):
        tools.append(_search_tool(cleaned_prompt))
    if any(word in normalized_prompt for word in ("file", "folder", "note", "document", "workspace")):
        tools.append(_workspace_tool(cleaned_prompt))

    if not tools:
        tools.append(rng.choice([
            _workspace_tool(cleaned_prompt),
            _search_tool(cleaned_prompt),
            _summary_tool(cleaned_prompt, attachments),
        ]))

    deduped_tools: list[ToolSimulation] = []
    seen_names: set[str] = set()
    for tool in tools:
        if tool.name in seen_names:
            continue
        deduped_tools.append(tool)
        seen_names.add(tool.name)
        if len(deduped_tools) == 3:
            break

    if len(deduped_tools) == 1:
        fallback = _summary_tool(cleaned_prompt, attachments)
        if fallback.name != deduped_tools[0].name:
            deduped_tools.append(fallback)

    tasks = tuple(tool.task_label for tool in deduped_tools)
    interleave_parallel = len(deduped_tools) > 1

    scenario = Scenario(
        planning_text=rng.choice((
            "Planning the next steps…",
            "Breaking the request into live tasks…",
            "Building an execution path…",
        )),
        reasoning_steps=(
            rng.choice((
                "Scoping the request",
                "Identifying the first useful tools",
                "Choosing the initial plan",
            )),
            rng.choice((
                "Preparing the worker stack",
                "Dispatching work across the task graph",
                "Collecting structured inputs",
            )),
            rng.choice((
                "Synthesizing the final answer",
                "Merging the worker results",
                "Turning the run into a response",
            )),
        ),
        tasks=tasks,
        tools=tuple(deduped_tools),
        interleave_parallel=interleave_parallel,
        final_text=_final_response(cleaned_prompt, attachments, deduped_tools, interleave_parallel, rng),
    )
    return scenario, rng


def _attachment_tool(attachments: list[str]) -> ToolSimulation:
    joined = ", ".join(f'"{name}"' for name in attachments)
    return ToolSimulation(
        name="attachment_inspector",
        title="Inspecting attached files",
        task_label="Inspect attachments and pull out the useful context",
        args_text='{\n  "attachments": [%s],\n  "mode": "summarize"\n}' % joined,
        output_chunks=(
            f"Queued {len(attachments)} attachment(s) for inspection.",
            f"Previewed: {', '.join(attachments[:3])}.",
        ),
        completion_text="Attachment inspection complete",
    )


def _calendar_tool(prompt: str) -> ToolSimulation:
    return ToolSimulation(
        name="calendar_lookup",
        title="Checking schedule context",
        task_label="Check schedule context and timing conflicts",
        args_text='{\n  "query": "%s",\n  "window": "next_7_days"\n}' % _compact(prompt),
        output_chunks=(
            "Found 3 upcoming calendar events related to the request.",
            "Detected a possible overlap on Thursday at 14:00.",
        ),
        completion_text="Calendar lookup complete",
    )


def _inbox_tool(prompt: str) -> ToolSimulation:
    return ToolSimulation(
        name="inbox_triage",
        title="Scanning inbox priorities",
        task_label="Scan the inbox and identify high-priority threads",
        args_text='{\n  "query": "%s",\n  "limit": 12\n}' % _compact(prompt),
        output_chunks=(
            "Ranked 12 messages by urgency and sender importance.",
            "Marked 2 threads as needing a same-day reply.",
        ),
        completion_text="Inbox triage complete",
    )


def _search_tool(prompt: str) -> ToolSimulation:
    return ToolSimulation(
        name="web_search",
        title="Running a quick web search",
        task_label="Search external sources for fresh context",
        args_text='{\n  "query": "%s",\n  "max_results": 5\n}' % _compact(prompt),
        output_chunks=(
            "Collected 5 candidate results.",
            "Pinned 2 likely high-signal sources for the answer.",
        ),
        completion_text="Search run complete",
    )


def _workspace_tool(prompt: str) -> ToolSimulation:
    return ToolSimulation(
        name="workspace_search",
        title="Searching local workspace context",
        task_label="Search the local workspace for relevant context",
        args_text='{\n  "query": "%s",\n  "scope": "recent_files"\n}' % _compact(prompt),
        output_chunks=(
            "Matched 4 local notes and 1 recent project artifact.",
            "Extracted the most relevant snippets for synthesis.",
        ),
        completion_text="Workspace search complete",
    )


def _summary_tool(prompt: str, attachments: list[str]) -> ToolSimulation:
    target = attachments[0] if attachments else "collected findings"
    return ToolSimulation(
        name="answer_synthesizer",
        title="Summarizing the gathered context",
        task_label="Summarize the findings into a reply draft",
        args_text='{\n  "target": "%s",\n  "goal": "draft_reply"\n}' % _compact(target),
        output_chunks=(
            "Condensed the findings into a short narrative.",
            f"Prepared a reply draft tailored to: {_compact(prompt)}.",
        ),
        completion_text="Summary draft prepared",
    )


def _extract_attachment_names(prompt: str) -> list[str]:
    lines = [line.strip() for line in prompt.splitlines()]
    try:
        start = lines.index("Attachments:") + 1
    except ValueError:
        return []

    attachments: list[str] = []
    for line in lines[start:]:
        if not line.startswith("- "):
            break
        attachments.append(line.removeprefix("- ").strip())
    return attachments


def _final_response(
    prompt: str,
    attachments: list[str],
    tools: list[ToolSimulation],
    interleave_parallel: bool,
    rng: random.Random,
) -> str:
    opener = rng.choice((
        "Here’s a streamed test response from the local backend engine.",
        "The backend just emitted a simulated live agent run.",
        "This is a fake backend pass designed to exercise the realtime UI.",
    ))
    tool_summary = ", ".join(tool.title.lower() for tool in tools)
    execution_note = (
        " It also interleaved multiple tool runs to mimic parallel work."
        if interleave_parallel
        else ""
    )
    attachment_summary = (
        f" I also noticed {len(attachments)} attachment(s): {', '.join(attachments[:3])}."
        if attachments
        else ""
    )
    prompt_summary = _compact(prompt) or "your latest request"

    return (
        f"{opener} It walked through {tool_summary}, streamed task breakdown and tool progress, "
        f"and then assembled this reply around “{prompt_summary}”.{execution_note}{attachment_summary}\n\n"
        "Once the real model backend is connected, it can emit the same event types and the UI should "
        "behave the same way without another protocol change."
    )


def _chunk_text(text: str, rng: random.Random) -> list[str]:
    chunks: list[str] = []
    cursor = 0

    while cursor < len(text):
        step = rng.randint(18, 38)
        end = min(len(text), cursor + step)
        while end < len(text) and text[end] not in {" ", "\n"}:
            end += 1
        chunks.append(text[cursor:end])
        cursor = end

    return [chunk for chunk in chunks if chunk]


def _compact(text: str, limit: int = 120) -> str:
    compacted = " ".join(part for part in text.split())
    if len(compacted) <= limit:
        return compacted
    return compacted[: limit - 1].rstrip() + "…"
