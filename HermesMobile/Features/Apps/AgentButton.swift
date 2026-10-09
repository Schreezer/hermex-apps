import SwiftUI

/// Where the Hermes button sits over one app (BUILD_SPEC §6.1): one of four
/// spots on either side edge, or tucked into a tab on that edge. Saved per app.
struct AgentButtonPlacement: Codable, Equatable {
    enum Side: String, Codable {
        case leading
        case trailing
    }

    static let slotCount = 4

    var side = Side.trailing
    /// 0 is the top spot; the default sits just above the app's tab bar.
    var slot = slotCount - 1
    var isTucked = false

    private static func key(_ appID: String) -> String { "agentButton.placement.\(appID)" }

    static func load(appID: String, defaults: UserDefaults = .standard) -> AgentButtonPlacement {
        guard let data = defaults.data(forKey: key(appID)),
              let placement = try? JSONDecoder().decode(AgentButtonPlacement.self, from: data) else {
            return AgentButtonPlacement()
        }
        return placement
    }

    func save(appID: String, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(appID))
    }

    /// The spot's center in a container of `size`.
    static func center(side: Side, slot: Int, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 18 + 30
        let top: CGFloat = 96
        let bottom = max(top, size.height - 112 - 30)
        let fraction = CGFloat(min(max(slot, 0), slotCount - 1)) / CGFloat(slotCount - 1)
        return CGPoint(
            x: side == .leading ? inset : size.width - inset,
            y: top + (bottom - top) * fraction
        )
    }

    /// Where a drag released at `point` lands: the nearest spot on that half,
    /// tucked when the throw carries past the edge.
    static func landing(at point: CGPoint, in size: CGSize) -> AgentButtonPlacement {
        let side: Side = point.x < size.width / 2 ? .leading : .trailing
        let slot = (0..<slotCount).min { a, b in
            abs(center(side: side, slot: a, in: size).y - point.y) < abs(center(side: side, slot: b, in: size).y - point.y)
        } ?? slotCount - 1
        let edgeMargin: CGFloat = 8
        let isTucked = point.x < edgeMargin || point.x > size.width - edgeMargin
        return AgentButtonPlacement(side: side, slot: slot, isTucked: isTucked)
    }
}

/// The Hermes button over a running app: drag to move, snap to a spot, throw
/// past an edge to tuck it into a tab that never fully hides.
struct AgentButtonLayer: View {
    let appName: String
    @Binding var placement: AgentButtonPlacement
    let open: () -> Void

