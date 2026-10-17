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
    private var lastNotice: String?
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
            DispatchQueue.main.async {
                self?.settings.refreshHistory()
                self?.refreshMenu()
            }
        }
        dictation.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.notify(title: "Nanflow", body: message, error: true)
            }
        }
        dictation.onNotice = { [weak self] message in
            NFLog.write("dict notice: \(message)")
            DispatchQueue.main.async {
                self?.lastNotice = message
                self?.refreshMenu()
            }
        }

        meetings.onStateChange = { [weak self] state in
            self?.meetingStateChanged(state)
        }
        meetings.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notify(title: "Nanflow · Reunión", body: message, error: true)
                if self.meetings.currentState == .idle { self.meetingRecordingActive = false }
                self.refreshMenu()
            }
        }
        meetings.onResult = { [weak self] entry in
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.refreshHistory()
                if entry.rawText.isEmpty && entry.summary == nil {
                    self.refreshMenu()
                    return
                }
                self.notify(title: "Reunión lista", body: "Transcripción y resumen guardados en el historial.")
                self.refreshMenu()
            }
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

        let provider = ProviderSettings.shared.provider
        if !ProviderSettings.shared.isConfigured() {
            let warn = NSMenuItem(title: "⚠️ Falta la API key de \(provider.label) — Configurar…", action: #selector(openSettings), keyEquivalent: "")
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

        let providerItem = NSMenuItem(title: "Proveedor", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for p in Provider.allCases {
            let item = NSMenuItem(title: p.label, action: #selector(changeProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            item.state = p == settings.provider ? .on : .off
            providerMenu.addItem(item)
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)
        if let last = settings.history.all().first(where: { $0.kind == .dictation }) {
            let total = last.transcriptionMs + last.formattingMs
            let stats = NSMenuItem(title: "Último dictado: \(total) ms · STT \(last.transcriptionMs) ms · IA \(last.formattingMs) ms", action: nil, keyEquivalent: "")
            stats.isEnabled = false
            menu.addItem(stats)
        }
        if let lastNotice {
            let notice = NSMenuItem(title: "Aviso: \(lastNotice)", action: nil, keyEquivalent: "")
            notice.isEnabled = false
            menu.addItem(notice)
        }
        menu.addItem(.separator())

        if meetingRecordingActive {
            let stop = NSMenuItem(title: "⏹ Detener reunión y resumir", action: #selector(stopMeetingRecording), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else if meetings.currentState == .processing {
            let processing = NSMenuItem(title: "⏳ Procesando reunión…", action: nil, keyEquivalent: "")
            processing.isEnabled = false
            menu.addItem(processing)
        } else {
            let start = NSMenuItem(title: "⏺ Grabar reunión ahora", action: #selector(startMeetingRecording), keyEquivalent: "")
            start.target = self
            start.isEnabled = dictation.currentState == .idle
            menu.addItem(start)
        }

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

        let transformItem = NSMenuItem(title: "Transformar último dictado", action: nil, keyEquivalent: "")
        let transformMenu = NSMenu()
        let hasDictations = settings.history.dictations().isEmpty == false
        for preset in Formatter.TransformPreset.allCases {
            let item = NSMenuItem(title: preset.label, action: hasDictations ? #selector(transformLastDictation(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            if !hasDictations { item.isEnabled = false }
            transformMenu.addItem(item)
        }
        transformItem.submenu = transformMenu
        menu.addItem(transformItem)

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
        let all = settings.history.all().prefix(8)
        if all.isEmpty {
            let empty = NSMenuItem(title: "(vacío)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for entry in all {
                let text = entry.kind == .meeting ? "🔵 \(entry.app) · \(entry.summary?.prefix(40) ?? "abrir…")" : entry.finalText
                let label = text.count > 48 ? String(text.prefix(48)) + "…" : text
                let item = NSMenuItem(title: label, action: entry.kind == .meeting ? #selector(openMeetingDetail(_:)) : #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id.uuidString
                item.toolTip = text
                historyMenu.addItem(item)
            }
            if settings.history.all().contains(where: { $0.kind == .dictation }) {
                let copyLast = NSMenuItem(title: "Copiar último dictado", action: #selector(copyLastDictation), keyEquivalent: "")
                copyLast.target = self
                historyMenu.addItem(.separator())
                historyMenu.addItem(copyLast)
            }
            let open = NSMenuItem(title: "Abrir historial (JSON)", action: #selector(openHistory), keyEquivalent: "")
            open.target = self
            historyMenu.addItem(.separator())
            historyMenu.addItem(open)
        }
        historyTitle.submenu = historyMenu
        menu.addItem(historyTitle)

        menu.addItem(.separator())
        let scratchpadItem = NSMenuItem(title: "Abrir Scratchpad", action: #selector(openScratchpad), keyEquivalent: "")
        scratchpadItem.target = self
        menu.addItem(scratchpadItem)
        if hasDictations {
            let append = NSMenuItem(title: "Añadir último dictado al Scratchpad", action: #selector(appendLastDictationToScratchpad), keyEquivalent: "")
            append.target = self
            menu.addItem(append)
        }

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

    @objc private func changeProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Provider(rawValue: raw) else { return }
        settings.provider = p
        refreshMenu()
    }

    private static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
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
              let entry = settings.history.all().first(where: { $0.id.uuidString == id })
        else { return }
        let text = entry.kind == .meeting ? (entry.summary ?? entry.rawText) : entry.finalText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify(title: "Copiado", body: String(text.prefix(80)))
    }

    @objc private func copyLastDictation() {
        guard let entry = settings.history.all().first(where: { $0.kind == .dictation }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.finalText, forType: .string)
        notify(title: "Copiado", body: String(entry.finalText.prefix(80)))
    }

    @objc private func transformLastDictation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = Formatter.TransformPreset(rawValue: raw),
              let entry = settings.history.all().first(where: { $0.kind == .dictation })
        else { return }
        let source = entry.finalText
        notify(title: "Transformando…", body: preset.label)
        Task.detached {
            do {
                let result = try await Formatter.transform(source, preset: preset)
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw NanError.invalidResponse }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
                Self.pushNotification(title: preset.label, body: String(trimmed.prefix(120)))
            } catch {
                Self.pushNotification(title: "Transform falló", body: error.localizedDescription, error: true)
            }
        }
    }

    @MainActor
    @objc private func openScratchpad() {
        ScratchpadWindowController.shared.show()
    }

    @objc private func appendLastDictationToScratchpad() {
        guard let entry = settings.history.all().first(where: { $0.kind == .dictation }) else { return }
        ScratchpadStore.shared.append(entry.finalText)
        notify(title: "Scratchpad", body: "Último dictado añadido.")
    }

    @objc private func openHistory() {
        NSWorkspace.shared.open(EnvLoader.appSupportDir())
    }

    @MainActor
    @objc private func openMeetingDetail(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = settings.history.all().first(where: { $0.id.uuidString == id }) else { return }
        MeetingDetailWindowController.shared.show(entry: entry)
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

    @objc private func startMeetingRecording() {
        guard !meetingRecordingActive, meetings.currentState == .idle else { return }
        let app = detector.current?.appName ?? "Reunión manual"
        meetings.startRecording(app: app)
        meetingRecordingActive = meetings.currentState != .idle
        if meetingRecordingActive {
            notify(title: "Grabando reunión", body: "Usa Detener reunión y resumir al terminar.")
        } else {
            notify(title: "No se pudo iniciar la reunión", body: "El motor está ocupado; inténtalo de nuevo.", error: true)
        }
        refreshMenu()
    }

    // MARK: - Dictation flow

    private func startHotkey(with hk: HotKey) {
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            guard self.dictation.currentState == .idle else { return }
            self.lastNotice = nil
            Task.detached { ProviderSettings.shared.prewarmIfNeeded() }
            let p = NSEvent.mouseLocation
            self.bubble.showRecording(near: p)
            self.statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Grabando")
            if !self.dictation.startDictation() {
                self.bubble.hide()
                self.statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Nanflow")
            }
        }
        hotkey.onRelease = { [weak self] in
            guard let self, self.dictation.currentState == .recording else { return }
            self.bubble.showProcessing()
            self.dictation.endDictation()
        }
        hotkey.onCancel = { [weak self] in
            guard let self, self.dictation.isBusy else { return false }
            self.dictation.cancelDictation()
            return true
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
        if settings.meetingsAutoRecord, meetings.currentState == .idle {
            meetings.startRecording(app: detected.appName)
            meetingRecordingActive = meetings.currentState != .idle
            if meetingRecordingActive {
                notify(title: "Reunión detectada", body: "Grabando \(detected.appName). Se detendrá al terminar.")
            }
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
        case .recording:
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Grabando reunión")
        case .processing:
            statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Procesando reunión")
        case .idle:
            meetingRecordingActive = false
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
        Self.pushNotification(title: title, body: body, error: error)
    }

    static func pushNotification(title: String, body: String, error: Bool = false) {
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
