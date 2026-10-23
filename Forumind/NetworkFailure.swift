import Foundation
import WebKit

/// Why a request failed when the network is to blame. One answer for every
/// job: the work queue, forum requests (which retry `.transient`), the daily
/// digest and the podcast (which wait instead of failing).
enum NetworkFailure: Equatable {
    /// The device has no connection it may use: retrying now only fails
    /// again; wait for the connection.
    case offline
    /// The connection dropped or timed out, the host could not be reached,
    /// or a gateway failed: another try soon may work.
    case transient

    /// Nil for errors the network did not cause (a refused key, a bad
    /// response, cancellation).
    static func classify(_ error: Error) -> NetworkFailure? {
        // A request made inside the forum page fails as a JavaScript `fetch`
        // rejection ("Load failed") instead of a URLError.
        if let webError = error as? WKError, webError.code == .javaScriptExceptionOccurred {
            let message = webError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            return message.contains("Load failed") || message.contains("NetworkError") ? .transient : nil
        }
        if case AssistantError.http(let status, _) = error, gatewayStatuses.contains(status) {
            return .transient
        }
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        case .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .transient
        default:
            return nil
        }
    }

    /// Offline or transient: the job should wait rather than fail.
    static func isUnreachable(_ error: Error) -> Bool {
        classify(error) != nil
    }

    /// Bad gateway, unavailable, gateway timeout.
    static let gatewayStatuses: Set<Int> = [502, 503, 504]
}
