import SwiftUI
import WitnessKit

/// Gives Ruru a public HTTPS address: paste a Cloudflare token, choose one of
/// its domains, pick a subdomain, connect. Shared by the setup assistant and
/// Internet Access. Ends with a check that the address answers from outside.
struct RuruCloudflareConnect: View {
    @EnvironmentObject private var model: WitnessAppModel
    /// Called once the address is connected and reachable.
    var onConnected: () -> Void = {}

    @State private var token = ""
    @State private var domains: [CloudflareDomain] = []
    @State private var domain: CloudflareDomain?
    @State private var subdomain = "ruru"
    @State private var finding = false
    @State private var connecting = false
    @State private var verifying = false
    @State private var reachable: Bool?
    @State private var error: String?

    private static let steps = ["Checking Cloudflare access", "Checking the hostname", "Creating Ruru’s tunnel",
                                "Connecting the local Ruru service", "Creating the HTTPS address",
                                "Starting Cloudflare’s connector on this Mac"]

    private var hostname: String? {
        guard let domain else { return nil }
        let label = subdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return WitnessInternetSetup.normalizedHostname(label.isEmpty ? domain.name : label + "." + domain.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.configuration.tunnel.isConfigured && !connecting {
                connected
            } else if connecting {
                progress
            } else if domains.isEmpty {
                tokenEntry
            } else {
                chooseAddress
            }
            if let error {
                ConsoleIssue(title: "That didn’t work", detail: error)
            }
        }
    }

    // MARK: Stages

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste a Cloudflare API token. Ruru will show the domains it can use.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                SecureField("API token", text: $token, prompt: Text(model.hasSavedCloudflareToken ? "Use the saved token" : "Paste token"))
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Create a Custom Token with these permissions:").font(.callout.weight(.medium))
                ForEach(["Zone → Zone → Read", "Zone → DNS → Edit", "Account → Cloudflare Tunnel → Edit"], id: \.self) {
                    Label($0, systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                }
                Link("Open Cloudflare API Tokens", destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
                    .font(.callout).padding(.top, 2)
            }
            HStack {
                if finding { ProgressView().controlSize(.small); Text("Looking up domains…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Find My Domains", action: findDomains)
                    .buttonStyle(.borderedProminent)
                    .disabled(finding || (token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.hasSavedCloudflareToken))
            }
        }
    }

    private var chooseAddress: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the address your servers will use.")
                .foregroundStyle(.secondary)
            Form {
                Picker("Domain", selection: $domain) {
                    ForEach(domains) { Text($0.name).tag(Optional($0)) }
                }
                LabeledContent("Subdomain") {
                    TextField("Subdomain", text: $subdomain, prompt: Text("ruru"))
                        .labelsHidden().multilineTextAlignment(.trailing)
                }
                LabeledContent("Address") {
                    Text(hostname.map { "https://" + $0 } ?? "Enter a valid subdomain")
                        .font(.body.monospaced())
                        .foregroundStyle(hostname == nil ? .orange : .primary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            Text("Ruru creates its own tunnel and DNS record for this address. It won’t replace a record that already exists.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use a Different Token") { domains = []; domain = nil; error = nil }.buttonStyle(.link)
                Spacer()
                Button("Connect", action: connect).buttonStyle(.borderedProminent).disabled(hostname == nil)
            }
        }
    }

    private var progress: some View {
        let current = Self.steps.firstIndex { model.internetProgress.hasPrefix($0) } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("Connecting \(hostname ?? model.configuration.tunnel.hostname)…").font(.headline)
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    Group {
                        if index < current { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        else if index == current { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }.frame(width: 18)
                    Text(step).foregroundStyle(index <= current ? .primary : .secondary)
                }
            }
            Text("This usually takes under a minute.").font(.callout).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.internetStatus.state == .enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(model.internetStatus.state == .enabled ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.internetStatus.state == .enabled ? "Connected" : "Configured, not connected").font(.headline)
                    Text(model.configuration.publicEndpoint).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            HStack(spacing: 10) {
                if verifying {
                    ProgressView().controlSize(.small)
                    Text("Checking Ruru answers from the internet…").font(.callout).foregroundStyle(.secondary)
                } else if reachable == true {
                    Label("Reachable from the internet", systemImage: "checkmark").font(.callout).foregroundStyle(.green)
                }
                Spacer()
                Button(reachable == nil ? "Check Address" : "Check Again", action: verify).disabled(verifying)
            }
        }
        .onAppear { if reachable == nil && !verifying { verify() } }
    }

    // MARK: Actions

    private func findDomains() {
        finding = true
        error = nil
        Task {
            do {
                domains = try await model.cloudflareDomains(tokenDraft: token.trimmingCharacters(in: .whitespacesAndNewlines))
                domain = domains.first
            } catch { self.error = error.localizedDescription }
            finding = false
        }
    }

    private func connect() {
        guard let hostname else { return }
        connecting = true
        error = nil
        Task {
            do {
                try await model.connectCloudflare(hostname: hostname, tokenDraft: token.trimmingCharacters(in: .whitespacesAndNewlines))
                token = ""
                connecting = false
                verify()
            } catch {
                self.error = error.localizedDescription
                connecting = false
            }
        }
    }

    private func verify() {
        verifying = true
        error = nil
        Task {
            let failure = await model.verifyPublicAddress()
            reachable = failure == nil
            error = failure
            verifying = false
            if failure == nil { onConnected() }
        }
    }
}
