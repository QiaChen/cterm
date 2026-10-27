import CryptoKit
import Foundation
import NIOCore
import NIOSSH

struct StoredHostKey: Codable, Equatable {
    var host: String
    var port: Int
    var algorithm: String
    var openSSHKey: String
    var fingerprint: String
    var firstSeen: Date

    var identifier: String { "\(host.lowercased()):\(port)" }
}

/// Trust on first use host key storage, similar in spirit to known_hosts.
final class KnownHostsStore {
    private(set) var keys: [String: StoredHostKey] = [:]
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.supportDirectory.appendingPathComponent("known_hosts.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func key(for host: String, port: Int) -> StoredHostKey? {
        keys["\(host.lowercased()):\(port)"]
    }

    func store(_ key: StoredHostKey) {
        keys[key.identifier] = key
        persist()
    }

    func remove(host: String, port: Int) {
        keys.removeValue(forKey: "\(host.lowercased()):\(port)")
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? decoder.decode([String: StoredHostKey].self, from: data) {
            keys = decoded
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(keys)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("cTerm: failed to save known hosts: \(error)")
        }
    }
}

struct HostKeyInfo {
    let host: String
    let port: Int
    let algorithm: String
    let openSSHKey: String
    let fingerprint: String
    let existing: StoredHostKey?

    var isChanged: Bool {
        guard let existing else { return false }
        return existing.algorithm == algorithm && existing.openSSHKey != openSSHKey
    }

    var isNewAlgorithm: Bool {
        guard let existing else { return false }
        return existing.algorithm != algorithm
    }

    var summary: String {
        "\(host):\(port)"
    }
}

enum HostKeyFingerprint {
    static func make(from publicKey: NIOSSHPublicKey, host: String, port: Int,
                     existing: StoredHostKey?) -> HostKeyInfo {
        let openSSH = String(openSSHPublicKey: publicKey)
        let components = openSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let algorithm = components.first.map(String.init) ?? "unknown"
        let base64 = components.count > 1 ? String(components[1]) : ""
        let blob = Data(base64Encoded: base64) ?? Data()
        let digest = SHA256.hash(data: blob)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return HostKeyInfo(
            host: host,
            port: port,
            algorithm: algorithm,
            openSSHKey: openSSH,
            fingerprint: fingerprint,
            existing: existing
        )
    }
}

struct HostKeyRejected: Error {}

/// Validates host keys against trusted keys, asking the user (through the
/// supplied async closure) when a key is unknown or has changed.
final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate {
    let host: String
    let port: Int
    let knownHosts: KnownHostsStore
    let decide: (HostKeyInfo) async -> Bool

    init(host: String, port: Int, knownHosts: KnownHostsStore,
         decide: @escaping (HostKeyInfo) async -> Bool) {
        self.host = host
        self.port = port
        self.knownHosts = knownHosts
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Host key storage and UI are main-actor state. The delegate is called
        // on the SSH event loop, so hop over before doing any store access.
        Task { @MainActor in
            let existing = self.knownHosts.key(for: self.host, port: self.port)
            let info = HostKeyFingerprint.make(
                from: hostKey,
                host: self.host,
                port: self.port,
                existing: existing
            )

            if let existing,
               existing.algorithm == info.algorithm,
               existing.openSSHKey == info.openSSHKey {
                validationCompletePromise.succeed(())
                return
            }

            let accepted = await self.decide(info)
            if accepted {
                self.knownHosts.store(StoredHostKey(
                    host: self.host,
                    port: self.port,
                    algorithm: info.algorithm,
                    openSSHKey: info.openSSHKey,
                    fingerprint: info.fingerprint,
                    firstSeen: existing?.firstSeen ?? Date()
                ))
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejected())
            }
        }
    }
}
