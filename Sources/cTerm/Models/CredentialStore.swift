import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted when a host credential is saved or removed; the object is the account.
    static let ctermCredentialsDidChange = Notification.Name("cterm.credentialsDidChange")
}

/// Saved passwords, key passphrases, private key copies, the sync password
/// and the OneDrive refresh token, in `credentials.json` in the app's support
/// folder.
///
/// The file is encrypted with a key derived from the user's master password
/// (PBKDF2-HMAC-SHA256, 600 000 rounds, then AES-256-GCM, the same scheme as
/// the cloud file). The password is asked for at launch; the derived key lives
/// only in memory, and nothing can be read or saved while the store is locked.
/// The file is also 0600 in a 0700 folder.
enum CredentialStore {
    static let credentialService = "credentials"
    static let syncService = "sync"

    /// Replaced by tests.
    static var fileURL = AppPaths.supportDirectory.appendingPathComponent("credentials.json")

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

    static let fileFormat = "cterm-local"

    enum State: Equatable {
        /// No master password yet: first launch, or after a reset. A file
        /// written by a build before master passwords is kept and encrypted
        /// on setup.
        case needsSetup
        case locked
        case unlocked
    }

    enum StoreError: LocalizedError {
        case wrongPassword
        case notUnlocked
        case unreadable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "主密码不正确。"
            case .notUnlocked: return "凭据尚未解锁。"
            case .unreadable: return "凭据文件已损坏，无法读取。"
            case .writeFailed: return "无法写入凭据文件。"
            }
        }
    }

    private static var payload: Payload?
    private static var masterKey: SymmetricKey?
    private static var keyParameters: SyncCrypto.KeyParameters?
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
        return body(payload ?? Payload())
    }

    @discardableResult
    private static func mutate(_ body: (inout Payload) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var value = payload, let masterKey, let keyParameters else {
            NSLog("cTerm: credentials are locked; change not saved")
            return false
        }
        body(&value)
        guard write(value, key: masterKey, parameters: keyParameters) else { return false }
        payload = value
        return true
    }

    // MARK: - Master password

    static var state: State {
        lock.lock()
        defer { lock.unlock() }
        if masterKey != nil { return .unlocked }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return .needsSetup }
        return SyncCrypto.isEnvelope(data, format: fileFormat) ? .locked : .needsSetup
    }

    /// Credentials an older build saved without encryption, which must be
    /// encrypted (by creating a master password) before cTerm goes on.
    static var hasUnencryptedCredentials: Bool {
        guard let data = try? Data(contentsOf: fileURL), !SyncCrypto.isEnvelope(data, format: fileFormat),
              let plain = try? JSONDecoder().decode(Payload.self, from: data) else { return false }
        return !plain.items.isEmpty
    }

    /// Creates the master password. Credentials left unencrypted by an older
    /// build are kept and encrypted with it. Slow (key derivation): call it
    /// off the main thread.
    static func setUp(password: String, iterations: Int = SyncCrypto.defaultIterations) throws {
        let parameters = SyncCrypto.KeyParameters.fresh(iterations: iterations)
        let newKey = try SyncCrypto.deriveKey(password: password, salt: parameters.salt, iterations: iterations)
        lock.lock()
        defer { lock.unlock() }
        var existing = Payload()
        if let data = try? Data(contentsOf: fileURL), !SyncCrypto.isEnvelope(data, format: fileFormat),
           let plain = try? JSONDecoder().decode(Payload.self, from: data) {
            existing = plain
        }
        guard write(existing, key: newKey, parameters: parameters) else { throw StoreError.writeFailed }
        payload = existing
        masterKey = newKey
        keyParameters = parameters
    }

    /// Opens the store. Slow (key derivation): call it off the main thread.
    static func unlock(password: String, minimumIterations: Int = SyncCrypto.minimumIterations) throws {
        guard let data = try? Data(contentsOf: fileURL) else { throw StoreError.unreadable }
        let parameters: SyncCrypto.KeyParameters
        do {
            parameters = try SyncCrypto.keyParameters(of: data, format: fileFormat, minimumIterations: minimumIterations)
        } catch {
            throw StoreError.unreadable
        }
        let derived = try SyncCrypto.deriveKey(password: password, salt: parameters.salt, iterations: parameters.iterations)
        let plaintext: Data
        do {
            plaintext = try SyncCrypto.open(data, key: derived, format: fileFormat, minimumIterations: minimumIterations)
        } catch {
            throw StoreError.wrongPassword
        }
        guard let value = try? JSONDecoder().decode(Payload.self, from: plaintext) else { throw StoreError.unreadable }
        lock.lock()
        defer { lock.unlock() }
        payload = value
        masterKey = derived
        keyParameters = parameters
    }

    /// Re-encrypts the store under a new master password. Slow: off the main thread.
    static func changePassword(current: String, to newPassword: String,
                               iterations: Int = SyncCrypto.defaultIterations) throws {
        lock.lock()
        guard let parameters = keyParameters, let activeKey = masterKey, let value = payload else {
            lock.unlock()
            throw StoreError.notUnlocked
        }
        lock.unlock()
        let check = try SyncCrypto.deriveKey(password: current, salt: parameters.salt, iterations: parameters.iterations)
        guard check == activeKey else { throw StoreError.wrongPassword }
        let newParameters = SyncCrypto.KeyParameters.fresh(iterations: iterations)
        let newKey = try SyncCrypto.deriveKey(password: newPassword, salt: newParameters.salt, iterations: iterations)
        lock.lock()
        defer { lock.unlock() }
        guard write(payload ?? value, key: newKey, parameters: newParameters) else { throw StoreError.writeFailed }
        masterKey = newKey
        keyParameters = newParameters
    }

    /// For a forgotten master password: deletes every saved credential so a
    /// new master password can be created. Hosts are not touched.
    static func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        payload = nil
        masterKey = nil
        keyParameters = nil
    }

    // MARK: - File

    private static func write(_ value: Payload, key: SymmetricKey, parameters: SyncCrypto.KeyParameters) -> Bool {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let plaintext = try JSONEncoder().encode(value)
            let data = try SyncCrypto.seal(plaintext, key: key, parameters: parameters, format: fileFormat)
            try data.write(to: fileURL, options: .atomic)
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
        masterKey = nil
        keyParameters = nil
    }
    #endif
}
