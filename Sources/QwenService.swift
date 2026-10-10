import Foundation

final class QwenNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    static func session(resourceTimeout: TimeInterval = 180) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config, delegate: QwenNoRedirects(), delegateQueue: nil)
    }
}
struct QwenService: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let transport: Transport
    let pollDelay: Duration
    init(transport: Transport? = nil, pollDelay: Duration = .seconds(2)) {
        self.pollDelay = pollDelay
        if let transport { self.transport = transport }
        else {
            let session = QwenNoRedirects.session()
            self.transport = { request in
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw QwenError.response }
                // Bounded errors, task metadata and downloaded transcript JSON.
                let limit = (200..<300).contains(http.statusCode) ? 16_000_000 : 64_000
                if response.expectedContentLength > limit { throw QwenError.response }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < limit else { throw QwenError.response }
                    data.append(byte)
                }
                return (data, http)
            }
        }
    }
    func fetch(_ request: URLRequest, stage: String) async throws -> Data {
        try Task.checkCancellation()
        do {
            let (data, http) = try await transport(request)
            try Task.checkCancellation()
            guard (200..<300).contains(http.statusCode) else { throw QwenError.http(stage, http.statusCode) }
            guard data.count <= 16_000_000 else { throw QwenError.response }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as QwenError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw QwenError.network // Never show URLs, authorization, transcripts or server messages.
        }
    }
    func transcribe(samples: [Float], model: QwenModel, key: String, region: QwenRegion, language: String?, prompt: String?) async throws -> String {
        guard !samples.isEmpty, samples.count <= QwenCore.maxSamples, samples.allSatisfy({ $0.isFinite }) else { throw QwenError.audio }
        guard !model.wire.live else { throw QwenError.notRealtime }
        if model.wire == .file || model.wire == .qwenFile {
            let wav = try MiMoCore.wav(samples[...])
            return try await file(wav: wav, model: model, key: key, region: region, language: language, prompt: prompt)
        }
        var texts: [String] = []
        for start in stride(from: 0, to: samples.count, by: MiMoCore.chunkSamples) {
            try Task.checkCancellation()
            let end = min(start + MiMoCore.chunkSamples, samples.count)
            let wav = try MiMoCore.wav(samples[start..<end])
            let request = try QwenCore.synchronous(model: model, wav: wav, key: key, region: region, language: language, prompt: prompt)
            texts.append(try QwenCore.synchronousText(await fetch(request, stage: "识别"), wire: model.wire))
        }
        return MiMoCore.join(texts)
    }
    func file(wav: Data, model: QwenModel, key: String, region: QwenRegion, language: String?, prompt: String?) async throws -> String {
        // Official DashScope temporary OSS policy: API Key alone, no personal OSS
        // bucket/account needed. Temporary object expires per Alibaba's policy.
        var policyRequest = try QwenCore.request(region: region, path: "/api/v1/uploads", key: key)
        var parts = URLComponents(url: policyRequest.url!, resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "action", value: "getPolicy"), .init(name: "model", value: model.id)]
        policyRequest.url = parts.url!
        let policy = try QwenCore.object(await fetch(policyRequest, stage: "获取临时上传凭证"))
        guard let output = policy["output"] as? [String: Any], let host = output["upload_host"] as? String,
              let directory = output["upload_dir"] as? String, !directory.isEmpty,
              !directory.utf8.contains(13), !directory.utf8.contains(10) else { throw QwenError.response }
        let objectKey = directory + "/" + UUID().uuidString + ".wav"
        let mapping = ["OSSAccessKeyId": "oss_access_key_id", "Signature": "signature", "policy": "policy",
                       "x-oss-object-acl": "x_oss_object_acl", "x-oss-forbid-overwrite": "x_oss_forbid_overwrite"]
        var fields = ["key": objectKey, "success_action_status": "200", "x-oss-content-type": "audio/wav"]
        for (name, source) in mapping {
            guard let value = output[source] as? String, !value.utf8.contains(13), !value.utf8.contains(10) else { throw QwenError.response }
            fields[name] = value
        }
        let boundary = "tietiezhi-" + UUID().uuidString
        var data = Data()
        for name in fields.keys.sorted() {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(fields[name]!)\r\n".utf8))
        }
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        data.append(wav)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var upload = URLRequest(url: try QwenCore.storageURL(host), timeoutInterval: 180)
        upload.httpMethod = "POST"
        upload.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        upload.httpBody = data
        _ = try await fetch(upload, stage: "上传录音")
        let submit = try QwenCore.submission(model: model, url: "oss://" + objectKey, key: key, region: region, language: language, prompt: prompt)
        let created = try QwenCore.object(await fetch(submit, stage: "提交文件转写"))
        guard let createdOutput = created["output"] as? [String: Any],
              let id = createdOutput["task_id"] as? String, UUID(uuidString: id) != nil else { throw QwenError.response }
        let query = try QwenCore.request(region: region, path: "/api/v1/tasks/" + id, key: key)
        let deadline = ContinuousClock.now + .seconds(1800)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let task = try QwenCore.object(await fetch(query, stage: "查询文件转写"))
            guard let output = task["output"] as? [String: Any], output["task_id"] as? String == id,
                  let status = output["task_status"] as? String else { throw QwenError.response }
            switch status {
            case "SUCCEEDED":
                let result = URLRequest(url: try QwenCore.resultURL(output, wire: model.wire), timeoutInterval: 60)
                return try QwenCore.fileText(await fetch(result, stage: "获取识别结果"))
            case "PENDING", "RUNNING": try await Task.sleep(for: pollDelay)
            case "FAILED", "CANCELED", "CANCELLED", "UNKNOWN": throw QwenError.failed("文件转写")
            default: throw QwenError.response
            }
        }
        throw QwenError.timeout
    }
}
