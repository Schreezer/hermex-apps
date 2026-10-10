# Hermex Apps on the Mac

The Mac half of Hermex Apps (BUILD_SPEC §3): the app factory Hermes uses to
build SwiftUI apps, each app's data API, and the service the phone talks to.
Plain Python 3.11+, no dependencies.

```
Mac/
  bin/hermex-apps              CLI: serve | mcp | list | build | call
  hermex_apps/                 store (records, IPAs, events), appapi (per-app tools),
                               factory (scaffold, xcodebuild, package), mcp, service
  template/                    what every new app starts from: server.py + SwiftUI project
  skills/hermex-app-factory/   the Hermes skill that drives a build
  webui-extension/             the hermes-webui manifest that exposes the service
  tests/                       python3 -m unittest discover -s Mac/tests
```

## How it fits together

- **Hermes** talks to the `hermex-apps` stdio MCP server. Fixed tools run the
  factory (`apps_create`, `apps_build`, `apps_set_info`, `apps_list`,
  `apps_refresh`). Each app adds its own data tools under its prefix
  (`hyrox_noida_log_session`), and the server sends `tools/list_changed` when
  they change, so a new app needs no restart.
- **Each app's data** lives on the Mac in `apps/<id>/data.sqlite`, behind the
  tools in `apps/<id>/server.py`. The app and Hermes call the same tools. When
  Hermes calls one marked `changes=True`, the open app refreshes and outlines the
  ids the tool returns under `highlight`.
- **The phone** reaches `hermex-apps serve` (loopback, port 8790) through
  hermes-webui's extension sidecar proxy, at
  `<webui>/api/extensions/hermex-apps/sidecar/…`, with the server URL and
  password Hermex already has. The service serves the registry, the IPAs (in
  384 KiB parts, because the proxy caps responses at 512 KiB), the apps' API
  calls, build cancellation and an events feed (build steps, refreshes).

## Setup (once)

1. Point hermes-webui at the extension manifest (in its `.env`) and restart it:

   ```
   HERMES_WEBUI_EXTENSION_DIR=/path/to/hermex-apps/Mac/webui-extension
   HERMES_WEBUI_EXTENSION_MANIFEST=extensions.json
   ```

   If you already use an extension directory, add the `hermex-apps` entry from
   `webui-extension/extensions.json` to your manifest instead.
2. Run the service, with the same `HERMEX_APPS_HOME` as the MCP server below:

   ```
   HERMEX_APPS_HOME=~/.hermes/hermex-apps Mac/bin/hermex-apps serve
   ```

3. Add the MCP server and the skill to the Hermes profile the webui uses
   (`config.yaml`):

   ```yaml
   mcp_servers:
     hermex-apps:
       command: python3
       args: [/path/to/hermex-apps/Mac/bin/hermex-apps, mcp]
       env:
         HERMEX_APPS_HOME: /Users/you/.hermes/hermex-apps
         HERMEX_APPS_PLATFORM: device        # or simulator, to match the phone
       timeout: 900
   skills:
     external_dirs:
       - /path/to/hermex-apps/Mac/skills
   ```

4. In Hermex, open **Apps** and tap **Allow**: that is the webui's one-time
   consent to proxy the service (the same switch as Settings → Extensions).

Settings: `HERMEX_APPS_HOME` (apps and their data), `HERMEX_APPS_PLATFORM`
(`device` builds unsigned arm64 iPhone apps that LiveContainer signs on install;
`simulator` builds for the iOS Simulator), `HERMEX_APPS_DERIVED_DATA` (Xcode
build cache), `HERMEX_APPKIT_PATH` (defaults to this repo's package).

## By hand

```
Mac/bin/hermex-apps list
Mac/bin/hermex-apps build <id> --change "What changed"
Mac/bin/hermex-apps call <id> <tool> '{"arg": "value"}'
```
