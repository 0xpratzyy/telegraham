import Foundation

struct HTTPSourceClient: Sendable {
    let session: URLSession
    let bearerToken: String
    let source: IntegrationSource

    init(source: IntegrationSource, bearerToken: String, session: URLSession = .shared) throws {
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SourceAdapterError.invalidCredential }
        self.source = source
        self.bearerToken = token
        self.session = session
    }

    func data(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceAdapterError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(in: data) ?? "Request failed (HTTP \(http.statusCode))."
            if http.statusCode == 401 || http.statusCode == 403 {
                throw SourceAdapterError.invalidCredential
            }
            throw SourceAdapterError.api(source: source, message: message)
        }
        return data
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return object["error"] as? String
    }
}
