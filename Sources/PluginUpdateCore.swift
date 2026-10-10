import Foundation
import CryptoKit

enum PluginUpdateError: LocalizedError {
    case invalidRelease, network, checksum, archive, incompatible, install, busy
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "更新信息无效，或安装包尚未发布完成。"
        case .network: return "无法访问 GitHub 更新服务，请稍后重试。"
        case .checksum: return "安装包 SHA-256 校验失败，未安装。"
        case .archive: return "安装包结构或签名无效，未安装。"
        case .incompatible: return "此更新与当前插件、宿主版本或安装位置不兼容。"
        case .install: return "更新安装失败，旧版已保留；请尝试手动安装。"
        case .busy: return "已有更新正在安装。"
        }
    }
}

struct PluginVersion: Comparable, Sendable {
    let parts: [Int]
    init?(_ text: String) {
        let values = text.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              values.allSatisfy({ (Int($0) ?? -1) >= 0 && (Int($0) ?? Int.max) < 1000000 }) else { return nil }
        parts = values.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct PluginRelease: Sendable {
    static let repository = "tietiezhi-1216/typewhisper-tietiezhi"
    static let page = URL(string: "https://github.com/" + repository + "/releases/latest")!
    let version: String
    let archiveURL: URL
    let checksumURL: URL
    let size: Int
    static func parse(_ data: Data, current: String) throws -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String, tag.hasPrefix("v"),
              let version = PluginVersion(String(tag.dropFirst())), let installed = PluginVersion(current) else { throw PluginUpdateError.invalidRelease }
        guard version > installed else { return nil }
        let text = String(tag.dropFirst()), filename = "tietiezhi-\(text)-macos-universal.zip"
        let assets = object["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) throws -> (URL, Int) {
            guard let item = assets.first(where: { $0["name"] as? String == name }),
                  let raw = item["browser_download_url"] as? String, let url = URL(string: raw),
                  url.absoluteString == "https://github.com/\(repository)/releases/download/\(tag)/\(name)",
                  let size = item["size"] as? Int, size > 0 else { throw PluginUpdateError.invalidRelease }
            return (url, size)
        }
        let archive = try asset(filename), checksum = try asset(filename + ".sha256")
        guard archive.1 <= 32 * 1024 * 1024, checksum.1 <= 4096 else { throw PluginUpdateError.invalidRelease }
        return Self(version: text, archiveURL: archive.0, checksumURL: checksum.0, size: archive.1)
    }
    static func verify(_ data: Data, checksum: Data) throws {
        guard let text = String(data: checksum, encoding: .utf8),
              let expected = text.split(whereSeparator: \.isWhitespace).first,
              expected.count == 64, expected.allSatisfy(\.isHexDigit) else { throw PluginUpdateError.checksum }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw PluginUpdateError.checksum }
    }
}

// Validate central AND local ZIP records before invoking ditto. Reject path
// traversal, symlinks, encryption, ZIP64, excessive entries/expanded size.
enum PluginUpdateArchive {
    // Native Mach-O check; unlike invoking lipo, this needs no Xcode/CLT.
    static func validateUniversalBinary(_ data: Data) throws {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ width: Int, little: Bool = false) throws -> UInt64 {
            guard offset >= 0, offset + width <= bytes.count else { throw PluginUpdateError.archive }
            return (0..<width).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * (little ? $1 : width - 1 - $1)) }
        }
        let magic = try number(0, 4)
        guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { throw PluginUpdateError.archive }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        let wide = magic == 0xcafebabf || magic == 0xbfbafeca
        let count = try number(4, 4, little: little)
        guard count >= 2, count <= 8 else { throw PluginUpdateError.archive }
        var architectures = Set<UInt64>()
        for index in 0..<Int(count) {
            let position = 8 + index * (wide ? 32 : 20)
            let cpu = try number(position, 4, little: little)
            let rawOffset = try number(position + 8, wide ? 8 : 4, little: little)
            let size = try number(position + (wide ? 16 : 12), wide ? 8 : 4, little: little)
            guard let offset = Int(exactly: rawOffset), rawOffset < UInt64(bytes.count), size <= UInt64(bytes.count) - rawOffset,
                  size >= 32, try number(offset, 4, little: true) == 0xfeedfacf,
                  try number(offset + 4, 4, little: true) == cpu else { throw PluginUpdateError.archive }
            architectures.insert(cpu)
        }
        guard architectures.contains(0x01000007), architectures.contains(0x0100000c) else { throw PluginUpdateError.incompatible }
    }
    static func validate(_ data: Data, root: String) throws {
        let bytes = [UInt8](data)
        func number(_ p: Int, _ width: Int) throws -> Int {
            guard p >= 0, p + width <= bytes.count else { throw PluginUpdateError.archive }
            return (0..<width).reduce(0) { $0 | Int(bytes[p + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 22 else { throw PluginUpdateError.archive }
        var end: Int?
        for p in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try number(p, 4) == 0x06054b50, try p + 22 + number(p + 20, 2) == bytes.count { end = p; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw PluginUpdateError.archive }
        let count = try number(end + 10, 2), centralSize = try number(end + 12, 4), start = try number(end + 16, 4)
        guard count > 0, count <= 4096, try number(end + 8, 2) == count, start + centralSize == end else { throw PluginUpdateError.archive }
        var position = start, expanded = 0, names = Set<String>(), hasManifest = false
        for _ in 0..<count {
            guard try number(position, 4) == 0x02014b50 else { throw PluginUpdateError.archive }
            let flags = try number(position + 8, 2), method = try number(position + 10, 2)
            let compressed = try number(position + 20, 4), size = try number(position + 24, 4)
            let length = try number(position + 28, 2), extra = try number(position + 30, 2), comment = try number(position + 32, 2)
            let attributes = try number(position + 38, 4), local = try number(position + 42, 4)
            guard length > 0, length < 1024, position + 46 + length + extra + comment <= end,
                  flags & 1 == 0, [0, 8].contains(method), [0, 0x8000, 0x4000].contains((attributes >> 16) & 0xf000),
                  try number(position + 34, 2) == 0 else { throw PluginUpdateError.archive }
            let nameBytes = Array(bytes[(position + 46)..<(position + 46 + length)])
            guard let name = String(bytes: nameBytes, encoding: .utf8), !name.contains("\\"), !name.contains(":"), !name.contains("\0"), !name.hasPrefix("/"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  name.hasPrefix(root + "/") || name.hasPrefix("__MACOSX/"), names.insert(name).inserted else { throw PluginUpdateError.archive }
            expanded += size
            guard expanded <= 128 * 1024 * 1024, local < start, try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method else { throw PluginUpdateError.archive }
            let localLength = try number(local + 26, 2), localExtra = try number(local + 28, 2)
            guard localLength == length, local + 30 + localLength + localExtra + compressed <= start,
                  Array(bytes[(local + 30)..<(local + 30 + localLength)]) == nameBytes else { throw PluginUpdateError.archive }
            if name == root + "/tietiezhi.bundle/Contents/Resources/manifest.json" { hasManifest = true }
            position += 46 + length + extra + comment
        }
        guard position == end, hasManifest else { throw PluginUpdateError.archive }
    }
}
