import AVFoundation
import AudioToolbox
import AudioSupport
import CoreAudio
import Foundation
import RemSoundJam

public final class StereoRing {
    public let raw: OpaquePointer
    public init(capacity: Int = 48000) { raw = rs_ring_create(capacity)! }
    deinit { rs_ring_destroy(raw) }
    public var available: Int { rs_ring_available(raw) }
    public var writtenFrames: Int { rs_ring_written_frames(raw) }
    public var droppedFrames: Int { rs_ring_dropped_frames(raw) }
    public var pullTotals: (frames: UInt64, count: UInt64)? {
        let figures = rs_ring_pull_figures(raw)
        return figures.coherent != 0 ? (figures.frames, figures.count) : nil
    }
    public func discard(_ frames: Int) -> Int { rs_ring_discard(raw, frames) }
    public func write(_ samples: [Float]) {
        let frames = samples.count / 2
        var left = [Float](repeating: 0, count: frames)
        var right = left
        for i in 0..<frames {
            left[i] = samples[i * 2]
            right[i] = samples[i * 2 + 1]
        }
        _ = rs_ring_write(raw, left, right, frames)
    }
    func write(_ buffer: AVAudioPCMBuffer) {
        Self.write(buffer, to: raw)
    }
    @discardableResult
    static func write(_ buffer: AVAudioPCMBuffer, to ring: OpaquePointer,
        duplicateFirstChannel: Bool = false) -> Int {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
            buffer.format.channelCount > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if !buffer.format.isInterleaved, let channels = buffer.floatChannelData {
            let right = !duplicateFirstChannel && buffer.format.channelCount > 1
                ? channels[1] : channels[0]
            return rs_ring_write(ring, channels[0], right, frames)
        } else {
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: buffer.audioBufferList))
            guard let first = buffers.first, let data = first.mData else { return 0 }
            let channels = Int(first.mNumberChannels)
            let samples = data.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                return rs_ring_write(ring, samples, samples, frames)
            } else if duplicateFirstChannel {
                return rs_ring_write_interleaved_first_channel(ring, samples, channels, frames)
            } else {
                return rs_ring_write_interleaved_channels(ring, samples, channels, frames)
            }
        }
    }
    public func read(_ frames: Int) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        var result = [Float](repeating: 0, count: frames * 2)
        _ = rs_ring_read(raw, &left, &right, frames)
        for i in 0..<frames {
            result[2 * i] = left[i]
            result[2 * i + 1] = right[i]
        }
        return result
    }
}

/// KEEPING IN TIME (30 September 2026; RemSoundJam's ClockDrift.swift has the reasoning and the tests). No two sound
/// cards run at the same rate, and this Mac's mix runs by a third clock. With this on - it is, unless the Jamming menu's
/// "Keep in Time with Other Sound Cards" is unticked - each incoming stream is played out at its sender's measured rate
/// (StreamDecoder), each output card is fed at its own (PlaybackFanout), and multiple physical inputs are matched to
/// the shared sending clock (CaptureInputClocks). Single-input capture and generic tap mixes remain unchanged.
/// Off, these paths bypass their clock correction.
/// Read and written on the session's queue only.
public enum ClockKeeping {
    public static var on = true
}

// An output card's clock keeper sees its playback ring through this.
extension StereoRing: OutputQueue {}

final class DirectInputCapture {
    private let samples: StereoRing
    private let retirements: CaptureRetirements
    private let wake: OpaquePointer?
    private var registration: DirectInputRegistration?
    private(set) var channelCount: UInt32 = 0

    init(samples: StereoRing, retirements: CaptureRetirements, wake: OpaquePointer? = nil) {
        self.samples = samples
        self.retirements = retirements
        self.wake = wake
    }

    // Returns false for ordinary mono/stereo devices so they keep the AVAudioEngine path.
    func start(uid: String, multichannelOnly: Bool = false,
        selectedPairs: [Int] = [0]) throws -> Bool {
        guard stop(), retirements.poll() else {
            throw ProtocolError.invalid("Previous direct input capture has not stopped safely.")
        }
        guard let id = try AudioDeviceCatalog.resolve(uid, for: .input) else {
            throw ProtocolError.invalid("The selected input is unavailable.")
        }
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            throw ProtocolError.invalid("Could not read the selected input format.")
        }
        var streams = [AudioStreamID](repeating: 0,
            count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &streamsAddress, 0, nil,
            &size, &streams) == noErr else {
            throw ProtocolError.invalid("Could not read the selected input stream.")
        }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(streams[0], &formatAddress, 0, nil,
            &size, &format) == noErr else {
            throw ProtocolError.invalid("Could not read the selected input sample format.")
        }
        if multichannelOnly && format.mChannelsPerFrame <= 2 { return false }
        guard format.mChannelsPerFrame > 0,
            format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
            format.mSampleRate == Double(Wire.sampleRate),
            format.mBitsPerChannel == 32,
            format.mBytesPerFrame == format.mChannelsPerFrame * UInt32(MemoryLayout<Float>.size) else {
            throw ProtocolError.invalid(
                "The selected input must provide interleaved 48 kHz floating-point audio.")
        }
        guard !selectedPairs.isEmpty,
            selectedPairs.allSatisfy({ $0 >= 0 && $0 < Int(format.mChannelsPerFrame / 2) })
                || format.mChannelsPerFrame == 1 && selectedPairs == [0] else {
            throw ProtocolError.invalid("The chosen input channel pair is unavailable.")
        }
        let context = try DirectInputCallback(samples: samples,
            channels: format.mChannelsPerFrame, pairs: selectedPairs, wake: wake)
        let next = DirectInputRegistration(device: id, context: context)
        registration = next
        do {
            try next.start()
            channelCount = format.mChannelsPerFrame
            return true
        } catch {
            _ = stop()
            throw error
        }
    }

    @discardableResult
    func stop() -> Bool {
        guard let registration else { return retirements.poll() }
        let complete = retirements.retire(registration)
        // Pending registration is owned by retirements; the copied native block
        // retains its immutable callback context. No mutable self reaches IO.
        self.registration = nil
        channelCount = 0
        return complete
    }

    deinit { stop() }
}

enum OutputChannelMap {
    static func make(channelCount: Int, pairs: [Int]) throws -> [Int32] {
        guard channelCount >= 2, !pairs.isEmpty,
            pairs.allSatisfy({ $0 >= 0 && $0 < channelCount / 2 }) else {
            throw ProtocolError.invalid("The chosen output channel pair is unavailable.")
        }
        var map = [Int32](repeating: -1, count: channelCount)
        for pair in pairs {
            map[pair * 2] = 0
            map[pair * 2 + 1] = 1
        }
        return map
    }
}

