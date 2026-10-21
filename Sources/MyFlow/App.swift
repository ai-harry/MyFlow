import SwiftUI
import AppKit
import ApplicationServices

@main
struct MyFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("My Flow", id: "main") {
            MainWindowView()
                .frame(minWidth: 900, minHeight: 620)
                .background(WindowOpenerCapture())
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsRootView()
        }
    }
}

/// Captures SwiftUI's `openWindow` action from inside the main scene so the
/// AppKit side can recreate the (released) main window reliably.
private struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { AppDelegate.openWindowAction = openWindow }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window has appeared at least once.
    static var openWindowAction: OpenWindowAction?
    private var menuBar: MenuBarController?
    private var windowObservers: [NSObjectProtocol] = []
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SINGLE INSTANCE GUARD. Multiple copies each install their own event
        // tap and open their own microphone, so they fight over every press —
        // this is what "the hotkey randomly does nothing" actually was.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.harry.myflow"
        let mine = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
        if let existing = others.min(by: {
            ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast)
        }) {
            mflog("duplicate instance (pid \(existing.processIdentifier) already live) — exiting this one")
            existing.activate()
            NSApp.terminate(nil)
            return
        }

        // Opt out of App Nap: a napped listener gets its event tap disabled by
        // the OS after long idle (the "hotkeys dead until force-quit" bug).
        // This does NOT prevent the Mac itself from sleeping.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Global dictation hotkey listener")

        // After system sleep/wake, a tap can be stale even if it looks
        // enabled — rebuild it outright on every wake.
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { _ in
            mflog("system woke — reinstalling event tap")
            HotkeyManager.shared.reinstall()
            Engine.shared.rearmMic()
        }
        wc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { _ in
            HotkeyManager.shared.reinstall()
        }
        let settings = AppSettings.shared
        settings.mainWindowVisible = false
        settings.settingsWindowVisible = false
        settings.applyDockIcon()   // .accessory unless alwaysShowDockIcon
        settings.syncLoginItem()
        installWindowTracking()
        _ = Store.shared
        _ = Engine.shared
        Sounds.preload()
        // Build the mic capture graph now so the first Fn press only pays the
        // ~30 ms engine.start(), not the ~140 ms cold build.
        Engine.shared.prearmMic()

        if settings.showFlowBar { FlowBarController.shared.show() }

        if !settings.vaultPath.isEmpty {
            VaultManager.ensureVaultScaffold(baseURL: URL(fileURLWithPath: settings.vaultPath))
        }

        LocalASR.warmUp()
        setupHotkeys()
        if Self.launchedAsLoginItem() {
            mflog("launched at login — keeping main window closed")
            // The Window scene opens its window on launch; close it quietly.
            for delay in [0.15, 0.6, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for w in NSApp.windows where AppDelegate.isMainWindow(w) { w.close() }
                    AppSettings.shared.applyDockIcon()
                }
            }
        }
        menuBar = MenuBarController(openMain: { [weak self] in self?.openMainWindow() },
                                    openSettings: { [weak self] in self?.openSettingsWindow() })
    }

    /// True when macOS launched us as a login item (best effort: the launch
    /// Apple event carries keyAELaunchedAsLogInItem in its prop data).
    private static func launchedAsLoginItem() -> Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent,
              ev.eventID == AEEventID(kAEOpenApplication) else { return false }
        return ev.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Install the event tap; if Accessibility is missing, show the official
    /// system prompt (which creates a correctly-bound entry in Settings) and
    /// keep retrying so hotkeys go live the moment the user toggles it on —
    /// no relaunch required.
    private func setupHotkeys() {
        if HotkeyManager.shared.install() { return }
        NSLog("event tap failed — requesting Accessibility via system prompt")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            if AXIsProcessTrusted(), HotkeyManager.shared.install() {
                NSLog("Accessibility granted — hotkeys live")
                timer.invalidate()
            }
        }
    }

    /// Closing the window (red X) must NOT quit — My Flow lives in the
    /// background: Flow Bar, hotkeys, and menu-bar icon stay active.
    /// Quitting is explicit: menu bar 🎙 → Quit, or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The Flow Bar panel always counts as a visible window, so ignore `flag`.
        openMainWindow()
        return false
    }

    // MARK: Window / Dock tracking

    static func isMainWindow(_ w: NSWindow) -> Bool {
        if w is NSPanel { return false }
        guard w.styleMask.contains(.titled), w.level == .normal else { return false }
        if isSettingsWindow(w) { return false }
        let id = w.identifier?.rawValue ?? ""
        return id == "main" || id.hasPrefix("main-") || id.hasPrefix("main_") || w.title == "My Flow"
    }

    static func isSettingsWindow(_ w: NSWindow) -> Bool {
        if w is NSPanel { return false }
        let id = (w.identifier?.rawValue ?? "").lowercased()
        return id.contains("settings") || w.title == "Settings"
    }

    private func installWindowTracking() {
        let nc = NotificationCenter.default
        windowObservers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                              object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if AppDelegate.isMainWindow(w) {
                    let s = AppSettings.shared
                    if !s.mainWindowVisible {
                        s.mainWindowVisible = true
                        s.applyDockIcon()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                } else if AppDelegate.isSettingsWindow(w) {
                    AppSettings.shared.settingsWindowVisible = true
                    NSApp.activate(ignoringOtherApps: true)
                    w.orderFrontRegardless()
                }
            }
        })
        windowObservers.append(nc.addObserver(forName: NSWindow.willCloseNotification,
                                              object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if AppDelegate.isMainWindow(w) {
                    let s = AppSettings.shared
                    s.mainWindowVisible = false
                    s.applyDockIcon()
                } else if AppDelegate.isSettingsWindow(w) {
                    let s = AppSettings.shared
                    s.settingsWindowVisible = false
                    s.applyDockIcon()
                }
            }
        })
    }

    // MARK: Opening windows

    func openMainWindow() {
        // Policy first, so the window can take focus and show a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { AppDelegate.isMainWindow($0) }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        // Closed `Window` scenes are released: recreate via the captured
        // OpenWindowAction (primary), else fall back to the Window-menu item.
        if let open = AppDelegate.openWindowAction {
            open(id: "main")
            return
        }
        // Fallback (window never created yet): SwiftUI keeps a Window-menu item
        // titled "My Flow" that recreates it.
        var found: (NSMenu, Int)?
        for top in NSApp.mainMenu?.items ?? [] {
            guard let sub = top.submenu else { continue }
            for (i, item) in sub.items.enumerated() {
                let isMatch: Bool = item.title == "My Flow" && item.submenu == nil
                    && item.action != nil && item.keyEquivalent != "q"
                if isMatch { found = (sub, i); break }
            }
            if found != nil { break }
        }
        if let (menu, idx) = found {
            menu.performActionForItem(at: idx)
        } else {
            mflog("openMainWindow: no Window-menu item found")
        }
    }

    func openSettingsWindow() {
        // Regular policy first so the window can take focus; reverted through
        // applyDockIcon() when the Settings window closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.async {
            if let w = NSApp.windows.first(where: { AppDelegate.isSettingsWindow($0) }) {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}
