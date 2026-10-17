import AppKit
import Foundation

/// Exports a meeting entry as Markdown (clipboard) or PDF (Cocoa text rendering).
public enum MeetingExporter {
    public static func markdown(for entry: HistoryEntry) -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short

        var md = "# \(entry.app) meeting — \(df.string(from: entry.timestamp))\n\n"
        md += "- **Duration:** \(Self.durationLabel(entry.audioDuration))\n"
        md += "- **Recorded by:** Nanflow (\(entry.app))\n\n"

        if let summary = entry.summary, !summary.isEmpty {
            md += "## Summary\n\n\(summary)\n\n"
        }
        if !entry.rawText.isEmpty {
            md += "## Transcript\n\n\(entry.rawText)\n"
        }
        return md
    }

    /// Copies the meeting as Markdown to the clipboard, ready to paste into any editor.
    public static func copyToClipboard(_ entry: HistoryEntry) {
        let md = markdown(for: entry)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    /// Renders the meeting report to PDF data via the Cocoa text system.
    public static func pdfData(for entry: HistoryEntry) -> Data {
        let md = markdown(for: entry)
        let content = NSAttributedString(
            string: md,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black,
            ]
        )

        let frame = NSRect(x: 0, y: 0, width: 523, height: 770) // A4 menos márgenes
        let tv = NSTextView(frame: frame)
        tv.textStorage?.setAttributedString(content)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nanflow-\(UUID().uuidString).pdf")
        let printInfo = NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tempURL

        let op = NSPrintOperation(view: tv, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()

        let data = (try? Data(contentsOf: tempURL)) ?? Data()
        try? FileManager.default.removeItem(at: tempURL)
        return data
    }

    /// Renders and asks where to save the PDF. Returns the chosen URL, if any.
    @MainActor
    public static func exportPDF(_ entry: HistoryEntry) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "reunion-\(df.string(from: entry.timestamp)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = pdfData(for: entry)
        try? data.write(to: url)
        return url
    }

    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
