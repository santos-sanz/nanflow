import Foundation

public enum Provider: String, CaseIterable, Sendable {
    case nan
    case openrouter

    public var label: String {
        switch self {
        case .nan: return "Nan"
        case .openrouter: return "OpenRouter"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .nan: return "https://api.nan.builders/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        }
    }

    public var defaultLLMModel: String {
        switch self {
        case .nan: return "qwen3.8-flash"
        case .openrouter: return "deepseek/deepseek-v4.1-flash"
        }
    }

    public var defaultSTTModel: String {
        switch self {
        case .nan: return "whisper"
        case .openrouter: return "openai/whisper-large-v3-turbo"
        }
    }

    public var envKeyPrefix: String {
        self == .nan ? "NAN" : "OPENROUTER"
    }

    public var keychainAccount: String {
        "provider.\(rawValue).api-key"
    }

    /// Nan exposes a single STT model; OpenRouter offers the OpenAI whisper family.
    public var sttModelSelectable: Bool { self == .openrouter }

    public static let openRouterSTTModels: [String] = [
        "openai/whisper-large-v3-turbo",
        "openai/whisper-large-v3",
        "openai/whisper-1",
    ]
}

public struct AppConfig: Sendable {
    public var provider: Provider
    public var apiKey: String
    public var baseURL: String
    public var model: String
    public var whisperModel: String
    /// True when the API key comes from .env (shown masked in the UI, not editable in place).
    public var keyFromEnv: Bool

    public init(
        provider: Provider = .nan,
        apiKey: String = "",
        baseURL: String? = nil,
        model: String? = nil,
        whisperModel: String? = nil,
        keyFromEnv: Bool = false
    ) {
        self.provider = provider
        self.apiKey = apiKey
        let resolvedBaseURL = baseURL ?? provider.defaultBaseURL
        self.baseURL = resolvedBaseURL.hasSuffix("/") ? String(resolvedBaseURL.dropLast()) : resolvedBaseURL
        self.model = model ?? provider.defaultLLMModel
        self.whisperModel = whisperModel ?? provider.defaultSTTModel
        self.keyFromEnv = keyFromEnv
    }

    public var isConfigured: Bool { !apiKey.isEmpty && !baseURL.isEmpty }

    /// Legacy loader: resolves the config for whatever provider is selected in ProviderSettings.
    public static func load() -> AppConfig {
        ProviderSettings.shared.effectiveConfig()
    }
}

public enum EnvLoader {
    public static func load() -> [String: String] {
        var result: [String: String] = [:]

        for (k, v) in ProcessInfo.processInfo.environment
        where k.hasPrefix("NAN_") || k.hasPrefix("OPENROUTER_") {
            result[k] = v
        }

        var candidates: [URL] = [
            URL(fileURLWithPath: NSString(string: "~/.nanflow/.env").expandingTildeInPath),
            appSupportDir().appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".env"),
        ]
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(".env"))
        }

        for url in candidates.reversed() {
            if let parsed = parse(url.path), !parsed.isEmpty {
                for (k, v) in parsed { result[k] = v }
            }
        }
        return result
    }

    static func parse(_ path: String) -> [String: String]? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    public static func appSupportDir() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Nanflow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
