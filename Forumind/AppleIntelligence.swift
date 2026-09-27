import Foundation

// Apple Intelligence provider: app-owned types and pure logic.
//
// Nothing in this file imports FoundationModels, so the rules (availability
// mapping, default-provider choice, context budgets, error text, prompt
// fitting, agent-action decoding) are unit-testable on any simulator with a
// fake `AppleIntelligenceServing`. The FoundationModels bridge lives in
// AppleIntelligenceClient.swift. See docs/APPLE_INTELLIGENCE.md.

/// Where an Apple Intelligence request runs.
enum AppleIntelligenceBackend: String, Codable, Equatable {
    /// `PrivateCloudComputeLanguageModel` (iOS 27+, managed entitlement,
    /// compiled only with `PCC_ENABLED`).
    case privateCloudCompute
    /// `SystemLanguageModel.default` (iOS 26+ on Apple Intelligence devices).
    case onDevice

    /// Recorded as the job's "model" ("Apple Intelligence · On-device").
    var label: String {
        switch self {
        case .privateCloudCompute: "Private Cloud Compute"
        case .onDevice: "On-device"
        }
    }

    init?(label: String) {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines) {
        case Self.privateCloudCompute.label: self = .privateCloudCompute
        case Self.onDevice.label: self = .onDevice
        default: return nil
        }
    }
}

/// Why Apple Intelligence can't be used right now.
enum AppleIntelligenceUnavailableReason: Equatable {
    /// iOS 17–25, or an SDK without FoundationModels.
    case requiresNewerOS
    /// The hardware doesn't support Apple Intelligence.
    case deviceNotEligible
    /// Supported device, but Apple Intelligence is off in Settings.
    case appleIntelligenceNotEnabled
    /// Model assets are still downloading or the system isn't ready.
    case modelNotReady
    /// The device's language or region isn't supported.
    case unsupportedLanguage

    var title: String {
        switch self {
        case .requiresNewerOS: "Requires iOS 26 or later"
        case .deviceNotEligible: "Device not supported"
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in Settings"
        case .modelNotReady: "Model downloading…"
        case .unsupportedLanguage: "Not available in your region or language"
        }
    }

    var detail: String {
        switch self {
        case .requiresNewerOS:
            "Apple Intelligence needs iOS 26 or later on a supported iPhone or iPad. Choose another provider below."
        case .deviceNotEligible:
            "This iPhone or iPad doesn’t support Apple Intelligence. Choose another provider below."
        case .appleIntelligenceNotEnabled:
            "Open Settings › Apple Intelligence & Siri and turn on Apple Intelligence, then come back."
        case .modelNotReady:
            "Apple Intelligence is still getting ready on this device. Keep it on Wi‑Fi and power, then try again in a few minutes."
        case .unsupportedLanguage:
            "Apple Intelligence isn’t available for this device’s language or region yet. Choose another provider below."
        }
    }
}

/// Availability of the Apple Intelligence provider, resolved to one backend.
enum AppleIntelligenceStatus: Equatable {
    case available(AppleIntelligenceBackend)
    case unavailable(AppleIntelligenceUnavailableReason)

    var isAvailable: Bool { backend != nil }

    var backend: AppleIntelligenceBackend? {
        if case .available(let backend) = self { return backend }
        return nil
    }

    var reason: AppleIntelligenceUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    var title: String {
        switch self {
        case .available(let backend): "Ready · \(backend.label)"
        case .unavailable(let reason): reason.title
        }
    }

    var detail: String {
        switch self {
        case .available(.privateCloudCompute):
            "Runs on Apple’s Private Cloud Compute: requests go only to Apple, aren’t stored, and aren’t visible to anyone, including Apple."
        case .available(.onDevice):
            "Runs entirely on this device. Nothing leaves your iPhone or iPad. The on-device model is small, so long discussions are summarized in more steps."
        case .unavailable(let reason):
            reason.detail
        }
    }
}

/// Raw availability read from the frameworks (or a fake), before choosing a backend.
struct AppleIntelligenceProbe: Equatable {
    enum ModelState: Equatable {
        case available
        case unavailable(AppleIntelligenceUnavailableReason)
    }

    /// `SystemLanguageModel.default`; nil below iOS 26 or without FoundationModels.
    var onDevice: ModelState?
    /// `PrivateCloudComputeLanguageModel`; nil below iOS 27 or in builds
    /// without `PCC_ENABLED` (no entitlement).
    var privateCloud: ModelState?
    /// `SystemLanguageModel.supportsLocale()` for the current locale.
    var localeSupported: Bool = true
}