final class PlaybackFanout {
    let primary: StereoRing
    private(set) var rings = [StereoRing]()
    // Keeping in time: a clock keeper for each output card, in the rings' order. Only for real cards (DeviceAudio
    // switches it on when it starts them), and only while ClockKeeping.on; otherwise the mix is written straight into
    // every ring, as it always was.
    var forCards = false
    private(set) var clocks = [OutputClock]()
    /// What each card takes at once, in frames (its Core Audio buffer), in the rings' order; 512 where it is not known.
    var cardFrames = [Int]()

    init(primary: StereoRing) { self.primary = primary }

    func addOutput() -> StereoRing {
        let ring = rings.isEmpty ? primary : StereoRing(capacity: OutputClock.maximumQueueFrames)
        rings.append(ring)
        return ring
    }

    func write(_ samples: [Float]) {
        guard forCards, ClockKeeping.on else {
            if rings.isEmpty { primary.write(samples); return }
            for ring in rings { ring.write(samples) }
            return
        }
        let targets = rings.isEmpty ? [primary] : rings
        while clocks.count < targets.count { clocks.append(OutputClock()) }
        let now = ProcessInfo.processInfo.systemUptime
        for (index, ring) in targets.enumerated() {
            if index < cardFrames.count, cardFrames[index] > 0 { clocks[index].cardFrames = cardFrames[index] }
            clocks[index].write(samples, to: ring, now: now)
        }
    }

    func clear() {
        rings.removeAll()
        clocks.removeAll()
        cardFrames.removeAll()
        forCards = false
        _ = primary.discard(primary.available)
    }
}

