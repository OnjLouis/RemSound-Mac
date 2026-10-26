import AudioSupport
import Foundation
import Network
import RemSoundJam
import RemSoundRuntime

public enum PeerAddResult: Equatable {
    case added(address: String, remembered: Bool)
    case invalidEntry, notRunning, unresolved, knownServer, limitReached
}

public struct PeerView: Equatable {
    public let address: String, name: String, status: String
    public let selected: Bool
}
/// A request's applied PTT state and ephemeral worker epoch; never stored in settings or control output.
public struct PushToTalkWorkerReceipt: Equatable {
    public let settings: PushToTalkSettings
    public let running: Bool
    public let generation: UUID
    public init(settings: PushToTalkSettings, running: Bool, generation: UUID) {
        self.settings = settings; self.running = running; self.generation = generation
    }
}

/// Ephemeral worker observation of the live audio UDP socket; never persisted.
public struct SessionNetworkBinding: Equatable, Sendable {
    public let port: UInt16
    public let generation: UUID
    public init(port: UInt16, generation: UUID) { self.port = port; self.generation = generation }
}

public struct SessionView {
    public let running: Bool, status: String, peers: [PeerView]
    public let networkBinding: SessionNetworkBinding?
    /// Original saved host names, including names waiting for DNS, and selected numeric peers.
    public let selectedPeerAddresses: [String]
    /// Machine-wide remembered entries available to select; excludes current selections and known servers.
    public let rememberedPeerEntries: [String]
    public let sendingInput: Bool, receiving: Bool, monitoringInApp: Bool, allowingPlugins: Bool
    public let inputDeviceUIDs: [String], inputChannelPairs: [String: [Int]]
    public let outputDeviceUID: String
    public let outputDeviceUIDs: [String]
    public let outputChannelPairs: [String: [Int]]
    public let systemCaptureDeviceUIDs: [String]?
    public let systemCaptureChannelPairs: [String: [Int]]
    public let sendCodec: SendCodec
    public let sendPacketSize: SendPacketSize
    public let pushToTalk: PushToTalkSettings
    public let pushToTalkKeyGeneration: UUID
    public let receiveJitterMs: Int
    public let receiveSmoothness: Int
    public let receiveArtifact: ConcealmentArtifact
    public let networkRTT: String
    public let recording: Bool
    /// Capture has stopped, but recording files are still draining to disk.
    public let recordingFinishing: Bool
    public let sendingSystemAudio: Bool
}

// Audio callbacks can deliver many milliseconds at once. Spread each source's queued frames
// over their actual duration so the Windows jitter buffer sees a continuous stream.
struct CapturePacer {
    private var nextPacketAt: TimeInterval?
    private let sampleRate = Double(Wire.sampleRate)
    private let maxPacketsPerTick = 4
    private static let maximumQueuedFrames = Wire.sampleRate / 4
    private static let targetQueuedFrames = Wire.sampleRate / 10

    mutating func reset() { nextPacketAt = nil }

    static func staleFrames(bufferedFrames: Int, packetFrames: Int) -> Int {
        guard packetFrames > 0, bufferedFrames > maximumQueuedFrames else { return 0 }
        let excess = bufferedFrames - targetQueuedFrames
        return excess - excess % packetFrames
    }

    mutating func packetCount(now: TimeInterval, bufferedFrames: Int, packetFrames: Int,
        pushDriven: Bool = false, sourceCount: Int = 1) -> Int {
        guard packetFrames > 0 else {
            nextPacketAt = nil
            return 0
        }
        // Independent callbacks must share one sample clock. Resetting it on an
        // empty tick, or draining each arriving input burst, over-sends the mix.
        guard bufferedFrames >= packetFrames else { return 0 }
        if pushDriven && sourceCount == 1 {
            nextPacketAt = nil
            return min(8, bufferedFrames / packetFrames)
        }
        let interval = Double(packetFrames) / sampleRate
        var due = nextPacketAt ?? now
        var count = 0
        let availablePackets = bufferedFrames / packetFrames
        while count < min(maxPacketsPerTick, availablePackets), due <= now {
            count += 1
            due += interval
        }
        nextPacketAt = due
        return count
    }
}

public final class Session {
    private let queue = DispatchQueue(label: "RemSound network and mixing", qos: .userInitiated)
    private let webAudioSource: WebSessionAudio
    private var timer: DispatchSourceTimer?
    // The routing history outlives the visible group, so departed servers cannot fall through to ordinary UDP.
    private var relayRouter: RelayGroupClient?
    private var sessionActivity = SessionActivity()
    private lazy var rememberedConnections = RememberedPeerConnections(settings: configuration.settings)
    private static let namedHistoryProofFreshness: TimeInterval = 8
    private lazy var namedPeerHistory = try? NamedPeerHistory(settings: configuration.settings)
    private var rememberingGeneration = UUID()
    private var knownServerAddresses: Set<String> = []
    private var lastRememberedPeerEntries: [String] = []
    private var directPeerSelection = DirectPeerSelectionPolicy()
    private var lockPeerAddresses = false
    private final class DirectPeerMoveToken {
        private let lock = NSLock()
        private var current = true
        var isCurrent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        func cancel() {
            lock.lock()
            current = false
            lock.unlock()
        }
    }
    private var directPeerGeneration = DirectPeerMoveToken()
    private lazy var directPeerResolver: DirectPeerResolver = {
        let resolver = DirectPeerResolver(owner: queue, monitorNetwork: useHardware)
        resolver.resolved = { [weak self] name, endpoint in
            self?.selectResolvedDirectPeer(name: name, endpoint: endpoint)
        }
        resolver.unavailable = { [weak self] _ in
            self?.log("Saved peer name unavailable; retrying in 30 seconds or when the network changes.")
        }
        return resolver
    }()
    private lazy var serverAddressResolver = ServerAddressResolver(owner: queue)
    /// Looks the connected server's name up again when it has gone quiet (ServerNameWatch), apart from a new connection's.
    private lazy var serverRecheckResolver = ServerAddressResolver(owner: queue)
    /// A main-thread question before joining, or after an unanswered probe receives telemetry.
    /// The receiver must check warning.isCurrent before presenting UI and return one decision.
    public var onServerVersionWarning: ((ServerVersionWarning, @escaping (Bool) -> Void) -> Void)?
    /// Optional release-provider boundary; call back once with a plain tag or nil. Returned work
    /// is cancelled on departure/replacement. The provider owns bounded transport/cache policy.
    public var fetchServerRelease: ((@escaping (String?) -> Void) -> (() -> Void))?
    private var injectedServerProbe: ((Endpoint, @escaping (ServerVersionProbe.Result) -> Void) -> (() -> Void))?
    private var testServerVersionWarnings = false
    private var serverVersionRequest: ServerVersionConnectionRequest?
    private var serverVersionOperation: ServerVersionOperation?
    private var serverProbeCancellation: (() -> Void)?
    private var serverVersionKnownOlder = false
    private lazy var addPeerResolver = EndpointAddressResolver(owner: queue)
    private var addPeerToken: DirectPeerMoveToken?
    private lazy var directedDiscovery = makeDirectedDiscovery()
    private var testDiscoveryDestinationPort: UInt16?
    private var directedDiscoveryEnabled: Bool {
        !configuration.isIsolated || (!useHardware && testDiscoveryDestinationPort != nil)
    }
    private func makeDirectedDiscovery(lookup: DirectedPeerDiscovery.Lookup? = nil) -> DirectedPeerDiscovery {
        DirectedPeerDiscovery(owner: queue, monitorNetwork: useHardware,
            lookup: lookup ?? { DNSAddressLookup.start($0, completion: $1) },
            isServer: { [weak self] entry, address in
                self?.rememberedConnections.isKnownServer(entry: entry, address: address) ?? true
            })
    }
    private var wire: UDP?, discovery: UDP?, bridge: UDP?
    private var credentials: Credentials?
    private var audio: DeviceAudio?
    private let id = UUID()
    /// Playing together through a server: the connection and the metronome (see the end of this file).
    fileprivate let jam = SessionJam()
    /// The server and the metronome changed: the Server menu and window, and the Metronome menu, follow this.
    public var onJamChange: ((JamView) -> Void)?
    /// Somebody asks to lead the metronome (or, while you lead, to take over): their name, whether you lead now, and
    /// the answer to call back. Called on the main thread.
    public var onMetronomeQuestion: ((_ name: String, _ whileLeading: Bool, _ answer: @escaping (Bool) -> Void) -> Void)?
    /// Words the person should hear about the metronome ("Ed is following your metronome"). Called on the main thread.
    public var onMetronomeNotice: ((String) -> Void)?
    /// Accept connections (see the end of this file): somebody who ticked us, on our password, and the answer to call
    /// back - "Do you want to allow this?". Called on the main thread; nil means nobody is here to ask.
    public var onAcceptQuestion: ((_ question: String, _ answer: @escaping (Bool) -> Void) -> Void)?
    /// Words to say when somebody has been connected for you ("Connected to Ed at 192.168.1.20."). Main thread.
    public var onAcceptNotice: ((String) -> Void)?
    fileprivate var accept = AcceptPolicy()
    /// A peer you ticked yourself is on another password (Windows CheckPeerSecurity): its address, once until that
    /// changes, for a warning. One ticked by the profile or by accept connections is held quietly instead.
    public var onPasswordMismatch: ((String) -> Void)?
    private var userTicked = Set<String>()
    /// When each peer's link last became healthy, for the details box's "Connected for".
    private var peerHealthySince: [String: TimeInterval] = [:]
    /// Someone who has just left the server, still listed "(gone)" for a while (Windows RelayGoneGrace, 15 s).
    private var goneServerMembers: [String: TimeInterval] = [:]
    static let serverGoneGrace: TimeInterval = 15
    /// The Connection status box: since when a peer has been connected without a break, and the last sample of the
    /// traffic and CPU, for the per-second figures.
    private var statusConnectedSince: TimeInterval?
    private var lastStatusSample: (at: TimeInterval, rx: Int64, tx: Int64, cpu: Double)?
    private var passwordMismatched = Set<String>()
    private var peers: [String: Peer] = [:], streams: [String: StreamDecoder] = [:],
        histories: [String: AudioHistory] = [:]
    private var streamSeen: [String: TimeInterval] = [:]
    private var plugins: [UInt32: Plugin] = [:], hosts: [Int32: HostRound] = [:]
    // Roster rows disappear while a member is absent; selection intent does not.
    // Saved addresses bind to client IDs on arrival, so a known tick follows identity.
    private var pendingServerPeerAddresses: Set<String> = []
    private var selectedServerMembers: [UUID: String] = [:]
    private var sendTargets: [Endpoint] = []
    private var sequence: UInt32 = 0
    // The Windows receiver detects missing Opus packets separately for each stream.
    private var audioSequences: [UInt16: UInt32] = [:]
    private var pcmFrameSequences: [UInt16: UInt32] = [:]
    private var nextStreamID = UInt16.random(in: 1..<UInt16.max), deviceStreamID: UInt16 = 0
    private var systemStreamID: UInt16 = 0
    private var clock: Int64 = 0, nextMix: TimeInterval = 0, nextAnnouncement: TimeInterval = 0,
        nextHello: TimeInterval = 0
    private var nextDeviceCheck: TimeInterval = 0, lastAudioIdentity = ""
    private lazy var networkRouteObserver = NetworkRouteObserver(owner: queue)
    private var nextAudioHealth: TimeInterval = 0, maxTickLag: TimeInterval = 0
    private var captureRateMeter = CaptureRateMeter()
    private var callbackRateMeter = CallbackRateMeter()
    private var captureDriftDiagnostics = CaptureSourceDriftDiagnostics()
    private var sentAudioDiagnostics = SentAudioDiagnostics()
    private var sendWorkDiagnostics = SendWorkDiagnostics()
    private var audioSendFailures = 0, lastAudioSendFailures = 0
    private var lastInputDrops = 0, lastSystemDrops = 0, audioHealthLogged = false
    private var inputTrimmedFrames = 0, systemTrimmedFrames = 0
    private var lastInputTrimmedFrames = 0, lastSystemTrimmedFrames = 0
    private var receiveTrimmedFrames = 0, lastReceiveTrimmedFrames = 0
    private var inputCaptureActivity = CaptureActivity()
    private var systemCaptureActivity = CaptureActivity()
    private var inputPacer = CapturePacer(), systemPacer = CapturePacer()
    private var sendDevice = false, sendSystemAudio = false, receive = false, monitorInApp = true
    private var sendCodec: SendCodec = .pcm
    private var sendPacketSize: SendPacketSize = .standard
    private var sendPacketFrames: Int { sendPacketSize.frames(for: sendCodec) }
    private var receiveJitterMs = ReceiveBuffer.legacyDefaultMs
    private var receiveSmoothness = BufferSmoothness.defaultLevel
    private var receiveArtifact = ConcealmentArtifact.defaultChoice
    private var receiveAutoTune = false
    private var receiveAutoTuneInterval = ReceiveBuffer.defaultAutoTuneInterval
    /// Windows' auto-tunes, fed a reading a second (ReceiveAutoTune); with "lowest delay" on, the dropout tuner instead.
    private var autoTune = ReceiveAutoTune()
    private var receiveLowestDelay = false
    /// Windows' "Apply pan and EQ to plugin audio" (machine-wide, on by default): off, a DAW track gets each peer raw, to
    /// shape in the DAW instead, as recording can.
    private var pluginShaping = true
    private var nextAutoTune: TimeInterval = 0
    private var heartbeatTiming = HeartbeatTiming()
    private var networkRTT = "not measured", lastPublishedNetworkRTT = ""
    private var nextRTTDisplay: TimeInterval = 0
    private var opusSenders: [UInt16: OpusSender] = [:]
    private var audioFormatSent: [UInt16: TimeInterval] = [:]
    private var recordingFile: RecordingFile?
    private var splitPeerFiles: [String: RecordingFile] = [:]
    private var splitSendFile: RecordingFile?
    private var recordingSource: RecordingSource = .both
    private var recordingBypassShaping = false
    private var recordedSend: [UInt16: StereoRing] = [:]
    private var lastPublishedPushToTalkKeyGeneration: UUID?
    private var networkBindingGeneration: UUID?
    private var lastPublishedNetworkBinding: SessionNetworkBinding?
    private var pushToTalkKeyGeneration = UUID()
    private var pushToTalkSettings = PushToTalkSettings()
    private var pushToTalkGate = PushToTalkAudioGate()
    private var pushToTalkLanes: [UInt16: PushToTalkLaneState] = [:]
    private let captureRetirements = CaptureRetirements()
    private var captureRetirementTimer: DispatchSourceTimer?
    private var captureRetirementPolls = 0
    private var captureRetirementTimedOut = false
    private var captureShutdownRetention: Session?
    private var captureWakeGeneration = UUID()
    private var captureWakes = [CaptureWakeAttachment]()
    private var captureWakeLimitReported = false
    private static let maximumRetainedCaptureWakes = 8
    private var finishingRecordings = 0
    private var shutdownCompletions = [() -> Void]()
    private var peerMixes: [String: PeerMix] = [:]
    private var peerAliases: [String: String] = [:]
    /// Remote volume and mute (Windows' Control packets, RemSoundJam's RemoteControl.swift): the listening volume and the
    /// receive mute - this Mac's own, which a peer may change only if acceptRemoteCommands is on - the guard against
    /// stale and replayed commands, and the counter for the ones we send. Kept across Stop and Start, as on Windows.
    private var listeningVolume = 100, receiveMuted = false, acceptRemoteCommands = false
    /// "Enable volume, pan and EQ for all peers" (Windows' EnableAllPeerShaping): off, no peer is shaped.
    private var allPeerShaping = false
    private var controlGuard = ControlReceiveGuard()
    /// Control packets from senders nobody ticked: counted, said once a minute (Windows' NoteControlRefused).
    private var controlRefused = RefusalCounter()
    private var controlSequence: UInt32 = 0
    private var equalizers: [String: PeerEqualizer] = [:]
    private var inputDeviceUIDs = [""], inputChannelPairs = [String: [Int]]()
    private var outputDeviceUID = ""
    private var outputDeviceUIDs = [""]
    private var outputChannelPairs = [String: [Int]]()
    private var systemCaptureDeviceUIDs: [String]?
    private var systemCaptureChannelPairs = [String: [Int]]()
    /// Mac system audio from chosen applications (bundle IDs) instead of whole outputs; nil: whole outputs.
    private var sendApplications: [String]?
    private var name = "RemSound Mac", running = false
    private var lastStatus = "Stopped", lastView: [PeerView] = []
    public var onChange: ((SessionView) -> Void)?
    /// A direct selection moved addresses. Delivered on the main thread only for the still-current session.
    public var onDirectPeerMove: ((_ oldAddress: String, _ newAddress: String) -> Void)?
    /// A peer moved the listening volume or switched the receive mute: (volume, muted). Called on the main thread.
    public var onListeningChange: ((Int, Bool) -> Void)?
    private var loggingEnabled: Bool
    private let configuration: RuntimeConfiguration
    public init(configuration: RuntimeConfiguration? = nil) {
        // A normal Session keeps the existing paths and identity. Test/headless callers inject their context.
        self.configuration = configuration ?? (try! RuntimeConfiguration(options: LaunchOptions.parse([])))
        loggingEnabled = self.configuration.diagnosticLoggingEnabled
        webAudioSource = WebSessionAudio(queue: queue)
        if self.configuration.isIsolated {
            audioPort = 0
            discoveryPort = 0
            bridgePort = 0
        }
    }
    // Core-only: the facade must first match its newest Start receipt and current running view.
    // True reserves one request; completion reports worker installation, not network delivery.
    func attachWebAudio(_ producer: WebAudioHandoff.Producer, completion: @escaping (Bool) -> Void) -> Bool {
        guard webAudioSource.request(producer, completion: { applied in
            DispatchQueue.main.async { completion(applied) }
        }) else { return false }
        queue.async { [self] in
            webAudioSource.apply(running: running, binding: currentNetworkBinding)
            if producer.isActive {
                // Preserve peer/recording packetization. Only the browser skips a packet
                // containing a prefix captured before this source registration.
                for key in Array(plugins.keys) {
                    let count = plugins[key]?.sendSamples.count ?? 0
                    plugins[key]?.webSkipSamples = count
                }
            }
        }
        return true
    }
    // Call before pending permission/profile changes. The owning handoff and Room still need exact close receipts.
    func revokeWebAudio() { webAudioSource.revoke() }
    func permitsWebAddressQuery(_ binding:WebAudioHandoff.Binding)->Bool {webAudioSource.permitsAddressQuery(binding)}

