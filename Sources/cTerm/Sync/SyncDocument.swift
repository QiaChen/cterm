import CryptoKit
import Foundation

/// Timestamps used for sync are whole seconds: the host store and the sync
/// file both store ISO 8601 dates, which drop fractions, and comparing a
/// fractional local time with its rounded copy would look like an edit.
enum SyncClock {
    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
}

struct SyncTombstone: Codable, Equatable {
    enum Kind: String, Codable {
        case host
        case group
    }

    var id: UUID
    var kind: Kind
    var deletedAt: Date
}

/// One credential. A nil value records that it was removed at `modifiedAt`.
struct SyncSecret: Codable, Equatable {
    var value: String?
    var modifiedAt: Date
}

struct SyncHost: Codable, Equatable {
    var profile: HostProfile
    var password: SyncSecret?
    var passphrase: SyncSecret?
    /// The private key file's content, for hosts that use a key.
    var privateKey: SyncSecret?
}

/// The plaintext inside the encrypted cloud file.
struct SyncDocument: Codable, Equatable {
    static let formatName = "cterm-hosts"
    static let currentSchema = 1

    var format: String = SyncDocument.formatName
    var schema: Int = SyncDocument.currentSchema
    var hosts: [SyncHost] = []
    var groups: [HostGroup] = []
    var tombstones: [SyncTombstone] = []

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func encoded() throws -> Data {
        try SyncDocument.makeEncoder().encode(normalized())
    }

    static func decode(_ data: Data) throws -> SyncDocument {
        let document = try makeDecoder().decode(SyncDocument.self, from: data)
        guard document.format == formatName else { throw SyncError.notASyncFile }
        guard document.schema <= currentSchema else { throw SyncError.newerFormat }
        return document
    }

    /// Sorted copy, so equal content always encodes to the same bytes.
    func normalized() -> SyncDocument {
        var copy = self
        copy.hosts.sort { $0.profile.id.uuidString < $1.profile.id.uuidString }
        for index in copy.hosts.indices {
            copy.hosts[index].profile.isTemporary = false
            // When a host was last connected is this Mac's history, not
            // configuration; syncing it made every connect look like an edit.
            copy.hosts[index].profile.lastConnectedAt = nil
            copy.hosts[index].profile.dropUnusedKeyPath()
        }
        copy.groups.sort { $0.id.uuidString < $1.id.uuidString }
        copy.tombstones.sort { $0.id.uuidString < $1.id.uuidString }
        return copy
    }

    /// A digest of the content; equal digests mean nothing needs syncing.
    func fingerprint() -> String {
        let data = (try? encoded()) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Merges two copies of the host list.
///
/// - Hosts and groups are matched by UUID; the copy with the newer
///   `modifiedAt` wins as a whole.
/// - Each credential (password, key passphrase, private key) is merged on its own by its
///   own time, because it is saved independently of the profile.
/// - A deletion is a tombstone. It removes the item unless the item was edited
///   after the deletion, in which case the item survives and the tombstone goes.
/// - `lastConnectedAt` is not synced; each Mac keeps its own.
/// - Ties are broken by content, so every device reaches the same result.
enum SyncMerge {
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    static func merge(local: SyncDocument, remote: SyncDocument, now: Date = SyncClock.now()) -> SyncDocument {
        var tombstones: [UUID: SyncTombstone] = [:]
        for stone in local.tombstones + remote.tombstones {
            if let existing = tombstones[stone.id], existing.deletedAt >= stone.deletedAt { continue }
            tombstones[stone.id] = stone
        }

        var hosts: [UUID: SyncHost] = [:]
        for host in local.hosts {
            hosts[host.profile.id] = host
        }
        for host in remote.hosts {
            if let mine = hosts[host.profile.id] {
                hosts[host.profile.id] = mergeHost(mine, host)
            } else {
                hosts[host.profile.id] = host
            }
        }

        var groups: [UUID: HostGroup] = [:]
        for group in local.groups {
            groups[group.id] = group
        }
        for group in remote.groups {
            if let mine = groups[group.id] {
                groups[group.id] = newer(mine, group, date: \.effectiveModifiedAt)
            } else {
                groups[group.id] = group
            }
        }

        for (id, stone) in tombstones {
            switch stone.kind {
            case .host:
                if let host = hosts[id] {
                    if host.profile.effectiveModifiedAt > stone.deletedAt {
                        tombstones[id] = nil
                    } else {
                        hosts[id] = nil
                    }
                }
            case .group:
                if let group = groups[id] {
                    if group.effectiveModifiedAt > stone.deletedAt {
                        tombstones[id] = nil
                    } else {
                        groups[id] = nil
                    }
                }
            }
        }

        let cutoff = now.addingTimeInterval(-tombstoneLifetime)
        let liveStones = tombstones.values.filter { $0.deletedAt >= cutoff }

        var result = SyncDocument()
        result.hosts = Array(hosts.values)
        for index in result.hosts.indices {
            if let groupID = result.hosts[index].profile.groupID, groups[groupID] == nil {
                result.hosts[index].profile.groupID = nil
            }
        }
        result.groups = Array(groups.values)
        result.tombstones = liveStones
        return result.normalized()
    }

    static func mergeHost(_ a: SyncHost, _ b: SyncHost) -> SyncHost {
        let profile = newer(a.profile, b.profile, date: \.effectiveModifiedAt)
        return SyncHost(
            profile: profile,
            password: newerSecret(a.password, b.password),
            passphrase: newerSecret(a.passphrase, b.passphrase),
            privateKey: newerSecret(a.privateKey, b.privateKey)
        )
    }

    static func newerSecret(_ a: SyncSecret?, _ b: SyncSecret?) -> SyncSecret? {
        guard let a else { return b }
        guard let b else { return a }
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt ? a : b }
        // Same time: prefer a value over a removal, then the larger value.
        switch (a.value, b.value) {
        case (nil, _): return b
        case (_, nil): return a
        case let (x?, y?): return x >= y ? a : b
        }
    }

    private static func newer<T: Codable>(_ a: T, _ b: T, date: KeyPath<T, Date>) -> T {
        let left = a[keyPath: date]
        let right = b[keyPath: date]
        if left != right { return left > right ? a : b }
        let encoder = SyncDocument.makeEncoder()
        let x = (try? encoder.encode(a)) ?? Data()
        let y = (try? encoder.encode(b)) ?? Data()
        return x.lexicographicallyPrecedes(y) ? b : a
    }
}

enum SyncError: LocalizedError, Equatable {
    case wrongPassword
    case passwordMissing
    case notASyncFile
    case newerFormat
    case unsupportedParameters
    case notConfigured
    case notSignedIn
    case conflict
    case network(String)
    case server(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return "同步密码不正确，或云端文件已损坏。"
        case .passwordMissing:
            return "本机没有保存同步密码，请重新输入。"
        case .notASyncFile:
            return "所选文件不是 cTerm 同步文件。"
        case .newerFormat:
            return "云端文件由更新版本的 cTerm 创建，请先升级。"
        case .unsupportedParameters:
            return "云端文件的加密参数不受支持。"
        case .notConfigured:
            return "尚未配置云同步。"
        case .notSignedIn:
            return "OneDrive 授权已失效，请重新登录。"
        case .conflict:
            return "云端文件同时被其他设备修改，请稍后重试。"
        case .network(let message):
            return "网络错误：\(message)"
        case .server(let code, let message):
            return "OneDrive 返回错误 \(code)：\(message)"
        case .cancelled:
            return "已取消。"
        }
    }
}
