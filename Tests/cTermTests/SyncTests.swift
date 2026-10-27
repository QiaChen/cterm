import XCTest
@testable import cTerm

final class SyncCryptoTests: XCTestCase {
    // Low iteration counts keep the tests fast; production uses 600 000.
    private let rounds = 1_000

    func testRoundTrip() throws {
        let plaintext = Data("{\"hello\":\"世界\"}".utf8)
        let sealed = try SyncCrypto.encrypt(plaintext, password: "correct horse", iterations: rounds)
        XCTAssertTrue(SyncCrypto.isEnvelope(sealed))
        XCTAssertNil(String(data: sealed, encoding: .utf8)?.range(of: "世界"))
        let opened = try SyncCrypto.decrypt(sealed, password: "correct horse", minimumIterations: rounds)
        XCTAssertEqual(opened, plaintext)
    }

    func testEachEncryptionUsesFreshSaltAndNonce() throws {
        let plaintext = Data("same".utf8)
        let a = try JSONDecoder().decode(SyncCrypto.Envelope.self,
                                         from: SyncCrypto.encrypt(plaintext, password: "pw-12345", iterations: rounds))
        let b = try JSONDecoder().decode(SyncCrypto.Envelope.self,
                                         from: SyncCrypto.encrypt(plaintext, password: "pw-12345", iterations: rounds))
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertNotEqual(a.ciphertext, b.ciphertext)
    }

    func testWrongPasswordFails() throws {
        let sealed = try SyncCrypto.encrypt(Data("secret".utf8), password: "right-password", iterations: rounds)
        XCTAssertThrowsError(try SyncCrypto.decrypt(sealed, password: "wrong-password", minimumIterations: rounds)) {
            XCTAssertEqual($0 as? SyncError, .wrongPassword)
        }
    }

    func testTamperedCiphertextFails() throws {
        let sealed = try SyncCrypto.encrypt(Data("secret data".utf8), password: "pw-12345", iterations: rounds)
        var envelope = try JSONDecoder().decode(SyncCrypto.Envelope.self, from: sealed)
        var bytes = Data(base64Encoded: envelope.ciphertext)!
        bytes[0] ^= 0x01
        envelope.ciphertext = bytes.base64EncodedString()
        let tampered = try JSONEncoder().encode(envelope)
        XCTAssertThrowsError(try SyncCrypto.decrypt(tampered, password: "pw-12345", minimumIterations: rounds)) {
            XCTAssertEqual($0 as? SyncError, .wrongPassword)
        }
    }

    func testHeaderIsAuthenticated() throws {
        let sealed = try SyncCrypto.encrypt(Data("secret".utf8), password: "pw-12345", iterations: rounds)
        var envelope = try JSONDecoder().decode(SyncCrypto.Envelope.self, from: sealed)
        envelope.iterations += 1
        let tampered = try JSONEncoder().encode(envelope)
        XCTAssertThrowsError(try SyncCrypto.decrypt(tampered, password: "pw-12345", minimumIterations: rounds))
    }

    func testWeakParametersAreRefused() throws {
        let sealed = try SyncCrypto.encrypt(Data("x".utf8), password: "pw-12345", iterations: rounds)
        // With the production minimum, a 1 000-round file is rejected outright.
        XCTAssertThrowsError(try SyncCrypto.decrypt(sealed, password: "pw-12345")) {
            XCTAssertEqual($0 as? SyncError, .unsupportedParameters)
        }
    }

    func testNotAnEnvelope() {
        XCTAssertThrowsError(try SyncCrypto.decrypt(Data("hello".utf8), password: "pw")) {
            XCTAssertEqual($0 as? SyncError, .notASyncFile)
        }
    }

    func testDefaultIterationsRoundTrip() throws {
        let sealed = try SyncCrypto.encrypt(Data("full strength".utf8), password: "pw-12345")
        XCTAssertEqual(try SyncCrypto.decrypt(sealed, password: "pw-12345"), Data("full strength".utf8))
    }
}

