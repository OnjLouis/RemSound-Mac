import Foundation

@MainActor
enum NativeEventClaims {
    enum Coverage: Equatable { case driven, pending, exempt }
    struct Claim {
        let file: String
        let count: Int
        let coverage: Coverage
        let reason: String
        var steps: [String] = []
    }
    // These are registration tokens, not a claim about the number of runtime invocations.
    // Overlapping selector/property matches count once; ordinary arithmetic and removals do not.
    static let actionPattern = #"\.\s*(?:action|doubleAction)\s*=(?!=)(?!\s*nil\b)\s*(?:[#@]selector\s*\(|[^\s;]+)"#
    static let patterns = [
        #"(?:#|@)selector\s*\("#,
        #"\.\s*(?:delegate|dataSource|terminationHandler|readabilityHandler|writeabilityHandler|on[A-Z]\w*)\s*=(?!=)(?!\s*nil\b)\s*(?:[#@]selector\s*\(|[^\s;]+)"#,
        actionPattern,
        #"\.\s*\w+\s*=(?!=)\s*(?:\[[^\]\r\n]*\]\s*)?\{"#,
        #"\bdelegate\s*:(?!\s*nil\b)"#,
        #"\b(?:setEventHandler|setCancelHandler|scheduledTimer|addObserver|addLocalMonitorForEvents|addGlobalMonitorForEvents|tapCreate|InstallEventHandler|AudioObjectAddPropertyListener|AudioObjectAddPropertyListenerBlock|AudioUnitAddPropertyListener|AudioDeviceCreateIOProcID|AudioDeviceCreateIOProcIDWithBlock|installTap|addStreamOutput|setSampleBufferDelegate|addListener|addParameterListener|startTimer|startTimerHz|FLAC__stream_encoder_init_stream)\s*(?:\(|\{)"#,
        #"\.\s*(?:asyncAfter|onReceive|onChange|onAppear|onDisappear|sink)\s*(?:\(|\{)"#,
        #"\bButton\s*(?:\(|\{)"#,
        #"\bkAudioUnitProperty_SetRenderCallback\b|\bkAudioOutputUnitProperty_SetInputCallback\b"#
    ]
    static let nonEventActions = [
        "App/Packages/RemSoundRuntime/Sources/RemSoundRuntime/ControlCommand.swift": "The action field stores a parsed command value; it is not a native target/action subscription.",
        "App/Sources/RemSoundApp/BrowserCredentialAccess.swift": "The action field stores a credential-operation enum; it is not a native target/action subscription.",
        "App/Sources/RemSoundCore/BrowserListenerService.swift": "The action field stores an address-request enum; it is not a native target/action subscription.",
        "App/Sources/RemSoundCore/UPnPMappingCreation.swift": "The action field stores a lease-operation enum; it is not a native target/action subscription."
    ]
    static func isProduction(_ file: String) -> Bool {
        let components = file.split(separator: "/").map(String.init)
        guard !components.contains(where: { ["Tests", "Tools", "vendor", ".build"].contains($0) }),
            ["swift", "c", "h", "cpp", "mm"].contains((file as NSString).pathExtension) else { return false }
        // The gate's own callbacks are observations, not product event wiring.
        let appFixtures = ["BootstrapEventClaims.swift", "BootstrapDialogAudit.swift", "BootstrapProfileLogging.swift", "BootstrapControlSpecifications.swift", "MainWindowControlAudit.swift", "NativeDialogAudit.swift", "NativeEventClaims.swift"]
        let coreFixtures = ["ProductAudioRoundTrip.swift", "ProductControlSpecifications.swift", "ProductDialogAudit.swift", "ProductHeartbeat.swift", "ProductEventClaims.swift", "ProductPCMReceiverChecks.swift", "ProductPluginInstallation.swift", "ProductNamedPeerCheck.swift", "ProductTestPack.swift", "ProductTestCatalog.swift", "ProductSelfCheck.swift", "ProductSecurityChecks.swift", "ProductReplayRoundTrip.swift", "ProductReplayCheck.swift", "ProductProfileLogging.swift"]
        return !appFixtures.contains(where: { file == "App/Sources/RemSoundApp/" + $0 }) &&
            !coreFixtures.contains(where: { file == "App/Sources/RemSoundCore/" + $0 })
    }
    static func census(_ sources: [String: String]) -> [String: Int] {
        var result = [String: Int]()
        for (file, text) in sources where isProduction(file) {
            let code = NativeDialogAudit.codeOnly(text)
            let length = (code as NSString).length
            var intervals = [NSRange]()
            for pattern in patterns {
                if pattern == actionPattern && nonEventActions[file] != nil { continue }
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                intervals += regex.matches(in: code, range: NSRange(location: 0, length: length)).map(\.range)
            }
            var merged = [NSRange]()
            for range in intervals.sorted(by: { $0.location < $1.location }) {
                if let last = merged.last, NSMaxRange(last) > range.location {
                    merged[merged.count - 1] = NSUnionRange(last, range)
                } else { merged.append(range) }
            }
            if !merged.isEmpty { result[file] = merged.count }
        }
        return result
    }
    static func inspect(sources: [String: String], claims: [Claim]? = nil, stepNames: [String]) -> (assertions: Int, failures: [String]) {
        let productionRegistry = claims == nil
        let claims = claims ?? reviewed
        let found = census(sources)
        var assertions = 0, failures = [String]()
        func require(_ condition: Bool, _ code: String) { assertions += 1; if !condition { failures.append("events.native." + code) } }
        func id(_ file: String) -> String { file.replacingOccurrences(of: "/", with: ".") }
        require(!found.isEmpty, "empty-source-census")
        require(!patterns.isEmpty && patterns.allSatisfy { (try? NSRegularExpression(pattern: $0)) != nil }, "invalid-wiring-pattern")
        require(stepNames.count > 100 && Set(stepNames).count == stepNames.count, "empty-or-duplicate-step-catalog")
        require(Set(claims.map(\.file)).count == claims.count, "duplicate-file-claim")
        if productionRegistry {
            for (file, reason) in nonEventActions {
                let code = sources[file].map(NativeDialogAudit.codeOnly) ?? ""
                let count = (try? NSRegularExpression(pattern: actionPattern))?.numberOfMatches(in: code, range: NSRange(location: 0, length: (code as NSString).length)) ?? 0
                require(count > 0 && reason.count >= 40, "stale-non-event-" + id(file))
            }
        }
        let claimed = Set(claims.map(\.file))
        for (file, count) in found.sorted(by: { $0.key < $1.key }) {
            require(claimed.contains(file), "unclaimed-" + id(file) + "-" + String(count))
        }
        for claim in claims {
            require(found[claim.file] != nil, "stale-claim-" + id(claim.file))
            require(found[claim.file] == claim.count, "count-drift-" + id(claim.file))
            require(claim.reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40, "bare-reason-" + id(claim.file))
            if claim.coverage == .driven { require(!claim.steps.isEmpty, "nameless-driver-" + id(claim.file)) }
            for step in claim.steps { require(stepNames.contains(step), "unknown-step-" + id(claim.file)) }
            if claim.coverage == .pending { failures.append("events.native.unverified-driver-" + id(claim.file)) }
        }
        return (assertions, failures)
    }
    static let reviewed: [Claim] = [
        .init(file: "App/Sources/RemSoundApp/PreferencesExtras.swift", count: 14, coverage: .pending, reason: "Logging, diagnostic and preference actions have isolated native checks; complete file-wide named event-driver coverage remains unjoined."),
        .init(file: "App/Sources/RemSoundApp/MetronomeSettingsWindow.swift", count: 13, coverage: .pending, reason: "Transactional metronome controls have related native cases; full file-wide named callback and keyboard evidence remains unjoined."),
        .init(file: "App/Sources/RemSoundApp/UpdateService.swift", count: 2, coverage: .pending, reason: "Scheduled updater callbacks have isolated update evidence; complete named timer and notification driver coverage remains unjoined."),
        .init(file: "App/Packages/RemSoundJam/Sources/RemSoundSim/MacSimulation.swift", count: 1, coverage: .pending, reason: "The queue event-log closure is real production replay code; its named callback assertion and full event proof are not yet joined."),
        .init(file: "App/Sources/AudioSupport/FLACEncoder.c", count: 1, coverage: .pending, reason: "The native encoder write callback needs its actual recording named driver joined; format tests alone are not this event receipt."),
        .init(file: "App/Sources/RemSoundApp/AppDelegate.swift", count: 208, coverage: .pending, reason: "Actual Root bindings and Preferences logging have product receipts; the remaining file-wide action, lifecycle and timer driver clauses are open."),
        .init(file: "App/Sources/RemSoundApp/AppEntry.swift", count: 40, coverage: .pending, reason: "The SwiftUI command and menu closures need their actual menu driver joined; a catalog name or constructor is not an event effect."),
        .init(file: "App/Sources/RemSoundApp/BrowserListenerWindow.swift", count: 14, coverage: .pending, reason: "Preview, Cancel, context and address native cases exist; their complete named dialog event-driver clauses remain unverified."),
        .init(file: "App/Sources/RemSoundApp/BrowserProfileTransaction.swift", count: 3, coverage: .pending, reason: "Preview and retirement callbacks have actual isolated transaction cases; the corresponding complete named event caller remains unjoined."),
        .init(file: "App/Sources/RemSoundApp/ConnectivityPeerControls.swift", count: 14, coverage: .pending, reason: "Peer add, cancel, selection and remembered-list callback cases exist; the complete named control-driver receipt is still missing."),
        .init(file: "App/Sources/RemSoundApp/CoreGraphicsPushToTalkBackend.swift", count: 1, coverage: .pending, reason: "The OS event-tap subscription is not installed by this source fixture; native hook and callback-body evidence need a separate exact join."),
        .init(file: "App/Sources/RemSoundApp/CuePreferencesPane.swift", count: 3, coverage: .pending, reason: "Cue mute and keyboard-click native controls have related cases; the actual complete named preference-event caller remains unjoined."),
        .init(file: "App/Sources/RemSoundApp/FocusedHelpWindow.swift", count: 6, coverage: .pending, reason: "The real help window is constructed, but constructor reachability is not its keyboard and manual-button event effect."),
        .init(file: "App/Sources/RemSoundApp/GlobalHotkeyManager.swift", count: 3, coverage: .pending, reason: "Carbon registration and key-repeat timer ownership require an actual native driver join; this source scan installs no global input."),
        .init(file: "App/Sources/RemSoundApp/JamController.swift", count: 7, coverage: .pending, reason: "Server and metronome callback wiring includes unfinished product callers; existing grid primitives do not prove those events."),
        .init(file: "App/Sources/RemSoundApp/NamedPeersWindow.swift", count: 10, coverage: .pending, reason: "Rename, delete and selection native cases are real; their full named management event-driver receipt is not consumed here."),
        .init(file: "App/Sources/RemSoundApp/PeerEqControls.swift", count: 1, coverage: .pending, reason: "The real weak-delegate preview fields have a native regression; the named EQ dialog event effect remains unregistered."),
        .init(file: "App/Sources/RemSoundApp/PushToTalkInputOwner.swift", count: 1, coverage: .pending, reason: "Input-registration failure forwarding has isolated ownership cases; named event evidence must be joined without installing global hooks."),
        .init(file: "App/Sources/RemSoundApp/PushToTalkPreview.swift", count: 1, coverage: .pending, reason: "Preview startup and failure forwarding have isolated cases; the actual named preview event receipt remains to be joined."),
        .init(file: "App/Sources/RemSoundApp/PushToTalkSettingsWindow.swift", count: 9, coverage: .pending, reason: "Actual control and keyboard cases are retained, but complete named PTT window event consumption remains unverified."),
        .init(file: "App/Sources/RemSoundApp/QuickProfileSwitchWindow.swift", count: 7, coverage: .pending, reason: "Actual construction and historical workflow evidence exist; current named selection and close event proof still needs joining."),
        .init(file: "App/Sources/RemSoundApp/RouterMappingControls.swift", count: 3, coverage: .pending, reason: "Checkbox, owner-change and wake forwarding have owned cases; their complete named control-event join is not established."),
        .init(file: "App/Sources/RemSoundApp/ServerConnectionNoticeWindow.swift", count: 5, coverage: .pending, reason: "Acknowledgment, retry and retirement native cases are real; complete named dialog-event consumption is not established."),
        .init(file: "App/Sources/RemSoundApp/ServerVersionWarningWindow.swift", count: 7, coverage: .pending, reason: "Connect, Cancel and validated Visit actions have native cases; their actual named driver join remains unverified."),
        .init(file: "App/Sources/RemSoundApp/ServerWindowController.swift", count: 12, coverage: .pending, reason: "Remembered-list and server action wiring needs its complete named driver join; the source fixture connects to no server."),
        .init(file: "App/Sources/RemSoundApp/TypingAudioOutput.swift", count: 1, coverage: .pending, reason: "The output configuration-change observer is not a device acceptance receipt; native recovery event evidence needs its own join."),
        .init(file: "App/Sources/RemSoundApp/TypingEventMonitor.swift", count: 2, coverage: .pending, reason: "Local key-monitor registration has isolated input cases; named event proof must be joined without capturing normal typing."),
        .init(file: "App/Sources/RemSoundApp/UIResponsivenessMonitor.swift", count: 2, coverage: .pending, reason: "Timer retirement and diagnostic preference cases exist; the named timer-event and action observation proof remains unjoined."),
        .init(file: "App/Sources/RemSoundCore/Audio.swift", count: 2, coverage: .pending, reason: "Capture tap and injected callback forwarding require exact native event proof; device-free receiver checks do not establish live capture."),
        .init(file: "App/Sources/RemSoundCore/BrowserListenerService.swift", count: 1, coverage: .pending, reason: "Controlled listener callbacks have retained owned native cases; complete named event-driver consumption remains unjoined."),
        .init(file: "App/Sources/RemSoundCore/CaptureRetirements.swift", count: 1, coverage: .pending, reason: "Retirement timer ownership has isolated cases; an actual named lifetime/event receipt still needs to be joined."),
        .init(file: "App/Sources/RemSoundCore/CaptureWakeAttachment.swift", count: 2, coverage: .pending, reason: "Wake source and cancel-handler ownership have isolated cases; complete named callback retirement proof remains unjoined."),
        .init(file: "App/Sources/RemSoundCore/DNSAddressLookup.swift", count: 1, coverage: .pending, reason: "Owned lookup deadline behavior has related cases; actual named lookup timer-event evidence still needs its exact join."),
        .init(file: "App/Sources/RemSoundCore/DirectInputCallback.swift", count: 1, coverage: .pending, reason: "The native audio IO registration is not invoked by this source fixture; real callback and owned adapter evidence remain separate."),
        .init(file: "App/Sources/RemSoundCore/DirectPeerResolver.swift", count: 1, coverage: .pending, reason: "Lookup completion forwarding has related production cases; the actual named resolver event driver has not been joined."),
        .init(file: "App/Sources/RemSoundCore/DirectedPeerDiscovery.swift", count: 1, coverage: .pending, reason: "Directed discovery completion forwarding has related cases; its exact named event receipt remains unjoined."),
        .init(file: "App/Sources/RemSoundCore/RouterHTTPTransport.swift", count: 1, coverage: .pending, reason: "URLSession delegate admission has owned transport cases; full named delegate-event consumption is not established here."),
        .init(file: "App/Sources/RemSoundCore/RouterMappingService.swift", count: 1, coverage: .pending, reason: "Cancellation callbacks have real mapping-service cases; the corresponding named event receipt remains to be joined."),
        .init(file: "App/Sources/RemSoundCore/RouterMappingWorkflow.swift", count: 1, coverage: .pending, reason: "Mapping workflow completion forwarding has retained cases; full named event-driver consumption remains unverified."),
        .init(file: "App/Sources/RemSoundCore/RouterNativeOperations.swift", count: 2, coverage: .pending, reason: "Timer pulse and cancellation adapters are production code; actual named native operation event proof remains unjoined."),
        .init(file: "App/Sources/RemSoundCore/RouterProtocolOperations.swift", count: 2, coverage: .pending, reason: "Owned protocol completion callbacks have retained cases; their exact named event-driver receipt remains unjoined."),
        .init(file: "App/Sources/RemSoundCore/Session.swift", count: 24, coverage: .pending, reason: "Named isolated audio, framing and heartbeat paths exist; other worker, timer and callback clauses remain open at file-wide event depth."),
        .init(file: "App/Sources/RemSoundCore/SystemAudioCapture.swift", count: 1, coverage: .pending, reason: "The Core Audio IO callback registration requires separate native capture evidence; this source fixture opens no capture device."),
        .init(file: "App/Sources/RemSoundCore/UPnPRouterProtocol.swift", count: 1, coverage: .pending, reason: "Owned router protocol completion cases exist; their actual named event-driver consumption remains unjoined."),
        .init(file: "App/Sources/RemSoundCore/UpdateCommand.swift", count: 1, coverage: .pending, reason: "Owned command termination cases exist; the exact named updater command event receipt still needs its current-source join."),
        .init(file: "App/Sources/RemSoundCore/WebNativeListener.swift", count: 7, coverage: .pending, reason: "Owned listener callbacks and retirement have real cases; complete named event-driver consumption is not yet joined."),
        .init(file: "App/Sources/RemSoundCore/WebNativeTransport.swift", count: 3, coverage: .pending, reason: "Owned transport timers and retirement have real cases; their exact named event receipt remains to be joined."),
        .init(file: "Plugin/Source/PluginHelp.mm", count: 2, coverage: .pending, reason: "Native help-window delegate and action cases exist; actual named plugin-help event consumption remains unverified."),
        .init(file: "Plugin/Source/Processor.cpp", count: 2, coverage: .pending, reason: "The JUCE help-button and editor timer need their named native driver join; host or wrapper acceptance is not inferred."),
    ]
}
