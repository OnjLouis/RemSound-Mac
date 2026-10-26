import Foundation

// ONE INCOMING STREAM'S QUEUE, between the network and the mix: the Mac's receive buffer, as its StreamDecoder had it,
// moved here (2026-09-30) so that it is plain Swift - the same code the app runs, and the Mac simulator (RemSoundSim)
// drives, on a Mac or on Windows. The decoding (PCM, Opus, the crypto) stays in the app's StreamDecoder; everything from
// "these frames were decoded" to "the mix takes these frames" is here:
//   - the start: nothing is played until the queue first reaches its target; transient gaps stay armed;
//   - keeping in time (ClockDrift.swift): the sender's clock measured by its packets, the queue resampled by the ratio;
//   - moving the target (Descent.swift): by hand, the crossfaded skip and the fast approach; by the auto-tune, the
//     descent and its snap;
//   - the click-trim, against a ceiling that glides down after a lowered target;
//   - a safety cap: a fixed 400 ms budget retains the newest audio and the stream starts again.
// Every call takes the time from the caller (`now`, in seconds), so a simulation runs it in its own time.

/// Whether a packet's sequence number comes next, late, or starts the sender over (StreamDecoder's rules).
public struct StreamOrder {
    public static let restartBackwardFrames: UInt32 = 128
    public static let restartFirstFrames: UInt32 = 32
    public private(set) var last: UInt32?
    public init() {}

    public enum Admit: Equatable {
        /// Behind or equal to the last one taken: thrown away (late, or doubled).
        case late
        /// The sender started again (its sequence went back to the start): everything learned about the stream goes.
        case restart
        /// Next, after `missing` packets that never came.
        case next(missing: Int)
    }

    public func admit(_ sequence: UInt32) -> Admit {
        guard let last else { return .next(missing: 0) }
        if Int32(bitPattern: sequence &- last) <= 0 {
            return sequence <= Self.restartFirstFrames && last &- sequence >= Self.restartBackwardFrames ? .restart : .late
        }
        return .next(missing: Int(sequence &- last) - 1)
    }

    /// Packets since the last one taken, this one included (1 at the start).
    public func packets(upTo sequence: UInt32) -> Int {
        last.map { Int(truncatingIfNeeded: sequence &- $0) } ?? 1
    }

    public mutating func took(_ sequence: UInt32) { last = sequence }
    public mutating func reset() { last = nil }
}

/// Windows-compatible excess-buffer trimming. Level 10 leaves clock correction and the safety cap active.
public enum BufferSmoothness {
    public static let defaultLevel = 3
    public static let choices = Array(1...10)
    private static let writeMsShortfallFrames = 7
    private static let extraMarginMs = [0, 3, 8, 16, 28, 45, 70, 110, 200]

    public static func clamped(_ level: Int) -> Int { max(1, min(10, level)) }

    fileprivate static func writeMs(frames: Int) -> Int {
        // Match SessionPlayout's integer duration, including its seven-frame shortfall allowance.
        (frames + writeMsShortfallFrames) * 1000 / PlayoutQueue.rate
    }

    fileprivate static func marginMs(writeMs: Int, level: Int) -> Int {
        let level = clamped(level)
        let floor = level == 1 ? max(writeMs * 2 + 4, 4) : max(writeMs * 4 + 4, 15)
        return floor + extraMarginMs[level - 1]
    }

    fileprivate static func cushionMs(writeMs: Int, level: Int) -> Int {
        clamped(level) == 1 ? writeMs : writeMs * 2 + 5
    }
}

public final class PlayoutQueue {
    public static let rate = 48_000
    public static let maximumBufferedMs = 400

    /// Queued, and what the queue is played to at the start (ms).
    public private(set) var jitterMs: Int
    public private(set) var smoothness: Int
    public private(set) var artifact: ConcealmentArtifact
    private var concealment: UnderrunConcealment
    private var largestWriteFrames = 0
    private var samples = [Float](), offset = 0, started = false
    /// The frames each packet of the stream holds (the clock is counted by packets).
    public let packetFrames: Int
    private var drift = DriftMeter()
    private var resampler = StereoResampler()
    private var resampling = false
    private var steering = DepthSteering()
    private var ceiling = TrimCeiling()

