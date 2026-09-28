import Foundation

/// Not final so tests can stand in for the provider (streams, gated answers).
class AIService {
    private let session: URLSession
    /// The Apple Intelligence provider (FoundationModels); tests pass a fake.
    let appleIntelligence: AppleIntelligenceServing

    init(
        session: URLSession = .shared,
        appleIntelligence: AppleIntelligenceServing = AppleIntelligenceClient.shared
    ) {
        self.session = session
        self.appleIntelligence = appleIntelligence
    }

    func generateSummary(
        content: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        customPrompt: String,
        batchLimit: Int = SummaryBatchLimit.default,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        if provider == .appleIntelligence {
            return try await appleIntelligenceSummary(
                content: content,
                configuration: configuration,
                customPrompt: customPrompt,
                onDelta: onDelta,
                onProgress: onProgress
            )
        }
        return try await hierarchicalSummary(
            content: content,
            configuration: configuration,
            provider: provider,
            customPrompt: customPrompt,
            batchLimit: SummaryBatchLimit.normalized(batchLimit),
            maxLevel: 4,
            onDelta: onDelta,
            onProgress: onProgress
        )
    }

    /// Summarizes in one request, or in batches of `batchLimit` characters
    /// whose summaries are folded (up to `maxLevel` levels) and combined.
    func hierarchicalSummary(
        content: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        customPrompt: String,
        batchLimit: Int,
        maxLevel: Int,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        let chunks = PromptBuilder.splitForHierarchicalSummary(content, limit: batchLimit)
        if chunks.count == 1 {
            await onProgress(.finalStarted(combining: false))
            return try await streamText(
                system: PromptBuilder.summarySystem(custom: customPrompt),
                messages: [ChatMessage(role: .user, content: content)],
                configuration: configuration,
                provider: provider,
                onDelta: Self.counting(onDelta, onProgress: onProgress)
            )
        }

        // Summarize each batch, then keep folding the batch summaries until they
        // fit a single request; very long discussions need more than one level.
        var partials = try await summarizeBatches(
            chunks,
            level: 1,
            configuration: configuration,
            provider: provider,
            onDelta: onDelta,
            onProgress: onProgress
        )
        var level = 2
        // Bounded so a model that answers at length cannot fold indefinitely.
        while level <= maxLevel,
              partials.count > 1,
              partials.joined(separator: "\n\n---\n\n").count > batchLimit {
            let regrouped = PromptBuilder.splitForHierarchicalSummary(
                partials.joined(separator: "\n\n---\n\n"),
                limit: batchLimit
            )
            partials = try await summarizeBatches(
                regrouped,
                level: level,
                configuration: configuration,
                provider: provider,
                onDelta: onDelta,
                onProgress: onProgress
            )
            level += 1
        }

        let combining = String(localized: "Combining section summaries…", comment: "Shown in a long summary while the section summaries are merged")
        await onDelta("\n\n_\(combining)_\n")
        await onProgress(.finalStarted(combining: true))
        return try await streamText(
            system: PromptBuilder.summarySystem(custom: customPrompt),
            messages: [
                ChatMessage(
                    role: .user,
                    content: "Create the final summary from these intermediate summaries:\n\n"
                        + partials.joined(separator: "\n\n---\n\n")
                )
            ],
            configuration: configuration,
            provider: provider,
            onDelta: Self.counting(onDelta, onProgress: onProgress)
        )
    }

    /// Passes deltas through and reports how many characters have arrived.
    private static func counting(
        _ onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void
    ) -> @MainActor (String) -> Void {
        let received = StreamedCharacters()
        return { delta in
            onDelta(delta)
            received.count += delta.count
            onProgress(.streamed(characters: received.count))
        }
    }

