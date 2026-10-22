#if os(macOS)
import GentleMergeCore
import AppKit
import SwiftUI

/// `GENTLEMERGE_SNAPSHOT_DIR=/some/dir` makes the app photograph its own window
/// and menu bar panel into that folder, in light and dark, and then quit.
///
/// For screenshots in a pull request: an agent's shell has no Screen Recording
/// permission and a menu bar app is invisible to the accessibility tools, so
/// `screencapture` fails and nothing else can see the window. A process may
/// always photograph its own windows. Off unless the variable is set.
@MainActor
enum UISnapshot {
    static func runIfRequested(model: InboxModel) {
        guard let dir = ProcessInfo.processInfo.environment["GENTLEMERGE_SNAPSHOT_DIR"],
              !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Give the hooks that whoever launched us is firing time to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            model.drainNow()
            model.refreshBus()
            shoot(.aqua, suffix: "light", model: model, into: out) {
                shoot(.darkAqua, suffix: "dark", model: model, into: out) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func shoot(
        _ appearance: NSAppearance.Name,
        suffix: String,
        model: InboxModel,
        into out: URL,
        then next: @escaping @MainActor () -> Void
    ) {
        NSApp.appearance = NSAppearance(named: appearance)

        let window = NSApp.windows.first { $0.canBecomeMain }
        window?.setFrame(NSRect(x: 80, y: 80, width: 1000, height: 820), display: true)
        window?.makeKeyAndOrderFront(nil)

        // The menu bar panel is not a window until it is clicked, so the same
        // view goes into one of ours, off screen.
        let panel = NSWindow(
            contentRect: NSRect(x: -4000, y: 0, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: MenuBarSummary(model: model, openMainWindow: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.orderFrontRegardless()

        // A moment for the new appearance to land everywhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let window { capture(window, to: out.appendingPathComponent("window-\(suffix).png")) }
            capture(panel, to: out.appendingPathComponent("menubar-\(suffix).png"))
            panel.orderOut(nil)
            next()
        }
    }

    /// `CGWindowListCreateImage` is obsolete in the current SDK, so it is
    /// looked up at run time. Its replacement, ScreenCaptureKit, asks for
    /// Screen Recording even for your own windows.
    private static func capture(_ window: NSWindow, to url: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        // A null rect is the window's own bounds; 8 = just this window;
        // 1 = without the drop shadow.
        guard let image = createImage(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
