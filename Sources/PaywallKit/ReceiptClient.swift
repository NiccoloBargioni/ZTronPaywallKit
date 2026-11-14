public import Foundation
public import PaywallCore

/// Decides whether an App Store receipt is Apple's. `AppleReceiptVerifier` checks the PKCS#7 signature against
/// the Apple Root CA; tests inject acceptors and rejectors.
public protocol ReceiptVerifier: Sendable {
    func isAuthentic(_ receipt: Data) -> Bool
}

/// The iOS 15 source of the app transaction: reads the App Store receipt on disk, verifies it, checks that it was
/// issued to this app, and extracts the original application version (field 19), original purchase date (field
/// 18), bundle id (field 2) and receipt type (field 0). Never issues `SKReceiptRefreshRequest`: a missing receipt
/// fails closed.
public struct ReceiptClient: Sendable {
    public var receiptURL: URL?
    public var verifier: any ReceiptVerifier
    /// The bundle id the receipt must name (field 2). `nil` skips the check; the default is this app's.
    public var expectedBundleID: String?

    public init(
        receiptURL: URL? = Bundle.main.appStoreReceiptURL,
        verifier: any ReceiptVerifier = AppleReceiptVerifier(),
        expectedBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.receiptURL = receiptURL
        self.verifier = verifier
        self.expectedBundleID = expectedBundleID
    }

    public enum ReceiptError: Error, Hashable, Sendable {
        case malformed
    }

    /// `nil` when there is no receipt, it does not verify, it names another app, or it lacks field 19 or 18.
    public func snapshot() throws -> AppTransactionSnapshot? {
        guard let receiptURL, let data = FileManager.default.contents(atPath: receiptURL.path) else { return nil }
        guard verifier.isAuthentic(data), let parsed = try Self.parse(data) else { return nil }
        if let expectedBundleID, parsed.bundleID != expectedBundleID { return nil }
        return parsed
    }

    /// Pure: parses a DER/BER PKCS#7 receipt. Returns `nil` when field 19, 18 or 2 is missing.
    public static func parse(_ data: Data) throws -> AppTransactionSnapshot? {
        let fields = try receiptFields(data)
        guard let version = fields[19].flatMap(ASN1.string), let dateString = fields[18].flatMap(ASN1.string),
            let date = parseDate(dateString), let bundleID = fields[2].flatMap(ASN1.string)
        else { return nil }
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
        guard let signed = SignedReceipt(data) else { throw ReceiptError.malformed }
        return signed.fields
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

/// The PKCS#7 `SignedData` container of a receipt, reduced to what verification and parsing need.
struct SignedReceipt {
    struct Signer {
        var digestAlgorithm: String
        var signatureAlgorithm: String
        /// The `[0] IMPLICIT SignedAttributes` node when present; Apple's receipts carry none.
        var signedAttributes: ASN1.Node?
        var signature: [UInt8]

        init?(_ node: ASN1.Node) {
            // SignerInfo ::= SEQUENCE { version, sid, digestAlgorithm, signedAttrs [0] OPTIONAL,
            //                           signatureAlgorithm, signature, unsignedAttrs [1] OPTIONAL }
            guard node.tag == 0x30, let digest = node.child(2)?.child(0)?.objectIdentifier else { return nil }
            var index = 3
            if node.child(index)?.tag == 0xA0 {
                signedAttributes = node.child(index)
                index += 1
            }
            guard let algorithm = node.child(index)?.child(0)?.objectIdentifier, let signature = node.child(index + 1),
                signature.tag == 0x04
            else { return nil }
            digestAlgorithm = digest
            signatureAlgorithm = algorithm
            self.signature = signature.octetBytes
        }
    }

    static let signedDataOID = "1.2.840.113549.1.7.2"

    /// The eContent: the receipt payload, a SET OF attributes.
    let payload: [UInt8]
    /// Every certificate in the container, DER encoded.
    let certificates: [[UInt8]]
    let signers: [Signer]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        // ContentInfo { contentType, [0] EXPLICIT SignedData { version, digestAlgorithms, encapContentInfo,
        //               certificates [0] IMPLICIT OPTIONAL, crls [1] IMPLICIT OPTIONAL, signerInfos } }
        guard let root = ASN1.parse(bytes[...]), root.child(0)?.objectIdentifier == Self.signedDataOID,
            let signed = root.child(1)?.child(0),
            let encap = signed.child(2),
            let explicit = encap.child(1),
            let octets = explicit.child(0)
        else { return nil }
        payload = octets.octetBytes
        var index = 3
        var certificates: [[UInt8]] = []
        if let set = signed.child(index), set.tag == 0xA0 {
            certificates = set.children.map(\.raw)
            index += 1
        }
        if signed.child(index)?.tag == 0xA1 { index += 1 }
        guard let signerInfos = signed.child(index), signerInfos.tag == 0x31 else { return nil }
        self.certificates = certificates
        self.signers = signerInfos.children.compactMap(Signer.init)
    }

    /// Attribute type → value bytes, from the payload's `SET OF { type INTEGER, version INTEGER, value OCTET STRING }`.
    var fields: [Int: [UInt8]] {
        guard let set = ASN1.parse(payload[...]) else { return [:] }
        var fields: [Int: [UInt8]] = [:]
        for attribute in set.children {
            guard attribute.children.count >= 3, let type = attribute.children[0].integer else { continue }
            fields[type] = attribute.children[2].octetBytes
        }
        return fields
    }
}

/// A minimal DER/BER reader: enough for PKCS#7 containers and X.509 certificates, including indefinite lengths.
enum ASN1 {
    struct Node {
        var tag: UInt8
        var contents: [UInt8]
        var children: [Node]
        /// The element as encoded: tag, length and contents (or the end-of-contents marker).
        var raw: [UInt8]

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

        /// Dotted OBJECT IDENTIFIER, `nil` for any other tag or an overlong arc.
        var objectIdentifier: String? {
            guard tag == 0x06, !contents.isEmpty else { return nil }
            var arcs: [UInt64] = []
            var value: UInt64 = 0
            var length = 0
            for byte in contents {
                guard length < 9 else { return nil }
                value = value << 7 | UInt64(byte & 0x7F)
                length += 1
                if byte & 0x80 == 0 {
                    arcs.append(value)
                    value = 0
                    length = 0
                }
            }
            guard length == 0, let first = arcs.first else { return nil }
            let head: [UInt64] = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80]
            return (head + arcs.dropFirst()).map(String.init).joined(separator: ".")
        }
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> Node? {
        var index = bytes.startIndex
        return parseNode(bytes, &index)
    }

    private static func parseNode(_ bytes: ArraySlice<UInt8>, _ index: inout Int) -> Node? {
        let start = index
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
            return Node(tag: tag, contents: [], children: children, raw: Array(bytes[start..<index]))
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
        return Node(tag: tag, contents: Array(contents), children: children, raw: Array(bytes[start..<index]))
    }

    /// A receipt value is the DER of a UTF8String or IA5String.
    static func string(_ valueBytes: [UInt8]) -> String? {
        guard let node = parse(valueBytes[...]), node.tag == 0x0C || node.tag == 0x16 else { return nil }
        return String(decoding: node.contents, as: UTF8.self)
    }
}
