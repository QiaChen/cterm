import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// A file in cTerm's OneDrive app folder.
struct DriveItem: Decodable, Equatable {
    struct FileFacet: Decodable, Equatable {}

    var id: String
    var name: String
    var size: Int64?
    var lastModifiedDateTime: String?
    /// Changes with every write; uploads send it as If-Match.
    var eTag: String?
    var file: FileFacet?
    var downloadURL: String?

    var byteCount: Int64 { size ?? 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, size, lastModifiedDateTime, eTag, file
        case downloadURL = "@microsoft.graph.downloadUrl"
    }
}

/// OneDrive access through Microsoft Graph.
///
/// Sign-in is the OAuth 2.0 authorization code flow with PKCE for a public
/// client, shown in an `ASWebAuthenticationSession`; the app never sees the
/// Microsoft password and needs no client secret. It asks only for
/// `Files.ReadWrite.AppFolder`, so cTerm can see just its own folder
/// (`Apps/cTerm`), not the rest of the user's OneDrive. The refresh token is
/// kept in the credential store and access tokens only in memory.
@MainActor
final class OneDriveClient: NSObject {
    static let scopes = "offline_access User.Read Files.ReadWrite.AppFolder"
    private static let refreshTokenAccount = "onedrive.refreshToken"
    private static let graph = "https://graph.microsoft.com/v1.0"
    private static let appFolder = "\(graph)/me/drive/special/approot"

    var clientID: String
    /// "common" accepts personal and work/school accounts.
    var tenant: String

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?
    private weak var anchorWindow: NSWindow?

    init(clientID: String, tenant: String = "common") {
        self.clientID = clientID
        self.tenant = tenant
    }

    /// The redirect URI registered for the Azure app ("Mobile and desktop
    /// applications"). The authentication session catches it itself, so the
    /// scheme needs no registration with macOS.
    static let callbackScheme = "cterm"
    static let redirectURI = "cterm://auth"

    var isSignedIn: Bool {
        CredentialStore.loadItem(account: Self.refreshTokenAccount, service: CredentialStore.syncService) != nil
    }

    /// Forgets the tokens. Microsoft has no token revocation endpoint for
    /// public clients; the user can remove cTerm's access in their account.
    func signOut() {
        accessToken = nil
        accessTokenExpiry = .distantPast
        CredentialStore.deleteItem(account: Self.refreshTokenAccount, service: CredentialStore.syncService)
    }

    // MARK: - Sign-in

