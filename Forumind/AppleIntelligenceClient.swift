import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// The FoundationModels bridge for the Apple Intelligence provider.
//
// - iOS 17–25: FoundationModels isn't there; the provider reports
//   "Requires iOS 26 or later".
// - iOS 26+: `SystemLanguageModel` (on-device).
// - iOS 27+ in builds with `PCC_ENABLED` (DC_ENABLE_PCC=YES, which also adds
//   the `com.apple.developer.private-cloud-compute` entitlement):
//   `PrivateCloudComputeLanguageModel` first, on-device as the fallback.
//
// API reference: the iOS 27 SDK's FoundationModels.swiftinterface; see
// docs/APPLE_INTELLIGENCE.md.

final class AppleIntelligenceClient: AppleIntelligenceServing {
    static let shared = AppleIntelligenceClient()

    /// True in builds compiled with `-D PCC_ENABLED`.
    static var isPrivateCloudComputeCompiled: Bool {
        #if PCC_ENABLED
        true
        #else
        false
        #endif
    }

    func probe() -> AppleIntelligenceProbe {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelsBridge.probe()
        }
        #endif
        return AppleIntelligenceProbe(onDevice: nil, privateCloud: nil)
    }

    func currentStatus() -> AppleIntelligenceStatus {
        #if DEBUG
        if let forced = Self.debugStatus { return forced }
        #endif
        return AppleIntelligenceAvailability.resolve(probe())
    }

    #if DEBUG
    /// `-dc-apple-intelligence pcc|on-device|off|unsupported|downloading|language|old`
    /// forces a status for QA and screenshots (a forced "pcc" only changes
    /// the label; requests still need the real model).
    static let debugStatus: AppleIntelligenceStatus? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-dc-apple-intelligence"),
              index + 1 < arguments.count
        else { return nil }
        switch arguments[index + 1] {
        case "pcc": return .available(.privateCloudCompute)
        case "on-device": return .available(.onDevice)
        case "off": return .unavailable(.appleIntelligenceNotEnabled)
        case "unsupported": return .unavailable(.deviceNotEligible)
        case "downloading": return .unavailable(.modelNotReady)
        case "language": return .unavailable(.unsupportedLanguage)
        case "old": return .unavailable(.requiresNewerOS)
        default: return nil
        }
    }()
    #endif

    func contextTokens(for backend: AppleIntelligenceBackend) async -> Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await FoundationModelsBridge.contextTokens(for: backend)
        }
        #endif
        return AppleIntelligenceBudget.onDeviceFallbackTokens
    }

    func generate(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String,
        maxResponseTokens: Int,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                return try await FoundationModelsBridge.generate(
                    backend: backend,
                    instructions: instructions,
                    prompt: prompt,
                    maxResponseTokens: maxResponseTokens,
                    onDelta: onDelta
                )
            } catch {
                throw FoundationModelsBridge.mapped(error)
            }
        }
        #endif
        throw AppleIntelligenceError.unavailable(.requiresNewerOS)
    }

    func generateAgentAction(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String
    ) async throws -> AppleIntelligenceActionDraft {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                return try await FoundationModelsBridge.generateAgentAction(
                    backend: backend,
                    instructions: instructions,
                    prompt: prompt
                )
            } catch {
                throw FoundationModelsBridge.mapped(error)
            }
        }
        #endif
        throw AppleIntelligenceError.unavailable(.requiresNewerOS)
    }
}

#if canImport(FoundationModels)

/// Guided-generation schema for one agent step (`[String: String]` isn't
/// Generable, so arguments are name/value pairs).
@available(iOS 26.0, *)
@Generable(description: "The research agent's next step: one tool call.")
struct AppleIntelligenceGeneratedAction {
    @Guide(description: "One short sentence of reasoning for this step.")
    var thought: String

    @Guide(
        description: "The tool to call.",
        .anyOf([
            "search_forum", "list_latest", "read_topic", "summarize_topic",
            "saved_summaries", "watch_topic", "final_answer"
        ])
    )
    var tool: String

    @Guide(description: "The tool's arguments as name/value pairs, for example name \"query\" or \"topic_id\" or \"answer\". Empty when the tool takes none.")
    var arguments: [AppleIntelligenceGeneratedArgument]

    var draft: AppleIntelligenceActionDraft {
        AppleIntelligenceActionDraft(
            thought: thought,
            tool: tool,
            arguments: arguments.map { .init(name: $0.name, value: $0.value) }
        )
    }
}

@available(iOS 26.0, *)
@Generable(description: "One tool argument.")
struct AppleIntelligenceGeneratedArgument {
    @Guide(description: "Argument name, such as query, topic_id or answer.")
    var name: String
    @Guide(description: "Argument value as text.")
    var value: String
}