    /// Frames the click-trim cut, and times it did.
    public private(set) var trimmedFrames = 0, trims = 0
    /// Frames the hand-lowered skips took.
    public private(set) var skippedFrames = 0
    /// The snaps: how many, how many at a quiet moment, and their frames.
    public var snaps: Int { steering.snaps }
    public var snapsInQuiet: Int { steering.snapsInQuiet }
    public var snappedFrames: Int { steering.snappedFrames }
    /// Times the mix found it empty, and times the safety cap discarded oldest audio.
    public private(set) var underrunsTotal = 0, overflows = 0
    /// Stereo frames displaced by the capacity cap, separate from click trims and manual skips.
    public private(set) var overflowDroppedFrames = 0
    private var underruns = 0
    private var underrunFrames = 0, longestUnderrunFrames = 0
    public private(set) var hasAudio = false
    /// A line for the log (a snap, a hand-lowered skip).
    public var onEvent: ((String) -> Void)?

    public init(jitterMs: Int, packetFrames: Int, now: Double, smoothness: Int = BufferSmoothness.defaultLevel,
        artifact: ConcealmentArtifact = .defaultChoice, concealmentSeed: UInt64? = nil) {
        // A supplied seed makes simulator runs reproducible; live streams seed once at creation.
        concealment = UnderrunConcealment(seed: concealmentSeed ?? UInt64.random(in: 1...UInt64.max))
        self.artifact = artifact
        self.smoothness = BufferSmoothness.clamped(smoothness)
        self.jitterMs = jitterMs
        self.packetFrames = packetFrames
        steering.target(jitterMs)
        _ = ceiling.update(targetMs: Double(jitterMs), bufferedMs: 0, now: now)
    }

    public var queuedFrames: Int { (samples.count - offset) / 2 }
    /// Whether initial priming finished; transient underruns leave playback armed.
    public var playing: Bool { started }
    /// The sender's clock against the mix's in parts per million (nil until measured): positive, theirs runs fast.
    public var clockPpm: Double? { drift.tracking ? drift.ppm : nil }
    public var clockTracking: Bool { drift.tracking }
    public var resampleRatio: Double { drift.ratio }
    /// Whether it is approaching a target moved by hand, or descending to a lowered one.
    public var approaching: Bool { steering.fast }
    public var descending: Bool { steering.descent }

    /// Underruns since last asked.
    public func takeUnderruns() -> Int {
        defer { underruns = 0 }
        return underruns
    }

    /// Longest contiguous output shortfall since last asked; observing it does not affect playback or tuning.
    public func takeLongestUnderrunFrames() -> Int {
        defer { longestUnderrunFrames = 0 }
        return longestUnderrunFrames
    }

    /// Start again: the sender restarted.
    public func reset(now: Double) {
        samples.removeAll(keepingCapacity: true)
        offset = 0
        started = false
        hasAudio = false
        concealment.reset()
        largestWriteFrames = 0
        underruns = 0
        underrunFrames = 0; longestUnderrunFrames = 0
        drift.reset()
        stopResampling()
        steering = DepthSteering()
        steering.target(jitterMs)
        ceiling = TrimCeiling()
        _ = ceiling.update(targetMs: Double(jitterMs), bufferedMs: 0, now: now)
    }

    /// The sender has made `frames` more (by its packets' sequence numbers, lost ones included).
    public func produced(_ frames: Int, now: Double) {
        guard frames > 0 else { return }
        drift.produced(frames, now: now)
    }

    /// Decoded stereo sound. The fixed budget retains the newest frames in arrival order.
    public func append(_ decoded: [Float]) {
        appendBounded(decoded)
        hasAudio = true
    }

    /// Codec loss fill uses the same capacity boundary as real audio.
    public func appendConcealment(_ decoded: [Float]) { appendBounded(decoded) }

    private func appendBounded(_ decoded: [Float]) {
        let capacityFrames = Self.maximumBufferedMs * Self.rate / 1000
        largestWriteFrames = max(largestWriteFrames, min(decoded.count / 2, capacityFrames))
        compact()
        let excess = max(0, queuedFrames + decoded.count / 2 - capacityFrames)
        var incomingOffset = 0
        if excess > 0 {
            // This queue belongs to the Session worker; the callback's SPSC capture ring is unchanged.
            let oldFrames = min(excess, queuedFrames)
            samples.removeFirst(oldFrames * 2)
            incomingOffset = (excess - oldFrames) * 2
            started = false
            concealment.reset()
            stopResampling()
            overflows += 1
            overflowDroppedFrames += excess
        }
        samples.append(contentsOf: decoded.dropFirst(incomingOffset))
    }

