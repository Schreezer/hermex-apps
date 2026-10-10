# Embedded LiveContainer runtime — agent notes

Hermex Apps runs apps that Hermes builds inside an embedded copy of
[LiveContainer](https://github.com/LiveContainer/LiveContainer). This note covers
how it is wired, what we changed in the vendored copy, and how to update it.

## Shape

- `Vendor/LiveContainer` is a **git subtree** of upstream LiveContainer
  (squashed). Its own submodules, `litehook` and `OpenSSL`, are git submodules
  of this repo: clone with `--recurse-submodules` or run
  `git submodule update --init`.
- `HermesMobile.xcodeproj` references `Vendor/LiveContainer/LiveContainer.xcodeproj`
  as a subproject. The `HermesMobile` target depends on `LiveContainerShared`,
  `LiveContainerSwiftUI`, `TweakLoader` and `LiveProcess`, links
  `LiveContainerSwiftUI.framework`, embeds both frameworks and `TweakLoader.dylib`
  in `Frameworks/`, and embeds `LiveProcess.appex` next to our other extensions.
- Hermex keeps its own `main()` and UI. Guest apps **always** run in the
  `LiveProcess` extension (LiveContainer's multitask mode), so guest code never
  loads into the Hermex process.
- Hermex talks to the runtime only through `LCHostRuntime`
  (`Vendor/LiveContainer/LiveContainerSwiftUI/HostRuntime/LCHostRuntime.swift`):
  `bootstrap()`, `installedApps()`, `installIPA(at:)`, `removeApp(_:)`,
  `makeAppViewController(for:onExit:onError:)`. The view controller launches the
  guest and renders its scene edge to edge; dismissing it terminates the guest.
- `HermesMobile/Features/Apps/ContainerRuntime.swift` is the only file that
  imports `LiveContainerSwiftUI` outside Debug-only code. That module exports a
  public `App` class (from its intent definition) that shadows `SwiftUI.App`, so
  keep the import out of files that use SwiftUI's `App`.

## Apps surfaces

- `HermexHomeTabs` puts the webui home in a Chats / Apps tab bar. Any pending
  chat route (deep link, share, intent, push, new chat) switches to Chats.
  Hermes-server (Bot Mode) homes keep their own bar for now.
- `AppsView` (library), `AppDetailView` (app page) and `RunningAppView` (a guest
  under a thin Hermex bar) follow screens 05–07 of the design, with tokens in
  `HermexAppsTheme`. Fonts fall back to the system face until Space Grotesk and
  IBM Plex are bundled.
- `AppLibrary` joins the Mac's registry (`AppsService`, see "Mac side" below)
  with the container's installs. New apps install when the user taps Install
  (or Open on a build card); updates install by themselves, except for the app
  that is open, which shows "Restart to update". Installed apps the registry
  doesn't know still show. Debug builds add the design's sample apps with the
  `--sample-apps` launch argument.
- `AppsView` shows a status card when the Mac can't be reached: Allow (the
  webui's sidecar proxy consent), not set up, or service not running.
- "Ask for a change" and "Ask Hermes for a new app" open a new chat with a draft
  through `NewChatRequest.initialDraft`.

## Bridge to running apps

- `Packages/HermexAppKit` is the guest SDK and the wire contract (see its
  README). Hermex links it too.
- `GuestBridge` is Hermex's end for one running app: an anonymous XPC listener
  whose endpoint `RunningAppView` passes to `LCHostRuntime.makeAppViewController`
  as launch info. It holds the app's registration and current context, and
  sends open, refresh and highlight.
- Debug builds add a bridge inspector to the running app's ⋯ menu.
- `GuestApps/LiftLog` is a sample guest (xcodegen); build it with
  `scripts/build-guest-ipa.sh GuestApps/LiftLog`.

## Hermes inside a running app

- `AgentButtonLayer` is the floating Hermes button (BUILD_SPEC §6.1): drag to
  one of four spots per side edge, throw past an edge to tuck it into a tab,
  tap the tab or swipe in from that edge to bring it back. Placement is saved
  per app; the first tuck shows a hint with Undo; the ⋯ menu has "Show agent
  button". VoiceOver gets move and tuck actions instead of dragging. Its edge
  strip is not `Color.clear`: over the guest's UIKit view a clear view loses
  hit-testing and the app gets the touch.
- `InAppChatSheet` (screen 09) drives Hermex's own `ChatViewModel` on a new
  webui session. `InAppChatModel` creates the session like New Chat does and
  applies the last new chat's composer picks (model, reasoning, profile).
- The first message carries the app context (BUILD_SPEC §3.4) as a block after
  the user's text, marked by `InAppChatContext.marker`, because the chat API
  has no hidden-context field. `MessageBubbleView` strips it for display, so
  neither the sheet nor the full chat shows it.
- When Hermes changes the app's data through one of its tools, the Mac emits a
  refresh event; `AppLibrary` polls the events feed while apps or build cards
  are on screen and `RunningAppView` refreshes the app and highlights the ids.
  "Full chat" hands the session to the Chats tab.
- `InAppChatSessions` records which app each session started in, for Home's
  "in Lift Log" labels.

## Mac side (build steps 6–7)

- `Mac/` holds the factory, each app's data API, the `hermex-apps` MCP server
  and the HTTP service; `Mac/README.md` has the setup. Hermes builds an app with
  the `hermex-app-factory` skill: `apps_create` copies `Mac/template`, Hermes (or
  a subagent it delegates to) writes `server.py` and the SwiftUI sources, and
  `apps_build` runs xcodegen and xcodebuild and publishes the IPA. The
  `hermex-apps` skill (same folder, `Mac/skills/hermex-apps/`) covers the rest:
  when to offer an app, logging to and reading the user's apps, and chats
  started inside an app. Hermes shows only the first 60 characters of a skill's
  description when choosing skills, so keep those short; the folder's
  `DESCRIPTION.md` carries the longer trigger.
- `AppsService` reaches the service through the webui's extension sidecar proxy
  (`APIClient.sendSidecar`). It sends `Sec-Fetch-Site: none` and no `Origin`:
  the proxy demands provenance, and an `Origin` would make the webui treat
  Hermex as a browser and require the page's CSRF token.
- Guests call their own API with `HermexAppKit.fetch` / `perform`; the call
  crosses the bridge (`HermexHostXPC.callAPI`) and `RunningAppView` forwards it
  to that app's tools only.
- `apps_open` (step 8): the MCP tool checks the route against the app's
  templates and emits an `open` event (route, highlight, note, preview). The
  phone's `AppLibrary` turns a fresh one (under 20 s old) into a `Handoff`:
  a 2 s countdown when the app is installed and VoiceOver is off, otherwise a
  tap. If that app is already open it just goes to the route. The card shows
  under the call in chat (`AppOpenCard`, matched to its request by time, then
  by tool-call id once settled), over another open app, or floating over the
  home when neither is on screen. `RunningAppView` opens the route once the
  guest connects, outlines the ids, and shows `OpenedByHermesBanner` for 8 s.
- `AppBuildCard` (screen 04) appears under the tool-call group holding Hermes'
  newest `apps_create` / `apps_build` for an app, also when tool cards are
  hidden or the turn is folded. Hermes may defer MCP tools behind a generic
  `tool_call(name, arguments)` whose settled arguments are cut-short text, so
  `AppBuildCall` reads both shapes. Steps come from the Mac's build events and
  the registry; Open installs a new app and lands in it through
  `AppLibrary.openRequest`. The hidden Apps tab stays alive, so `AppsView` only
  takes the request once it is on screen.

## Build settings that matter

- `Config/LiveContainerHost.xcconfig` is included at the end of
  `Vendor/LiveContainer/xcconfigs/Global.xcconfig` (LiveContainer's project-level
  base config). It pulls in `Config/Shared.xcconfig` and sets
  `LIVECONTAINER_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER)`, so LiveProcess is
  `$(APP_BUNDLE_IDENTIFIER).LiveProcess` as embedded extensions require.
- LiveContainer is arm64-only (ARM inline assembly). `Config/Shared.xcconfig`
  excludes `x86_64` for simulator builds, for Hermex and, through the include
  above, every LiveContainer target.
- `LiveContainerSwiftUI` is built with a bridging header that importers re-parse,
  so the `HermesMobile` and `HermesMobileTests` targets add
  `$(HERMEX_LIVECONTAINER_HEADER_SEARCH_PATHS)` (defined in `Config/Shared.xcconfig`)
  to `HEADER_SEARCH_PATHS`. (`-internal-import-bridging-header` would avoid that but
  needs many LiveContainer types marked `@_implementationOnly`.)
- Device signing still uses LiveContainer's `DEVELOPMENT_TEAM[config=…]` defaults
  from `Global.xcconfig`; device builds need that override next.

## Local patches to the vendored copy

Keep this list current; each one has to survive `git subtree pull`.

1. `LiveContainer/LCBootstrap.m`, `LCSharedUtils.h`: `LCHostInitialize()` sets
   the globals `LiveContainerMain` sets before its launcher UI.
2. `LiveContainerSwiftUI/HostRuntime/LCHostRuntime.swift`: the public facade.
3. `MultitaskSupport/DecoratedAppSceneViewController.m`: the
   `_UIFluidSliderInteraction` fix runs when LiveContainer's decorated window is
   created instead of in a load-time constructor, so Hermex's sliders keep
   stock behavior.
4. `xcconfigs/Global.xcconfig`: the optional include of
   `Config/LiveContainerHost.xcconfig`.
5. `MultitaskSupport/AppSceneViewController.{h,m}`: an initializer that takes
   `launchInfo`, merged into what LiveProcess receives (the bridge endpoint).
6. `MultitaskSupport/AppSceneViewController.{h,m}`: the optional
   `appSceneVC:didUpdateFromSettings:transitionContext:` delegate call is
   guarded with `respondsToSelector:` (upstream called it unconditionally and
   crashed delegates without it), and `applyHostSettings:transitionContext:`
   passes host scene changes (appearance, orientation, keyboard) to the guest.

## Updating LiveContainer

```zsh
git subtree pull --prefix Vendor/LiveContainer https://github.com/LiveContainer/LiveContainer main --squash
```

Then re-check the patches above, update the `litehook`/`OpenSSL` submodule
commits to whatever upstream pins, and run the harness below.

## Trying it on the simulator (Debug builds)

```zsh
scripts/build-container-test-ipa.sh            # writes .build/container-test/HermexContainerTest.ipa
(cd .build/container-test && python3 -m http.server 8000 --bind 127.0.0.1)
SIMCTL_CHILD_HERMEX_DEV_IPA_URL=http://127.0.0.1:8000/HermexContainerTest.ipa \
  xcrun simctl launch <udid> <bundle id> --container-apps
```

Tap **Install**, then the app. Settings › Developer › Container Apps opens the
same screen. Guests built with the iOS 27 SDK must adopt the scene life cycle or
UIKit refuses to launch them.

## Licensing and distribution

LiveContainer is AGPL-3.0; Hermex is MIT. A build that includes the vendored
runtime is distributed under the AGPL. It also downloads and runs code, so it
ships by sideloading (AltStore, SideStore, developer builds), not the App Store.