enum AppleIntelligenceAvailability {
    /// Prefers Private Cloud Compute, falls back to the on-device model, and
    /// otherwise reports the most useful reason.
    static func resolve(_ probe: AppleIntelligenceProbe) -> AppleIntelligenceStatus {
        if probe.privateCloud == .available {
            return .available(.privateCloudCompute)
        }
        switch probe.onDevice {
        case .available:
            return probe.localeSupported ? .available(.onDevice) : .unavailable(.unsupportedLanguage)
        case .unavailable(let reason):
            return .unavailable(reason)
        case nil:
            if case .unavailable(let reason) = probe.privateCloud { return .unavailable(reason) }
            return .unavailable(.requiresNewerOS)
        }
    }
}

// MARK: - Default provider

enum AppleIntelligenceDefaults {
    /// UserDefaults flag: the new-user default was applied (or declined) once.
    static let appliedKey = "appleIntelligence.defaultApplied"

    /// The user never set up a provider: the stock OpenRouter selection, no
    /// keys, no edited configurations, no favorites.
    static func isUntouched(_ settings: AppSettings) -> Bool {
        guard settings.selectedProvider == .openRouter, settings.favoriteModels.isEmpty else {
            return false
        }
        return AIProvider.allCases.allSatisfy { provider in
            settings.configuration(for: provider) == ProviderConfiguration(provider: provider)
        }
    }

    /// Apple Intelligence becomes the selection only for a user who never
    /// configured a provider, only once, and only when it's usable now.
    static func shouldSelectAppleIntelligence(
        settings: AppSettings,
        status: AppleIntelligenceStatus,
        alreadyApplied: Bool
    ) -> Bool {
        !alreadyApplied && status.isAvailable && isUntouched(settings)
    }
}

// MARK: - Context budgets

/// Turns a model's context window (tokens) into character budgets. The
/// on-device model has a small window (4,096 tokens on iOS 26), so summaries
/// use small batches and more folding levels; Private Cloud Compute is larger.
enum AppleIntelligenceBudget {
    /// Conservative floor for the on-device window. (The SDK's back-deployed
    /// `contextSize` body returns 4,096 only where the OS lacks the symbol;
    /// the iOS 26.3 simulator runtime reported 8,192.)
    static let onDeviceFallbackTokens = 4_096
    /// Used when `PrivateCloudComputeLanguageModel.contextSize` can't be read.
    static let cloudFallbackTokens = 16_384
    /// Smallest batch worth sending.
    static let minimumBatchCharacters = 1_000
    /// Folding levels allowed for hierarchical summaries (hosted providers use 4).
    static let maxFoldLevels = 8

    /// Characters per token, estimated from the text: about 3 for Latin
    /// scripts and about 1 for CJK (conservative on both ends).
    static func charactersPerToken(sample: String) -> Double {
        var total = 0
        var wide = 0
        for scalar in sample.unicodeScalars.prefix(4_000) where !scalar.properties.isWhitespace {
            total += 1
            if isWide(scalar) { wide += 1 }
        }
        guard total > 0 else { return 3 }
        let wideShare = Double(wide) / Double(total)
        return 3 - 2 * wideShare
    }

    static func estimatedTokens(_ text: String, charactersPerToken: Double) -> Int {
        Int((Double(text.count) / max(0.5, charactersPerToken)).rounded(.up))
    }

    /// Tokens kept free for the reply (larger windows, e.g. Private Cloud
    /// Compute, allow longer replies).
    static func reservedOutputTokens(contextTokens: Int) -> Int {
        min(contextTokens >= 32_768 ? 8_192 : 2_048, max(256, contextTokens / 4))
    }

    /// Characters of prompt (instructions + messages) that fit with room for the reply.
    static func promptCharacters(contextTokens: Int, charactersPerToken: Double) -> Int {
        let usable = contextTokens - reservedOutputTokens(contextTokens: contextTokens) - 64
        // 10% margin for the chat template and the estimate's error.
        return max(400, Int(Double(max(0, usable)) * charactersPerToken * 0.9))
    }

    /// Hierarchical-summary batch size for this context window. Not clamped to
    /// `SummaryBatchLimit.minimum` (the on-device window is far below it).
    static func summaryBatchCharacters(
        contextTokens: Int,
        sample: String,
        systemPrompt: String
    ) -> Int {
        let perToken = charactersPerToken(sample: sample)
        let available = promptCharacters(contextTokens: contextTokens, charactersPerToken: perToken)
            - systemPrompt.count
        return min(SummaryBatchLimit.maximum, max(minimumBatchCharacters, available))
    }

