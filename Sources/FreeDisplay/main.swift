import AppKit
import SwiftUI

private func parseLaunchArguments() -> (cliArgs: [String], silentLaunch: Bool) {
    let raw = Array(CommandLine.arguments.dropFirst())
    var filtered: [String] = []
    var silent = false
    var i = 0
    while i < raw.count {
        let arg = raw[i]
        if arg.hasPrefix("-psn_") {
            i += 1
            continue
        }
        if arg == "-NSDocumentRevisionsDebugMode" || arg == "-ApplePersistenceIgnoreState" || arg == "-AppleLanguages" {
            i += 2
            continue
        }
        if arg == "--silent" {
            silent = true
            i += 1
            continue
        }
        if arg == "--lang", i + 1 < raw.count {
            let code = raw[i + 1].lowercased()
            if code.hasPrefix("zh") {
                L10n.overrideLanguage = .zh
            } else if code.hasPrefix("en") {
                L10n.overrideLanguage = .en
            }
            i += 2
            continue
        }
        filtered.append(arg)
        i += 1
    }
    return (filtered, silent)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow!
    private var viewModel: DisplayViewModel!
    private let startSilently: Bool

    init(startSilently: Bool = false) {
        self.startSilently = startSilently
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel = DisplayViewModel()

        // 1. Menu Bar Popover
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: MenuBarPopoverView(vm: viewModel))
        self.popover = pop

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "display", accessibilityDescription: "FreeDisplay") {
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeading
            } else {
                button.title = "HiDPI"
            }
            button.toolTip = L10n.tr(
                zh: "FreeDisplay — 显示器高清缩放与亮度调节",
                en: "FreeDisplay — HiDPI Scaling & Brightness"
            )
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // 2. Standalone Main Control Window (closes to Menu Bar without quitting)
        let hostingController = NSHostingController(rootView: MenuBarPopoverView(vm: viewModel))
        let win = NSWindow(contentViewController: hostingController)
        win.title = "FreeDisplay"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        self.mainWindow = win

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowWindowNotification(_:)),
            name: Notification.Name("local.opensource.FreeDisplay.showPopover"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if !startSilently {
            showMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func handleShowWindowNotification(_ note: Notification) {
        showMainWindow()
    }

    /// Switching the mode of the screen the panel is on changes that screen's size and position, but AppKit keeps
    /// the popover and the window where they were, so part of them can end up off-screen (issue #1). Once the menu
    /// bar has settled, re-anchor the popover under the status item and pull the window back onto its screen.
    @objc private func screenParametersChanged(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if self.popover.isShown, let button = self.statusItem.button {
                let animates = self.popover.animates
                self.popover.animates = false
                self.popover.close()
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.makeKey()
                self.popover.animates = animates
            }
            if self.mainWindow.isVisible, let screen = self.mainWindow.screen ?? NSScreen.main {
                let frame = self.mainWindow.constrainFrameRect(self.mainWindow.frame, to: screen)
                if frame != self.mainWindow.frame {
                    self.mainWindow.setFrame(frame, display: true)
                }
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showMainWindow() {
        viewModel.refreshDisplays()
        if popover.isShown {
            popover.performClose(nil)
        }
        if !mainWindow.isVisible {
            mainWindow.center()
        }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            showMainWindow()
            return
        }
        viewModel.refreshDisplays()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

let parsed = parseLaunchArguments()
if !parsed.cliArgs.isEmpty {
    exit(CLIRunner.run(args: parsed.cliArgs))
} else {
    let bundleID = Bundle.main.bundleIdentifier ?? "local.opensource.FreeDisplay"
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

    if !running.isEmpty && L10n.overrideLanguage == nil {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("local.opensource.FreeDisplay.showPopover"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MainActor.assumeIsolated { AppDelegate(startSilently: parsed.silentLaunch) }
    app.delegate = delegate
    app.run()
}
