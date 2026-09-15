import AppKit
import ApplicationServices

/// Bringing a chosen window to the front before recording it.
enum WindowForegrounding {
    /// Activates the owning application, then — when Accessibility is granted — raises the specific
    /// window. Activation on its own surfaces every window that application owns, which is the
    /// wrong result whenever it has more than one open.
    static func bringToFront(_ candidate: WindowCandidate) {
        guard let app = NSRunningApplication(processIdentifier: candidate.ownerProcessID) else { return }
        if !app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
            appLog.info("could not activate \(candidate.ownerName, privacy: .private); recording the window as it is")
        }

        guard Permission.accessibility.isGranted else { return }
        raise(candidate)
    }

    private static func raise(_ candidate: WindowCandidate) {
        let application = AXUIElementCreateApplication(candidate.ownerProcessID)
        // A hung target application must not block the main thread, which is what drives the menu.
        AXUIElementSetMessagingTimeout(application, 1.0)

        var windowsReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsReference) == .success,
              let windows = windowsReference as? [AXUIElement] else {
            appLog.info("could not read the windows of \(candidate.ownerName, privacy: .private)")
            return
        }

        guard let window = matching(candidate, in: windows) else {
            appLog.info("no Accessibility window matched id \(candidate.windowID, privacy: .public)")
            return
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// The frame was read when the menu opened, moments earlier, and is the stronger signal:
    /// titles are often empty and rarely unique across one application's windows.
    private static func matching(_ candidate: WindowCandidate, in windows: [AXUIElement]) -> AXUIElement? {
        if let byPosition = windows.first(where: { frame(of: $0).map { $0.isNearly(candidate.frame) } ?? false }) {
            return byPosition
        }
        guard !candidate.title.isEmpty else { return nil }
        return windows.first { string(of: $0, kAXTitleAttribute) == candidate.title }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let positionReference = value(of: window, kAXPositionAttribute),
              let sizeReference = value(of: window, kAXSizeAttribute),
              CFGetTypeID(positionReference) == AXValueGetTypeID(),
              CFGetTypeID(sizeReference) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionReference as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeReference as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        value(of: element, attribute) as? String
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &reference) == .success else { return nil }
        return reference
    }
}

private extension CGRect {
    /// A window shifts by a point or two while its application activates, so compare with tolerance.
    func isNearly(_ other: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
