import AppKit
import CoreGraphics
import Foundation

/// Inserts text into the frontmost app via clipboard + Cmd+V, restoring the previous clipboard.
public enum TextInserter {
    public static func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types ?? [] {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)
        vDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        usleep(30_000)
        vDown?.post(tap: .cghidEventTap)
        usleep(30_000)
        vUp?.post(tap: .cghidEventTap)
        usleep(30_000)
        cmdUp?.post(tap: .cghidEventTap)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            let pb = NSPasteboard.general
            guard pb.string(forType: .string) == text else { return }
            pb.clearContents()
            if previousItems.isEmpty { return }
            pb.writeObjects(previousItems)
        }
    }

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }

    public static func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
}