    // Core-only, one caller credit in BrowserListenerService. Observation is not an attachment receipt.
    func observeWebNetworkBinding(_ completion: @escaping (SessionNetworkBinding?) -> Void) -> Bool {
        queue.async { [self] in completion(currentNetworkBinding) }
        return true
    }
    // Address observations require the exact installed browser producer as well
    // as this running worker's socket. No sample or socket authority is returned.
    func observeWebAudioBinding(_ binding: WebAudioHandoff.Binding, completion: @escaping (SessionNetworkBinding?) -> Void) -> Bool {
        queue.async { [self] in
            completion(running && currentNetworkBinding == binding.network && webAudioSource.matches(binding) ? currentNetworkBinding : nil)
        }
        return true
    }
    public static func requestSystemAudioAccess() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let capture = SystemAudioCapture()
        defer { capture.stop() }
        // Starting a disposable tap brings the system permission prompt forward without sending audio.
        return (try? capture.start()) != nil
    }
    private var audioPort = Wire.audioPort, discoveryPort = Wire.discoveryPort, bridgePort = Wire.bridgePort,
        peerPort = Wire.audioPort
    private var useHardware = true
    private var testCapturePushDriven = false
    private var fixtureOutputPresentationsMs:[Double?]?
    private static let maximumFixtureOutputs=8
    private var announcementSender: ((Data, Endpoint) -> Void)?
    convenience init(testPeerPort: UInt16, testCapturePushDriven: Bool = false, activity: SessionActivity? = nil,
        serverLookup: ServerAddressResolver.Lookup? = nil,
        serverProbe: ((Endpoint, @escaping (ServerVersionProbe.Result) -> Void) -> (() -> Void))? = nil,
        latestServerRelease: ((@escaping (String?) -> Void) -> (() -> Void))? = nil,
        serverVersionWarnings: Bool = false,
        peerLookup: EndpointAddressResolver.Lookup? = nil,
        discoveryLookup: DirectedPeerDiscovery.Lookup? = nil,
        testDiscoveryDestinationPort: UInt16? = nil,
        announcementSender: ((Data, Endpoint) -> Void)? = nil,
        testOutputPresentationsMs:[Double?]? = nil) {
        guard let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] else {
            preconditionFailure("Session fixtures require REMSOUND_TEST_ROOT")
        }
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-\(UUID().uuidString)")
        let options = try! LaunchOptions.parse(["--config-dir", root.path, "--silent"])
        self.init(configuration: try! RuntimeConfiguration(options: options))
        if let serverLookup {
            serverAddressResolver = ServerAddressResolver(owner: queue, lookup: serverLookup)
            serverRecheckResolver = ServerAddressResolver(owner: queue, lookup: serverLookup)
        }
        injectedServerProbe = serverProbe
        fetchServerRelease = latestServerRelease
        testServerVersionWarnings = serverVersionWarnings
        if let peerLookup { addPeerResolver = EndpointAddressResolver(owner: queue, lookup: peerLookup) }
        audioPort = 0
        discoveryPort = 0
        bridgePort = 0
        peerPort = testPeerPort
        useHardware = false
        self.testCapturePushDriven = testCapturePushDriven
        precondition(testOutputPresentationsMs.map { values in
            values.count<=Self.maximumFixtureOutputs && values.allSatisfy { $0.map { $0.isFinite && $0>=0 } ?? true }
        } ?? true)
        fixtureOutputPresentationsMs=testOutputPresentationsMs
        self.announcementSender = announcementSender
        if let port = testDiscoveryDestinationPort, port != 0,
           ![Wire.discoveryPort, Wire.audioPort, Wire.bridgePort].contains(port) {
            self.testDiscoveryDestinationPort = port
        }
        if let discoveryLookup { directedDiscovery = makeDirectedDiscovery(lookup: discoveryLookup) }
        if let activity { sessionActivity = activity }
    }
    func testPeerHistoryReportRoot() -> URL? { queue.sync { useHardware ? nil : configuration.root } }
    static func isolatedAudioProductSession(peerPort: UInt16, root: URL) throws -> Session {
        let options = try LaunchOptions.parse(["--config-dir", root.path, "--silent"])
        let configuration = try RuntimeConfiguration(options: options)
        guard configuration.isIsolated else { throw ProtocolError.invalid("Isolated audio fixture required.") }
        let session = Session(configuration: configuration)
        session.audioPort = 0; session.discoveryPort = 0; session.bridgePort = 0
        session.peerPort = peerPort; session.useHardware = false; session.testCapturePushDriven = true
        return session
    }
    // The synchronous product runner cannot wait for a main-queue completion. Only its isolated,
    // hardware-free source may join the existing native retirement receipts on this worker.
    func finishIsolatedProductSession() -> Bool {
        guard queue.sync(execute: { !useHardware && configuration.isIsolated }) else { return false }
        shutdown()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            if queue.sync(execute: { pollCaptureCleanup() && finishingRecordings == 0 && wire == nil
                && bridge == nil && discovery == nil && !running }) { return true }
            Thread.sleep(forTimeInterval: 0.001)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    var testPorts: (audio: UInt16, bridge: UInt16, discovery: UInt16) {
        queue.sync { (wire?.boundPort ?? 0, bridge?.boundPort ?? 0, discovery?.boundPort ?? 0) }
    }
    func testWebBridgePacket(_ data: Data, from endpoint: Endpoint) {
        guard data.count <= Bridge.headerSize + Bridge.maxAudioBytes else { return }
        queue.sync {
            guard !useHardware, running, endpoint.address == "127.0.0.1", endpoint.port > 0 else { return }
            receiveBridge(data, from: endpoint, now: Date.timeIntervalSinceReferenceDate)
        }
    }
    func testWebCustomTargetCount() -> Int {
        queue.sync { useHardware ? 0 : jamulusStyleTargets(now: Date.timeIntervalSinceReferenceDate).count }
    }
    func testWebCaptureWakeSignalAfterRefresh(frames: Int) -> Int? {
        queue.sync {
            guard !useHardware, running, frames > 0, frames <= WebAudio.maximumInputSamples / WebAudioPackets.channels,
                let wake = captureWakes.last(where: { !$0.retired }), let raw = wake.producer else { return nil }
            refreshCaptureWakeConfiguration()
            return Int(rs_capture_wake_signal(raw, frames))
        }
    }
    func testWebBoundAddresses() -> [String] {
        queue.sync { useHardware ? [] : [wire?.boundAddress, discovery?.boundAddress].compactMap { $0 } }
    }
    func testReceiveArtifacts() -> [ConcealmentArtifact] {
        queue.sync { useHardware ? [] : streams.values.map(\.artifact) }
    }
    func testReceiveSmoothness() -> [Int] {
        queue.sync { useHardware ? [] : streams.values.map(\.smoothness) }
    }
    func testPlayback(_ frames: Int) -> [Float] { queue.sync { audio?.playback.read(frames) ?? [] } }
    func testCapture(_ samples: [Float]) {
        queue.sync {
            guard !useHardware, running else { return }
            audio?.capture.write(samples)
        }
    }
    func testPushToTalkGeneration() -> UUID? {
        queue.sync { useHardware ? nil : pushToTalkKeyGeneration }
    }
    func testSystemCapture(_ samples: [Float]) {
        queue.sync {
            guard !useHardware, running else { return }
            audio?.systemCapture?.samples.sources.first?.write(samples)
        }
    }
    func testCaptureObservation() -> (counters: [CaptureRateMeter.Counter], trimmedFrames: Int,
                                      drift: [CaptureSourceDriftDiagnostics.Snapshot], pushDriven: Bool)? {
        queue.sync {
            guard !useHardware, running, let audio else { return nil }
            return (audio.inputCaptureCounters, inputTrimmedFrames, captureDriftDiagnostics.snapshots,
                    audio.usesDirectBuiltInMicrophone && audio.captureMix.sources.count == 1)
        }
    }
    private struct Peer {
        var endpoint: Endpoint, name: String, advertisedName: String,
            selected: Bool = false, lastSeen: TimeInterval = 0,
            lastProof: TimeInterval = 0, status = "Waiting for them to select you"
        var instanceID: UUID?
        var manualIdentity = UUID()
        var discoveryInstanceID: UUID?
        var selectedDiscoveryID: UUID?
        var discoverySeen: TimeInterval = 0
        var discoveryAudioPort: UInt16?
        var manualEntry: String?
        var lastAnswer: TimeInterval?
        var onLink = false
    }
    struct SendRoute {
        let address: String
        let instanceID: UUID?
        let onLink: Bool
    }
    static func preferredSendRoutes(_ routes: [SendRoute]) -> [String] {
        let ordered = routes.sorted {
            if $0.onLink != $1.onLink { return $0.onLink }
            return $0.address < $1.address
        }
        var seen = Set<UUID>()
        return ordered.compactMap { route in
            if let id = route.instanceID, !seen.insert(id).inserted { return nil }
            return route.address
        }
    }
    private func updateSendTargets() {
        let selected = peers.values.filter(\.selected)
        let addresses = Set(Self.preferredSendRoutes(selected.map {
            SendRoute(address: $0.endpoint.address, instanceID: $0.instanceID,
                onLink: $0.onLink)
        }))
        var updated = selected.filter { addresses.contains($0.endpoint.address) }
            .map(\.endpoint).sorted { $0.address < $1.address }
        // Somebody on a server is reached AT the server, and one copy covers everyone there.
        if let group = jam.group {
            updated = group.sendTargets(for: updated.map(JamEndpoint.init)).map(Endpoint.init).sorted { $0.address < $1.address }
        }
        guard updated != sendTargets else { return }
        sendTargets = updated
        refreshCaptureWakeConfiguration()
        networkRouteObserver.invalidate()
        audioFormatSent.removeAll()
        jam.nextCustomFormat = 0
        for instance in plugins.keys { plugins[instance]?.formatSent = 0 }
        nextHello = 0
        if useHardware, selected.count > updated.count {
            log("One audio route selected per verified remote computer; \(selected.count) addresses reduced to \(updated.count) destinations.")
        }
    }
    private struct Plugin {
        let sourceVisit = UUID()
        var webSkipSamples = 0
        var endpoint: Endpoint, pid: Int32, seen: TimeInterval, claims: [String] = [],
            claimSeen: TimeInterval = 0
        var stream: UInt16
        var formatSent: TimeInterval = 0
        var formatCaptureMs: Double?
        var sendSamples: [Float] = []
        var lastAudioAt: TimeInterval = -.infinity
        var hostCallback = DAWCallbackObservation()
    }
    private struct HostRound {
        var round: Int64 = 0, cursor: Int64, frames: Int, served: Set<UInt32> = []
        // Keeping in time (RemSoundJam's HostTime.swift): the DAW's reads held 10 ms behind the mix, whatever its clock.
        var keeper = HostTimeKeeper()
    }
    private struct CaptureActivity {
        private var started = Date.timeIntervalSinceReferenceDate
        private var sawFrames = false, sawSignal = false, reportedMissing = false

        mutating func reset() { self = CaptureActivity() }

        mutating func observe(_ samples: [Float], source: String, targets: Int) -> [String] {
            var messages = [String]()
            if !sawFrames {
                sawFrames = true
                messages.append("\(source) capture produced frames; \(targets) selected peers.")
            }
            if !sawSignal && samples.contains(where: { abs($0) > 0.001 }) {
                sawSignal = true
                messages.append("\(source) capture contains audible-level samples; \(targets) selected peers.")
            }
            return messages
        }

        mutating func missingFrames(at now: TimeInterval, source: String) -> String? {
            guard !sawFrames, !reportedMissing, now - started >= 8 else { return nil }
            reportedMissing = true
            return "\(source) capture produced no frames after eight seconds. Check the selected device or macOS capture permission."
        }
    }
    private var proofNonces: [Data: TimeInterval] = [:]

    private func freshStreamID() -> UInt16 {
        repeat { nextStreamID &+= 1 } while nextStreamID == 0 || nextStreamID == UInt16.max
        return nextStreamID
    }

    public func start(
        password: String, peerAddress: String, savedPeerAddresses: [String] = [], lockPeerAddresses: Bool = false,
        send: Bool, receive: Bool, monitorInApp: Bool = true, plugins: Bool, name: String,
        systemAudio: Bool = false,
        inputDeviceUID: String = "", inputDeviceUIDs: [String]? = nil,
        inputChannelPairs: [String: [Int]] = [:],
        outputDeviceUID: String = "",
        outputDeviceUIDs: [String]? = nil,
        outputChannelPairs: [String: [Int]] = [:],
        systemCaptureDeviceUIDs: [String]? = nil,
        systemCaptureChannelPairs: [String: [Int]] = [:], sendCodec: SendCodec = .pcm,
        sendPacketSize: SendPacketSize = .standard,
        receiveJitterMs: Int = ReceiveBuffer.legacyDefaultMs,
        receiveSmoothness: Int = BufferSmoothness.defaultLevel,
        receiveArtifact: ConcealmentArtifact = .defaultChoice,
        receiveAutoTune: Bool = false,
        receiveAutoTuneInterval: Int = ReceiveBuffer.defaultAutoTuneInterval,
        receiveLowestDelay: Bool = false,
        peerMixes: [String: PeerMix] = [:], peerAliases: [String: String] = [:],
        serverAddress: String? = nil, profileServer: String? = nil, pushToTalk: PushToTalkSettings = .init(),
        networkCompletion: ((SessionNetworkBinding?) -> Void)? = nil,
        completion: ((PushToTalkWorkerReceipt?) -> Void)? = nil
    ) {
        revokeWebAudio()
        queue.async { [self] in
            var applied = false
            defer {
                completePushToTalkRequest(completion, applied: applied)
                completeNetworkRequest(networkCompletion, applied: applied)
            }
            stopInternal()
            pushToTalkSettings = pushToTalk
            resetPushToTalkRuntime()
            self.lockPeerAddresses = lockPeerAddresses
            rememberingGeneration = rememberedConnections.generation
            do {
                guard captureRetirements.poll() else {
                    throw ProtocolError.invalid("Previous direct input capture has not stopped safely.")
                }
                let requestedInputUIDs = inputDeviceUIDs ?? [inputDeviceUID]
                let requestedOutputUIDs = outputDeviceUIDs ?? [outputDeviceUID]
                let key = try Credentials(password: password)
                let socket = try UDP(port: audioPort, loopback: configuration.isIsolated)
                let discover = try UDP(port: discoveryPort, loopback: configuration.isIsolated, broadcast: !configuration.isIsolated)
                let link = plugins ? try UDP(port: bridgePort, loopback: true) : nil
                let devices = newDeviceAudio()
                devices.noteBufferRestoration = { [weak self] in self?.log($0) }
                var startupDiagnostics: [String] = []
                func noteStartup(_ message: String) {
                    startupDiagnostics.append(message)
                    log(message)
                }
                if useHardware {
                    try devices.start(send: send, receive: receive && monitorInApp,
                        systemAudio: systemAudio,
                        inputDeviceUIDs: requestedInputUIDs,
                        inputChannelPairs: inputChannelPairs, outputDeviceUIDs: requestedOutputUIDs,
                        outputChannelPairs: outputChannelPairs,
                        systemCaptureDeviceUIDs: systemCaptureDeviceUIDs,
                        systemCaptureChannelPairs: systemCaptureChannelPairs, systemCaptureApplications: self.sendApplications)
                    if let reason = devices.inputCaptureFallback {
                        noteStartup("Direct input capture unavailable; using audio engine: \(reason)")
                    }
                    for mode in devices.inputCaptureModes { noteStartup("Input capture started: \(mode).") }
                    if jam.bufferFrames > 0 {
                        noteStartup(devices.applyBufferFrames(jam.bufferFrames, inputUIDs: requestedInputUIDs,
                            outputUIDs: requestedOutputUIDs))
                    }
                    for setup in devices.configurationDiagnostics() { noteStartup(setup) }
                }
                credentials = key
                wire = socket
                networkBindingGeneration = UUID()
                discovery = discover
                bridge = link
                audio = devices
                sendDevice = send
                sendSystemAudio = systemAudio
                inputCaptureActivity.reset()
                systemCaptureActivity.reset()
                inputPacer.reset()
                systemPacer.reset()
                receiveTrimmedFrames = 0
                lastReceiveTrimmedFrames = 0
                self.sendCodec = sendCodec
                self.sendPacketSize = sendPacketSize
                self.receiveJitterMs = ReceiveBuffer.clamped(receiveJitterMs)
                self.receiveSmoothness = BufferSmoothness.clamped(receiveSmoothness)
                self.receiveArtifact = receiveArtifact
                self.receiveAutoTune = receiveAutoTune
                self.receiveAutoTuneInterval = ReceiveBuffer.validAutoTuneInterval(
                    receiveAutoTuneInterval)
                self.receiveLowestDelay = receiveLowestDelay
                autoTune = ReceiveAutoTune()
                nextAutoTune = Date.timeIntervalSinceReferenceDate
                    + Double(self.receiveAutoTuneInterval)
                self.peerMixes = peerMixes
                self.peerAliases = peerAliases
                if send { deviceStreamID = freshStreamID() }
                if systemAudio { systemStreamID = freshStreamID() }
                self.receive = receive
                self.monitorInApp = monitorInApp
                self.inputDeviceUIDs = requestedInputUIDs
                self.inputChannelPairs = inputChannelPairs
                self.outputDeviceUID = requestedOutputUIDs.first ?? ""
                self.outputDeviceUIDs = requestedOutputUIDs
                self.outputChannelPairs = outputChannelPairs
                self.systemCaptureDeviceUIDs = systemCaptureDeviceUIDs
                self.systemCaptureChannelPairs = systemCaptureChannelPairs
                lastAudioIdentity = audioIdentity()
                self.name = String(name.prefix(64))
                running = true
                if directedDiscoveryEnabled { directedDiscovery.start() }
                sessionActivity.start()
                jamStart()
                // Startup already reached Latest.log before the detailed session log existed.
                for message in startupDiagnostics { jam.logFile?.event(message) }
                directPeerResolver.start([peerAddress] + savedPeerAddresses, port: peerPort)
                updateSendTargets()
                let now = Date.timeIntervalSinceReferenceDate
                nextMix = now
                nextAnnouncement = 0
                nextHello = 0
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(250))
                t.setEventHandler { [weak self] in self?.tick() }
                timer = t
                t.resume()
                applied = true
                publish("Running. Select the same peer on both computers.")
                // Join only after the password, sockets and profile's peer routes are ready. A server chosen now is the
                // person's; the profile's own, connected at start, is kept and tried again until its name can be found.
                if let serverAddress { connectServer(serverAddress) }
                else if let profileServer, !profileServer.isEmpty { connectServer(profileServer, userAsked: false) }
            } catch {
                stopInternal()
                if let serverAddress {
                    jam.serverEntry = serverAddress
                    jam.serverStatus = "Could not start RemSound for the server: \(error.localizedDescription)"
                    publishJam()
                }
                publish(error.localizedDescription)
            }
        }
    }
    public func stop() {
        revokeWebAudio()
        queue.async { [self] in
            stopInternal()
            publish("Stopped")
        }
    }
    public func setAudioOptions(
        send: Bool, receive: Bool, monitorInApp: Bool = true, plugins allowPlugins: Bool,
        systemAudio: Bool = false,
        inputDeviceUID: String = "", inputDeviceUIDs: [String]? = nil,
        inputChannelPairs: [String: [Int]] = [:],
        outputDeviceUID: String = "",
        outputDeviceUIDs: [String]? = nil,
        outputChannelPairs: [String: [Int]] = [:],
        systemCaptureDeviceUIDs: [String]? = nil,
        systemCaptureChannelPairs: [String: [Int]] = [:], sendCodec: SendCodec = .pcm,
        sendPacketSize: SendPacketSize = .standard, pushToTalk: PushToTalkSettings? = nil,
        completion: ((PushToTalkWorkerReceipt?) -> Void)? = nil
    ) {
        revokeWebAudio()
        queue.async { [self] in
            var applied = false
            defer { completePushToTalkRequest(completion, applied: applied) }
            guard running else { return }
            let requestedInputUIDs = inputDeviceUIDs ?? [inputDeviceUID]
            let requestedOutputUIDs = outputDeviceUIDs ?? [outputDeviceUID]
            let previousSend = sendDevice, previousReceive = self.receive
            let previousSystemAudio = sendSystemAudio
            let previousMonitor = self.monitorInApp
            let previousInputUIDs = self.inputDeviceUIDs
            let previousOutputUIDs = self.outputDeviceUIDs
            let previousInputPairs = self.inputChannelPairs
            let previousOutputPairs = self.outputChannelPairs
            let previousSystemCaptureUIDs = self.systemCaptureDeviceUIDs
            let previousSystemCapturePairs = self.systemCaptureChannelPairs
            do {
                let nextBridge: UDP?
                if allowPlugins { nextBridge = try bridge ?? UDP(port: bridgePort, loopback: true) }
                else { nextBridge = nil }
                if send != sendDevice || systemAudio != sendSystemAudio
                    || receive != self.receive || monitorInApp != self.monitorInApp
                    || requestedInputUIDs != self.inputDeviceUIDs
                    || inputChannelPairs != self.inputChannelPairs
                    || requestedOutputUIDs != self.outputDeviceUIDs
                    || outputChannelPairs != self.outputChannelPairs
                    || systemCaptureDeviceUIDs != self.systemCaptureDeviceUIDs
                    || systemCaptureChannelPairs != self.systemCaptureChannelPairs {
                    captureWakeGeneration = UUID()
                    audio?.stop()
                    let nextAudio = newDeviceAudio()
                    nextAudio.noteBufferRestoration = { [weak self] in self?.log($0) }
                    do {
                        if useHardware {
                            try nextAudio.start(send: send, receive: receive && monitorInApp,
                                systemAudio: systemAudio,
                                inputDeviceUIDs: requestedInputUIDs,
                                inputChannelPairs: inputChannelPairs,
                                outputDeviceUIDs: requestedOutputUIDs,
                                outputChannelPairs: outputChannelPairs,
                                systemCaptureDeviceUIDs: systemCaptureDeviceUIDs,
                                systemCaptureChannelPairs: systemCaptureChannelPairs, systemCaptureApplications: self.sendApplications)
                            if let reason = nextAudio.inputCaptureFallback {
                                log("Direct input capture unavailable; using audio engine: \(reason)")
                            }
                            for mode in nextAudio.inputCaptureModes {
                                log("Input capture started: \(mode).")
                            }
                            if jam.bufferFrames > 0 {
                                log(nextAudio.applyBufferFrames(jam.bufferFrames,
                                    inputUIDs: requestedInputUIDs, outputUIDs: requestedOutputUIDs))
                            }
                            for setup in nextAudio.configurationDiagnostics() { log(setup) }
                        }
                    } catch {
                        do {
                            if useHardware {
                                try audio?.start(
                                    send: previousSend, receive: previousReceive && previousMonitor,
                                    systemAudio: previousSystemAudio,
                                    inputDeviceUIDs: previousInputUIDs,
                                    inputChannelPairs: previousInputPairs,
                                    outputDeviceUIDs: previousOutputUIDs,
                                    outputChannelPairs: previousOutputPairs,
                                    systemCaptureDeviceUIDs: previousSystemCaptureUIDs,
                                    systemCaptureChannelPairs: previousSystemCapturePairs, systemCaptureApplications: self.sendApplications)
                                if jam.bufferFrames > 0, let audio {
                                    log(audio.applyBufferFrames(jam.bufferFrames,
                                        inputUIDs: previousInputUIDs, outputUIDs: previousOutputUIDs))
                                }
                                if let audio {
                                    for setup in audio.configurationDiagnostics() { log(setup) }
                                }
                            }
                        } catch {
                            stopInternal()
                            throw error
                        }
                        throw error
                    }
                    audio = nextAudio
                    resetPushToTalkRuntime()
                    sendDevice = send
                    sendSystemAudio = systemAudio
                    inputCaptureActivity.reset()
                    systemCaptureActivity.reset()
                    inputPacer.reset()
                    systemPacer.reset()
                    audioHealthLogged = false
                    if send != previousSend {
                        opusSenders.removeValue(forKey: deviceStreamID)
                        audioSequences.removeValue(forKey: deviceStreamID)
                        pcmFrameSequences.removeValue(forKey: deviceStreamID)
                        if send { deviceStreamID = freshStreamID() }
                    }
                    if systemAudio != previousSystemAudio {
                        opusSenders.removeValue(forKey: systemStreamID)
                        audioSequences.removeValue(forKey: systemStreamID)
                        pcmFrameSequences.removeValue(forKey: systemStreamID)
                        if systemAudio { systemStreamID = freshStreamID() }
                    }
                    self.receive = receive
                    if receive != previousReceive {
                        autoTune.restart()
                        nextAutoTune = Date.timeIntervalSinceReferenceDate
                            + Double(receiveAutoTuneInterval)
                        for stream in streams.values { _ = stream.takeUnderruns() }
                    }
                    self.monitorInApp = monitorInApp
                    self.inputDeviceUIDs = requestedInputUIDs
                    self.inputChannelPairs = inputChannelPairs
                    self.outputDeviceUID = requestedOutputUIDs.first ?? ""
                    self.outputDeviceUIDs = requestedOutputUIDs
                    self.outputChannelPairs = outputChannelPairs
                    self.systemCaptureDeviceUIDs = systemCaptureDeviceUIDs
                    self.systemCaptureChannelPairs = systemCaptureChannelPairs
                    lastAudioIdentity = audioIdentity()
                    if !receive {
                        streams.removeAll()
                        streamSeen.removeAll()
                        histories.removeAll()
                        for key in plugins.keys { plugins[key]?.claims = [] }
                    }
                }
                if let pushToTalk, pushToTalk != pushToTalkSettings {
                    pushToTalkSettings = pushToTalk
                    resetPushToTalkRuntime()
                }
                bridge = nextBridge
                if !allowPlugins {
                    for plugin in plugins.values {
                        pushToTalkLanes.removeValue(forKey: plugin.stream)
                        opusSenders.removeValue(forKey: plugin.stream)
                        audioSequences.removeValue(forKey: plugin.stream)
                        pcmFrameSequences.removeValue(forKey: plugin.stream)
                    }
                    plugins.removeAll()
                    hosts.removeAll()
                }
                if sendCodec != self.sendCodec || sendPacketSize != self.sendPacketSize {
                    resetPushToTalkRuntime()
                    self.sendCodec = sendCodec
                    self.sendPacketSize = sendPacketSize
                    refreshCaptureWakeConfiguration()
                    inputPacer.reset()
                    systemPacer.reset()
                    // A new advertised format must not inherit an old partial ordinary packet.
                    jam.ordinaryPending.removeAll()
                    opusSenders.removeAll()
                    audioSequences.removeAll()
                    pcmFrameSequences.removeAll()
                    if sendDevice { deviceStreamID = freshStreamID() }
                    if sendSystemAudio { systemStreamID = freshStreamID() }
                    for instance in plugins.keys {
                        plugins[instance]?.stream = freshStreamID()
                        plugins[instance]?.sendSamples.removeAll()
                        plugins[instance]?.formatSent = 0
                    }
                }
                applied = true
                nextHello = 0
                nextAnnouncement = 0
                if jam.selfMonitor.enabled, !receive || !(sendDevice || sendSystemAudio || !plugins.isEmpty) {
                    stopSelfMonitoring("Self-monitoring off: receiving or audio sending was turned off.")
                }
                publish("Audio settings updated. Input sending \(send ? "on" : "off"), system audio \(systemAudio ? "on" : "off"), receiving \(receive ? "on" : "off"), Mac output \(monitorInApp ? "on" : "off"), DAW plugins \(allowPlugins ? "on" : "off").")
            } catch {
                publish("Could not change audio settings: \(error.localizedDescription)")
            }
        }
    }
    private var currentNetworkBinding: SessionNetworkBinding? {
        guard running, let wire, wire.boundPort > 0, let generation = networkBindingGeneration else { return nil }
        return .init(port: wire.boundPort, generation: generation)
    }
    private func completeNetworkRequest(_ completion: ((SessionNetworkBinding?) -> Void)?, applied: Bool) {
        guard let completion else { return }
        // Copy this request's observation on the worker. A later Start/Stop may
        // replace it before main delivery; the App must fence its own request.
        let binding = applied ? currentNetworkBinding : nil
        DispatchQueue.main.async { completion(binding) }
    }
    private func completePushToTalkRequest(_ completion: ((PushToTalkWorkerReceipt?) -> Void)?, applied: Bool) {
        guard let completion else { return }
        let result = applied && running
            ? PushToTalkWorkerReceipt(settings: pushToTalkSettings, running: running, generation: pushToTalkKeyGeneration)
            : nil
        DispatchQueue.main.async { completion(result) }
    }
    /// The App owns key registration. The required snapshot generation also fences delayed events on this worker.
    public func setPushToTalkKeyTalking(_ talking: Bool, generation: UUID) {
        queue.async { [self] in
            guard running, generation == pushToTalkKeyGeneration,
                pushToTalkSettings.enabled, pushToTalkSettings.trigger == .key else { return }
            pushToTalkGate.setKeyTalking(talking)
        }
    }
    public func shutdown() { revokeWebAudio(); queue.sync { stopInternal() } }
    /// Stops the session and calls back on the main thread after recording writers, native capture and notification consumers have closed.
    /// Unlike the synchronous stop, this leaves the main queue available for writer completion callbacks.
    public func shutdown(completion: @escaping () -> Void) {
        revokeWebAudio()
        queue.async { [self] in
            stopInternal()
            publish("Stopped")
            shutdownCompletions.append(completion)
            // A caller may release the session immediately after requesting
            // asynchronous shutdown. Retain native/consumer ownership until safe.
            captureShutdownRetention = self
            completeShutdownIfReady()
        }
    }
    deinit {
        revokeWebAudio()
        sessionActivity.stop()
        timer?.cancel()
        captureRetirementTimer?.cancel()
        // Final release can occur off the worker. Transfer only the resources;
        // do not resurrect Session or stop native capture on the releasing thread.
        let cleanup = CaptureResourceCleanup(owner: queue, audio: audio,
            retirements: captureRetirements, wakes: captureWakes,
            remainingPolls: captureRetirementTimedOut ? 0 : max(0, CaptureCleanupPolicy.maximumPolls - captureRetirementPolls))
        let files = ([recordingFile, splitSendFile] + splitPeerFiles.values.map { Optional($0) })
            .compactMap { $0 }
        queue.async {
            cleanup.start()
            for file in files { file.finish { _, _, _ in } }
        }
    }
    private func newDeviceAudio() -> DeviceAudio {
        captureRetirements.noteFailure = { [weak self] in self?.log($0) }
        let makeWake: () -> CaptureWakeAttachment? = { [weak self] in self?.makeCaptureWake() }
        return useHardware
            ? DeviceAudio(captureRetirements: captureRetirements, makeCaptureWake: makeWake)
            : DeviceAudio(isolatedCapturePushDriven: testCapturePushDriven,
                captureRetirements: captureRetirements, makeCaptureWake: makeWake)
    }
    private func makeCaptureWake() -> CaptureWakeAttachment? {
        captureWakeGeneration = UUID()
        let generation = captureWakeGeneration
        captureWakes.removeAll { $0.disposed }
        guard captureWakes.count < Self.maximumRetainedCaptureWakes else {
            if !captureWakeLimitReported {
                captureWakeLimitReported = true
                log("Capture notification contexts are still draining; this source keeps the timer fallback.")
            }
            return nil
        }
        captureWakeLimitReported = false
        let wake = CaptureWakeAttachment(owner: queue, ready: { [weak self] in
            guard let self, self.running, self.captureWakeGeneration == generation else { return }
            self.tick()
        }, observed: { [weak self] figures in
            guard let self, self.running, self.captureWakeGeneration == generation,
                figures.timing_available == 1 else { return }
            self.sendWorkDiagnostics.noteWake(firstNs: figures.first_delay_ns, latestNs: figures.latest_delay_ns)
        }, finished: { [weak self] _ in
            guard let self else { return }
            _ = self.pollCaptureCleanup()
            self.completeShutdownIfReady()
        }, noteFailure: { [weak self] in self?.log($0) })
        if let wake { captureWakes.append(wake) }
        else { log("Capture notification unavailable; this source keeps the timer fallback.") }
        return wake
    }
    private func refreshCaptureWakeConfiguration() {
        let fast = jamulusStyleTargets(now: Date.timeIntervalSinceReferenceDate)
        audio?.configureCaptureWake(packetFrames: fast.isEmpty ? sendPacketFrames : JamulusStyle.frames,
            sending: sendDevice, hasDestination: !sendTargets.isEmpty || webAudioSource.hasDestination)
    }
    @discardableResult
    private func pollCaptureCleanup() -> Bool {
        let stopped = captureRetirements.poll()
        for wake in captureWakes where wake.retired { _ = wake.poll(producersStopped: stopped) }
        captureWakes.removeAll { $0.disposed }
        return stopped && !captureWakes.contains { $0.retired }
    }
    private func serviceCaptureRetirements() {
        let pending = captureRetirements.count > 0 || captureWakes.contains { $0.retired }
        if !pending { captureRetirementTimedOut = false; return }
        guard !captureRetirements.exhausted, !captureRetirementTimedOut,
            captureRetirementTimer == nil else { return }
        captureRetirementPolls = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        captureRetirementTimer = timer
        timer.schedule(deadline: .now(), repeating: CaptureCleanupPolicy.pollInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            captureRetirementPolls += 1
            if pollCaptureCleanup() {
                captureRetirementTimer?.cancel()
                captureRetirementTimer = nil
                completeShutdownIfReady()
            } else if captureRetirements.exhausted || captureRetirementPolls >= CaptureCleanupPolicy.maximumPolls {
                captureRetirementTimedOut = true
                captureRetirementTimer?.cancel()
                captureRetirementTimer = nil
                // Retain unresolved callbacks; do not claim safe shutdown or
                // create another provider. Restart is required after exhausted cleanup.
                log("Capture cleanup could not complete; native registrations or notifications remain retained. Restart the app before reconfiguring capture.")
            }
        }
        timer.resume()
    }
    private func completeShutdownIfReady() {
        guard finishingRecordings == 0, captureRetirements.count == 0, captureWakes.isEmpty,
            !shutdownCompletions.isEmpty else { return }
        let completions = shutdownCompletions
        shutdownCompletions.removeAll()
        captureShutdownRetention = nil
        DispatchQueue.main.async { completions.forEach { $0() } }
    }
    /// This Mac's listening volume (0...100) and receive mute: what is heard through its outputs and recorded as received.
    /// DAW plugins and the metronome's clicks are not affected (as on Windows).
    public func setListening(volume: Int, muted: Bool) {
        queue.async { [self] in
            listeningVolume = min(100, max(0, volume))
            receiveMuted = muted
            if muted { stopSelfMonitoring("Self-monitoring off: received audio is muted.") }
        }
    }
    /// "Accept remote volume commands from peers": off (the default) ignores every Control packet.
    public func setAcceptRemoteCommands(_ on: Bool) {
        queue.async { [self] in acceptRemoteCommands = on }
    }
    /// Send a volume or mute command to every peer we send to (Windows' SendRemoteControl): it changes nothing here, and
    /// only a peer with "Accept remote volume commands from peers" on acts on it. Not running: nothing is sent.
    public func sendRemoteControl(_ kind: RemoteControl.Kind) {
        queue.async { [self] in
            guard running else { return }
            let name = RemoteControl.name(kind)
            guard let credentials else {
                log("remote-control NOT sent (no profile password set) kind=\(name)")
                return
            }
            let targets = sendTargets
            guard !targets.isEmpty else { return }
            let delta = RemoteControl.delta(for: kind)
            let plain = RemoteControl.plaintext(kind, delta: delta, unixSeconds: Int64(Date().timeIntervalSince1970))
            guard let sealed = try? credentials.seal(Data(plain)) else { return }
            controlSequence &+= 1
            let packet = Wire.packet(.control, stream: RemoteControl.streamID, sequence: controlSequence, payload: sealed)
            var sent = 0
            for endpoint in targets where peerSend(packet, to: endpoint) { sent += 1 }
            log("remote-control sent kind=\(name) delta=\(delta) seq=\(controlSequence) peers=\(sent)/\(targets.count)")
        }
    }
    /// The master switch for every peer's volume, pan and EQ.
    public func setAllPeerShaping(_ on: Bool) {
        queue.async { [self] in
            allPeerShaping = on
            if !on { equalizers.removeAll() }
        }
    }
    /// A line for the log from the window (what the person changed), in order with the session's own.
    /// Applies a profile choice and its computer setting before changing the serial logger gate.
    @discardableResult public func applyDiagnosticLogging(profileChoice: Bool?) -> Bool {
        queue.sync { [self] in
            if let choice = profileChoice,
               !DiagnosticLoggingPreferences.setEnabled(choice, in: configuration.settings) { return false }
            let enabled = profileChoice ?? DiagnosticLoggingPreferences.enabled(in: configuration.settings)
            guard enabled != loggingEnabled else { return true }
            if !enabled {
                jam.logFile?.close(keepReadings: false)
                jam.logFile = nil
                jam.logPathMonitor?.cancel()
                jam.logPathMonitor = nil
            }
            loggingEnabled = enabled
            if enabled && running { openDetailedLog() }
            return true
        }
    }
    public var diagnosticLoggingEnabled: Bool { queue.sync { loggingEnabled } }
    public func note(_ message: String) {
        queue.async { [self] in log(message) }
    }
    /// Write logs now (Preferences): keep the five minutes before this moment in the readings file, mark it in the log,
    /// and write everything waiting, so it can be read straight away (Windows 6.2.3).
    public func writeLogsNow() {
        queue.async { [self] in
            guard let file = jam.logFile else { return }
            let kept = file.capture(lookBack: 300)
            file.event(.info, "Log", "user requested write logs now" + (kept.map { " - kept: \($0)" } ?? ""))
            file.flushReadings()
            file.flush()
        }
    }
    /// This Mac woke from sleep: a line of its own, and named in the reason of a disconnect soon after.
    public func noteWake() {
        queue.async { [self] in
            jam.connectionLog.woke(Date())
            jam.logFile?.event(.info, "Power", "this Mac woke from sleep")
        }
    }
    /// The log being written now (nil while logging is off or before its first line), the logs folder, and what this
    /// run's files start with: Preferences' Open current log and Open logs folder, and deleting logs around them.
    public var currentLog: (file: URL?, folder: URL, stem: String?) {
        queue.sync { (jam.logFile?.currentFile, jam.logFolder ?? configuration.logsDirectory, jam.logFile?.stem) }
    }
    /// Mac system audio from these applications (bundle IDs) instead of whole outputs; nil: whole outputs. Changed while
    /// sending, only the system audio capture starts again. Completion reports the actual running
    /// worker receipt on the main queue, or nil when stopped or capture could not be changed.
    public func setSendApplications(_ applications: [String]?, completion: ((PushToTalkWorkerReceipt?) -> Void)? = nil) {
        revokeWebAudio()
        queue.async { [self] in
            var applied = false
            defer { completePushToTalkRequest(completion, applied: applied) }
            guard running else { sendApplications = applications; return }
            applied = true
            guard applications != sendApplications else { return }
            sendApplications = applications
            guard sendSystemAudio, let group = audio?.systemCapture else { return }
            resetPushToTalkRuntime()
            do {
                try group.start(deviceUIDs: systemCaptureDeviceUIDs, channelPairs: systemCaptureChannelPairs,
                    applications: applications)
                systemCaptureActivity.reset()
                systemPacer.reset()
                log("System audio: sending \(applications.map { "\($0.count) chosen application(s)" } ?? "whole outputs").")
                if let line = group.lastChange { log(line) }
                publish()
            } catch {
                applied = false
                publish("Could not change Mac system audio: \(error.localizedDescription)")
            }
        }
    }
    public func setPeerMix(address: String, mix: PeerMix) {
        queue.async { [self] in
            peerMixes[address] = mix
            if !mix.enabled { equalizers.removeValue(forKey: address) }
            else if let equalizer = equalizers[address] { equalizer.configure(mix.eq) }
            publish("Peer mix updated for \(peers[address]?.name ?? address).")
        }
    }
    public var namedPeerRecords: [NamedPeerRecord]? { queue.sync { namedPeerHistory?.entries } }
    public func renameNamedPeer(_ record: NamedPeerRecord, friendlyName: String) -> Bool {
        queue.sync {
            guard namedPeerHistory?.rename(record, friendlyName: friendlyName) == true else { return false }
            refreshNamedPeers(clearedMachines: friendlyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [record.machineName.lowercased()] : [])
            publish("Named peer updated.")
            return true
        }
    }
    public func forgetNamedPeers(_ records: [NamedPeerRecord]) -> Bool {
        queue.sync {
            guard namedPeerHistory?.forget(records) == true else { return false }
            refreshNamedPeers(clearedMachines: Set(records.map { $0.machineName.lowercased() }))
            publish("Selected peer names forgotten. Connections are unchanged.")
            return true
        }
    }
    private func peerDisplayName(machine: String, address: String) -> String {
        namedPeerHistory?.friendlyName(machine: machine) ?? peerAliases[address] ?? machine
    }
    private func refreshNamedPeers(clearedMachines: Set<String> = []) {
        for address in peers.keys {
            guard var peer = peers[address] else { continue }
            if clearedMachines.contains(peer.advertisedName.lowercased()) { peerAliases.removeValue(forKey: address) }
            peer.name = peerDisplayName(machine: peer.advertisedName, address: address)
            peers[address] = peer
        }
    }
    public func friendlyNameForPeer(address: String) -> String? {
        queue.sync { peers[address].flatMap { namedPeerHistory?.friendlyName(machine: $0.advertisedName) } }
    }
    public func setPeerAlias(address: String, alias: String) {
        setPeerAlias(address: address, alias: alias, expectedDisplayName: nil)
    }
    public func setPeerAlias(address: String, alias: String, expectedDisplayName: String?) {
        queue.async { [self] in
            let normalized = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard let peer = peers[address], expectedDisplayName.map({ $0 == peer.name }) ?? true,
                namedPeerHistory?.name(machine: peer.advertisedName, address: address, friendlyName: normalized) == true else {
                publish("Peer name could not be saved. The previous name is unchanged.")
                return
            }
            // Global names follow the machine, rather than modifying a profile's saved address aliases.
            peerAliases.removeValue(forKey: address)
            refreshNamedPeers(clearedMachines: normalized.isEmpty ? [peer.advertisedName.lowercased()] : [])
            publish(normalized.isEmpty ? "Peer name restored." : "Peer renamed to \(normalized).")
        }
    }
    public func setReceiveArtifact(_ choice: ConcealmentArtifact) {
        queue.async { [self] in
            guard choice != receiveArtifact else { return }
            receiveArtifact = choice
            for stream in streams.values { stream.setArtifact(choice) }
            publish("Receive gap sound set to \(choice.label).")
        }
    }
    public func setReceiveSmoothness(_ level: Int) {
        queue.async { [self] in
            let requested = BufferSmoothness.clamped(level)
            guard requested != receiveSmoothness else { return }
            receiveSmoothness = requested
            for stream in streams.values { stream.setSmoothness(requested) }
            publish("Receive buffer smoothness set to \(requested).")
        }
    }
    public func setReceiveJitterMs(_ milliseconds: Int) {
        queue.async { [self] in
            let requested = ReceiveBuffer.clamped(milliseconds)
            guard requested != receiveJitterMs else { return }
            receiveJitterMs = requested
            // Your own value: the usual tune waits an interval, the lowest-delay one five seconds (Windows' pause).
            autoTune.youSetIt(now: Date.timeIntervalSinceReferenceDate)
            nextAutoTune = Date.timeIntervalSinceReferenceDate
                + Double(receiveAutoTuneInterval)
            for stream in streams.values {
                _ = stream.takeUnderruns()
                stream.setJitterMs(requested, byHand: true)
            }
            if running { publish("Receive jitter buffer set to \(requested) milliseconds.") }
        }
    }
    public func setReceiveAutoTune(_ enabled: Bool, interval: Int) {
        queue.async { [self] in
            receiveAutoTune = enabled
            receiveAutoTuneInterval = ReceiveBuffer.validAutoTuneInterval(interval)
            autoTune.restart()
            nextAutoTune = Date.timeIntervalSinceReferenceDate
                + Double(receiveAutoTuneInterval)
            for stream in streams.values { _ = stream.takeUnderruns() }
            if running {
                publish("Receive auto-tune \(enabled ? "on" : "off"); checking every \(receiveAutoTuneInterval) seconds.")
            }
        }
    }
    /// What a DAW track receives: each peer as you hear them (pan and EQ applied), or raw.
    public func setPluginShaping(_ on: Bool) {
        queue.async { [self] in
            guard pluginShaping != on else { return }
            pluginShaping = on
            log("pan and EQ into the DAW: \(on ? "on (what you hear)" : "off (raw)")")
        }
    }
    /// "Lowest-delay auto-tune, accepting a rare dropout" (Windows): with auto-tune on, the dropout tuner instead of the
    /// usual one.
    public func setReceiveLowestDelay(_ on: Bool) {
        queue.async { [self] in
            guard receiveLowestDelay != on else { return }
            receiveLowestDelay = on
            autoTune.restart()
            log("lowest-delay auto-tune \(on ? "on" : "off")")
            if running { publish("Lowest-delay auto-tune \(on ? "on" : "off").") }
        }
    }
    public func startRecording(url: URL, source: RecordingSource,
        format: RecordingFormat = .wav24, channels: RecordingChannels = .stereo,
        split: Bool = false, bypassShaping: Bool = false,
        flacCompression: Int = FLACCompression.defaultLevel) {
        queue.async { [self] in
            guard running else { publish("Start RemSound before recording."); return }
            guard !isRecording else { return }
            do {
                if split {
                    let selected = peers.values.filter(\.selected).sorted {
                        $0.endpoint.address < $1.endpoint.address
                    }
                    guard source != .received || !selected.isEmpty else {
                        throw ProtocolError.invalid("Select a peer before starting a split received recording.")
                    }
                    try FileManager.default.createDirectory(at: url,
                        withIntermediateDirectories: true)
                    // Windows' track names: each peer's name and the start time (their address too when two share a name),
                    // the click "Metronome", and your own this computer's name.
                    let stamp = DateFormatter()
                    stamp.dateFormat = "HH-mm-ss"
                    let time = stamp.string(from: Date())
                    var files: [String: RecordingFile] = [:]
                    if source != .sent {
                        var used = Set<String>()
                        for peer in selected {
                            let base = Self.safeRecordingName(peer.name.isEmpty ? peer.endpoint.address : peer.name)
                            var filename = "\(base) \(time)"
                            if !used.insert(filename.lowercased()).inserted { filename = "\(base) (\(peer.endpoint.address)) \(time)" }
                            files[peer.endpoint.address] = try RecordingFile(
                                url: url.appendingPathComponent("\(filename).\(format.fileExtension)"), format: format,
                                channels: channels, flacCompression: flacCompression)
                        }
                    }
                    // The click, when the profile records it: a track of its own (Windows, "Include the click").
                    if jam.clicksRecorded && jam.hearIn == .remSound {
                        files[MetronomeDAW.address] = try RecordingFile(
                            url: url.appendingPathComponent("\(MetronomeDAW.name) \(time).\(format.fileExtension)"), format: format,
                            channels: channels, flacCompression: flacCompression)
                    }
                    let own = source == .received ? nil : try RecordingFile(
                        url: url.appendingPathComponent("\(Self.recordingMachineName()) \(time).\(format.fileExtension)"),
                        format: format, channels: channels, flacCompression: flacCompression)
                    splitPeerFiles = files
                    splitSendFile = own
                } else {
                    recordingFile = try RecordingFile(url: url, format: format,
                        channels: channels, flacCompression: flacCompression)
                }
                recordingSource = source
                recordingBypassShaping = bypassShaping
                recordedSend.removeAll()
                log("recording: started format=\(format.rawValue) source=\(source.rawValue) split=\(split) bypass=\(bypassShaping) flacCompression=\(flacCompression)")
                publish("Recording \(source.label.lowercased()) to \(url.lastPathComponent).")
            } catch { publish("Could not start recording: \(error.localizedDescription)") }
        }
    }
    /// This computer's name for recording file names (Windows uses Environment.MachineName), made safe for a file name.
    public static func recordingMachineName() -> String {
        safeRecordingName(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }
    private static func safeRecordingName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Peer" : cleaned
    }
    private var isRecording: Bool {
        recordingFile != nil || !splitPeerFiles.isEmpty || splitSendFile != nil
    }
    public func stopRecording() {
        queue.async { [self] in
            guard isRecording else { return }
            finishRecording()
            publish("Finishing recording.")
        }
    }
    private func finishRecording() {
        let files = ([recordingFile, splitSendFile] + splitPeerFiles.values.map { Optional($0) })
            .compactMap { $0 }
        recordingFile = nil
        splitSendFile = nil
        splitPeerFiles.removeAll()
        recordedSend.removeAll()
        finishingRecordings += 1
        let group = DispatchGroup()
        for file in files {
            group.enter()
            file.finish { [weak self] url, drops, error in
                guard let self else { group.leave(); return }
                self.queue.async {
                    if let error {
                        self.publish("Recording disk error: \(error). Partial file: \(url.lastPathComponent).")
                    } else if drops > 0 {
                        self.publish("Recording saved as \(url.lastPathComponent); \(drops) audio blocks dropped.")
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: queue) { [weak self] in
            guard let self else { return }
            self.finishingRecordings -= 1
            self.publish("Recording finished. \(files.count) file\(files.count == 1 ? "" : "s") saved.")
            self.completeShutdownIfReady()
        }
    }
    /// The person's own tick or untick in the peer list.
    public func setSelected(address: String, selected: Bool) {
        queue.async { [self] in
            guard peers[address] != nil else { return }
            accept.userChose(acceptKey(address), selected: selected)
            if selected { userTicked.insert(address) } else { userTicked.remove(address) }
            passwordMismatched.remove(address)
            applySelected(address: address, selected: selected)
        }
    }
    /// A tick or untick, the person's or accept connections' own, on the queue.
    private func applySelected(address: String, selected: Bool) {
            guard peers[address] != nil else { return }
            peers[address]?.selected = selected
            if selected, !lockPeerAddresses {
                let discoveredID = peers[address]?.discoveryInstanceID
                peers[address]?.selectedDiscoveryID = discoveredID
            } else if !selected {
                directPeerSelection.forget(peers[address]?.selectedDiscoveryID)
                peers[address]?.selectedDiscoveryID = nil
            }
            if JamWire.isMemberAddress(address) {
                if selected, let member = jam.group?.members.first(where: { $0.address.address == address }) {
                    selectedServerMembers[member.id] = address
                    pendingServerPeerAddresses.remove(address)
                } else if selected {
                    pendingServerPeerAddresses.insert(address)
                } else {
                    pendingServerPeerAddresses.remove(address)
                    selectedServerMembers = selectedServerMembers.filter { $0.value != address }
                }
            }
            if selected, let peer = peers[address], !JamWire.isMemberAddress(address) {
                rememberSelectedPeer(peer)
            }
            updateSendTargets()
            syncServerTicks()
            if !selected {
                heartbeatTiming.forget(address)
                for key in streams.keys.filter({ $0.hasPrefix(address + "/") }) {
                    streams.removeValue(forKey: key)
                    streamSeen.removeValue(forKey: key)
                }
                histories.removeValue(forKey: address)
                equalizers.removeValue(forKey: address)
            }
            nextHello = 0
            nextRTTDisplay = 0
            publish(selected ? "Peer selected. Waiting for their selection." : "Peer deselected.")
    }
    private func rememberedIdentity(_ peer: Peer) -> RememberedPeerIdentity {
        let identity: UUID
        if peer.manualEntry != nil, peer.selectedDiscoveryID == nil { identity = peer.manualIdentity }
        else { identity = peer.selectedDiscoveryID ?? peer.discoveryInstanceID ?? peer.manualIdentity }
        return .init(instanceID: identity, advertisedName: peer.advertisedName, address: peer.endpoint.address)
    }
    private func rememberedConnectionRows() -> [RememberedPeerConnection] {
        peers.values.filter { !JamWire.isMemberAddress($0.endpoint.address) }.map {
            .init(identity: rememberedIdentity($0), selected: $0.selected,
                  isKnownServer: knownServerAddresses.contains($0.endpoint.address))
        }
    }
    private func rememberSelectedPeer(_ peer: Peer) {
        let identity = rememberedIdentity(peer)
        let server = knownServerAddresses.contains(peer.endpoint.address)
        if let entry = peer.manualEntry {
            rememberedConnections.rememberManual(entry, peer: identity, isKnownServer: server)
        } else {
            rememberedConnections.rememberDiscovered(identity,
                among: rememberedConnectionRows().filter { !$0.isKnownServer }.map(\.identity), isKnownServer: server)
        }
    }
    public func setLockPeerAddresses(_ locked: Bool) {
        queue.async { [self] in
            guard lockPeerAddresses != locked else { return }
            lockPeerAddresses = locked
            directPeerSelection.reset()
            if running {
                reconcileDirectPeerSelections(now: Date.timeIntervalSinceReferenceDate)
                updateSendTargets()
                publish()
            }
        }
    }

    public func forgetRememberedPeer(_ entry: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            cancelAddingPeerInternal()
            let saved = rememberedConnections.forget(entry)
            publish(saved ? "Remembered peer removed." : "Could not save remembered peer list.")
            DispatchQueue.main.async { completion?(saved) }
        }
    }
    public func clearRememberedPeers(completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            cancelAddingPeerInternal()
            let saved = rememberedConnections.clear()
            publish(saved ? "Remembered peer list cleared." : "Could not save remembered peer list.")
            DispatchQueue.main.async { completion?(saved) }
        }
    }
    func testRememberedPeers() -> (all: [String], available: [String]) {
        queue.sync {
            guard !useHardware else { return ([], []) }
            rememberedConnections.update(rememberedConnectionRows())
            return (rememberedConnections.entries, rememberedConnections.availableEntries)
        }
    }

    /// Adds one explicit IP/hostname selection. A newer Add, clear/forget or Stop cancels the old request.
    /// A still-current completion is delivered on the main thread; cancellation does not deliver a stale result.
    public func addPeer(_ entry: String, completion: ((PeerAddResult) -> Void)? = nil) {
        queue.async { [self] in
            cancelAddingPeerInternal()
            let token = DirectPeerMoveToken()
            addPeerToken = token
            let generation = rememberedConnections.generation
            let finish: (PeerAddResult) -> Void = { [weak self] result in
                guard let self, token.isCurrent else { return }
                switch result {
                case .added(_, let remembered): self.publish(remembered ? "Peer added." : "Peer added, but could not save remembered peer list.")
                case .invalidEntry: self.publish("Enter a valid IPv4 address or hostname, with an optional port from 1 to 65535.")
                case .notRunning: self.publish("Start RemSound first, then add a peer.")
                case .unresolved: self.publish("Could not resolve that IP address or hostname.")
                case .knownServer: self.publish("That's a known server. Use Connect to server.")
                case .limitReached: self.publish("The direct peer selection list is full.")
                }
                DispatchQueue.main.async {
                    guard token.isCurrent else { return }
                    completion?(result)
                }
            }
            guard running else { finish(.notRunning); return }
            guard let parsed = PeerAddressEntry.parse(entry, defaultPort: peerPort) else { finish(.invalidEntry); return }
            guard !rememberedConnections.isKnownServer(entry: parsed.text) else { finish(.knownServer); return }
            addPeerResolver.start(parsed.host, port: parsed.port) { [weak self] endpoint in
                guard let self, token.isCurrent, self.running,
                      self.rememberedConnections.generation == generation else { return }
                guard let endpoint else { finish(.unresolved); return }
                guard !self.rememberedConnections.isKnownServer(entry: parsed.text, address: endpoint.address) else {
                    finish(.knownServer); return
                }
                guard self.directPeerResolver.record(name: parsed.text, address: endpoint.address) else {
                    finish(.limitReached); return
                }
                let remembered = self.selectResolvedDirectPeer(name: parsed.text, endpoint: endpoint,
                    rememberedGeneration: generation, replaceEndpoint: true)
                finish(.added(address: endpoint.address, remembered: remembered))
            }
        }
    }
    public func cancelAddingPeer() {
        queue.async { [self] in cancelAddingPeerInternal() }
    }
    private func cancelAddingPeerInternal() {
        addPeerToken?.cancel()
        addPeerToken = nil
        addPeerResolver.stop()
    }

    @discardableResult
    private func selectResolvedDirectPeer(name: String, endpoint: Endpoint,
                                         rememberedGeneration: UUID? = nil, replaceEndpoint: Bool = false) -> Bool {
        guard running else { return false }
        var remembered = false
        if var peer = peers[endpoint.address] {
            if replaceEndpoint, peer.endpoint != endpoint {
                peer.endpoint = endpoint
                peer.instanceID = nil
                peer.lastProof = 0
                peer.lastAnswer = nil
                peer.status = "Waiting for them to select you"
                heartbeatTiming.forget(endpoint.address)
                for key in streams.keys.filter({ $0.hasPrefix(endpoint.address + "/") }) {
                    streams.removeValue(forKey: key)
                    streamSeen.removeValue(forKey: key)
                }
                histories.removeValue(forKey: endpoint.address)
            }
            peer.selected = true
            peers[endpoint.address] = peer
        } else {
            peers[endpoint.address] = Peer(endpoint: endpoint,
                name: peerDisplayName(machine: name, address: endpoint.address), advertisedName: name,
                selected: true, lastSeen: Date.timeIntervalSinceReferenceDate,
                onLink: endpoint.isOnDirectSubnet())
        }
        peers[endpoint.address]?.manualEntry = name
        if !JamWire.isMemberAddress(endpoint.address), let peer = peers[endpoint.address] {
            remembered = rememberedConnections.rememberManual(name, peer: rememberedIdentity(peer),
                generation: rememberedGeneration ?? rememberingGeneration, isKnownServer: knownServerAddresses.contains(endpoint.address))
        }
        if !lockPeerAddresses {
            let discoveredID = peers[endpoint.address]?.discoveryInstanceID
            peers[endpoint.address]?.selectedDiscoveryID = discoveredID
        }
        if JamWire.isMemberAddress(endpoint.address) {
            pendingServerPeerAddresses.insert(endpoint.address)
        }
        reconcileDirectPeerSelections(now: Date.timeIntervalSinceReferenceDate)
        updateSendTargets()
        if timer != nil {
            log("Saved peer address resolved; route selected.")
            publish()
        }
        return remembered
    }

    func testSelectResolvedDirectPeer(name: String, endpoint: Endpoint) {
        queue.sync {
            guard !useHardware, running, endpoint.address.hasPrefix("127.") else { return }
            selectResolvedDirectPeer(name: name, endpoint: endpoint)
        }
    }
    func testDiscoveryPacket(_ data: Data, from endpoint: Endpoint) {
        queue.sync {
            guard !useHardware, running, endpoint.address.hasPrefix("127.") else { return }
            receiveAnnouncement(data, from: endpoint, now: Date.timeIntervalSinceReferenceDate)
        }
    }
    func testDirectPeerViews() -> [PeerView] {
        queue.sync {
            guard !useHardware else { return [] }
            return peers.values.map {
                PeerView(address: $0.endpoint.address, name: $0.name, status: $0.status, selected: $0.selected)
            }
        }
    }
    func testVerifiedPeerIdentities() -> [String: UUID] {
        queue.sync {
            guard !useHardware else { return [:] }
            return peers.compactMapValues(\.instanceID)
        }
    }

    func testProtocolObservation() -> (malformed: UInt64, rejectedAudio: UInt64, decodedFrames: UInt64, streams: Int, volume: Int, notAllowed: UInt64)? {
        queue.sync {
            guard !useHardware, configuration.isIsolated else { return nil }
            let totals = jam.receiveTotals
            return (totals.malformedPackets, totals.rejectedAudioPayloads, totals.decodedAudioFrames, streams.count, listeningVolume, totals.notAllowedPackets)
        }
    }
    func testProtocolStreamReceipts() -> [(ObjectIdentifier, StreamFormat)] {
        queue.sync {
            guard !useHardware else { return [] }
            return streams.keys.sorted().prefix(128).compactMap { key in
                streams[key].map { (ObjectIdentifier($0),$0.format) }
            }
        }
    }
    func testPeerPacket(_ data: Data, from endpoint: Endpoint) {
        queue.sync {
            guard !useHardware, running, endpoint.address.hasPrefix("127.") else { return }
            receiveWire(data, from: endpoint, now: Date.timeIntervalSinceReferenceDate)
        }
    }
    func testDirectPeerSettings() -> (mixes: [String: PeerMix], aliases: [String: String]) {
        queue.sync { useHardware ? ([:], [:]) : (peerMixes, peerAliases) }
    }
    private func stopInternal() {
        revokeWebAudio()
        resetPushToTalkRuntime()
        directedDiscovery.stop()
        cancelAddingPeerInternal()
        rememberedConnections.resetRuntime()
        directPeerGeneration.cancel()
        directPeerGeneration = DirectPeerMoveToken()
        directPeerSelection.reset()
        lockPeerAddresses = false
        sessionActivity.stop()
        jamStop()
        // Relay teardown may publish the outgoing selection. Keep original
        // saved names until those snapshots have been built, then cancel DNS.
        directPeerResolver.stop()
        if isRecording { finishRecording() }
        equalizers.removeAll()
        timer?.cancel()
        timer = nil
        captureWakeGeneration = UUID()
        audio?.stop()
        audio = nil
        serviceCaptureRetirements()
        inputCaptureActivity.reset()
        systemCaptureActivity.reset()
        inputPacer.reset()
        systemPacer.reset()
        nextAudioHealth = 0
        captureRateMeter = CaptureRateMeter()
        callbackRateMeter = CallbackRateMeter()
        captureDriftDiagnostics = CaptureSourceDriftDiagnostics()
        sentAudioDiagnostics = SentAudioDiagnostics()
        sendWorkDiagnostics = SendWorkDiagnostics()
        maxTickLag = 0
        audioSendFailures = 0
        lastAudioSendFailures = 0
        lastInputDrops = 0
        lastSystemDrops = 0
        inputTrimmedFrames = 0
        systemTrimmedFrames = 0
        lastInputTrimmedFrames = 0
        lastSystemTrimmedFrames = 0
        audioHealthLogged = false
        // Capture is stopped. Drain the two bounded departure retries on this worker before releasing the socket;
        // no callback or old descriptor can send a late goodbye after a new session starts.
        relayRouter?.finishDepartures { Thread.sleep(forTimeInterval: $0) }
        networkBindingGeneration = nil
        wire = nil
        discovery = nil
        bridge = nil
        credentials = nil
        peers.removeAll()
        pendingServerPeerAddresses.removeAll()
        selectedServerMembers.removeAll()
        heartbeatTiming = HeartbeatTiming()
        networkRTT = "not measured"
        nextRTTDisplay = 0
        sendTargets.removeAll()
        networkRouteObserver.invalidate()
        streams.removeAll()
        histories.removeAll()
        streamSeen.removeAll()
        plugins.removeAll()
        hosts.removeAll()
        proofNonces.removeAll()
        opusSenders.removeAll()
        audioFormatSent.removeAll()
        audioSequences.removeAll()
        pcmFrameSequences.removeAll()
        clock = 0
        lastAudioIdentity = ""
        running = false
        _ = namedPeerHistory?.flush()
    }
    private var currentOutputPresentationsMs:[Double?] {
        if !useHardware,configuration.isIsolated,let values=fixtureOutputPresentationsMs { return values }
        return audio?.outputPresentationLatenciesMs ?? []
    }
    private func peerLatencySummary(address:String,rttMs:Double?,outputs:[Double?],heartbeat:HeartbeatTiming.Health?=nil) -> PeerLatencyReport.Summary {
        let inputs=streams.sorted(by:{ $0.key<$1.key }).compactMap { key,stream -> PeerLatencyReport.Input? in
            guard key.hasPrefix(address+"/") else { return nil }
            return .init(stream:String(key.split(separator:"/").last ?? "?"),format:stream.format,queuedFrames:stream.queuedFrames)
        }
        return .init(inputs:inputs,outputs:outputs,rttMs:rttMs,heartbeat:heartbeat)
    }
    private func peerStatus(_ peer: Peer, nowTickMs: UInt64, outputs: [Double?]) -> String {
        guard peer.selected else { return "Not selected" }
        guard running else { return peer.status }
        let health=heartbeatTiming.health(for:peer.endpoint.address,nowTickMs:nowTickMs)
        return peer.status+"; "+peerLatencySummary(address:peer.endpoint.address,
            rttMs:health.currentRTT,outputs:outputs,heartbeat:health).status
    }
    // Controlled read only: the same string publish sends to the existing native peer cell.
    func testHeartbeatPeerStatus(address: String, nowTickMs: UInt64) -> String? {
        queue.sync {
            guard !useHardware, configuration.isIsolated, let peer=peers[address] else { return nil }
            return peerStatus(peer,nowTickMs:nowTickMs,outputs:running ? currentOutputPresentationsMs : [])
        }
    }
    private func publish(_ status: String? = nil) {
        serviceCaptureRetirements()
        let text = status ?? lastStatus
        let nowTickMs=UInt64(ProcessInfo.processInfo.systemUptime*1000)
        let outputs=running ? currentOutputPresentationsMs : []
        if running {
            let now = Date.timeIntervalSinceReferenceDate
            for peer in peers.values where peer.selected && peer.instanceID != nil && peer.lastProof > 0 && (0..<Self.namedHistoryProofFreshness).contains(now - peer.lastProof) {
                namedPeerHistory?.noteConnected(machine: peer.advertisedName, address: peer.endpoint.address)
            }
        }
        let twins = SameMachineTwice.notes(peers.values.map {
            (address: $0.endpoint.address, name: $0.name, onServer: JamWire.isMemberAddress($0.endpoint.address))
        })
        let view = peers.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.map { peer in
            var detail=peerStatus(peer,nowTickMs:nowTickMs,outputs:outputs)
            if let note = twins[peer.endpoint.address] { detail = detail.isEmpty ? note : detail + ", " + note }
            return PeerView(address:peer.endpoint.address,name:peer.name,status:detail,selected:peer.selected)
        }
        rememberedConnections.update(rememberedConnectionRows())
        let rememberedEntries = rememberedConnections.availableEntries
        let networkBinding = currentNetworkBinding
        guard status != nil || view != lastView || networkRTT != lastPublishedNetworkRTT
            || rememberedEntries != lastRememberedPeerEntries
            || pushToTalkKeyGeneration != lastPublishedPushToTalkKeyGeneration
            || networkBinding != lastPublishedNetworkBinding
        else { return }
        lastStatus = text
        lastView = view
        lastRememberedPeerEntries = rememberedEntries
        lastPublishedNetworkRTT = networkRTT
        lastPublishedPushToTalkKeyGeneration = pushToTalkKeyGeneration
        lastPublishedNetworkBinding = networkBinding
        if useHardware, let status { log(status) }
        let snapshot = SessionView(running: running, status: text, peers: view, networkBinding: networkBinding,
            selectedPeerAddresses: directPeerResolver.savedEntries(
                selectedAddresses: Set(view.filter(\.selected).map(\.address))
                    .union(pendingServerPeerAddresses).union(selectedServerMembers.values)),
            rememberedPeerEntries: rememberedEntries,
            sendingInput: sendDevice, receiving: receive, monitoringInApp: monitorInApp,
            allowingPlugins: bridge != nil, inputDeviceUIDs: inputDeviceUIDs,
            inputChannelPairs: inputChannelPairs,
            outputDeviceUID: outputDeviceUID, outputDeviceUIDs: outputDeviceUIDs,
            outputChannelPairs: outputChannelPairs,
            systemCaptureDeviceUIDs: systemCaptureDeviceUIDs,
            systemCaptureChannelPairs: systemCaptureChannelPairs,
            sendCodec: sendCodec, sendPacketSize: sendPacketSize, pushToTalk: pushToTalkSettings, pushToTalkKeyGeneration: pushToTalkKeyGeneration,
            receiveJitterMs: receiveJitterMs, receiveSmoothness: receiveSmoothness, receiveArtifact: receiveArtifact,
            networkRTT: networkRTT,
            recording: isRecording, recordingFinishing: finishingRecordings > 0,
            sendingSystemAudio: sendSystemAudio)
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }
    private func log(_ message: String) {
        guard useHardware, loggingEnabled else { return }
        jam.logFile?.event(message)
        // State transitions and bounded aggregate diagnostics. No audio callback,
        // password, key or packet payload reaches this file.
        let directory = configuration.logsDirectory
        let url = directory.appendingPathComponent("Latest.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                size.intValue > 262144
            {
                try Data().write(to: url, options: .atomic)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(
                contentsOf: Data(
                    "\(ISO8601DateFormatter().string(from:Date())) RemSound \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"): \(message)\n".utf8))
        } catch {}
    }
    private func tick() {
        guard running, let credentials else { return }
        directPeerResolver.tick()
        let now = Date.timeIntervalSinceReferenceDate
        maxTickLag = max(maxTickLag, max(0, now - nextMix))
        if useHardware && now >= nextDeviceCheck {
            nextDeviceCheck = now + 1.5
            let identity = audioIdentity()
            if identity != lastAudioIdentity {
                lastAudioIdentity = identity
                restartChangedAudioDevices()
            }
            // Sending chosen applications: one that has started, or a helper of one that began to make sound, is caught.
            if sendSystemAudio, let group = audio?.systemCapture {
                do {
                    if let line = try group.refreshApplications() {
                        log(line)
                        for setup in group.configurationDiagnostics() { log(setup) }
                    }
                }
                catch { log("System audio: could not capture the chosen applications: \(error.localizedDescription)") }
            }
        }
        // Work per timer is bounded even when unsolicited datagrams flood a socket.
        for _ in 0..<128 {
            guard let (d, ep) = wire?.receive() else { break }
            receiveWire(d, from: ep, now: now)
        }
        for _ in 0..<64 {
            guard let (d, ep) = discovery?.receive() else { break }
            receiveAnnouncement(d, from: ep, now: now)
        }
        for _ in 0..<256 {
            guard let (d, ep) = bridge?.receive() else { break }
            receiveBridge(d, from: ep, now: now)
        }
        jamTick(now: now)
        if now >= nextAnnouncement {
            announceDiscovery(at: now)
            nextAnnouncement = now + Wire.discoveryInterval
        }
        if now >= nextHello {
            reconcileDirectPeerSelections(now: now)
            networkRouteObserver.request(sendTargets, now: now) { [weak self] endpoint, route in
                self?.log("UDP route to \(endpoint.address):\(endpoint.port): \(route). Current route selection, not a historical or per-packet interface measurement.")
            }
            sequence &+= 1
            let proof = try? credentials.tick(
                id: id, now: Int64(Date().timeIntervalSince1970), sequence: sequence)
            let pingTickMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
            if peers.values.contains(where: \.selected) {
                heartbeatTiming.sent(tickMs: pingTickMs, selected: peers.values.filter(\.selected).map { $0.endpoint.address })
            }
            for p in peers.values where p.selected {
                if let proof { peerSend(proof, to: p.endpoint) }
                let ping=HeartbeatPayload.encode(.ping,tickMs:pingTickMs,flags:jamLabFlags)

                peerSend(Wire.packet(.heartbeat, sequence: sequence, payload: ping), to: p.endpoint)
            }
            nextHello = now + HeartbeatTiming.pingInterval
            for (address, p) in peers {
                if !p.selected && now - p.lastSeen > Wire.discoveryExpiry {
                    peers.removeValue(forKey: address)
                    heartbeatTiming.forget(address)
                } else if p.selected && now - p.lastSeen > 8 {
                    peers[address]?.status = "Peer not responding"
                }
            }
            for (key, seen) in streamSeen where now - seen > 2 {
                streams.removeValue(forKey: key)
                streamSeen.removeValue(forKey: key)
            }
            for (hash, p) in plugins where now - p.seen > 3 {
                if let key = WebSessionAudio.PluginKey(instance: hash, endpoint: p.endpoint, visit: p.sourceVisit) { webAudioSource.retirePlugin(key) }
                opusSenders.removeValue(forKey: p.stream)
                audioSequences.removeValue(forKey: p.stream)
                pcmFrameSequences.removeValue(forKey: p.stream)
                pushToTalkLanes.removeValue(forKey: p.stream)
                recordedSend.removeValue(forKey: p.stream)
                plugins.removeValue(forKey: hash)
            }
            hosts = hosts.filter { pid, _ in plugins.values.contains { $0.pid == pid } }
            proofNonces = proofNonces.filter { now - $0.value < 1200 }
            if now >= nextRTTDisplay {
                nextRTTDisplay = now + 5
                let selected = peers.values.filter(\.selected).map { $0.endpoint.address }
                let nowTickMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
                if selected.isEmpty {
                    networkRTT = "select a peer to measure"
                } else if let range = heartbeatTiming.range(selected: selected,
                    nowTickMs: nowTickMs) {
                    networkRTT = range.lowerBound == range.upperBound
                        ? "\(range.lowerBound) milliseconds round trip"
                        : "\(range.lowerBound) to \(range.upperBound) milliseconds round trip across responding peers"
                } else {
                    networkRTT = "waiting for peer response"
                }
            }
            publish()
        }
        if now - nextMix > 2, useHardware {
            restartChangedAudioDevices()
        }
        let mixPeriod = Double(mixFrames) / Double(Wire.sampleRate)
        if now - nextMix > mixPeriod * Double(OutputClock.maximumCatchupBlocks) { nextMix = now }
        var work = 0
        while now >= nextMix && work < OutputClock.maximumCatchupBlocks {
            mix(now: now)
            nextMix += Double(mixFrames) / Double(Wire.sampleRate)
            work += 1
        }
        if !sendDevice { audio?.configureCaptureWake(packetFrames: 0, sending: false, hasDestination: false) }
        let selectedPeerCount = sendTargets.count
        if sendDevice, let audio {
            let fast = jamulusStyleTargets(now: now)
            let packetFrames = fast.isEmpty ? sendPacketFrames : JamulusStyle.frames
            audio.configureCaptureWake(packetFrames: packetFrames, sending: true,
                hasDestination: !sendTargets.isEmpty || webAudioSource.hasDestination)
            let stale = audio.captureMix.trimStale(packetFrames: packetFrames)
            if stale > 0 {
                inputTrimmedFrames += stale
                inputPacer.reset()
            }
            let packets = inputPacer.packetCount(now: now,
                bufferedFrames: audio.captureMix.available, packetFrames: packetFrames,
                pushDriven: audio.usesDirectBuiltInMicrophone,
                sourceCount: audio.captureMix.sources.count)
            for _ in 0..<packets {
                captureDriftDiagnostics.observe(audio.inputCaptureCounters, consumedFrames: packetFrames,
                    now: ProcessInfo.processInfo.systemUptime)
                let reading = captureReading(queuedFrames: audio.captureMix.available)
                let gateStartUs = pushToTalkCaptureTime(queuedFrames: audio.captureMix.available)
                var samples = audio.captureMix.read(packetFrames)
                for message in inputCaptureActivity.observe(samples, source: "Selected input",
                    targets: selectedPeerCount) where useHardware { log(message) }
                prepareSendSamples(&samples, stream: deviceStreamID, lane: .inputCapture, startUs: gateStartUs)
                if fast.isEmpty {
                    sendAudio(samples, stream: deviceStreamID, readingUs: reading)
                } else {
                    sendJamulusStyle(samples, to: fast, readingUs: reading)
                }
            }
            if useHardware, let message = inputCaptureActivity.missingFrames(
                at: now, source: "Selected input") { log(message) }
        }
        if sendSystemAudio, let capture = audio?.systemCapture {
            let stale = capture.samples.trimStale(packetFrames: sendPacketFrames)
            if stale > 0 {
                systemTrimmedFrames += stale
                systemPacer.reset()
            }
            let packets = systemPacer.packetCount(now: now,
                bufferedFrames: capture.samples.available, packetFrames: sendPacketFrames)
            for _ in 0..<packets {
                let reading = captureReading(queuedFrames: capture.samples.available)
                let gateStartUs = pushToTalkCaptureTime(queuedFrames: capture.samples.available)
                var samples = capture.samples.read(sendPacketFrames)
                for message in systemCaptureActivity.observe(samples, source: "Mac system audio",
                    targets: selectedPeerCount) where useHardware { log(message) }
                prepareSendSamples(&samples, stream: systemStreamID, lane: .systemCapture, startUs: gateStartUs)
                sendAudio(samples, stream: systemStreamID, readingUs: reading)
            }
            if useHardware, let message = systemCaptureActivity.missingFrames(
                at: now, source: "Mac system audio") { log(message) }
        }
        if useHardware, now >= nextAudioHealth { reportAudioHealth(now: now) }
        if now >= nextAutoTune {
            nextAutoTune = now + Double(receiveAutoTuneInterval)
            let underruns = streams.values.reduce(0) { $0 + $1.takeUnderruns() }
            let audible = streams.values.filter(\.hasAudio)
            if receiveAutoTune && receive && !receiveLowestDelay {
                let frameMs = audible.map { Int((Double($0.format.frames) * 1000 / Double(Wire.sampleRate)).rounded(.up)) }.max() ?? 5
                let (change, note) = autoTune.tick(currentMs: receiveJitterMs, underruns: underruns,
                    hasAudio: !audible.isEmpty, frameMs: frameMs)
                if let note { log(note) }
                if let change { applyTunedJitter(change) }
            }
        }
    }
    private func announceDiscovery(at now: TimeInterval) {
        guard running, directedDiscoveryEnabled else { return }
        let addresses = peers.values.filter {
            ($0.selected || $0.manualEntry != nil) && !JamWire.isMemberAddress($0.endpoint.address)
        }.map { $0.endpoint.address }.sorted()
        directedDiscovery.update(remembered: rememberedConnections.entries, addresses: addresses, at: now)
        let info = Announcement(id: id, name: name, port: wire?.boundPort ?? audioPort,
            send: sendDevice || sendSystemAudio || plugins.values.contains { !$0.sendSamples.isEmpty }, receive: receive)
        guard let data = try? JSONEncoder().encode(info) else { return }
        if !configuration.isIsolated {
            sendDiscovery(data, to: Endpoint("255.255.255.255", Wire.discoveryPort))
        }
        // The default isolated runtime never reaches this sender. An internal fixture may opt in
        // only to spare loopback destinations, never any normal discovery/audio/bridge port.
        for address in directedDiscovery.targets(at: now) {
            if configuration.isIsolated {
                guard !useHardware, address.hasPrefix("127."), let port = testDiscoveryDestinationPort else { continue }
                sendDiscovery(data, to: Endpoint(address, port))
            } else {
                sendDiscovery(data, to: Endpoint(address, Wire.discoveryPort))
            }
        }
    }
    private func sendDiscovery(_ data: Data, to destination: Endpoint) {
        if let announcementSender { announcementSender(data, destination) }
        else { discovery?.send(data, to: destination) }
    }
    func testAnnounceDiscovery(at now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        queue.sync {
            guard !useHardware else { return }
            announceDiscovery(at: now)
        }
    }
    func testDirectedTargets(at now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> [String] {
        queue.sync { useHardware ? [] : directedDiscovery.targets(at: now) }
    }

    private func reportAudioHealth(now: TimeInterval) {
        nextAudioHealth = now + 10
        let inputDrops = audio?.captureMix.droppedFrames ?? 0
        let systemDrops = audio?.systemCapture?.samples.droppedFrames ?? 0
        let receiveDepthMs = (streams.values.map(\.queuedFrames).max() ?? 0) * 1000
            / Wire.sampleRate
        let playbackDepthMs = (audio?.playbackQueuedFrames ?? 0) * 1000 / Wire.sampleRate
        if !audioHealthLogged || inputDrops > lastInputDrops || systemDrops > lastSystemDrops
            || inputTrimmedFrames > lastInputTrimmedFrames
            || systemTrimmedFrames > lastSystemTrimmedFrames
            || receiveTrimmedFrames > lastReceiveTrimmedFrames
            || audioSendFailures > lastAudioSendFailures || maxTickLag >= 0.03
            || playbackDepthMs > 100 {
            log("Audio health: input dropped \(inputDrops) frames, system dropped \(systemDrops) frames, "
                + "input stale trimmed \(inputTrimmedFrames) frames, system stale trimmed "
                + "\(systemTrimmedFrames) frames, receive stale trimmed \(receiveTrimmedFrames) frames, "
                + "receive queue \(receiveDepthMs) milliseconds, Mac output queue \(playbackDepthMs) milliseconds, "
                + "audio UDP send failures \(audioSendFailures), maximum mixer queue delay "
                + "\(Int(maxTickLag * 1000)) milliseconds, unique destinations \(sendTargets.count)."
                + " Input sources: \(audio?.inputCaptureHealth ?? "none").")
        }
        lastInputDrops = inputDrops
        lastSystemDrops = systemDrops
        lastInputTrimmedFrames = inputTrimmedFrames
        lastSystemTrimmedFrames = systemTrimmedFrames
        lastReceiveTrimmedFrames = receiveTrimmedFrames
        lastAudioSendFailures = audioSendFailures
        maxTickLag = 0
        audioHealthLogged = true
    }
    private func audioIdentity() -> String {
        var parts = [String]()
        if sendDevice {
            parts.append(contentsOf: inputDeviceUIDs.map {
                AudioDeviceCatalog.activeIdentity($0, for: .input)
            })
        }
        if receive && monitorInApp {
            parts.append(contentsOf: outputDeviceUIDs.map {
                AudioDeviceCatalog.activeIdentity($0, for: .output)
            })
        }
        if sendSystemAudio {
            if let systemCaptureDeviceUIDs {
                parts.append(contentsOf: systemCaptureDeviceUIDs.map {
                    AudioDeviceCatalog.activeIdentity($0, for: .output)
                })
            }
        }
        return parts.joined(separator: "|")
    }
    private func restartChangedAudioDevices() {
        revokeWebAudio()
        resetPushToTalkRuntime()
        captureWakeGeneration = UUID()
        audio?.stop()
        let replacement = newDeviceAudio()
        replacement.noteBufferRestoration = { [weak self] in self?.log($0) }
        do {
            try replacement.start(send: sendDevice, receive: receive && monitorInApp,
                systemAudio: sendSystemAudio,
                inputDeviceUIDs: inputDeviceUIDs,
                inputChannelPairs: inputChannelPairs, outputDeviceUIDs: outputDeviceUIDs,
                outputChannelPairs: outputChannelPairs,
                systemCaptureDeviceUIDs: systemCaptureDeviceUIDs,
                systemCaptureChannelPairs: systemCaptureChannelPairs, systemCaptureApplications: self.sendApplications)
            if let reason = replacement.inputCaptureFallback {
                log("Direct input capture unavailable; using audio engine: \(reason)")
            }
            for mode in replacement.inputCaptureModes { log("Input capture started: \(mode).") }
            if jam.bufferFrames > 0 {
                log(replacement.applyBufferFrames(jam.bufferFrames,
                    inputUIDs: inputDeviceUIDs, outputUIDs: outputDeviceUIDs))
            }
            for setup in replacement.configurationDiagnostics() { log(setup) }
            audio = replacement
            inputCaptureActivity.reset()
            systemCaptureActivity.reset()
            inputPacer.reset()
            systemPacer.reset()
            audioHealthLogged = false
            lastAudioIdentity = audioIdentity()
            publish("Audio device changed. Capture and playback restarted.")
        } catch {
            audio = replacement
            publish("Audio device changed. Waiting for a usable route: \(error.localizedDescription)")
        }
    }
    private func reconcileDirectPeerSelections(now: TimeInterval) {
        let discovered = peers.values.compactMap { peer -> DirectPeerSelectionPolicy.Discovery? in
            guard let identity = peer.discoveryInstanceID, let port = peer.discoveryAudioPort else { return nil }
            return .init(instanceID: identity, endpoint: Endpoint(peer.endpoint.address, port),
                         name: peer.advertisedName, seen: peer.discoverySeen)
        }
        for address in peers.keys.sorted() {
            guard let original = peers[address], original.selected,
                  !JamWire.isMemberAddress(address) else { continue }
            let responding = original.lastAnswer.map { now >= $0 && now - $0 <= Wire.discoveryExpiry } ?? false
            guard let result = directPeerSelection.resolve(instanceID: original.selectedDiscoveryID,
                typedEntry: original.manualEntry, pinned: original.endpoint, pinResponds: responding,
                discovered: discovered, locked: lockPeerAddresses, now: now) else { continue }
            let destination = result.endpoint.address
            var peer = peers[destination] ?? original
            let destinationVerified = destination != address && peer.selected && peer.instanceID == result.instanceID
            let changed = original.endpoint != result.endpoint
            rememberedConnections.redirect(address: address, to: RememberedPeerIdentity(
                instanceID: result.instanceID, advertisedName: result.name, address: destination))
            if destination != address {
                peers[address]?.selected = false
                peers[address]?.selectedDiscoveryID = nil
                if peerMixes[destination] == nil { peerMixes[destination] = peerMixes[address] }
                if peerAliases[destination] == nil { peerAliases[destination] = peerAliases[address] }
                directPeerResolver.redirect(address: address, to: destination)
                let generation = directPeerGeneration
                DispatchQueue.main.async { [weak self] in
                    guard generation.isCurrent, let self else { return }
                    self.onDirectPeerMove?(address, destination)
                }
            }
            peer.endpoint = result.endpoint
            peer.selected = true
            peer.selectedDiscoveryID = result.instanceID
            peer.manualEntry = peer.manualEntry ?? original.manualEntry
            peer.advertisedName = result.name
            peer.name = peerDisplayName(machine: result.name, address: destination)
            if changed {
                // Discovery can redirect selection, but only a new authenticated proof verifies this route.
                if !destinationVerified {
                    peer.instanceID = nil
                    peer.lastProof = 0
                    peer.lastAnswer = nil
                    peer.status = "Waiting for them to select you"
                }
                heartbeatTiming.forget(address)
                for key in streams.keys.filter({ $0.hasPrefix(address + "/") }) {
                    streams.removeValue(forKey: key)
                    streamSeen.removeValue(forKey: key)
                }
                histories.removeValue(forKey: address)
                equalizers.removeValue(forKey: address)
            }
            peers[destination] = peer
            updateSendTargets()
        }
    }

    private func receiveAnnouncement(_ d: Data, from ep: Endpoint, now: TimeInterval) {
        guard d.count <= 2048, let a = try? JSONDecoder().decode(Announcement.self, from: d),
            a.InstanceId != id, a.InstanceId != DirectPeerSelectionPolicy.emptyInstanceID, a.AudioPort > 0
        else { return }
        guard peers.count < 64 || peers[ep.address] != nil else { return }
        let trimmed = a.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        let announced = trimmed.isEmpty ? ep.address : String(trimmed.prefix(Wire.maximumDiscoveryNameCharacters))
        if peers[ep.address] == nil {
            peers[ep.address] = Peer(
                endpoint: Endpoint(ep.address, a.AudioPort),
                name: peerDisplayName(machine: announced, address: ep.address), advertisedName: announced,
                onLink: ep.isOnDirectSubnet())
        }
        peers[ep.address]?.advertisedName = announced
        peers[ep.address]?.name = peerDisplayName(machine: announced, address: ep.address)
        peers[ep.address]?.discoveryInstanceID = a.InstanceId
        peers[ep.address]?.discoverySeen = now
        peers[ep.address]?.discoveryAudioPort = a.AudioPort
        directedDiscovery.noteHeard(ep.address, at: now)
        peers[ep.address]?.lastSeen = now
        reconcileDirectPeerSelections(now: now)
        publish()
    }
    private func receiveWire(_ d: Data, from ep: Endpoint, now: TimeInterval) {
        // Windows binds its audio sender to an ephemeral port, separate from its listening port.
        // Selection follows the peer address; stream audio and tick proofs are authenticated below.
        if jamReceive(d, from: ep, now: now) { return }   // the server's own, or a member's packet taken on as theirs
        guard let p = Wire.parse(d) else { jam.receiveTotals.noteMalformed(); return }
        if p.kind == .control {
            receiveControl(p, from: ep, now: now)
            return
        }
        let ownEcho = jam.selfMonitor.enabled && jam.group?.ownMemberAddress.address == ep.address
            && (p.kind == .audio || p.kind == .format)
        guard let credentials else { return }
        guard ownEcho || peers[ep.address]?.selected == true else {
            // Somebody we haven't ticked is sending to us, so they have ticked us: accept connections looks (Windows' rule).
            if !JamWire.isMemberAddress(ep.address) { noteUnselectedSender(p, from: ep, credentials: credentials, now: now) }
            jam.receiveTotals.noteNotAllowed(); return
        }
        switch p.kind {
        case .heartbeat:
            guard let beat=HeartbeatPayload.parse(p.payload) else { jam.receiveTotals.noteMalformed(); return }
            peers[ep.address]?.lastSeen = now
            if beat.flags & 1 != 0 {
                jam.canDecode.note(ep.address, now: now)
            }
            if beat.kind == .ping {
                let pong=HeartbeatPayload.encode(.pong,tickMs:beat.tickMs,flags:jamLabFlags)
                peerSend(
                    Wire.packet(.heartbeat, stream: p.stream, sequence: p.sequence, payload: pong), to: ep)
            } else if heartbeatTiming.receivedPong(from: ep.address,
                echoTickMs: beat.tickMs,
                nowTickMs: UInt64(ProcessInfo.processInfo.systemUptime * 1000)) {
                peers[ep.address]?.lastAnswer = now
                if networkRTT == "waiting for peer response" { nextRTTDisplay = 0 }
            }
        case .format:
            guard let f = StreamFormat.parse(p.payload) else { jam.receiveTotals.noteMalformed(); return }
            if f.labFlags & 1 != 0 { jam.canDecode.note(ep.address, now: now) }
            guard f.fingerprint == credentials.fingerprint else {
                peers[ep.address]?.status = "Different shared password"
                if peers[ep.address]?.selected == true, passwordMismatched.insert(ep.address).inserted {
                    log("security: \(ep.address) is on a different password - not connected")
                    if userTicked.contains(ep.address), let warn = onPasswordMismatch {
                        let address = ep.address
                        DispatchQueue.main.async { warn(address) }
                    }
                }
                publish()
                return
            }
            if passwordMismatched.remove(ep.address) != nil {
                log("security: \(ep.address) is on the same password now - connected")
            }
            let key = ep.address + "/" + String(p.stream)
            guard streams.count < 128 || streams[key] != nil else { return }
            // Presentation metadata can change while an authenticated stream is playing.
            // Preserve the decoder, queued audio and loss history when its audio configuration is unchanged.
            if streams[key]?.updateMetadata(f) != true {
                let decoder = StreamDecoder(f, jitterMs: receiveJitterMs, smoothness: receiveSmoothness, artifact: receiveArtifact)
                autoTune.newStream()   // new conditions: the readings so far were another stream's (Windows)
                let who = peers[ep.address]?.name ?? ep.address
                decoder.onEvent = { [weak self] in self?.log("\(who): \($0)") }
                decoder.receiveTotals = jam.receiveTotals
                streams[key] = decoder
            }
            streamSeen[key] = now
            peers[ep.address]?.lastSeen = now
        case .audio:
            jam.recorder.note(from: "\(ep.address):\(ep.port)", streamId: p.stream, sequence: p.sequence, bytes: d.count,
                now: ProcessInfo.processInfo.systemUptime)
            guard receive else { return }
            let key = ep.address + "/" + String(p.stream)
            guard let stream = streams[key] else { return }
            autoTune.noteArrival(stream: key, now: now)
            let arrivedUs = MetronomeClock.nowUs()
            if stream.accept(p, credentials: credentials), ownEcho {
                jam.selfMonitor.noteEcho(stream: p.stream, sequence: p.sequence, arrivedUs: arrivedUs)
            }
            streamSeen[key] = now
            peers[ep.address]?.lastSeen = now
        case .tickProof:
            guard p.payload.count == TickProofPayload.sealedBytes else { jam.receiveTotals.noteMalformed(); return }
            guard let plain = try? credentials.open(p.payload), let proof=TickProofPayload.parse(plain)
            else { return }
            let stamp = proof.unixSeconds
            guard abs(Double(stamp) - Date().timeIntervalSince1970) <= 600 else { return }
            // One sender can broadcast the same proof on LAN and VPN. Reject replays per
            // address while still learning that both authenticated routes share its UUID.
            let nonce = Data(p.payload.prefix(12)) + Data(ep.address.utf8)
            guard proofNonces[nonce] == nil, proofNonces.count < 4096 else { return }
            proofNonces[nonce] = now

            peers[ep.address]?.instanceID = proof.id
            updateSendTargets()
            peers[ep.address]?.lastAnswer = now
            peers[ep.address]?.lastProof = now
            peers[ep.address]?.lastSeen = now
            peers[ep.address]?.status = "Connected; shared password verified"
            publish()
        case .metronome:
            receiveMetronome(p.payload, from: ep)
        default: break
        }
    }
    /// A peer's volume or mute command (Windows' HandleRemoteControlPacket, the same checks in the same order, logged in
    /// the same words): only from a ticked peer, only with "Accept remote volume commands from peers" on, only sealed with
    /// the shared password, sent within ten minutes of this Mac's clock, and never the same one twice. Never answered.
    private func receiveControl(_ p: Wire.Packet, from ep: Endpoint, now: TimeInterval) {
        let from = "\(ep.address):\(ep.port)"
        guard peers[ep.address]?.selected == true else {
            // Nobody we let in: counted, and said at most once a minute, so a flood costs nothing (Windows' receiver).
            if let count = controlRefused.note(now: now) {
                log("remote-control: ignored \(count) message(s) so far from senders not ticked (latest from \(from)) - said at most once a minute")
            }
            return
        }
        // Not the sealed size: dropped without a word, as Windows' receiver does before the window sees it.
        guard p.payload.count == RemoteControl.sealedBytes else { jam.receiveTotals.noteMalformed(); return }
        guard acceptRemoteCommands else {
            log("remote-control IGNORED (Accept remote volume commands is off) from=\(from)")
            return
        }
        guard let credentials else {
            log("remote-control IGNORED (no profile password set) from=\(from)")
            return
        }
        let sealed = [UInt8](p.payload)
        let plain = sealed.count == RemoteControl.sealedBytes ? (try? credentials.open(p.payload)).map { [UInt8]($0) } : nil
        let verdict = controlGuard.check(sealed: sealed, plain: plain, now: Date().timeIntervalSince1970)
        guard case let .accepted(kind, delta) = verdict else {
            log("remote-control REJECTED (\(verdict.reason)) from=\(from)")
            return
        }
        let name = RemoteControl.name(kind)
        switch kind {
        case .volumeUp, .volumeDown:
            listeningVolume = RemoteControl.nudged(volume: listeningVolume, kind: kind, delta: delta)
            log("remote-control APPLIED kind=\(name) delta=\(delta) new-volume=\(listeningVolume) from=\(from)")
            publishListening()
        case .muteToggle:
            receiveMuted.toggle()
            log("remote-control APPLIED kind=MuteToggle muted=\(receiveMuted ? "True" : "False") from=\(from)")
            publishListening()
        case .systemVolumeUp, .systemVolumeDown, .systemMuteToggle:
            let ok = kind == .systemMuteToggle ? SystemVolume.toggleMute() : SystemVolume.step(up: kind == .systemVolumeUp)
            log("remote-control APPLIED kind=\(name) ok=\(ok ? "True" : "False") state=\(RemoteControl.describeSystem(SystemVolume.state())) from=\(from)")
        }
    }
    private func publishListening() {
        let volume = listeningVolume, muted = receiveMuted
        DispatchQueue.main.async { [weak self] in self?.onListeningChange?(volume, muted) }
    }
    private func resetPushToTalkRuntime() {
        pushToTalkKeyGeneration = UUID()
        pushToTalkGate = PushToTalkAudioGate()
        pushToTalkGate.configure(pushToTalkSettings.gateConfiguration)
        pushToTalkLanes.removeAll()
        // Pending frames belong to the old key/profile/format policy, not the next one.
        jam.ordinaryPending.removeAll()
        for instance in plugins.keys { plugins[instance]?.sendSamples.removeAll() }
    }
    private func pushToTalkCaptureTime(queuedFrames: Int) -> Int64 {
        MetronomeClock.nowUs() - Int64(Double(queuedFrames) * 1_000_000 / Double(Wire.sampleRate))
    }
    private func recordSendSamples(_ samples: [Float], stream: UInt16) {
        guard isRecording, recordingSource != .received else { return }
        let ring = recordedSend[stream] ?? StereoRing(capacity: Wire.sampleRate * 5)
        ring.write(samples)
        recordedSend[stream] = ring
    }
    /// Runs once on each owned capture/bridge block before custom/ordinary fan-out. The in-place buffer
    /// has already been read on this worker; no scratch allocation or work is added to an audio callback.
    private func prepareSendSamples(_ samples: inout [Float], stream: UInt16,
                                    lane: PushToTalkSendLane, startUs: Int64, pluginSource: WebSessionAudio.PluginKey? = nil) {
        let originalRecording = pushToTalkGate.recordsUngated
        if originalRecording { recordSendSamples(samples, stream: stream) }
        // Quotient/remainder avoids multiplying the entire uptime microsecond value by the sample rate.
        let startFrame = (startUs / 1_000_000) * Int64(Wire.sampleRate)
            + (startUs % 1_000_000) * Int64(Wire.sampleRate) / 1_000_000
        var state = pushToTalkLanes[stream] ?? PushToTalkLaneState(lane)
        let endFrame = startFrame + Int64(samples.count / PushToTalkAudioGate.channels)
        samples.withUnsafeMutableBufferPointer { buffer in
            _ = pushToTalkGate.apply(lane: &state, input: UnsafeBufferPointer(buffer),
                                    output: buffer, blockEndFrame: endFrame)
        }
        pushToTalkLanes[stream] = state
        if !originalRecording { recordSendSamples(samples, stream: stream) }
        // Once per original post-PTT worker buffer, before ordinary/custom fan-out or destination guards.
        if let pluginSource {
            _ = webAudioSource.plugin(samples, from: pluginSource, now: Double(MetronomeClock.nowUs()) / 1_000_000)
        } else { _ = webAudioSource.capture(samples, lane: lane) }
    }
    private func sendAudio(_ samples: [Float], stream: UInt16, readingUs: Int64? = nil, to only: [Endpoint]? = nil) {
        let destinations = only ?? sendTargets
        guard let credentials else { return }
        guard !destinations.isEmpty else { return }
        // Announce only a lane that actually has samples for these destinations. In
        // custom-only mode the unused ordinary input lane must stay absent on Windows.
        if stream == deviceStreamID || stream == systemStreamID {
            if audioFormatSent[stream] == nil {
                audioFormatSent = audioFormatSent.filter { $0.key == deviceStreamID || $0.key == systemStreamID }
            }
            let now = Date.timeIntervalSinceReferenceDate
            if audioFormatSent[stream].map({ now - $0 >= 1 }) ?? true {
                let lane: StreamFormat.Lane = stream == deviceStreamID ? .wasapi : .asio
                let format = Wire.packet(.format, stream: stream,
                    payload: sendCodec.format(credentials.fingerprint, packetSize: sendPacketSize)
                        .flagged(jamLabFlags)
                        .capturing(milliseconds: stream == deviceStreamID ? (audio?.inputLatencySeconds ?? 0)*1000 : 0)
                        .encode(lane: lane))
                for endpoint in destinations { peerSend(format, to: endpoint) }
                audioFormatSent[stream] = now
            }
        }
        jam.lastAudioSentAt = Date.timeIntervalSinceReferenceDate
        if sendCodec != .pcm {
            let encoder: OpusSender
            if let existing = opusSenders[stream] { encoder = existing }
            else {
                guard let created = OpusSender(bitrate: sendCodec.bitrate) else { return }
                opusSenders[stream] = created
                encoder = created
            }
            let encodeBegan = sendWorkDiagnostics.begin()
            let encoded = encoder.encode(samples)
            sendWorkDiagnostics.note(.encode, began: encodeBegan)
            guard let encoded, let encrypted = try? credentials.sealAudio(encoded, diagnostics: &sendWorkDiagnostics)
            else { return }
            let opusSequence = nextAudioSequence(for: stream)
            noteCapture(stream: stream, sequence: opusSequence, frames: samples.count / 2, readingUs: readingUs)
            let frameBegan = sendWorkDiagnostics.begin()
            let packet = Wire.packet(.audio, stream: stream,
                sequence: opusSequence, payload: encrypted)
            sendWorkDiagnostics.note(.frame, began: frameBegan)
            var failures = 0
            for endpoint in destinations {
                if !peerSend(packet, to: endpoint) { audioSendFailures += 1; failures += 1 }
            }
            sentAudioDiagnostics.note(stream: stream, frames: samples.count / 2,
                copies: destinations.count, failures: failures, now: ProcessInfo.processInfo.systemUptime)
            return
        }
        let encodeBegan = sendWorkDiagnostics.begin()
        guard let pcm=PCM24.encode(samples) else { return }
        sendWorkDiagnostics.note(.encode, began: encodeBegan)
        guard let encrypted = try? credentials.sealAudio(pcm, diagnostics: &sendWorkDiagnostics) else { return }
        let frameSequence = nextPCMFrameSequence(for: stream)
        let count = (encrypted.count + Wire.maxAudioPayload - 1) / Wire.maxAudioPayload
        guard count <= 255 else { return }
        var capturedUs: Int64?
        for part in 0..<count {
            var payload = Data()
            payload.put(frameSequence)
            payload.append(UInt8(part))
            payload.append(UInt8(count))
            payload.append(
                encrypted[
                    (part * Wire.maxAudioPayload)..<min(encrypted.count, (part + 1) * Wire.maxAudioPayload)])
            let partSequence = nextAudioSequence(for: stream)
            if part == 0 {
                capturedUs = noteCapture(stream: stream, sequence: partSequence, frames: samples.count / 2, readingUs: readingUs)
            } else if let capturedUs {
                // PCM is authenticated only when the final fragment arrives: every fragment names the same capture.
                jam.selfMonitor.noteSent(stream: stream, sequence: partSequence, capturedUs: capturedUs)
            }
            let frameBegan = sendWorkDiagnostics.begin()
            let packet = Wire.packet(.audio, stream: stream,
                sequence: partSequence, payload: payload)
            sendWorkDiagnostics.note(.frame, began: frameBegan)
            var failures = 0
            for endpoint in destinations {
                if !peerSend(packet, to: endpoint) { audioSendFailures += 1; failures += 1 }
            }
            sentAudioDiagnostics.note(stream: stream, frames: part == 0 ? samples.count / 2 : 0,
                copies: destinations.count, failures: failures, now: ProcessInfo.processInfo.systemUptime)
        }
    }
    private func nextPCMFrameSequence(for stream: UInt16) -> UInt32 {
        let next = (pcmFrameSequences[stream] ?? 0) &+ 1
        pcmFrameSequences[stream] = next
        return next
    }
    private func nextAudioSequence(for stream: UInt16) -> UInt32 {
        let next = (audioSequences[stream] ?? 0) &+ 1
        audioSequences[stream] = next
        return next
    }
    private func mix(now: TimeInterval) {
        autoTune.noteMix(now: now)
        var output = [Float](repeating: 0, count: mixFrames * 2)
        var recordedReceived = [Float](repeating: 0, count: mixFrames * 2)
        let bypassRecording = isRecording && recordingBypassShaping
        // The listening volume and receive mute: what is heard, and (as on Windows) what is recorded as received.
        let listeningGain = RemoteControl.listeningGain(volume: listeningVolume, muted: receiveMuted)
        let claimed = Set(plugins.values.filter { now - $0.claimSeen < 0.5 }.flatMap { $0.claims })
        var receivingAddresses = peers.values.filter(\.selected).map { $0.endpoint.address }
        if jam.selfMonitor.enabled, let own = jam.group?.ownMemberAddress.address { receivingAddresses.append(own) }
        for address in receivingAddresses {
            var combined = [Float](repeating: 0, count: mixFrames * 2)
            for (key, stream) in streams where key.hasPrefix(address + "/") {
                let priorTrims = stream.trimmedFrames
                let block = stream.read(mixFrames)
                receiveTrimmedFrames += stream.trimmedFrames - priorTrims
                for i in 0..<mixFrames * 2 { combined[i] += block[i] }
            }
            // The Windows raw tap is before peer DSP and the mixed listening gain. Playback and DAW history keep their shaping.
            if bypassRecording {
                splitPeerFiles[address]?.append(combined.map { max(-1, min(1, $0)) })
                for i in combined.indices { recordedReceived[i] += combined[i] }
            }
            let raw = combined
            let settings = peerMixes[address] ?? PeerMix()
            // Shaped only with the master switch on and the peer's own tick (Windows' ShapingActiveFor): EQ, then volume
            // and pan.
            if allPeerShaping && settings.enabled {
                let equalizer = equalizers[address] ?? PeerEqualizer()
                equalizer.configure(settings.eq)
                combined = equalizer.process(combined)
                equalizers[address] = equalizer
                combined = settings.apply(combined)
            }
            if !bypassRecording {
                splitPeerFiles[address]?.append(combined.map { max(-1, min(1, $0)) })
                for i in combined.indices { recordedReceived[i] += combined[i] * listeningGain }
            }
            let history = histories[address] ?? AudioHistory()
            history.append(pluginShaping ? combined : raw, at: clock)
            histories[address] = history
            if !claimed.contains(address) { for i in 0..<mixFrames * 2 { output[i] += combined[i] } }
        }
        // The click heard in RemSound: made once a block, for the outputs and, when the profile says so, the recording.
        let monitoring = receive && monitorInApp
        let clicks = jam.hearIn == .remSound && (monitoring || (isRecording && jam.clicksRecorded)) ? renderClicks() : nil
        if isRecording {
            var sent = [Float](repeating: 0, count: mixFrames * 2)
            if recordingSource != .received {
                for ring in recordedSend.values {
                    let block = ring.read(mixFrames)
                    for i in 0..<mixFrames * 2 { sent[i] += block[i] }
                }
            }
            var recorded = sent
            if recordingSource != .sent {
                for i in 0..<mixFrames * 2 { recorded[i] += recordedReceived[i] }
            }
            if jam.clicksRecorded, let clicks {
                for i in 0..<min(recorded.count, clicks.count) { recorded[i] += clicks[i] }
                splitPeerFiles[MetronomeDAW.address]?.append(clicks.map { max(-1, min(1, $0)) })
            }
            let clipped = recorded.map { max(-1, min(1, $0)) }
            recordingFile?.append(clipped)
            if recordingSource != .received {
                splitSendFile?.append(sent.map { max(-1, min(1, $0)) })
            }
        }
        if monitoring {
            if listeningGain != 1 { for i in output.indices { output[i] *= listeningGain } }
            if let clicks { for i in 0..<min(output.count, clicks.count) { output[i] += clicks[i] } }
            audio?.writePlayback(output.map { max(-1, min(1, $0)) })
        }
        clock += Int64(mixFrames)
    }
    private func receiveBridge(_ d: Data, from ep: Endpoint, now: TimeInterval) {
        guard ep.address == "127.0.0.1", let p = Bridge.parse(d) else { return }
        if p.kind == .hello {
            guard p.payload.count == 4, plugins.count < 64 || plugins[p.instance] != nil else { return }
            if let old = plugins[p.instance], old.endpoint != ep { return }
            if plugins[p.instance] == nil {
                let stream = freshStreamID()
                plugins[p.instance] = Plugin(
                    endpoint: ep, pid: Int32(bitPattern: p.payload.u32(0)), seen: now, stream: stream)
            }
            plugins[p.instance]?.seen = now
            let list =
                receive
                ? peers.values.filter { $0.selected }.sorted { $0.endpoint.address < $1.endpoint.address }.map
                {
                    "\($0.endpoint.address)\t\($0.name.replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\t",with:" "))"
                }.joined(separator: "\n") + (jam.hearIn == .daw ? "\n\(MetronomeDAW.address)\t\(MetronomeDAW.name)" : "")
                : "#receive-off"
            bridge?.send(Bridge.encode(.peerList, instance: p.instance, payload: Data(list.utf8)), to: ep)
            return
        }
        guard var plugin = plugins[p.instance], plugin.endpoint == ep else { return }
        plugin.seen = now
        switch p.kind {
        case .goodbye:
            if let key = WebSessionAudio.PluginKey(instance: p.instance, endpoint: ep, visit: plugin.sourceVisit) { webAudioSource.retirePlugin(key) }
            opusSenders.removeValue(forKey: plugin.stream)
            audioSequences.removeValue(forKey: plugin.stream)
            pcmFrameSequences.removeValue(forKey: plugin.stream)
            pushToTalkLanes.removeValue(forKey: plugin.stream)
            recordedSend.removeValue(forKey: plugin.stream)
            plugins.removeValue(forKey: p.instance)
            jam.dawClicks.removeValue(forKey: p.instance)
            return
        case .releasePeer:
            if p.peer == Data(repeating: 0, count: 4) {
                plugin.claims = []
            } else {
                plugin.claims.removeAll { Endpoint($0).bytes == p.peer }
            }
        case .hostCallback:
            plugin.hostCallback.observe(p.payload, now: now)
        case .trackAudio:
            guard !p.payload.isEmpty, p.payload.count % 8 == 0 else { return }
            if !p.payload.isEmpty { plugin.lastAudioAt = now }
            for i in stride(from: 0, to: p.payload.count, by: 4) {
                let value = Float(bitPattern: p.payload.u32(i))
                plugin.sendSamples.append(value.isFinite ? value : 0)
            }
            // The host's fresh nominal block is a known capture component, not its
            // hardware/scheduling delay. A split bridge datagram cannot stand in for it.
            let captureMs=plugin.hostCallback.geometry(now:now)?.nominalBlockDurationMs ?? 0
            if let credentials, now - plugin.formatSent >= 1 || plugin.formatCaptureMs != captureMs {
                let format = Wire.packet(
                    .format, stream: plugin.stream,
                    payload: sendCodec.format(credentials.fingerprint, packetSize: sendPacketSize)
                        .capturing(milliseconds:captureMs).encode())
                for endpoint in sendTargets { peerSend(format, to: endpoint) }
                plugin.formatSent = now
                plugin.formatCaptureMs = captureMs
            }
            while plugin.sendSamples.count >= sendPacketFrames * 2 {
                // The bridge has no host capture timestamp: this times the first frame's arrival at the app.
                let readingUs = MetronomeClock.nowUs() - Int64(Double(plugin.sendSamples.count / 2) * 1_000_000 / 48_000)
                var samples = Array(plugin.sendSamples.prefix(sendPacketFrames * 2))
                let browserSource = plugin.webSkipSamples == 0
                    ? WebSessionAudio.PluginKey(instance: p.instance, endpoint: ep, visit: plugin.sourceVisit) : nil
                plugin.webSkipSamples = max(0, plugin.webSkipSamples - samples.count)
                prepareSendSamples(&samples, stream: plugin.stream, lane: .plugin, startUs: readingUs, pluginSource: browserSource)
                sendAudio(samples, stream: plugin.stream, readingUs: readingUs)
                plugin.sendSamples.removeFirst(sendPacketFrames * 2)
            }
        case .claimPeers:
            guard let claim = Bridge.claim(p.payload) else { return }
            let names = claim.peers.map { $0.map { String($0) }.joined(separator: ".") }
            plugin.claims = receive ? Array(Set(names.filter {
                peers[$0]?.selected == true || ($0 == MetronomeDAW.address && jam.hearIn == .daw)
            })) : []
            plugin.claimSeen = now
            var host = hosts[plugin.pid] ?? HostRound(cursor: max(0, clock - 480), frames: claim.frames)
            let newRound = host.served.contains(p.instance) || host.keeper.round == nil
            if host.served.contains(p.instance) {
                host.round += 1
                host.cursor += Int64(host.frames)
                host.frames = claim.frames
                host.served = []
            }
            if host.cursor < clock - 4800 || host.cursor > clock { host.cursor = max(0, clock - 480) }
            host.served.insert(p.instance)
            var block = [Float](repeating: 0, count: claim.frames * 2)
            if ClockKeeping.on {
                // The DAW's clock against the mix's: each round read from where the keeper says, every peer's block made
                // at the same ratio (see HostTimeKeeper). Off, the read position moves on by what was asked, as before.
                if newRound { host.keeper.startRound(frames: claim.frames, clock: clock, now: ProcessInfo.processInfo.systemUptime) }
                if let round = host.keeper.round {
                    for address in plugin.claims {
                        guard let history = histories[address] else { continue }
                        let samples = host.keeper.block(peer: address,
                            history: history.read(at: round.from - 2, frames: round.count + 2))
                        for i in 0..<min(block.count, samples.count) { block[i] += samples[i] }
                    }
                }
            } else {
                for address in plugin.claims {
                    if let history = histories[address] {
                        let samples = history.read(at: host.cursor, frames: claim.frames)
                        for i in block.indices { block[i] += samples[i] }
                    }
                }
            }
            hosts[plugin.pid] = host
            if plugin.claims.contains(MetronomeDAW.address) { addDawClicks(&block, instance: p.instance) }
            else { jam.dawClicks.removeValue(forKey: p.instance) }
            let partFloats = (Bridge.maxAudioBytes - Bridge.roundHeaderSize) / 8 * 2
            for start in stride(from: 0, to: block.count, by: partFloats) {
                var payload = Data()
                payload.put(host.round)
                payload.put(claim.ask)
                payload.put(Int32(start))
                payload.put(Int32(block.count))
                for sample in block[start..<min(block.count, start + partFloats)] {
                    payload.put(sample.bitPattern)
                }
                bridge?.send(Bridge.encode(.peerAudioRound, instance: p.instance, payload: payload), to: ep)
            }
        default: break
        }
        plugins[p.instance] = plugin
    }
}

// MARK: - Playing together through a server (2026-09-29)
//
// The server connection (a RemSound relay) and the metronome, joined to this session. The protocol is the RemSoundJam
// package's (App/Packages/RemSoundJam), the same as the Windows RemSound's and tested against the real relay; this is the
// part that needs the Mac: the socket, Core Audio's delays, the peer list and the output mix.
//
// On a server, each person there is a peer of their own, at an address in 240.0.0.0/5 the server connection gives them,
// named "… (on the server)", only while connected. Ticking them ticks them on the server; everything sent to them goes to the
// server, group-framed, once for everyone there. The metronome's own messages are sealed with the password like the audio.

extension Session {
    /// Go to a server: "host" or "host:port" (47830 when not said). Looked up off the network queue - a name that cannot be
    /// found would hold everything up. Needs RemSound running.
    public func connectServer(_ typed: String) { connectServer(typed, userAsked: true) }

    /// `userAsked` false: the profile's own server, at start or found at last - kept and tried again if not found.
    func connectServer(_ typed: String, userAsked: Bool) {
        let entry = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        queue.async { [self] in
            if userAsked { jam.serverWatch.userChose() }
            jam.serverUserAsked = userAsked
            log("Server: connection requested for \(entry)\(userAsked ? "" : " (the profile's)"); session \(running ? "running" : "stopped").")
            guard running else {
                jam.serverStatus = "Start RemSound first, then connect to the server."
                publishJam()
                return
            }
            serverAddressResolver.stop()
            if jam.group != nil { leaveServer() } else { retireServerVersionCheck() }
            let requestID = UUID()
            jam.serverRequestID = requestID
            jam.serverEntry = entry
            jam.serverStatus = "Connecting to \(entry)…"
            publishJam()
            let (host, port) = Self.splitServerEntry(entry)
            serverAddressResolver.start(host, port: port) { [weak self] endpoint in
                self?.checkBeforeConnectingServer(entry, endpoint, requestID: requestID)
            }
        }
    }

    public func disconnectServer() {
        queue.async { [self] in
            jam.serverWatch.userChose()
            leaveServer()
            publishJam()
            publish("Disconnected from the server.")
        }
    }

    /// Start or stop your own metronome (leading, the server's too); following, mute or unmute the clicks.
    public func metronomeStartStop() {
        queue.async { [self] in
            jam.metronome.startStop()
            publishJam()
        }
    }

    /// Be the master metronome - which needs a server - or stop being it.
    public func setMetronomeMaster(_ on: Bool) {
        queue.async { [self] in
            if on {
                if !jam.metronome.becomeMaster(name: name) {
                    noticeOnMain("Being the master metronome needs a server. Connect to one from the Server menu first.")
                }
            } else {
                jam.metronome.releaseMaster()
            }
            publishJam()
        }
    }

    public func setMetronomeTempo(_ bpm: Int) {
        queue.async { [self] in
            var s = jam.metronome.settings
            s.bpm = bpm
            jam.metronome.configure(s)
            publishJam()
        }
    }

    public func setMetronomeWhenAsked(_ answer: ServerMetronome.WhenAsked) {
        queue.async { [self] in
            var s = jam.metronome.settings
            s.whenAsked = answer
            jam.metronome.configure(s)
            publishJam()
        }
    }

    static func splitServerEntry(_ entry: String) -> (String, UInt16) {
        let parts = entry.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        return (entry, Wire.audioPort)
    }

    private func checkBeforeConnectingServer(_ entry: String, _ resolved: Endpoint?, requestID: UUID) {
        guard running, jam.serverRequestID == requestID, jam.serverEntry == entry else { return }
        guard let resolved else { finishConnectingServer(entry, nil, requestID: requestID); return }
        let request = ServerVersionConnectionRequest(id: requestID, entry: entry, endpoint: resolved,
            began: ProcessInfo.processInfo.systemUptime)
        serverVersionRequest = request
        jam.serverStatus = "Checking \(entry)…"
        log("Server version: checking \(entry) (\(resolved.address):\(resolved.port)) before connecting.")
        publishJam()
        if let fetchServerRelease {
            request.releaseCancellation = fetchServerRelease { [weak self, weak request] tag in
                self?.queue.async { [weak self, weak request] in
                    guard let self, let request, self.serverVersionRequest === request, !request.releaseDone else { return }
                    request.latestReleased = ServerVersionCheck.isPlainReleaseTag(tag) ? tag : nil
                    request.releaseDone = true
                    request.releaseCancellation = nil
                    self.checkServerVersion()
                }
            }
        } else { request.releaseDone = true }
        let complete: (ServerVersionProbe.Result) -> Void = { [weak self, weak request] result in
            self?.queue.async { [weak self, weak request] in
                guard let self, let request, self.serverVersionRequest === request, request.probe == nil,
                      !result.cancelled else { return }
                self.serverProbeCancellation = nil
                self.serverVersionOperation = nil
                request.probe = result
                request.probeFinishedAt = ProcessInfo.processInfo.systemUptime
                self.checkServerVersion()
            }
        }
        if let injectedServerProbe { serverProbeCancellation = injectedServerProbe(resolved, complete) }
        else {
            serverVersionOperation = ServerVersionOperation(endpoint: resolved,
                permitted: !configuration.isIsolated, clock: { ProcessInfo.processInfo.systemUptime }, completion: complete)
            serverVersionOperation?.tick()
        }
    }

    private func checkServerVersion() {
        guard let request = serverVersionRequest, running, jam.serverRequestID == request.id,
              !request.judged, !request.deciding else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if request.awaitingLate {
            guard let group = jam.group, let relay = group.connectedRelay, relay == JamEndpoint(request.endpoint),
                  group.isInGroup(relay) else { return }
            if group.latestServerInfo == nil {
                guard let since = group.inGroupSince else { return }
                let waited = Date.timeIntervalSinceReferenceDate - since
                if waited < ServerStatus.olderAfter { return }
                if group.serverRoundTripMs != nil, waited < ServerVersionConnectionRequest.pingingStatusWait { return }
            }
            if !request.releaseDone, now - request.began < ServerVersionConnectionRequest.releaseWaitForLateCheck { return }
            request.awaitingLate = false
            judgeServerVersion(request, version: group.latestServerInfo?.version, beforeConnecting: false)
            return
        }
        guard let probe = request.probe, let finishedAt = request.probeFinishedAt else { return }
        if !request.releaseDone, now - finishedAt < ServerVersionConnectionRequest.releaseWaitAfterProbe { return }
        if !probe.answered || probe.full {
            log("Server version: \(request.entry) \(probe.full ? "is full" : "did not answer the check"); connecting as usual, version still to judge.")
            request.awaitingLate = true
            finishConnectingServer(request.entry, request.endpoint, requestID: request.id)
            return
        }
        serverVersionKnownOlder = probe.version == nil
        judgeServerVersion(request, version: probe.version, beforeConnecting: true)
    }

    private func judgeServerVersion(_ request: ServerVersionConnectionRequest, version: String?, beforeConnecting: Bool) {
        request.deciding = true
        let old = ServerVersionCheck.isOutOfDate(version, latestReleased: request.latestReleased)
        let newest = ServerVersionCheck.newest(request.latestReleased)
        log("Server version: \(request.entry) says \(version ?? "no version (older than server-v2.16)"); newest \(newest) - \(old ? "OUT OF DATE" : "up to date") [send input \(sendDevice ? "on" : "off"), send system \(sendSystemAudio ? "on" : "off"), receive \(receive ? "on" : "off")].")
        guard old else { finishServerVersionDecision(request, accept: true, beforeConnecting: beforeConnecting); return }
        guard testServerVersionWarnings || (!configuration.silent && !configuration.isHeadless && !configuration.isIsolated) else {
            log("Server version: warning not shown; nobody to answer, \(beforeConnecting ? "connecting" : "staying on the server").")
            finishServerVersionDecision(request, accept: true, beforeConnecting: beforeConnecting)
            return
        }
        guard let handler = onServerVersionWarning else {
            log("Server version: required warning handler unavailable; refusing the out-of-date server.")
            finishServerVersionDecision(request, accept: false, beforeConnecting: beforeConnecting)
            return
        }
        let token = ServerVersionAnswerToken()
        request.answerToken = token
        let warning = ServerVersionWarning(requestID: request.id, server: request.entry, version: version,
            latestReleased: request.latestReleased, beforeConnecting: beforeConnecting, isCurrent: { token.isCurrent })
        DispatchQueue.main.async { [weak self, weak request] in
            guard token.isCurrent else { return }
            handler(warning) { [weak self, weak request] accept in
                self?.queue.async { [weak self, weak request] in
                    guard let self, let request, token.isCurrent, self.serverVersionRequest === request else { return }
                    self.log("Server version: \(accept ? "Connect anyway" : "Cancel") - \(beforeConnecting ? "before connecting" : "after joining").")
                    self.finishServerVersionDecision(request, accept: accept, beforeConnecting: beforeConnecting)
                }
            }
        }
    }

    private func finishServerVersionDecision(_ request: ServerVersionConnectionRequest, accept: Bool, beforeConnecting: Bool) {
        guard serverVersionRequest === request, jam.serverRequestID == request.id, running, !request.judged else { return }
        request.answerToken?.retire()
        request.answerToken = nil
        request.judged = true
        if accept {
            if beforeConnecting { finishConnectingServer(request.entry, request.endpoint, requestID: request.id) }
        } else if beforeConnecting {
            jam.serverStatus = "Not connected: \(request.entry) is out of date."
            publishJam()
        } else { leaveServer(); publishJam() }
    }

    private func retireServerVersionCheck() {
        serverVersionRequest?.answerToken?.retire()
        serverVersionRequest?.releaseCancellation?()
        serverVersionRequest = nil
        serverProbeCancellation?(); serverProbeCancellation = nil
        serverVersionOperation?.cancel(); serverVersionOperation = nil
        serverVersionKnownOlder = false
    }

    private func finishConnectingServer(_ entry: String, _ resolved: Endpoint?, requestID: UUID) {
        guard running, jam.serverRequestID == requestID, jam.serverEntry == entry else { return }
        guard let resolved else {
            jam.serverStatus = "Couldn't find \(entry)."
            jam.serverEntry = ""
            for line in jam.serverWatch.notFound(entry, userAsked: jam.serverUserAsked, now: Date.timeIntervalSinceReferenceDate) {
                log("Server: \(line).")
            }
            if jam.serverWatch.pending != nil { watchNetworkForServerName() }
            publishJam()
            return
        }
        for line in jam.serverWatch.found(entry) { log("Server: \(line).") }
        if !ServerNameWatch.isAddress(entry) { watchNetworkForServerName() }
        let group = relayRouter ?? RelayGroupClient(clientId: useHardware ? configuration.serverClientID : UUID())
        group.send = { [weak self] bytes, to in
            guard let self else { return }
            let payload = Data(bytes), endpoint = Endpoint(to)
            let audio = payload.count >= Wire.headerSize && payload[5] == Wire.Kind.audio.rawValue
            let began = audio ? self.sendWorkDiagnostics.begin() : 0
            self.wire?.send(payload, to: endpoint)
            self.sendWorkDiagnostics.note(.udp, began: began)
        }
        group.log = { [weak self] in self?.log("Server: \($0)") }
        group.changed = { [weak self] in self?.serverMembersChanged() }
        group.timingReceived = { [weak self] body, _ in
            if let grid = ServerMetronomeWire.readGrid(body) { self?.jam.metronome.onGrid(grid) }
        }
        if let credentials { group.setIdentity(name: name, fingerprint: [UInt8](credentials.fingerprint)) }
        relayRouter = group
        jam.group = group
        knownServerAddresses.insert(resolved.address)
        rememberedConnections.noteServer(entry: entry, address: resolved.address)
        group.connect(JamEndpoint(resolved))
        group.tick(now: Date.timeIntervalSinceReferenceDate)
        jam.connectedSince = Date.timeIntervalSinceReferenceDate
        jam.serverStatus = "Join request sent to \(entry); waiting for the server to answer."
        log("Server: connected to \(entry) (\(resolved.address):\(resolved.port)).")
        publishJam()
    }

    fileprivate func leaveServer() {
        retireServerVersionCheck()
        serverAddressResolver.stop()
        serverRecheckResolver.stop()
        jam.serverWatch.recheckAbandoned()
        stopSelfMonitoring("Self-monitoring off: left or changed server.")
        jam.serverRequestID = UUID()
        jam.group?.tick(now: Date.timeIntervalSinceReferenceDate)
        jam.group?.disconnect()
        jam.group = nil
        serverMembersChanged()
        jam.serverEntry = ""
        jam.serverStatus = "Not connected to a server."
        jam.connectedSince = nil
        log("Server: disconnected.")
    }

    /// The server's people as peers, only while connected: each at their own address, "… (on the server)". Our ticks go to
    /// the server in every hello, and sound for them goes to the server once.
    fileprivate func serverMembersChanged() {
        let members = jam.group?.members ?? []
        let now = Date.timeIntervalSinceReferenceDate
        let present = Set(members.map(\.address.address))
        for address in present { goneServerMembers.removeValue(forKey: address) }
        for address in peers.keys.filter({ JamWire.isMemberAddress($0) && !present.contains($0) }) {
            // Off the server's list but not ticked: "(gone)" for a while, as Windows' server list keeps them, unless we
            // have left the server ourselves.
            if jam.group != nil, peers[address]?.selected != true {
                if goneServerMembers[address] == nil {
                    goneServerMembers[address] = now
                    if let name = peers[address]?.name, !name.hasSuffix(" (gone)") { peers[address]?.name = name + " (gone)" }
                }
                if now - (goneServerMembers[address] ?? now) < Self.serverGoneGrace { continue }
            }
            goneServerMembers.removeValue(forKey: address)
            peers.removeValue(forKey: address)
            heartbeatTiming.forget(address)
            for key in streams.keys.filter({ $0.hasPrefix(address + "/") }) {
                streams.removeValue(forKey: key)
                streamSeen.removeValue(forKey: key)
            }
        }
        for m in members {
            let label = "\(m.name.isEmpty ? "Someone" : m.name) (on the server)"
            let address = m.address.address
            if peers[address] == nil {
                peers[address] = Peer(endpoint: Endpoint(m.address), name: peerDisplayName(machine: label, address: address),
                                      advertisedName: label, lastSeen: now)
            }
            let savedSelection = pendingServerPeerAddresses.remove(address) != nil
            let selected = savedSelection || selectedServerMembers[m.id] != nil
            if selected { selectedServerMembers[m.id] = address }
            peers[address]?.selected = selected
            peers[address]?.advertisedName = label
            peers[address]?.name = peerDisplayName(machine: label, address: address)
            peers[address]?.lastSeen = now
            if peers[address]?.selected == true && !m.ticksUs { peers[address]?.status = "Waiting for them to tick you on the server" }
            if peers[address]?.selected != true && m.ticksUs { considerServerMember(id: m.id, address: address, name: label) }
        }
        syncServerTicks()
        updateSendTargets()
        if let group = jam.group, let relay = group.connectedRelay, group.isInGroup(relay) {
            jam.serverStatus = "On \(jam.serverEntry) with \(members.count) other\(members.count == 1 ? "" : "s")."
        }
        publishJam()
        publish()
    }

    fileprivate func syncServerTicks() {
        guard let group = jam.group else { return }
        group.setTicked(Set(selectedServerMembers.keys))
    }

    /// Every turn of the loop: the server connection's clock and the metronome's; once a second, the capture report, the
    /// server's people kept fresh in the list, and a server that never answers said so.
    fileprivate func jamTick(now: TimeInterval) {
        serverVersionOperation?.tick()
        checkServerVersion()
        if jam.selfMonitor.expired(nowUs: MetronomeClock.nowUs()) {
            stopSelfMonitoring("Self-monitoring off: no audio came back for five seconds. Check sending and that the server supports round-trip testing.")
        }
        if jam.selfMonitor.enabled, now >= jam.nextSelfMeasurement {
            jam.nextSelfMeasurement = now + 1
            measureSelfMonitoring()
        }
        jam.metronome.tick()
        if now >= jam.nextRecorderSecond {
            jam.nextRecorderSecond = now + 1
            let t = jam.receiveTotals
            jam.recorder.noteSecond(.init(at: ProcessInfo.processInfo.systemUptime, audibleGaps: t.audibleGaps,
                lateOrDoubledDropped: t.lateOrDoubledDropped, concealed: t.concealed, gapsNotRepaired: t.gapsNotRepaired))
        }
        if now >= jam.nextLogSecond {
            jam.nextLogSecond = now + 1
            logSecond(now: now)
        }
        relayRouter?.tick(now: now)
        if now >= jam.nextNameCheck {
            jam.nextNameCheck = now + 1
            checkServerName(now: now)
            notePeerHealth()
            autoTuneSecond(now: now)
            if goneServerMembers.values.contains(where: { Date.timeIntervalSinceReferenceDate - $0 >= Self.serverGoneGrace }) {
                serverMembersChanged()
            }
        }
        guard let group = jam.group else { return }
        guard now >= jam.nextReport else { return }
        jam.nextReport = now + 1
        publishJam()
        for m in group.members { peers[m.address.address]?.lastSeen = now }
        let taken = jam.reports.take()
        if jam.onServer, !taken.isEmpty { group.sendTiming(ServerMetronomeWire.buildReport(taken)) }
        if let relay = group.connectedRelay, !group.isInGroup(relay), let since = jam.connectedSince, now - since > 10 {
            let text = "\(jam.serverEntry) isn't answering. Check the address, and that the server is running."
            if jam.serverStatus != text {
                jam.serverStatus = text
                publishJam()
            }
        }
    }

    /// Once a second: the profile's server tried again while its name can't be found, and the server we are on looked up
    /// again when it has gone quiet 30 seconds or the network changed - followed if its name now says somewhere else.
    /// A retry is quiet until the name is found: the status line is spoken, and "Connecting" every 30 seconds would not be.
    fileprivate func checkServerName(now: TimeInterval) {
        let networkChanged = jam.serverNetworkChanged
        jam.serverNetworkChanged = false
        let busy = jam.group != nil || !jam.serverEntry.isEmpty || serverVersionRequest != nil
        if let entry = jam.serverWatch.retryDue(now: now, networkChanged: networkChanged, connected: busy) {
            let (host, port) = Self.splitServerEntry(entry)
            serverAddressResolver.start(host, port: port) { [weak self] endpoint in
                guard let self, self.running, self.jam.serverWatch.pending == entry, self.jam.group == nil,
                      self.jam.serverEntry.isEmpty else { return }
                if endpoint == nil {
                    _ = self.jam.serverWatch.notFound(entry, userAsked: false, now: Date.timeIntervalSinceReferenceDate)
                } else {
                    self.connectServer(entry, userAsked: false)
                }
            }
        }
        guard let group = jam.group, let relay = group.connectedRelay else { return }
        jam.serverWatch.noteAnswering(group.isInGroup(relay), now: now)
        let entry = jam.serverEntry, current = relay.address
        guard jam.serverWatch.recheckDue(entry: entry, connected: true, now: now, networkChanged: networkChanged) else { return }
        let (host, port) = Self.splitServerEntry(entry)
        serverRecheckResolver.start(host, port: port) { [weak self] endpoint in
            guard let self else { return }
            guard let still = self.jam.group?.connectedRelay, still.address == current, self.jam.serverEntry == entry else {
                self.jam.serverWatch.recheckAbandoned()
                return
            }
            guard let line = self.jam.serverWatch.recheckFinished(entry: entry, current: current, found: endpoint?.address),
                  let endpoint else { return }
            self.log("Server: \(line).")
            self.followMovedServer(entry, to: endpoint)
        }
    }

    /// Once a second: the auto-tune's readings close, and the lowest-delay tune takes its turn.
    fileprivate func autoTuneSecond(now: TimeInterval) {
        for stream in streams.values where stream.hasAudio {
            autoTune.noteBuffer(ms: Double(stream.queuedFrames) * 1000 / Double(Wire.sampleRate))
        }
        autoTune.endSecond()
        let on = receiveAutoTune && receiveLowestDelay && receive && streams.values.contains(where: \.hasAudio)
        let floor = Int((Double(mixFrames) * 1000 / Double(Wire.sampleRate)).rounded(.up))
        if let change = autoTune.lowestDelaySecond(audibleGapsTotal: jam.receiveTotals.audibleGaps, currentMs: receiveJitterMs,
                                                   floorMs: floor, on: on, now: now) {
            applyTunedJitter(change)
        }
    }

    /// An auto-tune's new buffer, for every stream, said in the status line and the log.
    fileprivate func applyTunedJitter(_ change: ReceiveAutoTune.Change) {
        receiveJitterMs = change.targetMs
        for stream in streams.values { stream.setJitterMs(change.targetMs) }
        log(change.log)
        publish("Receive auto-tune set the jitter buffer to \(change.targetMs) milliseconds.")
    }

    /// Once a second: which peers' links are healthy, and since when (the details box's "Connected for").
    fileprivate func notePeerHealth() {
        let nowTickMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000), now = ProcessInfo.processInfo.systemUptime
        for (address, peer) in peers {
            let healthy = peer.selected && heartbeatTiming.health(for: address, nowTickMs: nowTickMs).state == .healthy
            if healthy { if peerHealthySince[address] == nil { peerHealthySince[address] = now } }
            else { peerHealthySince.removeValue(forKey: address) }
        }
        for address in peerHealthySince.keys where peers[address] == nil { peerHealthySince.removeValue(forKey: address) }
        let anyConnected = peerHealthySince.keys.contains { !passwordMismatched.contains($0) }
        if anyConnected { if statusConnectedSince == nil { statusConnectedSince = now } } else { statusConnectedSince = nil }
    }

    /// The Connection status box's text (Windows' status readout), handed back on the main queue.
    public func connectionStatus(reply: @escaping (String) -> Void) {
        queue.async { [self] in
            let nowTickMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000), now = ProcessInfo.processInfo.systemUptime
            let outputs = running ? currentOutputPresentationsMs : []
            var connected: [(name: String, link: String)] = [], different: [String] = []
            for peer in peers.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
                where peer.selected {
                let address = peer.endpoint.address
                if passwordMismatched.contains(address) { different.append(peer.name); continue }
                let health = heartbeatTiming.health(for: address, nowTickMs: nowTickMs)
                guard health.state == .healthy else { continue }
                connected.append((peer.name, peerLatencySummary(address: address, rttMs: health.currentRTT, outputs: outputs,
                    heartbeat: health).status))
            }
            let m = jam.metronome
            let extras = m.playing || m.role != .solo ? ["Metronome: \(m.describe())"] : []
            let rx = wire?.bytesReceived ?? 0, tx = wire?.bytesSent ?? 0
            let process = OwnProcessMetrics.read().snapshot
            let cpu = process.cpuSeconds ?? 0
            var rxKBs = 0.0, txKBs = 0.0, cpuPercent = 0.0
            if let last = lastStatusSample, now - last.at >= 0.25 {
                let elapsed = now - last.at
                rxKBs = Double(max(0, rx - last.rx)) / 1024 / elapsed
                txKBs = Double(max(0, tx - last.tx)) / 1024 / elapsed
                cpuPercent = ConnectionStatusText.cpuPercent(cpuSecondsDelta: cpu - last.cpu, elapsed: elapsed,
                    cores: ProcessInfo.processInfo.activeProcessorCount)
            }
            if lastStatusSample == nil || now - (lastStatusSample?.at ?? 0) >= 0.25 { lastStatusSample = (now, rx, tx, cpu) }
            let text = ConnectionStatusText.text(.init(connected: connected, differentPassword: different,
                uptime: statusConnectedSince.map { now - $0 }, extras: extras, receivingKBs: rxKBs, sendingKBs: txKBs,
                receivedBytes: rx, sentBytes: tx, cpuPercent: cpuPercent, memoryBytes: Int64(process.residentBytes ?? 0)))
            DispatchQueue.main.async { reply(text) }
        }
    }

    /// Every path in from a ticked peer, for the Total latency box, and whether any sound is arriving; on the main queue.
    public func latencyJourneys(reply: @escaping ([TotalLatencyText.Journey], Bool) -> Void) {
        queue.async { [self] in
            let nowTickMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
            let outputs = running ? currentOutputPresentationsMs : []
            var journeys: [TotalLatencyText.Journey] = []
            for peer in peers.values where peer.selected {
                let address = peer.endpoint.address
                let health = heartbeatTiming.health(for: address, nowTickMs: nowTickMs)
                let summary = peerLatencySummary(address: address, rttMs: health.currentRTT, outputs: outputs, heartbeat: health)
                journeys += summary.journeys.map { .init(bufferMs: $0.report.queuedMs, totalMs: $0.report.totalMs) }
            }
            let receiving = running && receive && !journeys.isEmpty
            DispatchQueue.main.async { reply(journeys, receiving) }
        }
    }

    /// The peer details box's text for one peer (Windows BuildPeerDetailsText), handed back on the main queue.
    public func peerDetails(address: String, reply: @escaping (String) -> Void) {
        queue.async { [self] in
            guard let peer = peers[address] else {
                DispatchQueue.main.async { reply(PeerDetailsText.nothingHighlighted) }
                return
            }
            let health = heartbeatTiming.health(for: address, nowTickMs: UInt64(ProcessInfo.processInfo.systemUptime * 1000))
            let fromThem = streams.filter { $0.key.hasPrefix(address + "/") }.map { entry -> (lane: String?, codec: String) in
                let f = entry.value.format
                let lane: String? = f.lane == .asio ? "ASIO" : f.lane == .wasapi ? "WASAPI" : nil
                let codec = f.codec == StreamFormat.Codec.pcm.rawValue ? "PCM"
                    : f.codec == StreamFormat.Codec.opusCustom.rawValue ? "Jamulus-style Opus" : "Opus"
                return (lane, codec)
            }
            let facts = PeerDetailsText.Facts(displayName: peer.name, machineName: peer.advertisedName, address: address,
                connectedFor: peerHealthySince[address].map { ProcessInfo.processInfo.systemUptime - $0 },
                healthy: peer.selected && health.state == .healthy, pingMs: health.milliseconds, streams: fromThem,
                receiving: receive, receivingYourAudio: (sendDevice || sendSystemAudio) && sendTargets.contains(peer.endpoint))
            let text = PeerDetailsText.text(facts)
            DispatchQueue.main.async { reply(text) }
        }
    }

    /// The server's name now says somewhere else: leave the old address and join the new one, as connecting does. The
    /// people ticked there are ticked again when they appear.
    private func followMovedServer(_ entry: String, to endpoint: Endpoint) {
        let userAsked = jam.serverUserAsked
        leaveServer()
        let requestID = UUID()
        jam.serverRequestID = requestID
        jam.serverEntry = entry
        jam.serverUserAsked = userAsked
        jam.serverStatus = "\(entry) has moved. Connecting to it again…"
        publishJam()
        checkBeforeConnectingServer(entry, endpoint, requestID: requestID)
    }

    /// A network change is a moment to look names up again: Wi-Fi or a VPN has just come up, or the home connection moved.
    private func watchNetworkForServerName() {
        guard useHardware, jam.serverPathMonitor == nil else { return }
        jam.serverPathSeen = false
        let watcher = NWPathMonitor()
        watcher.pathUpdateHandler = { [weak self, weak watcher] _ in
            guard let self, let watcher, self.jam.serverPathMonitor === watcher else { return }
            guard self.jam.serverPathSeen else { self.jam.serverPathSeen = true; return }
            self.jam.serverNetworkChanged = true
            self.jam.nextNameCheck = 0
        }
        jam.serverPathMonitor = watcher
        watcher.start(queue: queue)
    }

    /// A packet from the server itself: its address check goes straight back (until it has, the server passes us
    /// nothing), its bookkeeping stays here, and a member's packet goes on as that member's. True: handled here.
    fileprivate func jamReceive(_ d: Data, from ep: Endpoint, now: TimeInterval) -> Bool {
        guard let group = jam.group, let relay = group.connectedRelay, relay.address == ep.address, relay.port == ep.port
        else { return false }
        let bytes = [UInt8](d)
        if JamWire.isAddressCheck(bytes) {
            wire?.send(d, to: ep)
            return true
        }
        switch group.handleInbound(bytes, from: JamEndpoint(ep), now: now) {
        case .notGroup:
            return false
        case .consumed:
            return true
        case let .delivered(packet, member):
            receiveWire(Data(packet), from: Endpoint(member), now: now)
            return true
        }
    }

    /// Send to a peer: through the server when they are on it, as before otherwise.
    @discardableResult
    fileprivate func peerSend(_ data: Data, to endpoint: Endpoint) -> Bool {
        let audio = data.count >= Wire.headerSize && data[5] == Wire.Kind.audio.rawValue
        if let group = relayRouter {
            let began = audio ? sendWorkDiagnostics.begin() : 0
            let routed = group.route([UInt8](data), to: JamEndpoint(endpoint))
            // Record after the nested send callback, without holding inout access across it.
            sendWorkDiagnostics.note(.relayRoute, began: began)
            if routed { return true }
        }
        let began = audio ? sendWorkDiagnostics.begin() : 0
        let sent = wire?.send(data, to: endpoint) ?? false
        sendWorkDiagnostics.note(.udp, began: began)
        return sent
    }

    fileprivate func sendMetronomeMessage(_ m: MetronomeMessage, to endpoint: Endpoint) {
        guard let credentials, let sealed = try? credentials.seal(Data(m.plaintext())) else { return }
        jam.metronomeSequence &+= 1
        peerSend(Wire.packet(.metronome, stream: MetronomeMessage.streamId, sequence: jam.metronomeSequence, payload: sealed), to: endpoint)
    }

    fileprivate func receiveMetronome(_ payload: Data, from ep: Endpoint) {
        guard let credentials, jam.replay.firstTime(sealedPayload: [UInt8](payload)),
            let plain = try? credentials.open(payload), let m = MetronomeMessage.parse([UInt8](plain))
        else { return }
        jam.metronome.handle(m, from: JamEndpoint(ep))
    }

    /// When the oldest queued captured frame reached the input: now, less the input's own delay, less what is queued -
    /// nil unless on a server (only the server's metronome needs it).
    fileprivate func captureReading(queuedFrames: Int) -> Int64? {
        guard jam.onServer, let audio else { return nil }
        let inputUs = Int64((audio.inputLatencySeconds * 1_000_000).rounded())
        let source = "the input, its delay taken as \(Double(inputUs / 100) / 10) ms (Core Audio's figure)"
        if source != jam.timedFrom {
            jam.timedFrom = source
            log("Metronome: the server times this Mac's sound from \(source).")
        }
        return MetronomeClock.nowUs() - inputUs - Int64((Double(queuedFrames) * 1_000_000 / 48_000).rounded())
    }

    @discardableResult
    fileprivate func noteCapture(stream: UInt16, sequence: UInt32, frames: Int, readingUs: Int64?) -> Int64? {
        guard let readingUs else { return nil }
        let captured = jam.captureTime(stream: stream, frames: frames, readingUs: readingUs)
        jam.reports.note(CaptureReport(stream: stream, sequence: sequence, capturedUs: captured))
        jam.selfMonitor.noteSent(stream: stream, sequence: sequence, capturedUs: captured)
        return captured
    }

    /// The clicks for the block about to be played: heard after what is already queued ahead of it and the output's delay.
    fileprivate func renderClicks() -> [Float]? {
        guard let schedule = jam.metronome.schedule else { return nil }
        var block = [Float](repeating: 0, count: mixFrames * 2)
        let queuedUs = audio.map { Int64((Double($0.playbackQueuedFrames) * 1_000_000 / 48_000).rounded()) } ?? 0
        let outputUs = audio.map { Int64(($0.outputLatencySeconds * 1_000_000).rounded()) } ?? 0
        jam.clicks.gain = jam.metronome.settings.volume
        jam.clicks.render(into: &block, heardAtUs: MetronomeClock.nowUs() + queuedUs + outputUs, schedule: schedule)
        return block
    }

    /// "Metronome" on a DAW track (Windows MetronomeDaw): the clicks in the block a plugin asked for, placed by the
    /// plugin's playback - a block asked for now is heard about three blocks later, plus the DAW's own output delay, which
    /// RemSound cannot know: about one DAW block of accuracy, as on Windows.
    fileprivate func addDawClicks(_ block: inout [Float], instance: UInt32) {
        guard let schedule = jam.metronome.schedule else { return }
        let player = jam.dawClicks[instance] ?? MetronomeClickPlayer()
        player.sound = jam.clicks.sound
        player.gain = jam.metronome.settings.volume
        let frames = block.count / 2
        let leadUs = Int64(Double(MetronomeDAW.leadBlocks * frames) * 1_000_000 / 48_000)
        var clicks = [Float](repeating: 0, count: block.count)
        player.render(into: &clicks, heardAtUs: MetronomeClock.nowUs() + leadUs, schedule: schedule)
        for i in block.indices { block[i] += clicks[i] }
        jam.dawClicks[instance] = player
    }

    fileprivate func serverDetails(now: TimeInterval) -> String? {
        guard let group = jam.group, let relay = group.connectedRelay, group.isInGroup(relay) else {
            jam.serverStatusState.reset()
            return nil
        }
        let info = group.latestServerInfo, rtt = group.serverRoundTripMs
        let sendOn = sendDevice || sendSystemAudio || plugins.values.contains { now - $0.lastAudioAt < 3 }
        let facts = ServerStatus.Facts(entry: jam.serverEntry.isEmpty ? relay.address : jam.serverEntry,
            address: relay, connectedFor: max(0, now - (group.inGroupSince ?? now)), roundTripMs: rtt, info: info,
            olderServer: ServerStatus.isOlder(info: info, roundTripMs: rtt, inGroupSince: group.inGroupSince, now: now, knownOlder: serverVersionKnownOlder),
            sending: sendOn && sendTargets.contains(Endpoint(relay)),
            group: group.members.filter { $0.relay == relay }.map { .init(name: $0.name, ticksUs: $0.ticksUs) },
            phonePaired: group.isV1Paired(relay), sendOn: sendOn)
        let text = jam.serverStatusState.render(facts)
        if let file = jam.logFile, let line = jam.serverStatusState.takeLog(text, now: ProcessInfo.processInfo.systemUptime) {
            file.event("server status [send input \(sendDevice ? "on" : "off"), send system \(sendSystemAudio ? "on" : "off"), codec \(sendCodec.rawValue), packet size \(sendPacketSize.rawValue), receive \(receive ? "on" : "off")]: \(line)")
        }
        return text
    }

    fileprivate func publishJam() {
        let details = serverDetails(now: Date.timeIntervalSinceReferenceDate)
        let m = jam.metronome
        let view = JamView(connected: jam.onServer, server: jam.serverEntry, serverStatus: jam.serverStatus,
                           metronomeRole: m.role, metronomePlaying: m.playing, metronomeLine: m.describe(),
                           metronomeBpm: m.settings.clampedBpm, whenAsked: m.settings.whenAsked,
                           selfMonitoring: jam.selfMonitor.enabled, selfMonitoringStatus: jam.selfMonitoringStatus,
                           metronomeMuted: m.muted, serverDetails: details, pendingServer: jam.serverWatch.pending,
                           masterName: m.role == .follower ? m.masterName : nil,
                           masterBpm: m.role == .follower ? m.serverGridNow.map { Int((Double($0.timeline.milliBpm) / 1000).rounded()) } : nil,
                           masterSignature: m.role == .follower ? m.serverGridNow?.timeline.signature : nil)
        guard view != jam.lastView else { return }
        jam.lastView = view
        DispatchQueue.main.async { [weak self] in self?.onJamChange?(view) }
    }

    fileprivate func noticeOnMain(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onMetronomeNotice?(text) }
    }

    /// The session is running: the metronome's hooks (it clicks with or without a server).
    fileprivate func jamStart() {
        openDetailedLog()
        let m = jam.metronome
        m.onServerNow = { [weak self] in self?.jam.onServer ?? false }
        m.toServer = { [weak self] body in self?.jam.group?.sendTiming(body) }
        m.peers = { [weak self] in
            guard let self, let group = jam.group else { return [] }
            return group.members.filter { $0.ticksUs && self.peers[$0.address.address]?.selected == true }.map { ($0.address, $0.name) }
        }
        m.memberName = { [weak self] id in self?.jam.group?.members.first { $0.id == id }?.name }
        m.sendMessage = { [weak self] message, to in self?.sendMetronomeMessage(message, to: Endpoint(to)) }
        m.log = { [weak self] in self?.log($0) }
        m.notice = { [weak self] in self?.noticeOnMain($0) }
        m.changed = { [weak self] in self?.publishJam() }
        m.askAboutOffer = { [weak self] askedName, leading, answer in
            guard let self, let ask = onMetronomeQuestion else { answer(false); return }
            let queue = self.queue
            DispatchQueue.main.async { ask(askedName, leading) { yes in queue.async { answer(yes) } } }
        }
        publishJam()
    }

    /// The session is stopping: leave the server, and the metronome goes back to your own, stopped.
    fileprivate func jamStop() {
        leaveServer()
        jam.serverPathMonitor?.cancel()
        jam.serverPathMonitor = nil
        if jam.metronome.role == .master { jam.metronome.releaseMaster() }
        if jam.metronome.role == .follower { jam.metronome.stopFollowing("RemSound stopped", sendLeave: false) }
        if jam.metronome.playing { jam.metronome.startStop() }
        if let file = jam.logFile {
            for line in jam.connectionLog.endAll("RemSound stopped", Date()) { file.event(line.level, "Peer", line.text) }
            file.event(.info, "Log", "log stopped (RemSound stopped)")
            file.close()
        }
        jam.logFile = nil
        jam.customSender = nil
        jam.ordinaryPending = []
        jam.reset()
        publishJam()
    }
}

