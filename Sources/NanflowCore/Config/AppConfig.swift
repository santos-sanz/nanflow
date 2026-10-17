import Foundation

public struct AppConfig: Sendable {
    public var apiKey: String
    public var baseURL: String
    public var model: String
    public var whisperModel: String

    public init(apiKey: String = "", baseURL: String = "https://api.nan.builders/v1", model: String = "qwen3.8-flash", whisperModel: String = "whisper") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.whisperModel = whisperModel
    }

    public var isConfigured: Bool { !apiKey.isEmpty && !baseURL.isEmpty }

    public static func load() -> AppConfig {
        let env = EnvLoader.load()
        var cfg = AppConfig()
        if let k = env["NAN_API_KEY"], !k.isEmpty { cfg.apiKey = k }
        if let u = env["NAN_BASE_URL"], !u.isEmpty { cfg.baseURL = u }
        if let m = env["NAN_MODEL"], !m.isEmpty { cfg.model = m }
        if let w = env["NAN_WHISPER_MODEL"], !w.isEmpty { cfg.whisperModel = w }
        return cfg
    }
}

public enum EnvLoader {
    public static func load() -> [String: String] {
        var result: [String: String] = [:]

        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("NAN_") {
            result[k] = v
        }

        let fm = FileManager.default
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
