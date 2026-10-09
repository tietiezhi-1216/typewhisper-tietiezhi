import Foundation

// Independent of the host SDK so the wire format can be tested without the app.
enum MiMoError: LocalizedError {
    case missingKey, invalidResponse, oversizedAudio, invalidAudio, translationUnsupported
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在 MiMo ASR 插件设置中保存 API Key。"
        case .invalidResponse: return "MiMo 返回的数据不是有效的识别结果。"
        case .oversizedAudio: return "音频超过 MiMo 单次请求大小限制。"
        case .invalidAudio: return "录音数据为空或无效。"
        case .translationUnsupported: return "MiMo ASR 仅支持转录，请关闭翻译模式。"
        case .http(401), .http(403): return "MiMo 认证失败，请检查 API Key 和账户权限。"
        case .http(429): return "MiMo 请求受限，请检查账户额度并稍后重试。"
        case .http(let code): return "MiMo API 错误（HTTP \(code)）。请检查服务状态及账户。"
        }
    }
}

enum MiMoCore {
    static let endpoint = URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!
    static let model = "mimo-v2.5-asr"
    // 180 s of mono 16-bit 16 kHz WAV is ~7.7 MB after base64.
    static let chunkSamples = 180 * 16_000

    static func languageCode(_ language: String?) -> String {
        let value = language?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "auto"
        if value == "zh" || value.hasPrefix("zh-") { return "zh" }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        return "auto"
    }

    static func wav(_ samples: ArraySlice<Float>) throws -> Data {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw MiMoError.invalidAudio }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16((min(1, max(-1, sample)) * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var output = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { output.append(contentsOf: $0) }
        }
        output.append(Data("RIFF".utf8)); append(UInt32(36 + pcm.count))
        output.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000))
        append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        output.append(Data("data".utf8)); append(UInt32(pcm.count)); output.append(pcm)
        return output
    }

    static func request(wav: Data, key: String, language: String?) throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MiMoError.missingKey }
        let encoded = wav.base64EncodedString()
        guard encoded.utf8.count <= 10_000_000 else { throw MiMoError.oversizedAudio }
        let body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "user", "content": [[
                "type": "input_audio", "input_audio": ["data": "data:audio/wav;base64," + encoded, "format": "wav"]
            ]]]],
            "asr_options": ["language": languageCode(language)]
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func text(from data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw MiMoError.http(status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { throw MiMoError.invalidResponse }
        if let text = message["content"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let items = message["content"] as? [[String: Any]] {
            let texts = items.compactMap { ($0["text"] ?? $0["content"]) as? String }
            guard !texts.isEmpty else { throw MiMoError.invalidResponse }
            return texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw MiMoError.invalidResponse
    }

    static func join(_ texts: [String]) -> String {
        var result = ""
        for text in texts where !text.isEmpty {
            // Separate ASCII words, but avoid adding spaces between Chinese chunks.
            if let last = result.last, let first = text.first,
               last.isASCII, first.isASCII, last.isLetter || last.isNumber,
               first.isLetter || first.isNumber { result += " " }
            result += text
        }
        return result
    }
}