// MARK: - Hearing our own sound through the server

extension Session {
    /// Checks the live session before the UI offers its feedback warning. Rechecked when enabled after the warning.
    public func selfMonitoringReadiness(_ reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            let refusal = selfMonitoringRefusal()
            DispatchQueue.main.async { reply(refusal) }
        }
    }

    private func selfMonitoringRefusal() -> String? {
        let sending = sendDevice || sendSystemAudio
            || plugins.values.contains { Date.timeIntervalSinceReferenceDate - $0.lastAudioAt < 3 }
        return SelfMonitorTiming.refusal(onServer: running && jam.onServer, sending: sending,
                                        receiving: receive && !receiveMuted)
    }

    public func setSelfMonitoring(_ on: Bool) {
        queue.async { [self] in
            if !on { stopSelfMonitoring("Self-monitoring off. Muted myself."); return }
            guard !jam.selfMonitor.enabled else { return }
            if let reason = selfMonitoringRefusal() {
                jam.selfMonitoringStatus = reason
                publishJam()
                noticeOnMain(reason)
                return
            }
            jam.selfMonitor.start(nowUs: MetronomeClock.nowUs())
            jam.selfMonitoringStatus = "Self-monitoring on. Waiting for audio to come back from the server."
            jam.group?.setSelfMonitoring(true)
            updateSendTargets()
            nextHello = 0
            jam.nextCustomFormat = 0
            jam.nextSelfMeasurement = Date.timeIntervalSinceReferenceDate + 1
            for id in plugins.keys { plugins[id]?.formatSent = 0 }
            jam.group?.tick(now: Date.timeIntervalSinceReferenceDate)
            log(jam.selfMonitoringStatus)
            publishJam()
            noticeOnMain(jam.selfMonitoringStatus)
        }
    }

    private func stopSelfMonitoring(_ message: String) {
        guard jam.selfMonitor.enabled else { return }
        let own = jam.group?.ownMemberAddress.address
        jam.selfMonitor.stop()
        jam.group?.setSelfMonitoring(false)
        if let own {
            for key in streams.keys.filter({ $0.hasPrefix(own + "/") }) {
                streams[key] = nil
                streamSeen[key] = nil
            }
            histories[own] = nil
        }
        jam.selfMonitoringStatus = message
        updateSendTargets()
        jam.group?.tick(now: Date.timeIntervalSinceReferenceDate)
        log(message)
        publishJam()
        noticeOnMain(message)
    }

    private func measureSelfMonitoring() {
        let measurements = jam.selfMonitor.takeMeasurements()
        guard let own = jam.group?.ownMemberAddress.address, !measurements.isEmpty else { return }
        var descriptions: [String] = []
        for (id, result) in measurements.sorted(by: { $0.key < $1.key }) {
            let key = own + "/" + String(id)
            let buffered = Double(streams[key]?.queuedFrames ?? 0) / 48
            let outputQueue = Double(audio?.playbackQueuedFrames ?? 0) / 48
            let outputDelay = (audio?.outputLatencySeconds ?? 0) * 1000
            let isDAW = plugins.values.contains { $0.stream == id }
            let source = isDAW ? "DAW app bridge" : "captured input"
            let total = result.medianMs + buffered + outputQueue + outputDelay
            let text = "\(source), stream \(id): back from server \(String(format: "%.1f", result.medianMs)) milliseconds; "
                + "receive queue \(String(format: "%.1f", buffered)) milliseconds, "
                + "Mac output queue \(String(format: "%.1f", outputQueue)) milliseconds, "
                + "output hardware \(String(format: "%.1f", outputDelay)) milliseconds; "
                + "estimated total \(String(format: "%.1f", total)) milliseconds."
            descriptions.append(text)
            // One bounded line per second, on the network worker, never the real-time callback.
            jam.logFile?.event("hear myself: \(text) \(result.count) timed, longest \(String(format: "%.1f", result.longestMs)) ms, \(result.returnedCount) audio blocks returned on this stream."
                + (isDAW ? " Host input delay before the app bridge is not measured." : ""))
            if let audio {
                let origin: AudioDelayEstimates.Source = isDAW ? .dawBridge
                    : id == systemStreamID ? .systemOrApplications
                    : id == deviceStreamID ? .selectedInputs : .unknown
                let comparison = audio.delayEstimates.compare(source: origin, captureToReturnMs: result.medianMs,
                    includedInputMs: audio.inputLatencySeconds * 1000, receiveQueueMs: buffered,
                    outputQueueMs: outputQueue, originalOutputMs: outputDelay)
                jam.logFile?.event("hear myself components: stream \(id), "
                    + (comparison?.logDescription ?? "IO comparison unavailable: unknown source origin, incomplete setup "
                        + "or missing/inconsistent device delay reports; input IO-buffer overlap is not established. Existing timing unchanged."))
            }
        }
        jam.selfMonitoringStatus = "Self-monitoring on. " + descriptions.joined(separator: " ")
            + (monitorInApp ? "" : " Mac output is off; enable Play received audio through Mac output to hear the test.")
        publishJam()
    }
}