final class SyncMergeTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    }

    private func host(_ id: UUID, name: String, modified: TimeInterval, group: UUID? = nil) -> SyncHost {
        SyncHost(profile: HostProfile(
            id: id, name: name, host: "\(name).example", username: "u",
            createdAt: date(0), groupID: group, modifiedAt: date(modified)
        ))
    }

    private var now: Date { date(1000) }

    func testUnionOfDisjointHosts() {
        let a = UUID(), b = UUID()
        var local = SyncDocument()
        local.hosts = [host(a, name: "a", modified: 1)]
        var remote = SyncDocument()
        remote.hosts = [host(b, name: "b", modified: 1)]
        let merged = SyncMerge.merge(local: local, remote: remote, now: now)
        XCTAssertEqual(Set(merged.hosts.map(\.profile.id)), [a, b])
    }

    func testNewerEditWins() {
        let id = UUID()
        var local = SyncDocument()
        local.hosts = [host(id, name: "old", modified: 1)]
        var remote = SyncDocument()
        remote.hosts = [host(id, name: "new", modified: 2)]
        XCTAssertEqual(SyncMerge.merge(local: local, remote: remote, now: now).hosts.first?.profile.name, "new")
        XCTAssertEqual(SyncMerge.merge(local: remote, remote: local, now: now).hosts.first?.profile.name, "new")
    }

    func testMergeIsSymmetricOnTies() {
        let id = UUID()
        var local = SyncDocument()
        local.hosts = [host(id, name: "left", modified: 5)]
        var remote = SyncDocument()
        remote.hosts = [host(id, name: "right", modified: 5)]
        let ab = SyncMerge.merge(local: local, remote: remote, now: now)
        let ba = SyncMerge.merge(local: remote, remote: local, now: now)
        XCTAssertEqual(ab, ba)
    }

    func testTombstoneDeletesOlderHost() {
        let id = UUID()
        var local = SyncDocument()
        local.tombstones = [SyncTombstone(id: id, kind: .host, deletedAt: date(10))]
        var remote = SyncDocument()
        remote.hosts = [host(id, name: "gone", modified: 5)]
        let merged = SyncMerge.merge(local: local, remote: remote, now: now)
        XCTAssertTrue(merged.hosts.isEmpty)
        XCTAssertEqual(merged.tombstones.map(\.id), [id])
    }

    func testEditAfterDeleteRevivesHost() {
        let id = UUID()
        var local = SyncDocument()
        local.tombstones = [SyncTombstone(id: id, kind: .host, deletedAt: date(10))]
        var remote = SyncDocument()
        remote.hosts = [host(id, name: "edited", modified: 20)]
        let merged = SyncMerge.merge(local: local, remote: remote, now: now)
        XCTAssertEqual(merged.hosts.map(\.profile.name), ["edited"])
        XCTAssertTrue(merged.tombstones.isEmpty)
    }

    func testOldTombstonesArePruned() {
        let id = UUID()
        var local = SyncDocument()
        local.tombstones = [SyncTombstone(id: id, kind: .host, deletedAt: date(0))]
        let later = date(0).addingTimeInterval(SyncMerge.tombstoneLifetime + 10)
        XCTAssertTrue(SyncMerge.merge(local: local, remote: SyncDocument(), now: later).tombstones.isEmpty)
    }

    func testDeletedGroupUngroupsHosts() {
        let groupID = UUID(), hostID = UUID()
        var local = SyncDocument()
        local.tombstones = [SyncTombstone(id: groupID, kind: .group, deletedAt: date(10))]
        var remote = SyncDocument()
        remote.groups = [HostGroup(id: groupID, name: "g", createdAt: date(0), modifiedAt: date(1))]
        remote.hosts = [host(hostID, name: "h", modified: 1, group: groupID)]
        let merged = SyncMerge.merge(local: local, remote: remote, now: now)
        XCTAssertTrue(merged.groups.isEmpty)
        XCTAssertNil(merged.hosts.first?.profile.groupID)
    }

    func testSecretsMergeIndependentlyOfProfile() {
        let id = UUID()
        var local = host(id, name: "newer-profile", modified: 10)
        local.password = SyncSecret(value: "old", modifiedAt: date(1))
        var remote = host(id, name: "older-profile", modified: 5)
        remote.password = SyncSecret(value: "fresh", modifiedAt: date(8))
        remote.passphrase = SyncSecret(value: nil, modifiedAt: date(3))
        let merged = SyncMerge.mergeHost(local, remote)
        XCTAssertEqual(merged.profile.name, "newer-profile")
        XCTAssertEqual(merged.password?.value, "fresh")
        XCTAssertEqual(merged.passphrase, SyncSecret(value: nil, modifiedAt: date(3)))
    }

    func testSecretRemovalPropagates() {
        let removed = SyncSecret(value: nil, modifiedAt: date(9))
        let stale = SyncSecret(value: "pw", modifiedAt: date(2))
        XCTAssertEqual(SyncMerge.newerSecret(stale, removed), removed)
        XCTAssertEqual(SyncMerge.newerSecret(removed, stale), removed)
    }

    func testConnectingDoesNotChangeFingerprint() {
        var doc = SyncDocument()
        doc.hosts = [host(UUID(), name: "x", modified: 1)]
        let before = doc.fingerprint()
        doc.hosts[0].profile.lastConnectedAt = date(50)
        XCTAssertEqual(doc.fingerprint(), before)
        XCTAssertNil(doc.normalized().hosts[0].profile.lastConnectedAt)
    }

    func testPasswordHostCarriesNoKeyPath() {
        var doc = SyncDocument()
        var h = host(UUID(), name: "pw", modified: 1)
        h.profile.privateKeyPath = "~/.ssh/id_ed25519"
        doc.hosts = [h]
        XCTAssertEqual(doc.normalized().hosts[0].profile.privateKeyPath, "")

        var profile = HostProfile(host: "h", auth: .password, privateKeyPath: "~/.ssh/id_ed25519")
        profile.normalize()
        XCTAssertEqual(profile.privateKeyPath, "")
        var keyed = HostProfile(host: "h", auth: .privateKey, privateKeyPath: "~/.ssh/id_ed25519")
        keyed.normalize()
        XCTAssertEqual(keyed.privateKeyPath, "~/.ssh/id_ed25519")
    }

    func testDocumentRoundTripsThroughEncryption() throws {
        var doc = SyncDocument()
        var h = host(UUID(), name: "srv", modified: 1)
        h.password = SyncSecret(value: "p@ss", modifiedAt: date(1))
        doc.hosts = [h]
        doc.groups = [HostGroup(name: "g", createdAt: date(0))]
        let sealed = try SyncCrypto.encrypt(doc.encoded(), password: "pw-12345", iterations: 1_000)
        let opened = try SyncDocument.decode(SyncCrypto.decrypt(sealed, password: "pw-12345", minimumIterations: 1_000))
        XCTAssertEqual(opened, doc.normalized())
        XCTAssertEqual(opened.fingerprint(), doc.fingerprint())
    }

    func testMergeConverges() {
        // Two devices that each merge with the other end up identical.
        let shared = UUID()
        var a = SyncDocument()
        a.hosts = [host(shared, name: "a-edit", modified: 4), host(UUID(), name: "only-a", modified: 1)]
        var b = SyncDocument()
        b.hosts = [host(shared, name: "b-edit", modified: 6), host(UUID(), name: "only-b", modified: 1)]
        b.tombstones = [SyncTombstone(id: UUID(), kind: .host, deletedAt: date(2))]
        let afterA = SyncMerge.merge(local: a, remote: b, now: now)
        let afterB = SyncMerge.merge(local: b, remote: afterA, now: now)
        XCTAssertEqual(afterA, afterB)
        XCTAssertEqual(afterA.hosts.count, 3)
    }
}

