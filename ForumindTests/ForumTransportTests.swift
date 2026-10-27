import XCTest
@testable import Forumind

/// `ForumService.response` / `SiteNetwork.response`: the one request path
/// also hands back the headers (lowercased names).
final class ForumTransportTests: XCTestCase {
    private let site = "https://blog.example.com"

    override func setUp() {
        HeaderStub.reset()
    }

    private func network(
        loader: (@MainActor @Sendable (URL) async throws -> ForumResourceResponse)? = nil
    ) -> SiteNetwork {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderStub.self]
        let service = ForumService(
            session: URLSession(configuration: configuration),
            pacer: ForumRequestPacer(clock: FakePacingClock())
        )
        return service.net(site, resourceLoader: loader, pace: .gentle)
    }

    private var url: URL { URL(string: "\(site)/wp-json/wp/v2/comments?post=7")! }

    func testDirectResponseCarriesLowercasedHeaders() async throws {
        HeaderStub.respond(status: 200, headers: ["X-WP-Total": "212", "X-WP-TotalPages": "3"], body: "[]")
        let response = try await network().response(url)
        XCTAssertEqual(response.headers["x-wp-total"], "212")
        XCTAssertEqual(response.headers["x-wp-totalpages"], "3")
        XCTAssertEqual(String(data: response.data, encoding: .utf8), "[]")
    }

    func testDataIsTheResponseBody() async throws {
        HeaderStub.respond(status: 200, headers: ["X-WP-Total": "1"], body: "body")
        let data = try await network().data(url)
        XCTAssertEqual(String(data: data, encoding: .utf8), "body")
        XCTAssertEqual(HeaderStub.requests.count, 1)
    }

    func testInPageLoaderHeadersReachTheCaller() async throws {
        let loader: @MainActor @Sendable (URL) async throws -> ForumResourceResponse = { _ in
            ForumResourceResponse(
                statusCode: 200, statusText: "OK",
                headers: ["x-wp-total": "5", "x-wp-totalpages": "1"], data: Data("[]".utf8))
        }
        let response = try await network(loader: loader).response(url)
        XCTAssertEqual(response.headers["x-wp-total"], "5")
        XCTAssertTrue(HeaderStub.requests.isEmpty, "the page answered, nothing went out directly")
    }

    func testLoaderWithoutHeadersGivesAnEmptyMap() async throws {
        let loader: @MainActor @Sendable (URL) async throws -> ForumResourceResponse = { _ in
            ForumResourceResponse(statusCode: 200, statusText: "OK", headers: [:], data: Data("[]".utf8))
        }
        let response = try await network(loader: loader).response(url)
        XCTAssertTrue(response.headers.isEmpty)
    }

    func testErrorStatusesSurfaceAsHTTPErrors() async {
        for status in [400, 403, 404] {
            HeaderStub.respond(status: status, headers: [:], body: #"{"code":"rest_x"}"#)
            do {
                _ = try await network().response(url)
                XCTFail("\(status) should throw")
            } catch AssistantError.http(let code, let detail) {
                XCTAssertEqual(code, status)
                XCTAssertTrue(detail.contains("rest_x"))
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testLoaderErrorStatusAndRetryAfterHeaderPaceTheRetry() async throws {
        let counter = Counter()
        let loader: @MainActor @Sendable (URL) async throws -> ForumResourceResponse = { _ in
            let attempt = counter.next()
            return attempt == 1
                ? ForumResourceResponse(statusCode: 429, statusText: "", headers: ["retry-after": "1"], data: Data())
                : ForumResourceResponse(statusCode: 200, statusText: "OK", headers: ["x-wp-total": "9"], data: Data())
        }
        let response = try await network(loader: loader).response(url)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(response.headers["x-wp-total"], "9")
    }

    func testResponseOutsideTheSiteIsRefused() async {
        do {
            _ = try await network().response(URL(string: "https://other.example.org/x")!)
            XCTFail("should throw")
        } catch SiteNetworkError.outsideSite {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLowercasedHeadersOfAnHTTPResponse() {
        let http = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["X-WP-Total": "3", "Retry-After": "2"])!
        XCTAssertEqual(http.lowercasedHeaders, ["x-wp-total": "3", "retry-after": "2"])
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}

private final class HeaderStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply: (Int, [String: String], String) = (200, [:], "")
    nonisolated(unsafe) private static var seen: [URL] = []

    static func reset() { lock.withLock { reply = (200, [:], ""); seen = [] } }
    static func respond(status: Int, headers: [String: String], body: String) {
        lock.withLock { reply = (status, headers, body) }
    }
    static var requests: [URL] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, headers, body) = Self.lock.withLock { () -> (Int, [String: String], String) in
            Self.seen.append(request.url!)
            return Self.reply
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
