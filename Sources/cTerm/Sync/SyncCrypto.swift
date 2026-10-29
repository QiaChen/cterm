import CommonCrypto
import CryptoKit
import Foundation

/// Password-based authenticated encryption for the cloud sync file.
///
/// The key is derived with PBKDF2-HMAC-SHA256 from the sync password and a
/// random 16-byte salt, then the JSON is sealed with AES-256-GCM under a
/// random 12-byte nonce. Every encryption uses a fresh salt and nonce.
///
/// The file is a small JSON envelope. Its header (format, version, KDF name,
/// iteration count and salt) is bound to the ciphertext as additional
/// authenticated data, so changing any of it makes decryption fail just like
/// a wrong password or a modified ciphertext.
enum SyncCrypto {
    static let format = "cterm-sync"
    static let version = 1
    static let kdfName = "PBKDF2-HMAC-SHA256"
    static let cipherName = "AES-256-GCM"
    /// OWASP's current recommendation for PBKDF2-HMAC-SHA256.
    static let defaultIterations = 600_000
    /// Files asking for fewer rounds are refused, so a forged file cannot
    /// trick a device into using a weak key for its next upload.
    static let minimumIterations = 100_000
    /// Upper bound against a file that would make key derivation hang.
    static let maximumIterations = 10_000_000

    struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: String
        var cipher: String
        var nonce: String
        var ciphertext: String
        var tag: String
    }

    /// The salt and work factor a key is derived with; kept so a key derived
    /// once can seal many writes.
    struct KeyParameters: Equatable {
        var salt: Data
        var iterations: Int

        static func fresh(iterations: Int = SyncCrypto.defaultIterations) -> KeyParameters {
            KeyParameters(salt: SyncCrypto.randomBytes(16), iterations: iterations)
        }
    }

    static func encrypt(_ plaintext: Data, password: String, iterations: Int = defaultIterations) throws -> Data {
        let parameters = KeyParameters.fresh(iterations: iterations)
        let key = try deriveKey(password: password, salt: parameters.salt, iterations: iterations)
        return try seal(plaintext, key: key, parameters: parameters)
    }

    static func decrypt(_ data: Data, password: String, minimumIterations: Int = minimumIterations) throws -> Data {
        let parameters = try keyParameters(of: data, minimumIterations: minimumIterations)
        let key = try deriveKey(password: password, salt: parameters.salt, iterations: parameters.iterations)
        return try open(data, key: key, minimumIterations: minimumIterations)
    }

    /// Seals with an already derived key; a fresh nonce every time.
    static func seal(_ plaintext: Data, key: SymmetricKey, parameters: KeyParameters,
                     format: String = format) throws -> Data {
        let saltText = parameters.salt.base64EncodedString()
        let aad = header(format: format, iterations: parameters.iterations, salt: saltText)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        let envelope = Envelope(
            format: format,
            version: version,
            kdf: kdfName,
            iterations: parameters.iterations,
            salt: saltText,
            cipher: cipherName,
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Reads the salt and work factor a file was sealed with, checking them.
    static func keyParameters(of data: Data, format: String = format,
                              minimumIterations: Int = minimumIterations) throws -> KeyParameters {
        let envelope = try validEnvelope(data, format: format, minimumIterations: minimumIterations)
        return KeyParameters(salt: Data(base64Encoded: envelope.salt)!, iterations: envelope.iterations)
    }

    static func open(_ data: Data, key: SymmetricKey, format: String = format,
                     minimumIterations: Int = minimumIterations) throws -> Data {
        let envelope = try validEnvelope(data, format: format, minimumIterations: minimumIterations)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(base64Encoded: envelope.nonce)!),
                ciphertext: Data(base64Encoded: envelope.ciphertext)!,
                tag: Data(base64Encoded: envelope.tag)!
            )
            return try AES.GCM.open(box, using: key,
                                    authenticating: header(format: format, iterations: envelope.iterations, salt: envelope.salt))
        } catch {
            throw SyncError.wrongPassword
        }
    }

    private static func validEnvelope(_ data: Data, format: String, minimumIterations: Int) throws -> Envelope {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == format else {
            throw SyncError.notASyncFile
        }
        guard envelope.version <= version else { throw SyncError.newerFormat }
        guard envelope.kdf == kdfName, envelope.cipher == cipherName,
              (minimumIterations...maximumIterations).contains(envelope.iterations),
              let salt = Data(base64Encoded: envelope.salt), salt.count >= 16,
              Data(base64Encoded: envelope.nonce) != nil,
              Data(base64Encoded: envelope.ciphertext) != nil,
              let tag = Data(base64Encoded: envelope.tag), tag.count == 16 else {
            throw SyncError.unsupportedParameters
        }
        return envelope
    }

    /// Whether data looks like an encrypted file of `format` (without decrypting it).
    static func isEnvelope(_ data: Data, format: String = format) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.format == format
    }

    private static func header(format: String, iterations: Int, salt: String) -> Data {
        Data("\(format)|v\(version)|\(kdfName)|\(iterations)|\(salt)|\(cipherName)".utf8)
    }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SyncError.unsupportedParameters }
        return SymmetricKey(data: derived)
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }
}
