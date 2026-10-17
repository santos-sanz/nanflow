import XCTest
@testable import NanflowCore

final class EnvLoaderTests: XCTestCase {
    func testParseEnvFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-env-\(UUID()).env")
        try """
        # comentario
        NAN_API_KEY="sk-test-123"
        NAN_BASE_URL=https://api.example.com/v1
        NAN_MODEL= test-model
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let parsed = EnvLoader.parse(tmp.path) ?? [:]
        XCTAssertEqual(parsed["NAN_API_KEY"], "sk-test-123")
        XCTAssertEqual(parsed["NAN_BASE_URL"], "https://api.example.com/v1")
        XCTAssertEqual(parsed["NAN_MODEL"], "test-model")
        try? FileManager.default.removeItem(at: tmp)
    }

    func testParseEmptyAndMalformedLines() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-env-\(UUID()).env")
        try? "sin_igual\n\nNAN_API_KEY=abc\n".write(to: tmp, atomically: true, encoding: .utf8)
        let parsed = EnvLoader.parse(tmp.path) ?? [:]
        XCTAssertEqual(parsed["NAN_API_KEY"], "abc")
        XCTAssertNil(parsed["sin_igual"])
        try? FileManager.default.removeItem(at: tmp)
    }

    func testAppConfigDefaults() {
        let cfg = AppConfig()
        XCTAssertFalse(cfg.isConfigured)
        XCTAssertEqual(cfg.whisperModel, "whisper")
    }
}

final class HistoryStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-hist-\(UUID()).json")
        let store = HistoryStore(fileURL: file)

        let entry = HistoryEntry(
            kind: .dictation,
            app: "Xcode",
            audioDuration: 3.2,
            transcriptionMs: 800,
            formattingMs: 1200,
            rawText: "hola mundo",
            finalText: "Hola, mundo."
        )
        store.add(entry)

        let reloaded = HistoryStore(fileURL: file)
        XCTAssertEqual(reloaded.all().count, 1)
        XCTAssertEqual(reloaded.all().first?.finalText, "Hola, mundo.")
        XCTAssertEqual(reloaded.all().first?.app, "Xcode")
        try? FileManager.default.removeItem(at: file)
    }

    func testUpdateAndFilters() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-hist-\(UUID()).json")
        let store = HistoryStore(fileURL: file)

        var meeting = HistoryEntry(kind: .meeting, app: "Zoom", rawText: "contenido")
        store.add(HistoryEntry(kind: .dictation, app: "Notes"))
        store.add(meeting)

        meeting.summary = "## Resumen"
        store.update(meeting)

        XCTAssertEqual(store.dictations().count, 1)
        XCTAssertEqual(store.meetings().count, 1)
        XCTAssertEqual(store.meetings().first?.summary, "## Resumen")
        XCTAssertEqual(store.all().count, 2)
        try? FileManager.default.removeItem(at: file)
    }
}

final class NanClientTests: XCTestCase {
    func testLooksSpanish() {
        XCTAssertTrue(NanClient.looksSpanish("Hola, ¿qué tal? Esto funciona con ñandú."))
        XCTAssertTrue(NanClient.looksSpanish("el perro de la que se enoja"))
        XCTAssertFalse(NanClient.looksSpanish("Hello world this is a test"))
        XCTAssertFalse(NanClient.looksSpanish(""))
    }
}

final class AudioMixerTests: XCTestCase {
    func testResampleChangesLength() {
        let samples = [Float](repeating: 0.5, count: 4800) // 0.1s @48k
        let out = AudioMixer.resample(samples: samples, fromRate: 48_000, toRate: 16_000)
        XCTAssertEqual(out.count, 1600, accuracy: 30)
    }

    func testResampleSameRateIsPassthrough() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        let out = AudioMixer.resample(samples: samples, fromRate: 16_000, toRate: 16_000)
        XCTAssertEqual(out, samples)
    }

    func testMixOffsetsTrackB() {
        let a = [Float](repeating: 0.4, count: 100)
        let b = [Float](repeating: 0.4, count: 100)
        let mixed = AudioMixer.mix(trackA: a, trackB: b, offsetSeconds: 0.25, rate: 100)
        // b empieza a los 0.25s (25 samples): 0-24 solo a, 25-99 a+b, 100-124 solo b
        XCTAssertEqual(mixed.count, 125)
        XCTAssertEqual(mixed[10], 0.4, accuracy: 0.001)
        XCTAssertEqual(mixed[75], 0.8, accuracy: 0.001)
        XCTAssertEqual(mixed[110], 0.4, accuracy: 0.001)
    }

    func testMixNormalizesWhenClipping() {
        let a = [Float](repeating: 0.9, count: 10)
        let b = [Float](repeating: 0.9, count: 10)
        let mixed = AudioMixer.mix(trackA: a, trackB: b, offsetSeconds: 0)
        XCTAssertTrue(mixed.allSatisfy { $0 <= 1.0 })
    }

    func testMixEmpty() {
        XCTAssertTrue(AudioMixer.mix(trackA: [], trackB: [], offsetSeconds: 0).isEmpty)
    }
}

final class WavWriterTests: XCTestCase {
    func testWriteProducesFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-wav-\(UUID()).wav")
        let samples: [Float] = (0..<1600).map { sinf(Float($0) * 0.05) * 0.3 }
        try WavWriter.write(samples: samples, sampleRate: 16_000, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 3000)
        let header = String(data: data.prefix(4), encoding: .ascii)
        XCTAssertEqual(header, "RIFF")
        try? FileManager.default.removeItem(at: url)
    }

    func testWriteEmptyDoesNotCrash() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-wav-\(UUID()).wav")
        try WavWriter.write(samples: [], sampleRate: 16_000, to: url)
        try? FileManager.default.removeItem(at: url)
    }
}

final class MeetingDetectorTests: XCTestCase {
    func testKnownAppsCoverBasics() {
        let names = MeetingApp.known.map(\.name)
        XCTAssertTrue(names.contains("Zoom"))
        XCTAssertTrue(names.contains("Microsoft Teams"))
        XCTAssertTrue(names.contains("FaceTime"))
        XCTAssertTrue(names.contains("Webex"))
    }

    func testNoMeetingWhenNoAppsRunning() {
        // En el entorno de test no hay reunión real corriendo (FaceTime no lanzado)
        // Solo verificamos que la llamada no crashea.
        _ = MeetingDetector.currentlyInMeeting()
    }
}

final class FormatterTests: XCTestCase {
    func testStylePrompts() {
        XCTAssertTrue(Formatter.systemPrompt(for: .natural).contains("SAME LANGUAGE"))
        XCTAssertTrue(Formatter.systemPrompt(for: .informal).contains("CASUAL"))
        XCTAssertTrue(Formatter.systemPrompt(for: .formal).contains("PROFESSIONAL"))
        // .off comparte el prompt natural pero el motor no debe llamar al LLM
        XCTAssertTrue(Formatter.systemPrompt(for: .off).contains("SAME LANGUAGE"))
        XCTAssertTrue(Formatter.meetingSummarySystemPrompt.contains("markdown"))
    }

    func testStyleCases() {
        XCTAssertEqual(TextStyle.allCases.count, 4)
        XCTAssertTrue(TextStyle.off.label.contains("sin IA"))
    }
}

final class WavEncoderTests: XCTestCase {
    func testProducesValidWavHeader() {
        let data = WavEncoder.encode(samples: [0.0, 0.5, -0.5], sampleRate: 16_000)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + 3 * 2)
    }

    func testClipping() {
        let data = WavEncoder.encode(samples: [2.0, -2.0], sampleRate: 16_000)
        let pcm = data.subdata(in: 44..<48)
        let v0 = Int16(littleEndian: pcm.prefix(2).withUnsafeBytes { $0.load(as: Int16.self) })
        let v1 = Int16(littleEndian: pcm.suffix(2).withUnsafeBytes { $0.load(as: Int16.self) })
        XCTAssertEqual(v0, 32767)
        XCTAssertEqual(v1, -32767)
    }
}

final class TrimSilenceTests: XCTestCase {
    func testTrimsLeadingAndTrailingSilence() {
        var samples = [Float](repeating: 0, count: 8_000)          // 0.5s silence @16k
        samples += (0..<16_000).map { _ in Float.random(in: -0.5...0.5) } // 1s speech
        samples += [Float](repeating: 0, count: 8_000)             // 0.5s silence
        let trimmed = AudioMixer.trimSilence(samples: samples, sampleRate: 16_000)
        XCTAssertLessThan(trimmed.count, samples.count)
        // 1s de habla (16000) + padding en ambos lados (2 x 0.12s = 3840)
        XCTAssertTrue((19_500...20_000).contains(trimmed.count), "trimmed=\(trimmed.count)")
    }

    func testKeepsAllSpeech() {
        let speech = (0..<16_000).map { _ in Float.random(in: -0.5...0.5) }
        let trimmed = AudioMixer.trimSilence(samples: speech, sampleRate: 16_000)
        XCTAssertEqual(trimmed.count, speech.count)
    }

    func testAllSilenceReturnsOriginal() {
        let silence = [Float](repeating: 0, count: 4_000)
        let trimmed = AudioMixer.trimSilence(samples: silence, sampleRate: 16_000)
        XCTAssertEqual(trimmed, silence)
    }
}

final class KeychainMaskTests: XCTestCase {
    func testMaskedLongKey() {
        let masked = KeychainStore.masked("sk-or-v1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1234")
        XCTAssertTrue(masked.hasPrefix("sk-or-v"))
        XCTAssertTrue(masked.hasSuffix("1234"))
        XCTAssertTrue(masked.contains("…"))
        XCTAssertLessThan(masked.count, 20)
    }

    func testMaskedShortKey() {
        XCTAssertEqual(KeychainStore.masked("abc"), "•••")
    }
}

final class ProviderSettingsTests: XCTestCase {
    func testProviderDefaults() {
        XCTAssertEqual(Provider.nan.defaultSTTModel, "whisper")
        XCTAssertFalse(Provider.nan.sttModelSelectable)
        XCTAssertEqual(Provider.openrouter.defaultSTTModel, "openai/whisper-large-v3-turbo")
        XCTAssertTrue(Provider.openrouter.sttModelSelectable)
        XCTAssertEqual(Provider.openRouterSTTModels.count, 3)
        XCTAssertTrue(Provider.openRouterSTTModels.allSatisfy { $0.hasPrefix("openai/whisper") })
    }

    func testEnvKeysResolveBothProviders() {
        XCTAssertNotNil(ProviderSettings.shared.envKey(for: .nan))
        XCTAssertNotNil(ProviderSettings.shared.envKey(for: .openrouter))
        XCTAssertTrue(ProviderSettings.shared.hasKey(for: .nan))
        XCTAssertTrue(ProviderSettings.shared.hasKey(for: .openrouter))
    }

    func testModelsFromEnv() {
        XCTAssertEqual(ProviderSettings.shared.sttModel(for: .nan), "whisper")
        XCTAssertEqual(ProviderSettings.shared.sttModel(for: .openrouter), "openai/whisper-large-v3-turbo")
        XCTAssertEqual(ProviderSettings.shared.llmModel(for: .openrouter), "deepseek/deepseek-v4.1-flash")
    }

    func testEffectiveConfigPerProvider() {
        let nan = ProviderSettings.shared.effectiveConfig(for: .nan)
        XCTAssertEqual(nan.provider, .nan)
        XCTAssertTrue(nan.baseURL.contains("nan.builders"))

        let or = ProviderSettings.shared.effectiveConfig(for: .openrouter)
        XCTAssertEqual(or.provider, .openrouter)
        XCTAssertTrue(or.baseURL.contains("openrouter.ai"))
        XCTAssertTrue(or.isConfigured)
    }
}

final class VoiceCommandsTests: XCTestCase {
    func testLineBreakCommands() {
        XCTAssertEqual(VoiceCommands.apply("hola nueva línea mundo"), "hola\nmundo")
        XCTAssertEqual(VoiceCommands.apply("hola Nueva Línea mundo"), "hola\nmundo")
        XCTAssertEqual(VoiceCommands.apply("a punto y aparte b"), "a\n\nb")
        XCTAssertEqual(VoiceCommands.apply("a New Paragraph b"), "a\n\nb")
    }

    func testPunctuationCommands() {
        XCTAssertEqual(VoiceCommands.apply("uno dos puntos tres"), "uno: tres")
        XCTAssertEqual(VoiceCommands.apply("x punto y coma y"), "x; y")
    }

    func testCleanupBreaks() {
        XCTAssertEqual(VoiceCommands.cleanupBreaks("Hola, \n."), "Hola,\n")
        XCTAssertEqual(VoiceCommands.cleanupBreaks("clave: \n\n, primero"), "clave:\n\nprimero")
    }

    func testNoCommandsUntouched() {
        XCTAssertEqual(VoiceCommands.apply("hola mundo normal"), "hola mundo normal")
        XCTAssertEqual(VoiceCommands.apply(""), "")
    }

    func testContainsCommands() {
        XCTAssertTrue(VoiceCommands.containsCommands("dime nueva línea por favor"))
        XCTAssertFalse(VoiceCommands.containsCommands("nada que ver"))
    }
}

final class MeetingExporterTests: XCTestCase {
    func testMarkdownStructure() {
        var entry = HistoryEntry(kind: .meeting, app: "Zoom", audioDuration: 92, rawText: "habló ana de budget", summary: "## Resumen\n- Punto 1")
        entry.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let md = MeetingExporter.markdown(for: entry)
        XCTAssertTrue(md.hasPrefix("# Zoom meeting"))
        XCTAssertTrue(md.contains("**Duration:** 1m 32s"))
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("habló ana de budget"))
    }

    func testMarkdownClipboardRoundTrip() {
        let entry = HistoryEntry(kind: .meeting, app: "FaceTime", rawText: "texto", summary: "resumen")
        MeetingExporter.copyToClipboard(entry)
        let pb = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(pb.contains("# FaceTime meeting"))
        XCTAssertTrue(pb.contains("resumen"))
    }

    func testPDFProducesData() {
        let entry = HistoryEntry(kind: .meeting, app: "Zoom", rawText: "transcripcion de prueba", summary: "resumen de prueba")
        let data = MeetingExporter.pdfData(for: entry)
        XCTAssertTrue(data.count > 1000, "PDF demasiado pequeño: \(data.count)")
        XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
    }
}

final class DictionaryPromptTests: XCTestCase {
    func testSystemPromptIncludesDictionary() {
        let p = Formatter.systemPrompt(for: .natural, dictionary: ["Andrés Santos", "LangChain"])
        XCTAssertTrue(p.contains("SPELLING DICTIONARY"))
        XCTAssertTrue(p.contains("- Andrés Santos"))
        XCTAssertTrue(p.contains("- LangChain"))
    }

    func testSystemPromptWithoutDictionary() {
        let p = Formatter.systemPrompt(for: .natural, dictionary: [])
        XCTAssertFalse(p.contains("SPELLING DICTIONARY"))
    }
}

final class AppConfigBaseURLTests: XCTestCase {
    func testTrailingSlashRemoved() {
        let cfg = AppConfig(provider: .nan, apiKey: "x", baseURL: "https://api.nan.builders/v1/")
        XCTAssertEqual(cfg.baseURL, "https://api.nan.builders/v1")
    }

    func testDefaultProviderURLsAreNormalized() {
        XCTAssertFalse(AppConfig(provider: .nan).baseURL.hasSuffix("/"))
        XCTAssertFalse(AppConfig(provider: .openrouter).baseURL.hasSuffix("/"))
    }
}

final class ShortDictationTests: XCTestCase {
    func testShortNaturalUtteranceSkipsLLM() {
        XCTAssertTrue(Formatter.shouldSkipLLM("gracias", style: .natural, dictionary: []))
        XCTAssertTrue(Formatter.shouldSkipLLM("sí, claro", style: .natural, dictionary: []))
        XCTAssertFalse(Formatter.shouldSkipLLM("gracias equipo por todo el trabajo de hoy", style: .natural, dictionary: []))
        XCTAssertFalse(Formatter.shouldSkipLLM("gracias", style: .formal, dictionary: []))
        XCTAssertFalse(Formatter.shouldSkipLLM("gracias", style: .natural, dictionary: ["Nanflow"]))
        XCTAssertFalse(Formatter.shouldSkipLLM("nueva línea", style: .natural, dictionary: []))
    }

    func testPolishWithoutLLM() {
        XCTAssertEqual(Formatter.polishWithoutLLM("hola"), "Hola.")
        XCTAssertEqual(Formatter.polishWithoutLLM("  gracias  "), "Gracias.")
        XCTAssertEqual(Formatter.polishWithoutLLM("¿qué tal?"), "¿qué tal?")
        XCTAssertEqual(Formatter.polishWithoutLLM("hola nueva línea mundo"), "Hola\nmundo.")
        XCTAssertEqual(Formatter.polishWithoutLLM(""), "")
    }

    func testFormatForDictationFallsBackOnError() async {
        let result = await Formatter.formatForDictation("hola mundo", style: .natural, dictionary: [], fastShort: false) { _, _, _ in
            throw NanError.invalidResponse
        }
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, "Hola mundo.")
    }

    func testFormatForDictationShortPathDoesNotCallLLM() async {
        final class Box { var called = false }
        let box = Box()
        let result = await Formatter.formatForDictation("gracias", style: .natural, dictionary: [], fastShort: true) { _, _, _ in
            box.called = true
            return "no debería usarse"
        }
        XCTAssertFalse(box.called)
        XCTAssertEqual(result.text, "Gracias.")
    }

    func testOffStyleKeepsRawTextAndCommands() async {
        let result = await Formatter.formatForDictation("hola nueva línea mundo", style: .off, dictionary: [], fastShort: true) { _, _, _ in
            XCTFail("style .off should never call the LLM")
            return ""
        }
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "hola\nmundo")
    }
}

final class VoiceActivityTests: XCTestCase {
    func testDetectsVoice() {
        let speech = (0..<16_000).map { _ in Float.random(in: -0.4...0.4) }
        XCTAssertTrue(AudioMixer.hasSpeech(samples: speech, sampleRate: 16_000))
    }

    func testRejectsSilence() {
        XCTAssertFalse(AudioMixer.hasSpeech(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000))
        XCTAssertFalse(AudioMixer.hasSpeech(samples: [], sampleRate: 16_000))
    }

    func testRejectsSingleClick() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[8_000] = 0.9
        XCTAssertFalse(AudioMixer.hasSpeech(samples: samples, sampleRate: 16_000))
    }

    func testDownmixAveragesChannels() {
        XCTAssertEqual(AudioMixer.downmix(channels: [[1, 1], [3, 3]]), [2, 2])
        XCTAssertEqual(AudioMixer.downmix(channels: [[1, 2]]), [1, 2])
        XCTAssertTrue(AudioMixer.downmix(channels: []).isEmpty)
    }
}

final class ClientCacheTests: XCTestCase {
    func testClientIsReusedForUnchangedConfig() {
        let a = ProviderSettings.shared.client(for: .nan)
        let b = ProviderSettings.shared.client(for: .nan)
        XCTAssertTrue(a === b)
    }

    func testClientChangesWhenModelChanges() {
        let p = Provider.openrouter
        let old = ProviderSettings.shared.llmModel(for: p)
        defer {
            ProviderSettings.shared.setLLMModel(old, for: p)
            _ = ProviderSettings.shared.client(for: p)
        }
        ProviderSettings.shared.setLLMModel("test/model-one", for: p)
        let a = ProviderSettings.shared.client(for: p)
        ProviderSettings.shared.setLLMModel("test/model-two", for: p)
        let b = ProviderSettings.shared.client(for: p)
        XCTAssertFalse(a === b)
    }
}

final class SnippetsTests: XCTestCase {
    private func store(_ snippets: [Snippet]) -> SnippetsStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-snip-\(UUID()).json")
        let s = SnippetsStore(fileURL: url)
        s.set(snippets)
        return s
    }

    func testExactMatchIsCaseInsensitiveAndTrimmed() {
        let s = store([Snippet(trigger: "  mi email ", expansion: "andres@example.com")])
        XCTAssertEqual(s.exactMatch("MI  EMAIL"), "andres@example.com")
        XCTAssertEqual(s.exactMatch("mi email"), "andres@example.com")
        XCTAssertNil(s.exactMatch("dime mi email"))
        XCTAssertNil(s.exactMatch(""))
    }

    func testApplyReplacesInsideText() {
        let s = store([Snippet(trigger: "mi email", expansion: "andres@example.com")])
        XCTAssertEqual(s.apply("escríbeme a mi email porfa"), "escríbeme a andres@example.com porfa")
    }

    func testApplyPrefersLongestTrigger() {
        let s = store([
            Snippet(trigger: "mi web", expansion: "https://a.com"),
            Snippet(trigger: "mi web personal", expansion: "https://b.com"),
        ])
        XCTAssertEqual(s.apply("mira mi web personal"), "mira https://b.com")
        XCTAssertEqual(s.apply("mira mi web"), "mira https://a.com")
    }

    func testApplyRespectsWordBoundaries() {
        let s = store([Snippet(trigger: "pusea", expansion: "Pusea")])
        XCTAssertEqual(s.apply("hay una impusea ahí"), "hay una impusea ahí")
    }

    func testPersistenceRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-snip-\(UUID()).json")
        let first = SnippetsStore(fileURL: url)
        first.add(trigger: "linkedin", expansion: "https://linkedin.com/in/x")
        let second = SnippetsStore(fileURL: url)
        XCTAssertEqual(second.all().count, 1)
        XCTAssertEqual(second.all().first?.trigger, "linkedin")
        try? FileManager.default.removeItem(at: url)
    }
}

final class VoiceCommandExtensionsTests: XCTestCase {
    func testPunctuationSpacingIsCleaned() {
        XCTAssertEqual(VoiceCommands.apply("uno dos puntos tres"), "uno: tres")
        XCTAssertEqual(VoiceCommands.apply("x punto y coma y"), "x; y")
        XCTAssertEqual(VoiceCommands.apply("uno coma dos"), "uno, dos")
        XCTAssertEqual(VoiceCommands.apply("hola punto final"), "hola.")
    }

    func testLongestPhraseWins() {
        XCTAssertEqual(VoiceCommands.apply("fin punto y coma"), "fin;")
        // "palabra (nota)" is correct prose, so the space before "(" stays;
        // "( hola )" still gets normalized to "(hola)".
        XCTAssertEqual(VoiceCommands.apply("paréntesis abrir paréntesis cerrar paréntesis"), "paréntesis ()")
        XCTAssertEqual(VoiceCommands.cleanupSpacing("( hola )"), "(hola)")
    }

    func testEnterCommands() {
        XCTAssertEqual(VoiceCommands.apply("línea uno pulsa enter línea dos"), "línea uno\nlínea dos")
        XCTAssertEqual(VoiceCommands.apply("a press enter b"), "a\nb")
    }

    func testQuotes() {
        XCTAssertEqual(VoiceCommands.apply("dijo comillas hola comillas"), "dijo \" hola \"")
    }
}

final class InsightsTests: XCTestCase {
    func testSummaryCountsWordsAndWPM() {
        var a = HistoryEntry(kind: .dictation, audioDuration: 60, rawText: "uno dos", finalText: "uno dos tres cuatro")
        a.transcriptionMs = 100
        var b = HistoryEntry(kind: .dictation, audioDuration: 30, rawText: "hola", finalText: "hola mundo")
        b.transcriptionMs = 50
        let meeting = HistoryEntry(kind: .meeting, audioDuration: 600, rawText: "mucho texto", finalText: "mucho texto")

        let summary = Insights.summary([a, b, meeting])
        XCTAssertEqual(summary.dictationCount, 2)
        XCTAssertEqual(summary.totalWords, 6)
        // 6 words in 90 s = 4 wpm
        XCTAssertEqual(summary.averageWPM, 4)
        XCTAssertEqual(summary.totalMinutes, 1)
        _ = a; _ = b
    }

    func testEmptyHistory() {
        let summary = Insights.summary([])
        XCTAssertEqual(summary.totalWords, 0)
        XCTAssertEqual(summary.averageWPM, 0)
    }
}

final class TransformPresetTests: XCTestCase {
    func testSixPresetsWithPrompts() {
        XCTAssertEqual(Formatter.TransformPreset.allCases.count, 6)
        for preset in Formatter.TransformPreset.allCases {
            XCTAssertFalse(preset.systemPrompt.isEmpty)
            XCTAssertFalse(preset.label.isEmpty)
        }
        XCTAssertTrue(Formatter.TransformPreset.english.systemPrompt.contains("ENGLISH"))
        XCTAssertTrue(Formatter.TransformPreset.grammar.systemPrompt.contains("SAME LANGUAGE"))
    }
}

final class ScratchpadStoreTests: XCTestCase {
    func testReadWriteAndAppend() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-scratch-\(UUID()).md")
        let store = ScratchpadStore(fileURL: url)
        store.write("primera nota")
        XCTAssertEqual(store.read(), "primera nota")
        store.append("segunda nota", date: Date(timeIntervalSince1970: 1_700_000_000))
        let content = store.read()
        XCTAssertTrue(content.contains("## 2023-11-14"))
        XCTAssertTrue(content.contains("segunda nota"))
        XCTAssertTrue(content.contains("primera nota"))
        store.append("   ")
        XCTAssertEqual(store.read(), content)
        try? FileManager.default.removeItem(at: url)
    }
}

final class SnippetPromptTests: XCTestCase {
    func testExactMatchIgnoresTrailingPunctuation() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-snip-\(UUID()).json")
        let s = SnippetsStore(fileURL: url)
        s.set([Snippet(trigger: "mi email personal", expansion: "a@b.com")])
        XCTAssertEqual(s.exactMatch("mi email personal."), "a@b.com")
        XCTAssertEqual(s.exactMatch("Mi  email personal,"), "a@b.com")
        try? FileManager.default.removeItem(at: url)
    }

    func testPromptHintsJoinsTriggers() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nf-snip-\(UUID()).json")
        let s = SnippetsStore(fileURL: url)
        s.set([Snippet(trigger: "mi email personal", expansion: "a@b.com"), Snippet(trigger: "  ", expansion: "x")])
        XCTAssertEqual(s.promptHints(), "mi email personal.")
        try? FileManager.default.removeItem(at: url)
    }
}
