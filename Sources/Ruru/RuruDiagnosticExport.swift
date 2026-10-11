import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RuruDiagnosticExportSession: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published var isExporterPresented = false
    @Published var isShowingFailure = false
    @Published private(set) var report: RuruDiagnosticReportFile?
    @Published private(set) var filename: String?
    @Published private(set) var failureMessage = ""

    func begin(model: WitnessAppModel) {
        guard !isPreparing, !isExporterPresented else { return }
        isPreparing = true
        let snapshot = model.diagnosticSnapshot()
        Task {
            await Task.yield()
            let text = await Task.detached(priority: .userInitiated) {
                RuruDiagnostics.buildReport(snapshot)
            }.value
            report = RuruDiagnosticReportFile(text: text)
            filename = RuruDiagnostics.defaultFilename(for: snapshot.generatedAt)
            isPreparing = false
            isExporterPresented = true
        }
    }

    func finish(savedTo url: URL) {
        report = nil
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func fail(_ error: Error) {
        report = nil
        failureMessage = error.localizedDescription
        isShowingFailure = true
    }

    func cancel() { report = nil }
}

struct RuruDiagnosticReportFile: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { Data($0.text.utf8) }
    }
}

private struct RuruDiagnosticExportPresenter: ViewModifier {
    @ObservedObject var session: RuruDiagnosticExportSession

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $session.isExporterPresented,
                item: session.report,
                contentTypes: [.plainText],
                defaultFilename: session.filename
            ) { result in
                switch result {
                case .success(let url): session.finish(savedTo: url)
                case .failure(let error): session.fail(error)
                }
            }
            .alert("Couldn't save diagnostic report", isPresented: $session.isShowingFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.failureMessage)
            }
    }
}

extension View {
    func ruruDiagnosticExportPresenter(_ session: RuruDiagnosticExportSession) -> some View {
        modifier(RuruDiagnosticExportPresenter(session: session))
    }
}
