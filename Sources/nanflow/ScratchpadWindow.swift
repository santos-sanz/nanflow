import AppKit
import NanflowCore
import SwiftUI

@MainActor
final class ScratchpadModel: ObservableObject {
    @Published var text: String
    private var saveTask: Task<Void, Never>?

    init() {
        text = ScratchpadStore.shared.read()
    }

    func textDidChange() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            let value = self.text
            ScratchpadStore.shared.write(value)
        }
    }
}

struct ScratchpadView: View {
    @ObservedObject var model: ScratchpadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.blue)
                Text("Scratchpad")
                    .font(.headline)
                Spacer()
                Text("Guardado automático en scratchpad.md")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $model.text)
                .font(.system(size: 13))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
                .onChange(of: model.text) { _ in
                    model.textDidChange()
                }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 460)
    }
}

@MainActor
final class ScratchpadWindowController {
    static let shared = ScratchpadWindowController()
    private var window: NSWindow?
    private let model = ScratchpadModel()

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Nanflow · Scratchpad"
            w.contentView = NSHostingView(rootView: ScratchpadView(model: model))
            w.isReleasedWhenClosed = false
            window = w
        }
        model.text = ScratchpadStore.shared.read()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