    private func compact() {
        if offset > 0 {
            samples.removeFirst(offset)
            offset = 0
        }
    }

    private func stopResampling() {
        resampler.reset()
        resampling = false
    }

    /// A new target. `byHand`: the person chose it - followed at once: lowered, the excess skipped with a crossfade;
    /// either way the pull goes up to 5 % until it is there. Otherwise (the auto-tune) a lowered target is come down to by
    /// the descent and its snap. `keepsInTime` off, there is no pull: a lowered target is skipped to at once, and a raised
    /// one starts again at its depth.
    public func setJitterMs(_ milliseconds: Int, byHand: Bool, keepsInTime: Bool) {
        guard milliseconds != jitterMs else { return }
        let lowered = milliseconds < jitterMs
        jitterMs = milliseconds
        steering.target(milliseconds)
        if byHand { steering.movedByHand() }
        if lowered && (byHand || !keepsInTime) {
            let excess = queuedFrames - jitterMs * Self.rate / 1000
            if excess > 0 {
                let skipped = CrossfadeSkip.skip(&samples, from: offset, frames: excess)
                offset += skipped * 2
                skippedFrames += skipped
                onEvent?("Receive buffer lowered to \(jitterMs) ms: \(skipped * 1000 / Self.rate) ms skipped with a crossfade.")
            }
        }
        if !lowered && !keepsInTime {
            started = false
            stopResampling()
        }
    }

    public func setArtifact(_ choice: ConcealmentArtifact) { artifact = choice }

    /// Change only the excess-buffer policy; buffered sound, clock measurement and auto-tune remain intact.
    public func setSmoothness(_ level: Int) {
        smoothness = BufferSmoothness.clamped(level)
    }

    /// The click-trim's limit and destination, for one decoded write (Windows SessionPlayout's rules).
    public static func excessLimitFrames(targetMs: Int, packetFrames: Int,
        smoothness: Int = BufferSmoothness.defaultLevel) -> Int {
        guard BufferSmoothness.clamped(smoothness) != 10 else { return Int.max }
        let writeMs = BufferSmoothness.writeMs(frames: packetFrames)
        return (targetMs + BufferSmoothness.marginMs(writeMs: writeMs, level: smoothness)) * rate / 1000
    }
    public static func trimDestinationFrames(targetMs: Int, packetFrames: Int,
        smoothness: Int = BufferSmoothness.defaultLevel) -> Int {
        let writeMs = BufferSmoothness.writeMs(frames: packetFrames)
        return (targetMs + BufferSmoothness.cushionMs(writeMs: writeMs, level: smoothness)) * rate / 1000
    }

