import NanflowCore
import SwiftUI

/// Editor/export window for a single meeting: editable summary + transcript,
/// Markdown-to-clipboard export and PDF export.
struct MeetingDetailView: View {
    @ObservedObject var model: MeetingDetailModel
    @State private var savedFlash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            toolbar
            Divider()
            if model.saved {
                Label("Guardado", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            TextEditor(text: $model.summary)
                .font(.system(size: 13))
                .frame(minHeight: 180)
                .overlay(rounded)
            Text("Transcripción")
                .font(.headline)
            TextEditor(text: $model.transcript)
                .font(.system(size: 12))
                .frame(minHeight: 220)
                .overlay(rounded)
            Text("El portapapeles recibe Markdown listo para pegar en cualquier editor (.md).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 640, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var rounded: some View {
        RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "person.2.fill").foregroundStyle(.blue)
                Text("\(model.appName) · \(MeetingExporter.durationLabel(model.duration))")
                    .font(.headline)
                Spacer()
                Text(model.dateLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                model.copyMarkdown()
            } label: {
                Label("Copiar Markdown", systemImage: "doc.on.doc.fill")
            }
            Button {
                Task { await model.exportPDF() }
            } label: {
                Label("Exportar PDF", systemImage: "arrow.down.doc")
            }
            Button {
                model.save()
                savedFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedFlash = false }
            } label: {
                Label("Guardar cambios", systemImage: "square.and.arrow.down")
            }
            Spacer()
            if model.pdfURL != nil {
                Label("PDF guardado", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }
}

/// Observable backing for the meeting detail window.
@MainActor
final class MeetingDetailModel: ObservableObject {
    @Published var entryId: UUID
    @Published var summary: String
    @Published var transcript: String
    @Published var saved = false
    @Published var pdfURL: URL?

    private let history = HistoryStore()

    let appName: String
    let duration: TimeInterval
    let dateLabel: String

    init(entry: HistoryEntry) {
        entryId = entry.id
        summary = entry.summary ?? ""
        transcript = entry.rawText
        appName = entry.app
        duration = entry.audioDuration
        dateLabel = Self.staticDateLabel(entry.timestamp)
    }

    nonisolated static func staticDateLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        return df.string(from: date)
    }



    func save() {
        var entry = history.all().first(where: { $0.id == entryId }) ?? HistoryEntry(kind: .meeting)
        entry.summary = summary
        entry.rawText = transcript
        history.update(entry)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.saved = false }
    }

    func copyMarkdown() {
        save()
        var entry = history.all().first(where: { $0.id == entryId }) ?? HistoryEntry(kind: .meeting)
        MeetingExporter.copyToClipboard(entry)
    }

    func exportPDF() async {
        save()
        if let entry = history.all().first(where: { $0.id == entryId }) {
            pdfURL = await MeetingExporter.exportPDF(entry)
        }
    }
}

/// Keeps one window alive and swaps its content per meeting.
final class MeetingDetailWindowController {
    static let shared = MeetingDetailWindowController()
    private var window: NSWindow?

    @MainActor
    func show(entry: HistoryEntry) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Nanflow · Reunión"
            w.isReleasedWhenClosed = false
            window = w
        }
        let model = MeetingDetailModel(entry: entry)
        window?.contentView = NSHostingView(rootView: MeetingDetailView(model: model))
        window?.title = "Nanflow · \(entry.app) — \(MeetingDetailModel.staticDateLabel(entry.timestamp))"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
