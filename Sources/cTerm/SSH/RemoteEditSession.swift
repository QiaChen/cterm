import CryptoKit
import Foundation

/// A remote file being edited in a local app: a working copy is downloaded,
/// watched, and every save is uploaded back over the original.
@MainActor
final class RemoteEditSession {
    enum State: Equatable {
        case downloading, editing, syncing, failed(String)
    }

    enum ConflictChoice {
        /// Upload over the version someone else saved.
        case overwrite
        /// Upload next to it as "name 2.ext" and keep editing that copy.
        case saveCopy
        /// Skip this save; the next one asks again.
        case discard
    }

    /// What the server reported for the file, to notice someone else's edit.
    private struct RemoteStamp: Equatable {
        var modified: Date?
        var size: UInt64?
    }

    private struct LocalStamp: Equatable {
        var modified: Date
        var size: UInt64
    }

    let localURL: URL
    private(set) var remotePath: String
    private(set) var state: State = .downloading {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Uploads that reached the server; used by the smoke test.
    private(set) var syncCount = 0

    var onChange: (() -> Void)?
    /// Asks what to do when the server's copy changed since it was opened.
    var resolveConflict: ((RemoteEditSession) async -> ConflictChoice)?

    private let sftp: SFTPSession
    private let queue: TransferQueue
    private var baseline = RemoteStamp()
    private var syncedDigest: Data?
    private var lastSeen: LocalStamp?
    private var changeNoticedAt: TimeInterval?
    private var pollTimer: Timer?
    private var isSyncing = false
    private var syncAgain = false

    init(remotePath: String, localURL: URL, sftp: SFTPSession, queue: TransferQueue) {
        self.remotePath = remotePath
        self.localURL = localURL
        self.sftp = sftp
        self.queue = queue
    }

    var name: String { RemotePath.name(of: remotePath) }

    /// True when the working copy holds a save the server hasn't got.
    var hasUnsyncedChanges: Bool {
        guard state != .downloading, let digest = Self.digest(of: localURL) else { return false }
        return digest != syncedDigest
    }

    /// Downloads the working copy, then calls `opened` so the caller can hand
    /// it to an editor. Watching starts once it is on disk.
    func start(entry: RemoteEntry, opened: @escaping (URL) -> Void) {
        queue.enqueueDownload(entry, to: localURL) { [weak self] error in
            guard let self else { return }
            if let error {
                self.state = .failed(SFTPErrorMessage.describe(error))
                return
            }
            Task {
                self.baseline = (try? await self.remoteStamp()) ?? RemoteStamp()
                self.syncedDigest = Self.digest(of: self.localURL)
                self.lastSeen = Self.localStamp(of: self.localURL)
                self.state = .editing
                self.startWatching()
                opened(self.localURL)
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Deletes the working copy's folder. Only call once nothing is unsynced.
    func removeWorkingCopy() {
        try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
    }

    // MARK: - Watching

    /// Editors save in different ways: in place, or by writing a new file and
    /// renaming it over the old one. Polling the copy's modification time and
    /// size catches every one of them for the cost of one stat.
    private func startWatching() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        // Missing for a moment while an editor swaps the file in.
        guard let stamp = Self.localStamp(of: localURL) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if stamp != lastSeen {
            lastSeen = stamp
            changeNoticedAt = now
            return
        }
        // A save often touches the file several times; wait until it settles.
        if let noticed = changeNoticedAt, now - noticed >= 0.5 {
            changeNoticedAt = nil
            syncIfChanged()
        }
    }

    // MARK: - Syncing

    func syncIfChanged() {
        if isSyncing {
            syncAgain = true
            return
        }
        guard let digest = Self.digest(of: localURL), digest != syncedDigest else { return }
        isSyncing = true
        state = .syncing
        Task {
            await sync(digest: digest)
            isSyncing = false
            if syncAgain {
                syncAgain = false
                syncIfChanged()
            }
        }
    }

    private func sync(digest: Data) async {
        var target = remotePath
        do {
            let current = try await remoteStamp()
            if current != baseline {
                switch await resolveConflict?(self) ?? .overwrite {
                case .overwrite:
                    break
                case .saveCopy:
                    let folder = RemotePath.parent(of: remotePath)
                    let taken = Set(try await sftp.list(folder).map(\.name))
                    target = RemotePath.join(folder, SFTPPanelViewController.uniqueName(name, taken: taken))
                case .discard:
                    state = .editing
                    return
                }
            }
            let error: Error? = await withCheckedContinuation { continuation in
                queue.enqueueUpload(localURL, to: target, isEditSync: true) { error in
                    continuation.resume(returning: error)
                }
            }
            if let error { throw error }
            remotePath = target
            baseline = try await remoteStamp()
            syncedDigest = digest
            syncCount += 1
            state = .editing
        } catch {
            // The digest stays unsynced, so the next save tries again.
            state = .failed(SFTPErrorMessage.describe(error))
        }
    }

    private func remoteStamp() async throws -> RemoteStamp {
        let attributes = try await sftp.attributes(of: remotePath)
        return RemoteStamp(modified: attributes.accessModificationTime?.modificationTime, size: attributes.size)
    }

    private static func localStamp(of url: URL) -> LocalStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return LocalStamp(modified: modified, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    private static func digest(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}

/// The files being edited over one SFTP connection.
@MainActor
final class RemoteEditManager {
    private(set) var sessions: [RemoteEditSession] = []
    var onChange: (() -> Void)?
    var resolveConflict: ((RemoteEditSession) async -> RemoteEditSession.ConflictChoice)?

    private let root: URL

    init(root: URL = RemoteEditManager.defaultRoot) {
        self.root = root
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cTerm/edit", isDirectory: true)
    }

    func session(for remotePath: String) -> RemoteEditSession? {
        sessions.first { $0.remotePath == remotePath }
    }

    /// Starts editing, or brings the open copy forward if it already is.
    @discardableResult
    func edit(_ entry: RemoteEntry, sftp: SFTPSession, queue: TransferQueue,
              open: @escaping (URL) -> Void) -> RemoteEditSession? {
        if let existing = session(for: entry.path) {
            if existing.state != .downloading { open(existing.localURL) }
            return existing
        }
        // One private folder per file keeps the real file name, so the
        // editor shows it and picks syntax highlighting from its extension.
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let session = RemoteEditSession(remotePath: entry.path, localURL: folder.appendingPathComponent(entry.name),
                                        sftp: sftp, queue: queue)
        session.onChange = { [weak self] in self?.onChange?() }
        session.resolveConflict = { [weak self] session in
            await self?.resolveConflict?(session) ?? .overwrite
        }
        sessions.append(session)
        session.start(entry: entry, opened: open)
        onChange?()
        return session
    }

    func stop(_ session: RemoteEditSession, keepWorkingCopy: Bool = false) {
        session.stop()
        if !keepWorkingCopy { session.removeWorkingCopy() }
        sessions.removeAll { $0 === session }
        onChange?()
    }

    /// The connection went away. Copies with unsynced saves are kept on disk.
    func stopAll() {
        for session in sessions {
            stop(session, keepWorkingCopy: session.hasUnsyncedChanges)
        }
    }
}
