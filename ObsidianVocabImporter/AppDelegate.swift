import AppKit
import Carbon
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureWindow = QuickCaptureWindowController()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // Hotkey: Control + Option + Command + V
    // The Carbon callback is a top-level closure, so these must be file-scoped.
    fileprivate let hotKeyID: UInt32 = 1
    fileprivate let hotKeySignature: OSType = fourCharCode("OEIC")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched from Xcode, libLogRedirect can redirect stdout/stderr into a pipe.
        // If SwiftUI/AttributeGraph emits a large diagnostic during app shutdown (e.g. cycle dumps),
        // a full pipe can block the main thread and make the app appear to hang on quit.
        // Make stdio non-blocking in that environment to keep quitting responsive.
        makeStandardIONonBlockingIfXcodeRedirected()
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotKey()
    }

    private func registerHotKey() {
        // Install event handler first.
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventSpec, userData, &eventHandlerRef)
        if handlerStatus != noErr {
            NSLog("OEI: failed to install hotkey event handler (status=%d)", handlerStatus)
            eventHandlerRef = nil
            return
        }

        let hkID = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let hkStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if hkStatus != noErr {
            NSLog("OEI: failed to register global hotkey (status=%d)", hkStatus)
            hotKeyRef = nil
        }
    }

    private func unregisterHotKey() {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    fileprivate func handleQuickCaptureHotKey() {
        captureWindow.show()
    }

    private func makeStandardIONonBlockingIfXcodeRedirected() {
        let env = ProcessInfo.processInfo.environment
        let inserts = env["DYLD_INSERT_LIBRARIES"] ?? ""
        // Heuristic: these are injected by Xcode when launching under the debugger.
        let likelyXcodeRedirect = inserts.contains("libLogRedirect") || inserts.contains("libMainThreadChecker") || inserts.contains("libViewDebuggerSupport")
        guard likelyXcodeRedirect else { return }

        for fd in [STDOUT_FILENO, STDERR_FILENO] {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}

private func fourCharCode(_ s: String) -> OSType {
    var result: UInt32 = 0
    for u in s.unicodeScalars.prefix(4) {
        result = (result << 8) + UInt32(u.value)
    }
    return OSType(result)
}

private let hotKeyEventHandler: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef else { return noErr }
    guard let userData else { return noErr }

    var hkID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    guard status == noErr else { return noErr }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    if hkID.signature == delegate.hotKeySignature, hkID.id == delegate.hotKeyID {
        DispatchQueue.main.async {
            delegate.handleQuickCaptureHotKey()
        }
    }

    return noErr
}
