import CryptoKit
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// A tiny DER writer for synthetic receipts and containers.
enum DER {
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        var out = [tag]
        if body.count < 0x80 {
            out.append(UInt8(body.count))
        } else if body.count < 0x100 {
            out += [0x81, UInt8(body.count)]
        } else {
            out += [0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
        }
        return out + body
    }
    static func seq(_ items: [UInt8]...) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func int(_ v: Int) -> [UInt8] { tlv(0x02, [UInt8(v)]) }
    static func utf8(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static func ia5(_ s: String) -> [UInt8] { tlv(0x16, Array(s.utf8)) }
    static func octets(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
    static func oid(_ arcs: [UInt8]) -> [UInt8] { tlv(0x06, arcs) }
    static let signedData: [UInt8] = oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
    static let pkcs7Data: [UInt8] = oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])
    static let sha256: [UInt8] = oid([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])
    static let rsa: [UInt8] = oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])

    static func attribute(_ type: Int, _ value: [UInt8]) -> [UInt8] { seq(int(type), int(1), octets(value)) }

    /// ContentInfo { oid, [0] SignedData { version, digestAlgs, encap { oid, [0] OCTET STRING payload },
    ///                                     certs?, crls?, signerInfos } }
    static func receipt(
        fields: [[UInt8]], indefinite: Bool = false, certificates: [[UInt8]]? = nil, crls: Bool = false,
        signers: [[UInt8]] = []
    ) -> Data {
        let payload = set(fields)
        let encap = seq(pkcs7Data, tlv(0xA0, octets(payload)))
        var body = int(1) + set([]) + encap
        if let certificates { body += tlv(0xA0, certificates.flatMap { $0 }) }
        if crls { body += tlv(0xA1, []) }
        body += set(signers)
        let signed = tlv(0x30, body)
        if indefinite {
            let explicit: [UInt8] = [0xA0, 0x80] + signed + [0, 0]
            return Data([0x30, 0x80] + signedData + explicit + [0, 0])
        }
        return Data(seq(signedData, tlv(0xA0, signed)))
    }

    /// SignerInfo { version, sid, digestAlgorithm, signedAttrs?, signatureAlgorithm, signature }
    static func signer(digest: [UInt8] = sha256, attrs: [UInt8]? = nil, algorithm: [UInt8] = rsa, signature: [UInt8] = [1, 2, 3]) -> [UInt8] {
        var body = int(1) + seq(seq(utf8("issuer")), int(7)) + seq(digest)
        if let attrs { body += attrs }
        body += seq(algorithm) + octets(signature)
        return tlv(0x30, body)
    }
}

struct Accepting: ReceiptVerifier { func isAuthentic(_ receipt: Data) -> Bool { true } }
struct Rejecting: ReceiptVerifier { func isAuthentic(_ receipt: Data) -> Bool { false } }

let receiptFields = [
    DER.attribute(0, DER.utf8("Production")),
    DER.attribute(2, DER.utf8("com.ztron.app")),
    DER.attribute(19, DER.utf8("116")),
    DER.attribute(18, DER.ia5("2024-03-01T10:00:00Z")),
]

@Suite("Receipt (iOS 15 path)")
struct ReceiptClientTests {
    let fields = receiptFields

    @Test func parses_original_version_date_and_environment() throws {
        let snapshot = try #require(try ReceiptClient.parse(DER.receipt(fields: fields)))
        #expect(snapshot.originalAppVersion == "116")
        #expect(snapshot.bundleID == "com.ztron.app")
        #expect(snapshot.environment == .production)
        #expect(snapshot.origin == .receipt)
        #expect(snapshot.originalPurchaseDate == ISO8601DateFormatter().date(from: "2024-03-01T10:00:00Z"))
    }

    @Test func parses_indefinite_length_ber() throws {
        let snapshot = try #require(try ReceiptClient.parse(DER.receipt(fields: fields, indefinite: true)))
        #expect(snapshot.originalAppVersion == "116")
    }

    @Test func sandbox_receipt_type_maps_to_sandbox() throws {
        var sandbox = fields
        sandbox[0] = DER.attribute(0, DER.utf8("ProductionSandbox"))
        #expect(try ReceiptClient.parse(DER.receipt(fields: sandbox))?.environment == .sandbox)
        sandbox[0] = DER.attribute(0, DER.utf8("Xcode"))
        #expect(try ReceiptClient.parse(DER.receipt(fields: sandbox))?.environment == .xcode)
    }

