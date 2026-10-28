import Citadel
import Foundation
import NIOCore

/// Thread-safe byte totals, written by a transfer worker and sampled by the
/// queue's progress timer on the main thread.
final class TransferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _done: UInt64 = 0
    private var _total: UInt64 = 0

    var done: UInt64 { lock.withLock { _done } }
    var total: UInt64 { lock.withLock { _total } }

    func add(_ bytes: Int) {
        lock.withLock { _done += UInt64(max(0, bytes)) }
    }

    func setTotal(_ bytes: UInt64) {
        lock.withLock { _total = bytes }
    }
}

final class TransferItem {
    enum Direction {
        case upload, download
    }

    enum State: Equatable {
        case queued, running, completed, failed(String), cancelled
    }

    let id = UUID()
    let direction: Direction
    let name: String
    /// Download: where the file ends up. Upload: the file being sent.
    let localURL: URL
    /// Download: the file being fetched. Upload: where it ends up.
    let remotePath: String
    let isDirectory: Bool
    /// An upload that saves an edited file back; shown as "synced".
    let isEditSync: Bool

    fileprivate(set) var state: State = .queued
    fileprivate(set) var transferredBytes: UInt64 = 0
    fileprivate(set) var totalBytes: UInt64 = 0
    fileprivate(set) var bytesPerSecond: Double = 0
    /// Called once with whether the transfer finished; used by Finder drags.
    fileprivate var completion: ((Error?) -> Void)?

    fileprivate let counter = TransferCounter()
    fileprivate var task: Task<Void, Never>?
    fileprivate var lastSample: (bytes: UInt64, time: TimeInterval)?

    init(direction: Direction, name: String, localURL: URL, remotePath: String, isDirectory: Bool,
         isEditSync: Bool = false) {
        self.direction = direction
        self.name = name
        self.localURL = localURL
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.isEditSync = isEditSync
    }

