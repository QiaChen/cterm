import AppKit
import Foundation

extension Notification.Name {
    static let ctermSyncStatusDidChange = Notification.Name("cterm.syncStatusDidChange")
}

enum CloudSyncStatus: Equatable {
    case disabled
    case syncing
    case synced(Date)
    case pending
    case failed(String)

    /// The three states the sidebar names, plus what is going on right now.
    var title: String {
        switch self {
        case .disabled: return "未开启云同步"
        case .syncing: return "正在同步…"
        case .synced: return "已同步"
        case .pending, .failed: return "未同步"
        }
    }

    var detail: String? {
        switch self {
        case .synced(let date): return CloudSyncStatus.relative(date)
        case .failed: return "同步失败"
        case .pending: return "有本地更改"
        default: return nil
        }
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Keeps the saved hosts (and their saved credentials) in an end-to-end
/// encrypted file in the user's OneDrive (cTerm's app folder).
///
/// A sync downloads the file, decrypts it with the sync password, merges it
/// with the local hosts (`SyncMerge`), applies the result locally and uploads
/// it re-encrypted, guarded by the file's eTag (If-Match) so a concurrent upload
/// from another device is detected and the sync retried.
@MainActor
final class CloudSyncManager {
    static let shared = CloudSyncManager()

    private enum Key {
        static let enabled = "cterm.sync.enabled"
        static let clientID = "cterm.sync.clientID"
        static let fileID = "cterm.sync.fileID"
        static let filePath = "cterm.sync.filePath"
        static let account = "cterm.sync.account"
        static let lastSync = "cterm.sync.lastSync"
        static let baseline = "cterm.sync.baseline"
        static let provider = "cterm.sync.provider"
    }
    private static let passwordAccount = "sync.password"
    static let defaultFileName = "cterm-hosts.ctermsync"
    static let minimumPasswordLength = 8

    private let defaults = UserDefaults.standard
    private var hostStore: HostStore?
    private var debounce: DispatchWorkItem?
    private var timer: Timer?
    private var syncAgain = false
    #if DEBUG
    /// Snapshot rendering: pretend sync is on without touching real settings.
    var statusOverride: CloudSyncStatus?
    var preview: (account: String, path: String, lastSync: Date)?
    #endif

    private(set) var status: CloudSyncStatus = .disabled {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: .ctermSyncStatusDidChange, object: self)
        }
    }

    var currentStatus: CloudSyncStatus {
        #if DEBUG
        if let statusOverride { return statusOverride }
        #endif
        return status
    }

    lazy var client = OneDriveClient(clientID: clientID)

    // MARK: - Settings

    var isEnabled: Bool {
        #if DEBUG
        if preview != nil { return true }
        #endif
        return defaults.bool(forKey: Key.enabled) && fileID != nil
    }

    /// The Azure app (client) ID is built into the app (`CTermOneDriveClientID`
    /// in Info.plist, filled in by build.sh), the way other apps ship theirs, so
    /// users only sign in. A defaults value overrides it for development.
    var clientID: String {
        if let value = defaults.string(forKey: Key.clientID)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["CTERM_ONEDRIVE_CLIENT_ID"], !value.isEmpty {
            return value
        }
        #endif
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CTermOneDriveClientID") as? String
        return bundled?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var isAvailable: Bool { !clientID.isEmpty }

    var fileID: String? { defaults.string(forKey: Key.fileID) }
    var filePath: String? {
        #if DEBUG
        if let preview { return preview.path }
        #endif
        return defaults.string(forKey: Key.filePath)
    }

    var accountName: String? {
        #if DEBUG
        if let preview { return preview.account }
        #endif
        return defaults.string(forKey: Key.account)
    }

    var lastSyncAt: Date? {
        #if DEBUG
        if let preview { return preview.lastSync }
        #endif
        return defaults.object(forKey: Key.lastSync) as? Date
    }

    private var syncPassword: String? {
        CredentialStore.loadItem(account: Self.passwordAccount, service: CredentialStore.syncService)
    }

    // MARK: - Lifecycle

    static let provider = "onedrive"

    func start(hostStore: HostStore) {
        self.hostStore = hostStore
        // A build that synced through Google Drive left a Google file ID here,
        // which means nothing to OneDrive: switch sync off so it can be set up
        // again, and drop the Google sign-in that is no longer used.
        if defaults.bool(forKey: Key.enabled), defaults.string(forKey: Key.provider) != Self.provider {
            disable()
        }
        CredentialStore.deleteItem(account: "gdrive.refreshToken", service: CredentialStore.syncService)
        let center = NotificationCenter.default
        center.addObserver(forName: .ctermHostStoreDidChange, object: hostStore, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localDidChange() }
        }
        center.addObserver(forName: .ctermCredentialsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localDidChange() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                if (self.lastSyncAt.map { Date().timeIntervalSince($0) > 60 }) ?? true {
                    self.syncSoon(delay: 0.5)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(delay: 0) }
        }
        refreshStatus()
        if isEnabled { syncSoon(delay: 1) }
    }

