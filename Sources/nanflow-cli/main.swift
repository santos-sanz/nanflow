import AppKit
import AVFoundation
import Foundation
import NanflowCore

setvbuf(stdout, nil, _IOLBF, 8192)

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: \(msg)\n").data(using: .utf8)!)
    exit(1)
}

func flag(_ name: String) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func config() -> AppConfig {
    let cfg = AppConfig.load()
    guard cfg.isConfigured else { fail("Nan API sin configurar: rellena NAN_API_KEY y NAN_BASE_URL en .env") }
    return cfg
}

func providerOverride() -> Provider? {
    if args.contains("--provider"), let p = flag("--provider") {
        return Provider(rawValue: p)
    }
    return nil
}

func readSamples(url: URL) throws -> (samples: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        return ([], 16_000)
    }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else { return ([], 16_000) }
    let channelCount = Int(format.channelCount)
    let frameCount = Int(buffer.frameLength)
    var mono = [Float](repeating: 0, count: frameCount)
    for c in 0..<channelCount {
        let data = channels[c]
        for i in 0..<frameCount { mono[i] += data[i] }
    }
    if channelCount > 1 {
        for i in 0..<frameCount { mono[i] /= Float(channelCount) }
    }
    if format.sampleRate != 16_000 {
        mono = AudioMixer.resample(samples: mono, fromRate: format.sampleRate, toRate: 16_000)
    }
    return (mono, 16_000)
}

// MARK: - Commands

func cmdTranscribe() async {
    guard args.count >= 2 else { fail("usage: nanflow-cli transcribe <audio> [--lang es|en] [--provider nan|openrouter]") }
    let url = URL(fileURLWithPath: args[1])
    guard FileManager.default.fileExists(atPath: url.path) else { fail("file not found: \(args[1])") }
    let p = providerOverride()
    let cfg = ProviderSettings.shared.effectiveConfig(for: p)
    guard cfg.isConfigured else { fail("sin API key para \(cfg.provider.label)") }
    let client = NanClient(config: cfg)
    do {
        let out = try await client.transcribe(audioURL: url, language: flag("--lang"))
        print("provider: \(cfg.provider.label) · stt=\(cfg.whisperModel)")
        print("lang:     \(out.language ?? "?")")
        print("duration: \(String(format: "%.2f", out.audioDuration))s in \(String(format: "%.2f", out.processingTime))s")
        print("raw:      \(out.text)")
    } catch { fail("\(error)") }
}

func cmdPipeline() async {
    guard args.count >= 2 else { fail("usage: nanflow-cli pipeline <audio> [--no-format] [--no-fast] [--no-vad] [--provider nan|openrouter]") }
    let url = URL(fileURLWithPath: args[1])
    guard FileManager.default.fileExists(atPath: url.path) else { fail("file not found: \(args[1])") }
    let noFormat = args.contains("--no-format")
    let noFast = args.contains("--no-fast")
    let p = providerOverride()
    let cfg = ProviderSettings.shared.effectiveConfig(for: p)
    guard cfg.isConfigured else { fail("sin API key para \(cfg.provider.label)") }
    let client = ProviderSettings.shared.client(for: p)
    do {
        if !args.contains("--no-vad"), let loaded = try? readSamples(url: url),
           !AudioMixer.hasSpeech(samples: loaded.samples, sampleRate: loaded.sampleRate) {
            print("provider: \(cfg.provider.label) · stt=\(cfg.whisperModel) · llm=\(cfg.model)")
            print("vad:      no se detectó voz — no se llama a la API")
            print("timing:   stt 0ms · llm 0ms · total 0ms")
            return
        }

        let t0 = Date()
        let out = try await client.transcribe(audioURL: url)
        let t1 = Date()
        print("provider: \(cfg.provider.label) · stt=\(cfg.whisperModel) · llm=\(cfg.model)")
        print("raw:      \(out.text)")
        guard !noFormat, !out.text.isEmpty else { return }
        let result = await Formatter.formatForDictation(out.text, style: .natural, dictionary: [], fastShort: !noFast) { raw, style, dictionary in
            try await client.chat(
                system: Formatter.systemPrompt(for: style, dictionary: dictionary),
                user: raw,
                maxTokens: 2048,
                temperature: 0.1
            )
        }
        let t2 = Date()
        print("final:    \(result.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        if result.usedFallback {
            print("llm:      fallback a transcripción cruda")
        } else if !noFast && Formatter.shouldSkipLLM(out.text, style: .natural, dictionary: []) {
            print("llm:      omitido (dictado corto)")
        }
        print("timing:   stt \(Int(t1.timeIntervalSince(t0) * 1000))ms · llm \(Int(t2.timeIntervalSince(t1) * 1000))ms · total \(Int(t2.timeIntervalSince(t0) * 1000))ms")
    } catch { fail("\(error)") }
}

func cmdModels() async {
    let p = providerOverride()
    let cfg = ProviderSettings.shared.effectiveConfig(for: p)
    guard cfg.isConfigured else { fail("sin API key para \(cfg.provider.label)") }
    do {
        let catalog = try await NanClient(config: cfg).listModels()
        print("provider \(cfg.provider.label): \(catalog.llmModels.count) LLMs · STT: \(catalog.sttModels.joined(separator: ", "))")
        print("primeros LLMs: \(catalog.llmModels.prefix(8).joined(separator: ", "))")
    } catch { fail("\(error)") }
}

