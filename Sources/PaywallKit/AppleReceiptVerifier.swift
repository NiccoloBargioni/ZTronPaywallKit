import CryptoKit
public import Foundation
import Security

/// Verifies an App Store receipt the way Apple's receipt validation guide did on the device, without OpenSSL:
///
/// 1. The container is PKCS#7 `SignedData` with exactly the layout Apple emits (no signed attributes, RSA
///    PKCS#1 v1.5 over the payload with SHA-256, SHA-1 on older receipts). Signed attributes are accepted too,
///    with the `messageDigest` attribute checked against the payload.
/// 2. The signer certificate is found in the container and its chain is evaluated with the Apple Root CA as the
///    only anchor, **at the receipt's creation date** (field 12): Apple rotates the signing certificate every
///    few years and a receipt signed in 2015 stays valid after its certificate expired.
/// 3. The signer certificate carries Apple's receipt-signing marker extension, so a certificate Apple issued for
///    anything else (a developer's own code-signing identity also chains to the Apple Root CA) cannot sign one.
///
/// The container is parsed first (the parser is bounded in depth and copies nothing), then the signature is checked
/// over the parsed payload. Fails closed on any parse error, unknown algorithm, missing certificate or trust failure.
/// No network: the evaluation never fetches a CRL or OCSP response.
public struct AppleReceiptVerifier: ReceiptVerifier {
    /// Apple Inc. Root Certificate, SHA-256 b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024, as the
    /// system trust store ships it and as https://www.apple.com/certificateauthority/ publishes it.
    public static let appleRootCA = Data(base64Encoded: "MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0MDM2WhcNMzUwMjA5MjE0MDM2WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne+Uts9QerIjAC6Bg++FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4UadHJGXL1XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9wtj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IWq6NxkkdTVcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKMaLOPHd5lc/9nXmW8Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wggERBgNVHSAEggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCBthqBs1JlbGlhbmNlIG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBjb25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZpY2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBcNplMLXi37Yyb3PN3m/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQPy3lPNNiiPvl4/2vIB+x9OYOLUyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7R6PVbyTi69G3cN8PReEnyvFteO3ntRcXqNx+IjXKJdXZD9Zr1KIkIxH3oayPc4FgxhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uujL/lTaltkwGMzd/c6ByxW69oPIQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIqxw8dtk2cXmPIS4AXUKqK1drk/NAJBzewdXUh")!

    /// The extension every "Mac App Store and iTunes Store Receipt Signing" certificate carries.
    public static let receiptSigningMarker = "1.2.840.113635.100.6.11.1"

    /// DER certificates the chain must end in. Tests pass their own root.
    public var anchors: [Data]
    /// An extension OID the signer certificate must carry; `nil` accepts any certificate that chains.
    public var requiredSignerMarker: String?

    public init(anchors: [Data] = [Self.appleRootCA], requiredSignerMarker: String? = Self.receiptSigningMarker) {
        self.anchors = anchors
        self.requiredSignerMarker = requiredSignerMarker
    }

    public func isAuthentic(_ receipt: Data) -> Bool {
        guard let signed = SignedReceipt(receipt), !signed.signers.isEmpty, !signed.certificates.isEmpty else {
            return false
        }
        let certificates = signed.certificates.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        guard certificates.count == signed.certificates.count else { return false }
        let anchors = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard anchors.count == self.anchors.count, !anchors.isEmpty else { return false }
        let verifyDate = signed.fields[12].flatMap(ASN1.string).flatMap(ReceiptClient.parseDate) ?? Date()

        for signer in signed.signers {
            guard let algorithm = Self.keyAlgorithm(for: signer), let message = Self.signedMessage(of: signer, over: signed.payload)
            else { continue }
            for (index, candidate) in certificates.enumerated() {
                if let marker = requiredSignerMarker, !Self.hasExtension(marker, in: signed.certificates[index]) { continue }
                guard let key = SecCertificateCopyKey(candidate),
                    SecKeyVerifySignature(key, algorithm, message as CFData, Data(signer.signature) as CFData, nil)
                else { continue }
                var others = certificates
                others.remove(at: index)
                if Self.chains([candidate] + others, to: anchors, at: verifyDate) { return true }
            }
        }
        return false
    }

