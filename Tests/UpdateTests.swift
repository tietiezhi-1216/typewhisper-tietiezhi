import Foundation
import CryptoKit

extension Tests {
    static func updateFixture(version: String, size: Int) -> [String: Any] {
        let filename = "tietiezhi-\(version)-macos-universal.zip"
        return ["draft": false, "prerelease": false, "tag_name": "v" + version, "assets": [
            ["name": filename, "size": size, "browser_download_url": "https://github.com/\(PluginRelease.repository)/releases/download/v\(version)/\(filename)"],
            ["name": filename + ".sha256", "size": 100, "browser_download_url": "https://github.com/\(PluginRelease.repository)/releases/download/v\(version)/\(filename).sha256"]]]
    }
    static func plainZip(_ names: [String], mode: Int = 0x81a40000) -> Data {
        var locals = Data(), central = Data()
        func put(_ value: Int, _ count: Int, into data: inout Data) {
            for i in 0..<count { data.append(UInt8((value >> (8 * i)) & 255)) }
        }
        for name in names {
            let bytes = Data(name.utf8), offset = locals.count
            put(0x04034b50, 4, into: &locals); put(20, 2, into: &locals)
            for _ in 0..<4 { put(0, 2, into: &locals) }
            for _ in 0..<3 { put(0, 4, into: &locals) }
            put(bytes.count, 2, into: &locals); put(0, 2, into: &locals); locals.append(bytes)
            put(0x02014b50, 4, into: &central); put(0x0314, 2, into: &central); put(20, 2, into: &central)
            for _ in 0..<4 { put(0, 2, into: &central) }
            for _ in 0..<3 { put(0, 4, into: &central) }
            put(bytes.count, 2, into: &central)
            for _ in 0..<4 { put(0, 2, into: &central) }
            put(mode, 4, into: &central); put(offset, 4, into: &central); central.append(bytes)
        }
        var end = Data()
        put(0x06054b50, 4, into: &end); put(0, 2, into: &end); put(0, 2, into: &end)
        put(names.count, 2, into: &end); put(names.count, 2, into: &end)
        put(central.count, 4, into: &end); put(locals.count, 4, into: &end); put(0, 2, into: &end)
        return locals + central + end
    }
    @MainActor static func updateTests() async throws {
        expect(PluginVersion("0.10.0")! > PluginVersion("0.9.9")!, "Compare update versions numerically")
        for value in ["v1.2.3", "1.2", "1.2.3-beta", "-1.2.3", "1..3", "١.2.3"] {
            expect(PluginVersion(value) == nil, "Reject unsafe/non-stable version: \(value)")
        }
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: "manifest.json"))
        let currentManifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        let version = currentManifest["version"] as! String, root = "tietiezhi-" + version
        let package = try Data(contentsOf: URL(fileURLWithPath: "build/tietiezhi-\(version)-macos-universal.zip"))
        let fixture = updateFixture(version: version, size: package.count)
        let release = try PluginRelease.parse(JSONSerialization.data(withJSONObject: fixture), current: "0.4.0")!
        expect(release.version == version, "Parse complete release assets from fixed publisher")
        let noUpdate = try PluginRelease.parse(JSONSerialization.data(withJSONObject: fixture), current: version)
        expect(noUpdate == nil, "Never reinstall same version or downgrade")
        for key in ["draft", "prerelease"] {
            var changed = fixture; changed[key] = true
            expectError("Reject unpublished/prerelease update") { _ = try PluginRelease.parse(JSONSerialization.data(withJSONObject: changed), current: "0.4.0") }
        }
        var changed = fixture
        changed["assets"] = [["name": "tietiezhi-\(version)-macos-universal.zip", "size": package.count, "browser_download_url": "https://evil.invalid/payload.zip"]]
        expectError("Reject arbitrary update download origins") { _ = try PluginRelease.parse(JSONSerialization.data(withJSONObject: changed), current: "0.4.0") }
        changed = fixture; changed["assets"] = []
        expectError("Reject releases without complete ZIP/checksum assets") { _ = try PluginRelease.parse(JSONSerialization.data(withJSONObject: changed), current: "0.4.0") }
        let checksum = Data((SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined() + "  update.zip\n").utf8)
        try PluginRelease.verify(package, checksum: checksum)
        expectError("Corrupted download fails SHA-256") { try PluginRelease.verify(package + Data([1]), checksum: checksum) }
        try PluginUpdateArchive.validateUniversalBinary(Data(contentsOf: URL(fileURLWithPath: "build/tietiezhi.bundle/Contents/MacOS/tietiezhi")))
        print("PASS: Universal binary architecture validation needs no developer tools")
        expectError("Reject invalid Mach-O update") { try PluginUpdateArchive.validateUniversalBinary(Data("not a binary".utf8)) }
        try PluginUpdateArchive.validate(package, root: root)
        print("PASS: actual Universal release archive passes bounded ZIP preflight")
        let manifest = root + "/tietiezhi.bundle/Contents/Resources/manifest.json"
        try PluginUpdateArchive.validate(plainZip([manifest]), root: root)
        for name in ["../outside", root + "/../../outside", "/tmp/outside", root + "/..\\outside", root + "/a/./bad"] {
            expectError("Reject unsafe ZIP path") { try PluginUpdateArchive.validate(plainZip([manifest, name]), root: root) }
        }
        expectError("Reject ZIP symlinks before extraction") { try PluginUpdateArchive.validate(plainZip([manifest], mode: 0xa1ff0000), root: root) }
        expectError("Reject ZIP duplicate paths") { try PluginUpdateArchive.validate(plainZip([manifest, manifest]), root: root) }
        expectError("Reject truncated ZIP") { try PluginUpdateArchive.validate(Data(package.prefix(50)), root: root) }
        expectError("Reject ZIP without plugin manifest") { try PluginUpdateArchive.validate(plainZip([root + "/readme"]), root: root) }

        // Full native updater test: real ditto, codesign, architecture checks,
        // replacement and backup, with injected local bytes and a TEMP root.
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("tietiezhi-update-test-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("Plugins/tietiezhi.bundle")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "build/tietiezhi.bundle"), to: destination)
        let infoURL = destination.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
        info["CFBundleShortVersionString"] = "0.4.0"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let sentinel = temporary.appendingPathComponent("preferences-sentinel")
        try Data("keep settings".utf8).write(to: sentinel)
        let service = PluginUpdateService(transport: { url, _ in url.path.hasSuffix(".sha256") ? checksum : package }, installationRoot: temporary)
        do { try await service.install(release, currentBundle: destination, hostVersion: "1.0.0"); fatalError("Incompatible update installed") }
        catch PluginUpdateError.incompatible { print("PASS: incompatible host rejects update before replacing old plugin") }
        try await service.install(release, currentBundle: destination, hostVersion: "1.7.1")
        let updated = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
        expect(updated["CFBundleShortVersionString"] as? String == version, "Native updater installs verified Universal bundle")
        expect(tryData(sentinel) == "keep settings", "Updater never edits preferences or credentials")
        let backups = try fm.contentsOfDirectory(at: temporary.appendingPathComponent("PluginBackups"), includingPropertiesForKeys: nil)
        expect(backups.count == 1 && fm.fileExists(atPath: backups[0].appendingPathComponent("tietiezhi.bundle/Contents/Info.plist").path), "Native updater backs up previous bundle")
        do { try await service.install(release, currentBundle: destination, hostVersion: "1.7.1"); fatalError("Same-version replacement accepted") }
        catch PluginUpdateError.incompatible { print("PASS: on-disk version prevents duplicate installation until restart") }
    }
    static func tryData(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }
}
