"""Each app's data API: one set of tools that Hermes calls over MCP and the
app calls over HTTP (through Hermex and the webui).

An app's server.py looks like this:

    from hermex_apps import API

    api = API()

    @api.setup
    def setup(db):
        db.execute("create table if not exists items (id text primary key, title text, done integer)")

    @api.tool
    def items(db) -> list:
        \"\"\"Every item, oldest first.\"\"\"
        return db.execute("select * from items order by rowid").fetchall()

    @api.tool(changes=True, route="today")
    def add_item(db, title: str) -> dict:
        \"\"\"Add an item.

        Args:
            title: What the item says.
        \"\"\"
        ...
        return {"id": new_id, "highlight": [new_id]}

Tools take the app's SQLite connection first, then JSON arguments described by
their type hints. A tool marked `changes=True` changes data: when Hermes calls
it, the open app refreshes (on `route`, if given) and outlines the ids listed
under "highlight" in the result.
"""

from __future__ import annotations

import importlib.util
import inspect
import re
import sqlite3
import sys
import traceback
import types
import typing
from dataclasses import dataclass
from typing import Any, Callable

from . import store
from .store import AppsError


@dataclass
class Tool:
    name: str
    func: Callable[..., Any]
    description: str
    schema: dict[str, Any]
    changes: bool
    route: str | None


class API:
    def __init__(self) -> None:
        self.tools: dict[str, Tool] = {}
        self._setup: Callable[[sqlite3.Connection], None] | None = None

    def setup(self, func: Callable[[sqlite3.Connection], None]):
        """Creates tables and seed rows. Runs before every call, so keep it idempotent."""
        self._setup = func
        return func

    def tool(self, func: Callable[..., Any] | None = None, *, changes: bool = False, route: str | None = None):
        def register(f: Callable[..., Any]):
            if not re.match(r"^[a-z][a-z0-9_]*$", f.__name__):
                raise AppsError(f"Tool names must be snake_case (got {f.__name__}).")
            description, schema = _describe(f)
            self.tools[f.__name__] = Tool(f.__name__, f, description, schema, changes, route)
            return f

        return register(func) if func is not None else register


# ── Loading ──────────────────────────────────────────────────────────────────

_cache: dict[str, tuple[float, API]] = {}


def load(app_id: str) -> API:
    """The app's API, reloaded whenever server.py changes."""
    path = store.app_dir(app_id) / "server.py"
    if not path.is_file():
        raise AppsError(f"{app_id} has no server.py.", status=404)
    mtime = path.stat().st_mtime
    cached = _cache.get(app_id)
    if cached and cached[0] == mtime:
        return cached[1]
    name = f"hermex_app_{store.tool_prefix(app_id)}"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    try:
        sys.modules[name] = module
        spec.loader.exec_module(module)
    except Exception as error:
        sys.modules.pop(name, None)
        raise AppsError(f"{app_id}/server.py failed to load: {_short(error)}", status=500) from error
    api = getattr(module, "api", None)
    if not isinstance(api, API):
        raise AppsError(f"{app_id}/server.py must define api = API().", status=500)
    _cache[app_id] = (mtime, api)
    return api


def call(app_id: str, tool_name: str, args: dict[str, Any] | None, *, source: str) -> Any:
    """Runs one tool. `source` is "agent" (Hermes over MCP) or "app" (the app itself)."""
    api = load(app_id)
    tool = api.tools.get(tool_name)
    if tool is None:
        raise AppsError(f"{app_id} has no tool {tool_name}.", status=404)
    args = dict(args or {})
    _check_args(tool, args)

    db = sqlite3.connect(store.app_dir(app_id) / "data.sqlite", timeout=5)
    db.row_factory = sqlite3.Row
    db.execute("pragma foreign_keys = on")
    try:
        if api._setup:
            api._setup(db)
        result = tool.func(db, **args)
        db.commit()
    except AppsError:
        db.rollback()
        raise
    except (ValueError, KeyError, LookupError) as error:
        db.rollback()
        raise AppsError(_short(error)) from error
    except Exception as error:
        db.rollback()
        raise AppsError(f"{tool_name} failed: {_short(error)}\n{_trace(error)}", status=500) from error
    finally:
        db.close()

    result = _plain(result)
    if tool.changes and source == "agent":
        highlight = result.get("highlight", []) if isinstance(result, dict) else []
        store.emit("refresh", app_id, route=tool.route, highlight=[str(i) for i in highlight][:20])
    return result


