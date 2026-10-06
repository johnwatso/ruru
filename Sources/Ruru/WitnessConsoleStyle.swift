// Sequoia-compatible adaptations of SwiftBot's native console components.
import SwiftUI

struct WitnessGlassBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [
                Color(nsColor: .controlBackgroundColor).opacity(scheme == .dark ? 0.34 : 0.24),
                Color(nsColor: .underPageBackgroundColor).opacity(scheme == .dark ? 0.24 : 0.16),
                Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.18 : 0.10)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            Color.primary.opacity(scheme == .dark ? 0.030 : 0.012)
        }.ignoresSafeArea()
    }
}

enum WitnessHealth {
    case healthy, warning, error, inactive
    var tint: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .error: .red
        case .inactive: .secondary
        }
    }
}

struct WitnessStatusBadge: View {
    let text: String
    let health: WitnessHealth
    var body: some View {
        Label {
            Text(text)
        } icon: {
            Circle().fill(health.tint).frame(width: 7, height: 7).accessibilityHidden(true)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(health.tint)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(health.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct ConsolePageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                heading
                Spacer(minLength: 24)
                accessory.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) { heading; accessory }
        }.controlSize(.large)
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ConsolePageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

struct ConsoleSection<Content: View, Accessory: View>: View {
    let title: String
    var padding: CGFloat = 22
    var headerInset: CGFloat = 0
    var fillsAvailableHeight = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory.font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, headerInset)
            content
        }
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .top)
        .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        .consoleSurface()
    }
}

extension ConsoleSection where Accessory == EmptyView {
    init(_ title: String, padding: CGFloat = 22, headerInset: CGFloat = 0, fillsAvailableHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, padding: padding, headerInset: headerInset, fillsAvailableHeight: fillsAvailableHeight,
                  accessory: { EmptyView() }, content: content)
    }
}

extension View {
    func consoleSurface(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(.primary.opacity(0.07), lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.02), radius: 3, y: 1)
    }
    func consoleRowGroup() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(.background.opacity(0.55)))
            .overlay(shape.strokeBorder(.primary.opacity(0.05), lineWidth: 1).allowsHitTesting(false))
    }
}

struct ConsoleIconTile: View {
    let symbol: String
    var brandAsset: String?
    var active = true
    var size: CGFloat = 42
    var body: some View {
        Group {
            if let brandAsset {
                Image(brandAsset).resizable().scaledToFit().frame(width: size * 0.62, height: size * 0.62)
                    .saturation(active ? 1 : 0).opacity(active ? 1 : 0.55)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct ConsoleSettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                label
                Spacer(minLength: 16)
                trailing
            }
            VStack(alignment: .leading, spacing: 10) { label; trailing }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.weight(.medium))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct ConsoleValueRow: View {
    let title: String
    let value: String
    var monospaced = false
    var body: some View {
        ConsoleSettingRow(title: title) {
            Text(value).font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConsoleIssue: View {
    let title: String
    let detail: String
    var health: WitnessHealth = .warning
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: health == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(health.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(health.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .textSelection(.enabled)
    }
}

struct ConsoleEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
        }
        .padding(.vertical, 28).frame(maxWidth: .infinity)
    }
}

struct ConsoleActionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