// MARK: - Jamming at speed, and the detailed log (2026-09-29, Ed: "agree with your list" / "comprehensive logging")

extension Session {
    /// Jamulus-style 64-sample frames on or off (the Windows latency lab's switch). On, every Format and heartbeat says we
    /// can play them, and anyone who says the same gets them from our input instead of the ordinary stream.
    public func setJamulusStyle(_ on: Bool) {
        queue.async { [self] in
            guard jam.jamulusStyle != on else { return }
            jam.jamulusStyle = on
            if !on { jam.customSender = nil }
            log("Jamulus-style frames \(on ? "on" : "off").")
        }
    }

    /// Keeping in time with other sound cards (see ClockKeeping in Audio.swift): on unless unticked.
    public func setKeepsInTime(_ on: Bool) {
        queue.async { [self] in
            guard ClockKeeping.on != on else { return }
            ClockKeeping.on = on
            log("Keeping in time with other sound cards \(on ? "on" : "off").")
        }
    }

    /// The Core Audio buffer size to ask every device for (0: leave the devices as they are). Applied now if running.
    public func setCoreAudioBufferFrames(_ frames: Int) {
        guard [0, 32, 64, 128, 256].contains(frames) else { return }
        queue.async { [self] in
            jam.bufferFrames = frames
            guard running, let audio else { return }
            log(audio.applyBufferFrames(frames, inputUIDs: inputDeviceUIDs, outputUIDs: outputDeviceUIDs))
            for setup in audio.configurationDiagnostics() { log(setup) }
        }
    }

