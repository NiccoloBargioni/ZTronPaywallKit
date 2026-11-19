import CryptoKit
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// The identifier the committed fixtures are bound to (`Scripts/make-receipt-fixtures.sh`), and the one
/// `receipt-other-device.der` is bound to.
let fixtureDevice = UUID(uuidString: "6F1A2B3C-4D5E-4F60-8172-93A4B5C6D7E8")!
let otherFixtureDevice = UUID(uuidString: "00000000-0000-4000-8000-00000000BEEF")!

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

    /// The opaque value of field 4: Apple generates it; the fixtures use these sixteen bytes.
    static let opaque: [UInt8] = Array(0..<16)

    /// Field 5 of Apple's guide: SHA-1 of the device identifier's bytes, the opaque value and field 2 as encoded.
    static func deviceHash(bundle: [UInt8], identifier: UUID, opaque: [UInt8] = DER.opaque) -> [UInt8] {
        let u = identifier.uuid
        let bytes: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return Array(Insecure.SHA1.hash(data: Data(bytes + opaque + bundle)))
    }

    /// Fields 4 and 5, binding a receipt for `bundle` (the UTF8String DER of field 2) to `identifier`.
    static func deviceFields(bundle: [UInt8], identifier: UUID, opaque: [UInt8] = DER.opaque) -> [[UInt8]] {
        [attribute(4, opaque), attribute(5, deviceHash(bundle: bundle, identifier: identifier, opaque: opaque))]
    }

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

    /// SEQUENCEs nested `levels` deep with definite lengths, emitted front to back from precomputed sizes, so a
    /// 20 000-level nest costs its own size to build.
    static func definiteNest(levels: Int) -> [UInt8] {
        var sizes = [2]  // the innermost `30 00`
        for _ in 1..<max(levels, 1) { sizes.append(sizes[sizes.count - 1] + header(sizes[sizes.count - 1]).count) }
        var out: [UInt8] = []
        out.reserveCapacity(sizes[sizes.count - 1])
        for level in stride(from: levels - 1, through: 1, by: -1) { out += header(sizes[level - 1]) }
        return out + [0x30, 0x00]
    }

    static func header(_ contentLength: Int) -> [UInt8] {
        switch contentLength {
        case ..<0x80: return [0x30, UInt8(contentLength)]
        case ..<0x100: return [0x30, 0x81, UInt8(contentLength)]
        case ..<0x1_0000: return [0x30, 0x82, UInt8(contentLength >> 8), UInt8(contentLength & 0xFF)]
        default: return [0x30, 0x83, UInt8(contentLength >> 16), UInt8((contentLength >> 8) & 0xFF), UInt8(contentLength & 0xFF)]
        }
    }
}

struct Accepting: ReceiptVerifier { func isAuthentic(_ receipt: Data) -> Bool { true } }
struct Rejecting: ReceiptVerifier { func isAuthentic(_ receipt: Data) -> Bool { false } }

let receiptBundle = DER.utf8("com.ztron.app")

/// Type, bundle id, original version, original purchase date, then the device binding (fields 4 and 5).
let receiptFields = [
    DER.attribute(0, DER.utf8("Production")),
    DER.attribute(2, receiptBundle),
    DER.attribute(19, DER.utf8("116")),
    DER.attribute(18, DER.ia5("2024-03-01T10:00:00Z")),
] + DER.deviceFields(bundle: receiptBundle, identifier: fixtureDevice)

/// Build 116 was the last paid one; the fixtures' purchase date (2024-03-01) is inside the paid window.
let policy116 = GrandfatheringPolicy(
    lastPaidBuild: "116", paidWindow: DateInterval(start: Date(timeIntervalSince1970: 1_600_000_000), end: Date(timeIntervalSince1970: 1_710_000_000)))

