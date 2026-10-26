import Foundation

/// The Mac's detailed log (Ed, 2026-09-29: "build comprehensive logging into his mac app so we can test this stuff"),
/// laid out as the Windows RemSound's has been since 6.2.3 (its issue 35, Jonathan Schuster: the logs were too much).
///
/// Two files a run, in a folder the person can choose (Andre can point it into Dropbox for Ed to read), named by when
/// they started: `<prefix>-yyyy-MM-dd-HHmm-<machine>.log` and, beside it, `...-readings.csv`. Each goes on in a new part
/// (`-part2`) when it reaches its size, and files older than `keepDays` are removed.
/// - The LOG holds just what happened: every line `LEVEL<tab>HH:mm:ss.SSS<tab>Category: words`, the level INFO, WARN or
///   ERROR, so a search for WARN or ERROR finds the problems. Its first line says the version, the machine, the date
///   and the time zone; a line says when the date changes.
/// - The READINGS file holds what RemSound measures every second (`ReadingsRecorder`): a row for every minute summing
///   the whole minute up, and every second only around a problem (`capture`).
/// Written from the caller's queue - never from an audio callback - and it never holds passwords, keys or sound.
public final class JamLog {
    public let directory: URL
    public let prefix: String
    public let machine: String
    public let about: String
    public let maxBytes: Int
    public let readingsMaxBytes: Int
    public let keepDays: Int
    /// What this run's files are called, without the part or the ending.
    public let stem: String
    public private(set) var currentFile: URL?
    public private(set) var currentReadingsFile: URL?
    public var readingsName: String { stem + "-readings.csv" }

