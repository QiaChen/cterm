import CryptoKit
import Foundation
import Security

extension Notification.Name {
    /// Posted when a host credential is saved or removed; the object is the account.
    static let ctermCredentialsDidChange = Notification.Name("cterm.credentialsDidChange")
}

/// Saved passwords, key passphrases, private key copies, the sync password
/// and the OneDrive refresh token, in `credentials.json` in the app's support
/// folder.
///
/// The file is sealed with AES-256-GCM under a random 256-bit key kept in the
/// login keychain (this Mac only, readable while the Mac is unlocked), so
/// nothing has to be typed at launch. The key is created with the first write
/// and the file is loaded on first use. The file is also 0600 in a 0700 folder.
enum CredentialStore {
    static let credentialService = "credentials"
    static let syncService = "sync"

    /// Replaced by tests.
    static var fileURL = AppPaths.supportDirectory.appendingPathComponent("credentials.json")
    /// Where the file key lives; replaced by tests.
    static var keyStorage = KeyStorage.keychain

    private struct Payload: Codable {
        var version = 1
        var items: [String: String] = [:]
        /// When each host credential last changed on this Mac, for sync.
        var times: [String: Double] = [:]
        /// For imported private keys: the key file path and content hash at
        /// the last import ("path\nsha256"), so an unchanged file is not
        /// imported again over a newer key that arrived through sync.
        var imports: [String: String]?
    }

    private struct Envelope: Codable {
        var format: String
        var version: Int
        /// AES-GCM nonce, ciphertext and tag, base64.
        var sealed: String
    }

    static let fileFormat = "cterm-keychain"
    private static let fileVersion = 1

    private static var payload: Payload?
    private static var fileKey: SymmetricKey?
    /// Set when the keychain refused the key (access denied); not retried
    /// until the next launch, so the user is not asked over and over.
    private static var keyUnavailable = false
    private static let lock = NSRecursiveLock()

    static func account(for profileID: UUID, kind: String) -> String {
        "\(profileID.uuidString).\(kind)"
    }

    // MARK: - Host credentials

    /// Saves a host credential. The change time is recorded only when the
    /// value actually changes, so re-saving the same secret on every connect
    /// does not look like an edit to cloud sync. `modifiedAt` lets sync write
    /// a merged value with the time it carried on the other device.
    @discardableResult
    static func save(_ secret: String, account: String, modifiedAt: Date? = nil) -> Bool {
        let previous = load(account: account)
        let ok = saveItem(secret, account: account, service: credentialService)
        if ok, previous != secret || modifiedAt != nil {
            recordChange(account: account, at: modifiedAt)
        }
        return ok
    }

    static func load(account: String) -> String? {
        loadItem(account: account, service: credentialService)
    }

    static func delete(account: String, modifiedAt: Date? = nil) {
        let existed = load(account: account) != nil
        deleteItem(account: account, service: credentialService)
        if existed || modifiedAt != nil {
            recordChange(account: account, at: modifiedAt)
        }
    }

    static func deleteSecrets(for profileID: UUID) {
        delete(account: account(for: profileID, kind: "password"))
        delete(account: account(for: profileID, kind: "passphrase"))
        delete(account: account(for: profileID, kind: PrivateKeyVault.kind))
        setImportMarker(nil, account: account(for: profileID, kind: PrivateKeyVault.kind))
    }

    static func importMarker(account: String) -> String? {
        withPayload { $0.imports?[account] }
    }

    static func setImportMarker(_ marker: String?, account: String) {
        guard importMarker(account: account) != marker else { return }
        mutate { payload in
            var imports = payload.imports ?? [:]
            imports[account] = marker
            payload.imports = imports
        }
    }

    /// When a host credential was last saved or removed on this Mac, if known.
    static func modifiedAt(account: String) -> Date? {
        withPayload { $0.times[account] }.map { Date(timeIntervalSince1970: $0) }
    }

    private static func recordChange(account: String, at date: Date?) {
        let ok = mutate { $0.times[account] = (date ?? SyncClock.now()).timeIntervalSince1970 }
        if ok {
            NotificationCenter.default.post(name: .ctermCredentialsDidChange, object: account)
        }
    }

    // MARK: - Raw items

    @discardableResult
    static func saveItem(_ secret: String, account: String, service: String) -> Bool {
        mutate { $0.items[key(account, service)] = secret }
    }

    static func loadItem(account: String, service: String) -> String? {
        withPayload { $0.items[key(account, service)] }
    }

