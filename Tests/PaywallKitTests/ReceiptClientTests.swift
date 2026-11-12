import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// A tiny DER writer for synthetic receipts.
private enum DER {
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
    static let oid: [UInt8] = tlv(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])

    static func attribute(_ type: Int, _ value: [UInt8]) -> [UInt8] { seq(int(type), int(1), octets(value)) }

    /// ContentInfo { oid, [0] SignedData { version, digestAlgs, encap { oid, [0] OCTET STRING payload } } }
    static func receipt(fields: [[UInt8]], indefinite: Bool = false) -> Data {
        let payload = set(fields)
        let encap = seq(oid, tlv(0xA0, octets(payload)))
        let signed = seq(int(1), set([]), encap)
        if indefinite {
            let explicit: [UInt8] = [0xA0, 0x80] + signed + [0, 0]
            return Data([0x30, 0x80] + oid + explicit + [0, 0])
        }
        return Data(seq(oid, tlv(0xA0, signed)))
    }
}

private struct Accepting: ReceiptVerifier { func isAuthentic(_ receipt: Data) -> Bool { true } }
private struct Rejecting: ReceiptVerifier { func isAuthentic(_ receipt: Data) -> Bool { false } }

@Suite("Receipt (iOS 15 path)")
struct ReceiptClientTests {
    let fields = [
        DER.attribute(0, DER.utf8("Production")),
        DER.attribute(2, DER.utf8("com.ztron.app")),
        DER.attribute(19, DER.utf8("116")),
        DER.attribute(18, DER.ia5("2024-03-01T10:00:00Z")),
    ]

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

    @Test func receipt_without_field_19_fails_closed() throws {
        #expect(try ReceiptClient.parse(DER.receipt(fields: Array(fields.prefix(2)) + [fields[3]])) == nil)
    }

    @Test func fractional_seconds_dates_parse() throws {
        var fractional = fields
        fractional[3] = DER.attribute(18, DER.ia5("2024-03-01T10:00:00.123Z"))
        #expect(try ReceiptClient.parse(DER.receipt(fields: fractional)) != nil)
    }

    @Test func malformed_receipt_throws() {
        #expect(throws: ReceiptClient.ReceiptError.malformed) { try ReceiptClient.parse(Data([0x30, 0x03, 0x02, 0x01])) }
        #expect(throws: ReceiptClient.ReceiptError.malformed) { try ReceiptClient.parse(Data([0x30, 0x80, 0x02])) }
    }

    @Test func missing_unverified_or_unverifiable_receipts_fail_closed() throws {
        let url = makeTemporaryPaywallDirectory().appendingPathComponent("receipt")
        #expect(try ReceiptClient(receiptURL: url, verifier: Accepting()).snapshot() == nil)  // missing
        try DER.receipt(fields: fields).write(to: url)
        #expect(try ReceiptClient(receiptURL: url, verifier: nil).snapshot() == nil)  // no verifier
        #expect(try ReceiptClient(receiptURL: url, verifier: Rejecting()).snapshot() == nil)
        #expect(try ReceiptClient(receiptURL: url, verifier: Accepting()).snapshot()?.originalAppVersion == "116")
        #expect(try ReceiptClient(receiptURL: nil, verifier: Accepting()).snapshot() == nil)
    }

    @Test func asn1_integers_and_strings() {
        #expect(ASN1.parse([0x02, 0x02, 0x01, 0x00][...])?.integer == 256)
        #expect(ASN1.parse([0x04, 0x00][...])?.integer == nil)
        #expect(ASN1.string([0x04, 0x01, 0x41]) == nil)
        #expect(ASN1.parse([0x30, 0x85, 0, 0, 0, 0, 1][...]) == nil)
        #expect(ASN1.parse([][...]) == nil)
    }
}
