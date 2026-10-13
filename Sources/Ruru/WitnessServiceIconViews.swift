import SwiftUI
import UniformTypeIdentifiers

/// Accepts an app (.app) or image dropped anywhere on a sheet.
private struct ServiceIconDropTarget: ViewModifier {
    let onPick: (RuruServiceIcons.Pick) -> Void
    let onError: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                do { onPick(try RuruServiceIcons.pick(from: url)) }
                catch { onError(error.localizedDescription) }
                return true
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { Label("Drop to use this icon", systemImage: "square.and.arrow.down").font(.headline).foregroundStyle(Color.accentColor) }
                        .padding(6).allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func serviceIconDrop(onPick: @escaping (RuruServiceIcons.Pick) -> Void, onError: @escaping (String) -> Void) -> some View {
        modifier(ServiceIconDropTarget(onPick: onPick, onError: onError))
    }
}

/// Icon preview with Choose and Use Default controls. Dropping onto the sheet is
/// handled by `serviceIconDrop`; both routes share `RuruServiceIcons.pick`.
struct WitnessServiceIconPicker: View {
    /// The icon to show, or nil for the template icon.
    let image: NSImage?
    let templateSymbol: String
    let onPick: (RuruServiceIcons.Pick) -> Void
    let onClear: () -> Void
    let onError: (String) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ConsoleIconTile(symbol: templateSymbol, size: 64)
                }
            }
            .frame(width: 64, height: 64)
            .accessibilityLabel(image == nil ? "Default icon" : "Custom icon")
            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.callout.weight(.medium))
                Text("Drag an app or image onto this window, or choose one.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose…", action: choose)
                    if image != nil { Button("Use Default", action: onClear) }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an app to use its icon, or an image."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { onPick(try RuruServiceIcons.pick(from: url)) }
        catch { onError(error.localizedDescription) }
    }
}
