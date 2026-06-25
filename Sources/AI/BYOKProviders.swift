import Foundation

/// How reliably a provider honors `response_format` for structured output.
/// Drives whether we send a strict JSON-schema, the looser `json_object`
/// mode, or coerce JSON via the prompt + lean on the tolerant parsers.
enum StructuredOutputSupport: Sendable {
    case jsonSchema   // full response_format json_schema (OpenAI)
    case jsonObject   // json_object mode only — prompt-coerce + tolerant parse
    case native       // provider-native structured output (Anthropic)
}

/// BYOK provider presets. Almost every provider speaks the OpenAI
/// `/v1/chat/completions` format, so all of them except Anthropic run through
/// the existing OpenAI-compatible client (`OpenAIProvider`) with a swapped
/// base URL + model. Anthropic is the one native exception (`ClaudeProvider`).
///
/// Model ids + endpoints verified current as of 2026-06; the user can edit the
/// model in Settings, so these are first-run defaults, not hard requirements.
enum BYOKProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case anthropic
    case gemini
    case xai
    case groq
    case openRouter
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .xai: return "xAI (Grok)"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    /// Underlying app provider type. Everything but Anthropic is the
    /// OpenAI-compatible client pointed at `defaultBaseURL`.
    var providerType: AIProviderConfig.ProviderType {
        self == .anthropic ? .claude : .openai
    }

    /// Default OpenAI-compatible chat-completions endpoint. `nil` for
    /// `.anthropic` (native client owns its URL) and `.custom` (user supplies).
    var defaultBaseURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .xai: return URL(string: "https://api.x.ai/v1/chat/completions")
        case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")
        case .anthropic, .custom: return nil
        }
    }

    /// Sensible default model id (editable in Settings).
    var defaultModel: String {
        switch self {
        case .openAI: return AppConstants.AI.defaultOpenAIModel
        case .anthropic: return AppConstants.AI.defaultClaudeModel
        case .gemini: return "gemini-2.5-flash"
        case .xai: return "grok-4.3"
        case .groq: return "openai/gpt-oss-120b"
        case .openRouter: return "openai/gpt-5-mini"
        case .custom: return ""
        }
    }

    var structuredOutput: StructuredOutputSupport {
        switch self {
        case .openAI: return .jsonSchema
        case .anthropic: return .native
        // Conservative: non-OpenAI OpenAI-compat layers vary in json_schema
        // fidelity (Gemini rejected integer enums), so request the looser
        // json_object mode and rely on the tolerant result parsers.
        case .gemini, .xai, .groq, .openRouter, .custom: return .jsonObject
        }
    }

    /// Where the user gets an API key (linked from the settings UI).
    var keyURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .xai: return URL(string: "https://console.x.ai")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .custom: return nil
        }
    }

    /// Whether the user must supply their own base URL (only `.custom`).
    var requiresCustomBaseURL: Bool { self == .custom }

    /// Best-effort reverse map from a persisted (providerType, baseURL) back to
    /// a preset, so Settings can re-select the right row on relaunch.
    static func infer(providerType: AIProviderConfig.ProviderType, baseURL: URL?) -> BYOKProvider {
        if providerType == .claude { return .anthropic }
        guard let host = baseURL?.host else { return .openAI }
        switch host {
        case "api.openai.com": return .openAI
        case "generativelanguage.googleapis.com": return .gemini
        case "api.x.ai": return .xai
        case "api.groq.com": return .groq
        case "openrouter.ai": return .openRouter
        default: return .custom
        }
    }
}
