"""
stdlib_websocket_server.py — dependency-free local backend test server.

Provides:
- GET /health
- WebSocket endpoint at /ws

This exists so the app can exercise a real backend-side streaming transport
even when FastAPI/Uvicorn/websocket packages are not installed locally.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import json
import logging
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, urlsplit

from testing_engine import run_testing_engine

logger = logging.getLogger("wapo.stdlib_server")
_WS_ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WebSocketClosed(Exception):
    pass


@dataclass(frozen=True)
class HTTPRequest:
    method: str
    path: str
    query: dict[str, str]
    headers: dict[str, str]


class StdlibConnectionManager:
    def __init__(self) -> None:
        self.active: set[StdlibWebSocketConnection] = set()

    async def connect(self, connection: StdlibWebSocketConnection) -> None:
        self.active.add(connection)
        logger.info(f"Client connected. Total: {len(self.active)}")

    def disconnect(self, connection: StdlibWebSocketConnection) -> None:
        self.active.discard(connection)
        logger.info(f"Client disconnected. Total: {len(self.active)}")

    @property
    def connection_count(self) -> int:
        return len(self.active)


class StdlibWebSocketConnection:
    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        query: dict[str, str],
    ) -> None:
        self.reader = reader
        self.writer = writer
        self.query = query
        self._write_lock = asyncio.Lock()

    async def send_text(self, text: str) -> None:
        payload = text.encode("utf-8")
        frame = bytearray([0x81])
        frame.extend(_encoded_length(len(payload)))

        async with self._write_lock:
            self.writer.write(frame + payload)
            await self.writer.drain()

    async def send_json(self, message: dict[str, Any]) -> None:
        await self.send_text(json.dumps(message))

    async def receive_text(self) -> str:
        while True:
            header = await self.reader.readexactly(2)
            opcode = header[0] & 0x0F
            masked = bool(header[1] & 0x80)
            payload_length = header[1] & 0x7F

            if payload_length == 126:
                payload_length = int.from_bytes(await self.reader.readexactly(2), "big")
            elif payload_length == 127:
                payload_length = int.from_bytes(await self.reader.readexactly(8), "big")

            masking_key = await self.reader.readexactly(4) if masked else b""
            payload = await self.reader.readexactly(payload_length)

            if masked:
                payload = bytes(
                    byte ^ masking_key[index % 4]
                    for index, byte in enumerate(payload)
                )

            if opcode == 0x8:
                raise WebSocketClosed()

            if opcode == 0x9:
                await self._send_control_frame(0xA, payload)
                continue

            if opcode != 0x1:
                continue

            return payload.decode("utf-8")

    async def close(self) -> None:
        try:
            await self._send_control_frame(0x8, b"")
        except Exception:
            pass
        self.writer.close()
        with contextlib.suppress(Exception):
            await self.writer.wait_closed()

    async def _send_control_frame(self, opcode: int, payload: bytes) -> None:
        frame = bytearray([0x80 | opcode])
        frame.extend(_encoded_length(len(payload)))

        async with self._write_lock:
            self.writer.write(frame + payload)
            await self.writer.drain()


def _encoded_length(length: int) -> bytes:
    if length <= 125:
        return bytes([length])
    if length <= 65535:
        return bytes([126]) + length.to_bytes(2, "big")
    return bytes([127]) + length.to_bytes(8, "big")


async def run_stdlib_server(host: str, port: int, default_engine: str) -> None:
    manager = StdlibConnectionManager()

    async def handle_client(
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        try:
            request = await _read_http_request(reader)
        except Exception as exc:
            logger.error(f"Failed to read HTTP request: {exc}")
            writer.close()
            return

        if request.method == "GET" and request.path == "/health":
            await _send_health_response(writer, manager.connection_count, default_engine)
            return

        if request.method == "GET" and request.path == "/ws":
            try:
                connection = await _accept_websocket(request, reader, writer)
            except Exception as exc:
                logger.error(f"WebSocket handshake failed: {exc}")
                await _send_http_error(writer, 400, "Bad Request")
                return

            await manager.connect(connection)
            try:
                while True:
                    raw = await connection.receive_text()
                    data = json.loads(raw)
                    content = data.get("content", "")
                    if not content:
                        continue

                    engine = _resolve_engine(connection.query, data, default_engine)
                    asyncio.create_task(_process_message(connection, content, engine))
            except (asyncio.IncompleteReadError, ConnectionResetError, WebSocketClosed):
                manager.disconnect(connection)
            except Exception as exc:
                logger.error(f"WebSocket error: {exc}")
                manager.disconnect(connection)
            finally:
                await connection.close()
            return

        await _send_http_error(writer, 404, "Not Found")

    server = await asyncio.start_server(handle_client, host, port)
    sockets = server.sockets or []
    bound = sockets[0].getsockname() if sockets else (host, port)
    logger.info(f"Wapo stdlib backend starting on ws://{bound[0]}:{bound[1]}")

    async with server:
        await server.serve_forever()


async def _process_message(
    connection: StdlibWebSocketConnection,
    content: str,
    engine: str,
) -> None:
    try:
        if engine == "testing":
            await run_testing_engine(content, connection.send_json)
            return

        if engine == "langgraph":
            await _process_message_langgraph(connection, content)
            return

        await connection.send_json({
            "type": "error",
            "data": f"Unknown engine: {engine}",
            "metadata": None,
        })
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError, WebSocketClosed):
        logger.info("Client disconnected while streaming a response.")


async def _process_message_langgraph(
    connection: StdlibWebSocketConnection,
    content: str,
) -> None:
    try:
        from orchestrator import agent_graph
    except Exception as exc:
        await connection.send_json({
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

    await connection.send_json({
        "type": "status",
        "data": "Processing your request…",
        "metadata": None,
    })

    try:
        config = {"max_concurrency": 5}
        result = await asyncio.to_thread(agent_graph.invoke, initial_state, config=config)
    except Exception as exc:
        await connection.send_json({
            "type": "error",
            "data": f"LangGraph execution failed: {exc}",
            "metadata": None,
        })
        return

    for update in result.get("status_updates", []):
        await connection.send_json({
            "type": update.get("type", "status"),
            "data": update.get("data", ""),
            "metadata": update.get("metadata"),
        })
        await asyncio.sleep(0.05)

    final_content = result.get("content", "")
    if final_content and not any(
        item.get("type") == "content" for item in result.get("status_updates", [])
    ):
        await connection.send_json({
            "type": "content",
            "data": final_content,
            "metadata": None,
        })

    for error in result.get("errors", []):
        await connection.send_json({
            "type": "error",
            "data": error,
            "metadata": None,
        })


async def _read_http_request(reader: asyncio.StreamReader) -> HTTPRequest:
    raw = await reader.readuntil(b"\r\n\r\n")
    lines = raw.decode("utf-8").split("\r\n")
    method, target, _ = lines[0].split(" ", 2)
    parsed = urlsplit(target)
    headers: dict[str, str] = {}

    for line in lines[1:]:
        if not line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()

    query = {
        key: values[-1]
        for key, values in parse_qs(parsed.query, keep_blank_values=False).items()
    }
    return HTTPRequest(method=method, path=parsed.path, query=query, headers=headers)


async def _accept_websocket(
    request: HTTPRequest,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> StdlibWebSocketConnection:
    key = request.headers.get("sec-websocket-key")
    if not key:
        raise ValueError("Missing Sec-WebSocket-Key")

    accept = base64.b64encode(
        hashlib.sha1(f"{key}{_WS_ACCEPT_GUID}".encode("utf-8")).digest()
    ).decode("utf-8")

    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    writer.write(response.encode("utf-8"))
    await writer.drain()
    return StdlibWebSocketConnection(reader, writer, request.query)


async def _send_health_response(
    writer: asyncio.StreamWriter,
    connection_count: int,
    default_engine: str,
) -> None:
    payload = json.dumps({
        "status": "ok",
        "connections": connection_count,
        "engine": default_engine,
    }).encode("utf-8")
    response = (
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(payload)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("utf-8") + payload
    writer.write(response)
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def _send_http_error(
    writer: asyncio.StreamWriter,
    status_code: int,
    message: str,
) -> None:
    payload = message.encode("utf-8")
    response = (
        f"HTTP/1.1 {status_code} {message}\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        f"Content-Length: {len(payload)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("utf-8") + payload
    writer.write(response)
    await writer.drain()
    writer.close()
    await writer.wait_closed()


def _resolve_engine(
    query: dict[str, str],
    payload: dict[str, Any],
    default_engine: str,
) -> str:
    payload_engine = payload.get("engine")
    if isinstance(payload_engine, str) and payload_engine.strip():
        return payload_engine.strip().lower()

    query_engine = query.get("engine")
    if query_engine:
        return query_engine.strip().lower()

    return default_engine