    var fraction: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    var isFinished: Bool {
        switch state {
        case .completed, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

/// Runs uploads and downloads over one SFTP channel, a couple at a time.
@MainActor
final class TransferQueue {
    private(set) var items: [TransferItem] = []
    var maxConcurrent = 2
    var onChange: (() -> Void)?
    var onItemFinished: ((TransferItem) -> Void)?

    private var session: SFTPSession?
    private var progressTimer: Timer?

    var activeCount: Int {
        items.filter { !$0.isFinished }.count
    }

    func attach(_ session: SFTPSession) {
        self.session = session
        pump()
    }

    /// The channel is gone: everything still pending fails.
    func detach(reason: String) {
        session = nil
        for item in items where !item.isFinished {
            item.task?.cancel()
            finish(item, state: .failed(reason), error: SFTPUnavailable())
        }
        onChange?()
    }

    @discardableResult
    func enqueueDownload(_ entry: RemoteEntry, to destination: URL,
                         completion: ((Error?) -> Void)? = nil) -> TransferItem {
        let item = TransferItem(
            direction: .download,
            name: entry.name,
            localURL: destination,
            remotePath: entry.path,
            isDirectory: entry.isDirectory
        )
        item.completion = completion
        item.totalBytes = entry.isDirectory ? 0 : (entry.size ?? 0)
        items.append(item)
        pump()
        onChange?()
        return item
    }

    @discardableResult
    func enqueueUpload(_ localURL: URL, to remotePath: String, isEditSync: Bool = false,
                       completion: ((Error?) -> Void)? = nil) -> TransferItem {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        let item = TransferItem(
            direction: .upload,
            name: RemotePath.name(of: remotePath),
            localURL: localURL,
            remotePath: remotePath,
            isDirectory: isDirectory.boolValue,
            isEditSync: isEditSync
        )
        item.completion = completion
        items.append(item)
        pump()
        onChange?()
        return item
    }

    func cancel(_ item: TransferItem) {
        guard !item.isFinished else { return }
        if item.state == .queued {
            finish(item, state: .cancelled, error: CancellationError())
        } else {
            item.task?.cancel()
        }
        onChange?()
    }

    func cancelAll() {
        for item in items where !item.isFinished {
            cancel(item)
        }
    }

    func remove(_ item: TransferItem) {
        guard item.isFinished else { return }
        items.removeAll { $0 === item }
        onChange?()
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
        onChange?()
    }

    // MARK: - Scheduling

    private func pump() {
        guard let session else { return }
        var running = items.filter { $0.state == .running }.count
        for item in items where item.state == .queued && running < maxConcurrent {
            start(item, client: session.client)
            running += 1
        }
        updateTimer()
    }

    private func start(_ item: TransferItem, client: SFTPClient) {
        item.state = .running
        item.lastSample = (0, ProcessInfo.processInfo.systemUptime)
        let counter = item.counter
        if item.totalBytes > 0 { counter.setTotal(item.totalBytes) }
        let direction = item.direction
        let isDirectory = item.isDirectory
        let localURL = item.localURL
        let remotePath = item.remotePath

        item.task = Task.detached { [weak self] in
            var failure: Error?
            do {
                switch (direction, isDirectory) {
                case (.download, false):
                    try await Transfers.download(client: client, from: remotePath, to: localURL, counter: counter)
                case (.download, true):
                    try await Transfers.downloadDirectory(client: client, from: remotePath, to: localURL, counter: counter)
                case (.upload, false):
                    counter.setTotal(Transfers.localSize(localURL))
                    try await Transfers.upload(client: client, from: localURL, to: remotePath, counter: counter)
                case (.upload, true):
                    try await Transfers.uploadDirectory(client: client, from: localURL, to: remotePath, counter: counter)
                }
            } catch {
                failure = error
            }
            let result = failure
            await MainActor.run { [weak self] in
                self?.workerFinished(item, error: result)
            }
        }
    }

    private func workerFinished(_ item: TransferItem, error: Error?) {
        guard !item.isFinished else { return }
        sample(item)
        if let error {
            if error is CancellationError || item.task?.isCancelled == true {
                finish(item, state: .cancelled, error: error)
            } else {
                finish(item, state: .failed(SFTPErrorMessage.describe(error)), error: error)
            }
        } else {
            item.transferredBytes = max(item.transferredBytes, item.totalBytes)
            finish(item, state: .completed, error: nil)
        }
        pump()
        onChange?()
    }

    private func finish(_ item: TransferItem, state: TransferItem.State, error: Error?) {
        item.state = state
        item.bytesPerSecond = 0
        item.task = nil
        let completion = item.completion
        item.completion = nil
        completion?(error)
        onItemFinished?(item)
        updateTimer()
    }

    // MARK: - Progress

    private func updateTimer() {
        let running = items.contains { $0.state == .running }
        if running, progressTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        } else if !running {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func tick() {
        for item in items where item.state == .running {
            sample(item)
        }
        onChange?()
    }

    private func sample(_ item: TransferItem) {
        let done = item.counter.done
        let total = item.counter.total
        if total > 0 { item.totalBytes = total }
        item.transferredBytes = done
        let now = ProcessInfo.processInfo.systemUptime
        if let last = item.lastSample, now - last.time >= 0.2 {
            let rate = Double(done &- last.bytes) / (now - last.time)
            // Smooth the rate so the label doesn't jitter every tick.
            item.bytesPerSecond = item.bytesPerSecond == 0 ? rate : item.bytesPerSecond * 0.6 + rate * 0.4
            item.lastSample = (done, now)
        }
    }
}

/// The transfer workers. They keep a window of SFTP requests in flight, since
/// one 32 KB request per round trip is far too slow over a WAN.
enum Transfers {
    static let chunkSize = 32_000
    static let window = 32

    static func localSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func download(client: SFTPClient, from remotePath: String, to destination: URL,
                         counter: TransferCounter) async throws {
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).ctermpart")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            let file = try await client.openFile(filePath: remotePath, flags: .read)
            do {
                if let size = try? await file.readAttributes().size, counter.total == 0 {
                    counter.setTotal(size)
                }
                try await readAll(file, into: handle, counter: counter)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            try handle.synchronize()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func readAll(_ file: SFTPFile, into handle: FileHandle, counter: TransferCounter) async throws {
        var offset: UInt64 = 0
        var reachedEnd = false
        while !reachedEnd {
            try Task.checkCancellation()
            let base = offset
            let chunks = try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
                for index in 0..<window {
                    let at = base + UInt64(index * chunkSize)
                    group.addTask {
                        (index, try await file.read(from: at, length: UInt32(chunkSize)))
                    }
                }
                var results = [ByteBuffer?](repeating: nil, count: window)
                for try await (index, buffer) in group {
                    results[index] = buffer
                }
                return results.map { $0 ?? ByteBuffer() }
            }

            for (index, first) in chunks.enumerated() {
                let start = base + UInt64(index * chunkSize)
                var buffer = first
                var written = 0
                // A server may return less than asked; fetch the rest of
                // this chunk before moving on, or stop at end of file.
                while true {
                    if buffer.readableBytes == 0 {
                        reachedEnd = true
                        break
                    }
                    try handle.seek(toOffset: start + UInt64(written))
                    let bytes = buffer.readableBytes
                    try handle.write(contentsOf: buffer.readableBytesView)
                    counter.add(bytes)
                    written += bytes
                    if written >= chunkSize { break }
                    try Task.checkCancellation()
                    buffer = try await file.read(from: start + UInt64(written), length: UInt32(chunkSize - written))
                }
                if reachedEnd {
                    try handle.truncate(atOffset: start + UInt64(written))
                    break
                }
            }
            offset = base + UInt64(window * chunkSize)
        }
    }

    static func upload(client: SFTPClient, from source: URL, to remotePath: String,
                       counter: TransferCounter) async throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        // Writing over the existing file keeps its permissions and owner.
        let existed = (try? await client.getAttributes(at: remotePath)) != nil
        let file = try await client.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: window * chunkSize), !data.isEmpty else { break }
                let base = offset
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var start = 0
                    while start < data.count {
                        let end = min(start + chunkSize, data.count)
                        let slice = ByteBuffer(bytes: data[data.startIndex + start ..< data.startIndex + end])
                        let at = base + UInt64(start)
                        group.addTask {
                            try await file.write(slice, at: at)
                            counter.add(slice.readableBytes)
                        }
                        start = end
                    }
                    try await group.waitForAll()
                }
                offset += UInt64(data.count)
            }
            try await file.close()
        } catch {
            try? await file.close()
            // Don't leave a partial new file behind. A file that was already
            // there is left as it is: deleting it would lose it outright,
            // and an edit can simply be saved again.
            if !existed { try? await client.remove(at: remotePath) }
            throw error
        }
    }

    static func downloadDirectory(client: SFTPClient, from remotePath: String, to destination: URL,
                                  counter: TransferCounter) async throws {
        let session = SFTPSession(client: client)
        var files: [(remote: String, local: URL)] = []
        var total: UInt64 = 0

        func walk(_ remote: String, _ local: URL) async throws {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for entry in try await session.list(remote) {
                let target = local.appendingPathComponent(entry.name)
                if entry.isDirectory {
                    // Don't follow linked folders; they can loop.
                    if !entry.isSymlink { try await walk(entry.path, target) }
                } else {
                    files.append((entry.path, target))
                    total += entry.size ?? 0
                }
            }
        }

        try await walk(remotePath, destination)
        counter.setTotal(total)
        for file in files {
            try Task.checkCancellation()
            try await download(client: client, from: file.remote, to: file.local, counter: counter)
        }
    }

    static func uploadDirectory(client: SFTPClient, from source: URL, to remotePath: String,
                                counter: TransferCounter) async throws {
        let fileManager = FileManager.default
        var directories: [String] = [remotePath]
        var files: [(local: URL, remote: String)] = []
        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let base = source.standardizedFileURL.path
        let urls = fileManager.enumerator(at: source, includingPropertiesForKeys: keys)?
            .allObjects.compactMap { $0 as? URL } ?? []
        do {
            for url in urls {
                let values = try url.resourceValues(forKeys: Set(keys))
                let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let remote = RemotePath.join(remotePath, relative)
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    directories.append(remote)
                } else {
                    files.append((url, remote))
                    total += UInt64(values.fileSize ?? 0)
                }
            }
        }
        counter.setTotal(total)
        for directory in directories {
            try Task.checkCancellation()
            do {
                try await client.createDirectory(atPath: directory)
            } catch {
                // Uploading into an existing folder merges into it.
                if !SFTPSession(client: client).isActive { throw error }
            }
        }
        for file in files {
            try Task.checkCancellation()
            try await upload(client: client, from: file.local, to: file.remote, counter: counter)
        }
    }
}

extension ByteCountFormatter {
    private static let transfer: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 KB", not "Zero KB".
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func transferString(_ bytes: UInt64) -> String {
        transfer.string(fromByteCount: Int64(clamping: bytes))
    }
}