func receiptClient(_ url: URL?, verifier: any ReceiptVerifier = Accepting(), bundle: String? = nil, device: UUID? = fixtureDevice) -> ReceiptClient {
    ReceiptClient(receiptURL: url, verifier: verifier, expectedBundleID: bundle, deviceIdentifier: { device })
}

func writeReceipt(_ data: Data) throws -> URL {
    let url = makeTemporaryPaywallDirectory().appendingPathComponent("receipt")
    try data.write(to: url)
    return url
}

/// Parses on the cooperative pool, whose threads have the smallest stacks the parse will ever run on.
@concurrent
private func parsesOffMain(_ bytes: [UInt8]) async -> Bool { ASN1.parse(bytes[...]) != nil }

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

    /// B2: Apple's receipt types, exactly. No prefix match: `ProductionStub` is not production.
    @Test(arguments: [
        ("Production", StoreEnvironment.production), ("ProductionVPP", .production),
        ("ProductionSandbox", .sandbox), ("ProductionVPPSandbox", .sandbox), ("Sandbox", .sandbox),
        ("Xcode", .xcode), ("ProductionStub", .xcode), ("production", .xcode), ("Production ", .xcode), ("", .xcode),
    ])
    func receipt_types_map_exactly(type: String, environment: StoreEnvironment) throws {
        #expect(ReceiptClient.environment(ofReceiptType: type) == environment)
        var typed = fields
        typed[0] = DER.attribute(0, DER.utf8(type))
        #expect(try ReceiptClient.parse(DER.receipt(fields: typed))?.environment == environment)
    }

    @Test func a_missing_type_is_xcode_and_the_default_policy_refuses_it() throws {
        #expect(ReceiptClient.environment(ofReceiptType: nil) == .xcode)
        let untyped = try #require(try ReceiptClient.parse(DER.receipt(fields: Array(fields[1...]))))
        #expect(untyped.environment == .xcode)
        #expect(!policy116.admits(untyped))
    }

    /// B2: the VPP receipts examined so far carry no original version or purchase date, and fail closed before
    /// the type is even read. One with a history would be a production purchase like any other.
    @Test func vpp_receipt_without_purchase_history_fails_closed() async throws {
        var vpp = fields
        vpp[0] = DER.attribute(0, DER.utf8("ProductionVPP"))
        var observed = vpp
        observed[2] = DER.attribute(19, DER.utf8(""))
        observed[3] = DER.attribute(18, DER.ia5(""))
        #expect(try ReceiptClient.parse(DER.receipt(fields: observed)) == nil)
        #expect(try ReceiptClient.parse(DER.receipt(fields: [vpp[0], vpp[1], vpp[4], vpp[5]])) == nil)  // 18 and 19 absent
        #expect(try await receiptClient(try writeReceipt(DER.receipt(fields: observed))).snapshot() == nil)
        let full = try #require(try ReceiptClient.parse(DER.receipt(fields: vpp)))
        #expect(full.environment == .production)
        #expect(policy116.admits(full))
    }

    /// B2: an empty version is no version, in the parser and in the rule (where "" would sort below every build and
    /// skip the "1.0" sentinel).
    @Test func empty_original_version_is_never_admitted() throws {
        var empty = fields
        empty[2] = DER.attribute(19, DER.utf8(""))
        #expect(try ReceiptClient.parse(DER.receipt(fields: empty)) == nil)
        var emptyBundle = fields
        emptyBundle[1] = DER.attribute(2, DER.utf8(""))
        #expect(try ReceiptClient.parse(DER.receipt(fields: emptyBundle)) == nil)
        let blank = AppTransactionSnapshot(
            bundleID: "com.ztron.app", originalAppVersion: "", originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            environment: .production, origin: .appTransaction)
        #expect(!policy116.admits(blank))
        var sentinelPolicy = policy116
        sentinelPolicy.legacySentinel = .init(onSaleWindow: policy116.paidWindow)
        #expect(!sentinelPolicy.admits(blank))
    }

    /// B2: the Volume Purchase expiration (field 21). A receipt past it is no purchase; before it, it is one.
    @Test func a_receipt_past_its_volume_purchase_expiration_fails_closed() async throws {
        let expiry = DER.attribute(21, DER.ia5("2026-06-01T00:00:00Z"))
        let url = try writeReceipt(DER.receipt(fields: fields + [expiry]))
        let before = ISO8601DateFormatter().date(from: "2026-05-31T23:59:59Z")!
        #expect(try await receiptClient(url).snapshot(now: before) != nil)
        #expect(try await receiptClient(url).snapshot(now: before.addingTimeInterval(1)) == nil)  // at the second: gone
        #expect(try await receiptClient(url).snapshot(now: before.addingTimeInterval(86_400)) == nil)
        #expect(try ReceiptClient.parse(DER.receipt(fields: fields + [expiry])) != nil, "parse has no clock")
        // A verified receipt whose expiration this build cannot read is Apple's output in a format we do not know,
        // not a forgery: it is honoured, like one without the field.
        let unreadable = try writeReceipt(DER.receipt(fields: fields + [DER.attribute(21, DER.ia5("soon"))]))
        #expect(try await receiptClient(unreadable).snapshot() != nil)
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

    @Test func missing_unverified_foreign_or_unverifiable_receipts_fail_closed() async throws {
        let url = makeTemporaryPaywallDirectory().appendingPathComponent("receipt")
        #expect(try await receiptClient(url).snapshot() == nil)  // missing
        try DER.receipt(fields: fields).write(to: url)
        #expect(try await receiptClient(url, verifier: Rejecting()).snapshot() == nil)
        #expect(try await receiptClient(url).snapshot()?.originalAppVersion == "116")
        #expect(try await receiptClient(url, bundle: "com.ztron.app").snapshot() != nil)
        #expect(try await receiptClient(url, bundle: "com.someone.else").snapshot() == nil)
        #expect(try await receiptClient(nil).snapshot() == nil)
        // The default client fails closed on a receipt Apple did not sign, whatever device it names.
        #expect(try await ReceiptClient(receiptURL: url, deviceIdentifier: { fixtureDevice }).snapshot() == nil)
    }

    /// A11+B6: field 5 binds the receipt to the device that bought it. The fixture identifier passes; another
    /// identifier, none at all, or a receipt without the two fields never does.
    @Test func the_receipt_is_bound_to_this_device() async throws {
        let url = try writeReceipt(DER.receipt(fields: fields))
        #expect(try await receiptClient(url).snapshot() != nil)
        #expect(try await receiptClient(url, device: otherFixtureDevice).snapshot() == nil)
        #expect(try await receiptClient(url, device: UUID()).snapshot() == nil)
        #expect(try await receiptClient(url, device: nil).snapshot() == nil, "no identifier (before first unlock): no snapshot")
        // Another device's receipt, planted here, is that device's and nobody else's.
        let base = Array(fields.prefix(4))
        let strangers = try writeReceipt(DER.receipt(fields: base + DER.deviceFields(bundle: receiptBundle, identifier: otherFixtureDevice)))
        #expect(try await receiptClient(strangers).snapshot() == nil)
        #expect(try await receiptClient(strangers, device: otherFixtureDevice).snapshot() != nil)
        // No fields 4 and 5; only field 4; only field 5; a hash of the wrong length; a hash over the bundle id's
        // bytes instead of field 2 as encoded; a hash over another opaque value.
        let variants: [[[UInt8]]] = [
            base, base + [fields[4]], base + [fields[5]], base + [fields[4], DER.attribute(5, [UInt8](repeating: 0, count: 19))],
            base + DER.deviceFields(bundle: Array("com.ztron.app".utf8), identifier: fixtureDevice),
            base + [fields[4], DER.attribute(5, DER.deviceHash(bundle: receiptBundle, identifier: fixtureDevice, opaque: [1]))],
        ]
        for variant in variants {
            #expect(try await receiptClient(try writeReceipt(DER.receipt(fields: variant))).snapshot() == nil)
        }
        // The pure parse never looks at the device; the device check is the client's.
        #expect(try ReceiptClient.parse(DER.receipt(fields: base)) != nil)
        #expect(!ReceiptClient.matchesDevice([:], identifier: fixtureDevice))
        #expect(ReceiptClient.matchesDevice(try ReceiptClient.receiptFields(DER.receipt(fields: fields)), identifier: fixtureDevice))
        #expect(!ReceiptClient.matchesDevice(try ReceiptClient.receiptFields(DER.receipt(fields: fields)), identifier: otherFixtureDevice))
    }

    /// The identifier the production client binds to: `identifierForVendor` where UIKit is, nothing elsewhere.
    @Test func the_platform_identifier_is_the_vendor_one_on_ios_and_none_elsewhere() async throws {
        #if canImport(UIKit) && !os(watchOS)
            #expect(await ReceiptClient.vendorIdentifier() != nil)
        #else
            #expect(await ReceiptClient.vendorIdentifier() == nil)
            let url = try writeReceipt(DER.receipt(fields: fields))
            #expect(try await ReceiptClient(receiptURL: url, verifier: Accepting(), expectedBundleID: nil).snapshot() == nil)
        #endif
    }

    /// B9: nesting is bounded at `ASN1.maxDepth` and refused there, before a crafted container costs anything. The
    /// parses run on the cooperative pool, whose threads have the smallest stacks the receipt path will ever see.
    @Test func nesting_is_refused_at_the_bound() async throws {
        var open: [UInt8] = []  // never closed
        for _ in 0..<100_000 { open += [0x30, 0x80] }
        let indefinite: [UInt8] = open + [UInt8](repeating: 0, count: 200_000)  // closed 100 000 times
        let definite = DER.definiteNest(levels: 20_000)
        #expect(definite.count > 60_000)
        let real = AppleReceiptVerifier(anchors: [ReceiptSignatureTests.testRoot])
        for crafted in [open, indefinite, definite] {
            #expect(await parsesOffMain(crafted) == false)
            let data = Data(crafted)
            #expect(!real.isAuthentic(data))
            #expect(throws: ReceiptClient.ReceiptError.malformed) { try ReceiptClient.parse(data) }
            let url = try writeReceipt(data)
            #expect(try await receiptClient(url, verifier: real).snapshot() == nil)
            await #expect(throws: ReceiptClient.ReceiptError.malformed) { try await receiptClient(url).snapshot() }
        }
        #expect(await parsesOffMain(DER.definiteNest(levels: ASN1.maxDepth)))
        #expect(await parsesOffMain(DER.definiteNest(levels: ASN1.maxDepth + 1)) == false)
        #expect(ASN1.parse(DER.definiteNest(levels: ASN1.maxDepth)[...])?.children.count == 1)
        #expect(ASN1.parse(DER.definiteNest(levels: 1)[...])?.children.isEmpty == true)
        #expect(ASN1.parse([0x30, 0x80, 0x30, 0x00, 0x00, 0x00][...])?.children.count == 1)
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
        // Nodes are slices of the input: a child's raw bytes sit inside its parent's.
        let parent = ASN1.parse([0x30, 0x05, 0x04, 0x03, 0x01, 0x02, 0x03][...])
        #expect(parent?.child(0)?.raw.startIndex == 2 && parent?.child(0)?.raw.endIndex == 7)
    }

    @Test func signed_data_model_skips_crls_and_refuses_the_wrong_shape() throws {
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
        // A signer whose signature is an INTEGER, not an OCTET STRING, is dropped too.
        let integerSignature = DER.tlv(0x30, DER.int(1) + DER.seq(DER.seq(DER.utf8("issuer")), DER.int(7)) + DER.seq(DER.sha256) + DER.seq(DER.rsa) + DER.int(5))
        #expect(SignedReceipt(DER.receipt(fields: fields, signers: [integerSignature]))?.signers.isEmpty == true)
        // A payload that is not DER has no fields, so the receipt parses to nothing; an attribute too short to be one
        // is skipped.
        let garbagePayload = Data(DER.seq(DER.signedData, DER.tlv(0xA0, DER.seq(DER.int(1), DER.set([]), DER.seq(DER.pkcs7Data, DER.tlv(0xA0, DER.octets([0x30, 0x05]))), DER.set([])))))
        #expect(SignedReceipt(garbagePayload)?.fields.isEmpty == true)
        #expect(try ReceiptClient.parse(garbagePayload) == nil)
        // Every way the container can stop short of its payload: no SignedData, an empty one, no encapsulated content,
        // content without the explicit tag, an explicit tag with nothing inside.
        for truncated in [
            DER.seq(DER.signedData),
            DER.seq(DER.signedData, DER.tlv(0xA0, [])),
            DER.seq(DER.signedData, DER.tlv(0xA0, DER.seq(DER.int(1), DER.set([])))),
            DER.seq(DER.signedData, DER.tlv(0xA0, DER.seq(DER.int(1), DER.set([]), DER.seq(DER.pkcs7Data)))),
            DER.seq(DER.signedData, DER.tlv(0xA0, DER.seq(DER.int(1), DER.set([]), DER.seq(DER.pkcs7Data, DER.tlv(0xA0, []))))),
        ] {
            #expect(SignedReceipt(Data(truncated)) == nil)
            #expect(throws: ReceiptClient.ReceiptError.malformed) { try ReceiptClient.parse(Data(truncated)) }
        }
        #expect(try ReceiptClient.parse(DER.receipt(fields: fields + [DER.seq(DER.int(19), DER.int(1))]))?.originalAppVersion == "116")
        #expect(ASN1.string([]) == nil && ASN1.string([0x0C]) == nil)
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
    func every_accepted_layout_verifies_and_parses(name: String) async throws {
        let receipt = try Self.fixture(name)
        #expect(verifier.isAuthentic(receipt))
        let snapshot = try await receiptClient(try writeReceipt(receipt), verifier: verifier, bundle: "com.ztron.app").snapshot()
        #expect(snapshot?.originalAppVersion == "116")
        #expect(snapshot?.environment == .production)
        #expect(snapshot?.accountKey == AppTransactionSnapshot(
            bundleID: "com.ztron.app", originalAppVersion: "116",
            originalPurchaseDate: ISO8601DateFormatter().date(from: "2024-03-01T10:00:00Z")!, environment: .production,
            origin: .receipt).accountKey)
        // The fixture's binding is what the script says it is.
        let fields = try ReceiptClient.receiptFields(receipt)
        #expect(fields[4] == DER.opaque)
        #expect(fields[5] == DER.deviceHash(bundle: receiptBundle, identifier: fixtureDevice))
    }

    /// A11+B6: a genuine receipt of another device, or one with no device binding, verifies and is still refused.
    @Test func a_receipt_bound_to_another_device_or_to_none_verifies_but_is_refused() async throws {
        let strangers = try Self.fixture("receipt-other-device")
        #expect(verifier.isAuthentic(strangers))
        let strangersURL = try writeReceipt(strangers)
        #expect(try await receiptClient(strangersURL, verifier: verifier, bundle: "com.ztron.app").snapshot() == nil)
        #expect(try await receiptClient(strangersURL, verifier: verifier, bundle: "com.ztron.app", device: otherFixtureDevice).snapshot()?.originalAppVersion == "116")
        let unbound = try Self.fixture("receipt-no-device-hash")
        #expect(verifier.isAuthentic(unbound))
        #expect(try ReceiptClient.parse(unbound)?.originalAppVersion == "116", "the pure parse still reads it")
        for device in [fixtureDevice, otherFixtureDevice, UUID(), nil] {
            #expect(try await receiptClient(try writeReceipt(unbound), verifier: verifier, device: device).snapshot() == nil)
        }
        let mine = try writeReceipt(try Self.fixture("receipt-sha256"))
        #expect(try await receiptClient(mine, verifier: verifier, device: UUID()).snapshot() == nil)
        #expect(try await receiptClient(mine, verifier: verifier, device: nil).snapshot() == nil)
    }

    /// A11+B6 through the facade: a grandfather read from this device's receipt is cached and kept on a launch where
    /// no identifier is available (the receipt answers nothing, the cache stands), and another install with a
    /// stranger's genuine receipt planted in its container is granted nothing.
    @MainActor
    @Test func a_receipt_grandfather_is_kept_without_an_identifier_and_a_strangers_receipt_grants_nothing() async throws {
        let mine = try writeReceipt(try Self.fixture("receipt-sha256"))
        let strangers = try writeReceipt(try Self.fixture("receipt-other-device"))
        func answer(_ url: URL, device: UUID?) async throws -> AppTransactionSnapshot? {
            try await receiptClient(url, verifier: verifier, bundle: "com.ztron.app", device: device).snapshot()
        }
        let paywall = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.fileKeyStore = InMemoryFileKeyStore()
        configuration.grandfathering = policy116
        configuration.welcomeTokens = 0
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        configuration.store = FakeStore(app: try await answer(mine, device: fixtureDevice), products: products)
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        await settle()
        #expect(paywall.entitlement == .lifetime(.grandfathered(originalAppVersion: "116")))
        #expect(paywall.canPass(.paid))
        // Relaunch before first unlock: no identifier, so no snapshot, so the cached grandfather stands.
        configuration.store = FakeStore(app: try await answer(mine, device: nil), products: products)
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        await settle()
        #expect(paywall.entitlement == .lifetime(.grandfathered(originalAppVersion: "116")))
        // Another install, this device, a stranger's genuine receipt planted in the container.
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.store = FakeStore(app: try await answer(strangers, device: fixtureDevice), products: products)
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        await settle()
        #expect(paywall.entitlement == .free)
        #expect(!paywall.canPass(.paid))
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

    @Test func receipt_for_another_app_verifies_but_is_not_this_apps() async throws {
        let receipt = try Self.fixture("receipt-other-bundle")
        #expect(verifier.isAuthentic(receipt))
        let url = try writeReceipt(receipt)
        #expect(try await receiptClient(url, verifier: verifier, bundle: "com.ztron.app").snapshot() == nil)
        // The hash covers field 2 as the other app's receipt encodes it, so the binding holds for that app's id.
        #expect(try await receiptClient(url, verifier: verifier).snapshot()?.bundleID == "com.other.app")
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
        #expect(!AppleReceiptVerifier.hasExtension("1.2", in: DER.seq(DER.seq(DER.int(1), DER.tlv(0xA3, [])))), "an empty extensions block")
        #expect(!AppleReceiptVerifier.hasExtension("1.2", in: [0x30]))
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

        /// Real receipts, signed by Apple's production chain. Purchase receipts (`Production`) verify, parse and
        /// carry the device binding; the `ProductionStub` receipts Apple ships with its bundled apps carry no
        /// original version and fail closed in the parser (Apple also signs those with an already-expired
        /// certificate, so they are not asserted authentic). Nothing on this machine chains to the test root, and a
        /// Mac receipt is bound to the Mac's GUID, which is not an `identifierForVendor`: no identifier matches it.
        @Test(.enabled(if: !macAppStoreReceipts.isEmpty, "no Mac App Store receipts on this machine"))
        func every_mac_app_store_receipt_on_this_mac_verifies() async throws {
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
                    #expect(model.fields[4] != nil && model.fields[5]?.count == 20, "\(url.path): no device binding")
                    #expect(try await ReceiptClient(receiptURL: url, expectedBundleID: nil, deviceIdentifier: { UUID() }).snapshot() == nil)
                default:
                    #expect(snapshot == nil, "\(url.path): a stub receipt must never grandfather")
                }
            }
            print("verified \(purchases) Mac App Store purchase receipts of \(Self.macAppStoreReceipts.count)")
        }
    #endif
}