    /// Save the last minute of the network - every audio packet's arrival, and what was heard go wrong in it - in the
    /// Windows app's own format, beside the detailed log, for Ed's simulator to play back. Says, on the main queue,
    /// where it went and what it holds, or why nothing was saved.
    public func saveNetworkRecording(_ done: @escaping (URL?, String) -> Void) {
        queue.async { [self] in
            let facts = networkRecordingFacts()
            let rec = jam.recorder.take(facts: facts) { [self] from, id in
                let address = String(from.split(separator: ":").first ?? "")
                guard let stream = streams[address + "/" + String(id)] else { return nil }
                let f = stream.format
                let codec = f.codec == StreamFormat.Codec.opusCustom.rawValue ? "Jamulus-style"
                    : f.codec == StreamFormat.Codec.opus.rawValue ? "Opus" : "PCM"
                return .init(lane: "unknown", format: "48000 Hz, \(f.channels) channels, \(codec), \(f.frames) frames",
                    codec: f.codec, frameSamples: f.frames)
            }
            guard !rec.packets.isEmpty else {
                DispatchQueue.main.async { done(nil, "Nothing has been received in the last minute, so there is nothing to save.") }
                return
            }
            let folder = jam.logFolder ?? configuration.logsDirectory
            let file = folder.appendingPathComponent(NetworkRecorder.fileName(machine: name, at: Date()))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try rec.text().write(to: file, atomically: true, encoding: .utf8)
                let seconds = (rec.packets.last?.ms ?? 0) / 1000
                let said = "Saved \(Int(seconds.rounded())) seconds of the network, \(rec.packets.count) packets on \(rec.streams.count) "
                    + "stream\(rec.streams.count == 1 ? "" : "s"), to \(file.lastPathComponent)."
                log("Network recording saved: \(file.path)")
                DispatchQueue.main.async { done(file, said) }
            } catch {
                DispatchQueue.main.async { done(nil, "The network recording could not be saved: \(error.localizedDescription)") }
            }
        }
    }

    /// The facts at the head of a saved minute, with the names the Windows app and its simulator use.
    private func networkRecordingFacts() -> [NetworkRecording.Fact] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        var facts: [NetworkRecording.Fact] = [
            .init("machine", name), .init("saved", f.string(from: Date())), .init("RemSound", "Mac \(version)"),
            .init("configuration", "Mac, Core Audio"),
            .init("buffer ms", String(receiveJitterMs)), .init("buffer ASIO ms", String(receiveJitterMs)),
            .init("buffer smoothness", String(receiveSmoothness)),
            .init("gap sound", receiveArtifact.label),
            .init("auto-tune", receiveAutoTune ? "on, every \(receiveAutoTuneInterval) s" : "off"),
            .init("Jamulus-style", jam.jamulusStyle ? "on" : "off"),
            .init("keeping in time", ClockKeeping.on ? "on" : "off"),
            .init("mix block frames", String(mixFrames)),
        ]
        if let cards = audio?.outputClocks, let first = cards.first, first.cushionFrames > 0 {
            facts.append(.init("output cushion frames", String(first.cushionFrames)))
        }
        if jam.bufferFrames > 0 {
            facts.append(.init("receive card frames", String(jam.bufferFrames)))
            facts.append(.init("ASIO output period ms", String(format: "%.2f", Double(jam.bufferFrames) / 48)))
        }
        let nowTickMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
        let pings = peers.values.filter(\.selected).compactMap {
            heartbeatTiming.range(selected: [$0.endpoint.address], nowTickMs: nowTickMs).map { Double($0.lowerBound) }
        }
        if let least = pings.min() { facts.append(.init("one-way ms", String(format: "%.1f", least / 2))) }
        return facts
    }

    /// Where the detailed log goes (nil: ~/Library/Logs/RemSound). Andre can point it into Dropbox for Ed to read.
    public func setLogFolder(_ folder: URL?) {
        queue.async { [self] in
            jam.logFolder = configuration.isIsolated ? configuration.logsDirectory : folder
            if running { openDetailedLog() }
        }
    }

    public func setMetronomeSignature(_ beatsPerBar: Int, _ beatUnit: Int) {
        queue.async { [self] in
            var s = jam.metronome.settings
            s.signature = MetronomeSignature(UInt8(beatsPerBar), UInt8(beatUnit))
            jam.metronome.configure(s)
            log("Metronome: time signature \(beatsPerBar)/\(beatUnit).")
            publishJam()
        }
    }

    func testMetronomeVolume() -> Float { queue.sync { jam.metronome.settings.volume } }

    public func setMetronomeVolume(_ percent: Int) {
        queue.async { [self] in
            var s = jam.metronome.settings
            s.volume = Float(min(max(percent, 0), 100)) / 100
            jam.metronome.configure(s)
            log("Metronome: volume \(percent) %.")
            publishJam()
        }
    }

    public func setMetronomeSound(_ name: String) {
        queue.async { [self] in
            jam.clicks.sound = loadClickSound(name)
            log("Metronome: click sound \(name).")
        }
    }

    /// Everything in the profile's metronome settings at once (the Metronome settings window, a profile opening).
    public func setMetronomeChoices(_ choices: MetronomeChoices, volume: Int) {
        queue.async { [self] in
            var s = jam.metronome.settings
            s.bpm = choices.clampedBpm
            s.signature = choices.signature
            s.whenAsked = choices.whenAsked
            s.volume = Float(min(max(volume, 0), 100)) / 100
            jam.metronome.configure(s)
            jam.clicks.sound = loadClickSound(choices.sound)
            if jam.hearIn != choices.hearIn { jam.dawClicks.removeAll() }
            jam.hearIn = choices.hearIn
            jam.clicksRecorded = choices.recorded
            log("Metronome: \(choices.describe(volume: volume)).")
            publishJam()
        }
    }

    /// The shipped sounds in the app, and a person's own in a "Metronome sounds" folder beside the profiles.
    public static func metronomeSoundFolders(_ configuration: RuntimeConfiguration) -> (shipped: URL?, user: URL) {
        (Bundle.main.resourceURL?.appendingPathComponent("default sounds/metronome", isDirectory: true),
         configuration.profilesDirectory.deletingLastPathComponent()
            .appendingPathComponent(MetronomeSoundLibrary.userFolderName, isDirectory: true))
    }

    /// A sound by name; one that will not open is the first shipped sound, and failing that a click made here.
    private func loadClickSound(_ name: String) -> MetronomeClickSound {
        let folders = Self.metronomeSoundFolders(configuration)
        if let sound = MetronomeSoundLibrary.load(name, shipped: folders.shipped, user: folders.user) { return sound }
        log("Metronome: the click sound \(name) would not open; using \(MetronomeSoundLibrary.defaultName).")
        return MetronomeSoundLibrary.load(MetronomeSoundLibrary.defaultName, shipped: folders.shipped, user: nil)
            ?? .synthesized()
    }

    /// The lab flags our Format packets and heartbeats carry: bit 0 while Jamulus-style frames are on.
    var jamLabFlags: UInt8 { jam.jamulusStyle ? JamulusStyle.labFlagCanDecode : 0 }

    /// The mix's block: 96 frames (2 ms) while playing at speed, the usual 240 (5 ms) otherwise.
    var mixFrames: Int { jam.jamulusStyle ? 96 : 240 }

    /// Who gets Jamulus-style frames from our input now (empty: nobody, or the switch is off).
    func jamulusStyleTargets(now: TimeInterval) -> Set<Endpoint> {
        guard jam.jamulusStyle, !sendTargets.isEmpty else { return [] }
        let chosen = JamulusStyle.targets(sendTargets.map(JamEndpoint.init), group: jam.group) { [jam] address in
            if jam.selfMonitor.enabled && address == jam.group?.ownMemberAddress.address { return true }
            return jam.canDecode.canDecode(address, now: now)
        }
        return Set(chosen.map(Endpoint.init))
    }

    /// 64 frames of input: a Jamulus-style frame, sealed, to those who take it; the same sound gathered into ordinary
    /// packets for everyone else.
    func sendJamulusStyle(_ samples: [Float], to fast: Set<Endpoint>, readingUs: Int64?) {
        guard let credentials else { return }
        if jam.customSender == nil {
            jam.customSender = OpusCustomSender(frames: JamulusStyle.frames)
            jam.customStreamID = freshStreamID()
            jam.nextCustomFormat = 0
            log("Jamulus-style frames: sending to \(fast.count) (stream \(jam.customStreamID)).")
        }
        let now = Date.timeIntervalSinceReferenceDate
        if now >= jam.nextCustomFormat {
            jam.nextCustomFormat = now + 1
            // Format refreshes describe the stream; only audio may advance its loss-detection sequence.
            let format = Wire.packet(.format, stream: jam.customStreamID,
                payload: StreamFormat.opusCustom(credentials.fingerprint, frames: JamulusStyle.frames).encode(lane: .asio))
            for endpoint in fast { peerSend(format, to: endpoint) }
        }
        let encodeBegan = sendWorkDiagnostics.begin()
        let encoded = jam.customSender?.encode(samples)
        sendWorkDiagnostics.note(.encode, began: encodeBegan)
        if let encoded, let sealed = try? credentials.sealAudio(encoded, diagnostics: &sendWorkDiagnostics) {
            jam.lastAudioSentAt = now
            let sequence = nextAudioSequence(for: jam.customStreamID)
            noteCapture(stream: jam.customStreamID, sequence: sequence, frames: JamulusStyle.frames, readingUs: readingUs)
            let frameBegan = sendWorkDiagnostics.begin()
            let packet = Wire.packet(.audio, stream: jam.customStreamID, sequence: sequence, payload: sealed)
            sendWorkDiagnostics.note(.frame, began: frameBegan)
            var failures = 0
            for endpoint in fast where !peerSend(packet, to: endpoint) { audioSendFailures += 1; failures += 1 }
            sentAudioDiagnostics.note(stream: jam.customStreamID, frames: JamulusStyle.frames,
                copies: fast.count, failures: failures, now: ProcessInfo.processInfo.systemUptime)
            jam.customSentThisSecond += 1
        }
        // Everyone else keeps the ordinary stream, in its own packet size.
        let rest = sendTargets.filter { !fast.contains($0) }
        guard !rest.isEmpty else {
            jam.ordinaryPending = []
            return
        }
        jam.ordinaryPending += samples
        let size = sendPacketFrames * 2
        while jam.ordinaryPending.count >= size {
            sendAudio(Array(jam.ordinaryPending.prefix(size)), stream: deviceStreamID, to: rest)
            jam.ordinaryPending.removeFirst(size)
        }
    }

    /// Open (or move) the detailed log: a log and a readings file per run, in the chosen folder (Windows 6.2.3).
    func openDetailedLog() {
        guard useHardware, loggingEnabled else { return }
        jam.logFile?.close()
        let folder = jam.logFolder ?? configuration.logsDirectory
        let safeName = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let file = JamLog(directory: folder, prefix: "RemSound-Mac", machine: safeName, about: "RemSound for Mac \(version)")
        jam.logFile = file
        file.event(.info, "Log", "log started: \(name); Jamulus-style \(jam.jamulusStyle ? "on" : "off"), "
            + "Core Audio buffer \(jam.bufferFrames > 0 ? "\(jam.bufferFrames) frames" : "as the devices are"), receive buffer \(receiveJitterMs) ms"
            + "\(receiveAutoTune ? " with auto-tune every \(receiveAutoTuneInterval) s" : ", fixed"), codec \(sendCodec.rawValue), packet size \(sendPacketSize.rawValue), buffer smoothness \(receiveSmoothness), gap sound \(receiveArtifact.label), "
            + "keeping in time with other sound cards \(ClockKeeping.on ? "on" : "off")")
        file.flush()
        watchNetworkForLog()
    }

    /// The log's own watch on this Mac's network: a change is a line of its own (at most one every ten seconds) and is
    /// named in the reason of a disconnect that follows it.
    private func watchNetworkForLog() {
        guard useHardware, jam.logPathMonitor == nil else { return }
        jam.logPathSeen = false
        let watcher = NWPathMonitor()
        watcher.pathUpdateHandler = { [weak self, weak watcher] path in
            guard let self, let watcher, self.jam.logPathMonitor === watcher else { return }
            guard self.jam.logPathSeen else { self.jam.logPathSeen = true; return }
            let now = Date()
            self.jam.connectionLog.networkChanged(now)
            guard now.timeIntervalSince(self.jam.lastNetworkLine) >= 10 else { return }
            self.jam.lastNetworkLine = now
            self.jam.logFile?.event(.warn, "Network", path.status == .satisfied
                ? "this Mac's network changed" : "this Mac has no network now", at: now)
        }
        jam.logPathMonitor = watcher
        watcher.start(queue: queue)
    }

    /// Once a second while running (Windows 6.2.3, its issue 35, Jonathan Schuster: the logs were too much). What
    /// RemSound measured goes in the readings file - a row for the Mac, and one for each incoming stream, output card and
    /// ticked peer - every minute summed up and every second kept only around a problem. The log gets what happened: runs
    /// of audible gaps, and peers connecting and dropping, a disconnect saying why with the five minutes before it kept.
    func logSecond(now: TimeInterval) {
        guard let file = jam.logFile else { return }
        let date = Date()
        let sendingOn = sendDevice || sendSystemAudio
        let fast = jamulusStyleTargets(now: now)
        let onServer = jam.group != nil || jam.metronome.role != .solo || jam.metronome.playing
        // What is in use this second: a reading is written only while the thing it measures is.
        var groups: [String] = []
        if !streams.isEmpty { groups.append(MacReadings.receiving) }
        if sendingOn { groups.append(MacReadings.sending) }
        if sendingOn && !fast.isEmpty { groups.append(MacReadings.jamulusStyle) }
        if audio != nil { groups.append(MacReadings.audio) }
        if !plugins.isEmpty { groups.append(MacReadings.plugin) }
        if onServer { groups.append(MacReadings.server) }
        let schema = MacReadings.schema
        let machine = ReadingsRow(schema, groupsInUse: groups)
        var rows: [ReadingsRow] = []
        var observations: [String] = []

        let totals = jam.receiveTotals
        machine.set("sending", sendingOn)
        machine.set("sendingTo", sendingOn ? sendTargets.count : 0)
        machine.set("sendFailuresTotal", audioSendFailures)
        machine.set("canPlayJamulusStyle", jam.canDecode.count(now: now))
        machine.set("audibleGapsTotal", totals.audibleGaps)
        machine.set("concealedTotal", totals.concealed)
        machine.set("lateOrDoubledDroppedTotal", totals.lateOrDoubledDropped)
        machine.set("gapsNotRepairedTotal", totals.gapsNotRepaired)
        machine.set("malformedPacketsTotal", Double(totals.malformedPackets))
        machine.set("refusedAudioTotal", Double(totals.rejectedAudioPayloads))
        machine.set("notAllowedTotal", Double(totals.notAllowedPackets))
        machine.set("rejectedPCMTotal", Double(totals.rejectedPCMFragments))
        machine.set("discardedPCMTotal", Double(totals.discardedPCMPartials))
        machine.set("reorderWaitsTotal", Double(totals.reorderWaits))

        // Each incoming stream: its own row, its gaps for the run-of-gaps lines, and its peer's share for the connection's.
        var newGaps = 0
        var longestGapMs = 0
        var gapsByStream: [String: Int] = [:]
        var perPeer: [String: (packets: Int, gaps: Int, filledIn: Int, lowest: Double?)] = [:]
        for (key, stream) in streams.sorted(by: { $0.key < $1.key }) {
            let figures = stream.takeLogFigures()
            let parts = key.split(separator: "/")
            let address = parts.first.map(String.init) ?? key
            let peerName = peers[address]?.name ?? address
            let codec = stream.format.codec == StreamFormat.Codec.opusCustom.rawValue ? "Jamulus-style"
                : stream.format.codec == StreamFormat.Codec.opus.rawValue ? "Opus" : "PCM"
            let row = ReadingsRow(schema, groupsInUse: [MacReadings.stream],
                                  stream: "\(peerName)/\(parts.last.map(String.init) ?? "0")")
            row.text("codec", codec)
            row.set("frames", stream.format.frames)
            row.set("packets", figures.packets)
            row.set("arrivalGapMaxMs", figures.maxGapMs)
            row.set("arrivalGapP95Ms", figures.interval.gaps?.recentP95)
            row.set("queueMinMs", figures.interval.queue?.minimum)
            row.set("queueMeanMs", figures.interval.queue?.mean)
            row.set("queueMaxMs", figures.interval.queue?.maximum)
            row.set("queuedMs", stream.queuedFrames * 1000 / Wire.sampleRate)
            row.set("targetMs", receiveJitterMs)
            row.set("concealed", figures.concealed)
            row.set("underruns", figures.underruns)
            row.set("trims", figures.trims)
            row.set("trimmedFrames", figures.trimmedFrames)
            if ClockKeeping.on { row.set("clockPpm", stream.clockPpm) }
            rows.append(row)
            newGaps += figures.underruns
            longestGapMs = max(longestGapMs, Int(ceil(figures.longestUnderrunMs)))
            if figures.underruns > 0 { gapsByStream["\(peerName) on \(codec)", default: 0] += figures.underruns }
            var share = perPeer[address] ?? (packets: 0, gaps: 0, filledIn: 0, lowest: nil)
            share.packets += figures.packets
            share.gaps += figures.underruns
            share.filledIn += figures.concealed
            if let low = figures.interval.queue?.minimum { share.lowest = min(share.lowest ?? low, low) }
            perPeer[address] = share
        }

        // What goes out.
        machine.set("jamulusStyleTo", fast.count)
        machine.set("jamulusStyleFrames", jam.customSentThisSecond)
        jam.customSentThisSecond = 0
        var sentPackets = 0, sentFrames = 0, copies = 0, failures = 0
        var emitMax: Double?, emitP95: Double?
        for sent in sentAudioDiagnostics.take() {
            let stats = sent.statistics
            sentPackets += stats.packets; sentFrames += stats.frames; copies += stats.copies; failures += stats.failures
            if let gaps = stats.gaps {
                emitMax = max(emitMax ?? gaps.maximum, gaps.maximum)
                emitP95 = max(emitP95 ?? gaps.recentP95, gaps.recentP95)
            }
        }
        machine.set("sentPackets", sentPackets)
        machine.set("sentFrames", sentFrames)
        machine.set("sendCopies", copies)
        machine.set("sendFailures", failures)
        machine.set("emitGapMaxMs", emitMax)
        machine.set("emitGapP95Ms", emitP95)
        let work = sendWorkDiagnostics.take()
        if !work.isEmpty { observations.append(SendWorkDiagnostics.describe(work)) }

        machine.set("pluginInstances", plugins.count)
        for (instance, plugin) in plugins.sorted(by: { $0.key < $1.key }) {
            observations.append("DAW callback observation: instance \(instance), "
                + plugin.hostCallback.logDescription(now: now, workerRequestFrames: hosts[plugin.pid]?.frames))
        }

        // The sound cards: their delays, and each output card kept in time with the mix.
        if let audio {
            observations += audio.callbackBudgetDiagnostics
            observations += audio.inputClockDiagnostics
            observations += audio.captureTimestampDiagnostics
            for rate in callbackRateMeter.take(audio.callbackCaptureCounters, now: ProcessInfo.processInfo.systemUptime) {
                observations.append(rate.logDescription)
            }
            for rate in captureRateMeter.take(audio.inputCaptureCounters, now: ProcessInfo.processInfo.systemUptime) {
                observations.append("capture rate: \(rate.name), \(rate.frames) normalized frames in "
                    + "\(String(format: "%.3f", rate.seconds)) seconds, "
                    + "\(String(format: "%.1f", rate.framesPerSecond)) normalized frames/second; "
                    + "whole observed run \(rate.wholeRunFrames) frames in \(String(format: "%.3f", rate.wholeRunSeconds)) seconds, "
                    + "\(String(format: "%.1f", rate.wholeRunFramesPerSecond)) normalized frames/second; "
                    + "pipeline target \(Wire.sampleRate) Hz. Native device frame rate is not measured here.")
            }
            for source in captureDriftDiagnostics.snapshots {
                observations.append("capture clock observation: \(source.name), depth \(source.queuedFrames) normalized frames, "
                    + "drift \(source.ppm.map { String(format: "%+.1f", $0) } ?? "unmeasured") ppm, "
                    + "rejected ten-second windows \(source.rejectedWindows). Observation only; input clock correction is not applied.")
            }
            machine.set("inputLatencyMs", (audio.inputLatencySeconds * 1000).rounded())
            machine.set("outputLatencyMs", (audio.outputLatencySeconds * 1000).rounded())
            let queued = audio.playbackQueuedFrames * 1000 / Wire.sampleRate
            machine.set("playbackQueuedMs", queued)
            machine.set("playbackQueuedMaxMs", queued)
            machine.set("mixFrames", mixFrames)
            for (index, card) in audio.outputClocks.enumerated() {
                let row = ReadingsRow(schema, groupsInUse: [MacReadings.card], output: "card \(index + 1)")
                row.set("cardClockPpm", card.ppm)
                row.set("cushionMs", Double(card.cushionFrames) / 48)
                row.set("laidMs", Double(card.laidFrames) / 48)
                row.set("cutMs", Double(card.cutFrames) / 48)
                row.set("ranDry", card.ranDry)
                rows.append(row)
            }
        }

        // Every peer: whether it is connected (for the log's connection lines), and each ticked one's ping and latency.
        let nowTickMs = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
        let outputs = currentOutputPresentationsMs
        var seen: [ConnectionLog.Seen] = []
        for p in peers.values {
            let health = heartbeatTiming.health(for: p.endpoint.address, nowTickMs: nowTickMs)
            let share = perPeer[p.endpoint.address]
            seen.append(ConnectionLog.Seen(key: p.endpoint.address, name: p.name, selected: p.selected,
                state: Self.connectionState(health.state), pingMs: health.currentRTT, silentMs: health.ageMs,
                packets: share?.packets ?? 0, gaps: share?.gaps ?? 0, filledIn: share?.filledIn ?? 0,
                lowestBufferMs: share?.lowest))
            guard p.selected else { continue }
            let rtt = health.currentRTT
            let summary = peerLatencySummary(address: p.endpoint.address, rttMs: rtt, outputs: outputs, heartbeat: health)
            let row = ReadingsRow(schema, groupsInUse: [MacReadings.peer], stream: p.name, output: "peer")
            row.set("pingMs", rtt)
            row.set("pingMaxMs", rtt)
            row.set("totalLatencyMs", summary.maximumCompleteMs)
            row.text("peerStatus", summary.status)
            rows.append(row)
            for journey in summary.journeys {
                observations.append("receive latency: \(p.name), stream \(journey.stream), lane \(journey.lane.rawValue), "
                    + "output \(summary.hasMeasuredOutputs ? String(journey.output + 1) : "not measured"); \(journey.report.logDescription)")
            }
            if summary.truncated { observations.append("receive latency: \(p.name): additional journeys omitted; aggregate total unavailable.") }
        }
        if onServer {
            machine.text("serverStatus", jam.serverStatus)
            machine.text("metronome", jam.metronome.describe())
        }
        machine.text("observations", observations.isEmpty ? nil : observations.joined(separator: " | "))
        let connectionLines = jam.connectionLog.second(date, seen)
        machine.set("connectedPeers", jam.connectionLog.connectedCount)
        file.readings(machine, rows, at: date)

        // What happened: a run of gaps is one line when it starts (and if it gets clearly worse) and one when it ends.
        for change in jam.gapEpisodes.second(date, newGaps: newGaps, longestGapMs: longestGapMs, byStream: gapsByStream) {
            switch change.kind {
            case .started, .worse:
                let kept = file.capture(lookBack: 30, at: date)
                file.event(.warn, "Gaps", change.words + (kept.map { " - kept: \($0)" } ?? ""), at: date)
            case .stillGoing:
                file.event(.info, "Gaps", change.words, at: date)
            case .ended:
                file.event(.warn, "Gaps", change.words, at: date)
            }
        }
        for line in connectionLines {
            let kept = line.captureLookBack.flatMap { file.capture(lookBack: $0, at: date) }
            file.event(line.level, "Peer", line.text + (kept.map { " - kept: \($0)" } ?? ""), at: date)
        }
        file.flush()
    }

    private static func connectionState(_ state: HeartbeatTiming.State) -> ConnectionLog.State {
        switch state {
        case .pending: return .pending
        case .healthy: return .healthy
        case .stale: return .stale
        case .unreachable: return .unreachable
        }
    }
}


