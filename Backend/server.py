"""
server.py — WebSocket Server & FastAPI Gateway

Bridges the LangGraph orchestrator to the SwiftUI frontend via persistent
WebSocket connections. Streams reasoning telemetry, status updates, and
agent responses in real-time.
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from orchestrator import agent_graph
from state import AgentState

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("wapo.server")

# ---------------------------------------------------------------------------
# Connection Manager
# ---------------------------------------------------------------------------


class ConnectionManager:
    """Manages active WebSocket connections."""

    def __init__(self) -> None:
        self.active: list[WebSocket] = []

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self.active.append(ws)
        logger.info(f"Client connected. Total: {len(self.active)}")

    def disconnect(self, ws: WebSocket) -> None:
        self.active.remove(ws)
        logger.info(f"Client disconnected. Total: {len(self.active)}")

    async def broadcast(self, message: dict) -> None:
        payload = json.dumps(message)
        for ws in self.active:
            try:
                await ws.send_text(payload)
            except Exception:
                pass


manager = ConnectionManager()

# ---------------------------------------------------------------------------
# FastAPI App
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Wapo backend starting on ws://127.0.0.1:8765")
    yield
    logger.info("Wapo backend shutting down")


app = FastAPI(title="Wapo Backend", lifespan=lifespan)


@app.get("/health")
async def health():
    return JSONResponse({"status": "ok", "connections": len(manager.active)})


# ---------------------------------------------------------------------------
# WebSocket Endpoint
# ---------------------------------------------------------------------------


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await manager.connect(ws)
    try:
        while True:
            raw = await ws.receive_text()
            data = json.loads(raw)
            content = data.get("content", "")

            if not content:
                continue

            # Process through LangGraph DAG
            asyncio.create_task(_process_message(ws, content))

    except WebSocketDisconnect:
        manager.disconnect(ws)
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
        manager.disconnect(ws)


async def _process_message(ws: WebSocket, content: str) -> None:
    """Run the LangGraph agent and stream status updates to the client."""
    try:
        # Initial state
        initial_state: AgentState = {
            "content": "",
            "messages": [{"role": "user", "content": content}],
            "findings": [],
            "active_tasks": [],
            "errors": [],
            "status_updates": [],
        }

        # Send "thinking" status
        await ws.send_text(json.dumps({
            "type": "status",
            "data": "Processing your request…",
            "metadata": None,
        }))

        # Run the graph with max_concurrency control
        config = {"max_concurrency": 5}
        result = await asyncio.to_thread(
            agent_graph.invoke, initial_state, config=config
        )

        # Stream accumulated status updates
        for update in result.get("status_updates", []):
            msg = {
                "type": update.get("type", "status"),
                "data": update.get("data", ""),
                "metadata": update.get("metadata"),
            }
            await ws.send_text(json.dumps(msg))
            await asyncio.sleep(0.05)  # Small delay for visual progression

        # Send final content if not already sent via status_updates
        final_content = result.get("content", "")
        if final_content:
            has_content_update = any(
                u.get("type") == "content" for u in result.get("status_updates", [])
            )
            if not has_content_update:
                await ws.send_text(json.dumps({
                    "type": "content",
                    "data": final_content,
                    "metadata": None,
                }))

        # Report any errors
        for error in result.get("errors", []):
            await ws.send_text(json.dumps({
                "type": "error",
                "data": error,
                "metadata": None,
            }))

    except Exception as e:
        logger.error(f"Processing error: {e}")
        await ws.send_text(json.dumps({
            "type": "error",
            "data": f"Internal error: {str(e)}",
            "metadata": None,
        }))


# ---------------------------------------------------------------------------
# Entry Point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=8765,
        log_level="info",
    )
