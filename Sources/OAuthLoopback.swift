import AppKit
import Foundation
import Network

// Exists only while the user is signing in. Bound to IPv4 loopback, not LAN.
@MainActor final class OAuthLoopback {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var openedBrowser = false
    private var completed = false
    private var connections: [UUID: NWConnection] = [:]
    private let state: String
    private let authURL: URL
    private let port: UInt16
    typealias Browser = @MainActor @Sendable (URL, UInt16) -> Bool
    private let openBrowser: Browser
    private let queue = DispatchQueue(label: "typewhisper.antigravity.oauth")
    init(url: URL, state: String, port: UInt16, openBrowser: @escaping Browser) {
        self.authURL = url; self.state = state; self.port = port; self.openBrowser = openBrowser
    }

    static func authenticate(url: URL, state: String, port: UInt16 = 36742,
                             openBrowser: @escaping Browser = { url, _ in NSWorkspace.shared.open(url) }) async throws -> String {
        let server = OAuthLoopback(url: url, state: state, port: port, openBrowser: openBrowser)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                server.continuation = continuation
                server.start()
            }
        } onCancel: {
            Task { @MainActor in server.finish(.failure(CancellationError())) }
        }
    }

    private func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self, !self.completed else { return }
                    switch status {
                    case .ready:
                        guard !self.openedBrowser else { return }
                        self.openedBrowser = true
                        guard let port = self.listener?.port else { self.finish(.failure(AntigravityError.invalidResponse)); return }
                        if !self.openBrowser(self.authURL, port.rawValue) { self.finish(.failure(AntigravityError.browser)) }
                    case .failed:
                        self.finish(.failure(NSError(domain: "AntigravityOAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法监听本机 36742 端口，可能已被其他登录流程占用。"])))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                self?.finish(.failure(AntigravityError.timedOut))
            }
        } catch { finish(.failure(error)) }
    }

    private func accept(_ connection: NWConnection) {
        guard !completed, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, previous: Data())
        // A stalled local connection cannot occupy a slot forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let pending = self.connections.removeValue(forKey: id) else { return }
            pending.cancel()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, !self.completed else { connection.cancel(); return }
                var buffer = previous
                if let data { buffer.append(data) }
                guard buffer.count <= 8192 else { self.reply(connection, id: id, status: 400, message: "Invalid request"); return }
                guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if done || error != nil { self.connections.removeValue(forKey: id); connection.cancel() }
                    else { self.receive(connection, id: id, previous: buffer) }
                    return
                }
                guard let firstLine = String(data: buffer, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
                    self.reply(connection, id: id, status: 400, message: "Invalid request"); return
                }
                let fields = firstLine.split(separator: " ")
                guard fields.count == 3, fields[0] == "GET", fields[1].hasPrefix("/oauth-callback?") else {
                    self.reply(connection, id: id, status: 404, message: "Not found"); return
                }
                do {
                    let code = try AntigravityCore.callback(String(fields[1]), expectedState: self.state)
                    self.reply(connection, id: id, status: 200, message: "Authorization received. Return to TypeWhisper to see the final login result.", result: .success(code))
                } catch AntigravityError.denied {
                    self.reply(connection, id: id, status: 400, message: "Authorization declined.", result: .failure(AntigravityError.denied))
                } catch {
                    // Unrelated or forged callbacks must not cancel a valid login.
                    self.reply(connection, id: id, status: 400, message: "Invalid OAuth state or callback.")
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, id: UUID, status: Int, message: String, result: Result<String, any Error>? = nil) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.connections.removeValue(forKey: id)
                if let result { self?.finish(result) }
            }
        })
    }

    private func finish(_ result: Result<String, any Error>) {
        guard !completed else { return }
        completed = true
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
