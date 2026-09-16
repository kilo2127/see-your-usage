import AppKit
import Carbon
import SeeYourUsageCore

@MainActor
enum SafariLogin {
    static func open(_ url: URL, previousURL: URL?) async throws -> Bool {
        try Task.checkCancellation()
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            throw LLMCenterError.browserUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        do {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty {
                _ = try await NSWorkspace.shared.openApplication(at: safari, configuration: configuration)
            }
            if try await SafariAuthorizationTab.shared.open(url, replacing: previousURL, interactive: true) {
                return true
            }
            // Permission denial still permits a one-time login through Launch Services.
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: configuration)
        } catch let error as LLMCenterError {
            throw error
        } catch {
            throw LLMCenterError.browserUnavailable
        }
        try Task.checkCancellation()
        return false
    }

    static func reconnect(previousURL: URL, authorizationURL: URL) async throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
            throw LLMCenterError.browserTabMissing
        }
        guard try await SafariAuthorizationTab.shared.open(authorizationURL, replacing: previousURL, interactive: false) else {
            throw LLMCenterError.browserAutomationRequired
        }
    }

    static func finishReconnect(authorizationURL: URL) async {
        await SafariAuthorizationTab.shared.closeTemporary(authorizationURL)
    }
}

actor SafariAuthorizationTab {
    static let shared = SafariAuthorizationTab()
    private var temporaryURLs: Set<URL> = []

    func open(_ url: URL, replacing previousURL: URL?, interactive: Bool) throws -> Bool {
        try Task.checkCancellation()
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Safari")
        guard let descriptor = target.aeDesc else { throw LLMCenterError.browserUnavailable }
        let permission = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, interactive)
        guard permission == noErr else { return false }
        try Task.checkCancellation()
        guard let script = NSAppleScript(source: Self.source) else { throw LLMCenterError.browserUnavailable }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: url.absoluteString), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: previousURL?.absoluteString ?? ""), at: 2)
        arguments.insert(NSAppleEventDescriptor(boolean: interactive), at: 3)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "authorize"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        // Register before execution so timeout/cancellation can still clean up a
        // tab created by an Apple event whose reply did not reach us.
        if !interactive { temporaryURLs.insert(url) }
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { throw LLMCenterError.browserAutomationRequired }
            throw LLMCenterError.browserUnavailable
        }
        guard result.booleanValue else { throw LLMCenterError.browserTabMissing }
        return true
    }

    func closeTemporary(_ url: URL) {
        guard temporaryURLs.remove(url) != nil else { return }
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Safari")
        guard let descriptor = target.aeDesc,
              AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false) == noErr,
              let script = NSAppleScript(source: Self.source) else { return }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: url.absoluteString), at: 1)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "finishauthorization"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        _ = script.executeAppleEvent(event, error: &error)
    }

    // URLs are Apple event arguments, never executable source. Cleanup matches
    // the unique device-flow URL and leaves selected/navigated pages alone.
    static let source = """
    on authorize(nextURL, previousURL, interactive)
        with timeout of 10 seconds
            tell application id "com.apple.Safari"
                if not running then return false
                if interactive and previousURL is not "" then
                    repeat with browserWindow in windows
                        repeat with browserTab in tabs of browserWindow
                            if URL of browserTab is previousURL then
                                set URL of browserTab to nextURL
                                if interactive then
                                    set current tab of browserWindow to browserTab
                                    set index of browserWindow to 1
                                    activate
                                end if
                                return true
                            end if
                        end repeat
                    end repeat
                end if
                if not interactive then
                    if (count of windows) is 0 then return false
                    tell front window
                        make new tab at end of tabs with properties {URL:nextURL}
                    end tell
                    return true
                end if
                if (count of windows) is 0 then make new document
                tell front window
                    set authorizationTab to make new tab at end of tabs with properties {URL:nextURL}
                    set current tab to authorizationTab
                end tell
                activate
                return true
            end tell
        end timeout
    end authorize

    on finishauthorization(authorizationURL)
        with timeout of 10 seconds
            tell application id "com.apple.Safari"
                if not running then return
                set matches to {}
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        if URL of browserTab is authorizationURL then
                            set end of matches to browserTab
                        end if
                    end repeat
                end repeat
                if (count of matches) is 1 then
                    set authorizationTab to item 1 of matches
                    if not visible of authorizationTab then close authorizationTab
                end if
            end tell
        end timeout
    end finishauthorization
    """
}
