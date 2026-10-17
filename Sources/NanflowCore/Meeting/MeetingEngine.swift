import Foundation

/// Records a full meeting: system audio (Core Audio Process Tap) + microphone, mixed into one WAV.
/// On stop: transcribes via Nan whisper and generates an LLM summary.
public final class MeetingEngine: @unchecked Sendable {
    public enum MeetingState: Equatable, Sendable {
        case idle
        case recording(app: String)
        case processing
    }

    public var onStateChange: (@Sendable (MeetingState) -> Void)?
    public var onResult: (@Sendable (HistoryEntry) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private let mic = MicRecorder()
    private let systemAudio = SystemAudioRecorder()
    private let history: HistoryStore
    private let lock = NSLock()
    private var state: MeetingState = .idle
    private var micStartedAt: Date?
    private var sysStartedAt: Date?
    private var currentApp: String = ""

    public var saveAudio = true

    public init(history: HistoryStore = .shared) {
        self.history = history
    }

    public var currentState: MeetingState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    private func setState(_ s: MeetingState) {
        lock.lock(); state = s; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
    }

    @discardableResult
    private func transition(from expected: MeetingState, to new: MeetingState) -> Bool {
        lock.lock()
        guard state == expected else { lock.unlock(); return false }
        state = new
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(new) }
        return true
    }

    public func startRecording(app: String) {
        NFLog.write("meeting: startRecording app=\(app)")
        guard transition(from: .idle, to: .recording(app: app)) else { return }
        currentApp = app

        micStartedAt = Date()
        do {
            try mic.start()
        } catch {
            micStartedAt = nil
            onError?("Mic no disponible: \(error.localizedDescription)")
        }
        sysStartedAt = Date()
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try self.systemAudio.start()
            } catch {
                self.sysStartedAt = nil
                self.onError?("Audio del sistema no disponible: \(error.localizedDescription) (solo micrófono)")
            }
        }
    }

    public func stopAndProcess() {
        NFLog.write("meeting: stop -> process")
        lock.lock()
        guard case .recording = state else {
            lock.unlock()
            return
        }
        state = .processing
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(.processing) }
        let micData = mic.stop()
        let micStart = micStartedAt
        micStartedAt = nil
        let sysStart = sysStartedAt
        sysStartedAt = nil

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                var micSamples: [Float] = []
                if let micData { micSamples = micData.samples }

                var sysSamples: [Float] = []
                var offset: Double = 0
                if let sysData = self.systemAudio.stop() {
                    sysSamples = AudioMixer.resample(samples: sysData.samples, fromRate: sysData.sampleRate, toRate: 16_000)
                    if let micStart, let sysStart {
                        offset = max(0, sysStart.timeIntervalSince(micStart))
                    }
                }

                let base = micSamples.isEmpty ? sysSamples : micSamples
                let mixed: [Float]
                if micSamples.isEmpty && sysSamples.isEmpty {
                    self.setState(.idle)
                    self.onError?("La reunión no tenía audio capturable")
                    return
                } else if sysSamples.isEmpty {
                    mixed = base
                } else if micSamples.isEmpty {
                    mixed = sysSamples
                } else {
                    mixed = AudioMixer.mix(trackA: micSamples, trackB: sysSamples, offsetSeconds: offset)
                }

                let startedAt = micStart ?? sysStart ?? Date()
                let duration = Double(mixed.count) / 16_000

                let meetingDir = EnvLoader.appSupportDir().appendingPathComponent("meetings", isDirectory: true)
                try? FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
                let stamp = Self.filenameStamp(from: startedAt)
                let wavURL = meetingDir.appendingPathComponent("reunion-\(stamp).wav")
                try WavWriter.write(samples: mixed, sampleRate: 16_000, to: wavURL)

                let entry = HistoryEntry(
                    timestamp: startedAt,
                    kind: .meeting,
                    app: self.currentApp,
                    audioDuration: duration,
                    rawText: "",
                    finalText: "",
                    audioPath: self.saveAudio ? wavURL.path : nil
                )
                NFLog.write("meeting: audio saved \(duration)s -> \(wavURL.lastPathComponent)")
                self.history.add(entry)
                await self.processTranscription(entry: entry, wavURL: wavURL)
            } catch {
                self.setState(.idle)
                self.onError?("Error procesando la reunión: \(error.localizedDescription)")
            }
        }
    }

    private func processTranscription(entry: HistoryEntry, wavURL: URL) async {
        do {
            let client = ProviderSettings.shared.client()
            let transcript = try await client.transcribe(audioURL: wavURL)
            NFLog.write("meeting: transcript \(transcript.text.prefix(80))")
            var updated = entry
            updated.rawText = transcript.text

            if transcript.text.isEmpty {
                updated.summary = nil
                history.update(updated)
                setState(.idle)
                onResult?(updated)
                onError?("La reunión no tenía habla detectable (sin transcripción)")
                return
            }

            let summary = (try? await Formatter.summarizeMeeting(transcript.text)) ?? ""
            updated.summary = summary.isEmpty ? nil : summary
            NFLog.write("meeting: summary \(summary.prefix(80))")
            history.update(updated)
            setState(.idle)
            onResult?(updated)
        } catch {
            setState(.idle)
            onError?("Transcripción de reunión falló: \(error.localizedDescription)")
        }
    }

    static func filenameStamp(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }
}