    @Test func receipt_without_field_19_18_or_2_fails_closed() throws {
        #expect(try ReceiptClient.parse(DER.receipt(fields: Array(fields.prefix(2)) + [fields[3]])) == nil)  // no 19
        #expect(try ReceiptClient.parse(DER.receipt(fields: Array(fields.prefix(3)))) == nil)  // no 18
        #expect(try ReceiptClient.parse(DER.receipt(fields: [fields[0], fields[2], fields[3]])) == nil)  // no 2
    }

    @Test func fractional_seconds_dates_parse() throws {
        var fractional = fields
        fractional[3] = DER.attribute(18, DER.ia5("2024-03-01T10:00:00.123Z"))
        #expect(try ReceiptClient.parse(DER.receipt(fields: fractional)) != nil)
    }

    @Test func malformed_receipt_throws() {
        #expect(throws: ReceiptClient.ReceiptError.malformed) { try ReceiptClient.parse(Data([0x30, 0x03, 0x02, 0x01])) }
        #expect(throws: ReceiptClient.ReceiptError.malformed) { try ReceiptClient.parse(Data([0x30, 0x80, 0x02])) }
        // Right shape, wrong content type.
        var notSigned = DER.receipt(fields: fields)
        notSigned[notSigned.startIndex + 11] ^= 0x01
        #expect(throws: ReceiptClient.ReceiptError.malformed) { try ReceiptClient.parse(notSigned) }
    }

    @Test func missing_unverified_foreign_or_unverifiable_receipts_fail_closed() throws {
        let url = makeTemporaryPaywallDirectory().appendingPathComponent("receipt")
        #expect(try ReceiptClient(receiptURL: url, verifier: Accepting(), expectedBundleID: nil).snapshot() == nil)  // missing
        try DER.receipt(fields: fields).write(to: url)
        #expect(try ReceiptClient(receiptURL: url, verifier: Rejecting(), expectedBundleID: nil).snapshot() == nil)
        #expect(try ReceiptClient(receiptURL: url, verifier: Accepting(), expectedBundleID: nil).snapshot()?.originalAppVersion == "116")
        #expect(try ReceiptClient(receiptURL: url, verifier: Accepting(), expectedBundleID: "com.ztron.app").snapshot() != nil)
        #expect(try ReceiptClient(receiptURL: url, verifier: Accepting(), expectedBundleID: "com.someone.else").snapshot() == nil)
        #expect(try ReceiptClient(receiptURL: nil, verifier: Accepting()).snapshot() == nil)
        // The default client fails closed on a receipt Apple did not sign.
        #expect(try ReceiptClient(receiptURL: url).snapshot() == nil)
    }

    @Test func asn1_integers_strings_and_object_identifiers() {
        #expect(ASN1.parse([0x02, 0x02, 0x01, 0x00][...])?.integer == 256)
        #expect(ASN1.parse([0x04, 0x00][...])?.integer == nil)
        #expect(ASN1.string([0x04, 0x01, 0x41]) == nil)
        #expect(ASN1.parse([0x30, 0x85, 0, 0, 0, 0, 1][...]) == nil)
        #expect(ASN1.parse([][...]) == nil)
        #expect(ASN1.parse([0x06, 0x03, 0x2A, 0x86, 0x48][...])?.objectIdentifier == "1.2.840")
        #expect(ASN1.parse([0x06, 0x01, 0x55][...])?.objectIdentifier == "2.5")
        #expect(ASN1.parse([0x06, 0x01, 0x28][...])?.objectIdentifier == "1.0")
        #expect(ASN1.parse([0x06, 0x02, 0x88, 0x37][...])?.objectIdentifier == "2.999")  // (8 << 7 | 0x37) - 80
        #expect(ASN1.parse([0x06, 0x00][...])?.objectIdentifier == nil)
        #expect(ASN1.parse([0x06, 0x02, 0x81, 0x80][...])?.objectIdentifier == nil)  // unterminated arc
        #expect(ASN1.parse([0x06, 0x0A] + [UInt8](repeating: 0xFF, count: 9) + [0x7F])?.objectIdentifier == nil)  // overlong arc
        #expect(ASN1.parse([0x02, 0x01, 0x05][...])?.objectIdentifier == nil)
        let node = ASN1.parse([0x30, 0x03, 0x02, 0x01, 0x09][...])
        #expect(node?.raw == [0x30, 0x03, 0x02, 0x01, 0x09])
        #expect(node?.child(0)?.raw == [0x02, 0x01, 0x09])
        #expect(ASN1.parse([0x06, 0x01, 0x09][...])?.objectIdentifier == "0.9")
        #expect(ASN1.parse([0x30][...]) == nil)  // a tag with no length
        #expect(ASN1.parse([0x04, 0x80, 0, 0][...]) == nil)  // indefinite length on a primitive
        #expect(ASN1.parse([0x30, 0x80, 0x02, 0x01][...]) == nil)  // indefinite with a truncated child
        // BER: a constructed OCTET STRING is the concatenation of its segments.
        let constructed = ASN1.parse([0x24, 0x80, 0x04, 0x01, 0x41, 0x04, 0x01, 0x42, 0x00, 0x00][...])
        #expect(constructed?.octetBytes == [0x41, 0x42])
        #expect(constructed?.raw.count == 10)
    }

