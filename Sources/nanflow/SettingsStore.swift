import AVFoundation
import AppKit
import Combine
import NanflowCore
import ServiceManagement

/// Observable settings facade shared between the SwiftUI frontend and the engines.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let hotkey = "nanflow.hotkey"
        static let style = "nanflow.style"
        static let meetingsEnabled = "nanflow.meetings"
        static let meetingsAutoRecord = "nanflow.meetings.autorecord"
        static let trimSilence = "nanflow.trim"
    }

    weak var dictation: DictationEngine?
    weak var meetings: MeetingEngine?
    weak var detector: MeetingDetector?
    var history = HistoryStore()
    var onHotKeyChanged: ((HotKey) -> Void)?

    @Published var hotKey: HotKey {
        didSet { defaults.set(hotKey.rawValue, forKey: Keys.hotkey); onHotKeyChanged?(hotKey) }
    }
    @Published var style: TextStyle {
        didSet {
            defaults.set(style.rawValue, forKey: Keys.style)
            dictation?.style = style
        }
    }
    @Published var meetingsEnabled: Bool {
        didSet {
            defaults.set(meetingsEnabled, forKey: Keys.meetingsEnabled)
            meetingsEnabled ? detector?.start() : detector?.stop()
        }
    }
    @Published var meetingsAutoRecord: Bool {
        didSet { defaults.set(meetingsAutoRecord, forKey: Keys.meetingsAutoRecord) }
    }
    @Published var trimSilence: Bool {
        didSet {
            defaults.set(trimSilence, forKey: Keys.trimSilence)
            dictation?.trimSilenceEnabled = trimSilence
        }
    }
    @Published var historyEntries: [HistoryEntry] = []

    var launchAtLogin: Bool {
        (try? SMAppService.mainApp.status) == .enabled
    }

    private init() {
        hotKey = HotKey(rawValue: defaults.string(forKey: Keys.hotkey) ?? "") ?? .rightCommand
        style = TextStyle(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .natural
        meetingsEnabled = defaults.object(forKey: Keys.meetingsEnabled) as? Bool ?? true
        meetingsAutoRecord = defaults.object(forKey: Keys.meetingsAutoRecord) as? Bool ?? true
        trimSilence = defaults.object(forKey: Keys.trimSilence) as? Bool ?? true
    }

    func syncEngines() {
        dictation?.style = style
        dictation?.trimSilenceEnabled = trimSilence
    }

    func refreshHistory() {
        historyEntries = history.all()
    }

    func copyEntry(_ entry: HistoryEntry) {
        let text = entry.kind == .meeting ? (entry.summary ?? entry.rawText) : entry.finalText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openHistoryFolder() {
        NSWorkspace.shared.open(EnvLoader.appSupportDir())
    }

    func toggleLaunchAtLogin() {
        try? SMAppService.mainApp.unregister()
        if !launchAtLogin {
            try? SMAppService.mainApp.register()
        }
        objectWillChange.send()
    }

    // MARK: - Permissions

    var accessibilityGranted: Bool { HotKeyMonitor.hasAccessibilityPermission() }
    var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