    // MARK: Signature

    private static let digestOIDs: [String: SecKeyAlgorithm] = [
        "1.3.14.3.2.26": .rsaSignatureMessagePKCS1v15SHA1,
        "2.16.840.1.101.3.4.2.1": .rsaSignatureMessagePKCS1v15SHA256,
        "2.16.840.1.101.3.4.2.2": .rsaSignatureMessagePKCS1v15SHA384,
        "2.16.840.1.101.3.4.2.3": .rsaSignatureMessagePKCS1v15SHA512,
    ]

    /// `rsaEncryption`, or the `shaNWithRSAEncryption` that names the same digest as `digestAlgorithm`.
    private static let rsaSignatureOIDs: [String: String?] = [
        "1.2.840.113549.1.1.1": nil,
        "1.2.840.113549.1.1.5": "1.3.14.3.2.26",
        "1.2.840.113549.1.1.11": "2.16.840.1.101.3.4.2.1",
        "1.2.840.113549.1.1.12": "2.16.840.1.101.3.4.2.2",
        "1.2.840.113549.1.1.13": "2.16.840.1.101.3.4.2.3",
    ]

    static func keyAlgorithm(for signer: SignedReceipt.Signer) -> SecKeyAlgorithm? {
        guard let algorithm = digestOIDs[signer.digestAlgorithm],
            let boundDigest = rsaSignatureOIDs[signer.signatureAlgorithm],
            boundDigest == nil || boundDigest == signer.digestAlgorithm
        else { return nil }
        return algorithm
    }

    /// What the signature covers: the payload itself, or the DER of the signed attributes (re-tagged as a SET),
    /// whose `messageDigest` must then equal the payload's digest.
    static func signedMessage(of signer: SignedReceipt.Signer, over payload: [UInt8]) -> Data? {
        guard let attributes = signer.signedAttributes else { return Data(payload) }
        let messageDigest = attributes.children.first { $0.child(0)?.objectIdentifier == "1.2.840.113549.1.9.4" }
        guard let expected = messageDigest?.child(1)?.child(0)?.octetBytes, let actual = digest(payload, signer.digestAlgorithm),
            expected == actual
        else { return nil }
        // A copy: the node's bytes are a slice of the receipt, which stays as read.
        var set = Array(attributes.raw)
        set[0] = 0x31
        return Data(set)
    }

    static func digest(_ bytes: [UInt8], _ oid: String) -> [UInt8]? {
        let data = Data(bytes)
        switch oid {
        case "1.3.14.3.2.26": return Array(Insecure.SHA1.hash(data: data))
        case "2.16.840.1.101.3.4.2.1": return Array(SHA256.hash(data: data))
        case "2.16.840.1.101.3.4.2.2": return Array(SHA384.hash(data: data))
        case "2.16.840.1.101.3.4.2.3": return Array(SHA512.hash(data: data))
        default: return nil
        }
    }

    // MARK: Certificates

    /// Whether the certificate's extensions include `oid`.
    static func hasExtension(_ oid: String, in certificate: [UInt8]) -> Bool {
        // Certificate { tbsCertificate { ..., extensions [3] EXPLICIT { SEQUENCE OF { OID, critical?, OCTET STRING } } }, ... }
        guard let tbs = ASN1.parse(certificate[...])?.child(0),
            let extensions = tbs.children.last(where: { $0.tag == 0xA3 })?.child(0)
        else { return false }
        return extensions.children.contains { $0.child(0)?.objectIdentifier == oid }
    }

    /// `ordered[0]` is the candidate leaf; the rest are intermediates the evaluation may use.
    static func chains(_ ordered: [SecCertificate], to anchors: [SecCertificate], at date: Date) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(ordered as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
            let trust,
            SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
            SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
            SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
