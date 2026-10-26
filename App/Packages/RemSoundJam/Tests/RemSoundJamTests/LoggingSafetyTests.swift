import Foundation
import XCTest
@testable import RemSoundJam

final class LoggingSafetyTests: XCTestCase {
    func testSpreadsheetTextCannotBecomeAFormula() {
        for text in ["=1+1", "+SUM(1,2)", "-2+3", "@SUM(A1)", " \t=1+1"] {
            let escaped = ReadingsSchema.csv(text)
            XCTAssertTrue(escaped.hasPrefix("'") || escaped.hasPrefix("\"'"), escaped)
        }
        XCTAssertEqual(ReadingsSchema.csv("Peer, one"), "\"Peer, one\"")
        XCTAssertEqual(ReadingsSchema.number(-2.5), "-2.5", "numeric readings remain numeric")
    }

    func testFailedEventWriteDoesNotCrashAndCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("event-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = true
        let log = JamLog(directory: root, prefix: "events", openFile: { url in
            let handle = try FileHandle(forWritingTo: url)
            if fail { fail = false; try handle.close() }
            return handle
        })
        log.event("first event"); log.flush()
        log.event("recovered event"); log.flush(); log.close()
        let text = try String(contentsOf: try XCTUnwrap(log.currentFile), encoding: .utf8)
        XCTAssertTrue(text.contains("recovered event"))
    }

    func testFailedReadingsWriteRecoversWithAHeaderAndLeavesEventsWorking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("readings-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = true
        let log = JamLog(directory: root, prefix: "readings", everySecond: true, openFile: { url in
            let handle = try FileHandle(forWritingTo: url)
            if url.pathExtension == "csv", fail { fail = false; try handle.close() }
            return handle
        })
        let schema = ReadingsSchema([ReadingColumn("packets", .sum)])
        let row = ReadingsRow(schema, groupsInUse: []); row.set("packets", 12)
        log.readings(row); log.readings(row)
        log.event("events still work"); log.flush(); log.close()
        let text = try String(contentsOf: try XCTUnwrap(log.currentReadingsFile), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(schema.header() + "\n"))
        XCTAssertTrue(text.contains(",12"))
        XCTAssertTrue(try String(contentsOf: try XCTUnwrap(log.currentFile)).contains("events still work"))
    }
}
