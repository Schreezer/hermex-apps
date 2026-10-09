import CoreText
import SwiftUI
import UIKit

/// Design tokens for the Apps surfaces (BUILD_SPEC §5). The accent is reserved
/// for Hermes and its actions so the user can always tell what the agent did.
enum HermexAppsTheme {
    static let background = Color(hex: 0x0B0C0E)
    static let surface = Color(hex: 0x16181B)
    static let surface2 = Color(hex: 0x1F2226)
    static let line = Color(hex: 0x2B2F35)
    static let text = Color(hex: 0xF3F2ED)
    static let muted = Color(hex: 0xA0A5AD)
    static let faint = Color(hex: 0x8A8F97)
    static let accent = Color(hex: 0xBFF35C)
    static let onAccent = Color(hex: 0x10140A)
    static let destructive = Color(hex: 0xFF8F8F)

    // Bundled faces (Resources/Fonts), scaled with Dynamic Type. Each falls
    // back to the system face at the same weight if a font fails to load.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle = .title) -> Font {
        scaled(spaceGrotesk(size: size, weight: weight) ?? .systemFont(ofSize: size, weight: weight.uiWeight), relativeTo: style)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .medium: "IBMPlexSans-Medm"
        case .semibold, .bold: "IBMPlexSans-SmBld"
        default: "IBMPlexSans"
        }
        return scaled(UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight.uiWeight), relativeTo: style)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .caption) -> Font {
        let name = weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium"
        return scaled(UIFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight.uiWeight), relativeTo: style)
    }

    /// Space Grotesk ships as one variable face (weight axis 300–700) whose
    /// named instances skip SemiBold, so the weight is set on the axis.
    private static func spaceGrotesk(size: CGFloat, weight: Font.Weight) -> UIFont? {
        guard let base = UIFont(name: "SpaceGrotesk-Light", size: size) else { return nil }
        let wghtAxis = 0x7767_6874 // 'wght'
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        return UIFont(descriptor: base.fontDescriptor.addingAttributes([variation: [wghtAxis: weight.numericValue]]), size: size)
    }

    /// Scales with Dynamic Type like the text style it stands in for.
    private static func scaled(_ font: UIFont, relativeTo style: Font.TextStyle) -> Font {
        Font(UIFontMetrics(forTextStyle: style.uiTextStyle).scaledFont(for: font))
    }
}

private extension Font.Weight {
    var numericValue: CGFloat {
        switch self {
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        default: 400
        }
    }

    var uiWeight: UIFont.Weight {
        switch self {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// `amount` of `hex` laid over `base`: tinted card fills and borders.
    init(hex: UInt32, over base: UInt32, amount: Double) {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        func mix(_ shift: UInt32) -> Double { channel(base, shift) * (1 - amount) + channel(hex, shift) * amount }
        self.init(red: mix(16), green: mix(8), blue: mix(0))
    }
}
