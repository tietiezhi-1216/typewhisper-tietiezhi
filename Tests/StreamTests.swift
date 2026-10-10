import Foundation

extension Tests {
    static func streamTests() throws {
        let stream = """
        : keepalive

        data: {"response":{"candidates":[{"content":{"parts":[{"thought":true,"text":"private reasoning"}]}}]}}

        data: {"response":{"candidates":[{"content":{"parts":[{"text":"你好，"}]}}]}}

        data: {"response":{"candidates":[{"content":{"parts":[{"text":"世界。"}]},"finishReason":"STOP"}]}}

        data: [DONE]

        """
        let result = try AntigravityCore.streamText(Data(stream.utf8))
        expect(result == "你好，世界。", "Aggregate SSE text and strip private reasoning")
        let crlf = try AntigravityCore.streamText(Data(stream.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        expect(crlf == result, "Accept CRLF stream framing")
        let multiline = "data: {\"response\":\ndata: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"done\"}]},\"finishReason\":\"STOP\"}]}}\n\n"
        let multiResult = try AntigravityCore.streamText(Data(multiline.utf8))
        expect(multiResult == "done", "Join multiline SSE data events")
        expectError("Reject prematurely closed stream") {
            _ = try AntigravityCore.streamText(Data("data: {\"response\":{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}}\n\n".utf8))
        }
        expectError("Reject MAX_TOKENS instead of inserting partial text") {
            _ = try AntigravityCore.streamText(Data(stream.replacingOccurrences(of: "STOP", with: "MAX_TOKENS").utf8))
        }
        expectError("Stream errors cannot be mistaken for successful completion") {
            _ = try AntigravityCore.streamText(Data((stream + "data: {\"error\":{\"message\":\"private secret\"}}\n\n").utf8))
        }
        expectError("Reject malformed SSE JSON") { _ = try AntigravityCore.streamText(Data("data: {bad}\n\n".utf8)) }
        expectError("Reject empty stream") { _ = try AntigravityCore.streamText(Data()) }
        let quota = "data: {\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"private secret\"},\"usageMetadata\":{}}\n\n"
        do { _ = try AntigravityCore.streamText(Data(quota.utf8)); fatalError("SSE quota accepted") }
        catch let error as AntigravityHTTPError {
            expect(error.status == 429 && error.stage == .generate && !error.localizedDescription.contains("private secret"), "SSE quota error preserves status but never raw messages")
        }
        expectError("JSON completion also requires explicit STOP") {
            _ = try AntigravityCore.streamText(Data(#"{"candidates":[{"content":{"parts":[{"text":"partial"}]}}]}"#.utf8))
        }
        let json = try AntigravityCore.streamText(Data(#"{"response":{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"json"}]}}]}}"#.utf8))
        expect(json == "json", "Accept JSON completion fallback on stream endpoint")
    }
}
