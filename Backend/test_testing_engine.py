from __future__ import annotations

import unittest

from testing_engine import run_testing_engine


class TestingEngineTests(unittest.IsolatedAsyncioTestCase):
    async def _collect(self, prompt: str) -> list[dict]:
        events: list[dict] = []

        async def capture(event: dict) -> None:
            events.append(event)

        await run_testing_engine(prompt, capture)
        return events

    async def test_streaming_bookends_are_present(self) -> None:
        events = await self._collect("Please summarize my recent notes")
        types = [event["type"] for event in events]

        self.assertEqual(types[0], "status")
        self.assertIn("reasoning", types)
        self.assertIn("message_start", types)
        self.assertIn("text_delta", types)
        self.assertEqual(types[-1], "message_end")
        self.assertLess(types.index("message_start"), types.index("text_delta"))

    async def test_attachment_prompt_emits_attachment_tool(self) -> None:
        events = await self._collect(
            "Summarize the attached material\n\nAttachments:\n- notes.txt\n- plan.pdf"
        )
        attachment_tools = [
            event for event in events
            if event["type"] == "tool_start"
            and event.get("metadata", {}).get("tool") == "attachment_inspector"
        ]

        self.assertGreaterEqual(len(attachment_tools), 1)

    async def test_parallel_prompt_breaks_into_tasks_before_tools(self) -> None:
        events = await self._collect(
            "Check my calendar and inbox, then search the web for follow-up material"
        )
        types = [event["type"] for event in events]

        self.assertIn("task_update", types)
        self.assertGreaterEqual(types.count("tool_start"), 2)
        self.assertLess(types.index("task_update"), types.index("tool_start"))

    async def test_tool_lifecycle_pairs_call_ids(self) -> None:
        events = await self._collect(
            "Review my inbox, workspace notes, and schedule for today"
        )
        started = {
            event["metadata"]["call_id"]
            for event in events
            if event["type"] == "tool_start"
        }
        completed = {
            event["metadata"]["call_id"]
            for event in events
            if event["type"] == "tool_end"
        }

        self.assertSetEqual(started, completed)

    async def test_reasoning_precedes_task_breakdown_and_tools(self) -> None:
        events = await self._collect(
            "Please search the workspace and attachments for this topic\n\nAttachments:\n- brief.md"
        )
        types = [event["type"] for event in events]

        self.assertLess(types.index("reasoning"), types.index("task_update"))
        self.assertLess(types.index("reasoning"), types.index("tool_start"))


if __name__ == "__main__":
    unittest.main()