    private func summarizeBatches(
        _ chunks: [String],
        level: Int,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void
    ) async throws -> [String] {
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let reading = level == 1
                ? String(localized: "Reading section \(index + 1) of \(chunks.count)…", comment: "Shown in a long summary while each section of the discussion is summarized")
                : String(localized: "Reading level \(level) section \(index + 1) of \(chunks.count)…", comment: "Shown in a very long summary while section summaries are condensed again; level is 2, 3, …")
            await onDelta("\n\n_\(reading)_\n")
            await onProgress(.batchStarted(level: level, index: index, count: chunks.count))
            let partial = try await streamText(
                system: PromptBuilder.chunkPrompt,
                messages: [ChatMessage(role: .user, content: chunk)],
                configuration: configuration,
                provider: provider,
                // Batch text is not shown; its length still moves the bar.
                onDelta: Self.counting({ _ in }, onProgress: onProgress)
            )
            partials.append(partial)
            await onProgress(.batchFinished(level: level, index: index, count: chunks.count))
        }
        return partials
    }

    func answer(
        source: String,
        summary: String,
        history: [ChatMessage],
        contextLimit: Int,
        customPrompt: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        onDelta: @escaping @MainActor (String) -> Void,
        summaryIsStale: Bool = false
    ) async throws -> String {
        if provider == .appleIntelligence {
            return try await appleIntelligenceAnswer(
                source: source,
                summary: summary,
                history: history,
                contextLimit: contextLimit,
                customPrompt: customPrompt,
                configuration: configuration,
                onDelta: onDelta,
                summaryIsStale: summaryIsStale
            )
        }
        let boundedSource = PromptBuilder.boundedForumContext(source, limit: contextLimit)
        return try await streamText(
            system: PromptBuilder.chatSystem(
                custom: customPrompt,
                source: boundedSource,
                summary: summary,
                summaryIsStale: summaryIsStale
            ),
            messages: Array(history.suffix(24)),
            configuration: configuration,
            provider: provider,
            maxTokens: 4_096,
            onDelta: onDelta
        )
    }

    /// One non-streamed completion; used by the agent planner.
    func complete(
        system: String,
        messages: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int = 4_096
    ) async throws -> String {
        try await streamText(
            system: system,
            messages: messages,
            configuration: configuration,
            provider: provider,
            maxTokens: maxTokens,
            onDelta: { _ in }
        )
    }

    func discoverModels(
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> [String] {
        if provider == .appleIntelligence {
            // No model list: the system picks the backend.
            let backend = try appleIntelligence.requireBackend()
            return [backend.label]
        }
        let base = normalizedBaseURL(configuration.baseURL)
        var request: URLRequest

        switch provider {
        case .gemini:
            guard var components = URLComponents(string: "\(base)/models") else {
                throw AssistantError.invalidResponse
            }
            components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
            guard let url = components.url else { throw AssistantError.invalidResponse }
            request = URLRequest(url: url)
        case .ollama:
            guard let url = URL(string: "\(base)/api/tags") else {
                throw AssistantError.invalidResponse
            }
            request = URLRequest(url: url)
        default:
            guard let url = URL(string: "\(base)/models") else {
                throw AssistantError.invalidResponse
            }
            request = URLRequest(url: url)
            applyAuthentication(
                to: &request,
                configuration: configuration,
                provider: provider
            )
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AssistantError.invalidResponse
        }

        let models: [String]
        if provider == .gemini {
            models = (json["models"] as? [[String: Any]] ?? [])
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        } else if provider == .ollama {
            models = (json["models"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
        } else {
            models = (json["data"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
        }
        return Array(Set(models)).sorted()
    }

    func testConnection(
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws {
        if provider.requiresAPIKey && configuration.apiKey.isEmpty {
            throw AssistantError.missingConfiguration(String(localized: "\(provider.displayName) API key is required.", comment: "Error; the placeholder is the AI provider's name"))
        }
        _ = try await discoverModels(configuration: configuration, provider: provider)
    }

    func streamText(
        system: String,
        messages: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int = 16_384,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        if provider == .appleIntelligence {
            return try await appleIntelligenceText(
                system: system,
                messages: messages,
                maxTokens: maxTokens,
                onDelta: onDelta
            )
        }
        try validate(configuration: configuration, provider: provider)
        var tokenBudgets: [Int] = [
            maxTokens,
            min(maxTokens, 4_096),
            min(maxTokens, 2_048),
            min(maxTokens, 1_024)
        ]
        tokenBudgets = tokenBudgets.reduce(into: []) { budgets, value in
            if !budgets.contains(value) { budgets.append(value) }
        }
        var budgetIndex = 0

        while true {
            let requestedMaxTokens = tokenBudgets[budgetIndex]
            let request = try makeRequest(
                system: system,
                messages: messages,
                configuration: configuration,
                provider: provider,
                maxTokens: requestedMaxTokens
            )
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AssistantError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines {
                    body += line
                    if body.count > 1_000 { break }
                }
                let detail = body.isEmpty
                    ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    : String(body.prefix(1_000))
                let indicatesTokenBudget = detail.localizedCaseInsensitiveContains("max_tokens")
                    || detail.localizedCaseInsensitiveContains("max output")
                if http.statusCode == 402,
                   budgetIndex + 1 < tokenBudgets.count,
                   indicatesTokenBudget
                {
                    budgetIndex += 1
                    continue
                }
                throw AssistantError.http(http.statusCode, detail)
            }

            var result = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let delta = parseDelta(line: line, provider: provider), !delta.isEmpty else {
                    continue
                }
                result += delta
                await onDelta(delta)
            }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssistantError.emptyResponse
            }
            return result
        }
    }

    private func makeRequest(
        system: String,
        messages: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int
    ) throws -> URLRequest {
        let base = normalizedBaseURL(configuration.baseURL)
        let url: URL
        var body: [String: Any]

        switch provider {
        case .anthropic:
            guard let endpoint = URL(string: "\(base)/messages") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "max_tokens": maxTokens,
                "system": system,
                "stream": true,
                "messages": messages.map {
                    ["role": $0.role.rawValue, "content": $0.content]
                }
            ]

        case .gemini:
            let escapedModel = configuration.model.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? configuration.model
            guard var components = URLComponents(
                string: "\(base)/models/\(escapedModel):streamGenerateContent"
            ) else {
                throw AssistantError.invalidResponse
            }
            components.queryItems = [
                URLQueryItem(name: "alt", value: "sse"),
                URLQueryItem(name: "key", value: configuration.apiKey)
            ]
            guard let endpoint = components.url else { throw AssistantError.invalidResponse }
            url = endpoint
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": messages.map {
                    [
                        "role": $0.role == .assistant ? "model" : "user",
                        "parts": [["text": $0.content]]
                    ]
                },
                "generationConfig": [
                    "temperature": 0.2,
                    "maxOutputTokens": maxTokens
                ]
            ]

        case .ollama:
            guard let endpoint = URL(string: "\(base)/api/chat") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "stream": true,
                "options": ["num_predict": maxTokens],
                "messages": [["role": "system", "content": system]]
                    + messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }
            ]

        default:
            guard let endpoint = URL(string: "\(base)/chat/completions") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "temperature": 0.2,
                "stream": true,
                "max_tokens": maxTokens,
                "messages": [["role": "system", "content": system]]
                    + messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Some OpenAI-compatible hosts (NVIDIA NIM) buffer the whole reply
        // unless the client explicitly accepts server-sent events.
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyAuthentication(
            to: &request,
            configuration: configuration,
            provider: provider
        )
        return request
    }

    private func validate(
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) throws {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AssistantError.missingConfiguration(String(localized: "Choose a model in Settings."))
        }
        guard URL(string: configuration.baseURL) != nil else {
            throw AssistantError.missingConfiguration(String(localized: "Enter a valid provider URL."))
        }
        if provider.requiresAPIKey && configuration.apiKey.isEmpty {
            throw AssistantError.missingConfiguration(
                String(localized: "\(provider.displayName) API key is required. Add it in Settings › AI models.", comment: "Error; the placeholder is the AI provider's name. Settings › AI models names the app's own Settings pages.")
            )
        }
    }

    private func applyAuthentication(
        to request: inout URLRequest,
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) {
        switch provider {
        case .anthropic:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini, .ollama, .lmStudio:
            break
        default:
            request.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }
        if provider == .openRouter {
            request.setValue(
                "https://github.com/kccarlos/forumind",
                forHTTPHeaderField: "HTTP-Referer"
            )
            request.setValue("Forumind", forHTTPHeaderField: "X-Title")
        }
    }

    private func normalizedBaseURL(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private func parseDelta(line: String, provider: AIProvider) -> String? {
        var payload = line
        if payload.hasPrefix("data:") {
            payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        switch provider {
        case .anthropic:
            return ((json["delta"] as? [String: Any])?["text"] as? String)
        case .gemini:
            let candidates = json["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            return parts?.compactMap { $0["text"] as? String }.joined()
        case .ollama:
            return ((json["message"] as? [String: Any])?["content"] as? String)
        default:
            let choices = json["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return delta?["content"] as? String
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AssistantError.http(http.statusCode, String(detail.prefix(500)))
        }
    }
}

/// Characters a summary request has streamed so far (only touched by the
/// main-actor delta closure).
private final class StreamedCharacters: @unchecked Sendable {
    var count = 0
}
