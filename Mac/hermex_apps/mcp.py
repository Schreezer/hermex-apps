"""Hermes' side of the Mac: a stdio MCP server (JSON-RPC, one message per line).

Fixed tools run the factory and talk to the phone (`apps_*`). Each built app
adds its own data tools under its prefix (`lift_log_set_done`), and the server
sends `notifications/tools/list_changed` whenever an app's tools change, so
Hermes picks up a new app without a restart.
"""

from __future__ import annotations

import hashlib
import json
import sys
import threading
import time
from typing import Any, Callable

from . import appapi, factory, store
from .store import AppsError

PROTOCOL_VERSION = "2025-06-18"
INSTRUCTIONS = (
    "Hermex Apps: SwiftUI apps you build on this Mac for the user's iPhone. "
    "The hermex-apps skill says when to offer one and how to use the user's apps; "
    "the hermex-app-factory skill builds or changes one. Each app's data lives "
    "here; use its own tools (prefixed with the app id) to read or change it, and "
    "the app open on the phone refreshes by itself."
)

_STRING_LIST = {"type": "array", "items": {"type": "string"}}
_LOOK = {
    "name": {"type": "string", "description": "Display name, e.g. Lift Log."},
    "tagline": {"type": "string", "description": "A few words for list rows, e.g. 'Push / pull / legs · sets per lift'."},
    "summary": {"type": "string", "description": "One sentence for the app's card."},
    "symbol": {"type": "string", "description": "SF Symbol for the icon tile, e.g. dumbbell.fill."},
    "color": {"type": "string", "description": "Icon tile color as #RRGGBB."},
    "ink": {"type": "string", "description": "Symbol color on the tile as #RRGGBB, with strong contrast to color."},
    "routes": {**_STRING_LIST, "description": "Deep-link routes the app handles, e.g. ['today', 'history', 'lift/{id}']."},
    "origin": {"type": "string", "description": "Optional: where the app came from when not built from scratch, e.g. 'From a GitHub repo · owner/name (MIT)'."},
}