/// The payload of an `AppTransaction` JWS (`VerificationResult<AppTransaction>.jwsRepresentation`), decoded the way
/// `StoreKit2Client` maps the typed value: for comparing Apple's two sources for one install.
enum AppTransactionJWS {
    struct Payload: Decodable {
        let bundleId: String
        let originalApplicationVersion: String
        let originalPurchaseDate: Double  // milliseconds since 1970
        let receiptType: String
        let appTransactionId: String?
    }

    static func snapshot(_ jws: String) -> AppTransactionSnapshot? {
        let parts = jws.split(separator: ".")
        guard parts.count == 3, let data = base64URL(String(parts[1])), let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        let environment: StoreEnvironment =
            switch payload.receiptType {
            case "Production": .production
            case "Sandbox": .sandbox
            default: .xcode
            }
        return AppTransactionSnapshot(
            bundleID: payload.bundleId, originalAppVersion: payload.originalApplicationVersion,
            originalPurchaseDate: Date(timeIntervalSince1970: payload.originalPurchaseDate / 1000), environment: environment,
            appTransactionID: payload.appTransactionId.flatMap(StoreKit2Client.normalizedAppTransactionID), origin: .appTransaction,
            signedPayload: Data(jws.utf8))
    }

    static func base64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    /// A JWS with the given payload and an unverifiable signature: enough for the decoder.
    static func make(_ payload: [String: Any]) -> String {
        let json = try! JSONSerialization.data(withJSONObject: payload)
        let segment = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJFUzI1NiJ9.\(segment).c2ln"
    }
}

