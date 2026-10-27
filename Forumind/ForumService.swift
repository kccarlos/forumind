import Foundation

/// A forum's name and icon, as its adapter reads them.
struct ForumSiteInfo: Equatable {
    var name: String
    var iconURL: URL?
}

/// Keeps a forum's cookies on that forum across redirects. URLSession copies
/// a hand-set `Cookie` header onto the redirected request, so a redirect to
/// another origin (another host, port, or an https → http downgrade) is
/// followed without the `Cookie` and `Authorization` headers.
final class ForumRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ForumRedirectGuard()

    /// The request to follow when `original` redirects to `redirect`.
    static func redirectRequest(_ redirect: URLRequest, from original: URLRequest?) -> URLRequest {
        let sameOrigin: Bool = {
            guard let from = original?.url.flatMap(ForumSite.origin(of:)),
                  let to = redirect.url.flatMap(ForumSite.origin(of:))
            else {
                return false
            }
            return from.origin == to.origin
        }()
        guard !sameOrigin else { return redirect }
        var stripped = redirect
        stripped.setValue(nil, forHTTPHeaderField: "Cookie")
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        stripped.httpShouldHandleCookies = false
        return stripped
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirectRequest(request, from: task.currentRequest ?? task.originalRequest))
    }
}


/// A successful forum response: the body and the headers (lowercased names),
/// for adapters that read paging totals from them (`X-WP-Total`).
struct ForumHTTPResponse: Sendable {
    var data: Data
    var headers: [String: String]
}

/// The shared transport: one paced, retried GET of a forum URL. It knows no
/// platform; adapters build URLs and parse responses on top of it (through
/// `SiteNetwork`). Every request is paced per host (`ForumRequestPacer`, see
/// ForumRequestPacing.swift) with the pace the job started with.
final class ForumService: Sendable {
    private let session: URLSession
    /// `429`s retried per request.
    private let maximumRetries = 6
    /// Dropped connections, timeouts and gateway errors retried per request,
    /// after 1, 2 and 4 seconds.
    private let maximumTransientRetries = 3
    /// Shared by every request this service makes, so pacing covers all
    /// jobs, agent tools and watch checks on the same forum together.
    let pacer: ForumRequestPacer
    /// Longest wait for a request made inside the forum page (whose script
    /// gives up after 60 s itself); after it the request goes out directly.
    let resourceLoaderTimeout: Duration

    init(
        session: URLSession = .shared,
        pacer: ForumRequestPacer = ForumRequestPacer(),
        resourceLoaderTimeout: Duration = .seconds(75)
    ) {
        self.session = session
        self.pacer = pacer
        self.resourceLoaderTimeout = resourceLoaderTimeout
    }

    /// The `Accept` header of a request that names none.
    static let defaultAccept = "text/html,application/json;q=0.9,*/*;q=0.8"

    /// One forum request, paced per host. A `429` gives the slot back, pushes
    /// the host's next start back by `Retry-After` (or an exponential
    /// backoff) and tries again, up to `maximumRetries` times. The one request
    /// path: adapters reach it through `SiteNetwork.data` and `.response`.
    func response(_ url: URL, accept: String? = nil, context: SiteRequestContext) async throws -> ForumHTTPResponse {
        let pace = context.pace
        var rateLimited = 0
        var transient = 0
        while true {
            try Task.checkCancellation()
            let host = try await pacer.acquire(for: url, pace: pace)
            let outcome: Outcome
            do {
                outcome = try await attemptRequest(url: url, accept: accept, context: context)
            } catch {
                if !Task.isCancelled, transient < maximumTransientRetries,
                   NetworkFailure.classify(error) == .transient {
                    // A dropped or slow connection: try again shortly (the
                    // pause is the host's, like a 429's).
                    transient += 1
                    await pacer.release(host, backOff: pow(2, Double(transient - 1)))
                    continue
                }
                await pacer.release(host)
                throw error
            }

            switch outcome {
            case .success(let response):
                await pacer.release(host)
                return response
            case .failure(let status, let detail, let retryAfter):
                if status == 429 && rateLimited < maximumRetries {
                    // The back-off is in place before the slot passes on:
                    // a request waiting for it must not start inside it.
                    rateLimited += 1
                    let wait = Double(retryAfter ?? "") ?? pow(2, Double(rateLimited))
                    await pacer.release(host, backOff: min(60, max(1, wait)))
                    continue
                }
                if NetworkFailure.gatewayStatuses.contains(status), transient < maximumTransientRetries {
                    transient += 1
                    await pacer.release(host, backOff: pow(2, Double(transient - 1)))
                    continue
                }
                await pacer.release(host)
                throw AssistantError.http(status, String(detail.prefix(300)))
            }
        }
    }

