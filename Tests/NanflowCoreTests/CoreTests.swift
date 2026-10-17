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
