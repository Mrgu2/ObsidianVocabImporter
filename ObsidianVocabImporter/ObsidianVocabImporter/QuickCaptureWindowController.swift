import AppKit
import SwiftUI

final class QuickCaptureWindowController: NSWindowController {
    private let vm = QuickCaptureViewModel()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "快速捕获"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()

        super.init(window: panel)

        let rootView = QuickCaptureView(
            vm: vm,
            onClose: { [weak panel] in
                panel?.orderOut(nil)
            }
        )
        panel.contentView = NSHostingView(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func show() {
        vm.resetFromClipboard()

        guard let w = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