# ── Schemas from signatures ──────────────────────────────────────────────────

_JSON_TYPES = {str: "string", int: "integer", float: "number", bool: "boolean", dict: "object", list: "array"}


def _json_type(hint: Any) -> dict[str, Any]:
    origin = typing.get_origin(hint)
    if origin in (typing.Union, types.UnionType):
        options = [a for a in typing.get_args(hint) if a is not type(None)]
        return _json_type(options[0]) if len(options) == 1 else {}
    if origin is typing.Literal:
        return {"enum": list(typing.get_args(hint))}
    if origin in (list, tuple, set):
        inner = typing.get_args(hint)
        return {"type": "array", **({"items": _json_type(inner[0])} if inner else {})}
    if origin is dict:
        return {"type": "object"}
    return {"type": _JSON_TYPES[hint]} if hint in _JSON_TYPES else {}


def _describe(func: Callable[..., Any]) -> tuple[str, dict[str, Any]]:
    doc = inspect.getdoc(func) or ""
    summary, _, rest = doc.partition("\nArgs:")
    arg_docs = dict(re.findall(r"^\s*(\w+)\s*(?:\([^)]*\))?:\s*(.+)$", rest, re.M))
    hints = typing.get_type_hints(func)
    params = list(inspect.signature(func).parameters.values())[1:]  # skip db
    properties: dict[str, Any] = {}
    required: list[str] = []
    for p in params:
        if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            raise AppsError(f"{func.__name__}: tools take named arguments only.")
        prop = _json_type(hints.get(p.name, Any))
        if p.name in arg_docs:
            prop["description"] = arg_docs[p.name].strip()
        if p.default is inspect.Parameter.empty:
            required.append(p.name)
        else:
            prop["default"] = p.default
        properties[p.name] = prop
    schema = {"type": "object", "properties": properties, "additionalProperties": False}
    if required:
        schema["required"] = required
    return summary.strip(), schema


def _check_args(tool: Tool, args: dict[str, Any]) -> None:
    props = tool.schema["properties"]
    unknown = sorted(set(args) - set(props))
    if unknown:
        raise AppsError(f"{tool.name} does not take {', '.join(unknown)}.")
    missing = [name for name in tool.schema.get("required", []) if name not in args]
    if missing:
        raise AppsError(f"{tool.name} needs {', '.join(missing)}.")
    checks = {"string": str, "integer": int, "number": (int, float), "boolean": bool, "array": list, "object": dict}
    for name, value in args.items():
        expected = props[name].get("type")
        if expected and value is not None:
            ok = isinstance(value, checks[expected])
            if expected in ("integer", "number") and isinstance(value, bool):
                ok = False
            if not ok:
                raise AppsError(f"{tool.name}: {name} should be {expected}.")


def _plain(value: Any) -> Any:
    if isinstance(value, sqlite3.Row):
        return {k: value[k] for k in value.keys()}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _plain(v) for k, v in value.items()}
    return value


def _short(error: BaseException) -> str:
    text = str(error) or type(error).__name__
    return text if len(text) < 400 else text[:400] + "…"


def _trace(error: BaseException) -> str:
    frames = traceback.extract_tb(error.__traceback__)
    app_frames = [f for f in frames if f.filename.endswith("server.py")] or frames[-1:]
    return "\n".join(f"  server.py line {f.lineno}, in {f.name}: {f.line}" for f in app_frames[-3:])
