import AppKit
import Foundation

@MainActor
final class ChatGPTService: ObservableObject {
    static let shared = ChatGPTService()
    struct Registration: Codable, Identifiable {
        let clientID: String
        let subject: String
        let email: String?
        let name: String?
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date?
        var scopes: [String]
        var id: String { clientID }
        var label: String { "\(name ?? email ?? "ChatGPT account") · \(clientID.suffix(6))" }
        var canUsePlan: Bool {
            accessToken?.isEmpty == false && Set(scopes).isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"])
        }
    }
    struct Model: Decodable, Identifiable {
        let slug: String
        let display_name: String
        let visibility: String
        var id: String { slug }
    }
    struct Vault: Codable {
        var registrations: [Registration] = []
        var activeID: String?
    }
    @Published private(set) var registrations: [Registration] = []
    @Published private(set) var activeID: String?
    @Published private(set) var models: [Model] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status: String?
    @Published var selectedModel = ""
    @Published var showWelcome = false
    private var refreshTasks: [String: Task<String, Error>] = [:]
    private var server: ChatGPTCallbackServer?
    private var authorizationGeneration = 0
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let saveVault: (Vault) throws -> Void
    var active: Registration? { registrations.first { $0.id == activeID } }
    var backgroundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pidgy.chatgpt.backgroundAI") }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "pidgy.chatgpt.backgroundAI") }
    }

    private init() {
        transport = { try await URLSession.shared.data(for: $0) }
        saveVault = Self.storeVault
        if let raw = try? KeychainManager.retrieve(for: .chatGPTAccounts),
           let data = raw.data(using: .utf8), let vault = try? JSONDecoder().decode(Vault.self, from: data) {
            registrations = vault.registrations; activeID = vault.activeID
        }
        selectedModel = (try? KeychainManager.retrieve(for: .aiModelChatGPT)) ?? ""
    }

    init(testingVault: Vault, transport: @escaping (URLRequest) async throws -> (Data, URLResponse),
         saveVault: @escaping (Vault) throws -> Void = { _ in }) {
        self.transport = transport; self.saveVault = saveVault
        registrations = testingVault.registrations; activeID = testingVault.activeID
    }

    private func persist() throws {
        try saveVault(Vault(registrations: registrations, activeID: activeID))
    }
    private static func storeVault(_ vault: Vault) throws {
        let data = try JSONEncoder().encode(vault)
        try KeychainManager.save(String(decoding: data, as: UTF8.self), for: .chatGPTAccounts)
    }
    private func hostID() throws -> String {
        if let id = try KeychainManager.retrieve(for: .chatGPTHostID), id.hasPrefix("urn:uuid:") { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        try KeychainManager.save(id, for: .chatGPTHostID)
        return id
    }

    func signIn(registrationID: String? = nil, enablePlan: Bool = false) async throws {
        guard BundledSecrets.chatGPTLocalOSS else { throw ChatGPTAuth.Failure.planNotEnabled }
        guard !isBusy else { return }
        isBusy = true; status = nil
        authorizationGeneration += 1
        let generation = authorizationGeneration
        defer { server?.cancel(); server = nil; isBusy = false }
        let previous = registrations.first { $0.id == registrationID }
        var transaction = ChatGPTAuth.Transaction(redirectURI: "", clientID: previous?.clientID)
        let callbackServer = ChatGPTCallbackServer(expectedState: transaction.state)
        server = callbackServer
        let port = try await callbackServer.start()
        transaction.redirectURI = "http://127.0.0.1:\(port)/auth/callback"
        let url = transaction.authorizationURL(hostID: try hostID(), loginHint: previous?.email,
                                              idTokenHint: previous?.idToken, consent: enablePlan)
        guard NSWorkspace.shared.open(url) else { throw ChatGPTAuth.Failure.cancelled }
        let callback = try await callbackServer.wait()
        let fields = try transaction.exchangeFields(callback: callback)
        let token = try await tokenRequest(fields)
        guard let idToken = token.id_token else { throw ChatGPTAuth.Failure.invalidToken }
        let jwksURL = URL(string: ChatGPTAuth.issuer + "/.well-known/jwks.json")!
        let (data, response) = try await transport(URLRequest(url: jwksURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTAuth.Failure.invalidToken }
        let identity = try ChatGPTAuth.validateIDToken(idToken, keys: JSONDecoder().decode(ChatGPTAuth.JWKS.self, from: data),
                                                     clientID: fields["client_id"]!, nonce: transaction.nonce)
        guard previous == nil || previous?.subject == identity.subject else { throw ChatGPTAuth.Failure.securityCheck }
        try Task.checkCancellation()
        guard generation == authorizationGeneration else { throw CancellationError() }
        let granted = (token.scope ?? "").split(separator: " ").map(String.init)
        let hasPlan = Set(granted).isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"])
        if hasPlan {
            guard token.token_type?.lowercased() == "bearer", token.access_token?.isEmpty == false,
                  let lifetime = token.expires_in, lifetime > 0 else { throw ChatGPTAuth.Failure.invalidToken }
        }
        let record = Registration(clientID: fields["client_id"]!, subject: identity.subject, email: identity.email,
                                  name: identity.name, accessToken: token.access_token, refreshToken: token.refresh_token,
                                  idToken: idToken, expiresAt: token.expires_in.map { Date().addingTimeInterval(Double($0)) }, scopes: granted)
        let oldRecords = registrations; let oldActive = activeID
        registrations.removeAll { $0.id == record.id }; registrations.append(record); activeID = record.id
        do { try persist() } catch { registrations = oldRecords; activeID = oldActive; throw error }
        models = []
        status = hasPlan ? "Connected. Select a model to use your ChatGPT plan." : "Signed in. ChatGPT plan usage wasn't granted."
        if hasPlan {
            let welcomeKey = "pidgy.chatgpt.welcomed." + record.clientID
            if !UserDefaults.standard.bool(forKey: welcomeKey) { showWelcome = true }
            try await loadModels()
        }
    }
    func cancelSignIn() { server?.cancel() }
    func resetLocalState() {
        authorizationGeneration += 1
        server?.cancel()
        refreshTasks.values.forEach { $0.cancel() }; refreshTasks = [:]
        registrations = []; activeID = nil; models = []; selectedModel = ""
        status = nil; showWelcome = false
    }
    func dismissWelcome() {
        if let activeID { UserDefaults.standard.set(true, forKey: "pidgy.chatgpt.welcomed." + activeID) }
        showWelcome = false
    }
    func selectAccount(_ id: String) async throws {
        guard !isBusy, registrations.contains(where: { $0.id == id }) else { return }
        activeID = id; models = []; selectedModel = ""
        try persist()
        if active?.canUsePlan == true { try await loadModels() }
    }
    func saveModel() throws { try KeychainManager.save(selectedModel, for: .aiModelChatGPT) }
    func loadModels() async throws {
        guard let id = activeID else { throw ChatGPTAuth.Failure.signInRequired }
        let token = try await accessToken(for: id)
        var request = URLRequest(url: URL(string: ChatGPTAuth.resource + "/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await transport(request)
        try Self.checkResponse(data, response)
        struct Catalog: Decodable { let models: [Model] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
        guard activeID == id else { throw CancellationError() }
        models = catalog
        if !models.contains(where: { $0.slug == selectedModel }) {
            selectedModel = models.first(where: { $0.slug == "gpt-6-luna" })?.slug ?? models.first?.slug ?? ""
        }
        try saveModel()
    }

    func accessToken(for id: String) async throws -> String {
        guard let record = registrations.first(where: { $0.id == id }), activeID == id,
              record.canUsePlan else { throw ChatGPTAuth.Failure.planNotEnabled }
        if let token = record.accessToken, let expiry = record.expiresAt, expiry > Date().addingTimeInterval(60) { return token }
        if let task = refreshTasks[id] { return try await task.value }
        guard let refresh = record.refreshToken, !refresh.isEmpty else { throw ChatGPTAuth.Failure.signInRequired }
        let task = Task { @MainActor () throws -> String in
            do {
                let next = try await self.tokenRequest(["grant_type": "refresh_token", "client_id": id,
                                                       "refresh_token": refresh, "resource": ChatGPTAuth.resource])
                guard let index = self.registrations.firstIndex(where: { $0.id == id }),
                      self.registrations[index].refreshToken == refresh,
                      let token = next.access_token, !token.isEmpty, next.token_type?.lowercased() == "bearer",
                      let lifetime = next.expires_in, lifetime > 0 else { throw ChatGPTAuth.Failure.invalidToken }
                var updated = self.registrations[index]
                updated.accessToken = token; updated.expiresAt = Date().addingTimeInterval(Double(lifetime))
                updated.refreshToken = next.refresh_token ?? refresh
                if let scope = next.scope { updated.scopes = scope.split(separator: " ").map(String.init) }
                self.registrations[index] = updated
                try self.persist()
                guard updated.canUsePlan else { throw ChatGPTAuth.Failure.planNotEnabled }
                guard self.activeID == id else { throw CancellationError() }
                return token
            } catch let failure as ChatGPTAuth.Failure {
                if case .remote(_, let code, _) = failure,
                   ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code) {
                    self.clearTokens(id: id); try self.persist()
                    throw ChatGPTAuth.Failure.signInRequired
                }
                throw failure
            }
        }
        refreshTasks[id] = task
        defer { refreshTasks[id] = nil }
        return try await task.value
    }

    func signOut() async throws {
        guard let record = active else { return }
        isBusy = true; defer { isBusy = false }
        activeID = nil; models = []; selectedModel = ""
        refreshTasks[record.id]?.cancel(); refreshTasks[record.id] = nil
        var revoked = record.refreshToken == nil
        if let token = record.refreshToken {
            do {
                let discoveryURL = URL(string: ChatGPTAuth.issuer + "/.well-known/openid-configuration")!
                let (data, response) = try await transport(URLRequest(url: discoveryURL))
                try Self.checkResponse(data, response)
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let endpoint = (config?["revocation_endpoint"] as? String).flatMap(URL.init(string:)),
                      endpoint.scheme == "https", endpoint.host == "auth.openai.com" else { throw ChatGPTAuth.Failure.securityCheck }
                var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 15
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = ChatGPTAuth.form(["token": token, "token_type_hint": "refresh_token", "client_id": record.id])
                let (_, result) = try await transport(request)
                revoked = (result as? HTTPURLResponse)?.statusCode == 200
            } catch { revoked = false }
        }
        clearTokens(id: record.id); try persist()
        status = revoked ? "Signed out." : "Signed out locally. Remote revocation wasn't confirmed; disconnect Pidgy in ChatGPT settings."
    }
    private func clearTokens(id: String) {
        guard let index = registrations.firstIndex(where: { $0.id == id }) else { return }
        registrations[index].accessToken = nil; registrations[index].refreshToken = nil
        registrations[index].idToken = nil; registrations[index].expiresAt = nil; registrations[index].scopes = []
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> ChatGPTAuth.TokenResponse {
        var request = URLRequest(url: URL(string: ChatGPTAuth.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTAuth.form(fields)
        let (data, response) = try await transport(request)
        try Self.checkResponse(data, response)
        return try JSONDecoder().decode(ChatGPTAuth.TokenResponse.self, from: data)
    }
    nonisolated static func checkResponse(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuth.Failure.invalidToken }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let nested = body?["error"] as? [String: Any]
            let code = nested?["code"] as? String ?? body?["error"] as? String ?? "request_failed"
            throw ChatGPTAuth.Failure.remote(status: http.statusCode, code: code,
                requestID: http.value(forHTTPHeaderField: "x-request-id") ?? http.value(forHTTPHeaderField: "openai-request-id"))
        }
    }
}