// Owned by the network queue. Audio callbacks only touch the C single-producer/single-consumer rings.
public final class DeviceAudio {
    private let directRetirements: CaptureRetirements
    private var makeCaptureWake: (() -> CaptureWakeAttachment?)?
    private var captureWake: CaptureWakeAttachment?
    func configureCaptureWake(packetFrames: Int, sending: Bool, hasDestination: Bool) {
        captureWake?.configure(packetFrames: packetFrames, sending: sending,
            hasDestination: hasDestination, pushDriven: usesDirectBuiltInMicrophone,
            sourceCount: captureMix.sources.count)
    }
    var captureRetirementPending: Bool { directRetirements.count > 0 }
    var captureRetirementExhausted: Bool { directRetirements.exhausted }
    @discardableResult
    func pollCaptureRetirements() -> Bool { directRetirements.poll() }
    public let capture = StereoRing(), playback = StereoRing(capacity: OutputClock.maximumQueueFrames)
    private lazy var playbackFanout = PlaybackFanout(primary: playback)
    public var playbackQueuedFrames: Int {
        playbackFanout.rings.map(\.available).max() ?? playback.available
    }
    /// For the log, an entry for each output card: its clock against the mix's in parts per million (nil until measured;
    /// positive, the mix runs fast), the cushion being held, and what has been laid down in silence, cut, and how often
    /// the card ran dry. Empty while clocks are not being kept.
    public var outputClocks: [(ppm: Double?, cushionFrames: Int, laidFrames: Int, cutFrames: Int, ranDry: Int)] {
        playbackFanout.clocks.map { ($0.ppm, $0.cushionFrames, $0.laidFrames, $0.cutFrames, $0.ranDry) }
    }
    /// What a device takes at once: its Core Audio buffer, in frames (nil if it will not say).
    static func bufferFrames(_ id: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames) == noErr, frames > 0 else { return nil }
        return Int(frames)
    }
    /// Tell the clock keepers what each output card takes at once: when the outputs start, and when the buffer size is
    /// changed. `uids` in the order the outputs were started.
    private func noteOutputBuffers(_ uids: [String]) {
        playbackFanout.cardFrames = uids.map { uid in
            guard let id = (try? AudioDeviceCatalog.resolve(uid, for: .output)) ?? Self.defaultDevice(.output) else { return 512 }
            return Self.bufferFrames(id) ?? 512
        }
    }
    private var startedOutputUIDs = [String]()
    private var startedInputUIDs = [String]()
    var noteBufferRestoration: ((String) -> Void)?
    private let bufferSettings = DeviceBufferSettings(read: { id in
        DeviceAudio.bufferFrames(id).map(UInt32.init)
    }, write: { id, frames in
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = frames
        return AudioObjectSetPropertyData(id, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    })

    private func restoreBufferFrames() -> String {
        let failed = bufferSettings.restore()
        let message = failed.isEmpty ? "Core Audio buffer settings restored where unchanged by other apps."
            : "Core Audio buffer restoration failed for device IDs: \(failed.map(String.init).joined(separator: ", "))."
        if !failed.isEmpty { noteBufferRestoration?(message) }
        return message
    }
    /// The input's own delay, in seconds, as Core Audio gives it for the first capture engine (0 when none says): how long
    /// a sound takes from the input to the samples we are handed. The server's metronome times this Mac by it.
    /// Ask every device in use for this Core Audio buffer size (frames: 32, 64, 128, 256), and say what each took. The
    /// Mac's answer to the ASIO buffer size Ed keeps at 32: the smaller, the sooner sound moves - if the device keeps up.
    public func applyBufferFrames(_ frames: Int, inputUIDs: [String], outputUIDs: [String]) -> String {
        if frames == 0 {
            let message = restoreBufferFrames()
            noteOutputBuffers(startedOutputUIDs)
            return message
        }
        guard [32, 64, 128, 256].contains(frames) else { return "Unsupported Core Audio buffer size." }
        var said: [String] = []
        var seen = Set<AudioDeviceID>()
        func apply(_ uid: String, _ direction: AudioDeviceDirection) {
            let resolved = uid.isEmpty ? Self.defaultDevice(direction)
                : try? AudioDeviceCatalog.resolve(uid, for: direction)
            guard let id = resolved,
                seen.insert(id).inserted else { return }
            let accepted = bufferSettings.apply(device: id, frames: UInt32(frames))
            let actual = Self.bufferFrames(id)
            said.append("\(direction.label) \(uid.isEmpty ? "(default)" : uid): asked \(frames), "
                + (actual.map { "now \($0)" } ?? "unreadable") + (accepted ? "" : " (refused or unreadable)"))
        }
        for uid in startedInputUIDs where inputUIDs.contains(uid) { apply(uid, .input) }
        for uid in startedOutputUIDs where outputUIDs.contains(uid) { apply(uid, .output) }
        noteOutputBuffers(startedOutputUIDs)   // the clock keepers' cushions follow the cards' buffers
        return "Core Audio buffer: " + (said.isEmpty ? "no device to set" : said.joined(separator: "; "))
    }
    static func defaultDevice(_ direction: AudioDeviceDirection) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }
    public var inputLatencySeconds: Double { captureEngines.first.map { $0.inputNode.presentationLatency } ?? 0 }
    /// The output's own delay, in seconds, for the first playback engine: clicks are placed that far ahead.
    public var outputLatencySeconds: Double { playbackEngines.first.map { $0.outputNode.presentationLatency } ?? 0 }
    // Session-worker reporting only. No new engine/device lookup, and no hardware sum
    // is added to AV presentation latency (which already represents this output path).
    var outputPresentationLatenciesMs: [Double?] {
        playbackEngines.map { engine in
            guard engine.isRunning else { return nil }
            let value=engine.outputNode.presentationLatency*1000
            return value.isFinite && value>=0 ? value : nil
        }
    }
    private(set) var captureMix: SystemAudioMix
    private var captureEngines = [AVAudioEngine]()
    private var captureEngineUIDs = [String]()
    private var playbackEngines = [AVAudioEngine]()
    private var directInputs = [DirectInputCapture]()
    private var inputSources = [(id: UUID, name: String, ring: StereoRing, initialFrames: Int)]()
    private var startupDiscardedFrames = 0
    private(set) var systemCapture: SystemAudioCaptureGroup?
    private(set) var delayEstimates = AudioDelayEstimates.empty
    public private(set) var inputCaptureFallback: String?
    public private(set) var inputCaptureModes = [String]()
    public var inputCaptureHealth: String {
        inputSources.map {
            "\($0.name): \($0.ring.writtenFrames - $0.initialFrames) captured frames"
        }.joined(separator: "; ")
    }
    var inputCaptureCounters: [CaptureRateMeter.Counter] {
        inputSources.map {
            .init(id: $0.id, name: $0.name, frames: $0.ring.writtenFrames - $0.initialFrames,
                  queuedFrames: $0.ring.available)
        }
    }
    // Read only at setup/reconfiguration on the session worker, never in an audio callback.
    func configurationDiagnostics() -> [String] {
        var descriptions = [String]()
        var snapshots = [DeviceConfigurationSnapshot]()
        for direction in AudioDeviceDirection.allCases {
            let choices = AudioDeviceCatalog.choices(for: direction)
            let uids = direction == .input ? startedInputUIDs : startedOutputUIDs
            for (index, uid) in uids.enumerated() {
                let id = uid.isEmpty ? Self.defaultDevice(direction)
                    : choices.first(where: { $0.uid == uid })?.id
                guard let id else {
                    descriptions.append("Core Audio setup \(direction.label): selected device unavailable.")
                    continue
                }
                let name = choices.first(where: { $0.id == id })?.name ?? "Selected device"
                let presentation: Double?
                if direction == .input {
                    presentation = captureEngineUIDs.firstIndex(of: uid).map {
                        captureEngines[$0].inputNode.presentationLatency
                    }
                } else {
                    presentation = playbackEngines[index].outputNode.presentationLatency
                }
                let snapshot = DeviceConfigurationReader.hardware.snapshot(id: id, name: name,
                    direction: direction, presentationLatencySeconds: presentation)
                snapshots.append(snapshot)
                descriptions.append(snapshot.logDescription)
            }
        }
        descriptions.append(String(format: "Timing origin currently uses first capture engine %.3f ms "
            + "(zero when no capture engine); output estimate uses first playback engine %.3f ms. "
            + "Direct-input hardware delay is observed separately, not applied to the capture origin.",
            inputLatencySeconds * 1000, outputLatencySeconds * 1000))
        if inputSources.count > 1 {
            descriptions.append("Capture startup: discarded \(startupDiscardedFrames) setup frames "
                + "across \(inputSources.count) inputs before sending; live audio is not flushed.")
        }
        descriptions += systemCapture?.configurationDiagnostics() ?? []
        delayEstimates = AudioDelayEstimates(inputs: snapshots.filter { $0.direction == .input },
            outputs: snapshots.filter { $0.direction == .output }, expectedInputDevices: startedInputUIDs.count,
            expectedOutputDevices: startedOutputUIDs.count)
        return descriptions
    }
    var callbackCaptureCounters: [CallbackRateMeter.Counter] {
        inputSources.compactMap {
            CallbackRateMeter.counter(ring: $0.ring, id: $0.id, name: $0.name,
                formatRate: Double(Wire.sampleRate))
        } + (systemCapture?.callbackCaptureCounters ?? [])
    }
    static func captureCallback(_ ring: StereoRing) -> CaptureInputClocks.Callback {
        let snapshot = rs_ring_capture_snapshot(ring.raw)
        guard snapshot.coherent == 1, snapshot.sample_rate == Double(Wire.sampleRate),
            snapshot.frames > 0, snapshot.frames <= UInt64(Wire.sampleRate),
            snapshot.origin == UInt32(RS_CAPTURE_HAL) || snapshot.origin == UInt32(RS_CAPTURE_AV_TAP) else {
            return .unavailable
        }
        return .init(sequence: snapshot.sequence, frames: Int(snapshot.frames))
    }
    var inputClockDiagnostics: [String] {
        captureMix.inputClockFigures.enumerated().map { index, figure in
            let name = index < inputSources.count ? inputSources[index].name : "Selected input"
            return figure.logDescription(name: name)
        }
    }
    var callbackBudgetDiagnostics: [String] {
        inputSources.map {
            AudioCallbackBudget.describe(ring: $0.ring.raw, name: "input \($0.name)")
        } + playbackFanout.rings.enumerated().map {
            AudioCallbackBudget.describe(ring: $0.element.raw,
                name: "output \($0.offset + 1) app source render (48 kHz node, excludes the rest of the engine)")
        } + (systemCapture?.callbackBudgetDiagnostics ?? [])
    }
    var captureTimestampDiagnostics: [String] {
        inputSources.map {
            CaptureTimestampObservation.describe(ring: $0.ring.raw, name: $0.name)
        } + (systemCapture?.captureTimestampDiagnostics ?? [])
    }
    public private(set) var usesDirectBuiltInMicrophone = false
    public init() {
        directRetirements = CaptureRetirements()
        captureMix = SystemAudioMix(sources: [capture])
    }
    init(captureRetirements: CaptureRetirements,
        makeCaptureWake: (() -> CaptureWakeAttachment?)? = nil) {
        directRetirements = captureRetirements
        self.makeCaptureWake = makeCaptureWake
        captureMix = SystemAudioMix(sources: [capture])
    }
    convenience init(isolatedCapturePushDriven: Bool,
        captureRetirements: CaptureRetirements? = nil,
        makeCaptureWake: (() -> CaptureWakeAttachment?)? = nil) {
        if let captureRetirements {
            self.init(captureRetirements: captureRetirements, makeCaptureWake: makeCaptureWake)
        } else { self.init() }
        usesDirectBuiltInMicrophone = isolatedCapturePushDriven
        if isolatedCapturePushDriven { captureWake = makeCaptureWake?() }
        systemCapture = SystemAudioCaptureGroup(isolatedSource: StereoRing(capacity: Wire.sampleRate * 5))
        inputSources = [(UUID(), "isolated synthetic capture", capture, capture.writtenFrames)]
    }
    public func start(
        send: Bool, receive: Bool, systemAudio: Bool = false,
        inputDeviceUID: String = "", inputDeviceUIDs: [String]? = nil,
        inputChannelPairs: [String: [Int]] = [:],
        outputDeviceUID: String = "",
        outputDeviceUIDs: [String]? = nil,
        outputChannelPairs: [String: [Int]] = [:],
        systemCaptureDeviceUIDs: [String]? = nil,
        systemCaptureChannelPairs: [String: [Int]] = [:],
        systemCaptureApplications: [String]? = nil
    ) throws {
        stop()
        guard directRetirements.poll() else {
            throw ProtocolError.invalid("Previous direct input capture has not stopped safely.")
        }
        guard send || receive || systemAudio else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            if send {
                let selected = inputDeviceUIDs ?? [inputDeviceUID]
                var seen = Set<String>()
                let unique = selected.filter { seen.insert($0).inserted }
                guard !unique.isEmpty,
                    !unique.contains("") || unique.count == 1 else {
                    throw ProtocolError.invalid(
                        "Choose at least one audio input. System default input cannot be combined with named inputs.")
                }
                var rings = [StereoRing]()
                for uid in unique {
                    let ring = rings.isEmpty ? capture : StereoRing()
                    let name = AudioDeviceCatalog.choices(for: .input)
                        .first(where: { $0.uid == uid })?.name ?? "Selected input"
                    let initialFrames = ring.writtenFrames
                    if AudioDeviceCatalog.isBuiltInMicrophone(uid) {
                        captureWake = makeCaptureWake?()
                        let direct = DirectInputCapture(samples: ring, retirements: directRetirements,
                            wake: captureWake?.producer)
                        do {
                            _ = try direct.start(uid: AudioDeviceCatalog.builtInMicrophoneUID)
                            directInputs.append(direct)
                            usesDirectBuiltInMicrophone = true
                            inputCaptureModes.append("\(name): direct mono Core Audio")
                        } catch {
                            guard directRetirements.poll() else { throw error }
                            captureWake?.retire(producersStopped: true)
                            captureWake = nil
                            inputCaptureFallback = error.localizedDescription
                            try startInputEngine(uid: uid, ring: ring,
                                duplicateFirstChannel: true)
                            inputCaptureModes.append("\(name): audio engine fallback")
                        }
                    } else {
                        let pairs = inputChannelPairs[uid] ?? [0]
                        let direct = DirectInputCapture(samples: ring, retirements: directRetirements)
                        do {
                            if try direct.start(uid: uid, multichannelOnly: true,
                                selectedPairs: pairs) {
                                directInputs.append(direct)
                                inputCaptureModes.append(
                                    "\(name): direct \(direct.channelCount)-channel Core Audio, "
                                    + "pairs \(pairs.map { "\($0 * 2 + 1)/\($0 * 2 + 2)" }.joined(separator: ", "))")
                            } else {
                                try startInputEngine(uid: uid, ring: ring,
                                    duplicateFirstChannel: false)
                                inputCaptureModes.append("\(name): audio engine")
                            }
                        } catch {
                            guard directRetirements.poll() else { throw error }
                            if pairs != [0] { throw error }
                            inputCaptureFallback = error.localizedDescription
                            try startInputEngine(uid: uid, ring: ring,
                                duplicateFirstChannel: false)
                            inputCaptureModes.append("\(name): audio engine fallback")
                        }
                    }
                    rings.append(ring)
                    inputSources.append((UUID(), name, ring, initialFrames))
                }
                captureMix = SystemAudioMix(sources: rings, captureCallbacks: {
                    rings.map(Self.captureCallback)
                })
                startedInputUIDs = unique
            }
            if receive {
                let selected = outputDeviceUIDs ?? [outputDeviceUID]
                var seen = Set<String>()
                let unique = selected.filter { seen.insert($0).inserted }
                guard !unique.isEmpty,
                    !unique.contains("") || unique.count == 1 else {
                    throw ProtocolError.invalid(
                        "Choose at least one playback output. System default output cannot be combined with named outputs.")
                }
                for uid in unique {
                    let e = AVAudioEngine()
                    playbackEngines.append(e)
                    try selectDevice(e.outputNode.audioUnit, uid: uid, direction: .output)
                    if !uid.isEmpty,
                        let pairs = outputChannelPairs[uid], pairs != [0] {
                        try selectOutputPairs(e.outputNode.audioUnit, uid: uid, pairs: pairs)
                    }
                    // Each output consumes its own ring; sharing a ring would split frames
                    // between device callbacks instead of playing the same mix on each card.
                    let ring = playbackFanout.addOutput()
                    let raw = ring.raw
                    let source = AVAudioSourceNode(format: format) { _, _, frames, list in
                        let began = rs_callback_begin()
                        let buffers = UnsafeMutableAudioBufferListPointer(list)
                        guard buffers.count >= 2,
                            let left = buffers[0].mData, let right = buffers[1].mData else {
                            return noErr
                        }
                        _ = rs_ring_read(raw, left.assumingMemoryBound(to: Float.self),
                            right.assumingMemoryBound(to: Float.self), Int(frames))
                        rs_ring_note_callback(raw, began, Int(frames), Double(Wire.sampleRate))
                        return noErr
                    }
                    e.attach(source)
                    e.connect(source, to: e.mainMixerNode, format: format)
                    e.prepare()
                    try e.start()
                }
                startedOutputUIDs = unique
                noteOutputBuffers(unique)
                playbackFanout.forCards = true
            }
            if systemAudio {
                let group = SystemAudioCaptureGroup()
                try group.start(deviceUIDs: systemCaptureDeviceUIDs,
                    channelPairs: systemCaptureChannelPairs, applications: systemCaptureApplications)
                systemCapture = group
            }
            startupDiscardedFrames = captureMix.prepareForSending()
        } catch {
            stop()
            throw error
        }
    }
    public func writePlayback(_ samples: [Float]) {
        playbackFanout.write(samples)
    }
    private func startInputEngine(uid: String, ring: StereoRing,
        duplicateFirstChannel: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try selectDevice(input.audioUnit, uid: uid, direction: .input)
        let native = input.outputFormat(forBus: 0)
        guard native.channelCount > 0, native.sampleRate == Double(Wire.sampleRate),
            native.commonFormat == .pcmFormatFloat32 else {
            throw ProtocolError.invalid(
                "The selected input is unavailable or is not running at 48 kHz floating-point audio.")
        }
        let raw = ring.raw
        input.installTap(onBus: 0, bufferSize: 480, format: native) { buffer, time in
            let began = rs_callback_begin()
            let accepted = StereoRing.write(buffer, to: raw, duplicateFirstChannel: duplicateFirstChannel)
            CaptureTimestampObservation.note(ring: raw, began: began, time: time.audioTimeStamp,
                frames: Int(buffer.frameLength), accepted: accepted,
                rate: buffer.format.sampleRate, origin: UInt32(RS_CAPTURE_AV_TAP))
            rs_ring_note_callback(raw, began, Int(buffer.frameLength), buffer.format.sampleRate)
        }
        captureEngines.append(engine)
        captureEngineUIDs.append(uid)
        engine.prepare()
        try engine.start()
    }
    private func selectDevice(
        _ unit: AudioUnit?, uid: String, direction: AudioDeviceDirection
    ) throws {
        guard let id = try AudioDeviceCatalog.resolve(uid, for: direction) else { return }
        guard let unit else {
            throw ProtocolError.invalid("The audio \(direction.label) is unavailable.")
        }
        var selected = id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw ProtocolError.invalid(
                "Could not select the audio \(direction.label) (Core Audio error \(status)).")
        }
    }
    private func selectOutputPairs(_ unit: AudioUnit?, uid: String, pairs: [Int]) throws {
        guard let unit else {
            throw ProtocolError.invalid("The audio output is unavailable.")
        }
        var size: UInt32 = 0
        var writable = DarwinBoolean(false)
        let info = AudioUnitGetPropertyInfo(unit, kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output, 0, &size, &writable)
        guard info == noErr, writable.boolValue else {
            throw ProtocolError.invalid("The selected output does not support channel mapping.")
        }
        // The unit reports the current map length (initially stereo), not the
        // physical output count. Use the device's output stream formats instead.
        var map = try OutputChannelMap.make(
            channelCount: AudioDeviceCatalog.outputChannelCount(uid), pairs: pairs)
        let result = map.withUnsafeMutableBytes { bytes in
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output, 0, bytes.baseAddress, UInt32(bytes.count))
        }
        guard result == noErr else {
            throw ProtocolError.invalid(
                "Could not route received audio to the chosen output channels (Core Audio error \(result)).")
        }
    }
    public func stop() {
        // Disable/cancel notifications before retiring any native producer.
        captureWake?.retire(producersStopped: false)
        startupDiscardedFrames = 0
        delayEstimates = .empty
        systemCapture?.stop()
        systemCapture = nil
        for direct in directInputs { direct.stop() }
        directInputs.removeAll()
        captureWake?.retire(producersStopped: directRetirements.poll())
        captureWake = nil
        inputSources.removeAll()
        inputCaptureModes.removeAll()
        inputCaptureFallback = nil
        usesDirectBuiltInMicrophone = false
        for engine in captureEngines {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        captureEngines.removeAll()
        captureEngineUIDs.removeAll()
        captureMix = SystemAudioMix(sources: [capture])
        _ = capture.discard(capture.available)
        for engine in playbackEngines { engine.stop() }
        playbackEngines.removeAll()
        playbackFanout.clear()
        _ = restoreBufferFrames()
        startedInputUIDs.removeAll()
        startedOutputUIDs.removeAll()
    }
    deinit { stop() }
}

