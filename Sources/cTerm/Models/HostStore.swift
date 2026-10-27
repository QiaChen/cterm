import Foundation

extension Notification.Name {
    /// Posted after every change to the saved hosts or groups.
    static let ctermHostStoreDidChange = Notification.Name("cterm.hostStoreDidChange")
}

final class HostStore {
    private(set) var hosts: [HostProfile] = []
    private(set) var groups: [HostGroup] = []
    /// Deleted hosts and groups, kept so cloud sync can delete them elsewhere.
    private(set) var tombstones: [SyncTombstone] = []
    var onChange: (() -> Void)?

    private struct Payload: Codable {
        var version: Int
        var groups: [HostGroup]
        var hosts: [HostProfile]
        var tombstones: [SyncTombstone]?
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let url = fileURL ?? AppPaths.supportDirectory.appendingPathComponent("hosts.json")
        self.fileURL = url
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func host(withID id: UUID) -> HostProfile? {
        hosts.first { $0.id == id }
    }

    func group(withID id: UUID?) -> HostGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func hosts(inGroup id: UUID?) -> [HostProfile] {
        hosts.filter { $0.groupID == id }
    }

    var ungroupedHosts: [HostProfile] {
        hosts(inGroup: nil)
    }

    // MARK: - Hosts

    func add(_ profile: HostProfile) {
        var value = profile
        value.normalize()
        value.isTemporary = false
        value.groupID = validGroupID(value.groupID)
        value.modifiedAt = SyncClock.now()
        if let index = hosts.firstIndex(where: { $0.id == value.id }) {
            hosts[index] = value
        } else {
            hosts.insert(value, at: 0)
        }
        persist()
        onChange?()
    }

    func update(_ profile: HostProfile) {
        guard let index = hosts.firstIndex(where: { $0.id == profile.id }) else { return }
        var value = profile
        value.normalize()
        value.isTemporary = false
        value.groupID = validGroupID(value.groupID)
        if value != hosts[index] {
            value.modifiedAt = SyncClock.now()
        }
        hosts[index] = value
        persist()
        onChange?()
    }

    func remove(id: UUID) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        hosts.removeAll { $0.id == id }
        addTombstone(id: id, kind: .host)
        persist()
        onChange?()
    }

    func setGroup(_ groupID: UUID?, for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        let target = validGroupID(groupID)
        guard hosts[index].groupID != target else { return }
        hosts[index].groupID = target
        hosts[index].modifiedAt = SyncClock.now()
        persist()
        onChange?()
    }

    func markConnected(id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnectedAt = Date()
        persist()
        onChange?()
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(named name: String) -> HostGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("未分组") != .orderedSame else { return nil }
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }
        let group = HostGroup(name: trimmed, sortIndex: groups.count, modifiedAt: SyncClock.now())
        groups.append(group)
        persist()
        onChange?()
        return group
    }

    @discardableResult
    func renameGroup(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("未分组") != .orderedSame else { return false }
        guard !groups.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return false }
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[index].name = trimmed
        groups[index].modifiedAt = SyncClock.now()
        persist()
        onChange?()
        return true
    }

    func deleteGroup(id: UUID) {
        for index in hosts.indices where hosts[index].groupID == id {
            hosts[index].groupID = nil
        }
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        addTombstone(id: id, kind: .group)
        persist()
        onChange?()
    }

    // MARK: - Sync

    /// Replaces everything with the result of a cloud sync merge.
    func replaceAll(hosts newHosts: [HostProfile], groups newGroups: [HostGroup], tombstones newTombstones: [SyncTombstone]) {
        groups = newGroups.sorted { ($0.sortIndex ?? 0) < ($1.sortIndex ?? 0) }
        // Keep the local order for hosts that already exist; new ones go first,
        // like hosts added by hand.
        let order = Dictionary(uniqueKeysWithValues: hosts.enumerated().map { ($1.id, $0) })
        hosts = newHosts.sorted {
            (order[$0.id] ?? -1, $0.createdAt) < (order[$1.id] ?? -1, $1.createdAt)
        }
        for index in hosts.indices {
            hosts[index].isTemporary = false
            hosts[index].groupID = validGroupID(hosts[index].groupID)
            hosts[index].dropUnusedKeyPath()
        }
        tombstones = newTombstones
        persist()
        onChange?()
    }

    private func addTombstone(id: UUID, kind: SyncTombstone.Kind) {
        tombstones.removeAll { $0.id == id }
        tombstones.append(SyncTombstone(id: id, kind: kind, deletedAt: SyncClock.now()))
    }

    // MARK: - Persistence

    private func validGroupID(_ id: UUID?) -> UUID? {
        guard let id, groups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            if let payload = try? decoder.decode(Payload.self, from: data) {
                groups = payload.groups.sorted { ($0.sortIndex ?? 0) < ($1.sortIndex ?? 0) }
                hosts = payload.hosts
                tombstones = payload.tombstones ?? []
            } else {
                // Migrate the original array-only format.
                hosts = try decoder.decode([HostProfile].self, from: data)
                groups = []
            }
            for index in hosts.indices {
                hosts[index].groupID = validGroupID(hosts[index].groupID)
                hosts[index].dropUnusedKeyPath()
            }
        } catch {
            NSLog("cTerm: failed to load hosts: \(error)")
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            hosts = []
            groups = []
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for index in groups.indices where groups[index].sortIndex == nil {
                groups[index].sortIndex = index
            }
            let payload = Payload(version: 3, groups: groups, hosts: hosts, tombstones: tombstones)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("cTerm: failed to save hosts: \(error)")
        }
        NotificationCenter.default.post(name: .ctermHostStoreDidChange, object: self)
    }
}

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("cTerm", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
