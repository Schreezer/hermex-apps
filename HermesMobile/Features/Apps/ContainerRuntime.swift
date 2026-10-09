import LiveContainerSwiftUI

/// Hermex's launch-time entry to the embedded LiveContainer runtime. Kept in
/// its own file because LiveContainerSwiftUI exports a public `App` class (from
/// its intent definition) that would shadow SwiftUI's `App` where both are
/// imported.
enum ContainerRuntime {
    @MainActor static func bootstrap() {
        LCHostRuntime.bootstrap()
    }
}