/// What every stream a session has had heard go wrong, each a total since the session started - kept apart from the
/// streams, which come and go. The network recorder saves the change in them with a minute of arrivals.
final class ReceiveTotals {
    var audibleGaps = 0, lateOrDoubledDropped = 0, concealed = 0, gapsNotRepaired = 0
    private(set) var malformedPackets: UInt64 = 0, rejectedAudioPayloads: UInt64 = 0, decodedAudioFrames: UInt64 = 0
    private(set) var notAllowedPackets: UInt64 = 0, rejectedPCMFragments: UInt64 = 0, discardedPCMPartials: UInt64 = 0
    private(set) var reorderWaits: UInt64 = 0
    func noteReorderWait() { if reorderWaits < .max { reorderWaits += 1 } }
    func noteNotAllowed() { if notAllowedPackets < .max { notAllowedPackets += 1 } }
    func notePCMRejected() { if rejectedPCMFragments < .max { rejectedPCMFragments += 1 } }
    func notePCMDiscarded(_ count: Int) {
        let value = UInt64(max(0, count))
        discardedPCMPartials = discardedPCMPartials > .max - value ? .max : discardedPCMPartials + value
    }
    var diagnosticDescription: String {
        "receive lifetime totals: malformed packets \(malformedPackets), refused audio envelopes \(rejectedAudioPayloads), native decoded frames \(decodedAudioFrames), selection-gate refusals \(notAllowedPackets), rejected PCM fragments \(rejectedPCMFragments), discarded PCM partials \(discardedPCMPartials), reorder waits \(reorderWaits)"
    }
    func noteMalformed() { if malformedPackets < .max { malformedPackets += 1 } }
    func noteRejectedAudio() { if rejectedAudioPayloads < .max { rejectedAudioPayloads += 1 } }
    func noteDecodedAudio(frames: Int) {
        let value = UInt64(max(0, frames))
        decodedAudioFrames = decodedAudioFrames > .max - value ? .max : decodedAudioFrames + value
    }

}

