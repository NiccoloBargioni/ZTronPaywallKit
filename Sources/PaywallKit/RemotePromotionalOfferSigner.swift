public import Foundation
public import PaywallCore

/// One HTTP exchange, so `RemotePromotionalOfferSigner` is testable without a network. `URLSessionTransport` is the
/// production one. `send` must honour task cancellation (`URLSession.data(for:)` does): the signer cancels it when
/// its deadline passes.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public enum Failure: Error, Hashable, Sendable {
        /// The URL did not speak HTTP.
        case notHTTP
    }

    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        return (data, http)
    }
}

/// The production signer: posts the request to the deployed `Workers/PromotionalOfferSigner` (or anything that
/// speaks its JSON) and returns the compact JWS it minted. The In-App Purchase key never leaves that server; the app
/// holds only this URL.
///
///     configuration.promotionalOfferSigner = RemotePromotionalOfferSigner(
///         endpoint: URL(string: "https://promotional-offer-signer.<account>.workers.dev/v1/promotional-offers/sign")!)
///
/// Wire format, both ways camel-cased `…Id` as Apple's own JSON: the request is `{"bundleId", "productId", "offerId",
/// "transactionId"?}`, the answer `{"compactJWS", "productId", "offerId", …}`; any other status carries
/// `{"error": <code>}`. The engine checks that the answer names the product and offer it asked for.
public struct RemotePromotionalOfferSigner: PromotionalOfferSigner {
    public enum Failure: Error, Hashable, Sendable {
        /// A status other than 200; `code` is the server's `error` field when it sent one (`bundle_not_allowed`,
        /// `offer_not_allowed`, `invalid_request`, `misconfigured`, and `rate_limited` from a worker deployed with a
        /// rate limit, with a `retry-after` header).
        case http(status: Int, code: String?)
        /// 200 without the fields the kit needs.
        case malformedResponse
    }

    /// The sign route of the worker.
    public var endpoint: URL
    public var transport: any HTTPTransport
    /// The total deadline of one `sign`, in seconds, from the request until the answer is in hand: the request's own
    /// `timeoutInterval` (an idle timer, reset by every byte that arrives) and a clock started with the call, whichever
    /// fires first throws `URLError(.timedOut)`. A paywall waits on this before the payment sheet, so keep it short.
    public var timeout: TimeInterval

    public init(endpoint: URL, transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 15) {
        self.endpoint = endpoint
        self.transport = transport
        self.timeout = timeout
    }

    struct WireRequest: Encodable {
        var bundleId: String
        var productId: String
        var offerId: String
        var transactionId: String?
    }

    struct WireResponse: Decodable {
        var compactJWS: String
        var productId: String
        var offerId: String
    }

    struct WireError: Decodable {
        var error: String?
    }

    public func sign(_ request: PromotionalOfferSigningRequest) async throws -> SignedPromotionalOffer {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(
            WireRequest(
                bundleId: request.bundleID, productId: request.productID, offerId: request.offerID,
                transactionId: request.transactionID.flatMap { $0.isEmpty ? nil : $0 }))
        let prepared = urlRequest
        let transport = transport
        let (data, response) = try await Self.withDeadline(timeout) { try await transport.send(prepared) }
        guard response.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(WireError.self, from: data))?.error
            throw Failure.http(status: response.statusCode, code: code)
        }
        guard let wire = try? JSONDecoder().decode(WireResponse.self, from: data) else { throw Failure.malformedResponse }
        return SignedPromotionalOffer(productID: wire.productId, offerID: wire.offerId, compactJWS: wire.compactJWS)
    }

    /// Races `body` against a total deadline. The loser is cancelled; a deadline that fires throws
    /// `URLError(.timedOut)`, what `URLSession` throws for its own idle timeout.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds(seconds))
                throw URLError(.timedOut)
            }
            // The first child to finish decides: a result, the transport's error, or the deadline's.
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return first
        }
    }

    /// `timeout` is a public var: clamp a value that `UInt64` would trap on (NaN, negative, infinite, huge) to a year.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        return UInt64(min(seconds, 60 * 60 * 24 * 365) * 1_000_000_000)
    }
}
