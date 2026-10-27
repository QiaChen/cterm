import Citadel
import Crypto
import Foundation
import NIOSSH

enum SSHKeyError: LocalizedError, Equatable {
    case missingPath
    case unreadable(String)
    case unsupportedFormat
    case unsupportedAlgorithm(String)
    case passphraseRequired
    case invalidPassphrase
    case corrupted(String)

    var errorDescription: String? {
        switch self {
        case .missingPath:
            return "请先选择私钥文件。"
        case .unreadable(let path):
            return "无法读取私钥文件：\(path)"
        case .unsupportedFormat:
            return "暂不支持该私钥格式。请使用 OpenSSH 格式（由 ssh-keygen 生成）的 Ed25519 或 RSA 私钥。"
        case .unsupportedAlgorithm(let algorithm):
            return "暂不支持 \(algorithm) 私钥。请使用 Ed25519 或 RSA 私钥。"
        case .passphraseRequired:
            return "该私钥已加密，请输入私钥口令。"
        case .invalidPassphrase:
            return "私钥口令不正确，或私钥文件已损坏。"
        case .corrupted(let reason):
            return "私钥解析失败：\(reason)"
        }
    }
}

struct SSHKeyInspection {
    let algorithm: String
    let isEncrypted: Bool
    let kdf: String
}

enum SSHKeyLoader {
    static func inspect(path: String) throws -> SSHKeyInspection {
        let text = try readKey(path: path)
        return try inspect(text: text)
    }

    static func inspect(text: String) throws -> SSHKeyInspection {
        let base64 = try openSSHBase64(text)
        guard let data = Data(base64Encoded: base64) else {
            throw SSHKeyError.corrupted("Base64 解码失败")
        }
        var reader = ByteReader(data: data)
        // The OpenSSH key container starts with the literal magic string
        // "openssh-key-v1" followed by a NUL byte — it is not an SSH string,
        // so it has no length prefix.
        guard let magicData = reader.readBytes(length: 14),
              String(data: magicData, encoding: .utf8) == "openssh-key-v1",
              reader.readByte() == 0 else {
            throw SSHKeyError.unsupportedFormat
        }
        guard let cipher = reader.readString(),
              let kdf = reader.readString(),
              reader.readData() != nil, // bcrypt salt + rounds, binary
              reader.readUInt32() != nil,
              let publicBlob = reader.readData() else {
            throw SSHKeyError.corrupted("私钥结构不完整")
        }
        var publicReader = ByteReader(data: publicBlob)
        guard let algorithm = publicReader.readString(), !algorithm.isEmpty else {
            throw SSHKeyError.corrupted("缺少公钥类型")
        }
        return SSHKeyInspection(
            algorithm: algorithm,
            isEncrypted: cipher != "none",
            kdf: kdf
        )
    }

    static func authentication(for profile: HostProfile, passphrase: String?) throws -> SSHAuthenticationMethod {
        let text = try PrivateKeyVault.keyText(for: profile)
        let inspection = try inspect(text: text)
        let username = profile.username

        let usableKeyText: String
        if inspection.isEncrypted {
            guard let passphrase else { throw SSHKeyError.passphraseRequired }
            // Citadel's key parser rejects modern OpenSSH bcrypt work factors
            // (ssh-keygen defaults to 24 rounds). Unlock the key with the
            // system ssh-keygen in a private temporary directory, then parse
            // the unencrypted copy. The temporary file is removed immediately.
            usableKeyText = try unlockEncryptedKey(text: text, passphrase: passphrase)
        } else {
            usableKeyText = text
        }

        do {
            switch inspection.algorithm {
            case "ssh-ed25519":
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: usableKeyText)
                return .ed25519(username: username, privateKey: key)
            case "ssh-rsa":
                let key = try Insecure.RSA.PrivateKey(sshRsa: usableKeyText)
                return .rsa(username: username, privateKey: key)
            default:
                throw SSHKeyError.unsupportedAlgorithm(inspection.algorithm)
            }
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw SSHKeyError.corrupted(error.localizedDescription)
        }
    }

    private static func unlockEncryptedKey(text: String, passphrase: String) throws -> String {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cterm-key-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SSHKeyError.corrupted("无法创建临时目录：\(error.localizedDescription)")
        }
        defer { try? fileManager.removeItem(at: directory) }

        let keyURL = directory.appendingPathComponent("id")
        do {
            try text.write(to: keyURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        } catch {
            throw SSHKeyError.corrupted("无法写入临时私钥：\(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-p", "-P", passphrase, "-N", "", "-f", keyURL.path]
        process.standardInput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw SSHKeyError.corrupted("无法启动 ssh-keygen：\(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            NSLog("cTerm: ssh-keygen unlock failed: \(message)")
            throw SSHKeyError.invalidPassphrase
        }
        guard let decrypted = try? String(contentsOf: keyURL, encoding: .utf8) else {
            throw SSHKeyError.corrupted("无法读取解锁后的私钥")
        }
        return decrypted
    }

    static func readKey(path: String?) throws -> String {
        guard let path, !path.isEmpty else { throw SSHKeyError.missingPath }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: expanded) else {
            throw SSHKeyError.unreadable(expanded)
        }
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw SSHKeyError.unreadable(expanded)
        }
        return text
    }

    private static func openSSHBase64(_ text: String) throws -> String {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard text.contains(begin), text.contains(end) else {
            throw SSHKeyError.unsupportedFormat
        }
        guard let beginRange = text.range(of: begin),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else {
            throw SSHKeyError.unsupportedFormat
        }
        let body = text[beginRange.upperBound..<endRange.lowerBound]
        let base64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !base64.isEmpty else { throw SSHKeyError.corrupted("私钥内容为空") }
        return base64
    }
}

private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func readByte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(bytes[offset + index])
        }
        offset += 4
        return value
    }

    mutating func readBytes(length: Int) -> Data? {
        guard length >= 0, offset + length <= bytes.count else { return nil }
        let data = Data(bytes[offset..<(offset + length)])
        offset += length
        return data
    }

    mutating func readData() -> Data? {
        guard let length = readUInt32() else { return nil }
        let count = Int(length)
        guard offset + count <= bytes.count else { return nil }
        let data = Data(bytes[offset..<(offset + count)])
        offset += count
        return data
    }

    mutating func readString() -> String? {
        guard let data = readData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
