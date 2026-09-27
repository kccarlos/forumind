import Foundation
import UniformTypeIdentifiers

/// What the host app shared, resolved from the extension's input items.
struct SharedPage: Equatable {
    enum Detection: Equatable {
        /// Safari's preprocessing JS found Discourse markers.
        case discourse(forumName: String)
        /// Safari's preprocessing JS ran and found none.
        case notDetected
        /// Only a URL or text arrived (Chrome, other apps): can't tell yet.
        case unknown
    }

    var url: URL
    var title: String?
    var detection: Detection

    var host: String {
        url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return host
    }
}

enum SharedPageLoader {
    private static let propertyListType = UTType.propertyList.identifier
    private static let urlType = UTType.url.identifier
    private static let textType = UTType.plainText.identifier

    /// Resolves the shared page, preferring Safari's JS probe results, then a
    /// URL attachment, then a URL found in shared text. Calls back on main.
    static func load(
        from inputItems: [Any],
        completion: @escaping (SharedPage?) -> Void
    ) {
        let items = inputItems.compactMap { $0 as? NSExtensionItem }
        let providers = items.flatMap { $0.attachments ?? [] }
        let itemTitle = items.lazy.compactMap { item -> String? in
            let text = item.attributedTitle?.string ?? item.attributedContentText?.string
            return cleanTitle(text)
        }.first

        Task {
            let page = await resolve(providers: providers, itemTitle: itemTitle)
            await MainActor.run { completion(page) }
        }
    }

    private static func resolve(
        providers: [NSItemProvider],
        itemTitle: String?
    ) async -> SharedPage? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(propertyListType) {
            if let page = await probePage(from: provider) {
                return page
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(urlType) {
            if let url = await loadURL(from: provider), IncomingLink.isWebURL(url) {
                return SharedPage(url: url, title: itemTitle, detection: .unknown)
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(textType) {
            guard let text = await loadText(from: provider),
                  let url = IncomingLink.extractWebURL(from: text)
            else {
                continue
            }
            let remainder = text.replacingOccurrences(of: url.absoluteString, with: " ")
            return SharedPage(
                url: url,
                title: itemTitle ?? cleanTitle(remainder),
                detection: .unknown
            )
        }
        return nil
    }

    private static func probePage(from provider: NSItemProvider) async -> SharedPage? {
        guard let item = await loadItem(from: provider, type: propertyListType),
              let dictionary = item as? NSDictionary,
              let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
              let urlString = results["url"] as? String,
              let url = URL(string: urlString),
              IncomingLink.isWebURL(url)
        else {
            return nil
        }
        let title = cleanTitle(results["title"] as? String)
        let isDiscourse = (results["isDiscourse"] as? Bool) ?? false
        var page = SharedPage(url: url, title: title, detection: .notDetected)
        if isDiscourse {
            let forumName = cleanTitle(results["forumName"] as? String) ?? page.host
            page.detection = .discourse(forumName: forumName)
        }
        return page
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        let item = await loadItem(from: provider, type: urlType)
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        let item = await loadItem(from: provider, type: textType)
        if let string = item as? String { return string }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let attributed = item as? NSAttributedString { return attributed.string }
        return nil
    }

    private static func loadItem(
        from provider: NSItemProvider,
        type: String
    ) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    private static func cleanTitle(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(300))
    }
}