extension Session {
    func testServerStatusLog(_ file: JamLog) { queue.sync { if !useHardware { jam.logFile = file } } }
    func testFlushServerStatusLog() { queue.sync { if !useHardware { jam.logFile?.flushReadings(); jam.logFile?.flush() } } }
}

// MARK: - Accept connections (Windows MainForm.AcceptConnections: Ed 2026-09-20, tick proofs 2026-09-25, never on another
// password 2026-09-29). Somebody who ticks us is asked about, accepted, or left, as Preferences says. The decisions are
// RemSoundJam's AcceptPolicy; this only feeds it what arrives and carries out what it says.

extension Session {
    /// Ask me each time, Automatically, or Manual (Preferences). Machine-wide, as on Windows.
    public func setAcceptConnections(_ mode: AcceptConnections) {
        queue.async { [self] in
            guard accept.mode != mode else { return }
            accept.mode = mode
            log("accept connections: \(mode.title)")
        }
    }

    /// How a tick or untick is remembered against the person: a server member by who they are, anyone else by address.
    fileprivate func acceptKey(_ address: String) -> String {
        if JamWire.isMemberAddress(address), let member = jam.group?.members.first(where: { $0.address.address == address }) {
            return AcceptPolicy.memberKey(member.id)
        }
        return AcceptPolicy.peerKey(address)
    }