    /// Forum-source characters for a chat answer, after the rest of the prompt.
    static func chatSourceCharacters(
        contextTokens: Int,
        sample: String,
        fixedCharacters: Int,
        userLimit: Int
    ) -> Int {
        let perToken = charactersPerToken(sample: sample)
        let available = promptCharacters(contextTokens: contextTokens, charactersPerToken: perToken)
            - fixedCharacters
        return min(userLimit, max(500, available))
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            true
        default:
            false
        }
    }
}

// MARK: - Errors

/// Every FoundationModels failure, mapped to a message a user can act on.
enum AppleIntelligenceError: LocalizedError, Equatable {
    case unavailable(AppleIntelligenceUnavailableReason)
    /// The request didn't fit the context window (retried with smaller input).
    case contextExceeded
    case guardrailViolation
    case refusal
    case unsupportedLanguage
    case rateLimited(Date?)
    case quotaReached(Date?)
    case busy
    case network
    case serviceUnavailable
    case timeout
    case modelNotReady
    /// Guided generation failed or isn't supported; callers fall back to text.
    case guidedGenerationFailed
    case unsupportedRequest
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "Apple Intelligence: \(reason.title). \(reason.detail)"
        case .contextExceeded:
            "This is too long for Apple Intelligence on this device, even in smaller parts. Try a shorter question, or choose a hosted provider in Settings › AI provider for very long discussions."
        case .guardrailViolation:
            "Apple Intelligence declined because the discussion touches content its safety guidelines don’t allow. Try another provider for this topic."
        case .refusal:
            "Apple Intelligence declined to answer this request. Rephrase it or try another provider."
        case .unsupportedLanguage:
            "Apple Intelligence doesn’t support this discussion’s language yet. Choose another provider in Settings › AI provider."
        case .rateLimited(let date):
            "Apple Intelligence is busy handling other requests\(Self.retryHint(date))."
        case .quotaReached(let date):
            "You’ve reached today’s Private Cloud Compute limit for this app\(Self.retryHint(date)). You can switch to another provider meanwhile."
        case .busy:
            "Apple Intelligence is still answering another request. Try again in a moment."
        case .network:
            "Couldn’t reach Apple’s Private Cloud Compute. Check your connection and try again."
        case .serviceUnavailable:
            "Apple’s Private Cloud Compute is unavailable right now. Try again later."
        case .timeout:
            "Apple Intelligence took too long to answer. Try again."
        case .modelNotReady:
            "The Apple Intelligence model isn’t ready yet (it may still be downloading). Try again in a few minutes."
        case .guidedGenerationFailed:
            "Apple Intelligence couldn’t produce a valid agent step."
        case .unsupportedRequest:
            "Apple Intelligence can’t handle this kind of request."
        case .other(let message):
            "Apple Intelligence failed: \(message)"
        }
    }

    private static func retryHint(_ date: Date?) -> String {
        guard let date, date > Date() else { return "; try again in a little while" }
        return "; try again after \(date.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Prompts

enum AppleIntelligencePrompt {
    static let omittedMarker = "[Earlier steps omitted to fit Apple Intelligence’s context window.]"
    static let trimmedMarker = "\n[…trimmed…]\n"

    /// A fresh `LanguageModelSession` is made per request, so the conversation
    /// is rendered into one prompt (callers always pass the full history).
    static func render(_ messages: [ChatMessage]) -> String {
        guard messages.count > 1 else { return messages.first?.content ?? "" }
        let turns = messages.dropLast().map { message in
            "\(message.role == .user ? "User" : "Assistant"):\n\(message.content)"
        }
        let last = messages[messages.count - 1]
        return "Conversation so far:\n\n" + turns.joined(separator: "\n\n")
            + "\n\n---\n\(last.role == .user ? "User" : "Assistant") (reply to this):\n\(last.content)"
    }

    /// Keeps the text's beginning and end.
    static func trimMiddle(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let room = max(0, limit - trimmedMarker.count)
        let head = room / 2
        let tail = room - head
        return String(text.prefix(head)) + trimmedMarker + String(text.suffix(tail))
    }

    /// Fits a conversation into `budget` characters: the first message (the
    /// goal or question) stays, newest messages are kept first, long ones are
    /// trimmed in the middle, and dropped ones are replaced by a marker.
    static func fit(_ messages: [ChatMessage], budget: Int) -> [ChatMessage] {
        let total = messages.reduce(0) { $0 + $1.content.count }
        guard total > budget, messages.count > 0 else { return messages }
        if messages.count == 1 {
            var only = messages[0]
            only.content = trimMiddle(only.content, to: budget)
            return [only]
        }
        var first = messages[0]
        first.content = trimMiddle(first.content, to: max(200, budget / 4))
        var remaining = budget - first.content.count - omittedMarker.count
        var kept: [ChatMessage] = []
        for message in messages.dropFirst().reversed() {
            guard remaining > 200 || kept.isEmpty else { break }
            var copy = message
            copy.content = trimMiddle(copy.content, to: max(200, remaining))
            remaining -= copy.content.count
            kept.insert(copy, at: 0)
        }
        let dropped = messages.count - 1 - kept.count
        var result = [first]
        if dropped > 0 {
            result.append(ChatMessage(role: .user, content: omittedMarker))
        }
        return result + kept
    }
}

enum AppleIntelligenceStreaming {
    /// Stream snapshots carry the whole text so far; this returns what's new.
    static func delta(previous: String, current: String) -> String {
        guard current.hasPrefix(previous) else {
            // The model revised earlier text (rare); append only past the common prefix.
            let common = zip(previous, current).prefix { $0 == $1 }.count
            return String(current.dropFirst(max(common, previous.count)))
        }
        return String(current.dropFirst(previous.count))
    }
}

// MARK: - Agent actions

/// A guided-generation action before it becomes an `AgentAction`.
struct AppleIntelligenceActionDraft: Equatable {
    struct Argument: Equatable {
        var name: String
        var value: String
    }

    var thought: String
    var tool: String
    var arguments: [Argument]

    /// Tool names offered to guided generation (`@Guide(.anyOf(...))`).
    static let toolNames = AgentPrompt.tools.map(\.name)

    func agentAction() throws -> AgentAction {
        let tool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { throw AgentActionParseError.missingTool }
        var values: [String: String] = [:]
        for argument in arguments {
            let name = argument.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            values[name] = argument.value
        }
        return AgentAction(thought: thought, tool: tool, arguments: values)
    }
}

// MARK: - Service seam

/// What `AIService` needs from Apple Intelligence; the real implementation is
/// `AppleIntelligenceClient`, tests pass a fake.
protocol AppleIntelligenceServing: AnyObject {
    func currentStatus() -> AppleIntelligenceStatus
    /// The backend's context window in tokens.
    func contextTokens(for backend: AppleIntelligenceBackend) async -> Int
    /// Streams a reply as deltas and returns the full text.
    func generate(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String,
        maxResponseTokens: Int,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String
    /// One agent action via guided generation; throws
    /// `AppleIntelligenceError.guidedGenerationFailed` when it can't.
    func generateAgentAction(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String
    ) async throws -> AppleIntelligenceActionDraft
}

extension AppleIntelligenceServing {
    /// The backend available now, or the reason there is none.
    func requireBackend() throws -> AppleIntelligenceBackend {
        let status = currentStatus()
        guard let backend = status.backend else {
            throw AppleIntelligenceError.unavailable(status.reason ?? .requiresNewerOS)
        }
        return backend
    }
}

// MARK: - App model glue

extension AppModel {
    /// Selects Apple Intelligence for a user who never configured a provider
    /// (once). Called when provider setup appears.
    func applyAppleIntelligenceDefaultIfNeeded(
        status: AppleIntelligenceStatus? = nil,
        defaults: UserDefaults = .standard
    ) {
        let alreadyApplied = defaults.bool(forKey: AppleIntelligenceDefaults.appliedKey)
        let status = status ?? appleIntelligenceStatus
        guard AppleIntelligenceDefaults.shouldSelectAppleIntelligence(
            settings: settings,
            status: status,
            alreadyApplied: alreadyApplied
        ) else {
            return
        }
        defaults.set(true, forKey: AppleIntelligenceDefaults.appliedKey)
        settings.selectedProvider = .appleIntelligence
    }
}

extension RunSettings {
    /// For Apple Intelligence, records which backend the job runs on
    /// ("On-device" / "Private Cloud Compute") as its model.
    static func resolvingAppleIntelligence(
        _ configuration: ProviderConfiguration,
        provider: AIProvider,
        status: @autoclosure () -> AppleIntelligenceStatus
    ) -> ProviderConfiguration {
        guard provider == .appleIntelligence, let backend = status().backend else { return configuration }
        var resolved = configuration
        resolved.model = backend.label
        return resolved
    }
}
