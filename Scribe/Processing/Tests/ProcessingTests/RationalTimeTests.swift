import Foundation
import Testing
@testable import Processing

@Test func rationalTimeMapsHostUptimeTimestampsToExactFrameIndices() {
    // The measured captures put presentation timestamps around 207 500 s. A Double
    // seconds value there has about 30 ns of resolution left, so the timescale must
    // do the work rather than the arithmetic.
    let origin = RationalTime(seconds: 207_492.667875)
    let later = RationalTime(seconds: 207_492.998875)
    #expect((later - origin).frameIndex(atSampleRate: 48_000) == 15_888)
    #expect(RationalTime(value: 1, timescale: 48_000).frameIndex(atSampleRate: 48_000) == 1)
    #expect(RationalTime(value: 3, timescale: 96_000).frameIndex(atSampleRate: 48_000) == 2)
}

@Test func rationalTimeAdditionDoesNotAccumulateError() {
    // Two hours of 10 ms blocks added one at a time. A Double accumulator loses
    // whole samples here; exact arithmetic must land on the frame exactly.
    var time = RationalTime(seconds: 207_492.667875)
    let block = RationalTime(value: 480, timescale: 48_000)
    for _ in 0..<720_000 { time = time + block }
    let origin = RationalTime(seconds: 207_492.667875)
    #expect((time - origin).frameIndex(atSampleRate: 48_000) == 720_000 * 480)
}

@Test func rationalTimeComparesAcrossTimescales() {
    #expect(RationalTime(value: 1, timescale: 2) == RationalTime(value: 24_000, timescale: 48_000))
    #expect(RationalTime(value: 1, timescale: 3) < RationalTime(value: 1, timescale: 2))
    #expect(RationalTime(value: -1, timescale: 48_000) < .zero)
}

@Test func rationalTimeRoundsHalfAwayFromZero() {
    // Half a frame at 48 kHz, on a timescale that represents it exactly.
    #expect(RationalTime(value: 1, timescale: 96_000).frameIndex(atSampleRate: 48_000) == 1)
    #expect(RationalTime(value: -1, timescale: 96_000).frameIndex(atSampleRate: 48_000) == -1)
}

@Test func journalTimescaleRepresentsEverySupportedRateExactly() {
    for rate in [8_000, 16_000, 22_050, 32_000, 44_100, 48_000, 96_000, 192_000] {
        #expect(RationalTime.journalTimescale % Int64(rate) == 0, "\(rate) Hz is not exact on the journal timescale")
    }
}