func cmdTestLLM() async {
    let client = NanClient(config: config())
    do {
        let reply = try await client.chat(system: "Responde exactamente: NANFLOW-OK", user: "ping", maxTokens: 20)
        print("model \(AppConfig.load().model) -> \(reply)")
        guard reply.contains("NANFLOW-OK") else { fail("respuesta inesperada") }
        print("test-llm: OK")
    } catch { fail("\(error)") }
}

func cmdRecordTest() async {
    let seconds = Double(flag("--secs") ?? "3") ?? 3
    print("grabando micro \(seconds)s... habla ahora")
    let recorder = MicRecorder()
    do {
        try recorder.start()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let url = URL(fileURLWithPath: "/tmp/nanflow-mic-test.wav")
        let duration = try recorder.stopAndWrite(to: url)
        print("guardado: \(url.path) (\(String(format: "%.2f", duration))s)")
        let samples = recorder.level
        _ = samples
        print("transcribiendo via Nan whisper...")
        let out = try await NanClient(config: config()).transcribe(audioURL: url)
        print("raw: \(out.text)")
        let formatted = try await Formatter.formatDictation(out.text)
        print("final: \(formatted)")
    } catch { fail("\(error)") }
}

func cmdMeetingTest() async {
    let seconds = Double(flag("--secs") ?? "8") ?? 8
    let history = HistoryStore()
    let engine = MeetingEngine(history: history)
    engine.onResult = { entry in
        print("entry: \(entry.kind) app=\(entry.app) dur=\(Int(entry.audioDuration))s")
        print("raw:  \(entry.rawText.prefix(120))")
        if let s = entry.summary { print("summary:\n\(s.prefix(400))") }
    }
    engine.onError = { print("ERROR: \($0)") }
    print("grabando reunión simulada \(seconds)s (sistema+micro)...")
    engine.startRecording(app: "TestMeeting")
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    engine.stopAndProcess()
    print("procesando... espera")
    try? await Task.sleep(nanoseconds: 40_000_000_000)
    exit(0)
}

func cmdTapTest() async {
    let recorder = SystemAudioRecorder()
    print("iniciando tap de sistema...")
    do {
        try recorder.start()
    } catch { fail("\(error)") }
    print("tap OK — reproduciendo audio de prueba...")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["/tmp/nf-test-es.wav"]
    do { try p.run() } catch { fail("afplay no arrancó: \(error)") }
    p.waitUntilExit()
    try? await Task.sleep(nanoseconds: 500_000_000)
    guard let data = recorder.stop() else { fail("no se capturó nada") }
    print("capturados \(data.samples.count) samples @ \(Int(data.sampleRate))Hz (\(String(format: "%.1f", Double(data.samples.count) / data.sampleRate))s)")
    let wav = URL(fileURLWithPath: "/tmp/nanflow-tap-test.wav")
    do { try WavWriter.write(samples: data.samples, sampleRate: data.sampleRate, to: wav) } catch { fail("\(error)") }
    print("transcribiendo via Nan whisper...")
    let out: TranscriptionOutput
    do { out = try await NanClient(config: config()).transcribe(audioURL: wav) } catch { fail("\(error)") }
    print("TRANSCRITO: \(out.text)")
}

func cmdDetect() async {
    if let meeting = MeetingDetector.currentlyInMeeting() {
        print("REUNIÓN ACTIVA: \(meeting.appName) (\(meeting.appLocalizedName))")
    } else {
        print("sin reunión detectada")
    }
    print("apps de reunión corriendo: \(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }.filter { MeetingApp.known.flatMap(\.processNames).contains($0) })")
}

func cmdEnv() {
    let cfg = AppConfig.load()
    print("NAN_BASE_URL: \(cfg.baseURL)")
    print("NAN_MODEL:    \(cfg.model)")
    print("NAN_API_KEY:  \(cfg.apiKey.isEmpty ? "(vacía)" : "sk-...\(cfg.apiKey.suffix(4))")")
    print("configurado:  \(cfg.isConfigured)")
}

switch command {
case "transcribe": await cmdTranscribe()
case "pipeline": await cmdPipeline()
case "models": await cmdModels()
case "test-llm": await cmdTestLLM()
case "record-test": await cmdRecordTest()
case "meeting-test": await cmdMeetingTest()
case "tap-test": await cmdTapTest()
case "detect": await cmdDetect()
case "env": cmdEnv()
default:
    print("""
    nanflow-cli — dictado local toolkit

    COMMANDS:
      env                          muestra config Nan cargada
      test-llm                     verifica chat LLM de Nan
      transcribe <audio> [--lang]  whisper de Nan sobre un WAV/AIFF
      pipeline <audio>             transcribe + formatea (pipeline completo de dictado)
      record-test [--secs N]       graba el micro N segundos y hace el pipeline
      detect                       estado de detección de reuniones
    """)
}
