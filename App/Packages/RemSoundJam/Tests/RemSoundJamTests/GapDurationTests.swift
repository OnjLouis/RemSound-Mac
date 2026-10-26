import XCTest
@testable import RemSoundJam

final class GapDurationTests: XCTestCase {
    func testActualQueueShortfallContinuesAcrossReadingsAndEndsWhenSoundReturns() {
        let queue = PlayoutQueue(jitterMs: 0, packetFrames: 240, now: 0)
        queue.append([Float](repeating: 0.25, count: 120 * 2))
        _ = queue.read(240, now: 0, keepsInTime: false)
        XCTAssertEqual(queue.takeLongestUnderrunFrames(), 120)
        XCTAssertEqual(queue.takeLongestUnderrunFrames(), 0)
        _ = queue.read(240, now: 0.005, keepsInTime: false)
        XCTAssertEqual(queue.takeLongestUnderrunFrames(), 360, "observation does not end a continuing gap")
        queue.append([Float](repeating: 0.25, count: 240 * 2))
        _ = queue.read(240, now: 0.01, keepsInTime: false)
        _ = queue.read(240, now: 0.015, keepsInTime: false)
        XCTAssertEqual(queue.takeLongestUnderrunFrames(), 240, "real audio ended the earlier gap")
        XCTAssertEqual(queue.underrunsTotal, 3)
        queue.reset(now: 1)
        XCTAssertEqual(queue.takeLongestUnderrunFrames(), 0)
    }

    func testActualLongerQueueGapDrivesTheEpisodeWarning() {
        let queue = PlayoutQueue(jitterMs: 0, packetFrames: 240, now: 0), episodes = GapEpisodes()
        let start = Date(timeIntervalSince1970: 1_000)
        queue.append([Float](repeating: 0.25, count: 480))
        _ = queue.read(240, now: 0, keepsInTime: false)
        _ = queue.read(240, now: 0.005, keepsInTime: false)
        let first = episodes.second(start, newGaps: queue.takeUnderruns(),
            longestGapMs: queue.takeLongestUnderrunFrames() * 1_000 / 48_000)
        XCTAssertEqual(first.map(\.kind), [.started])
        for index in 0..<6 { _ = queue.read(240, now: 0.01 + Double(index) * 0.005, keepsInTime: false) }
        let longer = episodes.second(start.addingTimeInterval(1), newGaps: queue.takeUnderruns(),
            longestGapMs: queue.takeLongestUnderrunFrames() * 1_000 / 48_000)
        XCTAssertEqual(longer.map(\.kind), [.worse])
        XCTAssertTrue(longer[0].words.contains("35 ms gap"))
    }
}
