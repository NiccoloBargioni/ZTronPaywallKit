public import Foundation
public import PaywallCore

/// One HTTP exchange, so `RemotePromotionalOfferSigner` is testable without a network. `URLSessionTransport` is the
/// production one.
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
        /// `offer_not_allowed`, `invalid_request`, `misconfigured`).
        case http(status: Int, code: String?)
        /// 200 without the fields the kit needs.
        case malformedResponse
    }

    /// The sign route of the worker.
    public var endpoint: URL
    public var transport: any HTTPTransport
    /// Per request. A paywall waits on this before the payment sheet, so keep it short.
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
                transactionId: request.transactionID))
        let (data, response) = try await transport.send(urlRequest)
        guard response.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(WireError.self, from: data))?.error
            throw Failure.http(status: response.statusCode, code: code)
        }
        guard let wire = try? JSONDecoder().decode(WireResponse.self, from: data) else { throw Failure.malformedResponse }
        return SignedPromotionalOffer(productID: wire.productId, offerID: wire.offerId, compactJWS: wire.compactJWS)
    }
}
