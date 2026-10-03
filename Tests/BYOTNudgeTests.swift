import Foundation
import Testing
@testable import byot

@Suite("Star and review nudge")
struct BYOTNudgeTests {
    private func makeGate() throws -> BYOTNudgeGate {
        BYOTNudgeGate(defaults: try #require(UserDefaults(suiteName: "byot-nudge-\(UUID().uuidString)")),
                      isAutomated: false)
    }

    @Test("Nothing before the third completed turn, then the star card once")
    func threshold() throws {
        let gate = try makeGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(gate.recordValueMoment(now: start) == nil)
        #expect(gate.recordValueMoment(now: start) == nil)
        #expect(gate.recordValueMoment(now: start) == .star)
        #expect(gate.completedTurns == 3)
        // The ask itself starts the cooldown, even with no answer.
        #expect(gate.recordValueMoment(now: start.addingTimeInterval(24 * 60 * 60)) == nil)
        #expect(gate.recordValueMoment(now: start.addingTimeInterval(BYOTNudgeGate.cooldown)) == .star)
    }

    @Test("Later waits a month and doubles the bar")
    func later() throws {
        let gate = try makeGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<2 { _ = gate.recordValueMoment(now: start) }
        #expect(gate.recordValueMoment(now: start) == .star)
        gate.recordLater(now: start)
        #expect(gate.threshold == 6)
        let month = start.addingTimeInterval(BYOTNudgeGate.cooldown)
        // Four, then five turns: under the doubled bar even after the cooldown.
        #expect(gate.recordValueMoment(now: month) == nil)
        #expect(gate.recordValueMoment(now: month) == nil)
        #expect(gate.recordValueMoment(now: month) == .star)
        #expect(gate.completedTurns == 6)
    }

    @Test("After the repo was opened, the ask becomes Apple's review prompt")
    func starredThenReview() throws {
        let gate = try makeGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<3 { _ = gate.recordValueMoment(now: start) }
        gate.recordStarred(now: start)
        #expect(gate.hasStarred)
        #expect(gate.recordValueMoment(now: start.addingTimeInterval(60)) == nil)
        #expect(gate.recordValueMoment(now: start.addingTimeInterval(BYOTNudgeGate.cooldown)) == .review)
        // The review ask also waits a month before the next one.
        #expect(gate.recordValueMoment(now: start.addingTimeInterval(BYOTNudgeGate.cooldown + 60)) == nil)
    }

    @Test("Automated runs never ask and never count")
    func automated() throws {
        var gate = try makeGate()
        gate.isAutomated = true
        for _ in 0..<5 { #expect(gate.recordValueMoment() == nil) }
        #expect(gate.completedTurns == 0)
        #expect(gate.lastAskedAt == nil)
    }

    @Test("Outcomes fit the telemetry schema")
    func outcomeSchema() throws {
        let gate = try makeGate()
        for ask in [BYOTNudgeAsk.star, .review] {
            for outcome in ["shown", "starred", "later", "requested"] {
                #expect(BYOTTelemetry.validate(.nudgeOutcome, gate.outcome(ask, outcome)) != nil, "\(ask) \(outcome)")
            }
        }
        #expect(BYOTTelemetry.validate(.nudgeOutcome, ["kind": "star_card", "url": "https://github.com/x"]) == nil)
    }
}
