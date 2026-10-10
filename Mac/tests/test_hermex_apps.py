"""Run with: python3 -m unittest discover -s Mac/tests"""

import json
import os
import sys
import tempfile
import textwrap
import threading
import time
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from hermex_apps import appapi, factory, mcp, service, store  # noqa: E402
from hermex_apps.store import AppsError  # noqa: E402

LOOK = dict(name="Chores", tagline="Who does what", summary="House chores", symbol="checklist",
            color="#4aa3f2", ink="#04121E", routes=["home", "item/{id}"])


class AppsTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.environ["HERMEX_APPS_HOME"] = self.tmp.name
        appapi._cache.clear()

    def tearDown(self):
        os.environ.pop("HERMEX_APPS_HOME", None)

    def create(self, app_id="chores"):
        return factory.create(app_id, **LOOK)

    def fake_build(self, app_id="chores", payload=b"x" * (store.IPA_PART_BYTES + 10)):
        dist = store.app_dir(app_id) / "dist"
        dist.mkdir(exist_ok=True)
        (dist / "app.ipa").write_bytes(payload)
        (dist / "ipa.json").write_text(json.dumps({"version": 1, "size": len(payload), "sha256": "abc", "platform": "simulator"}))


class FactoryTests(AppsTestCase):
    def test_create_fills_the_template(self):
        result = self.create()
        folder = Path(result["folder"])
        project = (folder / "project" / "project.yml").read_text()
        self.assertIn("name: Chores", project)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: dev.hermex.chores", project)
        self.assertIn(str(factory.appkit_path()), project)
        self.assertNotIn("__", (folder / "project" / "App" / "App.swift").read_text())
        record = store.read_record("chores")
        self.assertEqual((record["version"], record["color"], record["target"]), (0, "#4AA3F2", "Chores"))

    def test_create_rejects_bad_ids_and_duplicates(self):
        with self.assertRaises(AppsError):
            factory.create("Lift Log", **LOOK)
        self.create()
        with self.assertRaises(AppsError) as caught:
            self.create()
        self.assertEqual(caught.exception.status, 409)

    def test_target_names_are_swift_identifiers(self):
        self.assertEqual(store.target_name("Lift Log", "lift-log"), "LiftLog")
        self.assertEqual(store.target_name("2048!", "game"), "App2048")

    def test_registry_lists_only_built_apps_and_splits_the_ipa(self):
        self.create()
        self.create("notes")
        self.assertEqual(store.registry(), [])
        self.fake_build()
        apps = store.registry()
        self.assertEqual([a["id"] for a in apps], ["chores"])
        self.assertEqual(apps[0]["ipa"]["parts"], 2)
        self.assertEqual(apps[0]["api"], {"tools": 3, "changes": 2})
        whole = store.ipa_part("chores", 0) + store.ipa_part("chores", 1)
        self.assertEqual(len(whole), store.IPA_PART_BYTES + 10)
        with self.assertRaises(AppsError):
            store.ipa_part("chores", 2)


class CancelTests(AppsTestCase):
    def test_cancel_stops_a_running_build_command(self):
        self.create()
        flag = store.app_dir("chores") / ".cancel"
        threading.Timer(0.3, factory.request_cancel, args=("chores",)).start()
        started = time.monotonic()
        with self.assertRaises(AppsError) as caught:
            factory._run(["sleep", "5"], flag)
        self.assertEqual(caught.exception.status, 499)
        self.assertLess(time.monotonic() - started, 3)

    def test_cancel_needs_a_real_app(self):
        with self.assertRaises(AppsError):
            factory.request_cancel("ghost")


