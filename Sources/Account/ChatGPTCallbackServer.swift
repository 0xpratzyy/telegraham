import Foundation
import Network

/// Ephemeral port, IPv4 loopback only. A listener is ready before the browser opens.
@MainActor
final class ChatGPTCallbackServer {
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private var timeoutTask: Task<Void, Never>?
    private let expectedState: String

    init(expectedState: String) { self.expectedState = expectedState }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue { self.ready?.resume(returning: port); self.ready = nil }
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000_000) }
            catch { return }
            self?.finish(.failure(ChatGPTAuth.Failure.timedOut))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .global()) }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func wait() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            if let pending { return try pending.get() }
            return try await withCheckedThrowingContinuation { callback = $0 }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel() { finish(.failure(CancellationError())) }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        read(connection, accumulated: Data())
    }
    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let buffer = accumulated + (data ?? Data())
                if buffer.count > 16_384 || error != nil { connection.cancel(); return }
                guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if complete { connection.cancel() }
                    else { self.read(connection, accumulated: buffer) }
                    return
                }
                let params = Self.parameters(request: text, expectedState: self.expectedState)
                let page = params == nil ? "Invalid callback. Return to Pidgy and try again." : "Return to Pidgy to finish signing in. You can close this tab."
                let body = "<html><body><p>\(page)</p></body></html>"
                let response = "HTTP/1.1 \(params == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let params { self.finish(.success(params)) }
            }
        }
    }
    static func parameters(request: String, expectedState: String) -> [String: String]? {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let fields = line.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET", fields[2].hasPrefix("HTTP/1."),
              fields[1].hasPrefix("/auth/callback?"),
              let url = URLComponents(string: "http://127.0.0.1" + String(fields[1]).replacingOccurrences(of: "+", with: "%20")),
              url.path == "/auth/callback" else { return nil }
        var params: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard params[item.name] == nil, let value = item.value else { return nil }
            params[item.name] = value
        }
        guard params["state"] == expectedState else { return nil }
        return params
    }
    private func finish(_ result: Result<[String: String], Error>) {
        guard pending == nil else { return }
        pending = result
        if case .failure(let error) = result { ready?.resume(throwing: error); ready = nil }
        callback?.resume(with: result); callback = nil
        listener?.cancel(); listener = nil
        timeoutTask?.cancel(); timeoutTask = nil
    }
}
