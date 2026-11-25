import AppKit
import CryptoKit
import Foundation
import Security

/// In-app updates from GitHub Releases, and the only code in FreeDisplay that uses the network.
///
/// It reads the latest release of acking-you/FreeDisplay. When that is newer than the running app it downloads
/// `FreeDisplay-X.Y.Z.dmg` (reporting progress and speed), checks it against `FreeDisplay-X.Y.Z.dmg.sha256`, copies the
/// app out of the disk image and accepts it only if it carries a valid Developer ID signature from the same team as
/// the running app, with the same bundle identifier and the release's version. FreeDisplay then quits, and a detached
/// shell script swaps the bundle (putting the old one back if anything fails) and reopens it. A copy that cannot
/// replace itself (a local ad hoc build, a read-only or translocated location) sends the user to the release page.
@MainActor
public final class Updater: ObservableObject {
    public static let shared = Updater(config: .running)

    public struct Release: Equatable {
        public let version: String
        public let pageURL: URL
        public let dmgURL: URL
        public let dmgSize: Int64
        public let sha256URL: URL
    }

    public enum State: Equatable {
        case idle
        case checking(userInitiated: Bool)
        case upToDate
        case available(Release)
        case downloading(Release, received: Int64, total: Int64, bytesPerSecond: Double)
        case installing(Release)
        case failed(String, Release?)
    }

    struct Config {
        /// nil when not running from an app bundle (`swift run`, the CLI binary): updates are off.
        var currentVersion: String?
        /// The running app's Developer ID team; nil for ad hoc builds, which never replace themselves.
        var teamID: String?
        var appURL: URL
        var relaunch: Bool
        var apiURL: URL

        static var running: Config {
            Config(
                currentVersion: Bundle.main.bundleURL.pathExtension == "app"
                    ? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    : nil,
                teamID: Updater.runningTeamID(),
                appURL: Bundle.main.bundleURL,
                relaunch: true,
                apiURL: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!
            )
        }
    }

    nonisolated static let repo = "acking-you/FreeDisplay"
    nonisolated static let bundleID = "local.opensource.FreeDisplay"
    private static let autoCheckKey = "FreeDisplay.autoCheckUpdates"
    private static let lastCheckKey = "FreeDisplay.lastUpdateCheck"
    private static let updatedFromKey = "FreeDisplay.updatedFrom"

