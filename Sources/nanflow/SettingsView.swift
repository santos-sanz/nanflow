import NanflowCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                providerSection
                dictationSection
                snippetsSection
                styleSection
                transformsSection
                dictionarySection
                insightsSection
                meetingsSection
                permissionsSection
                historySection
                aboutSection
            }
            .padding(20)
        }
        .frame(width: 620, height: 820)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refreshHistory() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.blue.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nanflow").font(.title2.bold())
                Text("Voice dictation + meeting notes, powered by Nan")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Provider

    private var providerSection: some View {
        section("Provider & API keys") {
            Picker("Provider", selection: $store.provider) {
                ForEach(Provider.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)

            keyRow

            Picker("Speech-to-text model", selection: $store.selectedSTTModel) {
                ForEach(store.sttModels.isEmpty ? [store.selectedSTTModel] : store.sttModels, id: \.self) { m in
                    Text(m).tag(m)
                }
            }
            .pickerStyle(.menu)
            .disabled(!store.sttSelectable)
            if !store.sttSelectable {
                Text("Nan provides a single Whisper endpoint — fixed for this provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Picker("LLM model", selection: $store.selectedLLMModel) {
                    ForEach(store.llmModels.isEmpty ? [store.selectedLLMModel] : store.llmModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    store.fetchModels()
                } label: {
                    if store.modelsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .help("Refresh model list")
            }

            if let err = store.modelsError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        if let masked = store.maskedCurrentKey, !store.showKeyEditor {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(.green).font(.caption)
                Text(masked)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Text("from \(store.keySourceLabel ?? "")")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.green)
                Spacer()
                Button("Replace") { store.showKeyEditor = true }
                    .controlSize(.small)
                if store.keySourceLabel == "Keychain" {
                    Button("Remove") { store.clearKey(); store.showKeyEditor = false }
                        .controlSize(.small)
                }
            }
        } else {
            keyEditor
        }
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Paste your \(store.provider.label) API key", text: $store.keyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    store.saveKey()
                    store.showKeyEditor = false
                }
                .disabled(store.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if store.showKeyEditor {
                    Button("Cancel") {
                        store.keyDraft = ""
                        store.showKeyEditor = false
                    }
                }
            }
            Text("Stored in the macOS Keychain — never written to disk in plain text.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var dictationSection: some View {
        section("Dictation") {
            Picker("Hotkey", selection: $store.hotKey) {
                ForEach(HotKey.allCases, id: \.self) { hk in
                    Text(hk.label).tag(hk)
                }
            }
            .pickerStyle(.menu)
            Toggle("Trim leading/trailing silence (faster transcription)", isOn: $store.trimSilence)
                .toggleStyle(.switch)
            Toggle("Skip the LLM for very short dictations (≈1 s faster)", isOn: $store.fastShortUtterances)
                .toggleStyle(.switch)
            Text("Short phrases like “sí”, “gracias” or “hola” get deterministic punctuation instead of an LLM round-trip.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Language", selection: $store.language) {
                ForEach(DictationLanguage.allCases, id: \.self) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            Text("Auto lets the model detect it per utterance. Pinning a language can improve accuracy.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Microphone", selection: $store.micDeviceUID) {
                Text("System default").tag("")
                ForEach(store.micDevices) { device in
                    Text(device.isDefault ? "\(device.name) (default)" : device.name).tag(device.uidTag)
                }
            }
        }
    }

    private var snippetsSection: some View {
        section("Snippets") {
            Text("Say the trigger phrase and it is replaced by the expansion — URLs, emails, whole prompts. An exact match skips the LLM entirely.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.snippets.isEmpty {
                Text("No snippets yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($store.snippets) { $snippet in
                HStack(spacing: 8) {
                    TextField("Trigger", text: $snippet.trigger)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Expansion", text: $snippet.expansion)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        store.snippets.removeAll { $0.id == snippet.id }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete snippet")
                }
            }
            HStack {
                Button {
                    store.addSnippet()
                } label: {
                    Label("Add snippet", systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
            }
        }
    }

    private var transformsSection: some View {
        section("Transforms") {
            Text("Apply an AI transform to your last dictation from the menu bar:")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Formatter.TransformPreset.allCases, id: \.self) { preset in
                    Label(preset.label, systemImage: "wand.and.stars")
                        .font(.callout)
                }
            }
            Text("The result is copied to the clipboard, ready to paste anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var insightsSection: some View {
        section("Insights") {
            let stats = store.insights
            HStack(spacing: 24) {
                statTile(value: "\(stats.totalWords)", label: "total words")
                statTile(value: "\(stats.averageWPM)", label: "avg WPM")
                statTile(value: "\(stats.dictationCount)", label: "dictations")
                statTile(value: "\(stats.totalMinutes)", label: "minutes")
            }
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var styleSection: some View {
        section("Text style") {
            Picker("Style", selection: $store.style) {
                ForEach(TextStyle.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            Text(store.style.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.style == .off {
                Label("The transcript is pasted raw — no LLM round-trip, minimum latency.", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var dictionarySection: some View {
        section("Dictionary") {
            Text("One term per line — names, brands or words the AI must spell exactly as written.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $store.dictionaryText)
                .font(.system(size: 12))
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
        }
    }

    private var meetingsSection: some View {
        section("Meetings") {
            Toggle("Detect meetings automatically", isOn: $store.meetingsEnabled)
                .toggleStyle(.switch)
            Toggle("Record meetings automatically when detected", isOn: $store.meetingsAutoRecord)
                .toggleStyle(.switch)
                .disabled(!store.meetingsEnabled)
            Text("When a meeting ends, Nanflow transcribes the system audio + your mic and generates a summary with decisions and action items.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsSection: some View {
        section("Permissions") {
            permissionRow(
                name: "Accessibility",
                detail: "Global hotkey + pasting text",
                ok: store.accessibilityGranted,
                actionTitle: "Open Settings",
                action: { store.openAccessibilitySettings() }
            )
            permissionRow(
                name: "Microphone",
                detail: "Capturing your voice",
                ok: store.microphoneGranted,
                actionTitle: store.microphoneGranted ? "" : "Grant",
                action: { store.requestMicrophone() }
            )
            Text("System audio capture uses a Core Audio Process Tap — no screen recording permission needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(name: String, detail: String, ok: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !actionTitle.isEmpty {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }

    private var historySection: some View {
        section("Recent history") {
            if store.historyEntries.isEmpty {
                Text("Nothing yet — hold the hotkey and speak.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.historyEntries.prefix(6)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.kind == .meeting ? "person.2.fill" : "mic.fill")
                            .foregroundStyle(entry.kind == .meeting ? .blue : .secondary)
                            .font(.caption)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entryDisplay(entry))
                                .font(.system(size: 12))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(entry.app.isEmpty ? "—" : entry.app)
                                Text("·")
                                Text("\(Int(entry.transcriptionMs + entry.formattingMs)) ms")
                                if entry.kind == .dictation {
                                    Text("·")
                                    Text(entry.styleLabel)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.kind == .meeting {
                            Button {
                                MeetingDetailWindowController.shared.show(entry: entry)
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Open meeting detail")
                        }
                        Button {
                            store.copyEntry(entry)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                    .padding(.vertical, 2)
                }
                Button("Open history folder") { store.openHistoryFolder() }
                    .controlSize(.small)
            }
        }
    }

    private func entryDisplay(_ entry: HistoryEntry) -> String {
        entry.kind == .meeting ? (entry.summary ?? entry.rawText) : entry.finalText
    }

    private var aboutSection: some View {
        section("About") {
            HStack {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                Spacer()
                Button("Quit Nanflow") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

private extension HistoryEntry {
    var styleLabel: String {
        guard let raw = UserDefaults.standard.string(forKey: "nanflow.style"), let st = TextStyle(rawValue: raw) else { return "" }
        return st.label
    }
}
