public import Foundation
public import PaywallCore

/// Checks the PKCS#7 signature of an App Store receipt against Apple's root certificate.
///
/// Open decision in the design: depend on TPInAppReceipt or write the in-house verifier. Until a verifier is
/// supplied, `ReceiptClient` fails closed, so an iOS 15 device is never grandfathered on an unverified receipt.
public protocol ReceiptVerifier: Sendable {
    func isAuthentic(_ receipt: Data) -> Bool
}

/// The iOS 15 source of the app transaction: reads the App Store receipt on disk, verifies it, and extracts the
/// original application version (field 19), original purchase date (field 18), bundle id (field 2) and receipt
/// type (field 0). Never issues `SKReceiptRefreshRequest`: a missing receipt fails closed.
public struct ReceiptClient: Sendable {
    public var receiptURL: URL?
    public var verifier: (any ReceiptVerifier)?

    public init(receiptURL: URL? = Bundle.main.appStoreReceiptURL, verifier: (any ReceiptVerifier)? = nil) {
        self.receiptURL = receiptURL
        self.verifier = verifier
    }

    public enum ReceiptError: Error, Hashable, Sendable {
        case malformed
    }

    /// `nil` when there is no receipt, it does not verify, or it lacks field 19.
    public func snapshot() throws -> AppTransactionSnapshot? {
        guard let receiptURL, let data = FileManager.default.contents(atPath: receiptURL.path) else { return nil }
        guard let verifier, verifier.isAuthentic(data) else { return nil }
        return try Self.parse(data)
    }

    /// Pure: parses a DER/BER PKCS#7 receipt. Returns `nil` when field 19 or 18 is missing.
    public static func parse(_ data: Data) throws -> AppTransactionSnapshot? {
        let fields = try receiptFields(data)
        guard let version = fields[19].flatMap(ASN1.string), let dateString = fields[18].flatMap(ASN1.string),
            let date = parseDate(dateString)
        else { return nil }
        let bundleID = fields[2].flatMap(ASN1.string) ?? Bundle.main.bundleIdentifier ?? ""
        let environment: StoreEnvironment
        switch fields[0].flatMap(ASN1.string) {
        case "Production"?: environment = .production
        case "ProductionSandbox"?, "Sandbox"?: environment = .sandbox
        default: environment = .xcode
        }
        return AppTransactionSnapshot(
            bundleID: bundleID, originalAppVersion: version, originalPurchaseDate: date, environment: environment,
            origin: .receipt, signedPayload: data)
    }

    /// The receipt's attribute set: type → value bytes (the DER of the value's inner element).
    static func receiptFields(_ data: Data) throws -> [Int: [UInt8]] {
        let bytes = [UInt8](data)
        guard let root = ASN1.parse(bytes[...]),
            let signed = root.child(1)?.child(0),  // [0] EXPLICIT SignedData
            let encap = signed.child(2),  // encapContentInfo
            let explicit = encap.child(1),  // [0] EXPLICIT
            let octets = explicit.child(0),
            let payload = ASN1.parse(octets.octetBytes[...])
        else { throw ReceiptError.malformed }
        var fields: [Int: [UInt8]] = [:]
        for attribute in payload.children {
            guard attribute.children.count >= 3, let type = attribute.children[0].integer else { continue }
            fields[type] = attribute.children[2].octetBytes
        }
        return fields
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

/// A minimal DER/BER reader: enough for PKCS#7 containers, including indefinite lengths.
enum ASN1 {
    struct Node {
        var tag: UInt8
        var contents: [UInt8]
        var children: [Node]

        var isConstructed: Bool { tag & 0x20 != 0 }

        func child(_ index: Int) -> Node? { index < children.count ? children[index] : nil }

        /// OCTET STRING contents, concatenating the segments of a constructed (BER) one.
        var octetBytes: [UInt8] {
            isConstructed ? children.flatMap(\.octetBytes) : contents
        }

        var integer: Int? {
            guard tag == 0x02, !contents.isEmpty, contents.count <= 8 else { return nil }
            return contents.reduce(0) { $0 << 8 | Int($1) }
        }
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> Node? {
        var index = bytes.startIndex
        return parseNode(bytes, &index)
    }

    private static func parseNode(_ bytes: ArraySlice<UInt8>, _ index: inout Int) -> Node? {
        guard index < bytes.endIndex else { return nil }
        let tag = bytes[index]
        index += 1
        guard index < bytes.endIndex else { return nil }
        let first = bytes[index]
        index += 1
        let constructed = tag & 0x20 != 0
        if first == 0x80 {
            // Indefinite length: children until the end-of-contents marker.
            guard constructed else { return nil }
            var children: [Node] = []
            while index + 1 < bytes.endIndex, !(bytes[index] == 0 && bytes[index + 1] == 0) {
                guard let child = parseNode(bytes, &index) else { return nil }
                children.append(child)
            }
            guard index + 1 < bytes.endIndex else { return nil }
            index += 2
            return Node(tag: tag, contents: [], children: children)
        }
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count <= 4, index + count <= bytes.endIndex else { return nil }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length <= bytes.endIndex - index else { return nil }
        let contents = bytes[index..<(index + length)]
        index += length
        var children: [Node] = []
        if constructed {
            var inner = contents.startIndex
            while inner < contents.endIndex {
                guard let child = parseNode(contents, &inner) else { return nil }
                children.append(child)
            }
        }
        return Node(tag: tag, contents: Array(contents), children: children)
    }

    /// A receipt value is the DER of a UTF8String or IA5String.
    static func string(_ valueBytes: [UInt8]) -> String? {
        guard let node = parse(valueBytes[...]), node.tag == 0x0C || node.tag == 0x16 else { return nil }
        return String(decoding: node.contents, as: UTF8.self)
    }
}
