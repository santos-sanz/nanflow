import Foundation

public struct TranscriptionOutput: Sendable {
    public let text: String
    public let language: String?
    public let audioDuration: TimeInterval
    public let processingTime: TimeInterval
}

public enum NanError: LocalizedError {
    case notConfigured
    case http(status: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Nan API no configurada: falta NAN_API_KEY en .env"
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(300))"
        case .invalidResponse: return "Respuesta inválida de la API de Nan"
        }
    }
}

public final class NanClient: @unchecked Sendable {
    private let config: AppConfig
    private let session: URLSession

    public init(config: AppConfig = .load()) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg)
    }

    /// Warms up DNS + TLS + HTTP/2 to the Nan API so the first real request skips the handshake.
    public func prewarm() {
        guard config.isConfigured else { return }
        var request = URLRequest(url: URL(string: "\(config.baseURL)/models")!)
        request.httpMethod = "HEAD"
        applyAuth(to: &request)
        request.timeoutInterval = 10
        session.dataTask(with: request).resume()
    }

    // MARK: - Whisper transcription (audio -> text)

    /// Transcribes raw mono samples without touching the disk (fast path for dictation).
    public func transcribe(samples: [Float], sampleRate: Double, language: String? = nil) async throws -> TranscriptionOutput {
        let wav = WavEncoder.encode(samples: samples, sampleRate: sampleRate)
        return try await transcribeUpload(audioData: wav, filename: "audio.wav", language: language)
    }

    /// Transcribes an audio file from disk (used for meetings).
    public func transcribe(audioURL: URL, language: String? = nil) async throws -> TranscriptionOutput {
        let data = try Data(contentsOf: audioURL)
        return try await transcribeUpload(audioData: data, filename: audioURL.lastPathComponent, language: language)
    }

    private func transcribeUpload(audioData: Data, filename: String, language: String?) async throws -> TranscriptionOutput {
        guard config.isConfigured else { throw NanError.notConfigured }

        let boundary = "nanflow-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(config.baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        addField("model", config.whisperModel)
        if let language { addField("language", language) }
        addField("response_format", "verbose_json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let start = Date()
        let (data, response) = try await session.upload(for: request, from: body)
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else { throw NanError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NanError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct WhisperResponse: Decodable {
            struct Segment: Decodable { let start: Double; let end: Double }
            let text: String
            let language: String?
            let duration: Double?
            let segments: [Segment]?
        }
        let decoded: WhisperResponse
        do { decoded = try JSONDecoder().decode(WhisperResponse.self, from: data) } catch { throw NanError.invalidResponse }

        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionOutput(
            text: text,
            language: (decoded.language == "en" && Self.looksSpanish(text)) ? "es" : decoded.language,
            audioDuration: decoded.duration ?? (decoded.segments?.last?.end ?? 0),
            processingTime: elapsed
        )
    }

    static func looksSpanish(_ text: String) -> Bool {
        let markers = ["á", "é", "í", "ó", "ú", "ñ", "¿", "¡", " el ", " la ", " que ", " de ", " y ", " en "]
        let lower = " \(text.lowercased()) "
        return markers.contains { lower.contains($0) }
    }

    // MARK: - Chat completions (LLM)

    public func chat(system: String, user: String, maxTokens: Int = 1024, temperature: Double = 0.2, jsonMode: Bool = false) async throws -> String {
        guard config.isConfigured else { throw NanError.notConfigured }

        var request = URLRequest(url: URL(string: "\(config.baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        switch config.provider {
        case .nan:
            payload["chat_template_kwargs"] = ["enable_thinking": false]
        case .openrouter:
            payload["reasoning"] = ["exclude": true, "enabled": false]
        }
        if jsonMode { payload["response_format"] = ["type": "json_object"] }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NanError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NanError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw NanError.invalidResponse }

        let content = (message["content"] as? String) ?? ""
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String) ?? ""
            if !reasoning.isEmpty {
                throw NanError.http(status: 590, body: "El modelo solo devolvió razonamiento (usa un modelo no-reasoning como \(config.model))")
            }
        }
        return content
    }

    // MARK: - Provider plumbing

    private func applyAuth(to request: inout URLRequest) {
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        if config.provider == .openrouter {
            request.setValue("Nanflow", forHTTPHeaderField: "X-Title")
        }
    }

    // MARK: - Model catalog

    public struct ModelCatalog: Sendable {
        public var llmModels: [String]
        public var sttModels: [String]
    }

    /// Fetches the model list for the configured provider.
    /// Nan: single STT model ("whisper"), chat models from /models.
    /// OpenRouter: whisper family for STT (not listed in /models), chat models from the public catalog.
    public func listModels() async throws -> ModelCatalog {
        guard config.isConfigured else { throw NanError.notConfigured }

        var request = URLRequest(url: URL(string: "\(config.baseURL)/models")!)
        request.httpMethod = "GET"
        applyAuth(to: &request)
        request.timeoutInterval = 15

        var llm: [String] = []
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NanError.invalidResponse
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["data"] as? [[String: Any]]
            else { throw NanError.invalidResponse }

            for item in items {
                guard let id = item["id"] as? String else { continue }
                switch config.provider {
                case .nan:
                    let lower = id.lowercased()
                    let excluded = ["whisper", "kokoro", "embedding", "rerank", "flux", "image", "tts"].contains { lower.contains($0) }
                    if !excluded { llm.append(id) }
                case .openrouter:
                    if id.contains(":batch") || id.contains(":free") { continue }
                    let arch = item["architecture"] as? [String: Any]
                    let modalities = (arch?["input_modalities"] as? [String]) ?? []
                    if modalities.contains("audio") { continue } // audio-input chat ≠ LLM de texto
                    llm.append(id)
                }
            }
            llm.sort()
        } catch {
            // sin catálogo seguimos con los defaults
        }

        let stt: [String]
        switch config.provider {
        case .nan:
            stt = [config.whisperModel]
        case .openrouter:
            stt = Provider.openRouterSTTModels
        }

        if !llm.contains(config.model) { llm.insert(config.model, at: 0) }
        return ModelCatalog(llmModels: llm, sttModels: stt)
    }
}