final class StreamDecoder {
    private(set) var format: StreamFormat
    @discardableResult func updateMetadata(_ current: StreamFormat) -> Bool {
        guard format.sameDecodingConfiguration(as:current) else { return false }
        format=current
        return true
    }
    private var opus: UnsafeMutableRawPointer?
    private var custom: UnsafeMutableRawPointer?
    // The receive buffer itself - the start, keeping in time, moving the target, the click-trim - is RemSoundJam's
    // PlayoutQueue (the same code the Mac simulator runs); this decodes into it. StreamOrder tracks played units;
    // authenticated admission, restart and the single-slot reorder wait live below.
    private let queue: PlayoutQueue
    private let clock: () -> TimeInterval
    private var order = StreamOrder()
    private static let maximumReorderGap = 3
    private static let maximumCustomOpusFramesConcealed = 8
    private static let minimumOpusFECFrames = 120
    private static let opusGapResetThreshold = 1_000_000
    private var lastCodecRepairSequence: UInt32?
    private static let sequenceRestartJump: UInt32 = 1000
    private static let sequenceRestartRun = 8
    private var lateInARow = 0
    private var held: (sequence: UInt32, plain: Data)?
    private var heldArrivals = 0
    // For the once-a-second log line: packets, the longest wait between two, frames filled in, dropouts.
    private(set) var logPackets = 0, logConcealed = 0, logUnderruns = 0
    private(set) var logMaxGapMs = 0.0
    private var lastArrival: TimeInterval?
    private var intervalDiagnostics = StreamIntervalDiagnostics()
    private var lastLoggedTrimmedFrames = 0, lastLoggedTrims = 0
    func takeLogFigures() -> (packets: Int, maxGapMs: Double, concealed: Int, underruns: Int,
                             interval: StreamIntervalDiagnostics.Snapshot, trimmedFrames: Int, trims: Int,
                             longestUnderrunMs: Double) {
        defer {
            logPackets = 0; logConcealed = 0; logUnderruns = 0; logMaxGapMs = 0
            lastLoggedTrimmedFrames = queue.trimmedFrames
            lastLoggedTrims = queue.trims
        }
        return (logPackets, logMaxGapMs, logConcealed, logUnderruns, intervalDiagnostics.take(),
                max(0, queue.trimmedFrames - lastLoggedTrimmedFrames), max(0, queue.trims - lastLoggedTrims),
                Double(queue.takeLongestUnderrunFrames()) * 1_000 / Double(Wire.sampleRate))
    }
    private func noteArrival() {
        let now = clock()
        if let lastArrival { logMaxGapMs = max(logMaxGapMs, (now - lastArrival) * 1000) }
        lastArrival = now
        logPackets += 1
        intervalDiagnostics.notePacket(now: now)
    }
    private var fragments: [UInt32: [Int: Data]] = [:]
    private var totals: [UInt32: Int] = [:]
    private var lastDecodedFrames = 0
    private static let maximumPCMFramesConcealed = 8
    private static let maximumPCMFramesPerPacket = 2880
    private static let pcmFadeFrames = 48 // 1 ms at the wire's 48 kHz rate.
    private var lastPCMLeft: Float = 0, lastPCMRight: Float = 0
    /// The session's running totals, which this stream adds to (nil: counted nowhere). (Not `totals`: that is the
    /// fragments' count above.)
    var receiveTotals: ReceiveTotals?
    var queuedFrames: Int { queue.queuedFrames }
    var nativeCodecReady: Bool {
        (format.codec == StreamFormat.Codec.opus.rawValue && opus != nil)
            || (format.codec == StreamFormat.Codec.opusCustom.rawValue && custom != nil)
    }
    var pendingPCMFrames: Int { fragments.count }
    var pendingPCMBytes: Int { fragments.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    var trimmedFrames: Int { queue.trimmedFrames }
    var smoothness: Int { queue.smoothness }
    func setSmoothness(_ level: Int) { queue.setSmoothness(level) }
    var artifact: ConcealmentArtifact { queue.artifact }
    func setArtifact(_ choice: ConcealmentArtifact) { queue.setArtifact(choice) }
    var hasAudio: Bool { queue.hasAudio }
    /// A line for the log (a snap, a hand-lowered skip). Called on the session's queue.
    var onEvent: ((String) -> Void)? {
        get { queue.onEvent }
        set { queue.onEvent = newValue }
    }
    /// The sender's clock against this Mac's, in parts per million (nil until it has been measured): positive, theirs
    /// runs fast.
    var clockPpm: Double? { ClockKeeping.on ? queue.clockPpm : nil }
    /// The sender has made this packet and any lost before it: by the sequence, so a lost packet is not read as a slow
    /// clock. Each is taken to hold what this one did.
    private func noteSenderFrames(upTo sequence: UInt32) {
        let packets = order.packets(upTo: sequence)
        guard packets > 0, packets <= 1000, lastDecodedFrames > 0 else { return }
        queue.produced(packets * lastDecodedFrames, now: clock())
    }
    private func resetForRestart() {
        queue.reset(now: clock())
        receiveTotals?.notePCMDiscarded(fragments.count)
        fragments.removeAll()
        totals.removeAll()
        lastPCMLeft = 0; lastPCMRight = 0
        held = nil; heldArrivals = 0; lateInARow = 0
        lastCodecRepairSequence = nil
        if format.codec == StreamFormat.Codec.opus.rawValue {
            rs_opus_destroy(opus)
            opus = rs_opus_decoder(Int32(format.channels))
        }
        if format.codec == StreamFormat.Codec.opusCustom.rawValue {
            rs_opus_custom_decoder_destroy(custom)
            custom = rs_opus_custom_decoder(Int32(format.frames))
        }
    }
    init(_ format: StreamFormat, jitterMs: Int = ReceiveBuffer.legacyDefaultMs,
        smoothness: Int = BufferSmoothness.defaultLevel, artifact: ConcealmentArtifact = .defaultChoice, playoutQueue: PlayoutQueue? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.format = format
        self.clock = clock
        queue = playoutQueue ?? PlayoutQueue(jitterMs: ReceiveBuffer.clamped(jitterMs), packetFrames: format.frames,
            now: clock(), smoothness: smoothness, artifact: artifact)
        if format.codec == StreamFormat.Codec.opus.rawValue { opus = rs_opus_decoder(Int32(format.channels)) }
        if format.codec == StreamFormat.Codec.opusCustom.rawValue { custom = rs_opus_custom_decoder(Int32(format.frames)) }
    }
    /// A new target. `byHand`: the person chose it (the buffer menu, a profile) - it is followed at once: lowered, the
    /// excess skipped with a crossfade; either way the pull goes up to 5 % until it is there. Otherwise (the auto-tune)
    /// a lowered target is come down to by the descent and its snap. Without the clock keeping there is no pull: a
    /// lowered target is skipped to at once, and a raised one starts again at its depth, as before.
    func setJitterMs(_ milliseconds: Int, byHand: Bool = false) {
        queue.setJitterMs(ReceiveBuffer.clamped(milliseconds), byHand: byHand, keepsInTime: ClockKeeping.on)
    }
    func takeUnderruns() -> Int { queue.takeUnderruns() }
    deinit {
        rs_opus_destroy(opus)
        rs_opus_custom_decoder_destroy(custom)
    }
    @discardableResult
    func accept(_ packet: Wire.Packet, credentials: Credentials) -> Bool {
        var encrypted = packet.payload
        let sequence: UInt32
        if format.codec == StreamFormat.Codec.pcm.rawValue {
            let subheaderBytes = 6, maximumParts = 32, maximumPendingFrames = 8, envelopeBytes = 28
            guard encrypted.count > subheaderBytes else { receiveTotals?.notePCMRejected(); return false }
            let frame = encrypted.u32(0), part = Int(encrypted[4]), total = Int(encrypted[5])
            guard total > 0, total <= maximumParts, part < total,
                encrypted.count <= Wire.maxAudioPayload + subheaderBytes,
                (1...2).contains(format.channels), [16, 24, 32].contains(format.bits) else {
                receiveTotals?.notePCMRejected(); return false
            }
            if fragments.count >= maximumPendingFrames, fragments[frame] == nil {
                receiveTotals?.notePCMDiscarded(fragments.count)
                fragments.removeAll(); totals.removeAll()
            }
            func discard() {
                if fragments.removeValue(forKey: frame) != nil { receiveTotals?.notePCMDiscarded(1) }
                totals.removeValue(forKey: frame)
                receiveTotals?.notePCMRejected()
            }
            if let old = totals[frame], old != total { discard(); return false }
            if let old = fragments[frame]?[part] {
                // Exact duplicate parts do not grow the cache. Conflicting bytes cannot replace
                // an earlier piece and keep a partial visit alive indefinitely.
                if old != encrypted.dropFirst(subheaderBytes) { discard() }
                else { receiveTotals?.notePCMRejected() }
                return false
            }
            let maximumBytes = Self.maximumPCMFramesPerPacket * format.channels * (format.bits / 8) + envelopeBytes
            let retained = fragments[frame]?.values.reduce(0) { $0 + $1.count } ?? 0
            guard encrypted.count - subheaderBytes <= maximumBytes - retained else { discard(); return false }
            totals[frame] = total
            fragments[frame, default: [:]][part] = Data(encrypted.dropFirst(subheaderBytes))
            guard let parts = fragments[frame], parts.count == total else { return false }
            encrypted = (0..<total).reduce(into: Data()) { $0.append(parts[$1]!) }
            fragments.removeValue(forKey: frame); totals.removeValue(forKey: frame)
            // Keep the Mac's authenticated, complete-frame boundary for legacy reverse-order PCM fragments.
            sequence = frame
        } else {
            sequence = packet.sequence
        }
        guard let plain = try? credentials.open(encrypted) else { receiveTotals?.noteRejectedAudio(); return false }
        if format.codec == StreamFormat.Codec.pcm.rawValue, !validPCM(plain) { return false }
        guard receiveAuthenticated(plain, sequence: sequence) else { return false }
        noteArrival()
        return true
    }
    private func receiveAuthenticated(_ plain: Data, sequence: UInt32) -> Bool {
        if held?.sequence == sequence {
            receiveTotals?.lateOrDoubledDropped += 1
            return false
        }
        if let last = order.last, Int32(bitPattern: sequence &- last) <= 0 {
            lateInARow += 1
            if last &- sequence > Self.sequenceRestartJump || lateInARow >= Self.sequenceRestartRun {
                resetForRestart()
                order.reset()
                return playAuthenticated(plain, sequence: sequence)
            }
            receiveTotals?.lateOrDoubledDropped += 1
            return false
        }
        if let waiting = held {
            if Int32(bitPattern: sequence &- waiting.sequence) < 0 {
                guard playAuthenticated(plain, sequence: sequence) else { return false }
                heldArrivals += 1
                if sequence &+ 1 == waiting.sequence || heldArrivals >= 2 { releaseHeld() }
                return true
            }
            releaseHeld()
        }
        let missing = order.last.map { Int(Int32(bitPattern: sequence &- $0)) - 1 } ?? 0
        let durationMs = max(1, (format.frames * 1000 + Int(Wire.sampleRate) - 1) / Int(Wire.sampleRate))
        let thresholdFrames = (2 * durationMs + 1) * Int(Wire.sampleRate) / 1000
        if (1...Self.maximumReorderGap).contains(missing), queue.queuedFrames >= thresholdFrames {
            held = (sequence, plain)
            heldArrivals = 0
            // Count one hold visit; duplicates, reads and release do not start another wait.
            receiveTotals?.noteReorderWait()
            return true
        }
        return playAuthenticated(plain, sequence: sequence)
    }
    private func releaseHeld() {
        guard let waiting = held else { return }
        held = nil; heldArrivals = 0
        _ = playAuthenticated(waiting.plain, sequence: waiting.sequence)
    }
    private func playAuthenticated(_ plain: Data, sequence: UInt32) -> Bool {
        let missing = order.last.map { max(0, Int(Int32(bitPattern: sequence &- $0)) - 1) } ?? 0
        var codecMissing = 0
        if format.codec != StreamFormat.Codec.pcm.rawValue {
            codecMissing = lastCodecRepairSequence.map {
                max(0, Int(Int32(bitPattern: sequence &- $0)) - 1)
            } ?? 0
            // Consume the authenticated packet before decoding: a failed arrival must not emit its repair twice.
            lastCodecRepairSequence = sequence
        }
        if format.codec == StreamFormat.Codec.opus.rawValue {
            if codecMissing == 1 { recoverOpus(from: plain) }
            else if codecMissing > 1 && codecMissing < Self.opusGapResetThreshold {
                receiveTotals?.gapsNotRepaired += 1
            }
        } else if format.codec == StreamFormat.Codec.opusCustom.rawValue {
            if codecMissing > 0 && codecMissing <= Self.maximumCustomOpusFramesConcealed {
                for _ in 0..<codecMissing { concealCustomOpus() }
            } else if codecMissing > Self.maximumCustomOpusFramesConcealed {
                receiveTotals?.gapsNotRepaired += 1
            }
        }
        guard decode(plain, pcmMissing: missing) else { return false }
        noteSenderFrames(upTo: sequence)
        order.took(sequence)
        lateInARow = 0
        return true
    }
    private func validPCM(_ data: Data) -> Bool {
        let width = format.bits / 8
        return width > 0 && format.channels > 0 && !data.isEmpty
            && data.count % (width * format.channels) == 0
            && data.count <= Self.maximumPCMFramesPerPacket * format.channels * width
    }
    private func recoverOpus(from packet: Data) {
        guard let opus else { return }
        let capacity = max(Self.minimumOpusFECFrames, format.frames)
        var out = [Float](repeating: 0, count: capacity * format.channels)
        let frames = packet.withUnsafeBytes {
            rs_opus_decode_fec(opus, $0.bindMemory(to: UInt8.self).baseAddress,
                Int32(packet.count), &out, Int32(capacity))
        }
        guard frames > 0 else { return }
        out = Array(out.prefix(Int(frames) * format.channels))
        if format.channels == 1 { out = out.flatMap { [$0, $0] } }
        appendCodecRepair(out)
    }
    private func concealCustomOpus() {
        guard let custom else { return }
        var out = [Float](repeating: 0, count: format.frames * 2)
        guard rs_opus_custom_decode(custom, nil, 0, &out) > 0 else { return }
        appendCodecRepair(out)
    }
    private func appendCodecRepair(_ samples: [Float]) {
        queue.appendConcealment(samples)
        logConcealed += 1
        receiveTotals?.concealed += 1
    }
    private func concealPCM(_ missing: Int, arrived: inout [Float]) {
        guard missing > 0 else { return }
        guard missing <= Self.maximumPCMFramesConcealed else {
            receiveTotals?.gapsNotRepaired += missing
            return
        }
        // Count lost frame IDs at the arriving piece's actual length, including variable-size PCM pieces.
        // Both stereo and the Mac's existing mono input have been normalized to stereo before this point.
        let frames = missing * (arrived.count / 2)
        var made = [Float](repeating: 0, count: frames * 2)
        let fadeOut = min(Self.pcmFadeFrames, frames)
        for frame in 0..<fadeOut {
            let gain = Float(0.5 * (1 + cos(.pi * Double(frame + 1) / Double(fadeOut))))
            made[frame * 2] = lastPCMLeft * gain
            made[frame * 2 + 1] = lastPCMRight * gain
        }
        queue.appendConcealment(made)
        let fadeIn = min(Self.pcmFadeFrames, arrived.count / 2)
        for frame in 0..<fadeIn {
            let gain = Float(0.5 * (1 - cos(.pi * Double(frame + 1) / Double(fadeIn))))
            arrived[frame * 2] *= gain
            arrived[frame * 2 + 1] *= gain
        }
        // Existing stream diagnostics count repaired packets, rather than individual samples.
        logConcealed += missing
        receiveTotals?.concealed += missing
    }
    @discardableResult private func decode(_ data: Data, pcmMissing: Int = 0) -> Bool {
        var decoded = [Float]()
        if format.codec == StreamFormat.Codec.opusCustom.rawValue {
            guard let custom else { return false }
            var out = [Float](repeating: 0, count: format.frames * 2)
            let frames = data.withUnsafeBytes {
                rs_opus_custom_decode(custom, $0.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &out)
            }
            guard frames > 0 else { return false }
            decoded = out
        } else if format.codec == StreamFormat.Codec.opus.rawValue {
            guard let opus else { return false }
            var out = [Float](repeating: 0, count: 2880 * format.channels)
            let frames = data.withUnsafeBytes {
                rs_opus_decode(opus, $0.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &out, 2880)
            }
            guard frames > 0 else { return false }
            decoded = Array(out.prefix(Int(frames) * format.channels))
        } else {
            let width = format.bits / 8
            guard validPCM(data) else { return false }
            for i in stride(from: 0, to: data.count, by: width) {
                let value: Float
                if format.encoding == 3 {
                    value = Float(bitPattern: data.u32(i))
                } else if width == 2 {
                    value = Float(Int16(bitPattern: data.u16(i))) / 32768
                } else if width == 3 {
                    value = PCM24.decodeSample(data,at:i)
                } else {
                    value = Float(Int32(bitPattern: data.u32(i))) / 2_147_483_648
                }
                decoded.append(value.isFinite ? value : 0)
            }
        }
        if format.channels == 1 { decoded = decoded.flatMap { [$0, $0] } }
        lastDecodedFrames = decoded.count / 2
        if format.codec == StreamFormat.Codec.pcm.rawValue {
            concealPCM(pcmMissing, arrived: &decoded)
            lastPCMLeft = decoded[decoded.count - 2]
            lastPCMRight = decoded[decoded.count - 1]
        }
        receiveTotals?.noteDecodedAudio(frames: decoded.count / 2)
        queue.append(decoded)
        return true
    }
    func read(_ frames: Int) -> [Float] {
        intervalDiagnostics.noteQueue(milliseconds: Double(queue.queuedFrames) * 1_000 / Double(Wire.sampleRate))
        let before = queue.underrunsTotal
        let output = queue.read(frames, now: clock(), keepsInTime: ClockKeeping.on)
        if queue.underrunsTotal > before {
            logUnderruns += 1
            receiveTotals?.audibleGaps += 1
        }
        return output
    }
}

final class AudioHistory {
    private let capacity = 48000
    private var buffer = [Float](repeating: 0, count: 96000)
    var end: Int64 = 0
    func append(_ samples: [Float], at frame: Int64) {
        for i in 0..<samples.count / 2 {
            let p = Int((frame + Int64(i)) % Int64(capacity)) * 2
            buffer[p] = samples[i * 2]
            buffer[p + 1] = samples[i * 2 + 1]
        }
        end = frame + Int64(samples.count / 2)
    }
    func read(at frame: Int64, frames: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let f = frame + Int64(i)
            if f >= max(0, end - Int64(capacity)) && f < end {
                let p = Int(f % Int64(capacity)) * 2
                result[i * 2] = buffer[p]
                result[i * 2 + 1] = buffer[p + 1]
            }
        }
        return result
    }
}
