"""The phone's side of the Mac: a loopback HTTP service that hermes-webui
proxies as the `hermex-apps` extension sidecar, so Hermex reaches it with the
server URL and password it already has:

    <webui>/api/extensions/hermex-apps/sidecar/<path>  ->  http://127.0.0.1:8790/<path>

    GET  /health
    GET  /apps                       registry: every app with a build
    GET  /apps/<id>/ipa?part=N       the IPA in parts of IPA_PART_BYTES
    POST /apps/<id>/call/<tool>      the app's own API calls (JSON args)
    POST /apps/<id>/cancel           stop the app's running build
    GET  /events?after=N             build steps and refresh requests
"""

from __future__ import annotations

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import appapi, factory, store
from .store import AppsError

MAX_BODY = 256 * 1024
CALL_RE = re.compile(r"^/apps/([a-z0-9-]+)/call/([a-z][a-z0-9_]*)$")
CANCEL_RE = re.compile(r"^/apps/([a-z0-9-]+)/cancel$")
IPA_RE = re.compile(r"^/apps/([a-z0-9-]+)/ipa$")


class Handler(BaseHTTPRequestHandler):
    server_version = "hermex-apps"

    def do_GET(self) -> None:
        url = urlparse(self.path)
        query = parse_qs(url.query)
        try:
            if url.path == "/health":
                return self._json({"ok": True, "service": "hermex-apps", "platform": factory.platform()})
            if url.path == "/apps":
                return self._json({"apps": store.registry(), "platform": factory.platform()})
            if url.path == "/events":
                after = int(query.get("after", ["0"])[0] or 0)
                events, last = store.events_after(after)
                return self._json({"events": events, "last": last})
            if match := IPA_RE.match(url.path):
                part = int(query.get("part", ["0"])[0] or 0)
                body = store.ipa_part(match.group(1), part)
                return self._send(200, body, "application/octet-stream")
            raise AppsError("Not found.", status=404)
        except ValueError:
            self._error(AppsError("Bad number in query."))
        except AppsError as error:
            self._error(error)

    def do_POST(self) -> None:
        url = urlparse(self.path)
        try:
            if cancel := CANCEL_RE.match(url.path):
                factory.request_cancel(cancel.group(1))
                return self._json({"ok": True})
            match = CALL_RE.match(url.path)
            if not match:
                raise AppsError("Not found.", status=404)
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                raise AppsError("Request too large.", status=413)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                args = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                raise AppsError("Arguments must be a JSON object.")
            if not isinstance(args, dict):
                raise AppsError("Arguments must be a JSON object.")
            result = appapi.call(match.group(1), match.group(2), args, source="app")
            self._json({"result": result})
        except AppsError as error:
            self._error(error)

    def _json(self, payload: object, status: int = 200) -> None:
        self._send(status, json.dumps(payload).encode(), "application/json")

    def _error(self, error: AppsError) -> None:
        self._json({"error": str(error)}, status=error.status)

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        if os.environ.get("HERMEX_APPS_LOG_REQUESTS"):
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), format % args))


def serve(port: int) -> None:
    # Loopback only: the webui is the front door and does the authentication.
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"hermex-apps service on http://127.0.0.1:{port} (apps in {store.home()})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
