import Foundation

enum HostAuth: String, Codable, CaseIterable {
    case password
    case privateKey

    var title: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "私钥"
        }
    }
}

struct HostProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var auth: HostAuth
    var privateKeyPath: String
    var rememberSecret: Bool
    var createdAt: Date
    var lastConnectedAt: Date?
    var notes: String
    /// Optional user-created group.
    var groupID: UUID?
    /// Quick-connect profiles are never written to the host store.
    var isTemporary: Bool
    /// Last edit of the profile itself; cloud sync keeps the newer copy.
    var modifiedAt: Date?
    /// Optional so saved hosts and sync files without the key still decode,
    /// and nil so they are written exactly as before.
    private var localShell: Bool?

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = NSUserName(),
        auth: HostAuth = .password,
        privateKeyPath: String = "",
        rememberSecret: Bool = false,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        notes: String = "",
        groupID: UUID? = nil,
        isTemporary: Bool = false,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.privateKeyPath = privateKeyPath
        self.rememberSecret = rememberSecret
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.notes = notes
        self.groupID = groupID
        self.isTemporary = isTemporary
        self.modifiedAt = modifiedAt
    }

    /// Profiles saved before cloud sync existed count as edited when created.
    var effectiveModifiedAt: Date {
        modifiedAt ?? createdAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "未命名主机" : host
    }

    var endpoint: String {
        if isLocal { return "本机 · \((LocalShellConnection.loginShell as NSString).lastPathComponent)" }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return "\(host):\(port)" }
        return "\(user)@\(host):\(port)"
    }

    var subtitle: String {
        let base = "\(username)@\(host)"
        return port == 22 ? base : "\(base):\(port)"
    }

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
            && (auth != .privateKey || !privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var expandedPrivateKeyPath: String {
        (privateKeyPath as NSString).expandingTildeInPath
    }

    mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        privateKeyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if port < 1 || port > 65535 { port = 22 }
        if name.isEmpty { name = host }
        dropUnusedKeyPath()
    }

    /// The editor pre-fills a key path even for password hosts; a password
    /// host keeps none, so the saved and synced profile does not suggest a key.
    mutating func dropUnusedKeyPath() {
        if auth == .password { privateKeyPath = "" }
    }
}

struct HostGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var sortIndex: Int?
    var modifiedAt: Date?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), sortIndex: Int? = nil,
         modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.modifiedAt = modifiedAt
    }

    var effectiveModifiedAt: Date {
        modifiedAt ?? createdAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名分组" : trimmed
    }
}

extension HostProfile {
    /// A shell on this Mac rather than an SSH host. Always temporary: never
    /// saved, synced or shown in the sidebar.
    var isLocal: Bool {
        get { localShell ?? false }
        set { localShell = newValue ? true : nil }
    }

    static func localShell() -> HostProfile {
        var profile = HostProfile(name: "本地终端", host: "localhost", isTemporary: true)
        profile.isLocal = true
        return profile
    }

    static func quickConnect(host: String, port: Int, username: String, auth: HostAuth) -> HostProfile {
        HostProfile(
            name: host,
            host: host,
            port: port,
            username: username,
            auth: auth,
            isTemporary: true
        )
    }
}