    @State private var dragCenter: CGPoint?
    @State private var tuckHint: AgentButtonPlacement?
    @AppStorage("agentButton.didShowTuckHint") private var didShowTuckHint = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Theme = HermexAppsTheme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if dragCenter != nil {
                    slotDots(in: size)
                }
                if placement.isTucked {
                    edgeSwipeStrip(in: size)
                    tab(in: size)
                } else {
                    button(in: size)
                }
                if let tuckHint {
                    hint(for: tuckHint)
                        .frame(width: size.width - 24)
                        .position(x: size.width / 2, y: size.height - 104 - 40)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: placement)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: tuckHint)
    }

    private func button(in size: CGSize) -> some View {
        let rest = AgentButtonPlacement.center(side: placement.side, slot: placement.slot, in: size)
        return HermesMark()
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .frame(width: 26, height: 26)
            .frame(width: 60, height: 60)
            .background(Theme.background, in: Circle())
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 3))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
            .contentShape(Circle())
            .position(dragCenter ?? rest)
            .onTapGesture(perform: open)
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .local)
                    .onChanged { dragCenter = $0.location }
                    .onEnded { value in
                        dragCenter = nil
                        let landing = AgentButtonPlacement.landing(at: value.predictedEndLocation, in: size)
                        settle(at: landing)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Ask Hermes about this screen"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
            .accessibilityAction(named: Text("Move up")) { move(by: -1) }
            .accessibilityAction(named: Text("Move down")) { move(by: 1) }
            .accessibilityAction(named: Text("Move to the other side")) {
                placement.side = placement.side == .leading ? .trailing : .leading
            }
            .accessibilityAction(named: Text("Tuck to the edge")) { settle(at: tucked(placement)) }
    }

    private func tab(in size: CGSize) -> some View {
        let isTrailing = placement.side == .trailing
        let y = AgentButtonPlacement.center(side: placement.side, slot: placement.slot, in: size).y
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isTrailing ? 18 : 0,
            bottomLeadingRadius: isTrailing ? 18 : 0,
            bottomTrailingRadius: isTrailing ? 0 : 18,
            topTrailingRadius: isTrailing ? 0 : 18
        )
        return VStack(spacing: 4) {
            HermesMark()
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
                .frame(width: 16, height: 16)
            Image(systemName: isTrailing ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Theme.accent)
        }
        .frame(width: 30, height: 76)
        .background(Theme.background, in: shape)
        .overlay(alignment: isTrailing ? .leading : .trailing) {
            Theme.accent.frame(width: 3).clipShape(shape)
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 8)
        .contentShape(Rectangle().inset(by: -8))
        .position(x: isTrailing ? size.width - 15 : 15, y: y)
        .onTapGesture { untuck() }
        .accessibilityElement()
        .accessibilityLabel(Text("Open Hermes"))
        .accessibilityHint(Text("Brings the Hermes button back"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { untuck() }
    }

    /// A thin strip on the tucked edge: swiping in from it brings Hermes back.
    private func edgeSwipeStrip(in size: CGSize) -> some View {
        let isTrailing = placement.side == .trailing
        // Not Color.clear: over the guest's UIKit view a fully clear view loses
        // UIKit hit-testing even with a content shape, and the app gets the touch.
        return Color.black.opacity(0.001)
            .frame(width: 20, height: size.height)
            .contentShape(Rectangle())
            .position(x: isTrailing ? size.width - 10 : 10, y: size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        let inward = isTrailing ? -value.translation.width : value.translation.width
                        if inward > 30 { untuck() }
                    }
            )
            .accessibilityHidden(true)
    }

    private func slotDots(in size: CGSize) -> some View {
        ForEach([AgentButtonPlacement.Side.leading, .trailing], id: \.self) { side in
            ForEach(0..<AgentButtonPlacement.slotCount, id: \.self) { slot in
                let center = AgentButtonPlacement.center(side: side, slot: slot, in: size)
                Circle()
                    .fill(Color(hex: 0xCDBFB0))
                    .frame(width: 6, height: 6)
                    .position(x: side == .leading ? 9 : size.width - 9, y: center.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func hint(for previous: AgentButtonPlacement) -> some View {
        HStack(spacing: 10) {
            Text(previous.side == .trailing
                 ? "Tucked to the edge. Tap the tab or swipe in from the right to bring Hermes back."
                 : "Tucked to the edge. Tap the tab or swipe in from the left to bring Hermes back.")
                .font(Theme.body(14, relativeTo: .subheadline))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                placement = previous
                tuckHint = nil
            } label: {
                Text("Undo")
                    .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color(hex: 0x111315), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
        .shadow(color: .black.opacity(0.35), radius: 15, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }

    private func settle(at landing: AgentButtonPlacement) {
        let previous = placement
        placement = landing
        guard landing.isTucked, !previous.isTucked, !didShowTuckHint else { return }
        didShowTuckHint = true
        tuckHint = previous
        Task {
            try? await Task.sleep(for: .seconds(6))
            tuckHint = nil
        }
    }

    private func tucked(_ placement: AgentButtonPlacement) -> AgentButtonPlacement {
        var tucked = placement
        tucked.isTucked = true
        return tucked
    }

    private func move(by delta: Int) {
        placement.slot = min(max(placement.slot + delta, 0), AgentButtonPlacement.slotCount - 1)
    }

    private func untuck() {
        placement.isTucked = false
        tuckHint = nil
    }
}

/// The agent's mark: an "H" with a slanted crossbar (24-point grid).
struct HermesMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        path.move(to: point(7, 5)); path.addLine(to: point(7, 19))
        path.move(to: point(17, 5)); path.addLine(to: point(17, 19))
        path.move(to: point(7, 13.5)); path.addLine(to: point(17, 10.5))
        return path
    }
}
