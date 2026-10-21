import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: - Translate (iOS 18+, on the device)
//
// `TranslateButton` sits next to Copy / Share / Listen on summaries, agent
// answers and digest cards; the browser's menu translates the posts on
// screen (`PostsTranslationSheet`). Both open `TranslationSheet`, which
// translates with a `TranslationSession` from `.translationTask` into the
// reading language. The page itself is never rewritten. On iOS 17 there is
// no button.

/// One block of text to translate: a summary, or one post.
struct TranslationSource: Identifiable, Equatable {
    var id: String
    /// Shown above the text ("#12 · alice"); nil for a single summary.
    var heading: String?
    /// Markdown or plain text.
    var text: String
}

/// The Translate button. Hidden on iOS 17, and when the text is already in
/// the reading language.
struct TranslateButton: View {
    @ObservedObject var app: AppModel
    let title: String
    let text: String
    var compact = false
    @State private var offers = false
    @State private var presented = false

    private var readingLanguage: String { ReadingLanguage.resolved(app.settings.readingLanguage) }

    var body: some View {
        Group {
            if offers {
                Button {
                    DCHaptics.tap()
                    presented = true
                } label: {
                    if compact {
                        Image(systemName: "translate")
                    } else {
                        Label("Translate", systemImage: "translate")
                    }
                }
                .accessibilityLabel(Text("Translate", comment: "Button: translates the text into the reading language on the device"))
                .accessibilityIdentifier("translate")
                .sheet(isPresented: $presented) {
                    TranslationSheet(
                        title: title,
                        sources: [TranslationSource(id: "text", text: text)],
                        target: readingLanguage
                    )
                }
            }
        }
        // Detecting the language is quick but not free: once per text.
        .task(id: "\(readingLanguage)|\(text.hashValue)") {
            let text = text
            let target = readingLanguage
            offers = await Task.detached(priority: .utility) {
                ReadingLanguage.offersTranslation(of: text, into: target)
            }.value
        }
    }
}

/// Translates the sources into `target` and shows them, each with its
/// original a tap away.
struct TranslationSheet: View {
    let title: String
    let sources: [TranslationSource]
    let target: String

    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 18, *) {
                    TranslationContent(sources: sources, target: target)
                } else {
                    ContentUnavailableView("Translation needs iOS 18", systemImage: "translate")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DismissButton()
                }
            }
        }
    }

    private struct DismissButton: View {
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            Button("Done") { dismiss() }
                .accessibilityIdentifier("translationDone")
        }
    }
}

/// The translations' states; the result is one string per source.
enum TranslationPhase: Equatable {
    case checking
    case translating
    case done([String: String])
    case failed(String)
}

@available(iOS 18, *)
private struct TranslationContent: View {
    let sources: [TranslationSource]
    let target: String
    @State private var phase: TranslationPhase = .checking
    @State private var configuration: TranslationSession.Configuration?
    @State private var showsOriginal: Set<String> = []