    /// A packet from somebody we haven't ticked. Their tick proof, opened with OUR password, says they ticked us and hold
    /// it; their stream's Format says the same through its password fingerprint. Anything else proves nothing.
    fileprivate func noteUnselectedSender(_ p: Wire.Packet, from ep: Endpoint, credentials: Credentials, now: TimeInterval) {
        guard p.kind == .tickProof || p.kind == .format, accept.mayLook(ep.address, now: now) else { return }
        switch p.kind {
        case .tickProof:
            guard p.payload.count == TickProofPayload.sealedBytes else { return }
            guard let plain = try? credentials.open(p.payload), let proof = TickProofPayload.parse(plain) else {
                accept.noteDifferentPassword(ep.address, now: now).forEach(log)
                return
            }
            guard abs(Double(proof.unixSeconds) - Date().timeIntervalSince1970) <= 600 else { return }
            let nonce = Data(p.payload.prefix(12)) + Data(ep.address.utf8)
            guard proofNonces[nonce] == nil, proofNonces.count < 4096 else { return }
            proofNonces[nonce] = now
            considerAccepting(address: ep.address, how: "has ticked us and proved our password", now: now)
        case .format:
            guard let f = StreamFormat.parse(p.payload) else { return }
            guard f.fingerprint == credentials.fingerprint else {
                accept.noteDifferentPassword(ep.address, now: now).forEach(log)
                return
            }
            considerAccepting(address: ep.address, how: "is sending to us", now: now)
        default:
            return
        }
    }

