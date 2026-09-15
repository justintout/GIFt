import AppKit
import ApplicationServices

let escapeKeyCode: UInt16 = 53

/// Global Escape catcher using a CGEvent tap, so the key is seen even when another app is frontmost.
@MainActor
final class EscTap {
    static let shared = EscTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (() -> Void)?

    func enable(handler: @escaping () -> Void) {
        self.handler = handler
        if source == nil {
            source = makeSource()
        }
        guard let source else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        rearm()
    }

    func disable() {
        handler = nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// The system disables a tap that is too slow or interrupted by secure input. Without this the
    /// tap stays dead and Escape silently stops working for the rest of the session.
    fileprivate func rearm() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func makeSource() -> CFRunLoopSource? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<EscTap>.fromOpaque(context).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    tap.rearm()
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }

                if event.getIntegerValueField(.keyboardEventKeycode) == Int64(escapeKeyCode) {
                    tap.handler?()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else {
            appLog.error("unable to create the Escape event tap; Escape will not stop recordings (accessibilityTrusted: \(AXIsProcessTrusted(), privacy: .public))")
            return nil
        }
        return CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    }
}
