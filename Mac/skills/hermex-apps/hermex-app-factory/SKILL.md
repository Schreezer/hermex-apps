---
name: hermex-app-factory
description: "Build or change a Hermex app: SwiftUI + data API"
version: 1.0.0
author: Hermex Apps
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [iOS, SwiftUI, Hermex, App Factory, MCP]
    related_skills: [hermex-apps]
prerequisites:
  commands: [xcodebuild, xcodegen]
---

# Hermex App Factory

The user runs Hermex on their iPhone. It installs apps you build here into its
built-in container: no App Store, no reinstall. Each app has:

- a **SwiftUI project** (`project/`, xcodegen) that links HermexAppKit,
- a **data API** (`server.py`) on this Mac that owns the app's data in SQLite.
  The app calls it through Hermex; you call the same tools over MCP as
  `<app_prefix>_<tool>` (for `lift-log`, `lift_log_log_sets`).

Use the `hermex-apps` MCP tools: `apps_list`, `apps_create`, `apps_set_info`,
`apps_build`, `apps_refresh`.

## When to use

- "Build me an app for …", "make a tracker for …", or a yes to your offer of
  one → new app.
- "Add … to Lift Log", "change …" (including from the chat inside an app,
  whose first message names the app) → change an existing app.
- Deciding whether an app would help, offering one, and reading or changing an
  app's data ("log my breakfast") are the **hermex-apps** skill: load it too.

## Build a new app

0. **Look for a head start (optional, quick).** Search GitHub for an open-source
   SwiftUI app close to what the user wants (`gh search repos` in the terminal,
   or web search). Only borrow from MIT, Apache-2.0 or BSD projects; read the
   license first. Borrow ideas, the data model or small pieces of code, adapted
   to this template (the app keeps its data in `server.py`, not on the phone).
   Say what you found in a sentence, and pass `origin` to `apps_create`, e.g.
   "From a GitHub repo · owner/name (MIT)". If nothing fits in a couple of
   minutes, build from scratch.
1. **Plan briefly.** Screens, data model, the tools the app and you need, and
   routes (`today`, `history`, `item/{id}`). Keep v1 small: one or two screens
   that work well beat five that half work. Don't ask more than one question;
   pick sensible defaults.
2. **`apps_create`** with an id (`lift-log`), name, tagline, summary, an SF
   Symbol, a tile `color` and a contrasting `ink`, and the routes. It copies the
   template (a working list app) and returns the folder.
3. **Write `server.py`.** Replace the template's tools. Rules:
   - `@api.setup` creates tables with `create table if not exists` (it runs
     before every call) and may seed rows only when the table is empty.
   - Every tool's first parameter is `db` (sqlite3, rows act like dicts). Other
     parameters need type hints (`str`, `int`, `float`, `bool`, `list`, `dict`,
     `Literal[...]`, `X | None`); document them under `Args:` in the docstring.
     The docstring's first line is what you will see as the tool description.
   - Return JSON: dicts, lists, strings, numbers, booleans. Convert SQLite 0/1
     with `bool()`. Raise `ValueError("message")` for bad input.
   - Mark tools that change data `@api.tool(changes=True, route="today")` and
     return the changed ids as `"highlight": [...]`.
   - Write tools for what the user will ask *you* to do ("log sets", "add a
     meal", "skip today", "undo"), not just what the screens need.
   - Add a bulk tool for what you made in the conversation (`import_plan`,
     `add_items`). Seed only examples or defaults in `@api.setup`; the user's
     own plan goes in through that tool after the build (step 7).
   - Check it: call the new tools once they appear (a few seconds after you
     save), or `python3 <repo>/Mac/bin/hermex-apps call <id> <tool> '{...}'`.
4. **Write the Swift sources** in `project/App/` (edit `App.swift`, `Store.swift`,
   `Views.swift`; add files freely, they are picked up). Rules:
   - Load data with `try await HermexAppKit.fetch("tool", args)` and change it
     with `try await HermexAppKit.perform("tool", args)`. Arguments encode with
     snake_case keys and results decode from snake_case, so Swift types use
     camelCase. `fetch` falls back to the last answer when offline.
   - Register routes and handlers once at launch: `registerRoutes`, `onOpen`
     (navigate, return whether handled) and `onRefresh` (reload from the API).
   - On every screen, call `HermexAppKit.reportContext(route:breadcrumb:entities:)`
     with what is visible. That is how the in-app chat knows what the user sees.
   - Put `.hermexHighlight(id:)` on rows whose ids your tools return.
   - iOS 17 APIs, SwiftUI only, no third-party packages, no network calls
     except through HermexAppKit, no `UIApplication.open` for routes. Give the
     app its own look: a palette, type and spacing that suit it. Use
     accessibility labels on icon-only buttons.
5. **`apps_build`** with `change` ("First version") and optionally `reason`. It
   checks the API, compiles, packages and publishes. On compiler errors, fix
   them and build again; don't stop at the first failure.
6. **Hand off the long part (optional).** Call `apps_create` yourself, so the
   build card appears in the user's chat at once, then you may give steps 3 to 5
   to a subagent with `delegate_task`: pass the app id, the folder, your plan
   (screens, tables, tools, routes, look) and "follow the hermex-app-factory
   skill; finish with apps_build and fix compiler errors until it builds". The
   card follows the build either way. Do step 7 yourself when it reports back.
7. **Load the conversation in.** Once the build is ready, call the bulk tool
   with what you made together (the plan, the list), then read it back to check
   it all landed. Call it as the app's own tool, never through a script, the
   terminal or `hermex-apps call`: those wait for the user's approval.
8. **Tell the user** in a sentence or two what the app does and the first thing
   to try. The build card in their chat has an **Open** button that installs
   and opens it; it is also in **Apps** (new apps need their OK to install;
   updates install by themselves).

## Change an app

1. `apps_list` to find the folder; read the current sources before editing.
2. Make the change in `server.py` and/or `project/App/`. Keep existing data:
   add columns with `alter table … add column` guarded by a check of
   `pragma table_info`, never drop tables with user data.
3. If routes, name or look change, call `apps_set_info`.
4. `apps_build` with a short `change` ("Rest timer between sets") and the
   user's reason. Then tell the user what changed. If the app is open, it shows
   **Restart to update**.

## Don'ts

- Don't touch HermexAppKit or other apps' folders.
- Don't run the app or simulators yourself; the phone installs it.
- Don't put secrets or the user's personal data in source files; data belongs
  in the app's database through its tools.
