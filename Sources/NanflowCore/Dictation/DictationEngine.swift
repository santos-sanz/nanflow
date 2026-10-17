import AppKit
import Foundation

public enum DictationLanguage: String, CaseIterable, Sendable {
    case auto
    case spanish = "es"
    case english = "en"

    public var label: String {
        switch self {
        case .auto: return "Automático"
        case .spanish: return "Español"
        case .english: return "English"
        }
    }

    /// nil lets whisper auto-detect the language.
    public var whisperCode: String? {
        switch self {
        case .auto: return nil
        case .spanish: return "es"
        case .english: return "en"
        }
    }
}

public protocol DictationService: Sendable {
    func transcribe(samples: [Float], sampleRate: Double, language: DictationLanguage) async throws -> TranscriptionOutput
    func format(_ raw: String, style: TextStyle, dictionary: [String]) async throws -> String
}

public struct LiveDictationService: DictationService {
    public init() {}

    public func transcribe(samples: [Float], sampleRate: Double, language: DictationLanguage) async throws -> TranscriptionOutput {
        try await ProviderSettings.shared.client().transcribe(
            samples: samples,
            sampleRate: sampleRate,
            language: language.whisperCode,
            prompt: SnippetsStore.shared.promptHints()
        )
    }

    public func format(_ raw: String, style: TextStyle, dictionary: [String]) async throws -> String {
        try await Formatter.formatDictation(raw, style: style, dictionary: dictionary)
    }
}

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
    public var onNotice: (@Sendable (String) -> Void)?

    public var style: TextStyle = .natural
    public var trimSilenceEnabled = true
    public var dictionary: [String] = []
    public var fastShortUtterances = true
    public var language: DictationLanguage = .auto
    public var snippets: SnippetsStore = .shared
    public var preferredMicUID: String?

    private let mic = MicRecorder()
    private let history: HistoryStore
    private let service: DictationService
    private var state: State = .idle
    private let lock = NSLock()
    private let minDuration: TimeInterval = 0.35
    private var generation = 0
    private var workTask: Task<Void, Never>?
    private var frontAppAtStart = ""

    public init(history: HistoryStore = .shared, service: DictationService = LiveDictationService()) {
        self.history = history
        self.service = service
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public var isBusy: Bool { currentState != .idle }

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

    @discardableResult
    public func startDictation() -> Bool {
        guard transition(from: .idle, to: .recording) else {
            NFLog.write("dict: ignored start (state=\(currentState))")
            return false
        }
        lock.lock()
        generation += 1
        lock.unlock()

        frontAppAtStart = Self.frontmostAppName()
        mic.preferredDeviceUID = preferredMicUID
        NFLog.write("dict: startRecording lang=\(language.rawValue)")
        do {
            try mic.start()
            return true
        } catch {
            setState(.idle)
            onError?("No se pudo acceder al micrófono: \(error.localizedDescription)")
            return false
        }
    }

    public func endDictation() {
        NFLog.write("dict: release -> transcribing")
        guard transition(from: .recording, to: .transcribing) else { return }

        let recording = mic.stop()
        let startedAt = mic.startedAt
        let app = frontAppAtStart
        lock.lock()
        let gen = generation
        lock.unlock()

        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.process(recording: recording, startedAt: startedAt, app: app, generation: gen)
        }
        lock.lock()
        if generation == gen { workTask = task }
        lock.unlock()
    }

    private func process(recording: (samples: [Float], sampleRate: Double, duration: TimeInterval)?, startedAt: Date?, app: String, generation gen: Int) async {
        guard isCurrent(gen) else { return }
        guard let recording else {
            finishIfCurrent(gen)
            return
        }

        let audioDuration = Double(recording.samples.count) / recording.sampleRate
        let wallDuration = startedAt.map { Date().timeIntervalSince($0) } ?? audioDuration
        NFLog.write("dict: captured \(recording.samples.count) samples, \(audioDuration)s")

        guard !recording.samples.isEmpty, wallDuration >= minDuration else {
            finishIfCurrent(gen)
            onNotice?("Dictado demasiado corto")
            return
        }

        let trimmed = trimSilenceEnabled
            ? AudioMixer.trimSilence(samples: recording.samples, sampleRate: recording.sampleRate)
            : recording.samples
        NFLog.write("dict: trimmed \(recording.samples.count) -> \(trimmed.count) samples")

        guard AudioMixer.hasSpeech(samples: trimmed, sampleRate: recording.sampleRate) else {
            finishIfCurrent(gen)
            NFLog.write("dict: no speech detected, skipped upload")
            onNotice?("No se detectó voz")
            return
        }

        do {
            let t0 = Date()
            let transcript = try await service.transcribe(samples: trimmed, sampleRate: recording.sampleRate, language: language)
            guard isCurrent(gen) else { return }
            let t1 = Date()
            guard !transcript.text.isEmpty else {
                finishIfCurrent(gen)
                onNotice?("No se detectó voz")
                return
            }

            if let exact = snippets.exactMatch(transcript.text) {
                NFLog.write("dict: snippet exact match, skipped LLM")
                return await finish(
                    gen: gen,
                    startedAt: startedAt,
                    app: app,
                    audioDuration: audioDuration,
                    raw: transcript.text,
                    final: exact,
                    t0: t0,
                    t1: t1
                )
            }

            let shouldFormat = style != .off && !(fastShortUtterances && Formatter.shouldSkipLLM(transcript.text, style: style, dictionary: dictionary))
            if shouldFormat {
                guard transitionIfCurrent(gen, from: .transcribing, to: .formatting) else { return }
            }
            let result = await Formatter.formatForDictation(transcript.text, style: style, dictionary: dictionary, fastShort: fastShortUtterances) { raw, textStyle, dict in
                guard self.isCurrent(gen) else { throw CancellationError() }
                return try await self.service.format(raw, style: textStyle, dictionary: dict)
            }
            guard isCurrent(gen), !Task.isCancelled else { return }
            if result.usedFallback {
                NFLog.write("dict: format failed, pasting raw transcript")
                onNotice?("No se pudo pulir el texto; se pegó la transcripción.")
            }
            let formattedText = snippets.apply(result.text)
            return await finish(
                gen: gen,
                startedAt: startedAt,
                app: app,
                audioDuration: audioDuration,
                raw: transcript.text,
                final: formattedText,
                t0: t0,
                t1: t1
            )
        } catch {
            guard isCurrent(gen), !Task.isCancelled else { return }
            NFLog.write("dict: ERROR \(error)")
            finishIfCurrent(gen)
            onError?("\(error.localizedDescription)")
        }
    }

    /// Saves the entry, pastes at the cursor and reports the result.
    private func finish(gen: Int, startedAt: Date?, app: String, audioDuration: TimeInterval, raw: String, final: String, t0: Date, t1: Date) async {
        let t2 = Date()
        let entry = HistoryEntry(
            timestamp: startedAt ?? Date(),
            kind: .dictation,
            app: app,
            audioDuration: audioDuration,
            transcriptionMs: Int(t1.timeIntervalSince(t0) * 1000),
            formattingMs: Int(t2.timeIntervalSince(t1) * 1000),
            rawText: raw,
            finalText: final
        )

        var insertError: Error?
        if !final.isEmpty {
            do {
                try await MainActor.run {
                    try TextInserter.insert(final)
                }
            } catch {
                insertError = error
            }
        }
        guard isCurrent(gen) else { return }

        history.add(entry)
        let cfg = ProviderSettings.shared.effectiveConfig()
        NFLog.write("dict: entry saved [\(cfg.provider.label)/\(cfg.whisperModel)+\(cfg.model)] raw=\(raw.prefix(60)) final=\(final.prefix(60))")
        finishIfCurrent(gen)

        if let insertError {
            onError?("No se pudo pegar el texto: \(insertError.localizedDescription)")
        } else {
            onResult?(entry)
        }
    }

    public func cancelDictation() {
        lock.lock()
        let wasBusy = state != .idle
        let wasRecording = state == .recording
        generation += 1
        let task = workTask
        workTask = nil
        state = .idle
        lock.unlock()

        task?.cancel()
        if wasRecording { _ = mic.stop() }
        guard wasBusy else { return }
        NFLog.write("dict: cancelled")
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.idle)
            self?.onNotice?("Dictado cancelado")
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }

    @discardableResult
    private func transitionIfCurrent(_ gen: Int, from expected: State, to new: State) -> Bool {
        lock.lock()
        guard generation == gen, state == expected else { lock.unlock(); return false }
        state = new
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(new) }
        return true
    }

    private func finishIfCurrent(_ gen: Int, notice: String? = nil) {
        lock.lock()
        guard generation == gen else { lock.unlock(); return }
        workTask = nil
        guard state != .idle else { lock.unlock(); return }
        state = .idle
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.idle)
            if let notice { self?.onNotice?(notice) }
        }
    }

    static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }
}
