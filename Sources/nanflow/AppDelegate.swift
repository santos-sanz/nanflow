import AppKit
import AVFoundation
import NanflowCore
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let bubble = BubblePanel()
    private let dictation = DictationEngine()
    private let meetings = MeetingEngine()
    private let detector = MeetingDetector()
    private let hotkey = HotKeyMonitor()
    private var meetingRecordingActive = false
    private let settings = SettingsStore.shared
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NFLog.write("app: launch · AX=\(HotKeyMonitor.hasAccessibilityPermission()) · mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        DictationBridge.engine = dictation

        settings.dictation = dictation
        settings.meetings = meetings
        settings.detector = detector
        settings.syncEngines()
        settings.onHotKeyChanged = { [weak self] hk in
            self?.startHotkey(with: hk)
        }

        ProviderSettings.shared.prewarm()
        dictation.onStateChange = { [weak self] state in
            self?.dictationStateChanged(state)
        }
        dictation.onResult = { [weak self] entry in
            self?.refreshMenu()
        }
        dictation.onError = { [weak self] message in
            self?.notify(title: "Nanflow", body: message, error: true)
        }

        meetings.onStateChange = { [weak self] state in
            self?.meetingStateChanged(state)
        }
        meetings.onError = { [weak self] message in
            self?.notify(title: "Nanflow · Reunión", body: message, error: true)
        }
        meetings.onResult = { [weak self] entry in
            self?.notify(title: "Reunión transcrita", body: "Se guardó en el historial. Resumen en camino…")
            self?.refreshMenu()
        }

        detector.onMeetingStarted = { [weak self] detected in
            self?.meetingDetected(detected)
        }
        detector.onMeetingEnded = { [weak self] in
            self?.meetingFinished()
        }

        setupStatusItem()
        startHotkey(with: settings.hotKey)
        if settings.meetingsEnabled { detector.start() }
        checkPermissionsOnLaunch()
        refreshMenu()
        settings.providerChanged()
        // Onboarding: si el proveedor activo no tiene API key, abre el panel
        if !ProviderSettings.shared.isConfigured() {
            settingsWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        detector.stop()
        if meetingRecordingActive { meetings.stopAndProcess() }
    }

    // MARK: - Settings

    // MARK: - Status bar & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Nanflow")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let config = AppConfig.load()
        if !config.isConfigured {
            let warn = NSMenuItem(title: "⚠️ Falta NAN_API_KEY en .env", action: #selector(openEnvFolder), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let dictState: String
        switch dictation.currentState {
        case .recording: dictState = "🎙️ Grabando…"
        case .transcribing, .formatting: dictState = "⚡️ Procesando…"
        case .idle: dictState = "Dictado: activo (\(settings.hotKey.label))"
        }
        let stateItem = NSMenuItem(title: dictState, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        let modelItem = NSMenuItem(title: "Motor: \(ProviderSettings.shared.provider.label) · \(ProviderSettings.shared.llmModel(for: ProviderSettings.shared.provider))", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)
        menu.addItem(.separator())

        if let current = detector.current {
            let m = NSMenuItem(title: "🔵 Reunión detectada: \(current.appName)", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
            if meetingRecordingActive {
                let stop = NSMenuItem(title: "  ⏹ Parar y resumir", action: #selector(stopMeetingRecording), keyEquivalent: "")
                stop.target = self
                menu.addItem(stop)
            }
        }

        let settingsItem = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let styleItem = NSMenuItem(title: "Estilo del texto", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for s in TextStyle.allCases {
            let item = NSMenuItem(title: s.label, action: #selector(changeStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = s == settings.style ? .on : .off
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem({
            let item = NSMenuItem(title: "Detectar reuniones", action: #selector(toggleMeetings), keyEquivalent: "")
            item.target = self
            item.state = settings.meetingsEnabled ? .on : .off
            return item
        }())
        menu.addItem({
            let item = NSMenuItem(title: "Grabar reuniones automáticamente", action: #selector(toggleAutoRecord), keyEquivalent: "")
            item.target = self
            item.state = settings.meetingsAutoRecord ? .on : .off
            return item
        }())

        let shortcutItem = NSMenuItem(title: "Atajo", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        for hk in HotKey.allCases {
            let item = NSMenuItem(title: hk.label, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hk.rawValue
            item.state = hk == settings.hotKey ? .on : .off
            shortcutMenu.addItem(item)
        }
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        menu.addItem(.separator())
        let historyTitle = NSMenuItem(title: "Historial", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        let all = HistoryStore().all().prefix(8)
        if all.isEmpty {
            let empty = NSMenuItem(title: "(vacío)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for entry in all {
                let text = entry.kind == .meeting ? "🔵 \(entry.app) · \(entry.summary?.prefix(40) ?? "procesando…")" : entry.finalText
                let label = text.count > 48 ? String(text.prefix(48)) + "…" : text
                let item = NSMenuItem(title: label, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id.uuidString
                item.toolTip = text
                historyMenu.addItem(item)
            }
            let open = NSMenuItem(title: "Abrir historial (JSON)", action: #selector(openHistory), keyEquivalent: "")
            open.target = self
            historyMenu.addItem(.separator())
            historyMenu.addItem(open)
        }
        historyTitle.submenu = historyMenu
        menu.addItem(historyTitle)

        menu.addItem(.separator())
        menu.addItem(permissionsMenuItem())
        menu.addItem({
            let item = NSMenuItem(title: "Arrancar al iniciar sesión", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            item.target = self
            item.state = Self.launchAtLoginEnabled ? .on : .off
            return item
        }())
        let quit = NSMenuItem(title: "Salir de Nanflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func permissionsMenuItem() -> NSMenuItem {
        let ax = HotKeyMonitor.hasAccessibilityPermission()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        var missing: [String] = []
        if !ax { missing.append("Accesibilidad") }
        if !mic { missing.append("Micrófono") }
        let item: NSMenuItem
        if missing.isEmpty {
            item = NSMenuItem(title: "✅ Permisos concedidos", action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else {
            item = NSMenuItem(title: "⚠️ Conceder: \(missing.joined(separator: ", "))", action: #selector(openPermissions), keyEquivalent: "")
        }
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    // MARK: - Actions

    @objc private func openSettings() { settingsWindow.show(); refreshMenu() }

    @objc private func changeStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = TextStyle(rawValue: raw) else { return }
        settings.style = st
        refreshMenu()
    }

    private static var launchAtLoginEnabled: Bool {
        (try? SMAppService.mainApp.status) == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if Self.launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify(title: "Nanflow", body: "No se pudo cambiar el arranque automático: \(error.localizedDescription)", error: true)
        }
        refreshMenu()
    }
    @objc private func toggleMeetings() {
        settings.meetingsEnabled.toggle()
        refreshMenu()
    }
    @objc private func toggleAutoRecord() { settings.meetingsAutoRecord.toggle(); refreshMenu() }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let hk = HotKey(rawValue: raw) else { return }
        settings.hotKey = hk
        refreshMenu()
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = HistoryStore().all().first(where: { $0.id.uuidString == id })
        else { return }
        let text = entry.kind == .meeting ? (entry.summary ?? entry.rawText) : entry.finalText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify(title: "Copiado", body: String(text.prefix(80)))
    }

    @objc private func openHistory() {
        NSWorkspace.shared.open(EnvLoader.appSupportDir())
    }

    @objc private func openEnvFolder() {
        NSWorkspace.shared.open(EnvLoader.appSupportDir())
    }

    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func stopMeetingRecording() {
        if meetingRecordingActive {
            meetings.stopAndProcess()
            meetingRecordingActive = false
        }
        refreshMenu()
    }

    // MARK: - Dictation flow

    private func startHotkey(with hk: HotKey) {
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            self.bubble.showRecording(near: p)
            self.statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Grabando")
            self.dictation.startDictation()
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            self.bubble.showProcessing()
            self.dictation.endDictation()
        }
        hotkey.start(hotKey: hk)
    }

    private func dictationStateChanged(_ state: DictationEngine.State) {
        switch state {
        case .idle:
            bubble.hide()
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Nanflow")
        case .recording:
            break
        case .transcribing, .formatting:
            bubble.showProcessing()
        }
        refreshMenu()
    }

    // MARK: - Meetings flow

    private func meetingDetected(_ detected: DetectedMeeting) {
        statusItem.button?.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: "Reunión")
        if settings.meetingsAutoRecord {
            meetingRecordingActive = true
            meetings.startRecording(app: detected.appName)
            notify(title: "Reunión detectada", body: "Grabando \(detected.appName). Se detendrá al terminar.")
        } else {
            notify(title: "Reunión detectada", body: "\(detected.appName) — abre el menú para grabar.")
        }
        refreshMenu()
    }

    private func meetingFinished() {
        if meetingRecordingActive {
            meetingRecordingActive = false
            meetings.stopAndProcess()
            notify(title: "Reunión finalizada", body: "Transcribiendo y generando resumen…")
        }
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Nanflow")
        refreshMenu()
    }

    private func meetingStateChanged(_ state: MeetingEngine.MeetingState) {
        switch state {
        case .recording(let app):
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Grabando reunión")
        case .processing:
            statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Procesando reunión")
        case .idle:
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Nanflow")
        }
        refreshMenu()
    }

    // MARK: - Permissions

    private func checkPermissionsOnLaunch() {
        if !HotKeyMonitor.hasAccessibilityPermission() {
            TextInserter.requestAccessibilityPermission()
            notify(title: "Nanflow necesita permisos", body: "Concede Accesibilidad en Ajustes del Sistema para usar el atajo global.", error: true)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    private func notify(title: String, body: String, error: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if error { content.sound = .default }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
