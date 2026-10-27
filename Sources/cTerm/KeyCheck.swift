#if DEBUG
import Foundation

/// Hidden diagnostic entry point for validating OpenSSH key parsing:
/// `cTerm --key-check /path/to/key [passphrase]`
enum KeyCheck {
    static func run(path: String, passphrase: String?) -> Never {
        do {
            let inspection = try SSHKeyLoader.inspect(path: path)
            print("algorithm=\(inspection.algorithm) encrypted=\(inspection.isEncrypted) kdf=\(inspection.kdf)")
            var profile = HostProfile(name: "key-check", host: "localhost", username: "test", auth: .privateKey,
                                      isTemporary: true)
            profile.privateKeyPath = path
            _ = try SSHKeyLoader.authentication(for: profile, passphrase: passphrase)
            print("KEY CHECK OK")
            exit(0)
        } catch {
            print("KEY CHECK FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}
#endif