    @Test func signed_data_model_skips_crls_and_refuses_the_wrong_shape() {
        let withCRLs = DER.receipt(fields: fields, certificates: [], crls: true, signers: [DER.signer()])
        let model = SignedReceipt(withCRLs)
        #expect(model?.signers.count == 1)
        #expect(model?.signers.first?.digestAlgorithm == "2.16.840.1.101.3.4.2.1")
        #expect(model?.signers.first?.signatureAlgorithm == "1.2.840.113549.1.1.1")
        #expect(model?.signers.first?.signature == [1, 2, 3])
        #expect(model?.fields[19].flatMap(ASN1.string) == "116")
        // A signer whose algorithm is not an OID, and a signer that is not a SEQUENCE, are dropped.
        let odd = DER.receipt(fields: fields, signers: [DER.signer(digest: DER.int(1)), DER.tlv(0x31, [])])
        #expect(SignedReceipt(odd)?.signers.isEmpty == true)
        let noSignerSet = Data(DER.seq(DER.signedData, DER.tlv(0xA0, DER.seq(DER.int(1), DER.set([]), DER.seq(DER.pkcs7Data, DER.tlv(0xA0, DER.octets([])))))))
        #expect(SignedReceipt(noSignerSet) == nil)
        #expect(SignedReceipt(Data([0x30, 0x00]))?.signers == nil)
        #expect(SignedReceipt(Data(DER.seq(DER.pkcs7Data, DER.tlv(0xA0, [])))) == nil)
    }
}

