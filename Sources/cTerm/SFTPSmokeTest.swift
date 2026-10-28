#if DEBUG
import AppKit
import Citadel
import Crypto
import Foundation

/// Hidden diagnostic entry point for the SFTP panel's transfer code:
/// `CTERM_SSH_HOST=... CTERM_SSH_USER=... (CTERM_SSH_PASSWORD=... | CTERM_SSH_KEY=path) cTerm --sftp-smoke`
/// Set `CTERM_SFTP_READONLY=1` for servers that only allow downloads.
@MainActor
enum SFTPSmokeTest {
    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CTERM_SSH_HOST"], let user = environment["CTERM_SSH_USER"] else {
            print("missing CTERM_SSH_* environment variables")
            exit(2)
        }
        let port = Int(environment["CTERM_SSH_PORT"] ?? "22") ?? 22
        let authentication: SSHAuthenticationMethod
        if let keyPath = environment["CTERM_SSH_KEY"],
           let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
           let key = try? Curve25519.Signing.PrivateKey(sshEd25519: text) {
            authentication = .ed25519(username: user, privateKey: key)
        } else if let password = environment["CTERM_SSH_PASSWORD"] {
            authentication = .passwordBased(username: user, password: password)
        } else {
            print("missing CTERM_SSH_PASSWORD or a readable ed25519 CTERM_SSH_KEY")
            exit(2)
        }
        let readOnly = environment["CTERM_SFTP_READONLY"] == "1"

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cterm-sftp-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let knownHosts = KnownHostsStore(fileURL: temporary.appendingPathComponent("known_hosts.json"))
        let validator = HostKeyValidationDelegate(host: host, port: port, knownHosts: knownHosts) { _ in true }
        let profile = HostProfile(name: "smoke", host: host, port: port, username: user, auth: .password)
        let connection = SSHConnection(profile: profile, authentication: authentication,
                                       hostKeyValidator: validator, cols: 80, rows: 24)
        connection.onStateChange = { state in
            print("state: \(state)")
            guard state == .connected else {
                if case .failed(let message) = state {
                    print("FAILED: \(message)")
                    exit(1)
                }
                return
            }
            Task { @MainActor in
                do {
                    let session = SFTPSession(client: try await connection.openSFTP())
                    let queue = TransferQueue()
                    queue.attach(session)
                    if environment["CTERM_SFTP_COMMANDS"] == "1" {
                        try await commandChecks(connection, session)
                    } else if let linkParent = environment["CTERM_SFTP_LINKS"] {
                        try await linkChecks(session, parent: linkParent)
                    } else if readOnly {
                        try await readOnlyChecks(session, queue, temporary)
                    } else {
                        try await readWriteChecks(session, queue, temporary)
                    }
                    try? FileManager.default.removeItem(at: temporary)
                    print("SFTP SMOKE OK")
                    exit(0)
                } catch {
                    print("FAILED: \(SFTPErrorMessage.describe(error)) (\(error))")
                    exit(1)
                }
            }
        }
        connection.onEnd = { message in
            print("END: \(message ?? "nil")")
            exit(1)
        }
        connection.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            print("TIMEOUT")
            exit(3)
        }
        NSApplication.shared.run()
        exit(0)
    }

    /// chmod, zip and extraction over an exec channel, with awkward names.
    private static func commandChecks(_ connection: SSHConnection, _ session: SFTPSession) async throws {
        print("  commands:")
        let home = try await session.homeDirectory()
        let root = RemotePath.join(home, "cterm-cmd-smoke-\(UUID().uuidString.prefix(8))")
        func sh(_ body: String) async throws -> RemoteCommandResult {
            try await connection.runCommand("sh -c " + RemotePath.shellQuoted(body))
        }
        func mode(_ path: String) async throws -> UInt32 {
            (try await session.attributes(of: path).permissions ?? 0) & 0o777
        }
        let q = RemotePath.shellQuoted
        let folder = RemotePath.join(root, "my 'docs'")
        let file = RemotePath.join(folder, "a b.txt")
        _ = try await sh("mkdir -p \(q(folder))/sub && printf hello > \(q(file)) && printf deep > \(q(folder))/sub/c.txt")
        do {
            var result = try await connection.runCommand(RemoteCommands.chmod([file], mode: 0o750, recursive: false))
            try check(result.succeeded, "chmod exit 0 (\(result.errorOutput))")
            try check(try await mode(file) == 0o750, "file is now 750")
            result = try await connection.runCommand(RemoteCommands.chmod([folder], mode: 0o700, recursive: true))
            try check(result.succeeded, "chmod -R exit 0")
            try check(try await mode(RemotePath.join(folder, "sub/c.txt")) == 0o700, "chmod -R reached a nested file")
            _ = try await connection.runCommand(RemoteCommands.chmod([folder], mode: 0o755, recursive: true))
            result = try await connection.runCommand(RemoteCommands.chmod([RemotePath.join(root, "missing")], mode: 0o644, recursive: false))
            try check(!result.succeeded && !result.failureMessage.isEmpty, "chmod of a missing file reports: \(result.failureMessage)")

            result = try await connection.runCommand(RemoteCommands.zip(["my 'docs'"], in: root, into: "my 'docs'.zip"))
            try check(result.succeeded, "zip exit 0 (\(result.failureMessage))")
            try check(await session.exists(RemotePath.join(root, "my 'docs'.zip")), "zip archive exists")
            let detected = ArchiveFormat.detect("my 'docs'.zip")
            try check(detected?.stem == "my 'docs'", "zip stem detected")
            let out = RemotePath.join(root, "unzipped")
            result = try await connection.runCommand(RemoteCommands.extract(RemotePath.join(root, "my 'docs'.zip"),
                                                                            format: .zip, into: out, output: "x"))
            try check(result.succeeded, "unzip exit 0 (\(result.failureMessage))")
            let unzipped = try await sh("cat \(q(RemotePath.join(out, "my 'docs'/sub/c.txt")))")
            try check(unzipped.output == "deep", "unzipped nested content intact")

            _ = try await sh("cd \(q(root)) && tar -czf t.tar.gz \"my 'docs'\" && gzip -c \(q(file)) > single.txt.gz")
            try check(ArchiveFormat.detect("t.tar.gz").map { $0.format == .tarGzip && $0.stem == "t" } == true,
                      "tar.gz detected before gz")
            result = try await connection.runCommand(RemoteCommands.extract(RemotePath.join(root, "t.tar.gz"),
                                                                            format: .tarGzip, into: RemotePath.join(root, "t"), output: "t"))
            try check(result.succeeded, "tar.gz exit 0")
            try check(await session.exists(RemotePath.join(root, "t/my 'docs'/a b.txt")), "tar.gz extracted")
            result = try await connection.runCommand(RemoteCommands.extract(RemotePath.join(root, "single.txt.gz"),
                                                                            format: .gzip, into: root, output: "single.txt"))
            try check(result.succeeded, "gz exit 0")
            try check(try await sh("cat \(q(RemotePath.join(root, "single.txt")))").output == "hello", "gz decompressed")

            _ = try await sh("printf junk > \(q(root))/bad.tar.gz")
            result = try await connection.runCommand(RemoteCommands.extract(RemotePath.join(root, "bad.tar.gz"),
                                                                            format: .tarGzip, into: RemotePath.join(root, "bad"), output: "bad"))
            try check(!result.succeeded && result.missingTool == nil, "corrupt archive fails: \(result.failureMessage)")

            for (name, format, tool) in [("x.7z", ArchiveFormat.sevenZip, "7z"), ("x.rar", .rar, "unrar")] {
                let probe = try await sh("command -v \(tool) || command -v 7zz || command -v 7za")
                guard probe.output.isEmpty else {
                    print("  skip \(tool) is installed")
                    continue
                }
                result = try await connection.runCommand(RemoteCommands.extract(RemotePath.join(root, name),
                                                                                format: format, into: root, output: "x"))
                try check(result.missingTool == tool, "missing \(tool) detected")
                try check(result.failureMessage.contains("请先安装"), "install hint shown")
            }
        } catch {
            _ = try? await sh("rm -rf \(q(root))")
            throw error
        }
        _ = try await sh("rm -rf \(q(root))")
        try check(!(await session.exists(root)), "scratch folder removed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        print(condition ? "  ok   \(message)" : "  FAIL \(message)")
        if !condition { throw SmokeFailure(message: message) }
    }

    private static func wait(_ item: TransferItem, _ queue: TransferQueue) async {
        while !item.isFinished {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = queue
    }

    /// Edit-and-sync: a working copy is watched and every save goes back.
    private static func editChecks(_ session: SFTPSession, _ queue: TransferQueue, _ local: URL,
                                   _ remote: String) async throws {
        print("  edit:")
        let fileManager = FileManager.default
        let remotePath = RemotePath.join(remote, "config.conf")
        let seed = local.appendingPathComponent("seed.conf")

        func putRemote(_ text: String, at path: String) async throws {
            try Data(text.utf8).write(to: seed)
            try await Transfers.upload(client: session.client, from: seed, to: path, counter: TransferCounter())
        }
        func remoteText(_ path: String) async throws -> String {
            let buffer = try await session.client.withFile(filePath: path, flags: .read) { try await $0.readAll() }
            return String(decoding: buffer.readableBytesView, as: UTF8.self)
        }
        func waitUntil(_ seconds: Double = 8, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        func isFailed(_ state: RemoteEditSession.State) -> Bool {
            if case .failed = state { return true }
            return false
        }

        try await putRemote("a=1\n", at: remotePath)
        let manager = RemoteEditManager(root: local.appendingPathComponent("edit-root"))
        var conflicts = 0
        var nextChoice = RemoteEditSession.ConflictChoice.overwrite
        manager.resolveConflict = { _ in
            conflicts += 1
            return nextChoice
        }
        var opened: URL?
        guard let entry = try await session.list(remote).first(where: { $0.name == "config.conf" }),
              let edit = manager.edit(entry, sftp: session, queue: queue, open: { opened = $0 }) else {
            throw SmokeFailure(message: "edit did not start")
        }
        await waitUntil { edit.state == .editing }
        try check(opened == edit.localURL && opened?.lastPathComponent == "config.conf", "editor gets a copy with the real name")
        try check((try? String(contentsOf: edit.localURL, encoding: .utf8)) == "a=1\n", "working copy holds the remote text")
        let folderMode = (try fileManager.attributesOfItem(atPath: edit.localURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try check(folderMode == 0o700, "working copy folder is private (\(String(folderMode, radix: 8)))")

        // Save in place, as TextEdit does.
        try Data("a=2\n".utf8).write(to: edit.localURL)
        await waitUntil { edit.syncCount == 1 }
        try check(try await remoteText(remotePath) == "a=2\n", "save in place reaches the server")

        // Atomic save: write elsewhere, then rename over, as VS Code and vim do.
        let temp = edit.localURL.deletingLastPathComponent().appendingPathComponent(".config.conf.swp")
        try Data("a=33\n".utf8).write(to: temp)
        _ = try fileManager.replaceItemAt(edit.localURL, withItemAt: temp)
        await waitUntil { edit.syncCount == 2 }
        try check(try await remoteText(remotePath) == "a=33\n", "write-then-rename save reaches the server")

        // Saving without changes uploads nothing.
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: edit.localURL.path)
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        try check(edit.syncCount == 2, "unchanged save is not uploaded")

        // Someone else changes the server copy, then we save: overwrite.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        try await putRemote("theirs=1\n", at: remotePath)
        nextChoice = .overwrite
        try Data("a=4\n".utf8).write(to: edit.localURL)
        await waitUntil { edit.syncCount == 3 }
        try check(conflicts == 1, "conflict is detected and asked about (\(conflicts))")
        try check(try await remoteText(remotePath) == "a=4\n", "overwrite puts our version on the server")

        // Again, but keep theirs and save ours as a copy.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        try await putRemote("theirs=22\n", at: remotePath)
        nextChoice = .saveCopy
        try Data("a=5\n".utf8).write(to: edit.localURL)
        await waitUntil { edit.syncCount == 4 }
        let copyPath = RemotePath.join(remote, "config 2.conf")
        try check(conflicts == 2 && edit.remotePath == copyPath, "save-copy switches editing to \"config 2.conf\"")
        try check(try await remoteText(remotePath) == "theirs=22\n", "their version is kept")
        try check(try await remoteText(copyPath) == "a=5\n", "our version is in the copy")

        // Discard: nothing uploaded, still editing.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        try await putRemote("x", at: copyPath)
        nextChoice = .discard
        try Data("a=6\n".utf8).write(to: edit.localURL)
        await waitUntil { conflicts == 3 }
        try? await Task.sleep(nanoseconds: 500_000_000)
        try check(edit.syncCount == 4 && edit.state == .editing, "discard skips the upload and keeps editing")
        try check(try await remoteText(copyPath) == "x", "server copy untouched after discard")
        try check(edit.hasUnsyncedChanges, "discarded save still counts as unsynced")

        // The server refuses the write: report it, keep the file, retry later.
        // This sshd serves this Mac's own disk, so lock the file from outside.
        nextChoice = .overwrite
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copyPath)
        try Data("a=7\n".utf8).write(to: edit.localURL)
        await waitUntil { isFailed(edit.state) }
        try check(isFailed(edit.state), "refused write shows as not synced (\(edit.state))")
        try check(fileManager.fileExists(atPath: copyPath), "failed overwrite does not delete the server file")
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copyPath)
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        try Data("a=8\n".utf8).write(to: edit.localURL)
        await waitUntil { edit.syncCount == 5 }
        try check(edit.state == .editing, "next save after fixing permissions syncs (\(edit.state))")
        try check(try await remoteText(copyPath) == "a=8\n", "server has the latest save")

        let folder = edit.localURL.deletingLastPathComponent()
        manager.stop(edit)
        try check(!fileManager.fileExists(atPath: folder.path) && manager.sessions.isEmpty, "stop editing removes the working copy")
    }

    /// Opens every symlinked folder in `parent` the way the panel does.
    private static func linkChecks(_ session: SFTPSession, parent: String) async throws {
        let started = Date()
        let entries = try await session.list(parent)
        print("  listed \(entries.count) entries in \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
        let links = entries.filter(\.isSymlink)
        let linkedFolders = links.filter(\.isDirectory).count
        print("  links: \(links.count), to folders: \(linkedFolders), as files: \(links.count - linkedFolders)")
        if links.count > 50 { return }
        print("links in \(parent): \(links.map { "\($0.name)\($0.isDirectory ? "/" : "")" })")
        try check(!links.isEmpty, "found symlinks")
        for link in links {
            guard link.isDirectory else {
                print("  file \(link.name) (size \(link.size.map(String.init) ?? "?"))")
                continue
            }
            do {
                let resolved = try await session.realPath(link.path)
                let children = try await session.list(resolved)
                print("  ok   \(link.path) -> \(resolved): \(children.map(\.name))")
            } catch {
                print("  FAIL \(link.path): \(SFTPErrorMessage.describe(error))")
            }
        }
    }

    private static func readOnlyChecks(_ session: SFTPSession, _ queue: TransferQueue, _ local: URL) async throws {
        let home = try await session.homeDirectory()
        print("home: \(home)")
        let root = try await session.list(home)
        print("listing: \(root.map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: " "))")
        try check(!root.isEmpty, "home directory lists entries")
        try check(root.allSatisfy { $0.name != "." && $0.name != ".." }, "dot entries are filtered")

        let files = root.filter { !$0.isDirectory }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        if let largest = files.first {
            let target = local.appendingPathComponent(largest.name)
            let started = Date()
            let item = queue.enqueueDownload(largest, to: target)
            await wait(item, queue)
            let size = Transfers.localSize(target)
            print("  downloaded \(largest.name): \(size) bytes in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            try check(item.state == .completed, "file download completes (\(item.state))")
            try check(size == largest.size, "downloaded size matches remote (\(size) vs \(largest.size ?? 0))")
        }

        if let folder = root.first(where: { $0.isDirectory && !$0.isSymlink }) {
            let target = local.appendingPathComponent(folder.name)
            let item = queue.enqueueDownload(folder, to: target)
            await wait(item, queue)
            let count = (FileManager.default.enumerator(atPath: target.path)?.allObjects.count) ?? 0
            try check(item.state == .completed, "folder download completes (\(item.state)), \(count) items")
        }

        // Overwriting an existing file the server won't let us write.
        if let existing = root.first(where: { !$0.isDirectory }) {
            let probe = local.appendingPathComponent("overwrite.txt")
            try Data("edited\n".utf8).write(to: probe)
            let started = Date()
            let item = queue.enqueueUpload(probe, to: existing.path, isEditSync: true)
            for _ in 0..<200 where !item.isFinished {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("  overwrite \(existing.name): \(item.state) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s, session active \(session.isActive)")
            try check(item.isFinished, "refused overwrite finishes instead of hanging")
        }

        let probe = local.appendingPathComponent("probe.txt")
        try Data("cterm".utf8).write(to: probe)
        let upload = queue.enqueueUpload(probe, to: RemotePath.join(home, "cterm-probe-\(UUID().uuidString).txt"))
        await wait(upload, queue)
        print("  upload on read-only server: \(upload.state)")
        try check(upload.state != .completed, "read-only server rejects upload with a message")
    }

    private static func readWriteChecks(_ session: SFTPSession, _ queue: TransferQueue, _ local: URL) async throws {
        let fileManager = FileManager.default
        let home = try await session.homeDirectory()
        let remote = RemotePath.join(home, "cterm-sftp-smoke-\(UUID().uuidString.prefix(8))")
        try await session.makeDirectory(remote)
        let scratch = RemoteEntry(name: RemotePath.name(of: remote), path: remote, isDirectory: true,
                                  isSymlink: false, size: nil, modified: nil, permissions: nil)
        do {
            try await readWriteSteps(session, queue, local, remote)
        } catch {
            try? await session.remove(scratch)
            throw error
        }
        try await session.remove(scratch)
        try check(!(await session.exists(remote)), "scratch folder is cleaned up")
    }

    private static func readWriteSteps(_ session: SFTPSession, _ queue: TransferQueue, _ local: URL,
                                       _ remote: String) async throws {
        let fileManager = FileManager.default
        try await editChecks(session, queue, local, remote)

        // Odd sizes catch off-by-one errors at chunk and window edges.
        let sizes = [0, 1, Transfers.chunkSize, Transfers.chunkSize * Transfers.window + 1, 5_000_123]
        let source = local.appendingPathComponent("up")
        try fileManager.createDirectory(at: source.appendingPathComponent("nested/深层 目录"), withIntermediateDirectories: true)
        var originals: [String: Data] = [:]
        for size in sizes {
            var bytes = [UInt8](repeating: 0, count: size)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            let name = "file-\(size).bin"
            originals[name] = Data(bytes)
            try Data(bytes).write(to: source.appendingPathComponent(name))
        }
        try Data("你好 SFTP\n".utf8).write(to: source.appendingPathComponent("nested/深层 目录/中文 文件.txt"))

        // Single files, through the same queue the panel uses.
        var uploads: [TransferItem] = []
        for name in originals.keys.sorted() {
            uploads.append(queue.enqueueUpload(source.appendingPathComponent(name), to: RemotePath.join(remote, name)))
        }
        let started = Date()
        for item in uploads { await wait(item, queue) }
        print("  uploaded \(uploads.count) files in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        try check(uploads.allSatisfy { $0.state == .completed }, "file uploads complete")
        try check(queue.items.filter { $0.state == .running }.isEmpty, "queue drains")

        let listing = try await session.list(remote)
        for (name, data) in originals {
            let entry = listing.first { $0.name == name }
            try check(entry?.size == UInt64(data.count), "remote size of \(name) is \(data.count)")
        }

        // Download them back and compare bytes.
        let back = local.appendingPathComponent("down")
        try fileManager.createDirectory(at: back, withIntermediateDirectories: true)
        var downloads: [(TransferItem, String)] = []
        for entry in listing where originals[entry.name] != nil {
            downloads.append((queue.enqueueDownload(entry, to: back.appendingPathComponent(entry.name)), entry.name))
        }
        for (item, _) in downloads { await wait(item, queue) }
        for (item, name) in downloads {
            let data = try? Data(contentsOf: back.appendingPathComponent(name))
            try check(item.state == .completed && data == originals[name], "round trip of \(name) is byte-identical")
        }
        let leftovers = (try fileManager.contentsOfDirectory(atPath: back.path)).filter { $0.hasSuffix(".ctermpart") }
        try check(leftovers.isEmpty, "no partial files left behind")

        // Folder upload and download, with non-ASCII names.
        let folderUpload = queue.enqueueUpload(source.appendingPathComponent("nested"), to: RemotePath.join(remote, "nested"))
        await wait(folderUpload, queue)
        try check(folderUpload.state == .completed, "folder upload completes (\(folderUpload.state))")
        let nested = try await session.list(RemotePath.join(remote, "nested/深层 目录"))
        try check(nested.map(\.name) == ["中文 文件.txt"], "nested folder and UTF-8 names survive")
        let folderEntry = try await session.list(remote).first { $0.name == "nested" }!
        let folderDownload = queue.enqueueDownload(folderEntry, to: back.appendingPathComponent("nested"))
        await wait(folderDownload, queue)
        let text = try? String(contentsOf: back.appendingPathComponent("nested/深层 目录/中文 文件.txt"), encoding: .utf8)
        try check(folderDownload.state == .completed && text == "你好 SFTP\n", "folder download round trip")

        // Rename and the Finder-style copy names used for conflicts.
        let renamedPath = RemotePath.join(remote, "renamed.bin")
        try await session.rename(RemotePath.join(remote, "file-1.bin"), to: renamedPath)
        try check(await session.exists(renamedPath), "rename works")
        try check(SFTPPanelViewController.uniqueName("a.txt", taken: ["a.txt", "a 2.txt"]) == "a 3.txt", "unique name for a.txt")
        try check(SFTPPanelViewController.uniqueName(".bashrc", taken: [".bashrc"]) == ".bashrc 2", "unique name for a dotfile")
        try check(SFTPPanelViewController.uniqueName("dir", taken: ["dir"]) == "dir 2", "unique name without extension")

        // Cancelling an upload stops it and removes the partial remote file.
        let big = local.appendingPathComponent("big.bin")
        try Data(count: 64 * 1024 * 1024).write(to: big)
        let bigRemote = RemotePath.join(remote, "big.bin")
        let cancelled = queue.enqueueUpload(big, to: bigRemote)
        try? await Task.sleep(nanoseconds: 150_000_000)
        queue.cancel(cancelled)
        await wait(cancelled, queue)
        try check(cancelled.state == .cancelled, "cancel marks the upload cancelled (\(cancelled.state))")
        try? await Task.sleep(nanoseconds: 300_000_000)
        try check(!(await session.exists(bigRemote)), "cancelled upload leaves no remote file")

        // Recursive delete.
        try await session.remove(folderEntry)
        try check(!(await session.exists(folderEntry.path)), "recursive delete removes the folder")

        // Errors read as sentences, not protocol dumps.
        do {
            _ = try await session.list(RemotePath.join(remote, "missing"))
            try check(false, "listing a missing folder fails")
        } catch {
            print("  missing folder error: \(SFTPErrorMessage.describe(error))")
            try check(SFTPErrorMessage.describe(error) == "文件或目录不存在。", "missing folder error is readable")
        }

        // Losing the channel fails pending work instead of hanging.
        let late = queue.enqueueUpload(big, to: bigRemote)
        queue.detach(reason: "连接已断开")
        try check(late.state == .failed("连接已断开"), "detach fails pending transfers")
    }
}

private struct SmokeFailure: Error {
    let message: String
}
#endif
