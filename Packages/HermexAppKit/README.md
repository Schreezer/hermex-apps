# HermexAppKit

The small SDK compiled into every app Hermes builds. It connects the app to the
Hermex host that runs it, so Hermes can see where the user is and act on the
app. Outside Hermex every call is a no-op and the app runs on its own.

## Use

```swift
import HermexAppKit

// Once, at launch:
HermexAppKit.registerRoutes(["today", "history", "lift/{id}"])
HermexAppKit.onOpen { route in router.open(route) }      // return whether it was handled
HermexAppKit.onRefresh { route in store.reload() }       // after Hermes changed the data

// On every screen change:
HermexAppKit.reportContext(
    route: "today",
    breadcrumb: ["Today", "Legs"],                       // the chat's "Sees:" line
    entities: [HermexEntity(type: "session", id: "2026-10-07-legs", title: "Legs")]
)

// On rows Hermes may change:
LiftCard(lift).hermexHighlight(id: lift.id)
```

`GuestApps/LiftLog` is a complete example.

## How it connects

Guests run in LiveContainer's `LiveProcess` extension, a separate process from
Hermex. Hermex starts an anonymous `NSXPCListener` per running app and passes its
endpoint in the LiveProcess launch info (`HermexBridge.endpointKey`). HermexAppKit
reads it from `LiveProcessHandler.retrievedAppInfo`, connects, and says hello at
once, because XPC only connects on the first message and Hermex cannot reach the
app before that.

`Bridge.swift` is the whole contract: `HermexHostXPC` (app → Hermex: registration,
context) and `HermexGuestXPC` (Hermex → app: open, refresh, highlight). Payloads
are JSON `Data`. Hermex links this package too, so both sides always agree.
