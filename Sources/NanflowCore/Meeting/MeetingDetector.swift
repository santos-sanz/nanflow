import AppKit
import Foundation

public struct MeetingApp: Sendable {
    public let name: String
    public let bundleIds: Set<String>
    public let processNames: Set<String>

    public static let known: [MeetingApp] = [
        MeetingApp(name: "Zoom", bundleIds: ["us.zoom.xos"], processNames: ["zoom.us"]),
        MeetingApp(name: "Microsoft Teams", bundleIds: ["com.microsoft.teams", "com.microsoft.teams2"], processNames: ["Microsoft Teams", "Microsoft Teams (work or school)"]),
        MeetingApp(name: "FaceTime", bundleIds: ["com.apple.FaceTime"], processNames: ["FaceTime"]),
        MeetingApp(name: "Webex", bundleIds: ["Cisco-WebEx-Meeting-Center", "com.cisco.webex.meetings"], processNames: ["Webex Meetings", "Webex"]),
        MeetingApp(name: "Google Meet", bundleIds: [], processNames: []),
        MeetingApp(name: "Whereby", bundleIds: ["com.whereby.desktop"], processNames: ["Whereby"]),
        MeetingApp(name: "Slack Huddle", bundleIds: ["com.tinyspeck.slackmacgap"], processNames: ["Slack"]),
        MeetingApp(name: "GoToMeeting", bundleIds: ["com.gotomeeting"], processNames: ["GoTo Meeting"]),
        MeetingApp(name: "RingCentral", bundleIds: ["com.ringcentral.rcdesktop"], processNames: ["RingCentral"]),
    ]
}

public struct DetectedMeeting: Sendable {
    public let appName: String
    public let appLocalizedName: String
}

/// Polls running apps to detect active meetings (Zoom, Teams, FaceTime, Webex, Whereby...).
/// Google Meet in browser: detects meet.google.com tabs in Chrome-family browsers via LSCopyApplicationURLs? —
/// best-effort via Chrome's AppleScript is opt-in (see detectBrowserMeetings).
public final class MeetingDetector {
    public var onMeetingStarted: ((DetectedMeeting) -> Void)?
    public var onMeetingEnded: (() -> Void)?

    private var timer: Timer?
    private var currentMeeting: DetectedMeeting?
    private let checkInterval: TimeInterval = 2.0

    public init() {}

    public var isActive: Bool { currentMeeting != nil }
    public var current: DetectedMeeting? { currentMeeting }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        check()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if currentMeeting != nil {
            currentMeeting = nil
            onMeetingEnded?()
        }
    }

    private func check() {
        let detected = Self.detectNativeMeeting()
        if let detected {
            if currentMeeting == nil {
                currentMeeting = detected
                onMeetingStarted?(detected)
            }
        } else if currentMeeting != nil {
            currentMeeting = nil
            onMeetingEnded?()
        }
    }

    static func detectNativeMeeting() -> DetectedMeeting? {
        let running = NSWorkspace.shared.runningApplications
        let runningNames = Set(running.compactMap(\.localizedName))
        for app in MeetingApp.known {
            for runningApp in running {
                let bundleId = runningApp.bundleIdentifier ?? ""
                let name = runningApp.localizedName ?? ""
                if app.bundleIds.contains(bundleId) || app.processNames.contains(name) {
                    // Para apps como Slack, solo cuenta si tiene una ventana activa llamada "Huddle"
                    if app.name == "Slack Huddle" && !slackHuddleActive() { continue }
                    return DetectedMeeting(appName: app.name == "Slack Huddle" ? "Slack" : app.name, appLocalizedName: name)
                }
            }
        }
        return Self.detectBrowserMeeting(runningNames: runningNames)
    }

    private static let browsers = ["Google Chrome", "Microsoft Edge", "Brave Browser", "Chromium"]

    static func detectBrowserMeeting(runningNames: Set<String>) -> DetectedMeeting? {
        for browser in browsers where runningNames.contains(browser) {
            let check = """
            tell application "\(browser)"
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            if URL of t contains "meet.google.com" then return "true"
                        end repeat
                    end try
                end repeat
                return "false"
            end tell
            """
            if let out = runOSAppleScript(check), out.contains("true") {
                return DetectedMeeting(appName: "Google Meet", appLocalizedName: browser)
            }
        }
        return nil
    }

    static func runOSAppleScript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func slackHuddleActive() -> Bool {
        // No invasivo: sin AX por ahora, se considera solo la app visible con audio. v1: false.
        false
    }

    public static func currentlyInMeeting() -> DetectedMeeting? {
        detectNativeMeeting()
    }
}