    private var sourceLanguage: String? {
        ReadingLanguage.detect(sources.map(\.text).joined(separator: "\n"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                switch phase {
                case .checking, .translating:
                    HStack(spacing: DCTheme.spacingS) {
                        ProgressView()
                        Text("Translating…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, DCTheme.spacingXL)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t translate", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(message)
                    }
                case .done(let translations):
                    ForEach(sources) { source in
                        section(source, translated: translations[source.id] ?? source.text)
                    }
                    Text(footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(DCTheme.spacingL)
        }
        .accessibilityIdentifier("translationSheet")
        .task { await prepare() }
        .translationTask(configuration) { session in
            await translate(with: session)
        }
    }

    private var footer: String {
        let to = ReadingLanguage.displayName(target)
        if let from = sourceLanguage {
            return String(localized: "Translated on this device from \(ReadingLanguage.displayName(from)) to \(to).", comment: "Translation sheet footer; the placeholders are language names")
        }
        return String(localized: "Translated on this device to \(to).", comment: "Translation sheet footer; the placeholder is a language name")
    }

    private func section(_ source: TranslationSource, translated: String) -> some View {
        let original = showsOriginal.contains(source.id)
        return VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            HStack {
                if let heading = source.heading {
                    Text(heading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DCTheme.spacingS)
                Button(original ? String(localized: "Show translation") : String(localized: "Show original")) {
                    if original { showsOriginal.remove(source.id) } else { showsOriginal.insert(source.id) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
            MarkdownView(original ? source.text : translated)
                .textSelection(.enabled)
        }
        .dcCard()
    }

    /// Unsupported pairs get a clear message here; a supported language
    /// that isn't downloaded yet is asked for by the system on the first
    /// request.
    private func prepare() async {
        let targetLanguage = Locale.Language(identifier: target)
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let source = sourceLanguage {
            status = await availability.status(from: Locale.Language(identifier: source), to: targetLanguage)
        } else if let detected = try? await availability.status(for: sources.map(\.text).joined(separator: "\n"), to: targetLanguage) {
            status = detected
        } else {
            status = .supported
        }
        guard status != .unsupported else {
            phase = .failed(unsupportedMessage)
            return
        }
        phase = .translating
        configuration = TranslationSession.Configuration(
            source: sourceLanguage.map { Locale.Language(identifier: $0) },
            target: targetLanguage
        )
    }

    private var unsupportedMessage: String {
        let to = ReadingLanguage.displayName(target)
        if let from = sourceLanguage {
            return String(localized: "Translating from \(ReadingLanguage.displayName(from)) to \(to) isn’t available on this device.", comment: "Translation error; the placeholders are language names")
        }
        return String(localized: "Translating this text to \(to) isn’t available on this device.", comment: "Translation error; the placeholder is a language name")
    }

    private func translate(with session: TranslationSession) async {
        var segmentsBySource: [String: [TranslationText.Segment]] = [:]
        var requests: [TranslationSession.Request] = []
        for source in sources {
            let segments = TranslationText.segments(of: source.text)
            segmentsBySource[source.id] = segments
            for request in TranslationText.requests(segments) {
                requests.append(TranslationSession.Request(sourceText: request.text, clientIdentifier: "\(source.id)\u{1F}\(request.index)"))
            }
        }
        guard !requests.isEmpty else {
            phase = .done(Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.text) }))
            return
        }
        do {
            let responses = try await session.translations(from: requests)
            var translated: [String: [Int: String]] = [:]
            for response in responses {
                let parts = (response.clientIdentifier ?? "").split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                guard parts.count == 2, let index = Int(parts[1]) else { continue }
                translated[parts[0], default: [:]][index] = response.targetText
            }
            phase = .done(Dictionary(uniqueKeysWithValues: sources.map { source in
                (source.id, TranslationText.assemble(segmentsBySource[source.id] ?? [], translations: translated[source.id] ?? [:]))
            }))
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .unsupportedSourceLanguage, .unsupportedTargetLanguage, .unsupportedLanguagePairing:
                return unsupportedMessage
            case .unableToIdentifyLanguage:
                return String(localized: "The text’s language couldn’t be identified.")
            default:
                break
            }
        }
        if error is CancellationError || (error as NSError).code == NSUserCancelledError {
            return String(localized: "The translation was cancelled. To translate, allow the language download when iOS asks.")
        }
        return error.localizedDescription
    }
}

// MARK: - Posts on screen

/// The browser menu's Translate Posts on Screen: reads the visible posts'
/// text through the browser bridge (without hidden posts), then translates
/// them. The page is left as it is.
struct PostsTranslationSheet: View {
    @ObservedObject var app: AppModel
    @State private var sources: [TranslationSource]?

    private var target: String { ReadingLanguage.resolved(app.settings.readingLanguage) }

    var body: some View {
        if let sources {
            // Posts already in the reading language are left out.
            let foreign = ReadingLanguage.needingTranslation(sources, into: target)
            if foreign.isEmpty {
                NavigationStack {
                    Group {
                        if sources.isEmpty {
                            ContentUnavailableView("No posts are on screen", systemImage: "text.bubble")
                        } else {
                            ContentUnavailableView(
                                String(localized: "These posts are already in \(ReadingLanguage.displayName(target)).", comment: "Translate Posts on Screen; the placeholder is a language name"),
                                systemImage: "checkmark.bubble"
                            )
                        }
                    }
                    .navigationTitle(String(localized: "Translate posts"))
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                TranslationSheet(title: String(localized: "Translate posts"), sources: foreign, target: target)
            }
        } else {
            ProgressView()
                .task {
                    sources = await app.postsToTranslate().map { post in
                        TranslationSource(id: "\(post.number)", heading: "#\(post.number) · \(post.username)", text: post.text)
                    }
                }
        }
    }
}