final class OneDriveClientTests: XCTestCase {
    @MainActor
    func testRedirectURI() {
        XCTAssertEqual(OneDriveClient.redirectURI, "cterm://auth")
        XCTAssertTrue(OneDriveClient.redirectURI.hasPrefix(OneDriveClient.callbackScheme + "://"))
    }

    func testDriveItemDecodesGraphFields() throws {
        let json = #"{"id":"x","name":"a.ctermsync","size":4812,"eTag":"\"{ABC},3\"","file":{"mimeType":"application/octet-stream"},"@microsoft.graph.downloadUrl":"https://example.invalid/dl"}"#
        let item = try JSONDecoder().decode(DriveItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.byteCount, 4812)
        XCTAssertEqual(item.eTag, "\"{ABC},3\"")
        XCTAssertNotNil(item.file)
        XCTAssertEqual(item.downloadURL, "https://example.invalid/dl")
    }
}

final class CredentialStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cterm-cred-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("credentials.json")
        CredentialStore.reset(fileURL: url)
        try? CredentialStore.setUp(password: "master-pw", iterations: 1_000)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testSaveLoadDeleteAndPersist() throws {
        let account = CredentialStore.account(for: UUID(), kind: "password")
        XCTAssertTrue(CredentialStore.save("s3cret", account: account))
        XCTAssertEqual(CredentialStore.load(account: account), "s3cret")

        // A fresh load from disk sees the same value; the file is private.
        CredentialStore.reset(fileURL: url)
        XCTAssertEqual(CredentialStore.state, .locked)
        XCTAssertNil(CredentialStore.load(account: account), "nothing is readable while locked")
        try CredentialStore.unlock(password: "master-pw", minimumIterations: 1_000)
        XCTAssertEqual(CredentialStore.load(account: account), "s3cret")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        CredentialStore.delete(account: account)
        XCTAssertNil(CredentialStore.load(account: account))
        XCTAssertNotNil(CredentialStore.modifiedAt(account: account), "a removal is recorded for sync")
    }

    func testResavingSameValueKeepsChangeTime() {
        let account = CredentialStore.account(for: UUID(), kind: "passphrase")
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        CredentialStore.save("pw", account: account, modifiedAt: first)
        CredentialStore.save("pw", account: account)
        XCTAssertEqual(CredentialStore.modifiedAt(account: account), first)
    }

    func testFileHoldsNoPlaintext() throws {
        CredentialStore.save("very-secret-value", account: "a.password")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("very-secret-value"))
        XCTAssertFalse(raw.contains("a.password"), "account names are encrypted too")
        XCTAssertTrue(SyncCrypto.isEnvelope(Data(raw.utf8), format: CredentialStore.fileFormat))
    }

    func testWrongMasterPasswordIsRejected() {
        CredentialStore.save("x", account: "a.password")
        CredentialStore.reset(fileURL: url)
        XCTAssertThrowsError(try CredentialStore.unlock(password: "nope", minimumIterations: 1_000))
        XCTAssertEqual(CredentialStore.state, .locked)
    }

    func testLockedStoreRefusesWrites() {
        CredentialStore.reset(fileURL: url)
        XCTAssertFalse(CredentialStore.saveItem("x", account: "y", service: CredentialStore.syncService))
    }

    func testChangeMasterPassword() throws {
        CredentialStore.save("kept", account: "a.password")
        XCTAssertThrowsError(try CredentialStore.changePassword(current: "wrong", to: "new-pw", iterations: 1_000))
        try CredentialStore.changePassword(current: "master-pw", to: "new-pw", iterations: 1_000)
        CredentialStore.reset(fileURL: url)
        XCTAssertThrowsError(try CredentialStore.unlock(password: "master-pw", minimumIterations: 1_000))
        try CredentialStore.unlock(password: "new-pw", minimumIterations: 1_000)
        XCTAssertEqual(CredentialStore.load(account: "a.password"), "kept")
    }

    func testSetUpEncryptsCredentialsFromOlderBuild() throws {
        // Before master passwords the file was plain JSON.
        CredentialStore.resetAll()
        let plain = #"{"version":1,"items":{"credentials/a.password":"legacy"},"times":{}}"#
        try plain.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CredentialStore.state, .needsSetup)
        try CredentialStore.setUp(password: "pw2", iterations: 1_000)
        XCTAssertEqual(CredentialStore.load(account: "a.password"), "legacy")
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("legacy"))
    }

    func testResetForgetsEverything() {
        CredentialStore.save("gone", account: "a.password")
        CredentialStore.resetAll()
        XCTAssertEqual(CredentialStore.state, .needsSetup)
        XCTAssertNil(CredentialStore.load(account: "a.password"))
    }

    func testServicesAreSeparate() {
        CredentialStore.saveItem("token", account: "x", service: CredentialStore.syncService)
        XCTAssertNil(CredentialStore.loadItem(account: "x", service: CredentialStore.credentialService))
        XCTAssertEqual(CredentialStore.loadItem(account: "x", service: CredentialStore.syncService), "token")
    }
}