@available(iOS 26.0, *)
enum FoundationModelsBridge {
    static func probe() -> AppleIntelligenceProbe {
        let model = SystemLanguageModel.default
        var probe = AppleIntelligenceProbe(
            onDevice: state(model.availability),
            privateCloud: nil,
            localeSupported: model.supportsLocale()
        )
        #if PCC_ENABLED
        if #available(iOS 27.0, *) {
            probe.privateCloud = state(PrivateCloudComputeLanguageModel().availability)
        }
        #endif
        return probe
    }

    static func state(_ availability: SystemLanguageModel.Availability) -> AppleIntelligenceProbe.ModelState {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.modelNotReady)
            }
        }
    }

    @available(iOS 27.0, *)
    static func state(_ availability: PrivateCloudComputeLanguageModel.Availability) -> AppleIntelligenceProbe.ModelState {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .systemNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.modelNotReady)
            }
        }
    }

    static func contextTokens(for backend: AppleIntelligenceBackend) async -> Int {
        switch backend {
        case .onDevice:
            // Back-deployed: 4,096 before iOS 26.4, the model's real size after.
            return SystemLanguageModel.default.contextSize
        case .privateCloudCompute:
            #if PCC_ENABLED
            if #available(iOS 27.0, *),
               let size = try? await PrivateCloudComputeLanguageModel().contextSize,
               size > 0 {
                return size
            }
            #endif
            return AppleIntelligenceBudget.cloudFallbackTokens
        }
    }

    /// A new session per request (callers pass the whole conversation).
    /// Summaries and chat transform the user's own content, so the
    /// on-device model uses the permissive content-transformation guardrails.
    static func session(
        backend: AppleIntelligenceBackend,
        instructions: String,
        permissive: Bool
    ) -> LanguageModelSession {
        #if PCC_ENABLED
        if backend == .privateCloudCompute, #available(iOS 27.0, *) {
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: Instructions(instructions)
            )
        }
        #endif
        let model = permissive
            ? SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            : SystemLanguageModel.default
        return LanguageModelSession(model: model, instructions: Instructions(instructions))
    }

    static func generate(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String,
        maxResponseTokens: Int,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let session = session(backend: backend, instructions: instructions, permissive: true)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: maxResponseTokens)
        let stream = session.streamResponse(to: prompt, options: options)
        var text = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            let current: String = snapshot.content
            let delta = AppleIntelligenceStreaming.delta(previous: text, current: current)
            text = current
            if !delta.isEmpty { await onDelta(delta) }
        }
        try Task.checkCancellation()
        return text
    }

    static func generateAgentAction(
        backend: AppleIntelligenceBackend,
        instructions: String,
        prompt: String
    ) async throws -> AppleIntelligenceActionDraft {
        let session = session(backend: backend, instructions: instructions, permissive: false)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 1_024)
        let response = try await session.respond(
            to: prompt,
            generating: AppleIntelligenceGeneratedAction.self,
            options: options
        )
        try Task.checkCancellation()
        return response.content.draft
    }

    /// Maps FoundationModels errors (iOS 26 `GenerationError`, iOS 27
    /// `LanguageModelError` and friends) to `AppleIntelligenceError`.
    static func mapped(_ error: Error) -> Error {
        if error is CancellationError || error is AppleIntelligenceError { return error }
        if #available(iOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return AppleIntelligenceError.contextExceeded
                case .rateLimited(let info): return AppleIntelligenceError.rateLimited(info.resetDate)
                case .guardrailViolation: return AppleIntelligenceError.guardrailViolation
                case .refusal: return AppleIntelligenceError.refusal
                case .unsupportedGenerationGuide: return AppleIntelligenceError.guidedGenerationFailed
                case .unsupportedCapability, .unsupportedTranscriptContent:
                    return AppleIntelligenceError.unsupportedRequest
                case .unsupportedLanguageOrLocale: return AppleIntelligenceError.unsupportedLanguage
                case .timeout: return AppleIntelligenceError.timeout
                @unknown default: return AppleIntelligenceError.other(error.localizedDescription)
                }
            }
            if error is LanguageModelSession.Error { return AppleIntelligenceError.busy }
            if error is SystemLanguageModel.Error { return AppleIntelligenceError.modelNotReady }
            if error is GeneratedContent.ParsingError { return AppleIntelligenceError.guidedGenerationFailed }
            if let error = error as? PrivateCloudComputeLanguageModel.Error {
                switch error {
                case .networkFailure: return AppleIntelligenceError.network
                case .quotaLimitReached(let info): return AppleIntelligenceError.quotaReached(info.resetDate)
                case .serviceUnavailable: return AppleIntelligenceError.serviceUnavailable
                @unknown default: return AppleIntelligenceError.other(error.localizedDescription)
                }
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            return mapped(generationError: error)
        }
        return AppleIntelligenceError.other(error.localizedDescription)
    }

    static func mapped(generationError error: LanguageModelSession.GenerationError) -> AppleIntelligenceError {
        switch error {
        case .exceededContextWindowSize: .contextExceeded
        case .assetsUnavailable: .modelNotReady
        case .guardrailViolation: .guardrailViolation
        case .unsupportedGuide, .decodingFailure: .guidedGenerationFailed
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .rateLimited: .rateLimited(nil)
        case .concurrentRequests: .busy
        case .refusal: .refusal
        @unknown default: .other(error.localizedDescription)
        }
    }
}

#endif