    /// Same request as `response`, the body only.
    func data(_ url: URL, accept: String? = nil, context: SiteRequestContext) async throws -> Data {
        try await response(url, accept: accept, context: context).data
    }

    private enum Outcome {
        case success(ForumHTTPResponse)
        case failure(status: Int, detail: String, retryAfter: String?)
    }

    private func attemptRequest(url: URL, accept: String?, context: SiteRequestContext) async throws -> Outcome {
        if let resourceLoader = context.resourceLoader {
            do {
                // WebKit's script calls ignore task cancellation: a cancel
                // or a stalled page must still free the pacer's slot and
                // the job's worker at once.
                let response = try await withPromptCancellation(timeout: resourceLoaderTimeout) {
                    try await resourceLoader(url)
                }
                if (200..<300).contains(response.statusCode) {
                    return .success(ForumHTTPResponse(data: response.data, headers: response.headers))
                }
                return .failure(
                    status: response.statusCode,
                    detail: String(data: response.data, encoding: .utf8) ?? response.statusText,
                    retryAfter: response.headers["retry-after"]
                )
            } catch {
                // The page could not make the request (its fetch failed or
                // timed out, the page went away): the forum directly, with
                // its cookies, below.
                if error is CancellationError || Task.isCancelled { throw error }
            }
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue(accept ?? Self.defaultAccept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        // Only the forum cookies passed in; nothing from the shared jar.
        request.httpShouldHandleCookies = false
        if let cookieHeader = context.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(
            for: request,
            delegate: ForumRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) {
            return .success(ForumHTTPResponse(data: data, headers: http.lowercasedHeaders))
        }
        return .failure(
            status: http.statusCode,
            detail: String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After")
        )
    }
}


extension HTTPURLResponse {
    /// Header names lowercased (HTTP names are case-insensitive).
    var lowercasedHeaders: [String: String] {
        var result: [String: String] = [:]
        for (name, value) in allHeaderFields {
            if let name = name as? String, let value = value as? String {
                result[name.lowercased()] = value
            }
        }
        return result
    }
}

// MARK: - Prompt cancellation

/// Runs `operation`, but returns as soon as the calling task is cancelled
/// (`CancellationError`) or `timeout` passes (`URLError(.timedOut)`), even
/// when `operation` ignores cancellation. The operation is cancelled then and
/// its late result dropped.
func withPromptCancellation<Value>(
    timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let gate = ResumeOnce<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard gate.install(continuation) else { return }
            let work = Task {
                do {
                    gate.finish(.success(try await operation()))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                gate.finish(.failure(URLError(.timedOut)))
            }
            gate.whenFinished {
                work.cancel()
                timer.cancel()
            }
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// Resumes a continuation with the first result only; a result that comes
/// before the continuation is installed is kept for it.
private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cleanup: (() -> Void)?

    /// False when a result (a cancel) was already there: nothing to start.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let early: Result<Value, Error>? = lock.withLock {
            if result == nil { self.continuation = continuation }
            return result
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    func finish(_ value: Result<Value, Error>) {
        let (waiting, cleanup): (CheckedContinuation<Value, Error>?, (() -> Void)?) = lock.withLock {
            guard result == nil else { return (nil, nil) }
            result = value
            defer {
                continuation = nil
                self.cleanup = nil
            }
            return (continuation, self.cleanup)
        }
        waiting?.resume(with: value)
        cleanup?()
    }

    /// Runs `cleanup` once there is a result (now, if there is one).
    func whenFinished(_ cleanup: @escaping () -> Void) {
        let finished: Bool = lock.withLock {
            if result == nil { self.cleanup = cleanup }
            return result != nil
        }
        if finished { cleanup() }
    }
}
