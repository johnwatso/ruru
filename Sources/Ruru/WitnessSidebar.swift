import AppKit
import SwiftUI

/// Local Sequoia-compatible adaptation of SwiftMiner's sidebar.
struct WitnessSidebar: View {
    @Binding var selection: WitnessPage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionHighlightNamespace
    @State private var rowFrames: [WitnessPage: CGRect] = [:]

    private static let dragCoordinateSpace = "witnessSidebarSelectorDrag"

    var body: some View {
        ZStack {
            WitnessSidebarBackground()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(WitnessPage.allCases) { page in
                        row(for: page)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .coordinateSpace(name: Self.dragCoordinateSpace)
                .onPreferenceChange(WitnessSidebarRowFramesKey.self) { rowFrames = $0 }
                .simultaneousGesture(selectionDragGesture)
                .onMoveCommand { direction in
                    let pages = WitnessPage.allCases
                    guard let index = pages.firstIndex(of: selection ?? .overview) else { return }
                    switch direction {
                    case .up: select(pages[max(0, index - 1)])
                    case .down: select(pages[min(pages.count - 1, index + 1)])
                    default: break
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func row(for page: WitnessPage) -> some View {
        let isSelected = (selection ?? .overview) == page
        return Button {
            select(page)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(page.rawValue)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    WitnessSidebarSelectionHighlight()
                        .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionHighlightNamespace)
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: WitnessSidebarRowFramesKey.self,
                        value: [page: geometry.frame(in: .named(Self.dragCoordinateSpace))]
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(page.purpose)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ page: WitnessPage) {
        guard selection != page else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            selection = page
        }
    }

    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.dragCoordinateSpace))
            .onChanged { value in
                guard let page = WitnessPage.allCases.first(where: {
                    rowFrames[$0]?.contains(value.location) ?? false
                }) else { return }
                select(page)
            }
    }
}

private struct WitnessSidebarRowFramesKey: PreferenceKey {
    static var defaultValue: [WitnessPage: CGRect] { [:] }
    static func reduce(value: inout [WitnessPage: CGRect], nextValue: () -> [WitnessPage: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct WitnessSidebarSelectionHighlight: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(controlActiveState == .active ? Material.ultraThinMaterial : .bar)
            }
        }
        .overlay {
            shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.25 : 1)
                .allowsHitTesting(false)
        }
    }
}

private struct WitnessSidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .underPageBackgroundColor)
            } else {
                WitnessSidebarMaterial()
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

private struct WitnessSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}