    fileprivate func considerAccepting(address: String, how: String, now: TimeInterval) {
        let peer = peers[address]
        let server = knownServerAddresses.contains(address)
            || rememberedConnections.isKnownServer(entry: address, address: address)
        let outcome = accept.considerPeer(address: address, name: peer.map { $0.advertisedName.isEmpty ? $0.name : $0.advertisedName },
                                          how: how, isSelected: peer?.selected == true, isServer: server, now: now)
        carryOut(outcome, address: address)
    }

    fileprivate func considerServerMember(id: UUID, address: String, name: String) {
        let who = name.hasSuffix(" (on the server)") ? String(name.dropLast(" (on the server)".count)) : name
        carryOut(accept.considerMember(id: id, name: who, isSelected: peers[address]?.selected == true), address: address)
    }

    fileprivate func carryOut(_ outcome: AcceptPolicy.Outcome, address: String) {
        outcome.log.forEach(log)
        switch outcome.action {
        case .nothing:
            return
        case .accept(let description):
            acceptPeer(address: address, description: description)
        case .ask(let key, let question, let description):
            askThenAccept(key, question) { [weak self] in self?.acceptPeer(address: address, description: description) }
        }
    }

    /// Tick them, as the person ticking them would - remembered too, unless they're on a server - and say so.
    fileprivate func acceptPeer(address: String, description: String) {
        if peers[address] != nil {
            applySelected(address: address, selected: true)
        } else {
            selectResolvedDirectPeer(name: address, endpoint: Endpoint(address, peerPort))
            updateSendTargets()
            publish("Peer selected. Waiting for their selection.")
        }
        log("accept connections: connected to \(description)")
        let words = "Connected to \(description)."
        DispatchQueue.main.async { [weak self] in self?.onAcceptNotice?(words) }
    }

    /// Ask, in front of whatever is on screen, and act on a yes. Nobody to ask (a headless or silent run) leaves the person
    /// unticked, as on Windows.
    fileprivate func askThenAccept(_ key: String, _ question: String, onYes: @escaping () -> Void) {
        guard onAcceptQuestion != nil else { log("accept connections: nobody to ask here - \(question)"); return }
        guard accept.beginQuestion(key) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let ask = self.onAcceptQuestion else { self.queue.async { self.accept.endQuestion() }; return }
            ask(question) { yes in
                self.queue.async {
                    self.accept.endQuestion()
                    if yes { onYes() } else { self.log("accept connections: declined - \(question)") }
                }
            }
        }
    }

    func testAcceptState() -> (mode: AcceptConnections, asked: Set<String>, refused: Set<String>) {
        queue.sync { (accept.mode, accept.asked, accept.refusedByUser) }
    }
    func testSelectedAddresses() -> Set<String> {
        queue.sync { Set(peers.values.filter(\.selected).map(\.endpoint.address)) }
    }
}