class AppAPITests(AppsTestCase):
    def test_template_tools_work_and_agent_changes_emit_refresh(self):
        self.create()
        added = appapi.call("chores", "add_item", {"title": "Bins"}, source="agent")
        items = appapi.call("chores", "items", {}, source="app")
        self.assertEqual(items[0]["title"], "Bins")
        self.assertIs(items[0]["done"], False)
        appapi.call("chores", "set_done", {"id": added["id"]}, source="app")
        events, _ = store.events_after(0)
        self.assertEqual([(e["kind"], e["route"], e["highlight"]) for e in events], [("refresh", "home", [added["id"]])])

    def test_schema_comes_from_hints_and_docstring(self):
        self.create()
        tool = appapi.load("chores").tools["set_done"]
        self.assertEqual(tool.description, "Mark an item done or not done.")
        self.assertEqual(tool.schema["required"], ["id"])
        self.assertEqual(tool.schema["properties"]["done"], {"type": "boolean", "description": "True to mark it done.", "default": True})
        self.assertTrue(tool.changes)

    def test_bad_arguments_are_rejected(self):
        self.create()
        for args in ({}, {"title": 3}, {"title": "x", "extra": 1}):
            with self.assertRaises(AppsError):
                appapi.call("chores", "add_item", args, source="app")
        with self.assertRaises(AppsError) as caught:
            appapi.call("chores", "set_done", {"id": "missing"}, source="app")
        self.assertIn("No item missing", str(caught.exception))

    def test_a_failing_tool_rolls_back_and_points_at_the_line(self):
        self.create()
        server = store.app_dir("chores") / "server.py"
        server.write_text(server.read_text() + textwrap.dedent('''

            @api.tool(changes=True)
            def broken(db) -> dict:
                """Adds then fails."""
                db.execute("insert into items (id, title) values ('z', 'z')")
                return 1 / 0
        '''))
        with self.assertRaises(AppsError) as caught:
            appapi.call("chores", "broken", {}, source="agent")
        self.assertIn("server.py line", str(caught.exception))
        self.assertEqual(appapi.call("chores", "items", {}, source="app"), [])

    def test_a_server_that_does_not_load_says_why(self):
        self.create()
        (store.app_dir("chores") / "server.py").write_text("import nope\n")
        with self.assertRaises(AppsError) as caught:
            appapi.load("chores")
        self.assertIn("failed to load", str(caught.exception))