final class PrivateKeyVaultTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cterm-vault-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CredentialStore.reset(fileURL: directory.appendingPathComponent("credentials.json"))
        try? CredentialStore.setUp(password: "master-pw", iterations: 1_000)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeKey(_ text: String, named name: String = "id_test", modified: TimeInterval) -> String {
        let url = directory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)],
                                               ofItemAtPath: url.path)
        return url.path
    }

    private func profile(path: String, id: UUID = UUID()) -> HostProfile {
        HostProfile(id: id, name: "k", host: "h", username: "u", auth: .privateKey, privateKeyPath: path)
    }

    func testImportsKeyWithFileTime() throws {
        let host = profile(path: writeKey("KEY-A", modified: 1_700_000_000))
        XCTAssertEqual(try PrivateKeyVault.keyText(for: host), "KEY-A")
        let account = PrivateKeyVault.account(for: host)
        XCTAssertEqual(CredentialStore.load(account: account), "KEY-A")
        XCTAssertEqual(CredentialStore.modifiedAt(account: account), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testOldFileDoesNotOverwriteNewerSyncedKey() throws {
        // A new Mac has an older key file at the same path; the cloud copy is newer.
        let host = profile(path: writeKey("OLD", modified: 1_600_000_000))
        CredentialStore.save("NEW", account: PrivateKeyVault.account(for: host),
                             modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try PrivateKeyVault.keyText(for: host), "NEW")
    }

    func testSyncedKeyIsNotReplacedByUnchangedFile() throws {
        let path = writeKey("ROTATE-ME", modified: 1_600_000_000)
        let host = profile(path: path)
        PrivateKeyVault.refresh(host)
        // Another Mac rotated the key; sync stores it here.
        CredentialStore.save("ROTATED", account: PrivateKeyVault.account(for: host),
                             modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try PrivateKeyVault.keyText(for: host), "ROTATED")
    }

    func testEditedFileIsImported() throws {
        let path = writeKey("V1", modified: 1_600_000_000)
        let host = profile(path: path)
        PrivateKeyVault.refresh(host)
        _ = writeKey("V2", modified: 1_650_000_000)
        XCTAssertEqual(try PrivateKeyVault.keyText(for: host), "V2")
    }

    func testChangingKeyPathUsesNewFile() throws {
        let id = UUID()
        PrivateKeyVault.refresh(profile(path: writeKey("FIRST", named: "a", modified: 1_700_000_000), id: id))
        let moved = profile(path: writeKey("SECOND", named: "b", modified: 1_500_000_000), id: id)
        XCTAssertEqual(try PrivateKeyVault.keyText(for: moved), "SECOND")
    }

    func testMissingFileFallsBackToSyncedCopy() throws {
        let host = profile(path: directory.appendingPathComponent("absent").path)
        CredentialStore.save("FROM-CLOUD", account: PrivateKeyVault.account(for: host),
                             modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try PrivateKeyVault.keyText(for: host), "FROM-CLOUD")
    }

    func testQuickConnectReadsFileOnly() throws {
        var host = profile(path: writeKey("TEMP", modified: 1_700_000_000))
        host.isTemporary = true
        XCTAssertEqual(try PrivateKeyVault.keyText(for: host), "TEMP")
        XCTAssertNil(CredentialStore.load(account: PrivateKeyVault.account(for: host)))
    }

    func testPrivateKeyMergesByTime() {
        let id = UUID()
        var a = SyncHost(profile: HostProfile(id: id, modifiedAt: Date(timeIntervalSince1970: 10)))
        a.privateKey = SyncSecret(value: "old", modifiedAt: Date(timeIntervalSince1970: 1))
        var b = a
        b.privateKey = SyncSecret(value: "new", modifiedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(SyncMerge.mergeHost(a, b).privateKey?.value, "new")
    }
}

final class LocalProfileTests: XCTestCase {
    func testHostsWithoutLocalFlagStillDecodeAndEncodeUnchanged() throws {
        let json = #"{"id":"4722D042-F5E6-45DA-AC85-11DE0369E23A","name":"a","host":"h","port":22,"username":"u","auth":"password","privateKeyPath":"","rememberSecret":false,"createdAt":"2026-10-26T12:50:32Z","notes":"","isTemporary":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(HostProfile.self, from: Data(json.utf8))
        XCTAssertFalse(profile.isLocal)
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertFalse(encoded.contains("local"), "no new key for ordinary hosts")
    }

    func testLocalShellProfile() {
        let profile = HostProfile.localShell()
        XCTAssertTrue(profile.isLocal)
        XCTAssertTrue(profile.isTemporary)
        XCTAssertTrue(profile.endpoint.hasPrefix("本机"))
    }
}