    func signIn(from window: NSWindow?) async throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw SyncError.notConfigured }
        let verifier = Self.base64URL(SyncCrypto.randomBytes(32))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.base64URL(SyncCrypto.randomBytes(16))
        let redirect = Self.redirectURI

        var components = URLComponents(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        anchorWindow = window
        let callback = try await presentAuthSession(url: components.url!, scheme: Self.callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? SyncError.cancelled : SyncError.server(400, value("error_description") ?? error)
        }
        guard value("state") == state, let code = value("code") else {
            throw SyncError.server(400, "授权回调无效")
        }
        try await requestToken([
            "client_id": id,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "code_verifier": verifier,
            "scope": Self.scopes
        ])
    }

    private func presentAuthSession(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SyncError.cancelled)
                } else {
                    continuation.resume(throwing: SyncError.network(error?.localizedDescription ?? "登录失败"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            if !session.start() {
                continuation.resume(throwing: SyncError.network("无法打开登录窗口"))
            }
        }
    }

    // MARK: - Tokens

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let refresh = CredentialStore.loadItem(account: Self.refreshTokenAccount,
                                                     service: CredentialStore.syncService) else {
            throw SyncError.notSignedIn
        }
        try await requestToken([
            "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": Self.scopes
        ])
        guard let accessToken else { throw SyncError.notSignedIn }
        return accessToken
    }

    private struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var expires_in: Double?
        var error: String?
        var error_description: String?
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, response) = try await send(request)
        let token = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard response.statusCode == 200, let access = token?.access_token else {
            if token?.error == "invalid_grant" || token?.error == "interaction_required" {
                accessToken = nil
                CredentialStore.deleteItem(account: Self.refreshTokenAccount, service: CredentialStore.syncService)
                throw SyncError.notSignedIn
            }
            throw SyncError.server(response.statusCode, token?.error_description ?? token?.error ?? "令牌请求失败")
        }
        accessToken = access
        accessTokenExpiry = Date().addingTimeInterval(token?.expires_in ?? 3000)
        // Microsoft rotates refresh tokens; always keep the newest.
        if let refresh = token?.refresh_token {
            CredentialStore.saveItem(refresh, account: Self.refreshTokenAccount, service: CredentialStore.syncService)
        }
    }

    // MARK: - Graph

    func accountName() async throws -> String? {
        struct Me: Decodable {
            var displayName: String?
            var mail: String?
            var userPrincipalName: String?
        }
        let me = try JSONDecoder().decode(
            Me.self, from: await request("GET", "\(Self.graph)/me?$select=displayName,mail,userPrincipalName"))
        return me.mail ?? me.userPrincipalName ?? me.displayName
    }

    /// The files in cTerm's app folder (from any device signed in to this account).
    func listFiles() async throws -> [DriveItem] {
        struct Page: Decodable {
            var value: [DriveItem]
            var next: String?
            enum CodingKeys: String, CodingKey {
                case value
                case next = "@odata.nextLink"
            }
        }
        var items: [DriveItem] = []
        var url = "\(Self.appFolder)/children?$top=200&$select=id,name,size,lastModifiedDateTime,eTag,file"
        while true {
            let page = try JSONDecoder().decode(Page.self, from: await request("GET", url))
            items += page.value.filter { $0.file != nil }
            guard let next = page.next, items.count < 1000 else { break }
            url = next
        }
        return items.sorted { ($0.lastModifiedDateTime ?? "") > ($1.lastModifiedDateTime ?? "") }
    }

    func item(id: String) async throws -> DriveItem {
        try JSONDecoder().decode(DriveItem.self, from: await request("GET", "\(Self.graph)/me/drive/items/\(id)"))
    }

    /// Downloads the file together with the eTag it had, for the conditional
    /// upload that follows.
    func download(id: String) async throws -> (data: Data, item: DriveItem) {
        let meta = try await item(id: id)
        if meta.byteCount == 0 { return (Data(), meta) }
        if let link = meta.downloadURL, let url = URL(string: link) {
            // Short-lived pre-authenticated URL; no bearer token is sent.
            let (body, response) = try await send(URLRequest(url: url))
            guard response.statusCode == 200 else { throw SyncError.server(response.statusCode, "下载失败") }
            return (body, meta)
        }
        return (try await request("GET", "\(Self.graph)/me/drive/items/\(id)/content"), meta)
    }

    /// Replaces the file content only if it is still at `expectedVersion`
    /// (its eTag); otherwise Graph answers 412 and this throws `.conflict`.
    func upload(id: String, data: Data, expectedVersion: String?) async throws -> DriveItem {
        var headers = ["Content-Type": "application/octet-stream"]
        if let expectedVersion { headers["If-Match"] = expectedVersion }
        let body = try await request("PUT", "\(Self.graph)/me/drive/items/\(id)/content", body: data, headers: headers)
        return try JSONDecoder().decode(DriveItem.self, from: body)
    }

    /// Creates a new file in the app folder; fails if the name is taken.
    func create(name: String, data: Data) async throws -> DriveItem {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let body = try await request(
            "PUT", "\(Self.appFolder):/\(encoded):/content?@microsoft.graph.conflictBehavior=fail",
            body: data, headers: ["Content-Type": "application/octet-stream"]
        )
        return try JSONDecoder().decode(DriveItem.self, from: body)
    }

    private func request(_ method: String, _ urlString: String, body: Data? = nil,
                         headers: [String: String] = [:], retried: Bool = false) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SyncError.server(0, "无效的地址") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401 where !retried:
            accessToken = nil
            return try await self.request(method, urlString, body: body, headers: headers, retried: true)
        case 401:
            throw SyncError.notSignedIn
        case 404:
            throw SyncError.server(404, "找不到同步文件，可能已被删除。")
        case 409:
            throw SyncError.server(409, "已有同名文件，请换一个文件名。")
        case 412:
            throw SyncError.conflict
        default:
            struct GraphError: Decodable {
                struct Inner: Decodable { var message: String? }
                var error: Inner?
            }
            let message = (try? JSONDecoder().decode(GraphError.self, from: data))?.error?.message
            throw SyncError.server(response.statusCode, message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.network("无效的响应") }
            return (data, http)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

extension OneDriveClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchorWindow ?? NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}
