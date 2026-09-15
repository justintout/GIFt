import AppKit
import Carbon.HIToolbox

/// A hotkey registered with the system.
///
/// Unlike the Escape event tap, the system delivers only this one combination, so a hotkey needs no
/// Input Monitoring or Accessibility permission. That makes it the only control the app can offer
/// every user without asking for anything.
final class GlobalHotkey {
    /// Four-character code identifying GIFt's hotkeys to Carbon.
    private static let signature: OSType = 0x47494654 // 'GIFT'

    private var hotKeyReference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    private let handler: () -> Void

    /// Fails when another application already owns the combination, which is why registration is
    /// attempted per recording rather than once at launch.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyReference) == noErr,
              hotKeyReference != nil else {
            return nil
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers this on the main thread; hop explicitly so the handler is free to
                // touch the menu bar and the recorder.
                DispatchQueue.main.async { hotKey.handler() }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerReference
        )

        guard status == noErr else {
            UnregisterEventHotKey(hotKeyReference)
            hotKeyReference = nil
            return nil
        }
    }

    func unregister() {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        if let handlerReference { RemoveEventHandler(handlerReference) }
        hotKeyReference = nil
        handlerReference = nil
    }

    deinit {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        if let handlerReference { RemoveEventHandler(handlerReference) }
    }
}
