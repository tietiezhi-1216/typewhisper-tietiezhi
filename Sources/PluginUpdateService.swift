import Foundation
import Darwin

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
        let url = request.url
        completionHandler(url?.scheme == "https" && allowed.contains(url?.host ?? "") && url?.user == nil && url?.password == nil ? request : nil)
    }
}

actor PluginUpdateService {
    typealias Transport = @Sendable (URL, Int) async throws -> Data
    private var installing = false
    private let transport: Transport?
    private let installationRoot: URL
    init(transport: Transport? = nil, installationRoot: URL? = nil) {
        self.transport = transport
        self.installationRoot = installationRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TypeWhisper")
    }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
    }()
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        if let transport {
            let data = try await transport(url, limit)
            guard data.count <= limit else { throw PluginUpdateError.network }
            try Task.checkCancellation()
            return data
        }
        var request = URLRequest(url: url)
        request.setValue("tietiezhi-updater", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= limit else { throw PluginUpdateError.network }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw PluginUpdateError.network }
                data.append(byte)
                if data.count % 8192 == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw PluginUpdateError.network }
    }
    func check(current: String) async throws -> PluginRelease? {
        let url = URL(string: "https://api.github.com/repos/" + PluginRelease.repository + "/releases/latest")!
        return try PluginRelease.parse(await fetch(url, limit: 1024 * 1024), current: current)
    }
    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); throw PluginUpdateError.archive }
        guard process.terminationStatus == 0 else { throw PluginUpdateError.archive }
    }
    func install(_ release: PluginRelease, currentBundle: URL, hostVersion: String) async throws {
        guard !installing else { throw PluginUpdateError.busy }
        installing = true
        defer { installing = false }
        let fm = FileManager.default
        let root = installationRoot
        let destination = root.appendingPathComponent("Plugins/tietiezhi.bundle")
        guard currentBundle.standardizedFileURL == destination.standardizedFileURL,
              currentBundle.resolvingSymlinksInPath() == destination.standardizedFileURL,
              let plist = try? PropertyListSerialization.propertyList(from: Data(contentsOf: currentBundle.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any],
              let installed = plist["CFBundleShortVersionString"] as? String,
              let old = PluginVersion(installed), let new = PluginVersion(release.version), new > old else { throw PluginUpdateError.incompatible }
        let data = try await fetch(release.archiveURL, limit: release.size + 1)
        guard data.count == release.size else { throw PluginUpdateError.archive }
        let checksum = try await fetch(release.checksumURL, limit: 4096)
        try PluginRelease.verify(data, checksum: checksum)
        let packageRoot = "tietiezhi-" + release.version
        try PluginUpdateArchive.validate(data, root: packageRoot)
        let plugins = destination.deletingLastPathComponent()
        let lock = open(plugins.appendingPathComponent(".tietiezhi-update.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw PluginUpdateError.install }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw PluginUpdateError.busy }
        defer { flock(lock, LOCK_UN) }
        let staging = plugins.appendingPathComponent(".tietiezhi-update-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let zip = staging.appendingPathComponent("update.zip"), extracted = staging.appendingPathComponent("extracted")
        try data.write(to: zip, options: .atomic)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        let candidate = extracted.appendingPathComponent(packageRoot + "/tietiezhi.bundle")
        let manifestURL = candidate.appendingPathComponent("Contents/Resources/manifest.json")
        guard let manifest = try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              manifest["id"] as? String == "com.tietiezhi.typewhisper.mimo-asr", manifest["version"] as? String == release.version,
              manifest["principalClass"] as? String == "MiMoASRPlugin", manifest["sdkCompatibilityVersion"] as? String == "v1",
              let minimum = manifest["minHostVersion"] as? String, let required = PluginVersion(minimum),
              let host = PluginVersion(hostVersion), host >= required,
              let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "com.tietiezhi.typewhisper.mimo-asr",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "tietiezhi" else { throw PluginUpdateError.incompatible }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let osText = manifest["minOSVersion"] as? String,
              let minOS = PluginVersion(osText.split(separator: ".").count == 2 ? osText + ".0" : osText),
              let currentOS = PluginVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"), currentOS >= minOS else { throw PluginUpdateError.incompatible }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        try PluginUpdateArchive.validateUniversalBinary(Data(contentsOf: candidate.appendingPathComponent("Contents/MacOS/tietiezhi")))
        try Task.checkCancellation()
        // Never execute scripts from the downloaded archive or hot-reload code.
        let backup = root.appendingPathComponent("PluginBackups/update-" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let previous = backup.appendingPathComponent("tietiezhi.bundle")
        do {
            try fm.moveItem(at: destination, to: previous)
            do { try fm.moveItem(at: candidate, to: destination) }
            catch { try fm.moveItem(at: previous, to: destination); throw error }
        } catch { throw PluginUpdateError.install }
    }
}
