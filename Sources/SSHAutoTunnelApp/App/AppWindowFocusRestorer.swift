import AppKit

@MainActor
enum AppActivation {
    static func activate() {
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

@MainActor
struct AppWindowFocusRestorer {
    private let windows: [NSWindow]

    static func capture() -> AppWindowFocusRestorer {
        AppWindowFocusRestorer(windows: frontableWindows())
    }

    static func restoreVisibleWindows() {
        restoreAfterSystemPrompt(windows: frontableWindows())
    }

    func restore() {
        Self.restoreAfterSystemPrompt(windows: windows)
    }

    private static func frontableWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { window in
            window.isVisible && !window.isMiniaturized
        }
    }

    private static func restore(windows: [NSWindow]) {
        let visibleWindows = windows.filter { window in
            window.isVisible && !window.isMiniaturized
        }
        guard let frontWindow = visibleWindows.first else { return }

        AppActivation.activate()

        for window in visibleWindows.reversed() {
            window.orderFrontRegardless()
        }
        frontWindow.makeKeyAndOrderFront(nil)
        frontWindow.orderFrontRegardless()
    }

    private static func restoreAfterSystemPrompt(windows: [NSWindow]) {
        restore(windows: windows)
        for delay in [0.1, 0.35, 0.8] {
            scheduleRestore(windows: windows, delay: delay)
        }
    }

    private static func scheduleRestore(windows: [NSWindow], delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            restore(windows: windows)
        }
    }
}
