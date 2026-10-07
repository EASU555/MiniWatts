import SwiftUI
import UIKit

struct ProblemReportView: View {
    private enum ReportOperation: Equatable {
        case marking, previewing, exporting

        var progressLabel: LocalizedStringResource {
            switch self {
            case .marking: "Marking problem time"
            case .previewing: "Preparing preview"
            case .exporting: "Preparing report for export"
            }
        }
    }

    @Environment(PowerMonitor.self) private var monitor
    @Environment(TelemetryPictureInPictureController.self) private var pictureInPicture
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var markedAt: Date?
    @State private var operation: ReportOperation?
    @State private var completionMessage: LocalizedStringResource?
    @State private var export: ProblemReportRecorder.Export?
    @State private var preview = ""
    @State private var errorTitle: LocalizedStringKey = "Could not prepare report"
    @State private var errorDetails: String?

    private var busy: Bool { operation != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Key events are recorded locally while MiniWatts runs. The previous run is retained after reopening the app. Reports are only shared when you export them.")
                        .foregroundStyle(.secondary)
                    Button {
                        operation = .marking
                        completionMessage = nil
                        Task { @MainActor in
                            defer { operation = nil }
                            do { markedAt = try await ProblemReportRecorder.shared.markIssue() }
                            catch {
                                errorTitle = "Could not mark problem time"
                                errorDetails = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Mark problem time", systemImage: "flag")
                    }
                    .disabled(busy)
                    if operation == .marking {
                        ProgressView("Marking problem time")
                    }
                    if let markedAt {
                        LabeledContent("Problem time marked") {
                            Text(markedAt, style: .time)
                        }
                    }
                }
                Section("Problem description (optional)") {
                    TextField("What happened? What did you tap?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .disabled(busy)
                        .onChange(of: note) { _, value in
                            if value.count > 2000 { note = String(value.prefix(2000)) }
                        }
                    Text("\(note.count) of 2,000 characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Section {
                    Button { makeReport(share: true) } label: {
                        Label("Export problem report", systemImage: "square.and.arrow.up")
                    }
                    .disabled(busy)
                    Button { makeReport(share: false) } label: {
                        Label("Preview problem report", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(busy)
                    if let operation, operation != .marking {
                        ProgressView { Text(operation.progressLabel) }
                    } else if let completionMessage {
                        Label {
                            Text(completionMessage)
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                        .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Includes app/iOS versions, device model, readings and recent events. No Apple ID, device serial number or other app content is collected. You can save the text file to Files and send it for troubleshooting.")
                }
                if !preview.isEmpty {
                    Section("Report preview") {
                        Text("Preview shows up to 24,000 characters. The exported file includes all retained records.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: preview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Problem report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $export) { item in ReportShareSheet(url: item.url) }
            .alert(errorTitle, isPresented: Binding(
                get: { errorDetails != nil }, set: { if !$0 { errorDetails = nil } }
            )) {
                Button("OK", role: .cancel) { errorDetails = nil }
            } message: {
                Text(verbatim: errorDetails ?? "")
            }
        }
    }

    private func makeReport(share: Bool) {
        // Put PiP state before the longer sensor traces, so the report's size
        // limit cannot silently remove the coexistence evidence.
        let summary = "# Picture in Picture\n" + pictureInPicture.diagnosticSummary
            + "\n\n" + monitor.diagnosticReport
        let description = note
        operation = share ? .exporting : .previewing
        completionMessage = nil
        Task { @MainActor in
            defer { operation = nil }
            do {
                let result = try await ProblemReportRecorder.shared.export(summary: summary, note: description)
                if share {
                    export = result
                    completionMessage = "Report ready to share."
                } else {
                    preview = result.preview
                    completionMessage = "Preview ready below."
                }
            } catch {
                errorTitle = "Could not prepare report"
                errorDetails = error.localizedDescription
            }
        }
    }
}

private struct ReportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
