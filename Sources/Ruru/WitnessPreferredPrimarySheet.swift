import SwiftUI
import WitnessKit

struct WitnessPreferredPrimarySheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    let service: GuardedService
    private enum Choice: Hashable { case none, node(String), manual }
    @State private var choice: Choice = .none
    @State private var manualNodeID = ""
    @State private var saving = false
    @State private var error: String?

    private var selectedNodeID: String? {
        switch choice {
        case .none: nil
        case .node(let id): id
        case .manual: manualNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    private var canSave: Bool {
        selectedNodeID.map(WitnessPrimaryPreference.validNodeID) != false &&
        selectedNodeID != model.configuration.primaryPreference(for: service.id).preferredPrimaryNodeID &&
        !saving && !model.busy && !model.internetBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferred Primary").font(.title2.weight(.semibold))
            Text("Choose the server that should normally own \(service.name). Current ownership stays separate from this preference.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Server", selection: $choice) {
                Text("No preference").tag(Choice.none)
                ForEach(model.knownNodes(for: service.clusterID), id: \.self) { node in
                    Text(model.nodeDisplayName(for: node, reportedName: model.reportedName(for: node, clusterID: service.clusterID), clusterID: service.clusterID) + " · " + node)
                        .tag(Choice.node(node))
                }
                Text("Enter Node ID…").tag(Choice.manual)
            }.pickerStyle(.menu)
            if case .manual = choice {
                TextField("Server node ID", text: $manualNodeID).textFieldStyle(.roundedBorder)
                Text("Copy the stable node ID from the intended server. A standby may not appear in Ruru until it has held ownership.")
                    .font(.caption).foregroundStyle(.secondary)
                if !manualNodeID.isEmpty, !WitnessPrimaryPreference.validNodeID(selectedNodeID ?? "") {
                    Text("Use a node ID of 1–128 UTF-8 bytes, without control characters.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let id = selectedNodeID {
                Text(id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Requires a compatible client. It must coordinate a safe handover and keep failover available when this server is unavailable. This setting never grants permission to act.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { ConsoleIssue(title: "Preference could not be saved", detail: error) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save Preference") {
                    Task {
                        saving = true
                        defer { saving = false }
                        do { try await model.setPreferredPrimary(selectedNodeID, for: service.id); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!canSave).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540).disabled(saving).interactiveDismissDisabled(saving)
            .onAppear {
                guard let preferred = model.configuration.primaryPreference(for: service.id).preferredPrimaryNodeID else { return }
                if model.knownNodes(for: service.clusterID).contains(preferred) { choice = .node(preferred) }
                else { choice = .manual; manualNodeID = preferred }
            }
    }
}
