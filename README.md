# wapo
<img width="2093" height="707" alt="image" src="https://github.com/user-attachments/assets/5e76ef28-c62a-41e5-acba-0cf9ef68e2b8" />

wapo is a little menu bar app for macos that puts an ai agent behind a floating chat window. you hit the menu bar item, a glass panel slides in, you type, it streams back. there's a swift app doing the ui and a python backend doing the actual agent work.

it's basically a wrapper. the swift side doesn't care whats on the other end of the socket, it just renders a stream of events. so you can point it at the bundled local backend, or at any openai-compatible endpoint, and the ui behaves the same.

## whats in here

- `Wapo/` - the macos app. swiftui, menu bar only, no dock icon. floating panel, streaming chat, screenshot capture, file attachments, settings window.
- `Backend/` - the python side. a websocket server with two "engines": a fake testing one that streams realistic looking agent events, and a real langgraph one that does parallel fan-out with openai.
- `Config/` - the always-on background agent wiring. openclaw gateway config, launchd plist, heartbeat checklist, mcp server list.

## how it talks

the app and backend talk over a websocket on loopback, `127.0.0.1:8765` by default. messages are json events like `message_start`, `text_delta`, `tool_start`, `tool_end`, `status`, `error`, `message_end`. both engines emit the same event shapes so the ui never has to change when you swap whats behind it.

backends are pluggable behind one swift protocol (`AgentBackend`). there are two right now:

- **local (langgraph)** - the bundled python websocket backend
- **hermes** - any openai-compatible http endpoint, you set the base url, model and key in settings

## requirements

- xcode 26+ and the macos 26 sdk. the ui leans on the new liquid glass apis so older xcode wont build it, sorry.
- python 3.11+

## running it

backend first:

```sh
cd Backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # edit if you want
python3 server.py
```

that starts the websocket server on `127.0.0.1:8765` using the testing engine. you dont strictly have to do this by hand though, the app will try to launch the backend itself on startup (see `BackendProcessController`), it just needs a python3 it can find. set `WAPO_PYTHON_PATH` if it cant.

then open `Wapo.xcodeproj` in xcode and run. it shows up in the menu bar.

if you skip the pip install the backend still runs. theres a dependency-free stdlib server that handles the testing engine, so you can work on the app without installing anything. you only need fastapi/uvicorn/langgraph for the real model-backed stuff.

## the two engines

`WAPO_AGENT_ENGINE` picks which one runs:

- `testing` (default) - no api key, no model calls. it just streams a believable fake agent run, planning, task breakdown, parallel-looking tool activity, then streamed text. good for building the ui.
- `langgraph` - the real one. it decomposes your request into independent subtasks, fans them out in parallel, then merges the results into one answer. needs `OPENAI_API_KEY` and the langgraph deps installed. uses gpt-4o.

## config / env vars

backend:

- `OPENAI_API_KEY` - required for the langgraph engine
- `WAPO_AGENT_ENGINE` - `testing` or `langgraph` (default `testing`)
- `WAPO_BACKEND_HOST` - default `127.0.0.1`
- `WAPO_BACKEND_PORT` - default `8765`

app (all optional):

- `WAPO_PYTHON_PATH` - the python the app uses to launch the backend
- `WAPO_PROJECT_ROOT` / `WAPO_BACKEND_SERVER_PATH` - where to find `server.py` if its not bundled
- `WAPO_BACKEND_HOST` / `WAPO_BACKEND_PORT` / `WAPO_BACKEND_FALLBACK_HOSTS`

theres a `.env.example` in `Backend/` with all of it.

## the background agent stuff (Config/)

heads up, this part is more scaffolding than finished product. the idea is an "openclaw" gateway daemon that runs in the background on a cron heartbeat, checks a task queue, watches your inbox/calendar/files, and can escalate to a twilio voice call if something is on fire and youre not answering text. the config, the launchd plist and the heartbeat protocol are all here. the gateway binary itself is not in this repo, the plist expects it at `/usr/local/lib/openclaw/gateway`. so treat `Config/` as the wiring and the spec, not a turnkey thing.

same deal with the python tools (`sed`/`awk` file editing through `sponge`, tmux background tasks, the mcp watcher, the path blocklist). theyre real and theres a path-validation test, but theyre meant to be driven by the agent, theres no standalone cli around them yet.

## security notes

- everything binds to loopback. no external listeners.
- the python tools run shell commands. theres a hardcoded path blocklist in `security.py` that blocks keychains, the imessage db, `/private/var/db` and a few others, but its a blocklist not a real sandbox. dont point the langgraph engine at untrusted input and assume its safe.
- the app itself is sandboxed (see `Wapo/Wapo.entitlements`), user-selected file access plus app-scoped bookmarks.
- no secrets in the repo, keys come from the environment.

## tests

```sh
cd Backend
python3 -m unittest discover -p "test_*.py"
```

## license

mit, see [LICENSE.txt](LICENSE.txt).
