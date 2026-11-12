/// What a gate asks of the user before the code behind it runs.
public enum GateLevel: Hashable, Codable, Sendable {
    /// Always open, still logged. The default everywhere.
    case free
    /// Any active subscription, the lifetime purchase, or a grandfathered install.
    case paid
    /// `N` tokens per use. Paying users pass without a draw.
    case tokens(Int)

    /// The tokens a non-paying user is asked for, `0` for `.free` and `.paid`.
    public var tokenCost: Int {
        if case .tokens(let n) = self { return n }
        return 0
    }

    /// `.tokens(0)` and negative costs are configuration errors, never a free gate.
    public var isValid: Bool {
        if case .tokens(let n) = self { return n > 0 }
        return true
    }
}

/// How a view gate spends tokens.
public enum TokenPolicy: Hashable, Sendable {
    /// Default on views: hold `N` on appear, consume on commit, release on disappear.
    case reserve
    /// Draw `N` on appear (views) or on call (`withPaywall`). Use it when the content *is* the value.
    case deductNow

    /// The original spelling ("scalare"). Prefer `.deductNow`.
    @available(*, deprecated, renamed: "deductNow")
    public static var scaleNow: TokenPolicy { .deductNow }
}

/// How the lease window behaves after a draw.
public enum LeasePolicy: Hashable, Codable, Sendable {
    /// The window runs `tolerance` seconds from the draw and is never extended. Default.
    case fixedFromDraw
    /// Every free re-entry moves the window to `now + tolerance`.
    case refreshOnReentry
}
