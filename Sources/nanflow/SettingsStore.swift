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

    // MARK: Provider state

    @Published var provider: Provider {
        didSet {
            ProviderSettings.shared.provider = provider
            providerChanged()
        }
    }
    @Published var selectedLLMModel: String = "" {
        didSet { guard !didSetGuard else { return }; ProviderSettings.shared.setLLMModel(selectedLLMModel, for: provider) }
    }
    @Published var selectedSTTModel: String = "" {
        didSet { guard !didSetGuard else { return }; ProviderSettings.shared.setSTTModel(selectedSTTModel, for: provider) }
    }
    @Published var llmModels: [String] = []
    @Published var sttModels: [String] = []
    @Published var modelsLoading = false
    @Published var modelsError: String?
    @Published var keyDraft: String = ""
    @Published var showKeyEditor = false
    @Published var keyRevision = 0

    private var didSetGuard = false

    var currentKey: String? {
        keyRevision; return ProviderSettings.shared.apiKey(for: provider)
    }

    var keySourceLabel: String? {
        keyRevision; return ProviderSettings.shared.keySource(for: provider)
    }

    var providerConfigured: Bool {
        keyRevision; return ProviderSettings.shared.isConfigured(for: provider)
    }

    var sttSelectable: Bool { provider.sttModelSelectable }

    var maskedCurrentKey: String? {
        currentKey.map(KeychainStore.masked)
    }

    private init() {
        hotKey = HotKey(rawValue: defaults.string(forKey: Keys.hotkey) ?? "") ?? .rightCommand
        style = TextStyle(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .natural
        meetingsEnabled = defaults.object(forKey: Keys.meetingsEnabled) as? Bool ?? true
        meetingsAutoRecord = defaults.object(forKey: Keys.meetingsAutoRecord) as? Bool ?? true
        trimSilence = defaults.object(forKey: Keys.trimSilence) as? Bool ?? true
        provider = ProviderSettings.shared.provider
    }

    func providerChanged() {
        didSetGuard = true
        defer { didSetGuard = false }
        selectedLLMModel = ProviderSettings.shared.llmModel(for: provider)
        selectedSTTModel = ProviderSettings.shared.sttModel(for: provider)
        keyDraft = ""
        showKeyEditor = false
        fetchModels()
    }

    func fetchModels() {
        modelsLoading = true
        modelsError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await ProviderSettings.shared.client().listModels()
                await MainActor.run {
                    self.llmModels = catalog.llmModels
                    self.sttModels = catalog.sttModels
                    self.modelsLoading = false
                    self.didSetGuard = true
                    if !catalog.llmModels.contains(self.selectedLLMModel) { self.selectedLLMModel = catalog.llmModels.first ?? self.selectedLLMModel }
                    if !catalog.sttModels.contains(self.selectedSTTModel) { self.selectedSTTModel = catalog.sttModels.first ?? self.selectedSTTModel }
                    self.didSetGuard = false
                }
            } catch {
                await MainActor.run {
                    self.modelsLoading = false
                    self.modelsError = "No se pudo cargar el catálogo: \(error.localizedDescription)"
                    self.sttModels = self.provider.sttModelSelectable ? Provider.openRouterSTTModels : [ProviderSettings.shared.sttModel(for: self.provider)]
                    if self.llmModels.isEmpty { self.llmModels = [self.selectedLLMModel] }
                }
            }
        }
    }

    func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespaces)
        ProviderSettings.shared.setKeychainKey(trimmed.isEmpty ? nil : trimmed, for: provider)
        keyDraft = ""
        showKeyEditor = false
        keyRevision &+= 1
        objectWillChange.send()
        fetchModels()
    }

    func clearKey() {
        ProviderSettings.shared.setKeychainKey(nil, for: provider)
        keyRevision &+= 1
        objectWillChange.send()
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
        if launchAtLogin {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        objectWillChange.send()
    }

    var launchAtLogin: Bool {
        (try? SMAppService.mainApp.status) == .enabled
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
