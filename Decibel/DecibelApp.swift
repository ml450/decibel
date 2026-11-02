import AppKit
import SwiftUI

/// Plain AppKit entry point. The SwiftUI `App` lifecycle swallows the "reopen" event that is sent when
/// you launch an already-running menu bar app from Spotlight, Finder or the Dock.
@main
enum DecibelMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.mainMenu = AppDelegate.makeMainMenu()
            app.run()
            _ = delegate
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: AppModel!
    private var statusItem: StatusItemController!
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }

        do {
            DecibelStore.migrateLegacyDirectory()
            model = AppModel(store: try DecibelStore())
        } catch {
            let alert = NSAlert()
            alert.messageText = "Decibel couldn't open its database"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // `--snapshot out.png [--demo] [--range M] [light]` renders the panel to a PNG and exits
        // (design checks; `--demo` uses a throwaway database with a sample month for screenshots).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dark = !args.contains("light")
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if args.contains("--demo"), let demo = try? DemoData.makeStore() {
                model = AppModel(store: demo)
                model.isSnapshot = true
                model.applyDemo()
            } else {
                model.isSnapshot = true
                model.loadCurrentDevice()
            }
            if let r = args.firstIndex(of: "--range"), r + 1 < args.count, let range = TimeRange(rawValue: args[r + 1]) {
                model.range = range
            }
            model.reloadStats()
            // Stand-in for the popover material, which ImageRenderer can't draw.
            let renderer = ImageRenderer(content: PanelView().environment(model)
                .background(dark ? Color(white: 0.16) : Color(white: 0.93))
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 3
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView().environment(model))
        host.sizingOptions = [.preferredContentSize]   // the panel grows/shrinks with its content
        popover.contentViewController = host
        model.setPanelPinned = { [weak self] pinned in
            self?.popover.behavior = pinned ? .applicationDefined : .transient
        }

        statusItem = StatusItemController()
        statusItem.item.button?.target = self
        statusItem.item.button?.action = #selector(togglePanel)
        model.onLiveChange = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()

        model.start()

        // `--install-update`: what the Install button does, for testing the update path from Terminal.
        if CommandLine.arguments.contains("--install-update") {
            Task {
                await model.updater.check()
                guard model.updater.updateAvailable else {
                    log.info("install-update: no newer version (\(String(describing: self.model.updater.state), privacy: .public))")
                    return
                }
                log.info("install-update: installing")
                await model.updater.install(beforeQuit: { self.model.flush() })
            }
        }
        model.configureLoginItemOnFirstRun()

        // Open the panel whenever you launch the app yourself; stay quiet when started at login.
        if model.captureState == .needsPermission || !launchedAtLogin {
            showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flush()
    }

    /// Launching the app again (Spotlight, Finder, Dock) opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: Panel

    @objc private func togglePanel() {
        popover.isShown ? popover.performClose(nil) : showPanel()
    }

    private func showPanel(attempt: Int = 0) {
        guard let button = statusItem?.item.button, !popover.isShown else { return }
        // Right after launch the status item isn't on screen yet and show() would silently do nothing.
        guard let w = button.window, w.isVisible, w.frame.height > 0 else {
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.showPanel(attempt: attempt + 1) }
            }
            return
        }
        model.reloadStats()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        darkenPopoverGlass()
        // `.transient` only closes when macOS notices we lost focus, which doesn't always happen when you
        // click another menu bar item (Control Center, volume…). Close on any click outside us instead.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.behavior == .transient else { return }   // pinned while calibrating
                self.popover.performClose(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// Swaps the popover's own glass (which also draws the arrow) for a darker material,
    /// so arrow and body stay one surface.
    private func darkenPopoverGlass() {
        guard let content = popover.contentViewController?.view.window?.contentView else { return }
        var root = content
        while let parent = root.superview { root = parent }
        func effectViews(in view: NSView) -> [NSVisualEffectView] {
            (view as? NSVisualEffectView).map { [$0] } ?? view.subviews.flatMap(effectViews)
        }
        let glass = effectViews(in: root)
        for effect in glass {
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
        }
        log.debug("Popover glass views darkened: \(glass.count) in \(String(describing: type(of: root)), privacy: .public)")
    }

    // MARK: Status item

    private func updateStatusItem() {
        if model.captureState == .needsPermission {
            statusItem?.update(text: "!", color: .systemOrange, toolTip: "Decibel needs audio access")
        } else if let spl = model.liveSPL {
            statusItem?.update(text: String(format: "%.0f", spl), color: Theme.levelNSColor(spl),
                               toolTip: String(format: "%.0f dB(A) on %@", spl, model.device?.name ?? ""))
        } else {
            statusItem?.update(text: nil, color: .secondaryLabelColor, toolTip: "Decibel")
        }
    }

    /// Hidden for a menu bar app, but keeps ⌘Q and copy/paste working in text fields.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Decibel", [NSMenuItem(title: "Quit Decibel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        return main
    }
}
