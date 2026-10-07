import SwiftUI
import WitnessKit

struct WitnessLegacyStorageNotice: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State private var showingSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Old SQLite storage needs explicit replacement before Ruru can start.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Set Up DuckDB…", systemImage: "externaldrive") { showingSetup = true }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .disabled(model.busy || model.internetBusy)
        }
        .sheet(isPresented: $showingSetup) { WitnessLegacyStorageSetupSheet().environmentObject(model) }
    }
}

struct WitnessLegacyStorageSetupSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var clientsStopped = false
    @State private var oldAppStopped = false
    @State private var replacing = false
    @State private var error: String?

    private var valid: Bool { clientsStopped && oldAppStopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WitnessSheetHeader(title: "Set Up DuckDB", subtitle: "Archive the old SQLite authority and create fresh pairing details.", symbol: "externaldrive")
            Text("Old leases, names and history will stay in a local archive. Every remaining service gets a new ownership group and bearer token. Re-pair its servers using Guarding → Connection Details. Ruru stays stopped after setup.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("All participating clients are stopped and unpaired", isOn: $clientsStopped)
            Toggle("The older app is stopped and will not be run again", isOn: $oldAppStopped)
            if let error { ConsoleIssue(title: "Storage could not be replaced", detail: error) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(replacing)
                Spacer()
                Button(replacing ? "Setting Up…" : "Archive and Set Up") {
                    replacing = true
                    Task {
                        do { try await model.replaceLegacyStorage(); dismiss() }
                        catch { self.error = error.localizedDescription; replacing = false }
                    }
                }.buttonStyle(.borderedProminent).disabled(!valid || replacing || model.busy)
            }
        }.padding(24).frame(width: 580).interactiveDismissDisabled(replacing)
    }
}