    @Published public internal(set) var state: State = .idle
    @Published public var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey) }
    }
    /// Set for a while after an update, to say so in the panel.
    @Published public private(set) var justUpdatedFrom: String?

    let config: Config
    private var timer: Timer?
    private var download: UpdateDownload?

    init(config: Config) {
        self.config = config
        let defaults = UserDefaults.standard
        autoCheck = defaults.object(forKey: Self.autoCheckKey) == nil ? true : defaults.bool(forKey: Self.autoCheckKey)
    }

    public var isEnabled: Bool { config.currentVersion != nil }
    public var currentVersion: String { config.currentVersion ?? "dev" }

    /// Whether this copy can replace itself: a Developer ID build in a folder it may write to, not a translocated copy.
    public var canInstallInPlace: Bool {
        guard config.teamID != nil else { return false }
        let app = config.appURL
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: app.path)
    }

    /// Starts the daily automatic check (when enabled) and reports a just-finished update.
    public func start() {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        if let from = defaults.string(forKey: Self.updatedFromKey) {
            defaults.removeObject(forKey: Self.updatedFromKey)
            if from != currentVersion {
                justUpdatedFrom = from
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self.justUpdatedFrom = nil
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.checkIfDue()
        }
    }

    /// Checks GitHub at most once a day while automatic checks are on.
    public func checkIfDue() {
        guard isEnabled, autoCheck else { return }
        switch state {
        case .idle, .upToDate, .failed(_, nil): break
        default: return
        }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        Task { await check(userInitiated: false) }
    }

    public func check(userInitiated: Bool) async {
        guard isEnabled else { return }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking(userInitiated: userInitiated)
        do {
            let latest = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if let latest, Self.isNewer(latest.version, than: currentVersion) {
                state = .available(latest)
            } else if userInitiated {
                state = .upToDate
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.state == .upToDate { self.state = .idle }
                }
            } else {
                state = .idle
            }
        } catch {
            state = userInitiated
                ? .failed(L10n.tr(zh: "检查更新失败：\(error.localizedDescription)",
                                  en: "Update check failed: \(error.localizedDescription)"), nil)
                : .idle
        }
    }

    /// Downloads and installs `release`, or opens its page when this copy can't replace itself.
    public func install(_ release: Release) {
        guard canInstallInPlace else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        switch state {
        case .downloading, .installing: return
        default: break
        }
        let work: URL
        do {
            work = try Self.makeWorkDirectory(version: release.version)
        } catch {
            state = .failed(L10n.tr(zh: "无法创建临时目录：\(error.localizedDescription)",
                                    en: "Could not create a work folder: \(error.localizedDescription)"), release)
            return
        }
        let dmg = work.appendingPathComponent("FreeDisplay-\(release.version).dmg")
        state = .downloading(release, received: 0, total: release.dmgSize, bytesPerSecond: 0)
        download = UpdateDownload(
            url: release.dmgURL,
            destination: dmg,
            expectedSize: release.dmgSize,
            progress: { [weak self] received, total, speed in
                guard let self = self, case .downloading = self.state else { return }
                self.state = .downloading(release, received: received, total: total, bytesPerSecond: speed)
            },
            completion: { [weak self] error in
                guard let self = self else { return }
                self.download = nil
                if let error = error {
                    try? FileManager.default.removeItem(at: work)
                    if (error as? URLError)?.code == .cancelled {
                        self.state = .available(release)
                    } else {
                        self.state = .failed(L10n.tr(zh: "下载失败：\(error.localizedDescription)",
                                                     en: "Download failed: \(error.localizedDescription)"), release)
                    }
                    return
                }
                Task { await self.finishInstall(release, dmg: dmg, work: work) }
            }
        )
    }

    public func cancelDownload() {
        download?.cancel()
    }

    public func dismissFailure() {
        if case .failed(_, let release) = state {
            state = release.map { .available($0) } ?? .idle
        }
    }

    private func finishInstall(_ release: Release, dmg: URL, work: URL) async {
        state = .installing(release)
        guard let team = config.teamID else { return }
        let version = release.version, sha256URL = release.sha256URL
        let prepared = await Task.detached(priority: .userInitiated) {
            await Updater.prepare(dmg: dmg, sha256URL: sha256URL, version: version, teamID: team, work: work)
        }.value
        switch prepared {
        case .failure(let error):
            try? FileManager.default.removeItem(at: work)
            state = .failed(error.message, release)
        case .success(let staged):
            do {
                try Self.launchSwap(staged: staged, work: work, destination: config.appURL, relaunch: config.relaunch)
            } catch {
                try? FileManager.default.removeItem(at: work)
                state = .failed(L10n.tr(zh: "无法启动安装：\(error.localizedDescription)",
                                        en: "Could not start the install: \(error.localizedDescription)"), release)
                return
            }
            UserDefaults.standard.set(currentVersion, forKey: Self.updatedFromKey)
            if config.relaunch {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let size: Int64
            let downloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name, size
                case downloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", draft, prerelease, assets
        }
    }

    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: config.apiURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FreeDisplay/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw UpdateError.http(status)
        }
        let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !latest.draft, !latest.prerelease, latest.tagName.hasPrefix("v") else { return nil }
        let version = String(latest.tagName.dropFirst())
        guard let dmg = latest.assets.first(where: { $0.name == "FreeDisplay-\(version).dmg" }),
              let sha = latest.assets.first(where: { $0.name == "FreeDisplay-\(version).dmg.sha256" }) else {
            return nil
        }
        return Release(version: version, pageURL: latest.htmlURL, dmgURL: dmg.downloadURL, dmgSize: dmg.size,
                       sha256URL: sha.downloadURL)
    }

    /// Numeric comparison of dotted versions ("1.10.0" is newer than "1.9.3").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Verify and install (off the main thread)

    enum UpdateError: Error {
        case http(Int)
        case checksumUnavailable, checksumMismatch, mountFailed, copyFailed, signatureMismatch, versionMismatch

        var message: String {
            switch self {
            case .http(let status):
                return L10n.tr(zh: "GitHub 返回 HTTP \(status)", en: "GitHub answered HTTP \(status)")
            case .checksumUnavailable:
                return L10n.tr(zh: "无法获取安装包的 SHA-256 校验值", en: "Could not get the installer's SHA-256")
            case .checksumMismatch:
                return L10n.tr(zh: "安装包的 SHA-256 不匹配，已放弃安装", en: "The installer's SHA-256 does not match; not installing")
            case .mountFailed:
                return L10n.tr(zh: "无法打开下载的 DMG", en: "Could not open the downloaded DMG")
            case .copyFailed:
                return L10n.tr(zh: "无法从 DMG 中取出应用", en: "Could not copy the app out of the DMG")
            case .signatureMismatch:
                return L10n.tr(zh: "新版本的签名与当前应用的开发者不符，已放弃安装", en: "The new version is not signed by the same developer; not installing")
            case .versionMismatch:
                return L10n.tr(zh: "下载的应用版本与发布不符，已放弃安装", en: "The downloaded app's version does not match the release; not installing")
            }
        }
    }

    nonisolated static func prepare(dmg: URL, sha256URL: URL, version: String, teamID: String,
                                    work: URL) async -> Result<URL, UpdateError> {
        // 1. the release's SHA-256 for the DMG
        guard let (data, response) = try? await URLSession.shared.data(from: sha256URL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              let expected = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first?.lowercased(),
              expected.count == 64,
              let bytes = try? Data(contentsOf: dmg, options: .mappedIfSafe) else {
            return .failure(.checksumUnavailable)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { return .failure(.checksumMismatch) }

        // 2. copy the app out of the disk image
        let mount = work.appendingPathComponent("mount")
        let staged = work.appendingPathComponent("FreeDisplay.app")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) == 0 else {
            return .failure(.mountFailed)
        }
        let source = mount.appendingPathComponent("FreeDisplay.app")
        let copied = FileManager.default.fileExists(atPath: source.path)
            && run("/usr/bin/ditto", [source.path, staged.path]) == 0
        _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard copied else { return .failure(.copyFailed) }

        // 3. signed by the same Developer ID team, and the version the release says
        guard verifySignature(of: staged, teamID: teamID) else { return .failure(.signatureMismatch) }
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == version else {
            return .failure(.versionMismatch)
        }
        return .success(staged)
    }

    /// The designated requirement of a Developer ID app from `teamID`, checked over every architecture and nested code.
    nonisolated static func verifySignature(of app: URL, teamID: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code = code else {
            return false
        }
        let text = "identifier \"\(bundleID)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement = requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Team ID of the running app's signature; nil for ad hoc and unsigned builds.
    nonisolated static func runningTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code = code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode = staticCode else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return nil
        }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// After this process exits, swaps `destination` for `staged` (restoring the old app if the copy fails), removes
    /// the work folder and, when asked, reopens the app.
    nonisolated static func launchSwap(staged: URL, work: URL, destination: URL, relaunch: Bool) throws {
        let script = """
        pid="$1"; staged="$2"; work="$3"; dest="$4"; relaunch="$5"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
        old="$dest.freedisplay-old"
        rm -rf "$old"
        if mv "$dest" "$old"; then
          if /usr/bin/ditto "$staged" "$dest"; then
            rm -rf "$old"
          else
            rm -rf "$dest"
            mv "$old" "$dest"
          fi
        fi
        rm -rf "$work"
        if [ "$relaunch" = 1 ]; then /usr/bin/open "$dest"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "freedisplay-update", String(ProcessInfo.processInfo.processIdentifier),
                             staged.path, work.path, destination.path, relaunch ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func makeWorkDirectory(version: String) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let work = caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Update-\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// One file download on its own delegate-driven URLSession, reporting bytes received and the speed over the last
/// ~1.5 s on the main thread, a few times a second.
@MainActor
final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let destination: URL
    private let expectedSize: Int64
    private let progress: (Int64, Int64, Double) -> Void
    private let completion: (Error?) -> Void
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var lastReport: TimeInterval = 0
    private var moveError: Error?

    init(url: URL, destination: URL, expectedSize: Int64,
         progress: @escaping (Int64, Int64, Double) -> Void,
         completion: @escaping (Error?) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    private func received(_ total: Int64, of expected: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, total))
        while samples.count > 2, now - samples[1].time > 1.5 {
            samples.removeFirst()
        }
        let size = expected > 0 ? expected : expectedSize
        guard now - lastReport >= 0.2 || total >= size else { return }
        lastReport = now
        var speed = 0.0
        if let first = samples.first, now - first.time > 0.05 {
            speed = Double(total - first.bytes) / (now - first.time)
        }
        progress(total, size, speed)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            received(totalBytesWritten, of: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The system deletes `location` as soon as this returns.
        MainActor.assumeIsolated {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            self.session?.finishTasksAndInvalidate() // the session retains its delegate until invalidated
            self.session = nil
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = error {
                completion(error)
            } else if !(200..<300).contains(status) {
                completion(Updater.UpdateError.http(status))
            } else {
                completion(moveError)
            }
        }
    }
}