/// The fixtures are signed by a throwaway chain shaped like Apple's (`Scripts/make-receipt-fixtures.sh`); the
/// verifier is pointed at that chain's root. Apple's own root is checked by fingerprint, and against the Mac App
/// Store receipts installed on the machine running the tests, when there are any.
@Suite("Receipt signature verification")
struct ReceiptSignatureTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static let testRoot: Data = {
        guard let url = Bundle.module.url(forResource: "test-root", withExtension: "der", subdirectory: "Fixtures") else { return Data() }
        return (try? Data(contentsOf: url)) ?? Data()
    }()

    var verifier: AppleReceiptVerifier { AppleReceiptVerifier(anchors: [Self.testRoot]) }

    @Test func the_fixture_root_is_present() {
        #expect(!Self.testRoot.isEmpty)
    }

    @Test(arguments: ["receipt-sha256", "receipt-sha1", "receipt-attrs"])
    func every_accepted_layout_verifies_and_parses(name: String) throws {
        let receipt = try Self.fixture(name)
        #expect(verifier.isAuthentic(receipt))
        let url = makeTemporaryPaywallDirectory().appendingPathComponent("receipt")
        try receipt.write(to: url)
        let snapshot = try ReceiptClient(receiptURL: url, verifier: verifier, expectedBundleID: "com.ztron.app").snapshot()
        #expect(snapshot?.originalAppVersion == "116")
        #expect(snapshot?.environment == .production)
        #expect(snapshot?.accountKey == AppTransactionSnapshot(
            bundleID: "com.ztron.app", originalAppVersion: "116",
            originalPurchaseDate: ISO8601DateFormatter().date(from: "2024-03-01T10:00:00Z")!, environment: .production,
            origin: .receipt).accountKey)
    }

    /// Apple rotates the signing certificate: a receipt is evaluated at its own creation date (field 12).
    @Test func expired_signer_verifies_at_the_receipt_creation_date_only() throws {
        #expect(verifier.isAuthentic(try Self.fixture("receipt-expired-leaf")))
        #expect(!verifier.isAuthentic(try Self.fixture("receipt-expired-leaf-undated")))
    }

    @Test func signer_without_the_receipt_marker_is_refused() throws {
        let receipt = try Self.fixture("receipt-nomarker")
        #expect(!verifier.isAuthentic(receipt))
        var anyChained = verifier
        anyChained.requiredSignerMarker = nil
        #expect(anyChained.isAuthentic(receipt))
    }

    @Test func receipt_for_another_app_verifies_but_is_not_this_apps() throws {
        let receipt = try Self.fixture("receipt-other-bundle")
        #expect(verifier.isAuthentic(receipt))
        let url = makeTemporaryPaywallDirectory().appendingPathComponent("receipt")
        try receipt.write(to: url)
        #expect(try ReceiptClient(receiptURL: url, verifier: verifier, expectedBundleID: "com.ztron.app").snapshot() == nil)
        #expect(try ReceiptClient(receiptURL: url, verifier: verifier, expectedBundleID: nil).snapshot()?.bundleID == "com.other.app")
    }

    @Test func tampering_with_the_payload_or_the_signature_is_refused() throws {
        let receipt = try Self.fixture("receipt-sha256")
        var payloadTampered = receipt
        let version = try #require(receipt.range(of: Data("116".utf8)))
        payloadTampered[version.lowerBound] = UInt8(ascii: "9")
        #expect(!verifier.isAuthentic(payloadTampered))
        var signatureTampered = receipt
        signatureTampered[signatureTampered.index(before: signatureTampered.endIndex)] ^= 0xFF
        #expect(!verifier.isAuthentic(signatureTampered))
    }

    @Test func the_test_chain_does_not_pass_as_apples_and_vice_versa() throws {
        #expect(!AppleReceiptVerifier().isAuthentic(try Self.fixture("receipt-sha256")))
        #expect(!AppleReceiptVerifier(anchors: []).isAuthentic(try Self.fixture("receipt-sha256")))
        #expect(!AppleReceiptVerifier(anchors: [Data([1, 2, 3])]).isAuthentic(try Self.fixture("receipt-sha256")))
    }

    static func firstSigner(_ receipt: Data) throws -> SignedReceipt.Signer {
        let model = try #require(SignedReceipt(receipt))
        return try #require(model.signers.first)
    }

    @Test func containers_without_signers_certificates_or_a_known_algorithm_are_refused() throws {
        #expect(!verifier.isAuthentic(Data([0x30, 0x03, 0x02, 0x01])))
        #expect(!verifier.isAuthentic(DER.receipt(fields: receiptFields)))  // no certificates, no signers
        #expect(!verifier.isAuthentic(DER.receipt(fields: receiptFields, certificates: [DER.seq(DER.int(1))], signers: [DER.signer()])))  // bogus cert
        let md5 = DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x05])
        let pss = DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A])
        let sha1WithRSA = DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05])
        func algorithm(_ signer: [UInt8]) throws -> SecKeyAlgorithm? {
            AppleReceiptVerifier.keyAlgorithm(for: try Self.firstSigner(DER.receipt(fields: receiptFields, signers: [signer])))
        }
        #expect(try algorithm(DER.signer(digest: md5)) == nil)
        #expect(try algorithm(DER.signer(algorithm: pss)) == nil)
        // sha1WithRSAEncryption next to a SHA-256 digest: the two disagree.
        #expect(try algorithm(DER.signer(algorithm: sha1WithRSA)) == nil)
        #expect(try algorithm(DER.signer()) == .rsaSignatureMessagePKCS1v15SHA256)
        #expect(AppleReceiptVerifier.digest([], "1.2.3") == nil)
        #expect(AppleReceiptVerifier.digest([], "1.3.14.3.2.26")?.count == 20)
        #expect(AppleReceiptVerifier.digest([], "2.16.840.1.101.3.4.2.2")?.count == 48)
        #expect(AppleReceiptVerifier.digest([], "2.16.840.1.101.3.4.2.3")?.count == 64)
        // A real certificate next to a signer whose algorithm is unknown: no candidate is even tried.
        let root = [UInt8](Self.testRoot)
        #expect(!verifier.isAuthentic(DER.receipt(fields: receiptFields, certificates: [root], signers: [DER.signer(digest: md5)])))
        // A signer that verifies nothing against the only certificate present.
        #expect(!verifier.isAuthentic(DER.receipt(fields: receiptFields, certificates: [root], signers: [DER.signer()])))
        #expect(!AppleReceiptVerifier.chains([], to: [], at: Date()))
    }

    @Test func signed_attributes_must_carry_the_payloads_digest() throws {
        let payload: [UInt8] = [1, 2, 3]
        let messageDigest = DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04])
        let good = DER.tlv(0xA0, DER.seq(messageDigest, DER.set([DER.octets(Array(SHA256.hash(data: Data(payload))))])))
        let bad = DER.tlv(0xA0, DER.seq(messageDigest, DER.set([DER.octets([0])])))
        let none = DER.tlv(0xA0, DER.seq(DER.oid([0x2A, 0x03]), DER.set([DER.octets([0])])))
        func signer(_ attrs: [UInt8]) throws -> SignedReceipt.Signer {
            try Self.firstSigner(DER.receipt(fields: receiptFields, signers: [DER.signer(attrs: attrs)]))
        }
        let message = try #require(AppleReceiptVerifier.signedMessage(of: signer(good), over: payload))
        #expect(message.first == 0x31)  // the SET re-tagged for signing
        #expect(AppleReceiptVerifier.signedMessage(of: try signer(bad), over: payload) == nil)
        #expect(AppleReceiptVerifier.signedMessage(of: try signer(none), over: payload) == nil)
        #expect(AppleReceiptVerifier.signedMessage(of: try signer(good), over: [9]) == nil)
        #expect(!AppleReceiptVerifier.hasExtension("1.2", in: [0x30, 0x00]))
        #expect(!AppleReceiptVerifier.hasExtension("1.2", in: DER.seq(DER.seq(DER.int(1)))))
    }

    @Test func embedded_apple_root_matches_the_published_fingerprint() {
        let fingerprint = SHA256.hash(data: AppleReceiptVerifier.appleRootCA).map { String(format: "%02x", $0) }.joined()
        #expect(fingerprint == "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024")
        #expect(SecCertificateCreateWithData(nil, AppleReceiptVerifier.appleRootCA as CFData) != nil)
        #expect(AppleReceiptVerifier.hasExtension("2.5.29.19", in: [UInt8](AppleReceiptVerifier.appleRootCA)))  // basicConstraints
    }

    #if os(macOS)
        static let macAppStoreReceipts: [URL] = {
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
            return apps.map { URL(fileURLWithPath: "/Applications/\($0)/Contents/_MASReceipt/receipt") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }()

        /// Real receipts, signed by Apple's production chain. Purchase receipts (`Production`) verify and parse;
        /// the `ProductionStub` receipts Apple ships with its bundled apps carry no original version and fail closed
        /// in the parser (Apple also signs those with an already-expired certificate, so they are not asserted
        /// authentic). Nothing on this machine chains to the test root.
        @Test(.enabled(if: !macAppStoreReceipts.isEmpty, "no Mac App Store receipts on this machine"))
        func every_mac_app_store_receipt_on_this_mac_verifies() throws {
            var purchases = 0
            for url in Self.macAppStoreReceipts {
                let receipt = try Data(contentsOf: url)
                #expect(!verifier.isAuthentic(receipt), "\(url.path) must not chain to the test root")
                let model = try #require(SignedReceipt(receipt), "\(url.path)")
                let snapshot = try ReceiptClient.parse(receipt)
                switch model.fields[0].flatMap(ASN1.string) {
                case "Production"?:
                    purchases += 1
                    #expect(AppleReceiptVerifier().isAuthentic(receipt), "\(url.path)")
                    #expect(snapshot?.environment == .production, "\(url.path)")
                    #expect(snapshot?.bundleID.isEmpty == false, "\(url.path)")
                    #expect(snapshot?.originalAppVersion.isEmpty == false, "\(url.path)")
                default:
                    #expect(snapshot == nil, "\(url.path): a stub receipt must never grandfather")
                }
            }
            print("verified \(purchases) Mac App Store purchase receipts of \(Self.macAppStoreReceipts.count)")
        }
    #endif
}

