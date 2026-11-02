import AppKit
import Observation

/// Checks GitHub Releases (ml450/decibel) for a newer version and installs it in place.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(version: String)
        case installing
        case failed(String)
    }

    static let repo = "ml450/decibel"
    static let assetName = "Decibel.zip"

    private(set) var state: State = .idle
    @ObservationIgnored private var downloadURL: URL?
    @ObservationIgnored private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    /// Quiet checks at launch and every 6 hours; only an available update changes what you see.
    func startAutomaticChecks() {
        Task { await check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.check(userInitiated: false) } }
        }
    }

    func check(userInitiated: Bool = true) async {
        if state == .checking || state == .installing { return }
        let previous = state
        if userInitiated { state = .checking }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
                throw UpdateError("The latest release has no \(Self.assetName)")
            }
            if Self.isNewer(latest, than: currentVersion) {
                downloadURL = asset.browserDownloadURL
                state = .available(version: latest)
            } else {
                state = userInitiated ? .upToDate : (previous == .checking ? .idle : previous)
                if userInitiated { resetAfterDelay() }
            }
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = userInitiated ? .failed("Couldn't check for updates") : previous
            if userInitiated { resetAfterDelay() }
        }
    }

    /// Downloads the zip, verifies it is a validly signed Decibel, swaps it in and relaunches.
    func install(beforeQuit: @escaping () -> Void) async {
        guard let downloadURL else { return }
        state = .installing
        do {
            let (zip, _) = try await URLSession.shared.download(from: downloadURL)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("DecibelUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

            let newApp = work.appendingPathComponent("Decibel.app")
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download isn't a Decibel app")
            }
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

            // Replace the running bundle (macOS allows this), then relaunch once we have quit.
            let target = Bundle.main.bundleURL
            let backup = work.appendingPathComponent("Decibel-old.app")
            try FileManager.default.moveItem(at: target, to: backup)
            do {
                try FileManager.default.moveItem(at: newApp, to: target)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: target)
                throw error
            }

            let pid = ProcessInfo.processInfo.processIdentifier
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(target.path)\""]
            try relaunch.run()
            beforeQuit()
            NSApp.terminate(nil)
        } catch {
            log.error("Update failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
    }

    // MARK: Helpers

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func resetAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            if self.state == .upToDate || { if case .failed = self.state { return true }; return false }() {
                self.state = .idle
            }
        }
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { proc in
                proc.terminationStatus == 0
                    ? cont.resume()
                    : cont.resume(throwing: UpdateError("\((tool as NSString).lastPathComponent) failed (\(proc.terminationStatus))"))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
