import AppKit
import UniformTypeIdentifiers

/// Which local app opens a remote file for editing. A choice made with
/// "编辑方式" is remembered per file extension.
enum EditorApps {
    private static let choicesKey = "cterm.editorByExtension"
    private static let textEditID = "com.apple.TextEdit"

    private static func key(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "(none)" : ext
    }

    private static func type(for fileName: String) -> UTType {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? .plainText : (UTType(filenameExtension: ext) ?? .plainText)
    }

    static var textEdit: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEditID)
    }

    /// The remembered app, else the system default for the type, else
    /// TextEdit. Config files like `.conf` or `.env` often have no default.
    static func preferredApp(forFileNamed fileName: String) -> URL? {
        let choices = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: String] ?? [:]
        if let path = choices[key(for: fileName)], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let type = type(for: fileName)
        if type != .data, let app = NSWorkspace.shared.urlForApplication(toOpen: type) {
            return app
        }
        return textEdit
    }

    static func remember(_ app: URL, forFileNamed fileName: String) {
        var choices = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: String] ?? [:]
        choices[key(for: fileName)] = app.path
        UserDefaults.standard.set(choices, forKey: choicesKey)
    }

    /// Apps for the "编辑方式" menu: ones that open this type plus plain-text
    /// editors, the preferred one first.
    static func candidates(forFileNamed fileName: String) -> [URL] {
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type(for: fileName))
        apps += NSWorkspace.shared.urlsForApplications(toOpen: .plainText)
        var seen = Set<String>()
        var unique = apps.filter { seen.insert($0.standardizedFileURL.path).inserted }
        unique.sort { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
        if let preferred = preferredApp(forFileNamed: fileName),
           let index = unique.firstIndex(where: { $0.standardizedFileURL == preferred.standardizedFileURL }) {
            unique.insert(unique.remove(at: index), at: 0)
        }
        return unique
    }

    static func displayName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    static func open(_ file: URL, with app: URL?) {
        guard let app = app ?? preferredApp(forFileNamed: file.lastPathComponent) else {
            NSWorkspace.shared.open(file)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }
}
