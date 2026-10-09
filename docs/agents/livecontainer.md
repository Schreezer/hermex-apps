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
- `AppLibrary` joins `AppRegistry` with the container's installs. The registry
  is hard-coded until the Mac-side registry (build step 6): Debug builds list the
  design's sample apps plus the container test app; Release lists installs only.
- "Ask for a change" and "Ask Hermes for a new app" open a new chat with a draft
  through `NewChatRequest.initialDraft`.

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