@Suite("AppTransaction JWS decoding")
struct AppTransactionJWSTests {
    @Test func decodes_the_fields_the_key_and_the_mapping_use() throws {
        let jws = AppTransactionJWS.make([
            "bundleId": "com.ztron.app", "originalApplicationVersion": "116", "originalPurchaseDate": 1_709_287_200_600,
            "receiptType": "Production", "appTransactionId": "",
        ])
        let snapshot = try #require(AppTransactionJWS.snapshot(jws))
        #expect(snapshot.bundleID == "com.ztron.app" && snapshot.originalAppVersion == "116")
        #expect(snapshot.originalPurchaseDate == Date(timeIntervalSince1970: 1_709_287_200.6))
        #expect(snapshot.environment == .production && snapshot.origin == .appTransaction)
        #expect(snapshot.appTransactionID == nil, "an empty id is no id, as in the client")
        #expect(snapshot.signedPayload == Data(jws.utf8))
        #expect(AppTransactionJWS.snapshot(AppTransactionJWS.make(["bundleId": "x", "originalApplicationVersion": "1", "originalPurchaseDate": 0, "receiptType": "Sandbox"]))?.environment == .sandbox)
        #expect(AppTransactionJWS.snapshot(AppTransactionJWS.make(["bundleId": "x", "originalApplicationVersion": "1", "originalPurchaseDate": 0, "receiptType": "Xcode", "appTransactionId": "7"]))?.appTransactionID == "7")
        #expect(AppTransactionJWS.snapshot("a.b") == nil)
        #expect(AppTransactionJWS.snapshot("a.!!.c") == nil)
    }
}

