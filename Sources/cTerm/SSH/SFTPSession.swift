import Citadel
import Foundation
import NIOCore

/// One entry of a remote directory listing.
struct RemoteEntry: Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64?
    let modified: Date?
    let permissions: UInt32?
}

enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Quotes a path for a POSIX shell, for `cd` typed into the terminal.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// File operations over one SFTP channel of an SSH connection.
final class SFTPSession {
    private static let typeMask: UInt32 = 0o170000
    private static let directoryType: UInt32 = 0o040000
    private static let symlinkType: UInt32 = 0o120000

    let client: SFTPClient

    init(client: SFTPClient) {
        self.client = client
    }

    var isActive: Bool { client.isActive }

    func close() {
        let client = self.client
        Task { try? await client.close() }
    }

    func homeDirectory() async throws -> String {
        try await client.getRealPath(atPath: ".")
    }

    func realPath(_ path: String) async throws -> String {
        try await client.getRealPath(atPath: path)
    }

    /// Lists a directory, folders first, then by name as Finder sorts them.
    func list(_ directory: String) async throws -> [RemoteEntry] {
        let names = try await client.listDirectory(atPath: directory)
        let components = names.flatMap(\.components).filter {
            !$0.filename.isEmpty && $0.filename != "." && $0.filename != ".."
        }
        // Show a link by what it points to, so a linked folder opens. Folders
        // like /usr/bin hold hundreds of links, so stat them concurrently
        // rather than paying one round trip each.
        let linkPaths = components
            .filter { Self.type(of: $0.attributes) == Self.symlinkType }
            .map { RemotePath.join(directory, $0.filename) }
        let targets = await resolveLinks(linkPaths)

        var entries: [RemoteEntry] = []
        for component in components {
            let name = component.filename
            let path = RemotePath.join(directory, name)
            let isSymlink = Self.type(of: component.attributes) == Self.symlinkType
            let attributes = targets[path] ?? component.attributes
            entries.append(RemoteEntry(
                name: name,
                path: path,
                isDirectory: Self.type(of: attributes) == Self.directoryType,
                isSymlink: isSymlink,
                size: attributes.size,
                modified: attributes.accessModificationTime?.modificationTime,
                permissions: attributes.permissions
            ))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Stats link targets, a bounded number at a time. Broken links are left
    /// out and show as plain files.
    private func resolveLinks(_ paths: [String]) async -> [String: SFTPFileAttributes] {
        guard !paths.isEmpty else { return [:] }
        let client = self.client
        return await withTaskGroup(of: (String, SFTPFileAttributes?).self) { group in
            var pending = paths.makeIterator()
            for _ in 0..<min(64, paths.count) {
                guard let path = pending.next() else { break }
                group.addTask { (path, try? await client.getAttributes(at: path)) }
            }
            var results: [String: SFTPFileAttributes] = [:]
            for await (path, attributes) in group {
                if let attributes { results[path] = attributes }
                if let next = pending.next() {
                    group.addTask { (next, try? await client.getAttributes(at: next)) }
                }
            }
            return results
        }
    }

    func attributes(of path: String) async throws -> SFTPFileAttributes {
        try await client.getAttributes(at: path)
    }

    func exists(_ path: String) async -> Bool {
        (try? await client.getAttributes(at: path)) != nil
    }

    func isDirectory(_ path: String) async throws -> Bool {
        Self.type(of: try await client.getAttributes(at: path)) == Self.directoryType
    }

    func makeDirectory(_ path: String) async throws {
        try await client.createDirectory(atPath: path)
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await client.rename(at: path, to: newPath)
    }

    /// Removes a file, a link or a whole folder tree. A linked folder is
    /// removed as a link; its target is left alone.
    func remove(_ entry: RemoteEntry) async throws {
        do {
            if entry.isDirectory, !entry.isSymlink {
                for child in try await list(entry.path) {
                    try Task.checkCancellation()
                    try await remove(child)
                }
                try await client.rmdir(at: entry.path)
            } else {
                try await client.remove(at: entry.path)
            }
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            // Already gone, e.g. removed by a cancelled upload's cleanup.
        }
    }

    private static func type(of attributes: SFTPFileAttributes) -> UInt32 {
        (attributes.permissions ?? 0) & typeMask
    }
}

enum SFTPErrorMessage {
    static func describe(_ error: Error) -> String {
        if let status = error as? SFTPMessage.Status {
            switch status.errorCode {
            case .noSuchFile: return "文件或目录不存在。"
            case .permissionDenied: return "权限不足。"
            case .noConnection, .connectionLost: return "SFTP 连接已断开。"
            case .unsupportedOperation: return "服务器不支持该操作。"
            default:
                return status.message.isEmpty ? "服务器返回错误。" : status.message
            }
        }
        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .errorStatus(let status): return describe(status)
            case .connectionClosed, .fileHandleInvalid: return "SFTP 连接已断开。"
            case .missingResponse: return "服务器没有响应 SFTP 请求，可能未启用 SFTP 子系统。"
            case .unsupportedVersion: return "服务器的 SFTP 协议版本不受支持。"
            default: return "SFTP 协议错误。"
            }
        }
        if error is SFTPUnavailable || error is ChannelError {
            return "SFTP 连接已断开。"
        }
        if error is SSHClientError {
            return "服务器拒绝了 SFTP 通道，可能未启用 SFTP 子系统。"
        }
        return error.localizedDescription
    }
}
