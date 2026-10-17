import AppKit
import NanflowCore
import SwiftUI

/// Hosts the SwiftUI control panel in a non-activating-ish normal window.
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Nanflow"
            w.contentView = NSHostingView(rootView: SettingsView(store: .shared))
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
