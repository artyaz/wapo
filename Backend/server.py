"""
server.py — local backend entrypoint.

Uses FastAPI/Uvicorn when available. Falls back to a dependency-free stdlib
HTTP + WebSocket server so the backend-side testing transport still works in
minimal local environments.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from contextlib import asynccontextmanager

from testing_engine import run_testing_engine

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("wapo.server")
DEFAULT_ENGINE = os.environ.get("WAPO_AGENT_ENGINE", "testing").strip().lower()
HOST = os.environ.get("WAPO_BACKEND_HOST", "127.0.0.1").strip() or "127.0.0.1"
PORT = int(os.environ.get("WAPO_BACKEND_PORT", "8765"))

try:
    from fastapi import FastAPI, WebSocket, WebSocketDisconnect
    from fastapi.responses import JSONResponse
except ModuleNotFoundError:
    FastAPI = None
    WebSocket = None
    WebSocketDisconnect = Exception
    JSONResponse = None


if FastAPI is not None:
    class ConnectionManager:
        """Manages active FastAPI WebSocket connections."""

        def __init__(self) -> None:
            self.active: list[WebSocket] = []

        async def connect(self, ws: WebSocket) -> None:
            await ws.accept()
            self.active.append(ws)
            logger.info(f"Client connected. Total: {len(self.active)}")

        def disconnect(self, ws: WebSocket) -> None:
            if ws in self.active:
                self.active.remove(ws)
            logger.info(f"Client disconnected. Total: {len(self.active)}")

        @property
        def connection_count(self) -> int:
            return len(self.active)


    manager = ConnectionManager()


    @asynccontextmanager
    async def lifespan(app: FastAPI):
        logger.info(f"Wapo backend starting on ws://{HOST}:{PORT} (engine={DEFAULT_ENGINE})")
        yield
        logger.info("Wapo backend shutting down")


    app = FastAPI(title="Wapo Backend", lifespan=lifespan)


    @app.get("/health")
    async def health():
        return JSONResponse({
            "status": "ok",
            "connections": manager.connection_count,
            "engine": DEFAULT_ENGINE,
        })


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

                engine = _resolve_engine(ws.query_params.get("engine"), data.get("engine"))
                asyncio.create_task(_process_fastapi_message(ws, content, engine))
        except WebSocketDisconnect:
            manager.disconnect(ws)
        except Exception as exc:
            logger.error(f"WebSocket error: {exc}")
            manager.disconnect(ws)


    async def _process_fastapi_message(ws: WebSocket, content: str, engine: str) -> None:
        if engine == "testing":
            await run_testing_engine(content, lambda event: _send_fastapi_json(ws, event))
            return

        if engine == "langgraph":
            await _process_fastapi_langgraph(ws, content)
            return

        await _send_fastapi_json(ws, {
            "type": "error",
            "data": f"Unknown engine: {engine}",
            "metadata": None,
        })


    async def _process_fastapi_langgraph(ws: WebSocket, content: str) -> None:
        try:
            from orchestrator import agent_graph
        except Exception as exc:
            await _send_fastapi_json(ws, {
                "type": "error",
                "data": f"LangGraph backend unavailable: {exc}",
                "metadata": None,
            })
            return

        initial_state = {
            "content": "",
            "messages": [{"role": "user", "content": content}],
            "findings": [],
            "active_tasks": [],
            "errors": [],
            "status_updates": [],
        }

        await _send_fastapi_json(ws, {
            "type": "status",
            "data": "Processing your request…",
            "metadata": None,
        })

        try:
            config = {"max_concurrency": 5}
            result = await asyncio.to_thread(agent_graph.invoke, initial_state, config=config)
        except Exception as exc:
            await _send_fastapi_json(ws, {
                "type": "error",
                "data": f"LangGraph execution failed: {exc}",
                "metadata": None,
            })
            return

        for update in result.get("status_updates", []):
            await _send_fastapi_json(ws, {
                "type": update.get("type", "status"),
                "data": update.get("data", ""),
                "metadata": update.get("metadata"),
            })
            await asyncio.sleep(0.05)

        final_content = result.get("content", "")
        if final_content and not any(
            item.get("type") == "content" for item in result.get("status_updates", [])
        ):
            await _send_fastapi_json(ws, {
                "type": "content",
                "data": final_content,
                "metadata": None,
            })

        for error in result.get("errors", []):
            await _send_fastapi_json(ws, {
                "type": "error",
                "data": error,
                "metadata": None,
            })


    async def _send_fastapi_json(ws: WebSocket, message: dict) -> None:
        await ws.send_text(json.dumps(message))


def _resolve_engine(query_engine: str | None, payload_engine: object) -> str:
    if isinstance(payload_engine, str) and payload_engine.strip():
        return payload_engine.strip().lower()

    if isinstance(query_engine, str) and query_engine.strip():
        return query_engine.strip().lower()

    return DEFAULT_ENGINE


def main() -> None:
    if FastAPI is not None:
        try:
            import uvicorn
        except ModuleNotFoundError:
            logger.warning("FastAPI is installed but uvicorn is missing; using stdlib fallback server.")
        else:
            uvicorn.run("server:app", host=HOST, port=PORT, log_level="info")
            return

    from stdlib_websocket_server import run_stdlib_server

    logger.info("FastAPI/Uvicorn unavailable; starting stdlib backend fallback.")
    asyncio.run(run_stdlib_server(host=HOST, port=PORT, default_engine=DEFAULT_ENGINE))


if __name__ == "__main__":
    main()
