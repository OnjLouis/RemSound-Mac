import Foundation
import XCTest
import RemSoundCore
@testable import RemSoundApp

@MainActor final class NativeEventClaimsTests: XCTestCase {
    private let file = "App/Sources/RemSoundApp/Window.swift"
    private let reason = "The actual named native driver calls this file's production event routine."
    func testCurrentProductionRegistryMatchesActualSourceWithoutClaimingPendingDrivers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var sources: [String: String] = [:]
        for directory in ["App/Sources", "App/Packages/RemSoundJam/Sources", "App/Packages/RemSoundRuntime/Sources", "Plugin/Source"] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(directory),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
            for case let file as URL in files where ["swift", "c", "h", "cpp", "mm"].contains(file.pathExtension) {
                sources[String(file.path.dropFirst(root.path.count + 1))] = try String(contentsOf: file)
            }
        }
        let counts = NativeEventClaims.census(sources)
        let result = NativeEventClaims.inspect(sources: sources, stepNames: ProductTestPack.names)
        XCTAssertEqual(result.failures.filter { !$0.hasPrefix("events.native.unverified-driver-") }, [], "Actual counts: \(counts)")
        XCTAssertFalse(result.failures.isEmpty, "Pending native drivers must remain explicitly unverified")
    }
    func testSelectorsDelegatesClosuresTimersAndSwiftUIButtonCountOnOneLine() {
        let code = """
            // ignored.action = #selector(no)
            let caption = "fake.onChange = handler"
            if ready { b.action = #selector(clicked); field.delegate = self; c.onChange = handler }
            table.rename = { rename() }
            c.onChange = nil; b.target = self; total += n
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            center.addObserver(forName: nil, object: nil, queue: nil) { _ in }
            Button("Do") { run() }
            """
        XCTAssertEqual(NativeEventClaims.census([file: code]), [file: 7])
    }
    func testNativeAndOrdinaryBootstrapFilesCannotHideBehindTestExclusions() {
        let cpp = "Plugin/Source/Processor.cpp", bootstrap = "App/Sources/RemSoundApp/BootstrapPluginCommand.swift"
        let found = NativeEventClaims.census([
            cpp: "help.onClick = [this] {}; startTimerHz(2);",
            bootstrap: "timer.setEventHandler { tick() }",
            "Plugin/Tests/EditorTests.cpp": "help.onClick = [this] {};",
            "App/Sources/AudioSupport/vendor/library.h": "timer.setEventHandler {}"
        ])
        XCTAssertEqual(found, [cpp: 2, bootstrap: 1])
    }
    func testGateLikeNewNamesAreNotBlanketExcluded() {
        for file in ["App/Sources/RemSoundCore/ProductNewFeature.swift", "App/Sources/RemSoundApp/NativeEventClaimsExtra.swift", "Plugin/Source/ProductTestPack.cpp"] {
            XCTAssertEqual(NativeEventClaims.census([file: "timer.setEventHandler { tick() }"]), [file: 1])
        }
    }
    func testParsedCommandActionExclusionDoesNotHideOtherNativeWiring() {
        for command in NativeEventClaims.nonEventActions.keys {
            XCTAssertEqual(NativeEventClaims.census([command: "request.action = .status; field.delegate = self"]), [command: 1])
        }
    }
    func testMissingStaleAndCountDriftClaimsRefuse() {
        let source = [file: "field.delegate = self"]
        let missing = NativeEventClaims.inspect(sources: source, claims: [], stepNames: ProductTestPack.names)
        XCTAssertTrue(missing.failures.contains { $0.contains("unclaimed-") })
        let stale = NativeEventClaims.inspect(sources: source, claims: [.init(file: "Deleted.swift", count: 1, coverage: .exempt, reason: reason)], stepNames: ProductTestPack.names)
        XCTAssertTrue(stale.failures.contains { $0.contains("stale-claim-") })
        let drift = NativeEventClaims.inspect(sources: source, claims: [.init(file: file, count: 2, coverage: .exempt, reason: reason)], stepNames: ProductTestPack.names)
        XCTAssertTrue(drift.failures.contains { $0.contains("count-drift-") })
    }
    func testEveryClaimedDriverMustNameARealStepAndExemptionsNeedAReason() {
        let source = [file: "field.delegate = self"]
        for steps in [[], ["deleted product step"]] {
            let result = NativeEventClaims.inspect(sources: source, claims: [.init(file: file, count: 1, coverage: .driven, reason: reason, steps: steps)], stepNames: ProductTestPack.names)
            XCTAssertTrue(result.failures.contains { $0.contains(steps.isEmpty ? "nameless-driver-" : "unknown-step-") })
        }
        let bare = NativeEventClaims.inspect(sources: source, claims: [.init(file: file, count: 1, coverage: .exempt, reason: "no test")], stepNames: ProductTestPack.names)
        XCTAssertTrue(bare.failures.contains { $0.contains("bare-reason-") })
    }
    func testPendingProofIsNotAnExemptionAndCannotBecomePass() {
        let source = [file: "field.delegate = self"]
        let result = NativeEventClaims.inspect(sources: source, claims: [.init(file: file, count: 1, coverage: .pending, reason: reason)], stepNames: ProductTestPack.names)
        XCTAssertEqual(result.failures.count, 1); XCTAssertTrue(result.failures[0].contains("unverified-driver-"))
        let empty = NativeEventClaims.inspect(sources: [:], claims: [], stepNames: [])
        XCTAssertTrue(empty.failures.contains("events.native.empty-source-census"))
        XCTAssertTrue(empty.failures.contains("events.native.empty-or-duplicate-step-catalog"))
    }
}
