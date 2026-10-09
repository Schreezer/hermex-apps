import SwiftUI

public extension View {
    /// Outlines this view for a few seconds when Hermes changes the entity
    /// with this id (screens 09 and 12). The outline uses the agent's accent
    /// so the user can tell what Hermes did.
    func hermexHighlight(id: String, cornerRadius: CGFloat = 18) -> some View {
        modifier(HermexHighlightModifier(id: id, cornerRadius: cornerRadius))
    }
}

/// The agent's accent color (#BFF35C).
public let hermexAccent = Color(red: 0xBF / 255, green: 0xF3 / 255, blue: 0x5C / 255)

private struct HermexHighlightModifier: ViewModifier {
    let id: String
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isOn = HermexHighlights.shared.ids.contains(id)
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(hermexAccent, lineWidth: 3)
                    .opacity(isOn ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isOn)
            .accessibilityValue(isOn ? Text(verbatim: "Changed by Hermes") : Text(verbatim: ""))
    }
}
