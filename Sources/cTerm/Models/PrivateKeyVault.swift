import CryptoKit
import Foundation

/// Keeps a copy of each saved host's private key in the credential store, so
/// cloud sync can carry it to another Mac. cTerm never writes into `~/.ssh`;
/// the copy is only used by cTerm itself.
///
/// - The key file at the host's path is imported when it is new or has changed
///   since the last import, stamped with the file's modification time. A
///   freshly rotated key therefore wins over the synced one, while an old file
///   that happens to sit at the same path on another Mac does not.
/// - Pointing the host at a different key file always imports that file.
/// - Connections use the stored copy, falling back to the file, so a host
///   works on a Mac that never had the key file.
enum PrivateKeyVault {
    static let kind = "privateKey"
    /// OpenSSH private keys are a few kilobytes; anything far larger is not one.
    static let maximumSize = 64 * 1024

    static func account(for profile: HostProfile) -> String {
        CredentialStore.account(for: profile.id, kind: kind)
    }

    private static func manages(_ profile: HostProfile) -> Bool {
        !profile.isTemporary && profile.auth == .privateKey
            && !profile.privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Imports the key file if it changed since the last import.
    static func refresh(_ profile: HostProfile) {
        guard manages(profile) else { return }
        let path = profile.expandedPrivateKeyPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size > 0, size <= maximumSize,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let account = account(for: profile)
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = "\(path)\n\(hash)"
        let previous = CredentialStore.importMarker(account: account)
        guard previous != marker else { return }

        // Record the import first: saving posts a change notification, and sync
        // may read the key again while handling it.
        CredentialStore.setImportMarker(marker, account: account)
        let stored = CredentialStore.load(account: account)
        if stored != text {
            let fileTime = ((attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0))
                .timeIntervalSince1970.rounded(.down)
            let pathChanged = previous.map { !$0.hasPrefix("\(path)\n") } ?? false
            let storedTime = CredentialStore.modifiedAt(account: account)?.timeIntervalSince1970
            if pathChanged {
                CredentialStore.save(text, account: account, modifiedAt: SyncClock.now())
            } else if stored == nil || storedTime == nil || fileTime >= storedTime! {
                CredentialStore.save(text, account: account, modifiedAt: Date(timeIntervalSince1970: fileTime))
            }
        }
    }

    /// The key to connect with: the stored copy if any, else the file.
    static func keyText(for profile: HostProfile) throws -> String {
        refresh(profile)
        if manages(profile), let stored = CredentialStore.load(account: account(for: profile)) {
            return stored
        }
        return try SSHKeyLoader.readKey(path: profile.privateKeyPath)
    }
}
