"""Where the apps Hermes builds live on the Mac, and what the phone reads.

Layout under HERMEX_APPS_HOME (default ~/.hermes/hermex-apps):

    events.sqlite            build steps and refresh requests the phone polls
    apps/<id>/app.json       the app's record: name, look, routes, versions
    apps/<id>/server.py      the app's data API (tools for Hermes and the app)
    apps/<id>/data.sqlite    the app's data; the Mac is the source of truth
    apps/<id>/project/       the SwiftUI project (xcodegen)
    apps/<id>/dist/app.ipa   the latest build, with dist/ipa.json beside it
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

APP_ID_RE = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
# The webui proxies at most 512 KiB per response, so IPAs go out in parts.
IPA_PART_BYTES = 384 * 1024


class AppsError(Exception):
    """A request the caller can fix; the message is shown as is."""

    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def home() -> Path:
    raw = os.environ.get("HERMEX_APPS_HOME", "").strip()
    path = Path(raw).expanduser() if raw else Path.home() / ".hermes" / "hermex-apps"
    (path / "apps").mkdir(parents=True, exist_ok=True)
    return path


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def check_id(app_id: str) -> str:
    if not isinstance(app_id, str) or not APP_ID_RE.match(app_id) or len(app_id) > 40:
        raise AppsError(f"App id must be lowercase words joined by dashes, like lift-log (got {app_id!r}).")
    return app_id


def app_dir(app_id: str) -> Path:
    return home() / "apps" / check_id(app_id)


def tool_prefix(app_id: str) -> str:
    """lift-log -> lift_log, the prefix of the app's MCP tools."""
    return check_id(app_id).replace("-", "_")


def bundle_id(app_id: str) -> str:
    return "dev.hermex." + check_id(app_id).replace("-", "")


def target_name(name: str, app_id: str) -> str:
    """A Swift-safe target name: "Lift Log" -> LiftLog."""
    words = re.findall(r"[A-Za-z0-9]+", name) or app_id.split("-")
    candidate = "".join(w[:1].upper() + w[1:] for w in words)
    if not candidate or not candidate[0].isalpha():
        candidate = "App" + candidate
    return candidate


# ── App records ──────────────────────────────────────────────────────────────

def read_record(app_id: str) -> dict[str, Any]:
    path = app_dir(app_id) / "app.json"
    if not path.is_file():
        raise AppsError(f"No app with id {app_id}.", status=404)
    return json.loads(path.read_text())


def write_record(record: dict[str, Any]) -> None:
    path = app_dir(record["id"]) / "app.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n")
    tmp.replace(path)


def app_ids() -> list[str]:
    root = home() / "apps"
    return sorted(p.name for p in root.iterdir() if (p / "app.json").is_file() and APP_ID_RE.match(p.name))


def ipa_info(app_id: str) -> dict[str, Any] | None:
    meta = app_dir(app_id) / "dist" / "ipa.json"
    ipa = app_dir(app_id) / "dist" / "app.ipa"
    if not meta.is_file() or not ipa.is_file():
        return None
    info = json.loads(meta.read_text())
    info["parts"] = max(1, -(-info["size"] // IPA_PART_BYTES))
    return info


def ipa_part(app_id: str, part: int) -> bytes:
    info = ipa_info(app_id)
    if info is None:
        raise AppsError(f"{app_id} has not been built yet.", status=404)
    if part < 0 or part >= info["parts"]:
        raise AppsError("No such part.", status=404)
    with open(app_dir(app_id) / "dist" / "app.ipa", "rb") as handle:
        handle.seek(part * IPA_PART_BYTES)
        return handle.read(IPA_PART_BYTES)


def public_record(app_id: str) -> dict[str, Any]:
    """What the phone's Apps tab reads for one app."""
    from . import appapi

    record = read_record(app_id)
    try:
        tools = appapi.load(app_id).tools
        api = {"tools": len(tools), "changes": sum(1 for t in tools.values() if t.changes)}
    except AppsError:
        api = None
    return {
        "id": record["id"],
        "name": record["name"],
        "tagline": record.get("tagline", ""),
        "summary": record.get("summary", ""),
        "bundle_id": record["bundle_id"],
        "symbol": record.get("symbol", "app.fill"),
        "color": record.get("color", "#3A3F46"),
        "ink": record.get("ink", "#F3F2ED"),
        "version": record.get("version", 0),
        "built_at": record.get("built_at"),
        "updated_at": record.get("updated_at"),
        "origin": record.get("origin"),
        "routes": record.get("routes", []),
        "api": api,
        "versions": list(reversed(record.get("versions", []))),
        "ipa": ipa_info(app_id),
    }


def registry() -> list[dict[str, Any]]:
    """Every app that has a build the phone can install, newest first."""
    apps = [public_record(i) for i in app_ids()]
    apps = [a for a in apps if a["ipa"]]
    return sorted(apps, key=lambda a: a.get("updated_at") or "", reverse=True)


# ── Events ───────────────────────────────────────────────────────────────────
#
# One table both processes append to: the MCP server (Hermes' side) and the
# HTTP service (the phone's side). The phone polls it through the webui.

def _events_db() -> sqlite3.Connection:
    db = sqlite3.connect(home() / "events.sqlite", timeout=5)
    db.execute(
        "create table if not exists events ("
        " seq integer primary key autoincrement,"
        " at real not null,"
        " kind text not null,"
        " app text,"
        " body text not null)"
    )
    return db


def emit(event: str, app_id: str | None, **body: Any) -> int:
    with closing(_events_db()) as db, db:
        cursor = db.execute(
            "insert into events (at, kind, app, body) values (?, ?, ?, ?)",
            (time.time(), event, app_id, json.dumps(body)),
        )
        # Keep a day of history; the phone only needs what it missed while asleep.
        db.execute("delete from events where at < ?", (time.time() - 86400,))
        return int(cursor.lastrowid)


def events_after(seq: int, limit: int = 100) -> tuple[list[dict[str, Any]], int]:
    with closing(_events_db()) as db:
        rows = db.execute(
            "select seq, at, kind, app, body from events where seq > ? order by seq limit ?",
            (seq, limit),
        ).fetchall()
        last = db.execute("select coalesce(max(seq), 0) from events").fetchone()[0]
    events = [
        {"seq": s, "at": datetime.fromtimestamp(at, timezone.utc).isoformat().replace("+00:00", "Z"),
         "kind": k, "app": a, **json.loads(b)}
        for s, at, k, a, b in rows
    ]
    return events, int(last)