class MCPTests(AppsTestCase):
    def setUp(self):
        super().setUp()
        self.sent = []
        self.server = mcp.Server(write=lambda line: self.sent.append(json.loads(line)))

    def request(self, method, params=None, msg_id=1):
        self.server.handle_line(json.dumps({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params or {}}))
        return [m for m in self.sent if m.get("id") == msg_id][-1]

    def test_initialize_advertises_list_changed(self):
        result = self.request("initialize", {"protocolVersion": "2025-03-26"})["result"]
        self.assertEqual(result["protocolVersion"], "2025-03-26")
        self.assertTrue(result["capabilities"]["tools"]["listChanged"])

    def test_new_app_tools_appear_with_a_list_changed_notice(self):
        names = [t["name"] for t in self.request("tools/list")["result"]["tools"]]
        self.assertNotIn("chores_items", names)
        reply = self.request("tools/call", {"name": "apps_create", "arguments": {"app_id": "chores", **LOOK}}, msg_id=2)
        self.assertFalse(reply["result"]["isError"])
        self.assertEqual(self.sent[-1], {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        names = [t["name"] for t in self.request("tools/list", msg_id=3)["result"]["tools"]]
        self.assertIn("chores_add_item", names)

    def test_app_tools_run_and_errors_come_back_as_tool_errors(self):
        self.create()
        reply = self.request("tools/call", {"name": "chores_add_item", "arguments": {"title": "Bins"}})
        self.assertFalse(reply["result"]["isError"])
        reply = self.request("tools/call", {"name": "chores_add_item", "arguments": {}}, msg_id=2)
        self.assertTrue(reply["result"]["isError"])
        reply = self.request("tools/call", {"name": "nope_tool", "arguments": {}}, msg_id=3)
        self.assertIn("Unknown tool", reply["result"]["content"][0]["text"])

    def test_refresh_needs_a_real_app(self):
        reply = self.request("tools/call", {"name": "apps_refresh", "arguments": {"app_id": "ghost"}})
        self.assertTrue(reply["result"]["isError"])
        self.create()
        self.request("tools/call", {"name": "apps_refresh", "arguments": {"app_id": "chores", "route": "home"}}, msg_id=2)
        events, last = store.events_after(0)
        self.assertEqual((events[-1]["kind"], events[-1]["route"], last), ("refresh", "home", 1))

    def test_open_needs_a_built_app_and_a_real_route(self):
        self.create()
        reply = self.request("tools/call", {"name": "apps_open", "arguments": {"app_id": "chores"}})
        self.assertIn("isn't built yet", reply["result"]["content"][0]["text"])
        self.fake_build()
        reply = self.request("tools/call", {"name": "apps_open", "arguments": {"app_id": "chores", "route": "settings"}}, msg_id=2)
        self.assertIn("no route 'settings'", reply["result"]["content"][0]["text"])
        reply = self.request("tools/call", {"name": "apps_open", "arguments": {
            "app_id": "chores", "route": "/item/42/", "highlight": ["42"], "note": "Added bins",
            "preview": [{"label": "Bins", "value": "Tonight"}, {"value": "no label"}],
        }}, msg_id=3)
        self.assertFalse(reply["result"]["isError"])
        event = store.events_after(0)[0][-1]
        self.assertEqual(
            (event["kind"], event["route"], event["highlight"], event["note"], event["preview"]),
            ("open", "item/42", ["42"], "Added bins", [{"label": "Bins", "value": "Tonight"}]),
        )
        self.request("tools/call", {"name": "apps_open", "arguments": {"app_id": "chores"}}, msg_id=4)
        self.assertEqual(store.events_after(0)[0][-1]["route"], "home")

    def test_routes_match_their_templates(self):
        routes = ["home", "item/{id}"]
        self.assertTrue(store.route_matches(routes, "item/a-1"))
        self.assertFalse(store.route_matches(routes, "item/"))
        self.assertFalse(store.route_matches(routes, "item/1/edit"))
        self.assertFalse(store.route_matches(routes, "homes"))

    def test_unknown_methods_are_errors(self):
        self.assertEqual(self.request("resources/list")["error"]["code"], -32601)


class ServiceTests(AppsTestCase):
    def setUp(self):
        super().setUp()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def fetch(self, path, body=None):
        request = urllib.request.Request(self.base + path, data=body, method="POST" if body is not None else "GET")
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read()

    def test_registry_ipa_calls_and_events(self):
        self.create()
        self.fake_build(payload=b"ipa")
        status, body = self.fetch("/apps")
        self.assertEqual((status, json.loads(body)["apps"][0]["id"]), (200, "chores"))
        self.assertEqual(self.fetch("/apps/chores/ipa?part=0"), (200, b"ipa"))
        status, body = self.fetch("/apps/chores/call/add_item", json.dumps({"title": "Bins"}).encode())
        self.assertEqual(status, 200)
        status, body = self.fetch("/apps/chores/call/items", b"")
        self.assertEqual(json.loads(body)["result"][0]["title"], "Bins")
        # The app's own changes don't bounce back to it as refresh events.
        self.assertEqual(json.loads(self.fetch("/events?after=0")[1])["events"], [])

    def test_errors_are_json_with_status(self):
        self.create()
        status, body = self.fetch("/apps/chores/call/add_item", b"[1]")
        self.assertEqual((status, json.loads(body)["error"]), (400, "Arguments must be a JSON object."))
        self.assertEqual(self.fetch("/apps/ghost/call/items", b"{}")[0], 404)
        self.assertEqual(self.fetch("/nope")[0], 404)


class EventTests(AppsTestCase):
    def test_events_page_by_sequence(self):
        for n in range(3):
            store.emit("refresh", "chores", route=None, highlight=[str(n)])
        events, last = store.events_after(1)
        self.assertEqual(([e["highlight"] for e in events], last), ([["1"], ["2"]], 3))
        self.assertLess(time.time() - time.mktime(time.strptime(events[0]["at"][:19], "%Y-%m-%dT%H:%M:%S")), 86400 * 2)


class SkillsTests(unittest.TestCase):
    """Hermes indexes skills by frontmatter and shows 60 characters of each description."""

    SKILLS = Path(__file__).resolve().parent.parent / "skills"

    def frontmatter(self, path):
        text = path.read_text()
        self.assertTrue(text.startswith("---\n"), path)
        fields = {}
        for line in text.split("---\n")[1].splitlines():
            key, sep, value = line.partition(":")
            if sep and not line.startswith(" "):
                fields[key] = value.strip().strip('"')
        return fields

    def test_skills_are_indexable(self):
        skills = sorted(self.SKILLS.rglob("SKILL.md"))
        self.assertEqual([p.parent.name for p in skills], ["hermex-app-factory", "hermex-apps"])
        for path in skills:
            fields = self.frontmatter(path)
            self.assertEqual(fields["name"], path.parent.name)
            self.assertLessEqual(len(fields["description"]), 60, path)
        category = self.frontmatter(self.SKILLS / "hermex-apps" / "DESCRIPTION.md")
        self.assertIn("hermex-apps", category["description"])


if __name__ == "__main__":
    unittest.main()