private let productionReceiptPath = ProcessInfo.processInfo.environment["PAYWALL_PRODUCTION_RECEIPT"]

/// A production receipt of the app under test, when `PAYWALL_PRODUCTION_RECEIPT` names one. An App Store install
/// keeps it at `Bundle.main.appStoreReceiptURL`; for an iOS app on an Apple silicon Mac that is
/// `~/Library/Containers/<bundle id>/Data/StoreKit/receipt`. It is Apple's real output, so the verifier, the parser,
/// the grandfathering rule and the engine run over it, with expectations taken from the receipt itself. A receipt
/// names its app, so none is committed and CI skips the suite.
@Suite("Production receipt", .enabled(if: productionReceiptPath != nil, "set PAYWALL_PRODUCTION_RECEIPT to an App Store receipt file"))
struct ProductionReceiptTests {
    static let day: TimeInterval = 86_400

    static func receipt() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: try #require(productionReceiptPath))) }
    static func snapshot() throws -> AppTransactionSnapshot { try #require(try ReceiptClient.parse(try receipt())) }

    /// The receipt's own build is the last paid one, bought a year into the paid window, freemium a month later.
    /// A build called `1.0` is also what the sandbox reports, so it needs the sentinel.
    static func policy(_ snapshot: AppTransactionSnapshot) -> GrandfatheringPolicy {
        let paid = DateInterval(
            start: snapshot.originalPurchaseDate.addingTimeInterval(-365 * day),
            end: snapshot.originalPurchaseDate.addingTimeInterval(30 * day))
        return GrandfatheringPolicy(
            lastPaidBuild: snapshot.originalAppVersion, paidWindow: paid,
            legacySentinel: snapshot.originalAppVersion == "1.0" ? .init(onSaleWindow: paid) : nil)
    }

    @Test func apple_signed_it_and_the_test_root_did_not() throws {
        let receipt = try Self.receipt()
        #expect(AppleReceiptVerifier().isAuthentic(receipt))
        #expect(!AppleReceiptVerifier(anchors: [ReceiptSignatureTests.testRoot]).isAuthentic(receipt))
        let model = try #require(SignedReceipt(receipt))
        #expect(model.signers.count == 1)
        #expect(model.certificates.count >= 2)  // the signer and at least the intermediate
        #expect(model.certificates.filter { AppleReceiptVerifier.hasExtension(AppleReceiptVerifier.receiptSigningMarker, in: $0) }.count == 1)
        // Apple's layout: no signed attributes, RSA PKCS#1 v1.5 straight over the payload.
        #expect(model.signers.first?.signedAttributes == nil)
        #expect(model.signers.first?.signatureAlgorithm == "1.2.840.113549.1.1.1")
        // One payload byte changed: the parser still reads it, the verifier refuses it.
        let snapshot = try Self.snapshot()
        var tampered = receipt
        let bundle = try #require(receipt.range(of: Data(snapshot.bundleID.utf8)))
        tampered[bundle.lowerBound] ^= 0x01
        #expect(try ReceiptClient.parse(tampered)?.bundleID != snapshot.bundleID)
        #expect(!AppleReceiptVerifier().isAuthentic(tampered))
    }

    @Test func parses_what_the_rule_uses_and_the_client_binds_it_to_its_app() throws {
        let receipt = try Self.receipt()
        let snapshot = try Self.snapshot()
        #expect(snapshot.environment == .production)
        #expect(!snapshot.bundleID.isEmpty)
        #expect(!snapshot.originalAppVersion.isEmpty)
        #expect(snapshot.originalPurchaseDate < Date())
        #expect(snapshot.origin == .receipt)
        #expect(snapshot.appTransactionID == nil)
        #expect(snapshot.signedPayload == receipt)
        let fields = try ReceiptClient.receiptFields(receipt)
        #expect(fields[0].flatMap(ASN1.string) == "Production")
        let created = try #require(fields[12].flatMap(ASN1.string).flatMap(ReceiptClient.parseDate))  // the chain is evaluated at it
        #expect(created >= snapshot.originalPurchaseDate)
        // The iOS 15 path and the iOS 16 path derive one account key from the same three values.
        let fromAppTransaction = AppTransactionSnapshot(
            bundleID: snapshot.bundleID, originalAppVersion: snapshot.originalAppVersion,
            originalPurchaseDate: snapshot.originalPurchaseDate, environment: .production, appTransactionID: "1", origin: .appTransaction)
        #expect(snapshot.accountKey == fromAppTransaction.accountKey)
        // The client, with the production verifier, reads it for its app and for no other.
        let url = makeTemporaryPaywallDirectory().appendingPathComponent("receipt")
        try receipt.write(to: url)
        #expect(try ReceiptClient(receiptURL: url, expectedBundleID: snapshot.bundleID).snapshot() == snapshot)
        #expect(try ReceiptClient(receiptURL: url, expectedBundleID: "com.ztron.app").snapshot() == nil)
        print("production receipt: \(snapshot.bundleID) build \(snapshot.originalAppVersion), bought \(snapshot.originalPurchaseDate), created \(created)")
    }

    @Test func the_rule_admits_it_inside_the_paid_window_and_the_resolver_grants_from_it() throws {
        let snapshot = try Self.snapshot()
        let policy = Self.policy(snapshot)
        #expect(policy.admits(snapshot))
        // Freemium went live a second before this purchase: a free-era install, whatever its build.
        var freemiumEarlier = policy
        freemiumEarlier.paidWindow = DateInterval(start: policy.paidWindow.start, end: snapshot.originalPurchaseDate.addingTimeInterval(-1))
        #expect(!freemiumEarlier.admits(snapshot))
        // The last paid build was "0": this one is a freemium build.
        var lastPaidZero = policy
        lastPaidZero.lastPaidBuild = "0"
        #expect(!lastPaidZero.admits(snapshot))
        // Production only, by default.
        var sandboxOnly = policy
        sandboxOnly.environments = [.sandbox]
        #expect(!sandboxOnly.admits(snapshot))
        let now = policy.paidWindow.end.addingTimeInterval(Self.day)  // the day after freemium went live
        let lifetime = EntitlementResolver(catalog: catalog, grandfathering: policy).resolve(transactions: [], appTransaction: snapshot, now: now)
        #expect(lifetime.entitlement == .lifetime(.grandfathered(originalAppVersion: snapshot.originalAppVersion)))
        #expect(lifetime.entitlement.tier(wallet: .empty) == .grandfathered)
        #expect(lifetime.grandfathered == snapshot)
        #expect(lifetime.expiresAt == nil)
        var tokens = policy
        tokens.grant = .tokens(50)
        let free = EntitlementResolver(catalog: catalog, grandfathering: tokens).resolve(transactions: [], appTransaction: snapshot, now: now)
        #expect(free.entitlement == .free)
        #expect(free.grandfathered == snapshot)  // the ledger grants the tokens from this, once per account
        let none = EntitlementResolver(catalog: catalog, grandfathering: nil).resolve(transactions: [], appTransaction: snapshot, now: now)
        #expect(none.entitlement == .free)
        #expect(none.grandfathered == nil)
    }

    /// End to end: a store reporting this app transaction opens every gate as a grandfathered lifetime.
    @MainActor
    @Test func a_facade_fed_this_app_transaction_is_grandfathered() async throws {
        let snapshot = try Self.snapshot()
        let paywall = Paywall()
        let audit = InMemoryAuditSink()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.grandfathering = Self.policy(snapshot)
        configuration.welcomeTokens = 0
        configuration.store = FakeStore(app: snapshot, products: products)
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        configuration.audit = [audit]
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        await settle()
        #expect(paywall.entitlement == .lifetime(.grandfathered(originalAppVersion: snapshot.originalAppVersion)))
        #expect(paywall.canPass(.paid))
        let events = await audit.events
        #expect(events.contains(.grandfathered(
            originalAppVersion: snapshot.originalAppVersion, originalPurchaseDate: snapshot.originalPurchaseDate, environment: .production)))
    }
}
