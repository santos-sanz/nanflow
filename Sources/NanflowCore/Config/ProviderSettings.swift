import Foundation

/// Resolves the active provider, API keys (Keychain override > .env > none) and models.
/// The UI writes here; the engines read through `client()`.
public final class ProviderSettings: @unchecked Sendable {
    public static let shared = ProviderSettings()

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var cachedEnv: [String: String]
    private var cachedClients: [Provider: (fingerprint: String, client: NanClient)] = [:]

    private enum Keys {
        static let provider = "nanflow.provider"
        static func llmModel(_ p: Provider) -> String { "nanflow.\(p.rawValue).llm.model" }
        static func sttModel(_ p: Provider) -> String { "nanflow.\(p.rawValue).stt.model" }
    }

    private init() {
        cachedEnv = EnvLoader.load()
    }

    public var provider: Provider {
        get {
            lock.lock(); defer { lock.unlock() }
            return Provider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .nan
        }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(newValue.rawValue, forKey: Keys.provider)
        }
    }

    public func reloadEnv() {
        lock.lock(); defer { lock.unlock() }
        cachedEnv = EnvLoader.load()
    }

    private func envValue(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let v = cachedEnv[name]
        return (v?.isEmpty == false) ? v : nil
    }

    // MARK: - API keys

    /// Keychain override (set from the UI) wins over .env.
    public func keychainKey(for p: Provider) -> String? {
        let v = KeychainStore.read(account: p.keychainAccount)
        return (v?.isEmpty == false) ? v : nil
    }

    public func envKey(for p: Provider) -> String? {
        envValue("\(p.envKeyPrefix)_API_KEY")
    }

    public func setKeychainKey(_ key: String?, for p: Provider) {
        if let key, !key.isEmpty {
            KeychainStore.save(key, account: p.keychainAccount)
        } else {
            KeychainStore.delete(account: p.keychainAccount)
        }
    }

    public func apiKey(for p: Provider) -> String? {
        keychainKey(for: p) ?? envKey(for: p)
    }

    public func keySource(for p: Provider) -> String? {
        if keychainKey(for: p) != nil { return "Keychain" }
        if envKey(for: p) != nil { return ".env" }
        return nil
    }

    public func hasKey(for p: Provider) -> Bool { apiKey(for: p) != nil }

    // MARK: - Models

    private func envModel(_ p: Provider, kind: String) -> String? {
        switch (p, kind) {
        case (.nan, "llm"): return envValue("NAN_MODEL")
        case (.nan, "stt"): return envValue("NAN_WHISPER_MODEL")
        case (.openrouter, "llm"): return envValue("LLM_OPENROUTER_MODEL")
        case (.openrouter, "stt"): return envValue("STT_OPENROUTER_MODEL")
        default: return nil
        }
    }

    public func llmModel(for p: Provider) -> String {
        if let saved = defaults.string(forKey: Keys.llmModel(p)), !saved.isEmpty { return saved }
        if let fromEnv = envModel(p, kind: "llm") { return fromEnv }
        return p.defaultLLMModel
    }

    public func setLLMModel(_ model: String, for p: Provider) {
        defaults.set(model, forKey: Keys.llmModel(p))
    }

    public func sttModel(for p: Provider) -> String {
        if let saved = defaults.string(forKey: Keys.sttModel(p)), !saved.isEmpty { return saved }
        if let fromEnv = envModel(p, kind: "stt") { return fromEnv }
        return p.defaultSTTModel
    }

    public func setSTTModel(_ model: String, for p: Provider) {
        defaults.set(model, forKey: Keys.sttModel(p))
    }

    public func baseURL(for p: Provider) -> String {
        envValue("\(p.envKeyPrefix)_BASE_URL") ?? p.defaultBaseURL
    }

    // MARK: - Resolution

    public func effectiveConfig(for p: Provider? = nil) -> AppConfig {
        let provider = p ?? self.provider
        let envOverride = envValue("\(provider.envKeyPrefix)_BASE_URL")
        let fromEnv = keychainKey(for: provider) == nil && envKey(for: provider) != nil
        return AppConfig(
            provider: provider,
            apiKey: apiKey(for: provider) ?? "",
            baseURL: envOverride ?? provider.defaultBaseURL,
            model: llmModel(for: provider),
            whisperModel: sttModel(for: provider),
            keyFromEnv: fromEnv
        )
    }

    public func isConfigured(for p: Provider? = nil) -> Bool {
        effectiveConfig(for: p).isConfigured
    }

    public func client(for p: Provider? = nil) -> NanClient {
        let provider = p ?? self.provider
        let config = effectiveConfig(for: provider)
        let fingerprint = "\(provider.rawValue)|\(config.baseURL)|\(config.apiKey.hashValue)|\(config.model)|\(config.whisperModel)"
        lock.lock()
        if let cached = cachedClients[provider], cached.fingerprint == fingerprint {
            lock.unlock()
            return cached.client
        }
        let client = NanClient(config: config)
        cachedClients[provider] = (fingerprint, client)
        lock.unlock()
        return client
    }

    /// Reuses the same client (and URLSession connection) when the config has not changed.
    public func prewarmIfNeeded() {
        client().prewarm()
    }

    public func prewarm() {
        client().prewarm(force: true)
    }
}