    private func localDidChange() {
        guard isEnabled else { return }
        if case .syncing = status { syncAgain = true; return }
        refreshStatus()
        if status == .pending { syncSoon(delay: 3) }
    }

    private func refreshStatus() {
        guard isEnabled else { status = .disabled; return }
        if case .syncing = status { return }
        if case .failed = status, isDirty { return }
        if !isDirty, let lastSyncAt {
            status = .synced(lastSyncAt)
        } else {
            status = .pending
        }
    }

    private var isDirty: Bool {
        guard let baseline = defaults.string(forKey: Key.baseline) else { return true }
        return localDocument().fingerprint() != baseline
    }

    func syncSoon(delay: TimeInterval) {
        guard isEnabled else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { try? await self.sync() }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Setup

    /// Signs in to OneDrive (the user picks the Microsoft account in a browser sheet).
    func signIn(from window: NSWindow?) async throws {
        client.clientID = clientID
        try await client.signIn(from: window)
        if let name = try? await client.accountName() {
            defaults.set(name, forKey: Key.account)
        }
    }

    /// Starts syncing with a new file at the top of My Drive.
    func enableWithNewFile(name: String, password: String) async throws {
        let sealed = try await Self.seal(localDocument(), password: password)
        let item = try await client.create(name: name, data: sealed)
        try finishEnabling(item: item, password: password)
        try await sync()
    }

    /// Starts syncing with an existing file. The password must open it,
    /// unless the file is empty.
    func enableWithExistingFile(_ item: DriveItem, password: String) async throws {
        let (data, _) = try await client.download(id: item.id)
        if !data.isEmpty {
            _ = try await Self.open(data, password: password)
        }
        try finishEnabling(item: item, password: password)
        try await sync()
    }

    private func finishEnabling(item: DriveItem, password: String) throws {
        guard CredentialStore.saveItem(password, account: Self.passwordAccount, service: CredentialStore.syncService) else {
            throw SyncError.network("无法在本机保存同步密码")
        }
        defaults.set(item.id, forKey: Key.fileID)
        defaults.set(item.name, forKey: Key.filePath)
        defaults.removeObject(forKey: Key.baseline)
        defaults.set(Self.provider, forKey: Key.provider)
        defaults.set(true, forKey: Key.enabled)
        status = .pending
    }

    /// Re-encrypts the cloud file with a new password (the old one must still open it).
    func changePassword(to newPassword: String) async throws {
        try await sync(encryptWith: newPassword)
        CredentialStore.saveItem(newPassword, account: Self.passwordAccount, service: CredentialStore.syncService)
    }

    /// Stores a password changed on another device, after checking it opens the file.
    func updatePassword(_ password: String) async throws {
        guard let fileID else { throw SyncError.notConfigured }
        let (data, _) = try await client.download(id: fileID)
        if !data.isEmpty {
            _ = try await Self.open(data, password: password)
        }
        CredentialStore.saveItem(password, account: Self.passwordAccount, service: CredentialStore.syncService)
        try await sync()
    }

    func disable() {
        debounce?.cancel()
        defaults.set(false, forKey: Key.enabled)
        for key in [Key.fileID, Key.filePath, Key.account, Key.lastSync, Key.baseline, Key.provider] {
            defaults.removeObject(forKey: key)
        }
        CredentialStore.deleteItem(account: Self.passwordAccount, service: CredentialStore.syncService)
        client.signOut()
        status = .disabled
    }

    // MARK: - Sync

    func sync() async throws {
        try await sync(encryptWith: nil)
    }

    private func sync(encryptWith newPassword: String?) async throws {
        guard isEnabled, let fileID else { throw SyncError.notConfigured }
        guard let password = syncPassword else { throw SyncError.passwordMissing }
        if case .syncing = status { syncAgain = true; return }
        debounce?.cancel()
        status = .syncing
        do {
            var attempt = 0
            while true {
                attempt += 1
                do {
                    try await syncOnce(fileID: fileID, password: password, uploadPassword: newPassword ?? password,
                                       forceUpload: newPassword != nil)
                    break
                } catch SyncError.conflict where attempt < 3 {
                    continue
                }
            }
            status = .pending
            refreshStatus()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
            syncAgain = false
            throw error
        }
        if syncAgain {
            syncAgain = false
            refreshStatus()
            if status == .pending { syncSoon(delay: 1) }
        }
    }

    private func syncOnce(fileID: String, password: String, uploadPassword: String, forceUpload: Bool) async throws {
        let (data, item) = try await client.download(id: fileID)
        let remote: SyncDocument? = data.isEmpty ? nil : try await Self.open(data, password: password)

        // Build, merge and apply in one main-actor step so edits made while the
        // download was running are part of the merge.
        let local = localDocument()
        if let remote {
            apply(SyncMerge.merge(local: local, remote: remote))
        }
        let result = localDocument()
        let fingerprint = result.fingerprint()

        if forceUpload || remote?.fingerprint() != fingerprint {
            let sealed = try await Self.seal(result, password: uploadPassword)
            let uploaded = try await client.upload(id: fileID, data: sealed, expectedVersion: item.eTag)
            defaults.set(uploaded.name, forKey: Key.filePath)
        }
        defaults.set(fingerprint, forKey: Key.baseline)
        defaults.set(Date(), forKey: Key.lastSync)
    }

    private static func seal(_ document: SyncDocument, password: String) async throws -> Data {
        let plaintext = try document.encoded()
        return try await Task.detached(priority: .userInitiated) {
            try SyncCrypto.encrypt(plaintext, password: password)
        }.value
    }

    private static func open(_ data: Data, password: String) async throws -> SyncDocument {
        let plaintext = try await Task.detached(priority: .userInitiated) {
            try SyncCrypto.decrypt(data, password: password)
        }.value
        return try SyncDocument.decode(plaintext)
    }

    // MARK: - Local data

    func localDocument() -> SyncDocument {
        guard let hostStore else { return SyncDocument() }
        var document = SyncDocument()
        document.groups = hostStore.groups
        document.tombstones = hostStore.tombstones
        let profiles = hostStore.hosts.filter { !$0.isTemporary }
        profiles.forEach(PrivateKeyVault.refresh)
        document.hosts = profiles.map { profile in
            SyncHost(
                profile: profile,
                password: Self.localSecret(profile.id, kind: "password"),
                passphrase: Self.localSecret(profile.id, kind: "passphrase"),
                privateKey: Self.localSecret(profile.id, kind: PrivateKeyVault.kind)
            )
        }
        return document.normalized()
    }

    private static func localSecret(_ id: UUID, kind: String) -> SyncSecret? {
        let account = CredentialStore.account(for: id, kind: kind)
        let value = CredentialStore.load(account: account)
        let time = CredentialStore.modifiedAt(account: account)
        if let value {
            // Saved before sync existed: lose to any copy with a known time.
            return SyncSecret(value: value, modifiedAt: time ?? Date(timeIntervalSince1970: 0))
        }
        return time.map { SyncSecret(value: nil, modifiedAt: $0) }
    }

    private func apply(_ merged: SyncDocument) {
        guard let hostStore else { return }
        let keptIDs = Set(merged.hosts.map(\.profile.id))
        let removed = hostStore.hosts.filter { !keptIDs.contains($0.id) }

        for host in merged.hosts {
            for (kind, secret) in [("password", host.password), ("passphrase", host.passphrase),
                                   (PrivateKeyVault.kind, host.privateKey)] {
                guard let secret else { continue }
                let current = Self.localSecret(host.profile.id, kind: kind)
                guard current != secret else { continue }
                let account = CredentialStore.account(for: host.profile.id, kind: kind)
                if let value = secret.value {
                    CredentialStore.save(value, account: account, modifiedAt: secret.modifiedAt)
                } else {
                    CredentialStore.delete(account: account, modifiedAt: secret.modifiedAt)
                }
            }
        }
        for profile in removed {
            CredentialStore.deleteSecrets(for: profile.id)
        }
        if merged.hosts.map(\.profile) != localDocument().hosts.map(\.profile)
            || merged.groups != hostStore.groups.sorted(by: { $0.id.uuidString < $1.id.uuidString })
            || merged.tombstones != hostStore.tombstones.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let profiles = merged.hosts.map { host -> HostProfile in
                var profile = host.profile
                profile.lastConnectedAt = hostStore.host(withID: profile.id)?.lastConnectedAt
                return profile
            }
            hostStore.replaceAll(hosts: profiles, groups: merged.groups, tombstones: merged.tombstones)
        }
    }
}
