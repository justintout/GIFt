import AppKit
import ApplicationServices

/// The system permissions GIFt can use, and how to check and ask for each.
///
/// macOS only shows its prompt once. After a denial, asking again does nothing, so every row in
/// Settings also offers the pane in System Settings, which is the only route that always works.
enum Permission: CaseIterable {
    /// Required. Without it there is nothing to record.
    case screenRecording
    /// Optional. Lets Escape cancel a recording while another app is frontmost.
    case inputMonitoring
    /// Optional. Raises the chosen window rather than every window its application owns.
    case accessibility

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    var explanation: String {
        switch self {
        case .screenRecording:
            return "Required. GIFt cannot capture anything without it."
        case .inputMonitoring:
            return "Optional. Lets Escape stop a recording while another app is in front. Escape during area selection works without it."
        case .accessibility:
            return "Optional. Brings the window you chose to the front instead of every window that application has. Used only when \"Bring the window to the front\" is on."
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// Shows the system prompt. Screen Recording reports the result; the other two normally send
    /// the user to System Settings, so a false result here means "not yet", not "refused".
    @discardableResult
    func request() -> Bool {
        switch self {
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        case .accessibility:
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
    }
}
