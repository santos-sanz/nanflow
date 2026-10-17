import AppKit
import Foundation

/// Orchestrates the hold-to-talk dictation flow:
/// hotkey press -> mic recording -> (release) -> Nan whisper -> LLM format -> paste at cursor.
public final class DictationEngine: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case formatting
    }

    public var onStateChange: (@Sendable (State) -> Void)?
    public var onResult: (@Sendable (HistoryEntry) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    public var style: TextStyle = .natural
    public var trimSilenceEnabled = true

    private let mic = MicRecorder()
    private let history: HistoryStore
    private var state: State = .idle
    private let lock = NSLock()
    private let minDuration: TimeInterval = 0.35

    public init(history: HistoryStore = HistoryStore()) {
        self.history = history
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public var level: Float { mic.level }

    private func setState(_ new: State) {
        lock.lock(); state = new; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(new) }
    }

    /// Transitions state only if current matches `expected`. Returns false otherwise.
    @discardableResult
    private func transition(from expected: State, to new: State) -> Bool {
        lock.lock()
        guard state == expected else { lock.unlock(); return false }
        state = new
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(new) }
        return true
    }

    public func startDictation() {
        NFLog.write("dict: startRecording")
        guard transition(from: .idle, to: .recording) else { return }

        do {
            try mic.start()
        } catch {
            setState(.idle)
            onError?("No se pudo acceder al micrófono: \(error.localizedDescription)")
        }
    }

    public func endDictation() {
        NFLog.write("dict: release -> transcribing")
        guard transition(from: .recording, to: .transcribing) else { return }

        let recording = mic.stop()
        let startedAt = mic.startedAt

        Task.detached { [weak self] in
            guard let self else { return }
            guard let recording else {
                self.setState(.idle)
                return
            }
            let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            NFLog.write("dict: captured \(recording.samples.count) samples, \(duration)s")
            if recording.samples.isEmpty || duration < self.minDuration {
                self.setState(.idle)
                return
            }

            let trimmed = trimSilenceEnabled
                ? AudioMixer.trimSilence(samples: recording.samples, sampleRate: recording.sampleRate)
                : recording.samples
            NFLog.write("dict: trimmed \(recording.samples.count) -> \(trimmed.count) samples")
            do {
                let t0 = Date()
                let transcript = try await ProviderSettings.shared.client().transcribe(samples: trimmed, sampleRate: recording.sampleRate)
                let t1 = Date()

                let formattedText: String
                if self.style != .off, !transcript.text.isEmpty {
                    self.setState(.formatting)
                    formattedText = try await Formatter.formatDictation(transcript.text, style: self.style)
                } else {
                    formattedText = transcript.text
                }
                let t2 = Date()

                let frontApp = Self.frontmostAppName()
                let entry = HistoryEntry(
                    timestamp: startedAt ?? Date(),
                    kind: .dictation,
                    app: frontApp,
                    audioDuration: duration,
                    transcriptionMs: Int(t1.timeIntervalSince(t0) * 1000),
                    formattingMs: Int(t2.timeIntervalSince(t1) * 1000),
                    rawText: transcript.text,
                    finalText: formattedText
                )
                self.history.add(entry)
                let cfg = ProviderSettings.shared.effectiveConfig()
                NFLog.write("dict: entry saved [\(cfg.provider.label)/\(cfg.whisperModel)+\(cfg.model)] raw=\(transcript.text.prefix(60)) final=\(formattedText.prefix(60))")

                if !formattedText.isEmpty {
                    try await MainActor.run {
                        try TextInserter.insert(formattedText)
                    }
                }
                self.setState(.idle)
                self.onResult?(entry)
            } catch {
                NFLog.write("dict: ERROR \(error)")
                self.setState(.idle)
                self.onError?("\(error.localizedDescription)")
            }
        }
    }

    public func cancelDictation() {
        if currentState == .recording {
            _ = mic.stop()
            setState(.idle)
        }
    }

    static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }
}
