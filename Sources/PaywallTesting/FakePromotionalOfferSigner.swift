#if DEBUG
    public import PaywallCore

    /// A scriptable signer: records every request and answers with a JWS-shaped token for it, a canned answer, or a
    /// failure, so a test (and the simulator) drive the offer purchase path without a server.
    public actor FakePromotionalOfferSigner: PromotionalOfferSigner {
        public enum Failure: Error, Hashable, Sendable { case unreachable }

        /// What the next `sign` does.
        public enum Next: Hashable, Sendable {
            /// Answers for the request, with `token(for:)`.
            case sign
            /// Throws `Failure.unreachable`: the server is down.
            case fail
            /// Answers this whatever was asked: how a test produces a mismatch.
            case answer(SignedPromotionalOffer)
        }

        public private(set) var requests: [PromotionalOfferSigningRequest] = []
        public private(set) var next: Next

        public init(next: Next = .sign) {
            self.next = next
        }

        public func setNext(_ next: Next) { self.next = next }

        /// The stand-in for the server's compact JWS: three dot-separated segments naming the request, so a test can
        /// tell which request a token answers.
        public static func token(for request: PromotionalOfferSigningRequest) -> String {
            "fake-jws.\(request.productID).\(request.offerID)"
        }

        public func sign(_ request: PromotionalOfferSigningRequest) async throws -> SignedPromotionalOffer {
            requests.append(request)
            switch next {
            case .sign:
                return SignedPromotionalOffer(productID: request.productID, offerID: request.offerID, compactJWS: Self.token(for: request))
            case .fail:
                throw Failure.unreachable
            case .answer(let signed):
                return signed
            }
        }
    }
#endif
