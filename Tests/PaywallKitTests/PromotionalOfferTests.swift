import Combine
import CryptoKit
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

let comebackOffer = PaywallProduct.Offer(
    kind: .promotional, id: "comeback", paymentMode: .payAsYouGo, displayPrice: "$2.99", price: Decimal(string: "2.99")!,
    periodDays: 30, periodCount: 3)

/// A transport answering a scripted status and body, recording what was sent.
actor ScriptedTransport: HTTPTransport {
    private var status: Int
    private var body: Data
    private var error: (any Error)?
    private(set) var sent: [URLRequest] = []

    init(status: Int = 200, body: String = "") {
        self.status = status
        self.body = Data(body.utf8)
    }

    func answer(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
        error = nil
    }

    func fail(_ error: any Error) { self.error = error }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (body, response)
    }
}

/// A transport whose answer takes `delay` seconds. It honours cancellation, as `URLSession.data(for:)` does.
struct SlowTransport: HTTPTransport {
    var delay: TimeInterval
    var body: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

/// The production signer against a scripted transport: the worker's JSON both ways, and every way it can fail.
@Suite("Remote promotional offer signer")
struct RemotePromotionalOfferSignerTests {
    let endpoint = URL(string: "https://signer.example/v1/promotional-offers/sign")!
    let request = PromotionalOfferSigningRequest(
        bundleID: "com.example.app", productID: "pro.monthly", offerID: "comeback", transactionID: "2000000123456789")
    let answer = #"""
        {"compactJWS":"a.b.c","bundleId":"com.example.app","productId":"pro.monthly","offerId":"comeback",
         "keyId":"ABCDE12345","nonce":"0f6e2b1a-4c3d-4e5f-8a9b-0c1d2e3f4a5b","issuedAt":1763100000}
        """#

    @Test func posts_the_request_as_the_workers_json_and_returns_the_jws_it_minted() async throws {
        let transport = ScriptedTransport(body: answer)
        let signer = RemotePromotionalOfferSigner(endpoint: endpoint, transport: transport, timeout: 7)
        let signed = try await signer.sign(request)
        #expect(signed == SignedPromotionalOffer(productID: "pro.monthly", offerID: "comeback", compactJWS: "a.b.c"))
        let sent = try #require(await transport.sent.first)
        #expect(sent.url == endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.timeoutInterval == 7)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(sent.httpBody))
        #expect(body == ["bundleId": "com.example.app", "productId": "pro.monthly", "offerId": "comeback", "transactionId": "2000000123456789"])
    }

    @Test func leaves_transactionId_out_when_the_install_has_none() async throws {
        let transport = ScriptedTransport(body: answer)
        let signer = RemotePromotionalOfferSigner(endpoint: endpoint, transport: transport)
        _ = try await signer.sign(PromotionalOfferSigningRequest(bundleID: "com.example.app", productID: "pro.monthly", offerID: "comeback"))
        let body = try JSONDecoder().decode([String: String].self, from: try #require(await transport.sent.first?.httpBody))
        #expect(body == ["bundleId": "com.example.app", "productId": "pro.monthly", "offerId": "comeback"])
    }

    @Test func reports_the_servers_error_code_with_the_status() async throws {
        let transport = ScriptedTransport(status: 403, body: #"{"error":"bundle_not_allowed"}"#)
        let signer = RemotePromotionalOfferSigner(endpoint: endpoint, transport: transport)
        await #expect(throws: RemotePromotionalOfferSigner.Failure.http(status: 403, code: "bundle_not_allowed")) {
            _ = try await signer.sign(request)
        }
        await transport.answer(status: 502, body: "<html>bad gateway</html>")
        await #expect(throws: RemotePromotionalOfferSigner.Failure.http(status: 502, code: nil)) { _ = try await signer.sign(request) }
        await transport.answer(status: 400, body: #"{"error":"invalid_request","detail":["offerId is malformed"]}"#)
        await #expect(throws: RemotePromotionalOfferSigner.Failure.http(status: 400, code: "invalid_request")) {
            _ = try await signer.sign(request)
        }
    }

    @Test func a_200_without_the_fields_is_malformed_and_a_transport_error_propagates() async throws {
        let transport = ScriptedTransport(body: #"{"compactJWS":"a.b.c"}"#)
        let signer = RemotePromotionalOfferSigner(endpoint: endpoint, transport: transport)
        await #expect(throws: RemotePromotionalOfferSigner.Failure.malformedResponse) { _ = try await signer.sign(request) }
        await transport.answer(status: 200, body: "not json")
        await #expect(throws: RemotePromotionalOfferSigner.Failure.malformedResponse) { _ = try await signer.sign(request) }
        await transport.fail(Boom())
        await #expect(throws: Boom.self) { _ = try await signer.sign(request) }
        #expect(await transport.sent.count == 3)
    }

    /// B10: an empty transaction id (what iOS 16.0 to 18.3 read before the back-deployed accessor had one) is left
    /// out of the body; the worker refuses an empty one.
    @Test func an_empty_transaction_id_is_left_out_of_the_wire_body() async throws {
        let transport = ScriptedTransport(body: answer)
        let signer = RemotePromotionalOfferSigner(endpoint: endpoint, transport: transport)
        _ = try await signer.sign(
            PromotionalOfferSigningRequest(bundleID: "com.example.app", productID: "pro.monthly", offerID: "comeback", transactionID: ""))
        let body = try JSONDecoder().decode([String: String].self, from: try #require(await transport.sent.first?.httpBody))
        #expect(body["transactionId"] == nil)
        #expect(body["productId"] == "pro.monthly")
    }

    /// B5: a worker deployed with a rate limit answers 429 `rate_limited`; the client reports it like any other code.
    @Test func a_rate_limited_answer_is_reported_with_its_code() async throws {
        let transport = ScriptedTransport(status: 429, body: #"{"error":"rate_limited"}"#)
        let signer = RemotePromotionalOfferSigner(endpoint: endpoint, transport: transport)
        await #expect(throws: RemotePromotionalOfferSigner.Failure.http(status: 429, code: "rate_limited")) { _ = try await signer.sign(request) }
    }

    /// B12: `timeout` is a total deadline. A transport that answers late is cancelled and `sign` throws
    /// `URLError(.timedOut)` at the deadline, not when the transport finally gives up.
    @Test func the_timeout_is_a_total_deadline_not_an_idle_timer() async throws {
        let slow = RemotePromotionalOfferSigner(endpoint: endpoint, transport: SlowTransport(delay: 5, body: answer), timeout: 0.2)
        let started = ContinuousClock.now
        await #expect(throws: URLError(.timedOut)) { _ = try await slow.sign(request) }
        #expect(ContinuousClock.now - started < .seconds(3))
        let quick = RemotePromotionalOfferSigner(endpoint: endpoint, transport: SlowTransport(delay: 0.05, body: answer), timeout: 5)
        #expect(try await quick.sign(request).compactJWS == "a.b.c")
        #expect(RemotePromotionalOfferSigner.nanoseconds(1.5) == 1_500_000_000)
        #expect(RemotePromotionalOfferSigner.nanoseconds(0) == 0 && RemotePromotionalOfferSigner.nanoseconds(-1) == 0)
        #expect(RemotePromotionalOfferSigner.nanoseconds(.nan) == 0)
        #expect(RemotePromotionalOfferSigner.nanoseconds(.infinity) == UInt64(365 * 24 * 60 * 60) * 1_000_000_000)
    }

    @Test func the_url_session_transport_insists_on_http() async throws {
        // A data: URL answers with a plain URLResponse: there is no status to read.
        await #expect(throws: URLSessionTransport.Failure.notHTTP) {
            _ = try await URLSessionTransport().send(URLRequest(url: URL(string: "data:application/json,%7B%7D")!))
        }
        #expect(RemotePromotionalOfferSigner(endpoint: endpoint).timeout == 15)
    }

    @Test func the_url_session_transport_hands_back_the_http_response() async throws {
        // A session whose only protocol answers in-process: the real URLSession path, without a network.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedSignerProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))
        let signer = RemotePromotionalOfferSigner(endpoint: endpoint, transport: transport)
        let signed = try await signer.sign(request)
        #expect(signed == SignedPromotionalOffer(productID: "pro.monthly", offerID: "comeback", compactJWS: "a.b.c"))
    }
}

/// Answers every request in-process with the worker's JSON for `comeback`, so `URLSessionTransport` runs its real
/// `URLSession` path in the unit lane.
final class CannedSignerProtocol: URLProtocol {
    static let body = Data(#"{"compactJWS":"a.b.c","bundleId":"com.example.app","productId":"pro.monthly","offerId":"comeback"}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// An app transaction naming the app: `swift test` runs without a bundle identifier, so the signing request takes the
/// app's id from the bound snapshot, as on a device whose cached snapshot the engine bound.
let namedApp = AppTransactionSnapshot(
    bundleID: "com.example.app", originalAppVersion: "200", originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
    environment: .production, appTransactionID: "7000000000000001", origin: .appTransaction)

/// `purchase(_:promotionalOffer:)` on an isolated facade: the configured signer is asked for the running app, the
/// outcome chains, and the unconfigured and passthrough facades answer like a plain purchase.
@Suite("Promotional offers (facade)", .serialized)
@MainActor
struct PromotionalOfferFacadeTests {
    @Test func purchase_with_a_promotional_offer_goes_through_the_configured_signer_and_the_chain() async throws {
        let signer = FakePromotionalOfferSigner()
        let (paywall, store, _) = await makePaywall(signer: signer)
        // `swift test` runs without a bundle identifier; the app transaction then names the app, as on a device
        // whose cached snapshot the engine bound.
        let app = AppTransactionSnapshot(
            bundleID: "com.example.app", originalAppVersion: "200", originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            environment: .production, appTransactionID: "7000000000000001", origin: .appTransaction)
        await store.setApp(app)
        await paywall.refresh()
        var completed: [UInt64] = []
        let outcome = try await paywall.purchase(products[1], promotionalOffer: comebackOffer)
            .onPurchaseCompleted { completed.append($0) }
            .onPurchasePending { Issue.record("not pending") }
            .onPurchaseCancelled { Issue.record("not cancelled") }
        guard case .purchased(let id) = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        #expect(completed == [id])
        // The request names the running app (`Bundle.main` when it has an identifier, as an app does; the xctest
        // runner under `swift test` has none, and the app transaction stands in), the product, the offer and the
        // app transaction.
        let request = try #require(await signer.requests.first)
        #expect(paywall.engine?.settings.bundleID == Bundle.main.bundleIdentifier)
        #expect(request.bundleID == (Bundle.main.bundleIdentifier ?? "com.example.app"))
        #expect(request.productID == "pro.monthly")
        #expect(request.offerID == "comeback")
        #expect(request.transactionID == "7000000000000001")
        let signed = SignedPromotionalOffer(productID: "pro.monthly", offerID: "comeback", compactJWS: "fake-jws.pro.monthly.comeback")
        #expect(await store.purchaseOffers == [signed])
        if case .subscribed(let subscription) = paywall.entitlement {
            #expect(subscription.tier == .monthly)
        } else {
            Issue.record("expected a subscription, got \(paywall.entitlement)")
        }
    }

    @Test func without_a_signer_the_facade_fails_the_offer_purchase_and_publishes_it() async throws {
        let (paywall, store, _) = await makePaywall()
        var published: [PaywallEvent] = []
        let subscription = paywall.events.sink { published.append($0) }
        await #expect(throws: PromotionalOfferError.signerNotConfigured) {
            _ = try await paywall.purchase(products[1], promotionalOffer: comebackOffer)
        }
        #expect(await store.purchaseCalls == 0)
        #expect(published.contains(.purchase(stage: .failed("signerNotConfigured"), productID: "pro.monthly", source: nil, transactionID: nil)))
        #expect(paywall.entitlement == .free)
        subscription.cancel()
    }

    /// B12 through the facade: a signer that does not answer in time fails the offer purchase at its deadline, before
    /// the payment sheet, and the store is never asked.
    @Test func a_slow_signer_fails_the_offer_purchase_at_its_deadline() async throws {
        let signer = RemotePromotionalOfferSigner(
            endpoint: URL(string: "https://signer.example/v1/promotional-offers/sign")!, transport: SlowTransport(delay: 5, body: ""), timeout: 0.2)
        let (paywall, store, _) = await makePaywall(signer: signer)
        await store.setApp(namedApp)
        await paywall.refresh()
        var published: [PaywallEvent] = []
        let subscription = paywall.events.sink { published.append($0) }
        let started = ContinuousClock.now
        await #expect(throws: URLError(.timedOut)) { _ = try await paywall.purchase(products[1], promotionalOffer: comebackOffer) }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(await store.purchaseCalls == 0)
        #expect(published.contains { if case .purchase(.failed, "pro.monthly", _, _) = $0 { true } else { false } })
        subscription.cancel()
    }

    /// B10: an app transaction whose id reads `""` signs without a transaction id rather than with an empty one.
    @Test func an_empty_app_transaction_id_signs_without_one() async throws {
        let signer = FakePromotionalOfferSigner()
        let (paywall, store, _) = await makePaywall(signer: signer)
        await store.setApp(AppTransactionSnapshot(
            bundleID: "com.example.app", originalAppVersion: "200", originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            environment: .production, appTransactionID: "", origin: .appTransaction))
        await paywall.refresh()
        _ = try await paywall.purchase(products[1], promotionalOffer: comebackOffer)
        let request = try #require(await signer.requests.first)
        #expect(request.transactionID == nil)
    }

    /// B8: the signer's answer for another product never reaches a log: not the error, not the published failure, not
    /// any file the audit sink writes next to the journal.
    @Test func a_mismatched_signature_stays_out_of_the_audit_log() async throws {
        let signer = FakePromotionalOfferSigner(
            next: .answer(SignedPromotionalOffer(productID: "pro.yearly", offerID: "comeback", compactJWS: "h.p.UNREDEEMED-SIG")))
        let paywall = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.fileKeyStore = InMemoryFileKeyStore()
        configuration.store = FakeStore(app: namedApp, products: products)
        let directory = makeTemporaryPaywallDirectory()
        configuration.storageDirectory = directory
        configuration.includesDefaultAudit = false
        configuration.audit = [JournalSink(directory: directory)]
        configuration.connectivity = nil
        configuration.promotionalOfferSigner = signer
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        var published: [PaywallEvent] = []
        let subscription = paywall.events.sink { published.append($0) }
        await #expect(throws: PromotionalOfferError.signatureMismatch(productID: "pro.yearly", offerID: "comeback")) {
            _ = try await paywall.purchase(products[1], promotionalOffer: comebackOffer)
        }
        await paywall.engine?.flushAudit()
        let failures = published.compactMap { event -> String? in
            if case .purchase(.failed(let text), _, _, _) = event { return text }
            return nil
        }
        #expect(failures.count == 1 && failures.allSatisfy { $0.contains("signatureMismatch") && !$0.contains("UNREDEEMED-SIG") }, "\(failures)")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!contents.contains("UNREDEEMED-SIG"), Comment(rawValue: file.lastPathComponent))
        }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains { $0.pathExtension == "jsonl" })
        subscription.cancel()
    }

    @Test func unconfigured_and_passthrough_facades_answer_like_a_plain_purchase() async throws {
        let unconfigured = Paywall()
        await #expect(throws: StoreClientError.notConfigured) {
            _ = try await unconfigured.purchase(products[1], promotionalOffer: comebackOffer)
        }
        let signer = FakePromotionalOfferSigner()
        let passthrough = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.fileKeyStore = InMemoryFileKeyStore()
        configuration.passthrough = true
        configuration.promotionalOfferSigner = signer
        passthrough.configure(configuration)
        #expect(try await passthrough.purchase(products[1], promotionalOffer: comebackOffer) == .purchased(transactionID: 0))
        #expect(await signer.requests.isEmpty)
    }
}

private let signerURL = ProcessInfo.processInfo.environment["PAYWALL_OFFER_SIGNER_URL"].flatMap(URL.init(string:))
/// The bundle id the worker under test allows (its `APPLE_BUNDLE_IDS`): `com.example.app` unless
/// `PAYWALL_OFFER_SIGNER_BUNDLE_ID` says otherwise.
private let signerBundleID = ProcessInfo.processInfo.environment["PAYWALL_OFFER_SIGNER_BUNDLE_ID"] ?? "com.example.app"
private let uuidPattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

/// The production signer against a running `Workers/PromotionalOfferSigner` (`npm run dev` on a throwaway key, then
/// `PAYWALL_OFFER_SIGNER_URL=http://127.0.0.1:8787`): what the worker mints is Apple's JWS, it verifies under the key
/// the worker publishes, and an app the worker was not configured for is refused. Skipped without the variable.
@Suite(
    "Promotional offer signer (live worker)",
    .enabled(if: signerURL != nil, "set PAYWALL_OFFER_SIGNER_URL to a running Workers/PromotionalOfferSigner"))
struct LivePromotionalOfferSignerTests {
    struct JWKS: Decodable {
        struct Key: Decodable {
            var kty: String
            var crv: String
            var x: String
            var y: String
            var kid: String
            var use: String?
            var alg: String?
        }
        var keys: [Key]
    }

    struct Header: Decodable {
        var alg: String
        var kid: String
        var typ: String
    }

    struct Claims: Decodable {
        var iss: String
        var iat: Int
        var aud: String
        var bid: String
        var nonce: String
        var productId: String
        var offerIdentifier: String
        var transactionId: String?
        var exp: Int?
    }

    static func base64URLDecode(_ text: String) throws -> Data {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try #require(Data(base64Encoded: base64), "not base64url: \(text)")
    }

    @Test func the_worker_mints_apples_jws_and_it_verifies_under_the_key_it_publishes() async throws {
        let base = try #require(signerURL)
        let signer = RemotePromotionalOfferSigner(endpoint: base.appendingPathComponent("v1/promotional-offers/sign"))
        let request = PromotionalOfferSigningRequest(
            bundleID: signerBundleID, productID: "pro.monthly", offerID: "comeback", transactionID: "2000000123456789")
        let signed = try await signer.sign(request)
        #expect(signed.productID == "pro.monthly")
        #expect(signed.offerID == "comeback")

        let segments = signed.compactJWS.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        try #require(segments.count == 3)
        let header = try JSONDecoder().decode(Header.self, from: Self.base64URLDecode(segments[0]))
        let claims = try JSONDecoder().decode(Claims.self, from: Self.base64URLDecode(segments[1]))
        #expect(header.alg == "ES256")
        #expect(header.typ == "JWT")
        #expect(claims.aud == "promotional-offer")
        #expect(claims.bid == signerBundleID)
        #expect(claims.productId == "pro.monthly")
        #expect(claims.offerIdentifier == "comeback")
        #expect(claims.transactionId == "2000000123456789")
        #expect(claims.exp == nil, "Apple refuses a JWS with exp")
        #expect(abs(Double(claims.iat) - Date().timeIntervalSince1970) < 120)
        #expect(claims.nonce.range(of: uuidPattern, options: .regularExpression) != nil)
        #expect(claims.iss.lowercased().range(of: uuidPattern, options: .regularExpression) != nil)

        // The key the worker publishes verifies the signature, and its kid is the header's.
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("v1/keys"))
        let key = try #require(try JSONDecoder().decode(JWKS.self, from: data).keys.first)
        #expect(key.kid == header.kid)
        #expect(key.kty == "EC" && key.crv == "P-256" && key.use == "sig" && key.alg == "ES256")
        let point = try Data([0x04]) + Self.base64URLDecode(key.x) + Self.base64URLDecode(key.y)
        let publicKey = try P256.Signing.PublicKey(x963Representation: point)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Self.base64URLDecode(segments[2]))
        #expect(publicKey.isValidSignature(signature, for: Data("\(segments[0]).\(segments[1])".utf8)))
        #expect(!publicKey.isValidSignature(signature, for: Data("\(segments[0]).\(segments[1])x".utf8)))

        // Every signature is good for one buy request: a second one has another nonce.
        let again = try await signer.sign(request)
        #expect(again.compactJWS != signed.compactJWS)
    }

    @Test func the_worker_refuses_an_app_it_was_not_configured_for() async throws {
        let base = try #require(signerURL)
        let signer = RemotePromotionalOfferSigner(endpoint: base.appendingPathComponent("v1/promotional-offers/sign"))
        await #expect(throws: RemotePromotionalOfferSigner.Failure.http(status: 403, code: "bundle_not_allowed")) {
            _ = try await signer.sign(PromotionalOfferSigningRequest(bundleID: "com.other.app", productID: "pro.monthly", offerID: "comeback"))
        }
    }
}