    private var handle: FileHandle?
    private var written = 0
    private var part = 1
    private var readingsHandle: FileHandle?
    private var readingsWritten = 0
    private var readingsPart = 1
    private var pending: [String] = []
    private var lastDay: String?
    private var recorder: ReadingsRecorder?
    private let everySecond: Bool
    private let openFile: (URL) throws -> FileHandle
    private var closed = false

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }
    private static let day = formatter("EEEE d MMMM yyyy")
    private static let clock = formatter("HH:mm:ss")
    private static let named = formatter("yyyy-MM-dd-HHmm")

    /// - Parameters:
    ///   - prefix: what every file starts with ("RemSound-Mac").
    ///   - machine: whose log it is (the Mac's name, letters and digits only); "" leaves it out of the name.
    ///   - about: the program and version for the first line ("RemSound for Mac 6.2.4").
    ///   - everySecond: write every second's readings, not only around a problem (a test's or a deep dive's choice).
    public convenience init(directory: URL, prefix: String, machine: String = "", about: String = "RemSound for Mac",
                maxBytes: Int = 20_000_000, readingsMaxBytes: Int = 50_000_000, keepDays: Int = 14,
                everySecond: Bool = false, now: Date = Date()) {
        self.init(directory: directory, prefix: prefix, machine: machine, about: about, maxBytes: maxBytes,
                  readingsMaxBytes: readingsMaxBytes, keepDays: keepDays, everySecond: everySecond, now: now,
                  openFile: { try FileHandle(forWritingTo: $0) })
    }

    init(directory: URL, prefix: String, machine: String = "", about: String = "RemSound for Mac",
         maxBytes: Int = 20_000_000, readingsMaxBytes: Int = 50_000_000, keepDays: Int = 14,
         everySecond: Bool = false, now: Date = Date(), openFile: @escaping (URL) throws -> FileHandle) {
        self.directory = directory
        self.prefix = prefix
        self.machine = machine
        self.about = about
        self.maxBytes = maxBytes
        self.readingsMaxBytes = readingsMaxBytes
        self.keepDays = keepDays
        self.everySecond = everySecond
        self.openFile = openFile
        var stem = "\(prefix)-\(Self.named.string(from: now))" + (machine.isEmpty ? "" : "-\(machine)")
        // Two runs in one minute: the second gets -2, and so on.
        let base = stem
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + ".log").path)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + "-readings.csv").path) {
            stem = "\(base)-\(n)"; n += 1
        }
        self.stem = stem
        prune(now: now)
    }

    /// A line that does not say its own level or category: sorted by its words (`LogLines.classify`).
    public func event(_ text: String, at date: Date = Date()) {
        let c = LogLines.classify(text)
        event(c.level, c.category, c.text, at: date)
    }

    public func event(_ level: LogLevel, _ category: String, _ text: String, at date: Date = Date()) {
        guard !closed else { return }
        if pending.isEmpty && currentFile == nil { pending.append(heading(date)) }
        let today = Self.day.string(from: date)
        if let lastDay, lastDay != today {
            pending.append(LogLines.format(.info, date, "Log", "the date is now \(today)"))
        }
        lastDay = today
        pending.append(LogLines.format(level, date, category, text))
        if pending.count >= 64 { flush() }
    }

    private func heading(_ date: Date) -> String {
        lastDay = Self.day.string(from: date)
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let zone = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        return LogLines.format(.info, date, "Log", "\(about) log for \(machine.isEmpty ? "this Mac" : machine), started "
            + "\(Self.day.string(from: date)). Times are this Mac's (\(zone)). What it measures every second is in "
            + "\(readingsName): a row for every minute, and every second around a problem.")
    }

    /// One second's readings: the machine's row, and a row for each stream, output or peer.
    public func readings(_ machine: ReadingsRow, _ rows: [ReadingsRow] = [], at now: Date = Date()) {
        guard !closed else { return }
        if recorder == nil {
            recorder = ReadingsRecorder(schema: machine.schema, everySecond: everySecond) { [weak self] line in
                self?.writeReadingsLine(line)
            }
        }
        recorder?.second(now, machine: machine, rows: rows)
    }

    /// Keep every second from `lookBack` ago until 30 seconds from now. Returns the words for the log line that points at
    /// them ("every second from 10:02:31 to 10:08:01 goes in ...-readings.csv"), nil before anything was measured.
    @discardableResult
    public func capture(lookBack: TimeInterval, at now: Date = Date()) -> String? {
        guard !closed, let recorder else { return nil }
        let span = recorder.capture(now, lookBack: lookBack)
        return "every second from \(Self.clock.string(from: span.from)) to \(Self.clock.string(from: span.to)) goes in \(readingsName)"
    }

    /// Write every readings row that is going to be written, now. `closing`: the minute still open is summed up too.
    public func flushReadings(closing: Bool = false, at now: Date = Date()) {
        recorder?.flush(now, closeMinute: closing)
    }

    private func writeReadingsLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        if readingsHandle == nil || (readingsWritten + data.count > readingsMaxBytes && readingsWritten > 0) {
            let rolling = readingsHandle != nil
            try? readingsHandle?.close()
            readingsHandle = nil
            if rolling { readingsPart += 1 }
            let url = directory.appendingPathComponent(stem + "-readings" + (readingsPart > 1 ? "-part\(readingsPart)" : "") + ".csv")
            (readingsHandle, readingsWritten) = open(url)
            currentReadingsFile = readingsHandle == nil ? nil : url
            if rolling || readingsWritten == 0, let recorder, !line.hasPrefix("Time,") {
                let header = Data((recorder.headerLine + "\n").utf8)
                guard write(header, to: readingsHandle) else {
                    readingsHandle = nil; currentReadingsFile = nil
                    return
                }
                readingsWritten += header.count
            }
        }
        guard write(data, to: readingsHandle) else {
            readingsHandle = nil; currentReadingsFile = nil
            return
        }
        readingsWritten += data.count
    }

    /// Write what is waiting (the session calls it once a second, and when stopping).
    public func flush() {
        guard !pending.isEmpty else { return }
        var batch = Data()
        for line in pending {
            let data = Data((line + "\n").utf8)
            if handle == nil || (written + batch.count + data.count > maxBytes && written + batch.count > 0) {
                if let handle, !batch.isEmpty {
                    if write(batch, to: handle) { written += batch.count }
                    else { self.handle = nil; currentFile = nil }
                }
                batch = Data()
                let rolling = handle != nil
                try? handle?.close()
                handle = nil
                if rolling { part += 1 }
                let url = directory.appendingPathComponent(stem + (part > 1 ? "-part\(part)" : "") + ".log")
                (handle, written) = open(url)
                currentFile = handle == nil ? nil : url
            }
            batch.append(data)
        }
        pending = []
        guard let handle else { return }
        if write(batch, to: handle) { written += batch.count }
        else { self.handle = nil; currentFile = nil }
    }

    private func write(_ data: Data, to handle: FileHandle?) -> Bool {
        guard let handle else { return false }
        do { try handle.write(contentsOf: data); return true }
        catch { try? handle.close(); return false }
    }

    /// Stop. `keepReadings`: what waits is written first (RemSound stopping); false lets it go (logging switched off -
    /// nothing may reach the file after that).
    public func close(keepReadings: Bool = true, at now: Date = Date()) {
        if keepReadings { flushReadings(closing: true, at: now) } else { recorder?.forget() }
        flush()
        closed = true
        try? handle?.close()
        handle = nil
        try? readingsHandle?.close()
        readingsHandle = nil
    }

    private func open(_ url: URL) -> (FileHandle?, Int) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? openFile(url)
        _ = try? handle?.seekToEnd()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return (handle, size)
    }

    /// Remove this app's logs and readings older than `keepDays`, never this run's own.
    public func prune(now: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix + "-") && (name.hasSuffix(".log") || name.hasSuffix(".csv"))
            && !name.hasPrefix(stem) {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(modified) > Double(keepDays) * 86_400 { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// The once-a-second figures, worded as the Windows RemSound words its own ("streams [...]"), so one reading of either
/// log serves both.
public enum JamLogLines {
    /// One incoming stream this second.
    public struct Stream: Equatable {
        public var peer: String
        public var stream: UInt16
        public var codec: String
        public var frames: Int
        public var packets: Int
        public var maxGapMs: Double
        public var concealed: Int
        public var underruns: Int
        public var queuedMs: Int
        public var targetMs: Int
        /// The sender's clock against ours, while clocks are being kept (nil: they are not).
        public var clock: Clock?
        public init(peer: String, stream: UInt16, codec: String, frames: Int, packets: Int, maxGapMs: Double, concealed: Int,
                    underruns: Int, queuedMs: Int, targetMs: Int, clock: Clock? = nil) {
            self.peer = peer; self.stream = stream; self.codec = codec; self.frames = frames; self.packets = packets
            self.maxGapMs = maxGapMs; self.concealed = concealed; self.underruns = underruns; self.queuedMs = queuedMs
            self.targetMs = targetMs; self.clock = clock
        }
    }

    /// One clock against another: measured, in parts per million, or still being measured (the first ten seconds).
    public struct Clock: Equatable {
        public var ppm: Double?
        public init(ppm: Double?) { self.ppm = ppm }
        public var text: String { ppm.map { "clock=" + String(format: "%+d", Int($0.rounded())) + "ppm" } ?? "clock=measuring" }
    }

    /// An output card this second: its clock against the mix's, the cushion held for it, and what keeping it cost - the
    /// silence laid down, the sound cut, the times it ran dry (all since the output started).
    public static func outputCard(ppm: Double?, cushionFrames: Int, laidFrames: Int, cutFrames: Int, ranDry: Int) -> String {
        func ms(_ frames: Int) -> String { String(format: "%.1f", Double(frames) / 48) + "ms" }
        return "\(Clock(ppm: ppm).text) cushion=\(ms(cushionFrames)) laid=\(ms(laidFrames)) cut=\(ms(cutFrames)) ran-dry=\(ranDry)"
    }

    public static func streams(_ streams: [Stream], sending: String) -> String {
        let each = streams.map {
            "\($0.peer) stream=\($0.stream) \($0.codec) \($0.frames) frames pkts=\($0.packets) gap-peak=\(Int($0.maxGapMs.rounded()))ms "
                + "concealed=\($0.concealed) underruns=\($0.underruns) queued=\($0.queuedMs)ms target=\($0.targetMs)ms"
                + ($0.clock.map { " " + $0.text } ?? "")
        }
        return "streams: \(sending); " + (each.isEmpty ? "nothing received" : each.joined(separator: " | "))
    }

    /// A peer's total latency, as Windows says it in its status: how long from their input to your ears - their capture,
    /// the packet's filling, half the round trip, your buffer and your output.
    public static func totalLatencyMs(captureMs: Double, packetMs: Double, rttMs: Double, bufferMs: Double, outputMs: Double) -> Double {
        captureMs + packetMs + rttMs / 2 + bufferMs + outputMs
    }

    public static func peer(_ name: String, rttMs: Double?, totalMs: Double?) -> String {
        guard let rttMs else { return "\(name): not measured yet" }
        let total = totalMs.map { ", total latency about \(Int($0.rounded())) ms" } ?? ""
        return "\(name): ping \(Int(rttMs.rounded())) ms\(total)"
    }
}