private let productionReceiptPath = ProcessInfo.processInfo.environment["PAYWALL_PRODUCTION_RECEIPT"]
private let productionAppTransactionPath = ProcessInfo.processInfo.environment["PAYWALL_PRODUCTION_APP_TRANSACTION"]
private let productionDeviceID = ProcessInfo.processInfo.environment["PAYWALL_PRODUCTION_DEVICE_ID"].flatMap(UUID.init(uuidString:))

/// A production receipt of the app under test, when `PAYWALL_PRODUCTION_RECEIPT` names one. An App Store install
/// keeps it at `Bundle.main.appStoreReceiptURL`; for an iOS app on an Apple silicon Mac that is
/// `~/Library/Containers/<bundle id>/Data/StoreKit/receipt`. It is Apple's real output, so the verifier, the parser,
/// the grandfathering rule and the engine run over it, with expectations taken from the receipt itself. A receipt
/// names its app, so none is committed and CI skips the suite. `PAYWALL_PRODUCTION_DEVICE_ID` (the install's
/// `identifierForVendor`) proves the device binding positively; `PAYWALL_PRODUCTION_APP_TRANSACTION` (a file holding
/// the same install's `AppTransaction` JWS) proves the account-key parity of Apple's two sources.
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

    @Test func parses_what_the_rule_uses_and_the_client_binds_it_to_its_app_and_device() async throws {
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
        // A11+B6: Apple bound it to the device that bought it (fields 4 and 5). Copied here, it is refused: a random
        // identifier, or none, never matches; the install's own `identifierForVendor` does, when the lane names it.
        #expect(fields[4] != nil && fields[5]?.count == 20)
        let url = try writeReceipt(receipt)
        #expect(try await ReceiptClient(receiptURL: url, expectedBundleID: snapshot.bundleID, deviceIdentifier: { UUID() }).snapshot() == nil)
        #expect(try await ReceiptClient(receiptURL: url, expectedBundleID: snapshot.bundleID, deviceIdentifier: { nil }).snapshot() == nil)
        #expect(!ReceiptClient.matchesDevice(fields, identifier: UUID()))
        if let productionDeviceID {
            #expect(ReceiptClient.matchesDevice(fields, identifier: productionDeviceID))
            #expect(try await ReceiptClient(receiptURL: url, expectedBundleID: snapshot.bundleID, deviceIdentifier: { productionDeviceID }).snapshot() == snapshot)
            #expect(try await ReceiptClient(receiptURL: url, expectedBundleID: "com.ztron.app", deviceIdentifier: { productionDeviceID }).snapshot() == nil)
        }
        print("production receipt: \(snapshot.bundleID) build \(snapshot.originalAppVersion), bought \(snapshot.originalPurchaseDate), created \(created), device \(productionDeviceID == nil ? "unnamed" : "matched")")
    }

    /// B13: the parity claim at `StoreClient.accountKey`, against Apple's two sources for one install. The receipt
    /// path and the `AppTransaction` path must bind the same key, or the install's tokens would move between two
    /// partitions whenever the source changes.
    @Test(.enabled(if: productionAppTransactionPath != nil, "set PAYWALL_PRODUCTION_APP_TRANSACTION to a file holding the install's AppTransaction JWS"))
    func the_same_installs_app_transaction_derives_the_receipts_account_key() throws {
        let receipt = try Self.snapshot()
        let jws = try String(contentsOf: URL(fileURLWithPath: try #require(productionAppTransactionPath)), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = try #require(AppTransactionJWS.snapshot(jws), "not an AppTransaction JWS")
        #expect(app.bundleID == receipt.bundleID)
        #expect(app.originalAppVersion == receipt.originalAppVersion)
        #expect(app.environment == receipt.environment)
        #expect(floor(app.originalPurchaseDate.timeIntervalSince1970) == floor(receipt.originalPurchaseDate.timeIntervalSince1970))
        #expect(app.accountKey == receipt.accountKey)
        print("account key parity: receipt and AppTransaction agree on \(app.bundleID) build \(app.originalAppVersion)")
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
        configuration.fileKeyStore = InMemoryFileKeyStore()
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
