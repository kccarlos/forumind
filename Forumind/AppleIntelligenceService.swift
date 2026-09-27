import Foundation

// How `AIService` runs summaries, chat and agent steps on Apple Intelligence:
// budgets come from the model's context window, prompts are fitted to it, and
// a context overflow is retried with smaller input.

extension AIService {
    /// One reply: the conversation is fitted to the context window and
    /// rendered into a single prompt for a fresh session.
    func appleIntelligenceText(
        system: String,
        messages: [ChatMessage],
        maxTokens: Int,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let backend = try appleIntelligence.requireBackend()
        let (instructions, prompt, outputTokens) = await appleIntelligencePrompt(
            backend: backend,
            system: system,
            messages: messages,
            maxTokens: maxTokens
        )
        try Task.checkCancellation()
        let result = try await appleIntelligence.generate(
            backend: backend,
            instructions: instructions,
            prompt: prompt,
            maxResponseTokens: outputTokens,
            onDelta: onDelta
        )
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantError.emptyResponse
        }
        return result
    }

    private func appleIntelligencePrompt(
        backend: AppleIntelligenceBackend,
        system: String,
        messages: [ChatMessage],
        maxTokens: Int
    ) async -> (instructions: String, prompt: String, outputTokens: Int) {
        let contextTokens = await appleIntelligence.contextTokens(for: backend)
        let sample = system.suffix(2_000) + (messages.last?.content.prefix(2_000) ?? "")
        let perToken = AppleIntelligenceBudget.charactersPerToken(sample: String(sample))
        let budget = AppleIntelligenceBudget.promptCharacters(
            contextTokens: contextTokens,
            charactersPerToken: perToken
        )
        // Instructions keep at most 60% of the room; the conversation gets the rest.
        let instructions = AppleIntelligencePrompt.trimMiddle(system, to: budget * 6 / 10)
        let fitted = AppleIntelligencePrompt.fit(messages, budget: max(400, budget - instructions.count))
        let outputTokens = min(
            maxTokens,
            AppleIntelligenceBudget.reservedOutputTokens(contextTokens: contextTokens)
        )
        return (instructions, AppleIntelligencePrompt.render(fitted), outputTokens)
    }

    /// Hierarchical summary with batches sized from the context window; a
    /// context overflow retries with batches about half the size (twice).
    func appleIntelligenceSummary(
        content: String,
        configuration: ProviderConfiguration,
        customPrompt: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let backend = try appleIntelligence.requireBackend()
        let contextTokens = await appleIntelligence.contextTokens(for: backend)
        let system = PromptBuilder.summarySystem(custom: customPrompt)
        var batchLimit = AppleIntelligenceBudget.summaryBatchCharacters(
            contextTokens: contextTokens,
            sample: String(content.prefix(4_000)),
            systemPrompt: system
        )
        var attempt = 0
        while true {
            do {
                return try await hierarchicalSummary(
                    content: content,
                    configuration: configuration,
                    provider: .appleIntelligence,
                    customPrompt: customPrompt,
                    batchLimit: batchLimit,
                    maxLevel: AppleIntelligenceBudget.maxFoldLevels,
                    onDelta: onDelta
                )
            } catch AppleIntelligenceError.contextExceeded
                where attempt < 2 && batchLimit > AppleIntelligenceBudget.minimumBatchCharacters {
                attempt += 1
                batchLimit = max(AppleIntelligenceBudget.minimumBatchCharacters, batchLimit * 55 / 100)
                await onDelta("\n\n_Too long for one pass; retrying in smaller sections…_\n")
            }
        }
    }

    /// Chat answer with the forum source bounded to what fits; a context
    /// overflow retries once with half the source.
    func appleIntelligenceAnswer(
        source: String,
        summary: String,
        history: [ChatMessage],
        contextLimit: Int,
        customPrompt: String,
        configuration: ProviderConfiguration,
        onDelta: @escaping @MainActor (String) -> Void,
        summaryIsStale: Bool
    ) async throws -> String {
        let backend = try appleIntelligence.requireBackend()
        let contextTokens = await appleIntelligence.contextTokens(for: backend)
        let recent = Array(history.suffix(backend == .onDevice ? 6 : 24))
        let template = PromptBuilder.chatSystem(
            custom: customPrompt,
            source: "",
            summary: summary,
            summaryIsStale: summaryIsStale
        )
        let fixed = template.count + recent.reduce(0) { $0 + min($1.content.count, 1_500) }
        var sourceLimit = AppleIntelligenceBudget.chatSourceCharacters(
            contextTokens: contextTokens,
            sample: String(source.prefix(4_000)),
            fixedCharacters: fixed,
            userLimit: contextLimit
        )
        var retried = false
        while true {
            let bounded = PromptBuilder.boundedForumContext(source, limit: sourceLimit, minimum: 500)
            do {
                return try await appleIntelligenceText(
                    system: PromptBuilder.chatSystem(
                        custom: customPrompt,
                        source: bounded,
                        summary: summary,
                        summaryIsStale: summaryIsStale
                    ),
                    messages: recent,
                    maxTokens: 4_096,
                    onDelta: onDelta
                )
            } catch AppleIntelligenceError.contextExceeded where !retried && sourceLimit > 500 {
                retried = true
                sourceLimit = max(500, sourceLimit / 2)
            }
        }
    }

    /// One agent step: guided generation (`@Generable`) first, then the
    /// JSON-prompt parser if guided generation isn't possible.
    func appleIntelligenceAgentAction(
        system: String,
        transcript: [ChatMessage]
    ) async throws -> AgentAction {
        let backend = try appleIntelligence.requireBackend()
        let (instructions, prompt, _) = await appleIntelligencePrompt(
            backend: backend,
            system: system,
            messages: transcript,
            maxTokens: 1_024
        )
        do {
            let draft = try await appleIntelligence.generateAgentAction(
                backend: backend,
                instructions: instructions,
                prompt: prompt
            )
            return try draft.agentAction()
        } catch AppleIntelligenceError.guidedGenerationFailed {
            let reply = try await appleIntelligence.generate(
                backend: backend,
                instructions: instructions,
                prompt: prompt,
                maxResponseTokens: 1_024,
                onDelta: { _ in }
            )
            return try AgentActionParser.parse(reply)
        } catch is AgentActionParseError {
            throw AppleIntelligenceError.guidedGenerationFailed
        }
    }
}

/// Agent planner for Apple Intelligence (see `AIService.appleIntelligenceAgentAction`).
struct AppleIntelligenceAgentPlanner: AgentPlanner {
    let aiService: AIService

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        try await aiService.appleIntelligenceAgentAction(system: system, transcript: transcript)
    }
}
