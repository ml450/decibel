import AppKit
import ServiceManagement

/// "Uninstall Decibel…" in the settings menu. Everything goes to the Bin, so it can be undone.
@MainActor
enum Uninstaller {
    static let downloadPage = URL(string: "https://ml450.github.io/decibel/")!

    static func confirmAndUninstall(model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall Decibel?"
        alert.informativeText = "Decibel is moved to the Bin, and its login item, audio permission and settings are removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Keep my listening history"
        alert.suppressionButton?.state = .on
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        model.flush()
        uninstall(keepHistory: alert.suppressionButton?.state == .on)
    }

    /// What uninstalling removes, in order. `dryRun` only logs and prints the steps.
    static func uninstall(keepHistory: Bool, dryRun: Bool = false) {
        let bundleID = Bundle.main.bundleIdentifier ?? "local.hearing.app"
        let app = Bundle.main.bundleURL
        let data = DecibelStore.defaultDirectory

        func step(_ description: String, _ action: () throws -> Void) {
            if dryRun {
                print("would: \(description)")
                return
            }
            do {
                try action()
                log.info("Uninstall: \(description, privacy: .public)")
            } catch {
                log.error("Uninstall: \(description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        step("remove the login item") { try SMAppService.mainApp.unregister() }
        step("reset the audio permission for \(bundleID)") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "All", bundleID]
            try p.run()
            p.waitUntilExit()
        }
        if keepHistory {
            if dryRun { print("keep: listening history in \(data.path)") }
        } else {
            step("move \(data.path) to the Bin") { try FileManager.default.trashItem(at: data, resultingItemURL: nil) }
        }
        step("remove settings (\(bundleID))") { UserDefaults.standard.removePersistentDomain(forName: bundleID) }

        if dryRun {
            print("would: move \(app.path) to the Bin and quit")
            return
        }
        NSWorkspace.shared.recycle([app]) { _, error in
            if let error { log.error("Uninstall: moving the app failed: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// "Share Decibel" in the settings menu: a link to the download page.
@MainActor
enum ShareDecibel {
    static let message = "Decibel viser hvor høyt du hører, rett i menylinjen på Macen."

    static func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Uninstaller.downloadPage.absoluteString, forType: .string)
    }

    /// Copy Link / Messages / Mail / AirDrop, at the pointer.
    static func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Copy Link") { copyLink() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Messages") { share(via: .composeMessage) })
        menu.addItem(ClosureMenuItem("Mail") { share(via: .composeEmail) })
        menu.addItem(ClosureMenuItem("AirDrop") { share(via: .sendViaAirDrop) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    static func share(via name: NSSharingService.Name) {
        guard let service = NSSharingService(named: name) else { return copyLink() }
        service.subject = "Decibel"
        let items: [Any] = name == .sendViaAirDrop ? [Uninstaller.downloadPage] : [message, Uninstaller.downloadPage]
        if service.canPerform(withItems: items) {
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: items)
        } else {
            copyLink()
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