    /// The mix takes `frames` (by its own clock, at `now`). Initially silent until the target; a transient gap
    /// remains armed so returning audio does not wait for another full jitter cushion.
    public func read(_ frames: Int, now: Double, keepsInTime: Bool) -> [Float] {
        guard frames > 0 else { return [] }
        let count = frames * 2
        let targetFrames = Double(jitterMs * Self.rate / 1000)
        // Coming down from a lowered target: everything over the target plus 100 ms skipped with a crossfade, at a quiet
        // moment if one comes within two seconds.
        if let snap = steering.snap(queuedFrames: (samples.count - offset) / 2, targetMs: jitterMs, now: now, quietAhead: {
            CrossfadeSkip.peakAhead(samples, from: offset, frames: CrossfadeSkip.fadeFrames) <= DepthSteering.snapQuietPeak
        }) {
            let skipped = CrossfadeSkip.skip(&samples, from: offset, frames: snap)
            offset += skipped * 2
            steering.snapped(skipped)
            onEvent?("Receive buffer coming down to \(jitterMs) ms: \(skipped * 1000 / Self.rate) ms skipped with a crossfade (snap \(steering.snaps), \(steering.snapsInQuiet) at a quiet moment).")
        }
        let queued = (samples.count - offset) / 2
        // The mix has asked for this many more frames, by its own clock; and what to play the queue out at.
        var ratio = 1.0
        if keepsInTime {
            drift.consumed(frames, now: now)
            ratio = drift.update(depthFrames: Double(queued), targetFrames: targetFrames, now: now)
            // Approaching a target moved by hand, or descending to a lowered one: the pull reworked five times a second.
            if steering.due(now: now, tracking: drift.tracking) {
                let (pull, depth) = steering.pull(depthFrames: Double(queued),
                    meanDepthFrames: drift.meanDepthFrames, targetFrames: targetFrames)
                drift.pull = pull
                drift.repull(depthFrames: depth, targetFrames: targetFrames)
                ratio = drift.ratio
            }
        } else if resampling {
            stopResampling()
        }
        // The click-trim: measured against a ceiling that follows a lowered target down no faster than the buffer does;
        // what it trims to is the real target.
        let ceilingMs = ceiling.update(targetMs: Double(jitterMs), bufferedMs: Double(queued) * 1000 / Double(Self.rate), now: now)
        let writeFrames = largestWriteFrames > 0 ? largestWriteFrames : packetFrames
        let limit = Self.excessLimitFrames(targetMs: Int(ceilingMs.rounded()), packetFrames: writeFrames, smoothness: smoothness)
        if queued > limit {
            let drop = queued - Self.trimDestinationFrames(targetMs: jitterMs, packetFrames: writeFrames, smoothness: smoothness)
            offset += drop * 2
            trimmedFrames += drop
            trims += 1
        }
        if !started {
            guard samples.count - offset >= jitterMs * Self.rate / 1000 * 2 else {
                return [Float](repeating: 0, count: count)
            }
            started = true
        }
        // Once the sender's clock has been measured the ratio leaves 1, and from then on the queue goes through the
        // resampler (it holds two frames of its own, so it is not left again until the stream stops or starts over).
        if keepsInTime, resampling || ratio != 1 {
            let need = resampler.inputFrames(forOutput: frames, ratio: ratio)
            let take = min(need, (samples.count - offset) / 2)
            let tail: (Float, Float)? = take > 0 ? (samples[offset + take * 2 - 2], samples[offset + take * 2 - 1]) : nil
            var input = Array(samples[offset..<offset + take * 2])
            input.append(contentsOf: repeatElement(0, count: (need - take) * 2))
            resampling = true
            var output = resampler.pull(input, outFrames: frames, ratio: ratio)
            offset += take * 2
            if take < need {
                // Convert missing resampler input to its corresponding output duration.
                noteUnderrun(frames: Int(ceil(Double(need - take) * Double(frames) / Double(need))), resumed: take > 0)
            } else { underrunFrames = 0 }
            if need > 0 && take == 0 { return concealment.empty(frames: frames, artifact: artifact) }
            // A zero-input pull still contains held real audio and must resolve a pending fade.
            concealment.real(&output, lastFrame: tail, artifact: artifact)
            return output
        }
        let take = min(count, samples.count - offset)
        let tail: (Float, Float)? = take > 0 ? (samples[offset + take - 2], samples[offset + take - 1]) : nil
        var output = Array(samples[offset..<offset + take])
        offset += take
        if take < count {
            output.append(contentsOf: repeatElement(0, count: count - take))
            noteUnderrun(frames: (count - take) / 2, resumed: take > 0)
        } else { underrunFrames = 0 }
        if take == 0 { return concealment.empty(frames: frames, artifact: artifact) }
        concealment.real(&output, lastFrame: tail, artifact: artifact)
        return output
    }

    private func noteUnderrun(frames: Int, resumed: Bool) {
        underruns += 1
        underrunsTotal += 1
        if resumed { underrunFrames = 0 }
        let (total, overflow) = underrunFrames.addingReportingOverflow(frames)
        underrunFrames = overflow ? Int.max : total
        longestUnderrunFrames = max(longestUnderrunFrames, underrunFrames)
    }
}

/// The receive buffer's choices. The auto-tune that moves it is Windows' (ReceiveAutoTune.swift, WindowsAutoTune.swift).
public enum ReceiveTuning {
    public static let minimumMs = 2   // jamming at 5 ms and below (Ed, 2026-09-29)
    public static let maximumMs = 200
    public static let choicesMs = [2, 3, 4, 5, 8, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120, 160, 200]
    public static func clamped(_ milliseconds: Int) -> Int { max(minimumMs, min(maximumMs, milliseconds)) }
}

