import AppKit

@MainActor
struct AppWindowFocusRestorer {
    private let windows: [NSWindow]

    static func capture() -> AppWindowFocusRestorer {
        AppWindowFocusRestorer(windows: frontableWindows())
    }

    static func restoreVisibleWindows() {
        restore(windows: frontableWindows())
    }

    func restore() {
        Self.restore(windows: windows)
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

        NSApp.activate(ignoringOtherApps: true)
        frontWindow.makeKeyAndOrderFront(nil)
        for window in visibleWindows.dropFirst() {
            window.orderFront(nil)
        }
    }
}
