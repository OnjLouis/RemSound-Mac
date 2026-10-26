import AppKit
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor final class LoggingPreferencesTests: XCTestCase {
    func testActualLoggingButtonsHaveNamesHelpKeyboardOrderAndNativeActions() throws {
        XCTAssertNil(AppRuntime.configuration, "Run this owner test in its own isolated process")
        let base = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]))
        let root = base.appendingPathComponent("logging-controls-\(UUID())")
        try AppRuntime.prepare(LaunchOptions.parse(["--silent", "--config-dir", root.path]))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(AppRuntime.configuration.isIsolated)
        _ = NSApplication.shared
        let controls = PreferencesExtras(), stack = NSStackView()
        controls.addControls(to: stack)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = stack
        stack.layoutSubtreeIfNeeded()
        defer { window.close() }
        XCTAssertFalse(window.isVisible, "The native controls are hosted without showing or focusing a window")
        let buttons = [controls.writeLogsNow, controls.openCurrentLog, controls.openLogsFolder]
        XCTAssertEqual(buttons.map(\.title), ["Write logs now", "Open current log", "Open logs folder"])
        let index = try XCTUnwrap(controls.controlOrder.firstIndex { $0 === controls.writeLogsNow })
        XCTAssertEqual(Array(controls.controlOrder[index..<(index + 3)]).map(ObjectIdentifier.init), buttons.map(ObjectIdentifier.init))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manual = FocusedHelpContent.Manual(try String(contentsOf: source.appendingPathComponent("README.md")))
        for button in buttons {
            // AppKit exposes the button cell, rather than its ignored NSControl wrapper, to accessibility clients.
            XCTAssertEqual(button.cell?.accessibilityRole(), .button)
            XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true)
            XCTAssertFalse(button.accessibilityHelp()?.isEmpty ?? true)
            XCTAssertTrue(button.isDescendant(of: stack))
            XCTAssertNotNil(manual.entry(try XCTUnwrap(FocusedHelpContent.key(of: button))))
            XCTAssertTrue(button.target as AnyObject? === controls)
            XCTAssertNotNil(button.action)
        }
        var writes = 0, opens = 0, folders = 0, hasLog = false
        var announcements: [String] = []
        controls.writeLogs = { writes += 1 }
        controls.openLog = { opens += 1; return hasLog }
        controls.openFolder = { folders += 1 }
        controls.announce = { announcements.append($0) }
        controls.writeLogsNow.performClick(nil)
        controls.openCurrentLog.performClick(nil)
        XCTAssertEqual(writes, 1); XCTAssertEqual(opens, 1)
        XCTAssertEqual(announcements.last, "No log is being written. Turn on logging first.")
        hasLog = true
        let before = announcements.count
        controls.openCurrentLog.performClick(nil)
        controls.openLogsFolder.performClick(nil)
        XCTAssertEqual(opens, 2); XCTAssertEqual(folders, 1)
        XCTAssertEqual(announcements.count, before)
    }
}
