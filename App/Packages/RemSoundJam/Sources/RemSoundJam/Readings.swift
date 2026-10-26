import Foundation

/// How a column's seconds are summed up into its minute row.
public enum ReadingAgg: Sendable {
    /// Counts added up.
    case sum
    /// The highest (peaks, the longest gap).
    case max
    /// The lowest (how far a buffer fell).
    case min
    /// The average (levels).
    case mean
    /// As the minute ended (running totals, settings).
    case last
    /// Second rows only: long words that would swamp a minute row (the Mac's own deep-dive observations).
    case secondsOnly
}

/// One column of the readings file: its name, how a minute sums it up, what it belongs to ("" is always in use) and
/// whether it holds words rather than a number.
public struct ReadingColumn: Sendable {
    public let name: String
    public let agg: ReadingAgg
    public let group: String
    public let text: Bool
    public init(_ name: String, _ agg: ReadingAgg, group: String = "", text: Bool = false) {
        self.name = name; self.agg = agg; self.group = group; self.text = text
    }
}

/// The columns of a readings file (Windows 6.2.3, issue 35 there): `Time,Kind,Stream,Output,` and then these, one CSV
/// row a line, which opens in a spreadsheet.
public struct ReadingsSchema: Sendable {
    public let columns: [ReadingColumn]
    let index: [String: Int]
    public init(_ columns: [ReadingColumn]) {
        self.columns = columns
        var index: [String: Int] = [:]
        for (i, c) in columns.enumerated() { index[c.name] = i }
        self.index = index
    }

    public func header() -> String { (["Time", "Kind", "Stream", "Output"] + columns.map(\.name)).joined(separator: ",") }

    /// A field as CSV has it: quoted when it holds a comma, a quote or a line break.
    public static func csv(_ field: String) -> String {
        // Peer-controlled text must stay text when a spreadsheet opens the CSV.
        let first = field.drop(while: { $0.isWhitespace }).first
        let field = first.map { "=+-@".contains($0) } == true ? "'" + field : field
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A number as the file has it: up to three decimals, no trailing zeros, nothing for one that is not a number.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

/// One second's readings: for the machine, or one stream (`stream`) on one output (`output`). A value is kept only when
/// what its column belongs to is in use (Ed: readings "only get logged when they get turned on") - an output not in
/// use, a send not sending, leave their cells empty, while a zero for something that is in use is written as a zero.
public final class ReadingsRow {
    public let schema: ReadingsSchema
    public var stream: String
    public var output: String
    public internal(set) var numbers: [Double?]
    public internal(set) var texts: [String?]
    /// Names set that the schema does not have (a test catches these).
    public private(set) var unknown: [String] = []
    private let inUse: Set<String>

    public init(_ schema: ReadingsSchema, groupsInUse: [String], stream: String = "", output: String = "") {
        self.schema = schema
        self.stream = stream
        self.output = output
        numbers = Array(repeating: nil, count: schema.columns.count)
        texts = Array(repeating: nil, count: schema.columns.count)
        inUse = Set(groupsInUse + [""])
    }

    private func slot(_ name: String) -> Int? {
        guard let i = schema.index[name] else { unknown.append(name); return nil }
        return inUse.contains(schema.columns[i].group) ? i : nil
    }

    public func set(_ name: String, _ value: Double?) {
        guard let value, let i = slot(name) else { return }
        numbers[i] = value
    }
    public func set(_ name: String, _ value: Int?) { set(name, value.map(Double.init)) }
    public func set(_ name: String, _ value: Bool) { set(name, value ? 1.0 : 0.0) }
    public func text(_ name: String, _ value: String?) {
        guard let value, let i = slot(name) else { return }
        texts[i] = value
    }

    /// A cell as the file will have it ("" when not in use or not set).
    public func cell(_ name: String) -> String {
        guard let i = schema.index[name] else { return "" }
        if schema.columns[i].text { return texts[i] ?? "" }
        return numbers[i].map(ReadingsSchema.number) ?? ""
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// The row as a CSV line, at `time`, of `kind` ("second" or "minute").
    public func line(_ time: Date, kind: String) -> String {
        var fields = [Self.stamp.string(from: time), kind, ReadingsSchema.csv(stream), ReadingsSchema.csv(output)]
        for (i, c) in schema.columns.enumerated() {
            fields.append(c.text ? ReadingsSchema.csv(texts[i] ?? "") : (numbers[i].map(ReadingsSchema.number) ?? ""))
        }
        return fields.joined(separator: ",")
    }
}