    static func deleteItem(account: String, service: String) {
        let k = key(account, service)
        guard withPayload({ $0.items[k] }) != nil else { return }
        mutate { $0.items[k] = nil }
    }

    // MARK: - Storage

    private static func key(_ account: String, _ service: String) -> String {
        "\(service)/\(account)"
    }

    private static func withPayload<T>(_ body: (Payload) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return body(payload ?? Payload())
    }

    @discardableResult
    private static func mutate(_ body: (inout Payload) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard loadIfNeeded(), var value = payload else {
            NSLog("cTerm: credentials are unavailable; change not saved")
            return false
        }
        body(&value)
        guard write(value) else { return false }
        payload = value
        return true
    }

    /// Reads the file the first time it is needed. A file this Mac cannot
    /// open (sealed with a master password by an older build, or its key
    /// gone from the keychain) is moved aside and the store starts empty.
    @discardableResult
    private static func loadIfNeeded() -> Bool {
        if payload != nil { return true }
        if keyUnavailable { return false }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            payload = Payload()
            return true
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == fileFormat else {
            // An early build wrote plain JSON: keep it and encrypt it now.
            if let plain = try? JSONDecoder().decode(Payload.self, from: data) {
                payload = plain
                _ = write(plain)
            } else {
                discardUnreadableFile()
            }
            return true
        }
        let key: SymmetricKey
        do {
            guard let stored = try keyStorage.load() else {
                discardUnreadableFile()
                return true
            }
            key = SymmetricKey(data: stored)
        } catch {
            NSLog("cTerm: could not read the credentials key: \(error)")
            keyUnavailable = true
            return false
        }
        guard let plaintext = try? open(envelope, key: key),
              let value = try? JSONDecoder().decode(Payload.self, from: plaintext) else {
            discardUnreadableFile()
            return true
        }
        fileKey = key
        payload = value
        return true
    }

    private static func discardUnreadableFile() {
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("credentials-unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: fileURL, to: aside)
        NSLog("cTerm: credentials file could not be opened; moved to \(aside.path)")
        payload = Payload()
    }

    /// The key to seal with: the one loaded, else the keychain's, else a new one.
    private static func sealingKey() -> SymmetricKey? {
        if let fileKey { return fileKey }
        do {
            let key: SymmetricKey
            if let stored = try keyStorage.load() {
                key = SymmetricKey(data: stored)
            } else {
                key = SymmetricKey(size: .bits256)
                try keyStorage.save(key.withUnsafeBytes { Data($0) })
            }
            fileKey = key
            return key
        } catch {
            NSLog("cTerm: could not store the credentials key: \(error)")
            return nil
        }
    }

    // MARK: - File

    private static func aad() -> Data {
        Data("\(fileFormat)|v\(fileVersion)|AES-256-GCM".utf8)
    }

    private static func open(_ envelope: Envelope, key: SymmetricKey) throws -> Data {
        guard envelope.version <= fileVersion, let combined = Data(base64Encoded: envelope.sealed) else {
            throw SyncError.unsupportedParameters
        }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad())
    }

    private static func write(_ value: Payload) -> Bool {
        guard let key = sealingKey() else { return false }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let plaintext = try JSONEncoder().encode(value)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad())
            let envelope = Envelope(format: fileFormat, version: fileVersion,
                                    sealed: sealed.combined!.base64EncodedString())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(envelope).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            NSLog("cTerm: failed to save credentials: \(error)")
            return false
        }
    }

    #if DEBUG
    /// Tests point the store at a new file and drop what was loaded.
    static func reset(fileURL url: URL) {
        lock.lock()
        defer { lock.unlock() }
        fileURL = url
        payload = nil
        fileKey = nil
        keyUnavailable = false
    }
    #endif
}

/// Loads and saves the 32-byte key that seals `credentials.json`.
struct KeyStorage {
    var load: () throws -> Data?
    var save: (Data) throws -> Void

    struct KeychainError: LocalizedError {
        var status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "me.cqq.cterm",
        kSecAttrAccount: "credentials-key"
    ]

    static let keychain = KeyStorage(
        load: {
            var lookup = query
            lookup[kSecReturnData] = true
            lookup[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
            return data
        },
        save: { data in
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "cTerm 凭据密钥"
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    )

    #if DEBUG
    /// A key kept in memory, for tests.
    static func inMemory() -> KeyStorage {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        return KeyStorage(load: { box.data }, save: { box.data = $0 })
    }
    #endif
}
