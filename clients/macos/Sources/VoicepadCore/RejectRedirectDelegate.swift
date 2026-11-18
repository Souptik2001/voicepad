import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Audio must never be replayed to a redirected destination, even on the same host.
final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