def _schema(properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


FIXED_TOOLS: list[dict[str, Any]] = [
    {
        "name": "apps_list",
        "description": "The apps built for the user: version, routes, and each app's data tools.",
        "inputSchema": _schema({}, []),
    },
    {
        "name": "apps_create",
        "description": "Start a new app from the template (SwiftUI project + data API). Returns the folder to edit. "
                       "Then write the app and call apps_build.",
        "inputSchema": _schema(
            {"app_id": {"type": "string", "description": "Lowercase words joined by dashes, e.g. lift-log."}, **_LOOK},
            ["app_id", "name", "tagline", "summary", "symbol", "color", "ink", "routes"],
        ),
    },
    {
        "name": "apps_set_info",
        "description": "Change an app's name, look, descriptions or routes. Shown on the phone after the next refresh.",
        "inputSchema": _schema({"app_id": {"type": "string"}, **_LOOK}, ["app_id"]),
    },
    {
        "name": "apps_build",
        "description": "Build the app's next version and publish it to the phone. Takes a minute or two. "
                       "On failure returns the compiler errors; fix them and build again.",
        "inputSchema": _schema(
            {
                "app_id": {"type": "string"},
                "change": {"type": "string", "description": "What this version adds, in a few words, e.g. 'Rest timer between sets'."},
                "reason": {"type": "string", "description": "Optional: why, in the user's terms, e.g. 'You asked after leg day'."},
            },
            ["app_id", "change"],
        ),
    },
    {
        "name": "apps_refresh",
        "description": "Ask the app, if it is open on the phone, to reload and outline the given ids. "
                       "Data tools that change data already do this.",
        "inputSchema": _schema(
            {"app_id": {"type": "string"}, "route": {"type": "string"}, "highlight": _STRING_LIST},
            ["app_id"],
        ),
    },
]


class Server:
    def __init__(self, write: Callable[[str], None] = None) -> None:
        self._write = write or self._stdout
        self._lock = threading.Lock()
        self._listed_signature: str | None = None
        self._initialized = False

    # ── Transport ───────────────────────────────────────────────────────────

    @staticmethod
    def _stdout(line: str) -> None:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()

    def send(self, message: dict[str, Any]) -> None:
        with self._lock:
            self._write(json.dumps(message))

    def run(self) -> None:
        threading.Thread(target=self._watch, daemon=True).start()
        for line in sys.stdin:
            line = line.strip()
            if line:
                self.handle_line(line)

    def handle_line(self, line: str) -> None:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            self.send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            return
        method = message.get("method")
        msg_id = message.get("id")
        if msg_id is None:  # a notification
            if method == "notifications/initialized":
                self._initialized = True
            return
        try:
            result = self.dispatch(method, message.get("params") or {})
            self.send({"jsonrpc": "2.0", "id": msg_id, "result": result})
        except _MethodNotFound:
            self.send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"Unknown method {method}"}})
        if method == "tools/call":
            self._notify_if_changed()

    # ── Methods ─────────────────────────────────────────────────────────────

    def dispatch(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "initialize":
            return {
                "protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": "hermex-apps", "version": "1"},
                "instructions": INSTRUCTIONS,
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            tools, signature = self.tools()
            self._listed_signature = signature
            return {"tools": tools}
        if method == "tools/call":
            return self.call(params.get("name", ""), params.get("arguments") or {})
        raise _MethodNotFound()

    def tools(self) -> tuple[list[dict[str, Any]], str]:
        tools = list(FIXED_TOOLS)
        for app_id in store.app_ids():
            try:
                api = appapi.load(app_id)
                name = store.read_record(app_id)["name"]
            except AppsError:
                continue
            prefix = store.tool_prefix(app_id)
            for tool in api.tools.values():
                note = " Changes the app's data; the open app refreshes." if tool.changes else ""
                tools.append({
                    "name": f"{prefix}_{tool.name}",
                    "description": f"{name}: {tool.description or tool.name}{note}",
                    "inputSchema": tool.schema,
                })
        signature = hashlib.sha256(json.dumps(tools, sort_keys=True, default=str).encode()).hexdigest()
        return tools, signature

    def call(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        try:
            result = self._call(name, args)
            text = result if isinstance(result, str) else json.dumps(result, indent=2, default=str)
            return {"content": [{"type": "text", "text": text}], "isError": False}
        except AppsError as error:
            return {"content": [{"type": "text", "text": str(error)}], "isError": True}
        except Exception as error:  # never let one tool take the server down
            return {"content": [{"type": "text", "text": f"{name} failed: {error}"}], "isError": True}

    def _call(self, name: str, args: dict[str, Any]) -> Any:
        if name == "apps_list":
            return self._list()
        if name == "apps_create":
            if args.get("app_id") == "apps":
                raise AppsError("Pick another id; apps is reserved.")
            return factory.create(
                args.get("app_id", ""), args.get("name", ""), args.get("tagline", ""), args.get("summary", ""),
                args.get("symbol", ""), args.get("color", ""), args.get("ink", ""), list(args.get("routes") or []),
                origin=args.get("origin"),
            ) | {"next": "Edit server.py and the Swift sources under project/App, then call apps_build."}
        if name == "apps_set_info":
            app_id = args.pop("app_id", "")
            return factory.set_info(app_id, **args)
        if name == "apps_build":
            steps: list[str] = []
            record = factory.build(
                args.get("app_id", ""), args.get("change", ""), args.get("reason"),
                progress=lambda step, state, detail: steps.append(f"{step}: {state}" + (f" ({detail})" if detail else "")),
            )
            return {"steps": steps, "version": record["version"], "ipa": record["ipa"],
                    "next": "The phone shows the update in Apps. New apps need the user to tap Install."}
        if name == "apps_refresh":
            app_id = store.check_id(args.get("app_id", ""))
            store.read_record(app_id)
            store.emit("refresh", app_id, route=args.get("route"), highlight=list(args.get("highlight") or [])[:20])
            return {"ok": True}
        return self._app_tool(name, args)

    def _list(self) -> list[dict[str, Any]]:
        apps = []
        for app_id in store.app_ids():
            record = store.read_record(app_id)
            entry = {
                "id": app_id,
                "name": record["name"],
                "version": record.get("version", 0),
                "routes": record.get("routes", []),
                "folder": str(store.app_dir(app_id)),
                "built": store.ipa_info(app_id) is not None,
            }
            try:
                api = appapi.load(app_id)
                entry["tools"] = {f"{store.tool_prefix(app_id)}_{t.name}": t.description for t in api.tools.values()}
            except AppsError as error:
                entry["api_error"] = str(error)
            apps.append(entry)
        return apps

    def _app_tool(self, name: str, args: dict[str, Any]) -> Any:
        for app_id in store.app_ids():
            prefix = store.tool_prefix(app_id) + "_"
            if name.startswith(prefix):
                tool = name[len(prefix):]
                if tool in appapi.load(app_id).tools:
                    return appapi.call(app_id, tool, args, source="agent")
        raise AppsError(f"Unknown tool {name}.", status=404)

    # ── list_changed ────────────────────────────────────────────────────────

    def _notify_if_changed(self) -> None:
        if self._listed_signature is None:
            return
        _, signature = self.tools()
        if signature != self._listed_signature:
            self._listed_signature = signature
            self.send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})

    def _watch(self) -> None:
        # Apps also change outside tool calls (Hermes edits server.py with its
        # file tools), so check every few seconds.
        while True:
            time.sleep(3)
            try:
                self._notify_if_changed()
            except Exception:
                pass


class _MethodNotFound(Exception):
    pass


def main() -> None:
    Server().run()
