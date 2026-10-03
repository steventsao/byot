import Foundation

/// What byot may ask for at a value moment.
enum BYOTNudgeAsk: String, Equatable, Sendable {
    /// A card that asks for a GitHub star.
    case star = "star_card"
    /// Apple's review prompt. Apple decides whether it appears.
    case review = "review_request"
}

/// One ask per 30 days, at a value moment: a turn byot requested finished
/// well. The first asks are for a GitHub star; once the person has opened the
/// repo, byot asks Apple's review prompt instead. Nothing before the third
/// completed turn, and "Later" doubles that bar. Nothing in automated runs.
///
/// Orca's desktop star card inspired the shape (threshold, cooldown, doubled
/// threshold on dismiss). Apple allows a custom card for a GitHub star but
/// not for a review, so the review half uses `requestReview()` only.
struct BYOTNudgeGate {
    static let cooldown: TimeInterval = 30 * 24 * 60 * 60
    static let initialThreshold = 3
    static let repoURL = URL(string: "https://github.com/steventsao/byot")!
    static let reviewURL = URL(string: "https://apps.apple.com/app/id6782403920?action=write-review")!

    static let completedTurnsKey = "byot.nudge.completed-turns"
    static let thresholdKey = "byot.nudge.threshold"
    static let lastAskedKey = "byot.nudge.last-asked"
    static let starredKey = "byot.nudge.starred"

    let defaults: UserDefaults
    /// Tests and UI fixtures never ask.
    var isAutomated: Bool

    init(defaults: UserDefaults = .standard, isAutomated: Bool = BYOTLaunch.isAutomated) {
        self.defaults = defaults
        self.isAutomated = isAutomated
    }

    var completedTurns: Int { defaults.integer(forKey: Self.completedTurnsKey) }

    var threshold: Int {
        let saved = defaults.integer(forKey: Self.thresholdKey)
        return saved > 0 ? saved : Self.initialThreshold
    }

    var hasStarred: Bool { defaults.bool(forKey: Self.starredKey) }

    var lastAskedAt: Date? { defaults.object(forKey: Self.lastAskedKey) as? Date }

    /// Counts the value moment and says what to ask now, if anything. An ask
    /// starts the cooldown at once, so a card nobody answers still waits a month.
    func recordValueMoment(now: Date = .now) -> BYOTNudgeAsk? {
        guard isAutomated == false else { return nil }
        let turns = completedTurns + 1
        defaults.set(turns, forKey: Self.completedTurnsKey)
        guard turns >= threshold else { return nil }
        if let lastAskedAt, now.timeIntervalSince(lastAskedAt) < Self.cooldown { return nil }
        defaults.set(now, forKey: Self.lastAskedKey)
        return hasStarred ? .review : .star
    }

    /// "Later": wait for the cooldown and twice as many turns.
    func recordLater(now: Date = .now) {
        defaults.set(threshold * 2, forKey: Self.thresholdKey)
        defaults.set(now, forKey: Self.lastAskedKey)
    }

    /// The person opened the repo. byot cannot see the star itself, so this
    /// is taken as done; later asks go to Apple's prompt.
    func recordStarred(now: Date = .now) {
        defaults.set(true, forKey: Self.starredKey)
        defaults.set(now, forKey: Self.lastAskedKey)
    }

    /// Properties for the `nudge_outcome` event.
    func outcome(_ ask: BYOTNudgeAsk, _ outcome: String) -> BYOTTelemetry.Properties {
        ["kind": ask.rawValue, "outcome": outcome, "completed_turns": completedTurns, "threshold": threshold]
    }
}
